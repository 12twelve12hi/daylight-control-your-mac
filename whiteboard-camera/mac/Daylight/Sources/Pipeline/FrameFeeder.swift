import CoreMedia
import CoreVideo
import DaylightKit
import Foundation

/// Wraps a pixel buffer in a host-clock `CMSampleBuffer` and hands it to the `VirtualCameraSink` contract
/// (research-mac-pipeline section 6). One cached format description per (width, height, pixel format); PTS strictly
/// increasing. Never blocks: the sink's `push` returns false when it drops.
///
/// B-internal (component C ships its own `SinkFeeder` with the same job behind the same contract; the pipeline
/// talks to the sink only through `VirtualCameraSink.push`).
final class FrameFeeder {
    let sink: VirtualCameraSink
    private var formatDescription: CMVideoFormatDescription?
    private var formatKey: (Int, Int, OSType) = (0, 0, 0)
    private var lastPTS = CMTime.invalid
    private let counters = Locked<(pushed: UInt64, dropped: UInt64)>((0, 0))
    private let lock = NSLock()

    init(sink: VirtualCameraSink) {
        self.sink = sink
    }

    var pushedFrames: UInt64 { return counters.withLock { $0.pushed } }
    var droppedFrames: UInt64 { return counters.withLock { $0.dropped } }

    /// Builds the sample buffer and pushes it. Callable from the capture queue and the Metal completion thread.
    @discardableResult
    func push(_ pixelBuffer: CVPixelBuffer, hostTimeNs: UInt64?) -> Bool {
        guard let sample = makeSampleBuffer(pixelBuffer, hostTimeNs: hostTimeNs) else {
            counters.withLock { $0.dropped += 1 }
            return false
        }
        let ok = sink.push(sample)
        counters.withLock { if ok { $0.pushed += 1 } else { $0.dropped += 1 } }
        return ok
    }

    func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, hostTimeNs: UInt64?) -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let key = (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), CVPixelBufferGetPixelFormatType(pixelBuffer))
        if formatDescription == nil || key != formatKey {
            var created: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &created)
            guard status == noErr, let fd = created else { return nil }
            formatDescription = fd
            formatKey = key
        }
        guard let description = formatDescription else { return nil }
        var pts: CMTime
        if let ns = hostTimeNs {
            pts = CMTime(value: CMTimeValue(ns), timescale: 1_000_000_000)
        } else {
            pts = CMClockGetTime(CMClockGetHostTimeClock())
        }
        if lastPTS.isValid && CMTimeCompare(pts, lastPTS) <= 0 {
            pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: lastPTS.timescale))
        }
        lastPTS = pts
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sample)
        guard status == noErr else { return nil }
        return sample
    }
}
