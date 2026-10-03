import AVFoundation
import CoreMedia
import CoreVideo
import DaylightKit
import Foundation
import Metal
import os
import QuartzCore

/// The frame pipeline (ARCHITECTURE section 3): camera frames pass through untouched while the governor is in
/// PASSTHROUGH; a 30 Hz clock drives one Metal pass per frame otherwise. Owns the governor under one lock, the idle
/// rule of SPEC D32, the STATE cadence of SPEC D47 and the perf counters. Implements `PipelineControl`.
final class FramePipeline: PipelineControl {
    /// STATE cadence (SPEC D47): 10 Hz while ENGAGING, RETURNING or pre-warning; 1 Hz while LIVE.
    static let stateIntervalAnimating: Double = 0.1
    static let stateIntervalLive: Double = 1.0
    static let outputWidth = 1920
    static let outputHeight = 1080

    let sink: VirtualCameraSink
    let telemetry: Telemetry
    let renderQueue: DispatchQueue
    let captureQueue: DispatchQueue
    let clock: FrameClock
    let surfaces: CanvasSurfaces
    let compositor: Compositor?
    let pool: OutputPool?
    let feeder: FrameFeeder
    let cameraSlot = LatestFrameSlot()
    let device: MTLDevice?
    private let governor: Locked<EngageGovernor>
    private let log = Logger(subsystem: Telemetry.subsystem, category: "pipeline")

    private struct Flags {
        var viewers = 0
        var previewVisible = false
        var sinkConnected = false
        var saving = false
        var cameraAttached = false
        var captureRunning = false
        var captureIdleReason: String?
        var inkSource: InkSource
        var mirror: MirrorFrameSource?
        var zeroCopyEligible = true
        var firstFrame: String?
    }
    private let flags: Locked<Flags>
    private var settings: Settings
    private(set) var capture: CaptureSource?
    private var captureObserver: NSObjectProtocol?
    private var idleWork: DispatchWorkItem?
    /// Tests shorten the 60 s hysteresis; nil means `settings.viewerIdleStopSeconds`.
    var idleStopOverrideSeconds: Double?

    // Counters (render queue and Metal completion thread; the Locked keeps them coherent for the 2 Hz readers).
    private struct Counters {
        var pushed: UInt64 = 0
        var dropped: UInt64 = 0
        var composed: UInt64 = 0
        var cpuMsLast: Double = 0
        var gpuMsLast: Double = 0
        var fpsWindowStart: Double = 0
        var fpsWindowCount: UInt64 = 0
        var fps: Double = 0
        var inkArrivalNs: UInt64?
    }
    private let counters = Locked<Counters>(Counters())
    private var stateLimiter = RateLimiter(minInterval: FramePipeline.stateIntervalAnimating)
    private var lastReportKey: (UInt8, UInt8, UInt8, UInt8)?
    private var perfTimer: DispatchSourceTimer?
    private var creamCard: CVPixelBuffer?

    // MARK: Callbacks (set once at wiring time)

    var onStateForClients: ((StateReport) -> Void)?
    var onPreviewFrame: ((CVPixelBuffer) -> Void)?
    /// Governor effects the ink router acts on (ink.queue hop is the router's job).
    var onSavePage: ((SaveReason) -> Void)?
    var onClearCanvas: (() -> Void)?
    var onStateChanged: ((GovernorState, GovernorState) -> Void)?
    var onCameraPresence: ((Bool) -> Void)?
    var onFailure: ((FailureText.Case, [String]) -> Void)?
    var latencyProbe = false

    init(sink: VirtualCameraSink, settings: Settings, telemetry: Telemetry, device: MTLDevice? = MTLCreateSystemDefaultDevice(), capture: CaptureSource? = nil, now: Double = CACurrentMediaTime()) throws {
        let validated = settings.validated()
        self.sink = sink
        self.settings = validated
        self.telemetry = telemetry
        self.device = device
        let target = DispatchQueue.global(qos: .userInteractive)
        renderQueue = DispatchQueue(label: "com.twelve.daylight.render", qos: .userInteractive, target: target)
        captureQueue = DispatchQueue(label: "com.twelve.daylight.capture", qos: .userInteractive)
        clock = FrameClock(queue: renderQueue, fps: 30)
        surfaces = try CanvasSurfaces(device: device)
        if let device = device {
            compositor = try Compositor(device: device)
            pool = try OutputPool(width: FramePipeline.outputWidth, height: FramePipeline.outputHeight)
        } else {
            compositor = nil
            pool = nil
        }
        feeder = FrameFeeder(sink: sink)
        governor = Locked(EngageGovernor(config: GovernorConfig(settings: validated), now: now))
        var initialFlags = Flags(inkSource: validated.inkSource)
        if case .connected = sink.status { initialFlags.sinkConnected = true }
        flags = Locked(initialFlags)
        self.capture = capture
        clock.onTick = { [weak self] now in self?.tick(now: now) }
        compositor?.onConversionFallback = { [weak self] text in self?.telemetry.note("pipeline", text) }
        if let capture = capture {
            capture.onEvent = { [weak self] event in self?.handleCapture(event) }
        }
        captureObserver = NotificationCenter.default.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.renderQueue.async { self.recomputeCapture() }
        }
    }

    deinit {
        if let observer = captureObserver { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: PipelineControl

    func post(_ event: GovernorEvent) {
        let now = CACurrentMediaTime()
        let out = governor.withLock { $0.handle(event, now: now) }
        renderQueue.async { [weak self] in self?.consume(out, now: now, fromEvent: true) }
    }

    var governorSnapshot: GovernorOutput {
        return governor.withLock { $0.snapshot }
    }

    func setViewerCount(_ n: Int) {
        flags.withLock { $0.viewers = max(0, n) }
        renderQueue.async { [weak self] in
            self?.recomputeCapture()
            self?.publishFlagsChange()
        }
    }

    func setPreviewVisible(_ visible: Bool) {
        flags.withLock { $0.previewVisible = visible }
        renderQueue.async { [weak self] in
            self?.recomputeCapture()
            self?.publishFlagsChange()
        }
    }

    func setSinkConnected(_ connected: Bool) {
        flags.withLock { $0.sinkConnected = connected }
        renderQueue.async { [weak self] in
            self?.recomputeCapture()
            self?.publishFlagsChange()
        }
    }

    // MARK: Wiring

    /// Replaces the capture source (tests pass a `FakeCapture`; the app passes a `WebcamCapture` on `captureQueue`).
    func setCaptureSource(_ source: CaptureSource?) {
        renderQueue.async { [weak self] in
            guard let self = self else { return }
            if let old = self.capture, old.isRunning { old.stop() }
            self.capture = source
            source?.onEvent = { [weak self] event in self?.handleCapture(event) }
            self.flags.withLock { $0.captureRunning = false }
            self.recomputeCapture()
        }
    }

    /// Switches the webcam (Settings `cameraUniqueID`).
    func setCamera(_ device: AVCaptureDevice?) {
        renderQueue.async { [weak self] in
            guard let self = self, let webcam = self.capture as? WebcamCapture else { return }
            webcam.device = device
            if webcam.isRunning {
                webcam.stop()
                self.flags.withLock { $0.captureRunning = false }
            }
            self.recomputeCapture()
        }
    }

    func setInkSource(_ source: InkSource) {
        flags.withLock { $0.inkSource = source }
        post(.sourceChanged(source))
    }

    func setMirrorSource(_ mirror: MirrorFrameSource?) {
        flags.withLock { $0.mirror = mirror }
    }

    /// STATE bit6 while a page write is in progress.
    func setSaving(_ saving: Bool) {
        flags.withLock { $0.saving = saving }
        renderQueue.async { [weak self] in self?.publishFlagsChange() }
    }

    /// Applies changed governor settings (idle timeout, pre-warning, spring, eraser rule). A changed config restarts
    /// the governor in PASSTHROUGH (settings change in the Settings window, never mid-call by design).
    func updateSettings(_ newSettings: Settings) {
        let validated = newSettings.validated()
        settings = validated
        let config = GovernorConfig(settings: validated)
        let now = CACurrentMediaTime()
        governor.withLock { g in
            if g.config != config {
                g = EngageGovernor(config: config, now: now)
            }
        }
        flags.withLock { $0.inkSource = validated.inkSource }
        renderQueue.async { [weak self] in self?.publishFlagsChange() }
    }

    /// The latency probe (ARCHITECTURE 3.5): the ink router stamps the arrival of an engaging STROKE_START.
    func noteInkArrival(hostTimeNs: UInt64) {
        guard latencyProbe else { return }
        counters.withLock { if $0.inkArrivalNs == nil { $0.inkArrivalNs = hostTimeNs } }
    }

    /// Starts the clock bookkeeping and the capture decision; call once after wiring.
    func start() {
        renderQueue.async { [weak self] in
            guard let self = self else { return }
            self.recomputeCapture()
            if self.telemetry.perfLog { self.startPerfLog() }
        }
    }

    /// Quit: stop the clock and the camera. The router saves the page (`savePage(.quit)`) before this is called.
    func shutdown() {
        renderQueue.sync {
            clock.stop()
            perfTimer?.cancel()
            perfTimer = nil
            idleWork?.cancel()
            idleWork = nil
            if let capture = capture, capture.isRunning { capture.stop() }
            flags.withLock { $0.captureRunning = false }
        }
    }

    // MARK: Stats

    var stats: PipelineStats {
        let f = flags.withLock { $0 }
        let c = counters.withLock { $0 }
        let out = governorSnapshot
        var s = PipelineStats()
        switch out.state {
        case .passthrough: s.mode = "passthrough"
        case .engaging: s.mode = "engaging"
        case .live: s.mode = out.layout == .whiteboardOnly ? "whiteboard" : "split"
        case .returning: s.mode = "returning"
        }
        s.fps = c.fps
        s.cpuMsPerFrame = c.cpuMsLast
        s.gpuMsPerFrame = c.gpuMsLast
        s.dropped = c.dropped + feeder.droppedFrames
        s.pushed = feeder.pushedFrames
        s.inFlight = pool?.inFlight ?? 0
        s.passthroughZeroCopy = f.zeroCopyEligible
        s.capturing = f.captureRunning
        s.captureIdleReason = f.captureIdleReason
        s.viewers = f.viewers
        s.firstFrame = f.firstFrame
        s.cameraAttached = f.cameraAttached
        s.sinkConnected = f.sinkConnected
        return s
    }

    /// The flags every STATE carries (bits 4 to 7); the router adds the per-client bits.
    var globalStateFlags: StateReport.Flags {
        let f = flags.withLock { $0 }
        var bits: StateReport.Flags = []
        if f.cameraAttached { bits.insert(.cameraAttached) }
        if f.sinkConnected { bits.insert(.sinkConnected) }
        if f.saving { bits.insert(.saving) }
        if f.captureIdleReason != nil { bits.insert(.captureIdle) }
        return bits
    }

    var inkSource: InkSource {
        return flags.withLock { $0.inkSource }
    }

    func stateReport(_ out: GovernorOutput) -> StateReport {
        return out.stateReport(clientFlags: globalStateFlags, inkSource: inkSource, pageIndex: 0, strokeCount: 0, undoDepth: 0, redoDepth: 0)
    }

    // MARK: Governor outputs (render queue)

    private func consume(_ out: GovernorOutput, now: Double, fromEvent: Bool) {
        for effect in out.effects {
            switch effect {
            case let .stateChanged(from, to):
                telemetry.note("governor", "\(from) -> \(to)")
                if to == .engaging && from == .passthrough {
                    clock.start()
                    renderFrame(now: now, out: out)
                }
                onStateChanged?(from, to)
            case let .savePage(reason):
                onSavePage?(reason)
            case .clearCanvas:
                onClearCanvas?()
            case .preWarningStarted, .preWarningCancelled, .pinChanged, .holdChanged:
                break
            }
        }
        let needsTicks = governor.withLock { $0.needsTicks }
        if needsTicks && !clock.isRunning { clock.start() }
        if !needsTicks && clock.isRunning { clock.stop() }
        publishState(out, now: now, force: !out.effects.isEmpty)
    }

    private func tick(now: Double) {
        let out = governor.withLock { $0.tick(now: now) }
        consume(out, now: now, fromEvent: false)
        if out.state != .passthrough {
            renderFrame(now: now, out: out)
        }
    }

    private func publishFlagsChange() {
        let out = governorSnapshot
        publishState(out, now: CACurrentMediaTime(), force: false)
    }

    private func publishState(_ out: GovernorOutput, now: Double, force: Bool) {
        let report = stateReport(out)
        let key = (report.governor, report.flags, report.mode, report.inkSource)
        let changed = lastReportKey == nil || lastReportKey! != key
        if changed || force {
            lastReportKey = key
            stateLimiter = RateLimiter(minInterval: FramePipeline.stateIntervalAnimating)
            _ = stateLimiter.allow(now: now)
            onStateForClients?(report)
            return
        }
        switch out.state {
        case .engaging, .returning:
            stateLimiter.minInterval = FramePipeline.stateIntervalAnimating
        case .live:
            stateLimiter.minInterval = out.preWarning ? FramePipeline.stateIntervalAnimating : FramePipeline.stateIntervalLive
        case .passthrough:
            return
        }
        if stateLimiter.allow(now: now) {
            onStateForClients?(report)
        }
    }

    // MARK: Rendering (render queue)

    private func renderFrame(now: Double, out: GovernorOutput) {
        guard let compositor = compositor, let pool = pool else { return }
        let signpost = telemetry.begin("composite")
        let cpuStart = CACurrentMediaTime()
        let f = flags.withLock { $0 }
        var canvas: Compositor.CanvasInput = .layers(surfaces)
        var orientation = StudioLayout.CanvasOrientation.portrait
        var aspect = StudioLayout.portraitAspect
        if f.inkSource == .mirror {
            if let mirror = f.mirror, let latest = mirror.latest() {
                canvas = .mirror(latest.buffer, uv: latest.uv)
                orientation = latest.orientation
                aspect = latest.aspect
            } else {
                canvas = .none
            }
        }
        let frame = StudioLayout.frame(progress: out.progress, layout: out.layout, orientation: orientation, canvasAspect: aspect, breath: out.breath)
        guard let target = pool.acquire() else {
            counters.withLock { $0.dropped += 1 }
            telemetry.end(signpost, "composite")
            return
        }
        let presenter = cameraSlot.take()?.buffer
        let inputs = Compositor.Inputs(presenter: presenter, canvas: canvas, frame: frame)
        let progress = out.progress
        compositor.render(inputs, into: target) { [weak self] gpuSeconds in
            guard let self = self else { return }
            let pushSignpost = self.telemetry.begin("sink.push")
            self.feeder.push(target, hostTimeNs: nil)
            self.telemetry.end(pushSignpost, "sink.push")
            self.onPreviewFrame?(target)
            pool.release(target)
            self.recordComposedFrame(gpuMs: gpuSeconds * 1000, progress: progress)
        }
        let cpuMs = (CACurrentMediaTime() - cpuStart) * 1000
        counters.withLock { $0.cpuMsLast = cpuMs }
        telemetry.end(signpost, "composite")
    }

    /// Passthrough for a camera that is not IOSurface-backed 1920x1080 BGRA: one GPU pass with the passthrough frame.
    private func renderPassthroughComposed(_ pixelBuffer: CVPixelBuffer) {
        guard let compositor = compositor, let pool = pool else {
            feeder.push(pixelBuffer, hostTimeNs: nil)
            return
        }
        guard let target = pool.acquire() else {
            counters.withLock { $0.dropped += 1 }
            return
        }
        let inputs = Compositor.Inputs(presenter: pixelBuffer, canvas: .none, frame: StudioLayout.passthrough())
        compositor.render(inputs, into: target) { [weak self] gpuSeconds in
            guard let self = self else { return }
            self.feeder.push(target, hostTimeNs: nil)
            self.onPreviewFrame?(target)
            pool.release(target)
            self.recordComposedFrame(gpuMs: gpuSeconds * 1000, progress: 0)
        }
    }

    private func recordComposedFrame(gpuMs: Double, progress: Double) {
        let now = CACurrentMediaTime()
        var probe: Double?
        counters.withLock { c in
            c.composed += 1
            c.gpuMsLast = gpuMs
            FramePipeline.countFrame(&c, now: now)
            if progress > 0, let arrival = c.inkArrivalNs {
                probe = Double(DispatchTime.now().uptimeNanoseconds - arrival) / 1_000_000
                c.inkArrivalNs = nil
            }
        }
        if let ms = probe {
            telemetry.note("latency", String(format: "engage probe: STROKE_START to first moved frame %.1f ms", ms))
        }
    }

    private static func countFrame(_ c: inout Counters, now: Double) {
        c.pushed += 1
        if c.fpsWindowStart == 0 { c.fpsWindowStart = now }
        c.fpsWindowCount += 1
        let elapsed = now - c.fpsWindowStart
        if elapsed >= 1 {
            c.fps = Double(c.fpsWindowCount) / elapsed
            c.fpsWindowStart = now
            c.fpsWindowCount = 0
        }
    }

    // MARK: Capture path (capture queue)

    private func handleCapture(_ event: CaptureEvent) {
        switch event {
        case let .frame(pixelBuffer, hostTimeNs):
            let signpost = telemetry.begin("capture")
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let fourcc = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let backed = CVPixelBufferGetIOSurface(pixelBuffer) != nil
            var eligible = true
            var firstFacts: String?
            flags.withLock { f in
                if f.firstFrame == nil {
                    f.zeroCopyEligible = backed && width == FramePipeline.outputWidth && height == FramePipeline.outputHeight && fourcc == kCVPixelFormatType_32BGRA
                    f.firstFrame = "\(width)x\(height) \(Compositor.fourcc(fourcc)) iosurface=\(backed)"
                    firstFacts = f.firstFrame
                    f.cameraAttached = true
                }
                eligible = f.zeroCopyEligible
            }
            if let facts = firstFacts {
                telemetry.note("capture", "first frame \(facts) zeroCopy=\(eligible)")
                if !eligible {
                    telemetry.note("capture", FailureText.logLine(.webcamFormatComposed, ["\(width)", "\(height)", Compositor.fourcc(fourcc), "\(backed)"]))
                    onFailure?(.webcamFormatComposed, ["\(width)", "\(height)", Compositor.fourcc(fourcc), "\(backed)"])
                }
            }
            cameraSlot.publish(pixelBuffer, hostTimeNs: hostTimeNs)
            let state = governor.withLock { $0.state }
            if state == .passthrough {
                if eligible {
                    let pushSignpost = telemetry.begin("sink.push")
                    feeder.push(pixelBuffer, hostTimeNs: hostTimeNs)
                    telemetry.end(pushSignpost, "sink.push")
                    onPreviewFrame?(pixelBuffer)
                    let now = CACurrentMediaTime()
                    counters.withLock { FramePipeline.countFrame(&$0, now: now) }
                } else {
                    renderQueue.async { [weak self] in self?.renderPassthroughComposed(pixelBuffer) }
                }
            }
            telemetry.end(signpost, "capture")
        case let .formatChanged(width, height, pixelFormat):
            telemetry.note("capture", "format \(width)x\(height) \(Compositor.fourcc(pixelFormat))")
        case .lost:
            flags.withLock { $0.cameraAttached = false }
            cameraSlot.clear()
            telemetry.note("capture", "camera lost")
            onCameraPresence?(false)
            renderQueue.async { [weak self] in self?.publishFlagsChange() }
        case .restored:
            flags.withLock { $0.cameraAttached = true }
            telemetry.note("capture", "camera restored")
            onCameraPresence?(true)
            renderQueue.async { [weak self] in self?.publishFlagsChange() }
        }
    }

    // MARK: Idle rule (SPEC D32), render queue

    var wantsCapture: Bool {
        let f = flags.withLock { $0 }
        return f.viewers > 0 || f.previewVisible || !f.sinkConnected
    }

    private var idleStopSeconds: Double {
        return idleStopOverrideSeconds ?? Double(settings.viewerIdleStopSeconds)
    }

    private func recomputeCapture() {
        let wants = wantsCapture
        let running = flags.withLock { $0.captureRunning }
        if wants {
            idleWork?.cancel()
            idleWork = nil
            if !running { startCapture() }
        } else if running && idleWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.idleWork = nil
                if !self.wantsCapture { self.stopCaptureForIdle() }
            }
            idleWork = work
            renderQueue.asyncAfter(deadline: .now() + idleStopSeconds, execute: work)
        }
    }

    private func startCapture() {
        guard let capture = capture else {
            flags.withLock { $0.cameraAttached = false }
            return
        }
        do {
            try capture.start()
            flags.withLock { f in
                f.captureRunning = true
                f.captureIdleReason = nil
                f.cameraAttached = capture.hasDevice
            }
            let f = flags.withLock { $0 }
            telemetry.note("capture", "capture started (viewers=\(f.viewers) preview=\(f.previewVisible) sink=\(f.sinkConnected))")
            // The viewer never sees the extension placeholder: the last frame or a cream card goes out at once.
            if let cached = cameraSlot.take()?.buffer {
                feeder.push(cached, hostTimeNs: nil)
                onPreviewFrame?(cached)
            } else if let card = creamCardBuffer() {
                feeder.push(card, hostTimeNs: nil)
                onPreviewFrame?(card)
            }
            onCameraPresence?(capture.hasDevice)
        } catch {
            flags.withLock { f in
                f.captureRunning = false
                f.cameraAttached = false
            }
            telemetry.note("capture", FailureText.logLine(.noWebcam))
            onFailure?(.noWebcam, [])
            onCameraPresence?(false)
            if let card = creamCardBuffer() {
                feeder.push(card, hostTimeNs: nil)
                onPreviewFrame?(card)
            }
        }
        publishFlagsChange()
    }

    private func stopCaptureForIdle() {
        capture?.stop()
        flags.withLock { f in
            f.captureRunning = false
            f.captureIdleReason = "viewers=0 preview=hidden"
        }
        pool?.flush()
        telemetry.note("capture", FailureText.logLine(.captureIdle))
        publishFlagsChange()
    }

    /// A 1920x1080 SurfaceCream frame for the moments without a camera picture.
    private func creamCardBuffer() -> CVPixelBuffer? {
        if let card = creamCard { return card }
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, FramePipeline.outputWidth, FramePipeline.outputHeight, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let card = created else { return nil }
        CVPixelBufferLockBaseAddress(card, [])
        if let base = CVPixelBufferGetBaseAddress(card) {
            let stride = CVPixelBufferGetBytesPerRow(card)
            let cream = Tokens.surfaceCream
            let b = UInt8(cream.b * 255 + 0.5), g = UInt8(cream.g * 255 + 0.5), r = UInt8(cream.r * 255 + 0.5)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<FramePipeline.outputHeight {
                var o = y * stride
                for _ in 0..<FramePipeline.outputWidth {
                    bytes[o] = b
                    bytes[o + 1] = g
                    bytes[o + 2] = r
                    bytes[o + 3] = 255
                    o += 4
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(card, [])
        creamCard = card
        return card
    }

    // MARK: Perf log

    private func startPerfLog() {
        if perfTimer != nil { return }
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.telemetry.emit(self.stats)
        }
        perfTimer = timer
        timer.activate()
    }
}
