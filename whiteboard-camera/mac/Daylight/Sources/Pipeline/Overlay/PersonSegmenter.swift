import CoreVideo
import DaylightKit
import Foundation
import QuartzCore
import Vision

enum PersonSegmenterError: Error, CustomStringConvertible {
    case noResult

    var description: String {
        switch self {
        case .noResult: return "person segmentation returned no mask"
        }
    }
}

/// Produces one OneComponent8 person mask for a camera frame, or throws. The Vision engine below is the real one;
/// tests inject fakes (a throwing engine, a blocking one) through `PersonSegmenter.init(engine:)`.
protocol PersonMaskEngine: AnyObject {
    func mask(for pixelBuffer: CVPixelBuffer, quality: OverlayQuality) throws -> CVPixelBuffer
}

/// `VNGeneratePersonSegmentationRequest` (macOS 12) through one reused `VNSequenceRequestHandler`, output format
/// `kCVPixelFormatType_OneComponent8`, result `VNPixelBufferObservation.pixelBuffer`. Segmenter queue only.
final class VisionPersonEngine: PersonMaskEngine {
    private let handler = VNSequenceRequestHandler()
    private let request = VNGeneratePersonSegmentationRequest()

    init() {
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        request.qualityLevel = .fast
    }

    static func level(_ quality: OverlayQuality) -> VNGeneratePersonSegmentationRequest.QualityLevel {
        switch quality {
        case .fast: return .fast
        case .balanced: return .balanced
        case .accurate: return .accurate
        }
    }

    func mask(for pixelBuffer: CVPixelBuffer, quality: OverlayQuality) throws -> CVPixelBuffer {
        let level = VisionPersonEngine.level(quality)
        if request.qualityLevel != level { request.qualityLevel = level }
        try handler.perform([request], on: pixelBuffer)
        guard let observation = request.results?.first else { throw PersonSegmenterError.noResult }
        return observation.pixelBuffer
    }
}

/// Runs person segmentation on its own serial queue (SPEC 6.7). `offer` never queues: while a frame is in flight
/// (segmentation plus the mask processing the handler does on this queue) a new frame is dropped and counted.
final class PersonSegmenter {
    enum Outcome {
        case mask(CVPixelBuffer, coverage: Double)
        case failed(String)
    }

    let queue = DispatchQueue(label: "com.twelve.daylight.overlay.segment", qos: .userInitiated)
    private let engine: PersonMaskEngine
    private struct State {
        var busy = false
        var dropped: UInt64 = 0
        var lastMs: Double = 0
        var quality: OverlayQuality
    }
    private let state: Locked<State>
    /// Called on `queue` for every offered frame that was not dropped, with the offer time in `CACurrentMediaTime()`
    /// seconds. The frame stays in flight until it returns.
    var onOutcome: ((Outcome, Double) -> Void)?

    init(engine: PersonMaskEngine, quality: OverlayQuality) {
        self.engine = engine
        state = Locked(State(quality: quality))
    }

    func setQuality(_ quality: OverlayQuality) {
        state.withLock { $0.quality = quality }
    }

    var dropped: UInt64 { return state.withLock { $0.dropped } }
    var lastSegmentationMs: Double { return state.withLock { $0.lastMs } }
    var busy: Bool { return state.withLock { $0.busy } }

    /// Capture queue. `hostTimeNs` is the camera's timestamp; the mask is stamped with the offer time instead, the
    /// clock the render path's `now` uses.
    func offer(_ pixelBuffer: CVPixelBuffer, hostTimeNs: UInt64?) {
        let quality = state.withLock { (s: inout State) -> OverlayQuality? in
            if s.busy {
                s.dropped += 1
                return nil
            }
            s.busy = true
            return s.quality
        }
        guard let level = quality else { return }
        let offeredAt = CACurrentMediaTime()
        queue.async { [weak self] in
            guard let self = self else { return }
            let start = CACurrentMediaTime()
            let outcome: Outcome
            do {
                let mask = try self.engine.mask(for: pixelBuffer, quality: level)
                outcome = .mask(mask, coverage: PersonSegmenter.coverage(of: mask))
            } catch {
                outcome = .failed("\(error)")
            }
            let ms = (CACurrentMediaTime() - start) * 1000
            self.state.withLock { $0.lastMs = ms }
            self.onOutcome?(outcome, offeredAt)
            self.state.withLock { $0.busy = false }
        }
    }

    /// Mean of a OneComponent8 mask (0...1), sampling every 4th pixel of every 4th row under a read-only lock, no
    /// copy. Other formats count as full coverage (the matte is then never refused for being empty).
    static func coverage(of mask: CVPixelBuffer) -> Double {
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8 else { return 1 }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return 1 }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let stride = CVPixelBufferGetBytesPerRow(mask)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        var count = 0
        var y = 0
        while y < height {
            let row = bytes + y * stride
            var x = 0
            while x < width {
                sum += Int(row[x])
                count += 1
                x += 4
            }
            y += 4
        }
        return count == 0 ? 0 : Double(sum) / Double(count * 255)
    }
}
