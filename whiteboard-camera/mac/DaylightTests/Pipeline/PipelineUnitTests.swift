import CoreMedia
import CoreVideo
import DaylightKit
import QuartzCore
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
        XCTAssertNil(pool.acquire(), "the fourth acquire fails instead of blocking")
        pool.release(a!)
        XCTAssertEqual(pool.inFlight, 2)
        let d = pool.acquire()
        XCTAssertNotNil(d, "a released slot is handed out again")
        XCTAssertEqual(pool.inFlight, 3)
        XCTAssertNil(pool.acquire(), "still three in flight")
        pool.release(b!)
        pool.release(c!)
        pool.release(d!)
        XCTAssertEqual(pool.inFlight, 0)
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
    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

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
        // Bounds against the measured window, not a fixed sleep: a test thread that wakes late must not read as a
        // clock running fast, and a strict timer coalesces missed fires, so it can never over-fire.
        let t0 = CACurrentMediaTime()
        queue.sync { clock.start() }
        XCTAssertTrue(queue.sync { clock.isRunning })
        XCTAssertTrue(waitUntil(5) {
            lock.lock()
            defer { lock.unlock() }
            return ticks >= 20
        }, "ticks arrive")
        queue.sync { clock.stop() }
        let elapsed = CACurrentMediaTime() - t0
        lock.lock()
        let counted = ticks
        let monotonic = zip(stamps, stamps.dropFirst()).allSatisfy { $0 < $1 }
        let intervals = zip(stamps, stamps.dropFirst()).map { $1 - $0 }.sorted()
        lock.unlock()
        XCTAssertGreaterThanOrEqual(counted, 20)
        XCTAssertGreaterThanOrEqual(counted, Int(elapsed * 30) - 10, "about 30 ticks per measured second")
        XCTAssertLessThanOrEqual(counted, Int((elapsed * 30).rounded(.up)) + 1, "never more ticks than 30 Hz allows in the measured window")
        if intervals.isEmpty {
            XCTFail("no tick intervals")
        } else {
            let median = intervals[intervals.count / 2]
            XCTAssertTrue((0.030...0.037).contains(median), "the median tick interval is 33 ms (was \(median))")
        }
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

/// SPEC 11 `cameraUniqueID` and the own-camera exclusion, on facts instead of real devices.
final class WebcamChoiceTests: XCTestCase {
    private typealias Facts = WebcamCapture.DeviceFacts

    func testOwnCameraIsNeverChosenAndTheFallbacksFollowSpec11() {
        WebcamCapture.excludeOwnCamera(uniqueID: "ab51c6ba-17fd-4a67-be3a-06a8540ba6aa")
        let own = Facts(uniqueID: "AB51C6BA-17FD-4A67-BE3A-06A8540BA6AA", name: "Daylight Camera", isConnected: true)
        let builtIn = Facts(uniqueID: "builtin", name: "FaceTime HD Camera", isConnected: true)
        let external = Facts(uniqueID: "usb-1", name: "Logitech BRIO", isConnected: true)
        let gone = Facts(uniqueID: "usb-2", name: "Old webcam", isConnected: false)
        XCTAssertTrue(WebcamCapture.isOwnCamera(uniqueID: own.uniqueID, name: "anything"), "the fixed device UUID, case-insensitive")
        XCTAssertTrue(WebcamCapture.isOwnCamera(uniqueID: "other", name: "Daylight Camera"))
        XCTAssertFalse(WebcamCapture.isOwnCamera(uniqueID: "builtin", name: "FaceTime HD Camera"))
        // The owner's explicit choice wins while it is present.
        XCTAssertEqual(WebcamCapture.choose(preferredUniqueID: "usb-1", systemPreferredID: "builtin", from: [own, builtIn, external]), external)
        // An unplugged choice: the system's preferred camera, then the first connected one (never a stale object).
        XCTAssertEqual(WebcamCapture.choose(preferredUniqueID: "usb-2", systemPreferredID: "builtin", from: [own, gone, external, builtIn]), builtIn)
        XCTAssertEqual(WebcamCapture.choose(preferredUniqueID: "usb-2", systemPreferredID: nil, from: [own, gone, external, builtIn]), external)
        // FaceTime made Daylight Camera the system preference: Daylight must not capture itself.
        XCTAssertEqual(WebcamCapture.choose(preferredUniqueID: nil, systemPreferredID: own.uniqueID, from: [own, builtIn]), builtIn)
        XCTAssertNil(WebcamCapture.choose(preferredUniqueID: nil, systemPreferredID: nil, from: [own, gone]))
    }

    /// PIPA-02 / PIPB-01: losing the camera in use re-runs the rule without it, so a present camera takes over.
    func testLostCameraFallsBackToAnotherPresentCamera() {
        WebcamCapture.excludeOwnCamera(uniqueID: "ab51c6ba-17fd-4a67-be3a-06a8540ba6aa")
        let own = Facts(uniqueID: "AB51C6BA-17FD-4A67-BE3A-06A8540BA6AA", name: "Daylight Camera", isConnected: true)
        let builtIn = Facts(uniqueID: "builtin", name: "FaceTime HD Camera", isConnected: true)
        // The unplugged webcam may still read as connected while its disconnect notification is delivered.
        let lostStillListed = Facts(uniqueID: "usb-1", name: "Logitech BRIO", isConnected: true)
        let lostGone = Facts(uniqueID: "usb-1", name: "Logitech BRIO", isConnected: false)
        // The owner's explicit choice and the system's preference both name the lost webcam: the built-in takes over.
        XCTAssertEqual(WebcamCapture.replacement(afterLosing: "usb-1", preferredUniqueID: "usb-1", systemPreferredID: "usb-1", from: [lostStillListed, own, builtIn]), builtIn)
        XCTAssertEqual(WebcamCapture.replacement(afterLosing: "usb-1", preferredUniqueID: nil, systemPreferredID: nil, from: [lostGone, builtIn]), builtIn)
        // Nothing else present: no replacement, the cream card stays (row 4).
        XCTAssertNil(WebcamCapture.replacement(afterLosing: "usb-1", preferredUniqueID: "usb-1", systemPreferredID: nil, from: [lostStillListed]))
        // Daylight's own camera is never the fallback.
        XCTAssertNil(WebcamCapture.replacement(afterLosing: "usb-1", preferredUniqueID: nil, systemPreferredID: own.uniqueID, from: [lostStillListed, own]))
    }
}

/// PIPB-04: WebcamCapture changes its session, `running` and `input` on one serial queue only. A device notification
/// queues its work there; `stop()` from the render queue waits behind it instead of racing it.
final class WebcamCaptureQueueTests: XCTestCase {
    func testStopRunsOnTheSessionQueue() {
        let capture = WebcamCapture(queue: DispatchQueue(label: "webcam-test.capture"))
        let gate = DispatchSemaphore(value: 0)
        let blocked = DispatchSemaphore(value: 0)
        capture.sessionQueue.async {
            blocked.signal()
            gate.wait()
        }
        XCTAssertEqual(blocked.wait(timeout: .now() + 10), .success, "the session queue is held")
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            capture.stop()
            stopped.signal()
        }
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.3), .timedOut, "stop() waits for the work already queued on the session queue")
        gate.signal()
        XCTAssertEqual(stopped.wait(timeout: .now() + 10), .success, "and then runs")
        XCTAssertFalse(capture.isRunning)
        XCTAssertFalse(capture.hasDevice)
    }
}

/// PIPB-05: the app assigns every pipeline callback before the first render-queue block that reads one is queued
/// (`setCaptureAuthorized`, then `setCaptureSource`, in that required order). Pinned on the source of `wirePipeline`.
final class PipelineWiringOrderTests: XCTestCase {
    func testCallbacksAreAssignedBeforeTheFirstRenderQueueWork() throws {
        let mac = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = mac.appendingPathComponent("Daylight/Sources/App/AppDelegate.swift")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw XCTSkip("AppDelegate.swift not reachable from the test host at \(file.path)")
        }
        let start = try XCTUnwrap(text.range(of: "private func wirePipeline()"))
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        let body = String(rest[..<end])
        let authorize = try XCTUnwrap(body.range(of: "pipeline.setCaptureAuthorized("), "wirePipeline sets row 3")
        let source = try XCTUnwrap(body.range(of: "pipeline.setCaptureSource("), "wirePipeline sets the capture source")
        XCTAssertTrue(authorize.lowerBound < source.lowerBound, "row 3 is set before the capture source")
        for callback in ["onStateForClients", "onSavePage", "onClearCanvas", "onPreviewFrame", "onFailure", "onCameraPresence", "onStateChanged"] {
            let assignment = try XCTUnwrap(body.range(of: "pipeline.\(callback) = "), "wirePipeline assigns \(callback)")
            XCTAssertTrue(assignment.lowerBound < authorize.lowerBound, "\(callback) is assigned before setCaptureAuthorized queues render work")
        }
    }
}

/// research-mac-pipeline 1.9: the preview never holds more than one captured buffer, however long main stalls.
final class LatestSampleCoalescerTests: XCTestCase {
    func testOnlyTheNewestSampleReachesAStalledQueueOnce() {
        let target = DispatchQueue(label: "coalescer-test.target")
        let coalescer = LatestSampleCoalescer(queue: target)
        let feeder = FrameFeeder(sink: FakeSink())
        let pb = SelfTest.gradientBuffer(width: 64, height: 64)!
        let delivered = Locked<[CMTime]>([])
        target.suspend()
        var lastOffered = CMTime.invalid
        for _ in 0..<50 {
            let sample = feeder.makeSampleBuffer(pb, hostTimeNs: nil)!
            lastOffered = CMSampleBufferGetPresentationTimeStamp(sample)
            coalescer.offer(sample) { s in delivered.withLock { $0.append(CMSampleBufferGetPresentationTimeStamp(s)) } }
        }
        target.resume()
        target.sync {}
        XCTAssertEqual(delivered.withLock { $0 }, [lastOffered], "one delivery, the newest sample")
        // Once drained, the next frame is dispatched again.
        let next = feeder.makeSampleBuffer(pb, hostTimeNs: nil)!
        coalescer.offer(next) { s in delivered.withLock { $0.append(CMSampleBufferGetPresentationTimeStamp(s)) } }
        target.sync {}
        XCTAssertEqual(delivered.withLock { $0.count }, 2)
        XCTAssertEqual(delivered.withLock { $0.last }, CMSampleBufferGetPresentationTimeStamp(next))
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
