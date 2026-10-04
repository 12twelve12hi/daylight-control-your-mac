import DaylightKit
import Metal
import XCTest
@testable import Daylight

/// FramePipeline hooks for Presenter Overlay (SPEC 6.7): no controller while the setting is off, frames offered only
/// while the board is up in the Overlay layout, the overlay perf line only with a controller. FakeCapture into FakeSink.
final class OverlayPipelineTests: XCTestCase {
    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    private func overlaySettings(enabled: Bool, layout: LayoutStyle = .overlay) -> Settings {
        var s = Settings.defaults
        s.overlayEnabled = enabled
        s.preferredLayout = layout
        return s
    }

    func testNoControllerWhileTheSettingIsOff() throws {
        let pipeline = try FramePipeline(sink: FakeSink(), settings: Settings.defaults, telemetry: Telemetry(perfLog: false), device: MTLCreateSystemDefaultDevice(), capture: FakeCapture())
        XCTAssertNil(pipeline.overlayController, "Overlay is off by default: no controller, no queue, no Vision")
        let stored = overlaySettings(enabled: false)
        pipeline.updateSettings(stored)
        XCTAssertNil(pipeline.overlayController)
        XCTAssertEqual(pipeline.governorConfig.preferredLayout, .studioSplit, "a stored Overlay layout engages in Studio Split while Overlay is off")
        guard pipeline.compositor != nil else { return }
        pipeline.updateSettings(overlaySettings(enabled: true))
        XCTAssertNotNil(pipeline.overlayController, "turning the setting on creates the controller")
        XCTAssertEqual(pipeline.governorConfig.preferredLayout, .overlay)
        pipeline.updateSettings(overlaySettings(enabled: false))
        XCTAssertNil(pipeline.overlayController, "turning it off releases the controller")
        pipeline.shutdown()
    }

    func testFramesAreOfferedOnlyWhileLiveInTheOverlayLayout() throws {
        let sink = FakeSink()
        let capture = FakeCapture()
        let pipeline = try FramePipeline(sink: sink, settings: Settings.defaults, telemetry: Telemetry(perfLog: false), device: MTLCreateSystemDefaultDevice(), capture: capture)
        guard pipeline.compositor != nil else {
            pipeline.shutdown()
            throw XCTSkip("no Metal device: the overlay controller needs one")
        }
        let engine = FixedMaskEngine(value: 255)
        pipeline.makeOverlayEngine = { engine }
        pipeline.updateSettings(overlaySettings(enabled: true))
        let controller = try XCTUnwrap(pipeline.overlayController)
        pipeline.start()
        XCTAssertTrue(waitUntil(5) { capture.frames >= 15 }, "camera frames flow in PASSTHROUGH")
        controller.drain()
        XCTAssertEqual(engine.calls, 0, "never offered in PASSTHROUGH")

        pipeline.post(.engage)
        XCTAssertTrue(waitUntil(2) { pipeline.governorSnapshot.state == .live })
        XCTAssertEqual(pipeline.governorSnapshot.layout, .overlay)
        XCTAssertTrue(waitUntil(5) { engine.calls >= 3 }, "offered while the Overlay board is up")
        XCTAssertTrue(waitUntil(2) { pipeline.stats.mode == "overlay" }, "stats mode: \(pipeline.stats.mode)")
        XCTAssertTrue(waitUntil(2) { sink.pushCount >= 3 }, "composed overlay frames flow")

        pipeline.post(.returnNow)
        XCTAssertTrue(waitUntil(3) { pipeline.governorSnapshot.state == .passthrough })
        capture.queue.sync {}
        controller.drain()
        let settled = engine.calls
        let frames = capture.frames
        XCTAssertTrue(waitUntil(5) { capture.frames >= frames + 10 })
        controller.drain()
        XCTAssertEqual(engine.calls, settled, "no offers after the return to PASSTHROUGH")
        pipeline.shutdown()
    }

    func testStudioSplitWithTheControllerNeverOffers() throws {
        let capture = FakeCapture()
        let pipeline = try FramePipeline(sink: FakeSink(), settings: Settings.defaults, telemetry: Telemetry(perfLog: false), device: MTLCreateSystemDefaultDevice(), capture: capture)
        guard pipeline.compositor != nil else {
            pipeline.shutdown()
            throw XCTSkip("no Metal device: the overlay controller needs one")
        }
        let engine = FixedMaskEngine(value: 255)
        pipeline.makeOverlayEngine = { engine }
        pipeline.updateSettings(overlaySettings(enabled: true, layout: .studioSplit))
        let controller = try XCTUnwrap(pipeline.overlayController)
        pipeline.start()
        pipeline.post(.engage)
        XCTAssertTrue(waitUntil(2) { pipeline.governorSnapshot.state == .live })
        let frames = capture.frames
        XCTAssertTrue(waitUntil(5) { capture.frames >= frames + 10 })
        controller.drain()
        XCTAssertEqual(engine.calls, 0, "Studio Split never segments")
        XCTAssertEqual(pipeline.stats.mode, "split")
        pipeline.shutdown()
    }

    func testOverlayFallbackRendersStudioSplitAndReportsRow48() throws {
        let capture = FakeCapture()
        let pipeline = try FramePipeline(sink: FakeSink(), settings: Settings.defaults, telemetry: Telemetry(perfLog: false), device: MTLCreateSystemDefaultDevice(), capture: capture)
        guard pipeline.compositor != nil else {
            pipeline.shutdown()
            throw XCTSkip("no Metal device: the overlay controller needs one")
        }
        let lock = NSLock()
        var reported: [FailureText.Case] = []
        pipeline.onFailure = { failure, _ in
            lock.lock()
            reported.append(failure)
            lock.unlock()
        }
        pipeline.makeOverlayEngine = { ThrowingMaskEngine() }
        pipeline.updateSettings(overlaySettings(enabled: true))
        pipeline.start()
        pipeline.post(.engage)
        XCTAssertTrue(waitUntil(2) { pipeline.governorSnapshot.state == .live })
        XCTAssertTrue(waitUntil(10) { pipeline.overlayController?.isFellBack ?? false }, "15 failed frames latch the fallback")
        XCTAssertEqual(pipeline.stats.mode, "split", "a fallen-back Overlay renders Studio Split")
        lock.lock()
        let rows = reported.filter { $0 == .overlayFallback }.count
        lock.unlock()
        XCTAssertEqual(rows, 1)
        pipeline.shutdown()
    }

    /// OV-2: a controller that cannot be created posts row 48 once; later Settings changes (a slider drag sends many)
    /// neither retry nor post it again until Overlay is turned off and on.
    func testControllerCreationFailurePostsRow48OnceUntilToggled() throws {
        let pipeline = try FramePipeline(sink: FakeSink(), settings: Settings.defaults, telemetry: Telemetry(perfLog: false), device: MTLCreateSystemDefaultDevice(), capture: FakeCapture())
        guard pipeline.compositor != nil else {
            pipeline.shutdown()
            throw XCTSkip("no Metal device: the overlay controller needs one")
        }
        let lock = NSLock()
        var rows = 0
        var attempts = 0
        pipeline.onFailure = { failure, _ in
            lock.lock()
            if failure == .overlayFallback { rows += 1 }
            lock.unlock()
        }
        pipeline.makeOverlayEngine = {
            lock.lock()
            attempts += 1
            lock.unlock()
            throw OverlayFakes.Failure()
        }
        var s = overlaySettings(enabled: true)
        pipeline.updateSettings(s)
        XCTAssertNil(pipeline.overlayController)
        for opacity in [0.9, 0.8, 0.7] {
            s.overlayOpacity = opacity
            pipeline.updateSettings(s)
        }
        lock.lock()
        XCTAssertEqual(rows, 1, "row 48 once, not once per Settings change")
        XCTAssertEqual(attempts, 1, "no retry until the setting is toggled")
        lock.unlock()
        pipeline.updateSettings(overlaySettings(enabled: false))
        pipeline.updateSettings(overlaySettings(enabled: true))
        lock.lock()
        XCTAssertEqual(rows, 2, "turning Overlay off and on tries again")
        XCTAssertEqual(attempts, 2)
        lock.unlock()
        pipeline.shutdown()
    }

    func testOverlayPerfLineOnlyWithAController() throws {
        for enabled in [false, true] {
            let telemetry = Telemetry(perfLog: true)
            let lock = NSLock()
            var lines: [String] = []
            telemetry.sink = { line in
                lock.lock()
                lines.append(line)
                lock.unlock()
            }
            let pipeline = try FramePipeline(sink: FakeSink(), settings: overlaySettings(enabled: enabled), telemetry: telemetry, device: MTLCreateSystemDefaultDevice(), capture: FakeCapture())
            let hasController = pipeline.overlayController != nil
            XCTAssertEqual(hasController, enabled && pipeline.compositor != nil)
            pipeline.start()
            XCTAssertTrue(waitUntil(5) {
                lock.lock()
                defer { lock.unlock() }
                return lines.contains { $0.hasPrefix("perf mode=") }
            })
            pipeline.renderQueue.sync {}
            pipeline.shutdown()
            lock.lock()
            let overlayLines = lines.filter { $0.hasPrefix("perf overlay ") }
            let perfLines = lines.filter { $0.hasPrefix("perf mode=") }
            lock.unlock()
            XCTAssertEqual(!overlayLines.isEmpty, hasController, "enabled=\(enabled): \(lines)")
            if hasController { XCTAssertEqual(overlayLines.count, perfLines.count, "one overlay line after each perf line") }
            XCTAssertTrue(perfLines.allSatisfy { !$0.contains("overlay") }, "the existing perf line is unchanged")
        }
    }
}

/// The menu's row 48 line (AppModel): set by the pipeline's failure, cleared when Overlay is toggled.
final class OverlayAppModelTests: XCTestCase {
    func testFallbackLineFollowsTheFailureAndClearsOnToggle() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "overlay-\(UUID().uuidString)")!, unsignedBuild: false)
        store.settings.overlayEnabled = true
        let model = AppModel(settingsStore: store, signed: true, version: "0", build: "0")
        XCTAssertNil(model.overlayFallbackLine)
        model.noteFailure(.overlayFallback, ["15", "fake"])
        XCTAssertEqual(model.overlayFallbackLine, FailureText.sentence(.overlayFallback))
        XCTAssertNil(model.banner, "row 48 has its own menu line, not a second banner")
        model.noteFailure(.overlayLowCoverage, ["0.000"])
        XCTAssertNil(model.banner, "row 49 is for Diagnostics only")
        XCTAssertTrue(model.recentFailures.contains(FailureText.sentence(.overlayLowCoverage)))
        store.settings.overlayEnabled = false
        XCTAssertNil(model.overlayFallbackLine, "toggling Overlay clears the line")
    }
}
