import DaylightKit
import Metal
import XCTest
@testable import Daylight

/// ARCHITECTURE 11.2 PipelineSmokeTests: FakeCapture at 30 Hz into a FakeSink through the real FramePipeline.
final class PipelineSmokeTests: XCTestCase {
    private func makePipeline(sink: FakeSink, capture: FakeCapture, settings: Settings = Settings.defaults) throws -> FramePipeline {
        let telemetry = Telemetry(perfLog: false)
        return try FramePipeline(sink: sink, settings: settings, telemetry: telemetry, device: MTLCreateSystemDefaultDevice(), capture: capture)
    }

    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    func testPassthroughForwardsCameraFramesZeroCopy() throws {
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        pipeline.start()
        XCTAssertTrue(waitUntil(2) { capture.isRunning }, "capture starts because the sink is not connected (D32)")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertGreaterThanOrEqual(sink.pushCount, 25, "about 30 pushes in one second of passthrough")
        XCTAssertTrue(sink.lastPixelBuffer === capture.buffer, "zero copy: the camera's own buffer reaches the sink")
        let stats = pipeline.stats
        XCTAssertTrue(stats.passthroughZeroCopy)
        XCTAssertEqual(stats.mode, "passthrough")
        XCTAssertTrue(stats.capturing)
        XCTAssertEqual(stats.dropped, 0)
        XCTAssertNotNil(stats.firstFrame)
        XCTAssertTrue(stats.firstFrame?.contains("1920x1080 BGRA iosurface=true") ?? false)
        pipeline.shutdown()
    }

    func testEngageReachesLiveAndComposedFramesFlow() throws {
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        var reports: [StateReport] = []
        let lock = NSLock()
        pipeline.onStateForClients = { report in
            lock.lock()
            reports.append(report)
            lock.unlock()
        }
        pipeline.start()
        XCTAssertTrue(waitUntil(2) { sink.pushCount > 5 })
        sink.resetRecording()
        pipeline.post(.engage)
        XCTAssertTrue(waitUntil(1.0) { pipeline.governorSnapshot.state == .live }, "ENGAGING settles to LIVE within about 0.25 s")
        XCTAssertTrue(pipeline.clock.isRunning)
        if pipeline.compositor != nil {
            XCTAssertTrue(waitUntil(1.0) { sink.pushCount >= 8 }, "composed frames flow at 30 Hz")
            XCTAssertFalse(sink.lastPixelBuffer === capture.buffer, "composed frames come from the pool, not the camera")
            XCTAssertLessThanOrEqual(pipeline.pool?.inFlight ?? 0, 3)
            // A prompt fake sink never causes back-pressure drops. The shared runner's GPU may take longer than
            // three ticks for its very first command buffers, which the pool answers with a skipped tick by design
            // (LOOSE_ENDS B19 d), so the first second tolerates a couple of skips and the steady state tolerates none.
            let coldDrops = pipeline.stats.dropped
            XCTAssertLessThanOrEqual(coldDrops, 2, "at most a couple of ticks skipped while the GPU warms up")
            let before = sink.pushCount
            XCTAssertTrue(waitUntil(1.0) { sink.pushCount >= before + 8 }, "frames keep flowing")
            XCTAssertEqual(pipeline.stats.dropped, coldDrops, "no drops once the GPU is warm")
        } else {
            print("PipelineSmokeTests: no Metal device; composed frame assertions skipped")
        }
        lock.lock()
        let governors = reports.map { $0.governor }
        lock.unlock()
        XCTAssertTrue(governors.contains(GovernorState.engaging.rawValue), "STATE on the change to ENGAGING")
        XCTAssertTrue(governors.contains(GovernorState.live.rawValue), "STATE on the change to LIVE")
        pipeline.post(.returnNow)
        XCTAssertTrue(waitUntil(1.0) { pipeline.governorSnapshot.state == .passthrough })
        XCTAssertTrue(waitUntil(0.5) { !pipeline.clock.isRunning }, "the clock stops in PASSTHROUGH")
        pipeline.shutdown()
    }

    func testGovernorConfigChangeWaitsWhileTheBoardIsUp() throws {
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        pipeline.start()
        XCTAssertTrue(waitUntil(2) { sink.pushCount > 3 })
        var inPassthrough = Settings.defaults
        inPassthrough.idleTimeoutSeconds = 60
        pipeline.updateSettings(inPassthrough)
        XCTAssertEqual(pipeline.governorConfig.idleTimeout, 60, "in PASSTHROUGH the new config applies at once")
        XCTAssertEqual(pipeline.governorSnapshot.state, .passthrough)
        pipeline.post(.engage)
        XCTAssertTrue(waitUntil(1.0) { pipeline.governorSnapshot.state == .live })
        var midCall = inPassthrough
        midCall.idleTimeoutSeconds = 30
        pipeline.updateSettings(midCall)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(pipeline.governorSnapshot.state, .live, "Settings > General mid-call never drops the board")
        XCTAssertEqual(pipeline.governorConfig.idleTimeout, 60, "the running config stays until the return")
        XCTAssertTrue(pipeline.clock.isRunning)
        if pipeline.compositor != nil {
            sink.resetRecording()
            XCTAssertTrue(waitUntil(1.0) { sink.pushCount >= 3 }, "composed frames keep flowing")
        }
        pipeline.post(.returnNow)
        XCTAssertTrue(waitUntil(1.0) { pipeline.governorSnapshot.state == .passthrough })
        XCTAssertTrue(waitUntil(1.0) { pipeline.governorConfig.idleTimeout == 30 }, "the pending config applies on the return to PASSTHROUGH")
        pipeline.shutdown()
    }

    func testCaptureWaitsForCameraAuthorization() throws {
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        pipeline.setCaptureAuthorized(false)
        pipeline.start()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(capture.isRunning, "row 3: nothing opens the camera before access is granted")
        XCTAssertFalse(pipeline.stats.capturing)
        XCTAssertGreaterThanOrEqual(sink.pushCount, 1, "the sink gets the cream card, never the extension placeholder")
        XCTAssertFalse(sink.lastPixelBuffer === capture.buffer)
        pipeline.setCaptureAuthorized(true)
        XCTAssertTrue(waitUntil(1.0) { capture.isRunning }, "granting access opens the gate without a relaunch")
        pipeline.shutdown()
    }

    func testStateCadenceConstantsMatchSpecD47() {
        XCTAssertEqual(FramePipeline.stateIntervalAnimating, 0.1, accuracy: 1e-12, "10 Hz while ENGAGING, RETURNING or pre-warning")
        XCTAssertEqual(FramePipeline.stateIntervalLive, 1.0, accuracy: 1e-12, "1 Hz while LIVE")
        XCTAssertEqual(FramePipeline.outputWidth, 1920)
        XCTAssertEqual(FramePipeline.outputHeight, 1080)
        XCTAssertEqual(Settings.defaults.viewerIdleStopSeconds, 60, "D32 hysteresis")
    }

    func testIdleRuleStopsCaptureAndRestartPushesTheCachedFrameFirst() throws {
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        pipeline.idleStopOverrideSeconds = 0.4
        sink.setStatus(.connected)
        pipeline.setSinkConnected(true)
        pipeline.start()
        // viewers = 0, preview hidden, sink connected: nobody wants capture; it was never started.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(capture.isRunning)
        pipeline.setViewerCount(1)
        XCTAssertTrue(waitUntil(1.0) { capture.isRunning }, "capture restarts within 1 s of a viewer appearing")
        XCTAssertTrue(waitUntil(1.0) { sink.pushCount > 3 })
        pipeline.setViewerCount(0)
        XCTAssertTrue(waitUntil(2.0) { !capture.isRunning }, "capture stops after the (shortened) hysteresis")
        XCTAssertEqual(pipeline.stats.captureIdleReason, "viewers=0 preview=hidden")
        XCTAssertFalse(pipeline.stats.capturing)
        sink.resetRecording()
        pipeline.setViewerCount(2)
        XCTAssertTrue(waitUntil(1.0) { sink.pushCount >= 1 })
        XCTAssertTrue(sink.firstPixelBuffer === capture.buffer, "the first frame after restart is the cached camera frame")
        XCTAssertTrue(waitUntil(1.0) { capture.isRunning })
        XCTAssertNil(pipeline.stats.captureIdleReason)
        pipeline.shutdown()
    }

    func testPreviewVisibilityCountsAsAViewer() throws {
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        pipeline.idleStopOverrideSeconds = 0.3
        pipeline.setSinkConnected(true)
        pipeline.start()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(capture.isRunning)
        pipeline.setPreviewVisible(true)
        XCTAssertTrue(waitUntil(1.0) { capture.isRunning })
        pipeline.setPreviewVisible(false)
        XCTAssertTrue(waitUntil(2.0) { !capture.isRunning })
        pipeline.shutdown()
    }

    func testStateReportCarriesTheGlobalFlags() throws {
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        pipeline.setSinkConnected(true)
        pipeline.setSaving(true)
        XCTAssertTrue(waitUntil(0.5) { pipeline.globalStateFlags.contains(.sinkConnected) })
        let report = pipeline.stateReport(pipeline.governorSnapshot)
        XCTAssertEqual(report.governor, 0)
        XCTAssertTrue(report.flagSet.contains(.sinkConnected))
        XCTAssertTrue(report.flagSet.contains(.saving))
        XCTAssertFalse(report.flagSet.contains(.clientAllowed))
        XCTAssertEqual(report.msToReturn, StateReport.noReturnScheduled)
        pipeline.setInkSource(.native)
        XCTAssertEqual(pipeline.inkSource, .native)
        XCTAssertEqual(pipeline.stateReport(pipeline.governorSnapshot).inkSource, InkSource.native.rawValue)
        pipeline.shutdown()
    }

    func testMirrorSourceIsComposedWhenSelected() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        let mirror = FakeMirrorSource()
        pipeline.setMirrorSource(mirror)
        pipeline.setInkSource(.mirror)
        pipeline.start()
        XCTAssertTrue(waitUntil(2) { sink.pushCount > 3 })
        pipeline.post(.penContact(down: true))
        XCTAssertTrue(waitUntil(1.0) { pipeline.governorSnapshot.state != .passthrough })
        sink.resetRecording()
        XCTAssertTrue(waitUntil(1.0) { sink.pushCount >= 3 })
        let frame = sink.lastPixelBuffer!
        XCTAssertFalse(frame === capture.buffer)
        // Composed frame: presenter on the right, mirror picture in the slot (not cream).
        XCTAssertFalse(SelfTest.matches(SelfTest.pixel(frame, 640, 540), Tokens.surfaceCream))
        pipeline.post(.penContact(down: false))
        pipeline.shutdown()
    }

    func testThreeHundredTicksMeasured() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device; nothing is composed in hold mode") }
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        pipeline.start()
        pipeline.post(.hold(.split))
        XCTAssertTrue(waitUntil(1.0) { pipeline.governorSnapshot.state == .live })
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            let before = sink.pushCount
            _ = waitUntil(15) { sink.pushCount - before >= 300 }
        }
        print("PipelineSmokeTests: 300 frames, stats \(Telemetry.perfLine(pipeline.stats))")
        XCTAssertLessThanOrEqual(pipeline.pool?.inFlight ?? 0, 3)
        pipeline.post(.hold(.auto))
        pipeline.shutdown()
    }
}
