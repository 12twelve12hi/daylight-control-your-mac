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
        // Count frames, not wall-clock time: a stalled fake capture queue delivers fewer frames, never fewer pushes
        // per frame. After the drain every delivered frame has been pushed (synchronously on the capture queue).
        XCTAssertTrue(waitUntil(5) { capture.frames >= 30 }, "about one second of camera frames")
        capture.stop()
        capture.queue.sync {}
        pipeline.renderQueue.sync {}
        XCTAssertEqual(sink.pushCount, capture.frames + 1, "every camera frame is forwarded, plus the one cream card the start pushed from the empty slot")
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
            XCTAssertTrue(waitUntil(5) { sink.pushCount >= before + 8 }, "frames keep flowing")
            XCTAssertLessThanOrEqual(pipeline.pool?.inFlight ?? 0, 3)
            XCTAssertEqual(pipeline.feeder.droppedFrames, 0, "the prompt fake sink never refuses a frame (no back-pressure drops at all)")
            XCTAssertEqual(pipeline.stats.dropped, coldDrops, "no drops once the GPU is warm (LOOSE_ENDS B24 (2))")
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

    func testSettingsPreferredLayoutDrivesEngage() throws {
        // Settings "Layout when engaging" (SPEC 5, SPEC 11 `preferredLayout`): read at launch, and a change goes through
        // the same config path as the other governor settings (at once in PASSTHROUGH, on the next return otherwise).
        let sink = FakeSink()
        let capture = FakeCapture()
        var whiteboard = Settings.defaults
        whiteboard.preferredLayout = .whiteboardOnly
        let pipeline = try makePipeline(sink: sink, capture: capture, settings: whiteboard)
        pipeline.start()
        XCTAssertEqual(pipeline.governorSnapshot.layout, .whiteboardOnly, "the launch config carries the layout")
        pipeline.post(.engage)
        XCTAssertTrue(waitUntil(10) { pipeline.governorSnapshot.state == .live })
        XCTAssertEqual(pipeline.governorSnapshot.layout, .whiteboardOnly)
        pipeline.updateSettings(Settings.defaults)
        XCTAssertEqual(pipeline.governorSnapshot.layout, .whiteboardOnly, "mid-call the layout change waits for the return")
        pipeline.post(.returnNow)
        XCTAssertTrue(waitUntil(10) { pipeline.governorConfig.preferredLayout == .studioSplit }, "the pending config applies on the return")
        XCTAssertEqual(pipeline.governorSnapshot.layout, .studioSplit)
        pipeline.updateSettings(whiteboard)
        XCTAssertEqual(pipeline.governorConfig.preferredLayout, .whiteboardOnly, "in PASSTHROUGH the change applies at once")
        pipeline.post(.engage)
        XCTAssertTrue(waitUntil(10) { pipeline.governorSnapshot.state == .live })
        XCTAssertEqual(pipeline.governorSnapshot.layout, .whiteboardOnly)
        pipeline.shutdown()
    }

    func testCaptureWaitsForCameraAuthorization() throws {
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        pipeline.setCaptureAuthorized(false)
        pipeline.start()
        // Wait for the card itself, not a fixed 0.3 s: the card is built and pushed on the render queue, which the
        // shared runner can hold up for longer than that (runs 37134646725 and 37136061242 asserted while the queue was
        // still building it). Then a window in which nothing may open the camera, then a drain of the render queue,
        // where every capture decision runs, so nothing queued by start() can still open it after the assertions.
        XCTAssertTrue(waitUntil(10) { sink.pushCount >= 1 }, "the sink gets the cream card, never the extension placeholder")
        Thread.sleep(forTimeInterval: 0.3)
        pipeline.renderQueue.sync {}
        XCTAssertFalse(capture.isRunning, "row 3: nothing opens the camera before access is granted")
        XCTAssertEqual(capture.startCount, 0, "the capture source was never started")
        XCTAssertFalse(pipeline.stats.capturing)
        let card = try XCTUnwrap(sink.lastPixelBuffer)
        XCTAssertFalse(card === capture.buffer)
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(card, 100, 100), Tokens.surfaceCream), "the cream card")
        pipeline.setCaptureAuthorized(true)
        XCTAssertTrue(waitUntil(10) { capture.isRunning }, "granting access opens the gate without a relaunch")
        pipeline.shutdown()
    }

    func testFormatChangeMidRunLeavesZeroCopyAndComposesTheFallback() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        var failures: [FailureText.Case] = []
        let lock = NSLock()
        pipeline.onFailure = { failure, _ in
            lock.lock()
            failures.append(failure)
            lock.unlock()
        }
        pipeline.start()
        XCTAssertTrue(waitUntil(2) { sink.pushCount > 5 })
        XCTAssertTrue(pipeline.stats.passthroughZeroCopy)
        capture.switchFormat(width: 1280, height: 720)
        XCTAssertTrue(waitUntil(2) { pipeline.stats.firstFrame?.contains("1280x720") ?? false }, "Diagnostics follows the current camera")
        XCTAssertFalse(pipeline.stats.passthroughZeroCopy, "eligibility is re-decided per frame, not once at launch")
        sink.resetRecording()
        XCTAssertTrue(waitUntil(2) { sink.pushCount >= 3 })
        let frame = sink.lastPixelBuffer!
        XCTAssertFalse(frame === capture.currentBuffer, "the 720p buffer never reaches the 1080p sink directly")
        XCTAssertEqual(CVPixelBufferGetWidth(frame), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(frame), 1080)
        lock.lock()
        let seen = failures
        lock.unlock()
        XCTAssertTrue(seen.contains(.webcamFormatComposed), "row 5 is reported for the new format")
        // SPEC 16 B3 "logs exactly once otherwise": several 720p frames went out composed, one report.
        XCTAssertEqual(seen.filter { $0 == .webcamFormatComposed }.count, 1, "row 5 is reported once per format, not per frame")
        pipeline.shutdown()
    }

    func testLostCameraInPassthroughPushesTheCreamCard() throws {
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        pipeline.start()
        XCTAssertTrue(waitUntil(2) { sink.pushCount > 3 })
        capture.stop()   // an unplugged webcam delivers nothing more
        capture.queue.sync {}   // a frame handler already running finishes (and pushes) before the reset
        pipeline.renderQueue.sync {}
        sink.resetRecording()
        capture.simulateLost()
        XCTAssertTrue(waitUntil(5) { sink.pushCount >= 1 }, "viewers get one more frame instead of a frozen face")
        pipeline.renderQueue.sync {}
        XCTAssertEqual(sink.pushCount, 1, "exactly the card after the loss")
        let frame = sink.lastPixelBuffer!
        XCTAssertFalse(frame === capture.buffer)
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(frame, 100, 100), Tokens.surfaceCream), "the cream card")
        XCTAssertFalse(pipeline.stats.cameraAttached)
        pipeline.shutdown()
    }

    /// PIPA-05: a 720p camera's passthrough frames are composed on the GPU. A frame that arrived just before the loss
    /// must not complete after the card and freeze the face again. The render queue is held so the frame's render
    /// block and the card block are both queued before either runs (the order the race needs, made certain).
    func testLostCameraDuringComposedPassthroughEndsOnTheCard() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device; nothing is composed") }
        let sink = FakeSink()
        let capture = FakeCapture(width: 1280, height: 720)
        let pipeline = try makePipeline(sink: sink, capture: capture)
        pipeline.start()
        XCTAssertTrue(waitUntil(10) { sink.pushCount > 3 }, "composed passthrough frames flow")
        capture.stop()
        capture.queue.sync {}
        pipeline.renderQueue.sync {}
        XCTAssertTrue(waitUntil(10) { pipeline.pool?.inFlight == 0 }, "every earlier GPU pass completed")
        sink.resetRecording()
        let gate = DispatchSemaphore(value: 0)
        pipeline.renderQueue.async { gate.wait() }
        capture.queue.sync { capture.deliverFrame() }   // queues its GPU pass behind the gate
        capture.simulateLost()                          // queues the card behind it
        gate.signal()
        XCTAssertTrue(waitUntil(10) { sink.pushCount >= 1 && pipeline.pool?.inFlight == 0 }, "the card went out and no GPU pass is left")
        pipeline.renderQueue.sync {}
        XCTAssertEqual(sink.pushCount, 1, "the frame from before the loss is dropped, only the card goes out")
        let frame = try XCTUnwrap(sink.lastPixelBuffer)
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(frame, 100, 100), Tokens.surfaceCream), "the last frame is the cream card")
        pipeline.shutdown()
    }

    /// PIPA-02 / PIPB-01 at the pipeline level: WebcamCapture falls back to another present camera, so `.lost` is
    /// followed by `.restored` and frames; the camera bit comes back and camera frames replace the card.
    func testLostCameraFallsBackToAnotherCameraAndFramesResume() throws {
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        pipeline.start()
        XCTAssertTrue(waitUntil(2) { sink.pushCount > 3 })
        capture.stop()
        capture.queue.sync {}
        pipeline.renderQueue.sync {}
        sink.resetRecording()
        capture.simulateLostWithFallback()
        XCTAssertTrue(waitUntil(10) { pipeline.stats.cameraAttached && sink.pushCount >= 5 }, "the replacement camera is attached and its frames flow")
        let resumed = sink.pushCount
        XCTAssertTrue(waitUntil(10) { sink.pushCount > resumed + 2 })
        XCTAssertTrue(sink.lastPixelBuffer === capture.buffer, "camera frames, not the card, after the fallback")
        pipeline.shutdown()
    }

    /// PIPA-01 / PIPB-02 (row 3): the card pushed when access was found missing went nowhere (no app was streaming);
    /// a viewer who opens Daylight Camera later gets it again instead of no frame at all.
    func testLateViewerGetsTheCreamCardWhileUnauthorized() throws {
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        sink.setStatus(.connected)
        pipeline.setSinkConnected(true)
        pipeline.setCaptureAuthorized(false)
        pipeline.start()
        XCTAssertTrue(waitUntil(10) { sink.pushCount >= 1 }, "the first card")
        pipeline.renderQueue.sync {}
        sink.resetRecording()
        pipeline.setViewerCount(1)
        pipeline.renderQueue.sync {}
        XCTAssertEqual(sink.pushCount, 1, "the arriving viewer gets one card")
        let card = try XCTUnwrap(sink.lastPixelBuffer)
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(card, 100, 100), Tokens.surfaceCream), "the cream card")
        XCTAssertEqual(capture.startCount, 0, "row 3: still nothing opens the camera")
        pipeline.shutdown()
    }

    /// PIPA-01 / PIPB-02 (row 4): the camera was lost while capture runs; a viewer arriving afterwards gets the card.
    func testLateViewerGetsTheCreamCardAfterCameraLost() throws {
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        pipeline.start()
        XCTAssertTrue(waitUntil(2) { sink.pushCount > 3 })
        capture.stop()
        capture.queue.sync {}
        capture.simulateLost()
        pipeline.renderQueue.sync {}   // the loss's own card went out here
        pipeline.setViewerCount(0)
        pipeline.renderQueue.sync {}
        sink.resetRecording()
        pipeline.setViewerCount(1)
        pipeline.renderQueue.sync {}
        XCTAssertEqual(sink.pushCount, 1, "the arriving viewer gets one card")
        let card = try XCTUnwrap(sink.lastPixelBuffer)
        XCTAssertFalse(card === capture.buffer)
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(card, 100, 100), Tokens.surfaceCream), "the cream card")
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
        pipeline.renderQueue.sync {}   // the idle stop writes its flags after stopping the capture
        XCTAssertEqual(pipeline.stats.captureIdleReason, "viewers=0 preview=hidden")
        XCTAssertFalse(pipeline.stats.capturing)
        // The camera's next frames are fresh buffers, so the cached frame is told apart from live ones by identity.
        let cached = capture.buffer
        let live = capture.replaceBuffer()
        let pushesWhenStartBegan = Locked<Int?>(nil)
        capture.onStart = { pushesWhenStartBegan.withLock { $0 = sink.pushCount } }
        sink.resetRecording()
        pipeline.setViewerCount(2)
        XCTAssertTrue(waitUntil(1.0) { sink.pushCount >= 1 })
        XCTAssertTrue(sink.firstPixelBuffer === capture.buffer, "the first frame after restart is the cached camera frame")
        XCTAssertTrue(sink.firstPixelBuffer === cached)
        XCTAssertFalse(sink.firstPixelBuffer === live)
        XCTAssertTrue(waitUntil(1.0) { capture.isRunning })
        pipeline.renderQueue.sync {}   // startCapture clears the idle reason after start() returns
        XCTAssertEqual(pushesWhenStartBegan.withLock { $0 }, 1, "the cached frame went out before start() began the camera's warm-up")
        XCTAssertNil(pipeline.stats.captureIdleReason)
        pipeline.shutdown()
    }

    /// PIPB-03: a viewer arriving while the board is up restarts the camera, but no raw camera buffer goes into the
    /// composed stream (the next tick draws the cached frame as the presenter).
    func testRestartWhileLiveNeverPushesARawCameraFrame() throws {
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try makePipeline(sink: sink, capture: capture)
        pipeline.idleStopOverrideSeconds = 0.4
        sink.setStatus(.connected)
        pipeline.setSinkConnected(true)
        pipeline.start()
        pipeline.setViewerCount(1)
        XCTAssertTrue(waitUntil(10) { capture.isRunning && sink.pushCount > 3 })
        pipeline.setViewerCount(0)
        XCTAssertTrue(waitUntil(10) { !capture.isRunning })
        pipeline.renderQueue.sync {}
        pipeline.post(.hold(.split))
        XCTAssertTrue(waitUntil(10) { pipeline.governorSnapshot.state == .live })
        let cached = capture.buffer
        let live = capture.replaceBuffer()
        sink.resetRecording()
        pipeline.setViewerCount(1)
        XCTAssertTrue(waitUntil(10) { capture.isRunning })
        pipeline.renderQueue.sync {}
        if pipeline.compositor != nil {
            XCTAssertTrue(waitUntil(10) { sink.pushCount >= 3 }, "composed frames keep flowing")
        }
        XCTAssertFalse(sink.didPush(cached), "the cached camera frame never goes raw into a composed stream")
        XCTAssertFalse(sink.didPush(live), "nor does a live one")
        pipeline.post(.hold(.auto))
        pipeline.shutdown()
    }

    /// PIPA-04: the cached frame of a 720p camera is composed on restart like every frame of that camera, so the
    /// 1080p sink never receives the raw 720p buffer.
    func testRestartWithANon1080pCameraComposesTheCachedFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device; nothing is composed") }
        let sink = FakeSink()
        let capture = FakeCapture(width: 1280, height: 720)
        let pipeline = try makePipeline(sink: sink, capture: capture)
        pipeline.idleStopOverrideSeconds = 0.4
        sink.setStatus(.connected)
        pipeline.setSinkConnected(true)
        pipeline.start()
        pipeline.setViewerCount(1)
        XCTAssertTrue(waitUntil(10) { capture.isRunning && sink.pushCount > 3 })
        pipeline.setViewerCount(0)
        XCTAssertTrue(waitUntil(10) { !capture.isRunning })
        pipeline.renderQueue.sync {}
        XCTAssertTrue(waitUntil(10) { pipeline.pool?.inFlight == 0 })
        sink.resetRecording()
        pipeline.setViewerCount(2)
        XCTAssertTrue(waitUntil(10) { sink.pushCount >= 1 })
        let first = try XCTUnwrap(sink.firstPixelBuffer)
        XCTAssertFalse(first === capture.buffer, "the 720p buffer never reaches the 1080p sink directly")
        XCTAssertEqual(CVPixelBufferGetWidth(first), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(first), 1080)
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
        // Probe a settled frame: mid-slide (progress 0.50 to 0.68) x=640 is the cream behind the sliding slot, and
        // the 67 ms tick lands there. LIVE snaps the spring to 1, and a frame still in flight is already near 1.
        XCTAssertTrue(waitUntil(2.0) { pipeline.governorSnapshot.state == .live }, "ENGAGING settles to LIVE")
        pipeline.renderQueue.sync {}
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
