import CoreMedia
import CoreVideo
import DaylightKit
import XCTest
@testable import Daylight

final class LatestFrameSlotTests: XCTestCase {
    func testTakeKeepsTheNewestEntryAndSequenceCounts() {
        let slot = LatestFrameSlot()
        XCTAssertNil(slot.take())
        let a = SelfTest.gradientBuffer(width: 16, height: 16)!
        let b = SelfTest.gradientBuffer(width: 16, height: 16)!
        slot.publish(a, hostTimeNs: 1)
        slot.publish(b, hostTimeNs: 2)
        let entry = slot.take()
        XCTAssertTrue(entry?.buffer === b)
        XCTAssertEqual(entry?.sequence, 2)
        XCTAssertEqual(entry?.hostTimeNs, 2)
        XCTAssertNotNil(slot.take(), "take peeks; the frame stays for the next render tick")
        slot.clear()
        XCTAssertNil(slot.take())
        XCTAssertEqual(slot.sequence, 2)
    }
}

final class OutputPoolTests: XCTestCase {
    func testPoolNeverHandsOutAFourthBuffer() throws {
        let pool = try OutputPool()
        XCTAssertEqual(OutputPool.capacity, 3)
        let a = pool.acquire(), b = pool.acquire(), c = pool.acquire()
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotNil(c)
        XCTAssertEqual(pool.inFlight, 3)
        XCTAssertNil(pool.acquire(), "wait(timeout: .now()) fails instead of blocking")
        pool.release(a!)
        XCTAssertEqual(pool.inFlight, 2)
        XCTAssertNotNil(pool.acquire())
        pool.release(b!)
        pool.release(c!)
        pool.flush()
    }

    func testBuffersAreIOSurfaceBackedBGRA1080p() throws {
        let pool = try OutputPool()
        let pb = pool.acquire()!
        XCTAssertEqual(CVPixelBufferGetWidth(pb), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(pb), 1080)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), kCVPixelFormatType_32BGRA)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(pb))
        let dimensions = CMVideoFormatDescriptionGetDimensions(pool.formatDescription)
        XCTAssertEqual(Int(dimensions.width), 1920)
        XCTAssertEqual(Int(dimensions.height), 1080)
        pool.release(pb)
    }
}

final class FrameClockTests: XCTestCase {
    func testThirtyHertzTicksArriveAndStopStops() {
        let queue = DispatchQueue(label: "clock-test")
        let clock = FrameClock(queue: queue, fps: 30)
        let lock = NSLock()
        var ticks = 0
        var stamps: [Double] = []
        clock.onTick = { now in
            lock.lock()
            ticks += 1
            stamps.append(now)
            lock.unlock()
        }
        queue.sync { clock.start() }
        XCTAssertTrue(queue.sync { clock.isRunning })
        Thread.sleep(forTimeInterval: 1.0)
        queue.sync { clock.stop() }
        lock.lock()
        let counted = ticks
        let monotonic = zip(stamps, stamps.dropFirst()).allSatisfy { $0 < $1 }
        lock.unlock()
        XCTAssertGreaterThanOrEqual(counted, 20, "about 30 ticks in one second")
        XCTAssertLessThanOrEqual(counted, 40)
        XCTAssertTrue(monotonic)
        Thread.sleep(forTimeInterval: 0.1)
        lock.lock()
        let after = ticks
        lock.unlock()
        XCTAssertEqual(after, counted, "no ticks after stop")
        XCTAssertFalse(queue.sync { clock.isRunning })
    }
}

final class FrameFeederTests: XCTestCase {
    func testPTSStrictlyIncreasingAndFormatDescriptionCached() throws {
        let sink = FakeSink()
        let feeder = FrameFeeder(sink: sink)
        let pb = SelfTest.gradientBuffer(width: 1920, height: 1080)!
        var last = CMTime.invalid
        var descriptions = Set<ObjectIdentifier>()
        for _ in 0..<100 {
            let sample = feeder.makeSampleBuffer(pb, hostTimeNs: nil)!
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if last.isValid { XCTAssertGreaterThan(CMTimeCompare(pts, last), 0) }
            last = pts
            descriptions.insert(ObjectIdentifier(CMSampleBufferGetFormatDescription(sample)!))
        }
        XCTAssertEqual(descriptions.count, 1, "one format description across 100 same-size buffers")
        let small = SelfTest.gradientBuffer(width: 1280, height: 720)!
        let sample = feeder.makeSampleBuffer(small, hostTimeNs: nil)!
        XCTAssertFalse(descriptions.contains(ObjectIdentifier(CMSampleBufferGetFormatDescription(sample)!)), "a size change recreates it")
        XCTAssertTrue(feeder.push(pb, hostTimeNs: nil))
        XCTAssertEqual(feeder.pushedFrames, 1)
        sink.acceptPushes = false
        XCTAssertFalse(feeder.push(pb, hostTimeNs: nil))
        XCTAssertEqual(feeder.droppedFrames, 1)
    }

    func testExplicitHostTimeIsUsedAndNeverRegresses() {
        let feeder = FrameFeeder(sink: FakeSink())
        let pb = SelfTest.gradientBuffer(width: 64, height: 64)!
        let a = CMSampleBufferGetPresentationTimeStamp(feeder.makeSampleBuffer(pb, hostTimeNs: 5_000_000_000)!)
        XCTAssertEqual(a.value, 5_000_000_000)
        XCTAssertEqual(a.timescale, 1_000_000_000)
        let b = CMSampleBufferGetPresentationTimeStamp(feeder.makeSampleBuffer(pb, hostTimeNs: 4_000_000_000)!)
        XCTAssertGreaterThan(CMTimeCompare(b, a), 0, "an older stamp is bumped past the last one")
    }
}

final class TelemetryTests: XCTestCase {
    func testPerfLineFormat() {
        var stats = PipelineStats()
        stats.mode = "split"
        stats.fps = 29.97
        stats.dropped = 2
        stats.cpuMsPerFrame = 0.123
        stats.gpuMsPerFrame = 0.456
        stats.inFlight = 1
        stats.passthroughZeroCopy = true
        stats.capturing = false
        stats.viewers = 1
        let line = Telemetry.perfLine(stats)
        XCTAssertEqual(line, "perf mode=split fps=30.0 dropped=2 cpu_ms=0.123 gpu_ms=0.456 inflight=1 zerocopy=true capture=idle viewers=1")
        let telemetry = Telemetry(perfLog: true)
        var captured: [String] = []
        telemetry.sink = { captured.append($0) }
        telemetry.emit(stats)
        XCTAssertEqual(captured, [line])
        XCTAssertEqual(telemetry.recentLines.last, line)
    }

    func testRecentLinesKeepTheLastTwoHundred() {
        let telemetry = Telemetry()
        for i in 0..<250 { telemetry.remember("line \(i)") }
        XCTAssertEqual(telemetry.recentLines.count, 200)
        XCTAssertEqual(telemetry.recentLines.first, "line 50")
    }
}
