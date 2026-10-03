import CoreMedia
import CoreVideo
import DaylightKit
import XCTest
@testable import Daylight

/// SPEC C4: a `CMSimpleQueue` of capacity 1 gives one enqueue and one drop for two pushes; PTS strictly increasing;
/// the format description is cached across 100 buffers and recreated on a size change.
final class SinkFeederTests: XCTestCase {
    func testTwoPushesIntoACapacityOneQueueGiveOneEnqueueAndOneDrop() throws {
        let sink = try QueueSink(capacity: 1)
        XCTAssertEqual(sink.capacity, 1)
        let feeder = SinkFeeder(sink: sink)
        let buffer = try XCTUnwrap(CameraTestBuffers.make(width: 1920, height: 1080))
        XCTAssertTrue(feeder.push(buffer, hostTimeNs: nil))
        XCTAssertFalse(feeder.push(buffer, hostTimeNs: nil), "the second push finds the queue full and drops, never blocks")
        XCTAssertEqual(sink.enqueued, 1)
        XCTAssertEqual(sink.dropped, 1)
        XCTAssertEqual(sink.count, 1)
        XCTAssertEqual(feeder.pushedFrames, 1)
        XCTAssertEqual(feeder.droppedFrames, 1)
        // The consumer drains one element; the next push fits again.
        let consumed = try XCTUnwrap(sink.dequeue())
        XCTAssertTrue(CMSampleBufferGetImageBuffer(consumed) === buffer, "the enqueued sample buffer wraps the pushed pixel buffer, no copy")
        XCTAssertEqual(sink.count, 0)
        XCTAssertTrue(feeder.push(buffer, hostTimeNs: nil))
        XCTAssertEqual(sink.enqueued, 2)
    }

    func testPresentationTimeStampsAreStrictlyIncreasingOver100Buffers() throws {
        let sink = PreviewOnlySink()
        let feeder = SinkFeeder(sink: sink)
        let buffer = try XCTUnwrap(CameraTestBuffers.make(width: 64, height: 36))
        var previous = CMTime.invalid
        for i in 0..<100 {
            // Same host time for every frame: the feeder must still move the PTS forward by one tick.
            let sample = try XCTUnwrap(feeder.makeSampleBuffer(buffer, hostTimeNs: 1_000_000_000))
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            XCTAssertTrue(pts.isValid)
            if previous.isValid {
                XCTAssertEqual(CMTimeCompare(pts, previous), 1, "frame \(i) PTS \(pts.value) must exceed \(previous.value)")
            }
            previous = pts
            XCTAssertEqual(CMSampleBufferGetDuration(sample), SinkFeeder.frameDuration)
        }
        XCTAssertEqual(feeder.lastPresentationTimeStamp, previous)
    }

    func testHostClockPTSWhenNoHostTimeIsGiven() throws {
        let feeder = SinkFeeder(sink: PreviewOnlySink())
        let buffer = try XCTUnwrap(CameraTestBuffers.make(width: 64, height: 36))
        let before = CMClockGetTime(CMClockGetHostTimeClock())
        let sample = try XCTUnwrap(feeder.makeSampleBuffer(buffer, hostTimeNs: nil))
        let after = CMClockGetTime(CMClockGetHostTimeClock())
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        XCTAssertGreaterThanOrEqual(CMTimeCompare(pts, before), 0)
        XCTAssertLessThanOrEqual(CMTimeCompare(pts, after), 0)
        XCTAssertEqual(pts.timescale, 1_000_000_000, "the host clock has a nanosecond timescale")
    }

    func testNextPTSPureRule() {
        let first = SinkFeeder.nextPTS(after: .invalid, hostTimeNs: 5_000)
        XCTAssertEqual(first.value, 5_000)
        XCTAssertEqual(first.timescale, 1_000_000_000)
        let same = SinkFeeder.nextPTS(after: first, hostTimeNs: 5_000)
        XCTAssertEqual(same.value, 5_001, "an equal stamp is bumped by one tick")
        let earlier = SinkFeeder.nextPTS(after: same, hostTimeNs: 10)
        XCTAssertEqual(earlier.value, 5_002, "a stamp from the past is bumped too")
        let later = SinkFeeder.nextPTS(after: earlier, hostTimeNs: 9_000)
        XCTAssertEqual(later.value, 9_000)
    }

    func testFormatDescriptionIsCachedAcross100BuffersAndRecreatedOnASizeChange() throws {
        let feeder = SinkFeeder(sink: PreviewOnlySink())
        let small = try XCTUnwrap(CameraTestBuffers.make(width: 64, height: 36))
        var first: CMVideoFormatDescription?
        for _ in 0..<100 {
            let sample = try XCTUnwrap(feeder.makeSampleBuffer(small, hostTimeNs: nil))
            let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            if first == nil { first = description }
            XCTAssertTrue(description === first!, "one format description serves every same-size buffer")
        }
        XCTAssertEqual(feeder.formatDescriptionsCreated, 1)
        let dimensions = CMVideoFormatDescriptionGetDimensions(try XCTUnwrap(first))
        XCTAssertEqual(dimensions.width, 64)
        XCTAssertEqual(dimensions.height, 36)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(first)), kCVPixelFormatType_32BGRA)

        let large = try XCTUnwrap(CameraTestBuffers.make(width: 128, height: 72))
        let changed = try XCTUnwrap(feeder.makeSampleBuffer(large, hostTimeNs: nil))
        let second = try XCTUnwrap(CMSampleBufferGetFormatDescription(changed))
        XCTAssertFalse(second === first!, "a size change makes a new description")
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(second).width, 128)
        XCTAssertEqual(feeder.formatDescriptionsCreated, 2)
        // Back to the first size: created again (one cached description, by design), still correct.
        _ = try XCTUnwrap(feeder.makeSampleBuffer(small, hostTimeNs: nil))
        XCTAssertEqual(feeder.formatDescriptionsCreated, 3)
    }

    func testFullHDBufferProducesAReadySampleBufferWithTheRightDescription() throws {
        let feeder = SinkFeeder(sink: PreviewOnlySink())
        let buffer = try XCTUnwrap(CameraTestBuffers.make(width: 1920, height: 1080))
        let sample = try XCTUnwrap(feeder.makeSampleBuffer(buffer, hostTimeNs: nil))
        XCTAssertTrue(CMSampleBufferDataIsReady(sample))
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
        let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(description).width, 1920)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(description).height, 1080)
    }
}
