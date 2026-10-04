import CoreVideo
import DaylightKit
import Foundation
import Metal
import QuartzCore

/// Presenter Overlay (SPEC 6.7): owns the person segmenter, the mask processor and the fallback state machine
/// (`OverlayHealth`). Exists only while `Settings.overlayEnabled`; FramePipeline creates and releases it.
/// Threads: `offer` from the capture queue, `renderInput` and `perfLine` from the render queue, `update` from the
/// caller of `FramePipeline.updateSettings`, the segmentation outcome on the segmenter queue. Shared state is under
/// one lock.
final class OverlayController {
    let segmenter: PersonSegmenter
    let processor: MaskProcessor
    private let telemetry: Telemetry

    private struct State {
        var health = OverlayHealth()
        var config: OverlayLayout.Config
        var quality: OverlayQuality
        var resetProcessorHistory = false
    }
    private let state: Locked<State>

    /// Rows 48 and 49 (`.overlayFallback`, `.overlayLowCoverage`); called on the segmenter queue.
    var onFailure: ((FailureText.Case, [String]) -> Void)?

    convenience init(device: MTLDevice, settings: Settings, telemetry: Telemetry) throws {
        try self.init(device: device, settings: settings, telemetry: telemetry, engine: VisionPersonEngine())
    }

    init(device: MTLDevice, settings: Settings, telemetry: Telemetry, engine: PersonMaskEngine) throws {
        let s = settings.validated()
        self.telemetry = telemetry
        processor = try MaskProcessor(device: device, smoothing: s.overlaySmoothing, feather: s.overlayFeather)
        segmenter = PersonSegmenter(engine: engine, quality: s.overlayQuality)
        state = Locked(State(config: OverlayLayout.Config(settings: s), quality: s.overlayQuality))
        processor.onLog = { [weak telemetry] text in telemetry?.note("overlay", text) }
        segmenter.onOutcome = { [weak self] outcome, at in self?.handle(outcome, at: at) }
    }

    func update(settings: Settings) {
        let s = settings.validated()
        processor.setTuning(smoothing: s.overlaySmoothing, feather: s.overlayFeather)
        segmenter.setQuality(s.overlayQuality)
        state.withLock { st in
            st.config = OverlayLayout.Config(settings: s)
            if st.quality != s.overlayQuality {
                st.quality = s.overlayQuality
                st.health.reset()
                st.resetProcessorHistory = true
            }
        }
    }

    /// Capture queue: hands the frame to the segmenter, which drops it while busy. Once the fallback has latched
    /// nothing is segmented: the pipeline draws Studio Split until a reset (toggle or quality change), so a mask
    /// would be work nobody sees.
    func offer(_ pixelBuffer: CVPixelBuffer, hostTimeNs: UInt64?) {
        if isFellBack { return }
        segmenter.offer(pixelBuffer, hostTimeNs: hostTimeNs)
    }

    /// The cutout's layout config (position, size, opacity, halo) from Settings.
    var layoutConfig: OverlayLayout.Config {
        return state.withLock { $0.config }
    }

    var isFellBack: Bool {
        return state.withLock { $0.health.fallbackReason != nil }
    }

    func presentation(now: Double) -> OverlayHealth.Presentation {
        return state.withLock { $0.health.presentation(now: now) }
    }

    /// Render queue: whether Overlay fell back to Studio Split, and the compositor input. A missing, stale or empty
    /// mask leaves `mask` nil, which the compositor draws as the camera rectangle.
    func renderInput(now: Double) -> (fellBack: Bool, input: Compositor.OverlayInput) {
        let presentation = self.presentation(now: now)
        var input = Compositor.OverlayInput()
        switch presentation {
        case .fellBack:
            return (true, input)
        case .rectangle:
            return (false, input)
        case .matte:
            input.mask = processor.latest?.texture
            return (false, input)
        }
    }

    var lastSegmentationMs: Double { return segmenter.lastSegmentationMs }
    var dropped: UInt64 { return segmenter.dropped }

    /// Age of the newest mask in milliseconds, or -1 before the first one.
    func maskAgeMs(now: Double) -> Double {
        guard let at = state.withLock({ $0.health.lastMaskAt }) else { return -1 }
        return max(0, now - at) * 1000
    }

    /// `perf overlay seg_ms=<x> mask_age_ms=<x> seg_dropped=<n> state=<matte|rectangle|fellBack>`.
    func perfLine(now: Double) -> String {
        let name: String
        switch presentation(now: now) {
        case .matte: name = "matte"
        case .rectangle: name = "rectangle"
        case .fellBack: name = "fellBack"
        }
        return String(format: "perf overlay seg_ms=%.3f mask_age_ms=%.1f seg_dropped=%llu state=%@", lastSegmentationMs, maskAgeMs(now: now), dropped, name)
    }

    /// Tests and the self-test: returns once the segmenter queue has finished what it was given.
    func drain() {
        segmenter.queue.sync {}
    }

    // MARK: Segmenter queue

    private func handle(_ outcome: PersonSegmenter.Outcome, at: Double) {
        let resetHistory = state.withLock { st -> Bool in
            let reset = st.resetProcessorHistory
            st.resetProcessorHistory = false
            return reset
        }
        if resetHistory { processor.resetHistory() }
        var effects: [OverlayHealth.Effect] = []
        var failures = 0
        switch outcome {
        case let .mask(mask, coverage):
            do {
                try processor.process(mask: mask, at: at, coverage: coverage)
                effects = state.withLock { $0.health.segmented(coverage: coverage, now: at) }
            } catch {
                let reason = "mask processing: \(error)"
                effects = state.withLock { st -> [OverlayHealth.Effect] in
                    let result = st.health.failed(reason: reason, now: at)
                    failures = st.health.consecutiveFailures
                    return result
                }
            }
        case let .failed(reason):
            effects = state.withLock { st -> [OverlayHealth.Effect] in
                let result = st.health.failed(reason: reason, now: at)
                failures = st.health.consecutiveFailures
                return result
            }
        }
        for effect in effects {
            switch effect {
            case let .fellBack(reason):
                let args = ["\(failures)", reason]
                telemetry.note("overlay", FailureText.logLine(.overlayFallback, args))
                onFailure?(.overlayFallback, args)
            case let .lowCoverage(coverage):
                let args = [String(format: "%.3f", coverage)]
                telemetry.note("overlay", FailureText.logLine(.overlayLowCoverage, args))
                onFailure?(.overlayLowCoverage, args)
            case .matteRestored:
                telemetry.note("overlay", "overlay: mask coverage back above 0.01; showing the matte")
            }
        }
    }
}
