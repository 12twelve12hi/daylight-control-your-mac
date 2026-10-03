import CoreMedia
import CoreVideo
import DaylightKit
import Foundation

/// Wraps a pixel buffer in a host-clock `CMSampleBuffer` and pushes it through the `VirtualCameraSink` contract
/// (research-mac-pipeline section 6, ARCHITECTURE 2.3). One cached format description per (width, height, pixel
/// format); presentation time stamps strictly increasing; never blocks (the sink's `push` says false when it drops).
/// Callable from the capture queue and the Metal completion thread at once.
final class SinkFeeder {
    static let frameDuration = CMTime(value: 1, timescale: 30)

    let sink: VirtualCameraSink
    private let lock = NSLock()
    private var formatDescription: CMVideoFormatDescription?
    private var formatKey: (Int, Int, OSType) = (0, 0, 0)
    private var lastPTS = CMTime.invalid
    private var created: UInt64 = 0
    private let counters = Locked<(pushed: UInt64, dropped: UInt64)>((0, 0))

    init(sink: VirtualCameraSink) {
        self.sink = sink
    }

    var pushedFrames: UInt64 { return counters.withLock { $0.pushed } }
    var droppedFrames: UInt64 { return counters.withLock { $0.dropped } }

    /// How many format descriptions were created so far (one per distinct (w, h, fmt) run).
    var formatDescriptionsCreated: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return created
    }

    var currentFormatDescription: CMVideoFormatDescription? {
        lock.lock()
        defer { lock.unlock() }
        return formatDescription
    }

    /// The last presentation time stamp handed out (invalid before the first push).
    var lastPresentationTimeStamp: CMTime {
        lock.lock()
        defer { lock.unlock() }
        return lastPTS
    }

    /// Builds the sample buffer and pushes it. `hostTimeNs` nil stamps with the host clock now.
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

    /// The sample buffer alone (tests and the preview path).
    func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, hostTimeNs: UInt64?) -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let key = (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), CVPixelBufferGetPixelFormatType(pixelBuffer))
        if formatDescription == nil || key != formatKey {
            var fresh: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fresh)
            guard status == noErr, let description = fresh else { return nil }
            formatDescription = description
            formatKey = key
            created += 1
        }
        guard let description = formatDescription else { return nil }
        let pts = SinkFeeder.nextPTS(after: lastPTS, hostTimeNs: hostTimeNs)
        lastPTS = pts
        var timing = CMSampleTimingInfo(duration: SinkFeeder.frameDuration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
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

    /// Host-clock PTS in nanoseconds, bumped by one tick when it would not exceed the previous one.
    static func nextPTS(after previous: CMTime, hostTimeNs: UInt64?) -> CMTime {
        var pts: CMTime
        if let ns = hostTimeNs {
            pts = CMTime(value: CMTimeValue(ns), timescale: 1_000_000_000)
        } else {
            pts = CMClockGetTime(CMClockGetHostTimeClock())
        }
        if previous.isValid && CMTimeCompare(pts, previous) <= 0 {
            pts = CMTimeAdd(previous, CMTime(value: 1, timescale: previous.timescale))
        }
        return pts
    }
}
