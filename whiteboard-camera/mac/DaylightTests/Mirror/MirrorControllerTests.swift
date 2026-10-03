import CoreVideo
import DaylightKit
import Foundation
import XCTest
@testable import Daylight

/// The `MirrorControl` facade with a fake adb: device states to status rows, the pen path to governor events, the
/// pen-button gestures with and without the swap, USB onboarding, and the session failure path.
final class MirrorControllerTests: XCTestCase {
    var vendor: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        vendor = FileManager.default.temporaryDirectory.appendingPathComponent("daylight-mirror-tests-\(UUID().uuidString)/Vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        try Data("not a real server".utf8).write(to: vendor.appendingPathComponent("scrcpy-server-v4.1"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vendor.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    private func makeController(settings: Settings = Settings.defaults, adb: FakeAdb, pipeline: FakePipelineControl) -> MirrorController {
        var deterministic = settings
        deterministic.adbServerMode = .shared   // no probe of the runner's 5037
        let controller = MirrorController(settings: deterministic, vendorDirectory: vendor, pipeline: pipeline, queue: DispatchQueue(label: "mirror-control"), adb: adb)
        controller.trackerTuning = (pollInterval: 0.05, useTrackSocket: false)
        controller.sessionTuning = (attempts: 3, interval: 0.05)
        return controller
    }

    private func waitForStatus(_ controller: MirrorController, timeout: Double = 8, where predicate: @escaping (MirrorStatus) -> Bool) {
        let done = expectation(description: "status")
        done.assertForOverFulfill = false
        controller.onStatusChange = { status in if predicate(status) { done.fulfill() } }
        if predicate(controller.status) { done.fulfill() }
        wait(for: [done], timeout: timeout)
    }

    func testUnauthorizedDeviceIsRow22AndOfflineIsRow23() {
        let adb = FakeAdb()
        let listing = Locked("JP0001   unauthorized usb:1-1 transport_id:1\n")
        adb.respond { args in args == ["devices", "-l"] ? FakeAdb.ok(listing.withLock { $0 }) : nil }
        adb.respond(containing: ["version"], with: FakeAdb.ok("Android Debug Bridge version 1.0.41\n"))
        let pipeline = FakePipelineControl()
        let controller = makeController(adb: adb, pipeline: pipeline)
        XCTAssertEqual(controller.status, .idle)
        controller.start()
        waitForStatus(controller) { $0 == .error(.adbUnauthorized, "JP0001") }
        XCTAssertEqual(controller.devices.first?.state, "unauthorized")
        listing.withLock { $0 = "JP0001   offline usb:1-1 transport_id:1\n" }
        waitForStatus(controller) { $0 == .error(.adbOffline, "JP0001") }
        listing.withLock { $0 = "" }
        waitForStatus(controller) { $0 == .noDevice }
        XCTAssertEqual(controller.diagnostics["adb.mode"], "shared 5037")
        XCTAssertEqual(controller.diagnostics["devices"], "none")
        XCTAssertTrue(adb.spawned.isEmpty, "nothing is launched for an unauthorized or offline tablet")
        controller.stop()
        waitForStatus(controller) { $0 == .idle }
        XCTAssertTrue(pipeline.posted.isEmpty)
    }

    /// LOOSE_ENDS H1 seam: the controller resolves the adb source from its own settings. Download without accepted
    /// terms raises row 39 itself (the menu banner) and shows the row's sentence inside row 25 in the status, never a
    /// Swift enum description; a missing bundled adb keeps row 25's wording and raises nothing else.
    func testAdbSourceFailureRaisesItsOwnRowAndAReadableStatus() {
        var settings = Settings.defaults
        settings.adbServerMode = .shared
        settings.adbSource = .download
        settings.adbTermsAcceptedVersion = nil
        let controller = MirrorController(settings: settings, vendorDirectory: vendor, pipeline: FakePipelineControl(), queue: DispatchQueue(label: "mirror-control"))
        let raised = Locked<[FailureText.Case]>([])
        let row39 = expectation(description: "row 39")
        controller.onFailure = { failure, _ in
            raised.withLock { $0.append(failure) }
            if failure == .adbTermsDeclined { row39.fulfill() }
        }
        let sentence = FailureText.sentence(.adbTermsDeclined)
        controller.start()
        wait(for: [row39], timeout: 8)
        waitForStatus(controller) { $0 == .error(.scrcpyServerFailed, sentence) }
        XCTAssertEqual(MirrorController.describe(controller.status), "error: The screen mirror could not start: " + sentence)
        XCTAssertEqual(raised.withLock { $0 }, [.adbTermsDeclined])
        controller.stop()

        settings.adbSource = .bundled
        let bundled = MirrorController(settings: settings, vendorDirectory: vendor, pipeline: FakePipelineControl(), queue: DispatchQueue(label: "mirror-control-bundled"))
        let other = Locked<[FailureText.Case]>([])
        bundled.onFailure = { failure, _ in other.withLock { $0.append(failure) } }
        let missing = vendor.appendingPathComponent(AdbClient.vendorExecutableName).path
        bundled.start()
        waitForStatus(bundled) { $0 == .error(.scrcpyServerFailed, "bundled adb missing at \(missing) (run make fetch-tools)") }
        XCTAssertEqual(other.withLock { $0 }, [], "a missing bundled adb is row 25 only, as before H1")
        bundled.stop()
    }

    func testReadyDeviceStartsTheSessionAndThePenPathPostsGovernorEvents() {
        let adb = FakeAdb()
        adb.respond(containing: ["devices"], with: FakeAdb.ok("JP0001   device usb:1-1 product:daylight model:Daylight_DC_1 device:dc1 transport_id:1\n"))
        adb.respond(containing: ["getevent", "-pl"], with: FakeAdb.ok(StylusFixtures.listingWithPen))
        adb.respond(containing: ["version"], with: FakeAdb.ok("Android Debug Bridge version 1.0.41\n"))
        let pipeline = FakePipelineControl()
        var settings = Settings.defaults
        settings.mirrorPinClearMode = .both
        let controller = makeController(settings: settings, adb: adb, pipeline: pipeline)
        controller.sessionTuning = (attempts: 200, interval: 0.1)   // the dummy byte never comes; keep the session alive for the pen test
        let penSpawned = expectation(description: "getevent spawned")
        adb.onSpawn = { args, _ in if args.contains("-lt") { penSpawned.fulfill() } }
        controller.start()
        waitForStatus(controller) { $0 == .connecting(serial: "JP0001") }
        wait(for: [penSpawned], timeout: 8)
        XCTAssertTrue(adb.calls.contains(ScrcpyLaunch(serial: "JP0001").pushArguments(serverPath: vendor.appendingPathComponent("scrcpy-server-v4.1").path)))
        XCTAssertTrue(adb.calls.contains { $0.contains("app_process") && $0.contains("4.1") })
        XCTAssertTrue(adb.calls.contains(["-s", "JP0001", "shell", "-T", "getevent", "-pl"]))
        XCTAssertFalse(adb.calls.contains { $0.contains("install") }, "no APK in this build, so no pills install")
        guard let pen = adb.spawned.first(where: { $0.args.contains("-lt") }) else { return XCTFail("no getevent child") }
        let events = expectation(description: "pen events")
        events.expectedFulfillmentCount = 4
        pipeline.onPost = { _ in events.fulfill() }
        pen.emitStdout(StylusFixtures.penDown(at: 1.0))
        pen.emitStdout(StylusFixtures.penUp(at: 1.5))
        pen.emitStdout(StylusFixtures.sideButton(true, at: 2.0))
        pen.emitStdout(StylusFixtures.sideButton(false, at: 2.1))
        pen.emitStdout(StylusFixtures.sideButton(true, at: 2.3))
        pen.emitStdout(StylusFixtures.sideButton(false, at: 2.4))
        pen.emitStdout(StylusFixtures.report(3.0, [("EV_KEY", "BTN_TOOL_PEN", "UP"), ("EV_KEY", "BTN_TOOL_RUBBER", "DOWN"), ("EV_KEY", "BTN_TOUCH", "DOWN")]))
        wait(for: [events], timeout: 8)
        XCTAssertEqual(pipeline.posted, [.penContact(down: true), .penContact(down: false), .pin(-1), .eraserContact(down: true)])
        XCTAssertNotNil(controller.diagnostics["pen.node"])
        pipeline.onPost = nil
        controller.stop()
        waitForStatus(controller) { $0 == .idle }
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 5)
        XCTAssertEqual(pipeline.posted.last, .penContact(down: false), "the session end lifts the pen for the governor")
        XCTAssertTrue(adb.spawned.allSatisfy { !$0.isRunning }, "every child is terminated when the session ends")
    }

    func testSessionWithoutADummyByteIsRow25() {
        let adb = FakeAdb()
        adb.respond(containing: ["devices"], with: FakeAdb.ok("JP0001   device transport_id:1\n"))
        adb.respond(containing: ["getevent", "-pl"], with: FakeAdb.ok(StylusFixtures.listingWithoutPen))
        let pipeline = FakePipelineControl()
        let controller = makeController(adb: adb, pipeline: pipeline)
        let failures = Locked<[FailureText.Case]>([])
        controller.onFailure = { failure, _ in failures.withLock { $0.append(failure) } }
        controller.start()
        waitForStatus(controller, timeout: 15) { if case .error(.scrcpyServerFailed, _) = $0 { return true } else { return false } }
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 5)
        XCTAssertTrue(failures.withLock { $0 }.contains(.scrcpyServerFailed), "row 25 reaches the menu")
        XCTAssertTrue(failures.withLock { $0 }.contains(.noPenDevice), "row 28 for a tablet without a pen node")
        XCTAssertTrue(adb.spawned.allSatisfy { !$0.isRunning }, "the server child is terminated")
        XCTAssertEqual(pipeline.posted, [.penContact(down: false)], "a session end lifts the pen; nothing else was posted")
        XCTAssertTrue(controller.diagnostics["status"]?.hasPrefix("error: The screen mirror could not start") ?? false)
        controller.stop()
    }

    func testSwapSettingAndPillsOnlyModeGateTheGestures() {
        let adb = FakeAdb()
        adb.respond(containing: ["devices"], with: FakeAdb.ok("JP0001   device transport_id:1\n"))
        adb.respond(containing: ["getevent", "-pl"], with: FakeAdb.ok(StylusFixtures.listingWithPen))
        let pipeline = FakePipelineControl()
        var settings = Settings.defaults
        settings.sideButtonSwap = true
        let controller = makeController(settings: settings, adb: adb, pipeline: pipeline)
        controller.sessionTuning = (attempts: 200, interval: 0.1)
        let penSpawned = expectation(description: "getevent spawned")
        adb.onSpawn = { args, _ in if args.contains("-lt") { penSpawned.fulfill() } }
        controller.start()
        wait(for: [penSpawned], timeout: 8)
        guard let pen = adb.spawned.first(where: { $0.args.contains("-lt") }) else { return XCTFail("no getevent child") }
        let cleared = expectation(description: "clear from a swapped double press")
        pipeline.onPost = { event in if event == .clear { cleared.fulfill() } }
        pen.emitStdout(StylusFixtures.sideButton(true, at: 2.0))
        pen.emitStdout(StylusFixtures.sideButton(false, at: 2.1))
        pen.emitStdout(StylusFixtures.sideButton(true, at: 2.3))
        pen.emitStdout(StylusFixtures.sideButton(false, at: 2.4))
        wait(for: [cleared], timeout: 5)
        XCTAssertEqual(pipeline.posted, [.clear])
        // Pills only: the pen button does nothing, the pen tip still engages.
        settings.mirrorPinClearMode = .pills
        controller.updateSettings(settings)
        let engaged = expectation(description: "pen contact still engages")
        let gesture = expectation(description: "no gesture")
        gesture.isInverted = true
        pipeline.onPost = { event in
            if event == .penContact(down: true) { engaged.fulfill() }
            if event == .clear || event == .pin(-1) { gesture.fulfill() }
        }
        pen.emitStdout(StylusFixtures.sideButton(true, at: 5.0))
        pen.emitStdout(StylusFixtures.sideButton(false, at: 5.1))
        pen.emitStdout(StylusFixtures.sideButton(true, at: 5.3))
        pen.emitStdout(StylusFixtures.sideButton(false, at: 5.4))
        pen.emitStdout(StylusFixtures.penDown(at: 6.0))
        wait(for: [engaged, gesture], timeout: 3)
        controller.stop()
    }

    func testSetUpOverUSBForWebAndNative() {
        let adb = FakeAdb()
        adb.respond(containing: ["devices"], with: FakeAdb.ok("JP0001   device usb:1-1 model:Daylight_DC_1 transport_id:1\n192.168.1.40:5555 device transport_id:2\n"))
        let pipeline = FakePipelineControl()
        let controller = makeController(adb: adb, pipeline: pipeline)
        controller.serverPort = 7789
        let web = expectation(description: "web")
        controller.setUpOverUSB(source: .web, host: "192.168.1.10", pills: true) { result in
            if case let .failure(error) = result { XCTFail("\(error)") }
            web.fulfill()
        }
        wait(for: [web], timeout: 8)
        XCTAssertTrue(adb.calls.contains(["-s", "JP0001", "reverse", "tcp:7789", "tcp:7789"]), "the USB device, never the Wi-Fi one; the bound port")
        XCTAssertTrue(adb.calls.contains(["-s", "JP0001", "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", "http://localhost:7789"]))
        let native = expectation(description: "native without an APK")
        controller.setUpOverUSB(source: .native, host: nil, pills: false) { result in
            guard case let .failure(error) = result, case .failed? = error as? AdbError else { return XCTFail("\(result)") }
            native.fulfill()
        }
        wait(for: [native], timeout: 8)
        XCTAssertFalse(adb.calls.contains { $0.contains("install") })
        // With an APK next to the Vendor folder the native path installs it and passes the host.
        let apk = vendor.deletingLastPathComponent().appendingPathComponent("DaylightInk.apk")
        try? Data("apk".utf8).write(to: apk)
        controller.apkURL = apk
        let installed = expectation(description: "installed")
        controller.setUpOverUSB(source: .native, host: "100.64.0.7", pills: true) { result in
            if case let .failure(error) = result { XCTFail("\(error)") }
            installed.fulfill()
        }
        wait(for: [installed], timeout: 8)
        XCTAssertTrue(adb.calls.contains(["-s", "JP0001", "install", "-r", "-d", apk.path]))
        // The tablet dials 127.0.0.1:7788; the Mac bound 7789 here, so the reverse maps 7788 onto it and the remembered
        // wireless host carries the bound port (review round 1 android-09).
        XCTAssertTrue(adb.calls.contains(["-s", "JP0001", "reverse", "tcp:7788", "tcp:7789"]))
        XCTAssertTrue(adb.calls.contains(["-s", "JP0001", "shell", "am", "start", "-n", "com.twelve.daylight.ink/.ui.MainActivity", "--es", "host", "100.64.0.7:7789"]))
        XCTAssertTrue(adb.calls.contains(["-s", "JP0001", "shell", "am", "start-foreground-service", "-n", "com.twelve.daylight.ink/.overlay.OverlayService", "--es", "pills", "top", "--es", "host", "100.64.0.7:7789"]))
        XCTAssertEqual(controller.status, .idle, "onboarding never starts the mirror")
    }

    func testNoUSBDeviceFailsOnboardingWithRow21() {
        let adb = FakeAdb()
        adb.respond(containing: ["devices"], with: FakeAdb.ok("192.168.1.40:5555 device transport_id:2\n"))
        let controller = makeController(adb: adb, pipeline: FakePipelineControl())
        let done = expectation(description: "no device")
        controller.setUpOverUSB(source: .web, host: nil, pills: false) { result in
            guard case let .failure(error) = result else { return XCTFail("\(result)") }
            XCTAssertEqual(error as? AdbError, .noDevice)
            done.fulfill()
        }
        wait(for: [done], timeout: 8)
        XCTAssertEqual(FailureText.sentence(.adbNoDevice), "No Daylight found over USB. Is USB debugging on?")
    }

    /// SPEC 13.1 step 3: the Welcome window offers "Set up over USB" with the Web or Daylight Ink source selected, when
    /// the tracker is not running. `refreshDevices()` lists the tablet without mirroring and is rate limited.
    func testRefreshDevicesListsTheUSBTabletWithoutStartingTheMirror() {
        let adb = FakeAdb()
        adb.respond(containing: ["devices"], with: FakeAdb.ok("JP0001   device usb:1-1 model:Daylight_DC_1 transport_id:1\n"))
        adb.respond(containing: ["version"], with: FakeAdb.ok("Android Debug Bridge version 1.0.41\n"))
        let pipeline = FakePipelineControl()
        let controller = makeController(adb: adb, pipeline: pipeline)
        let listed = expectation(description: "devices listed")
        listed.assertForOverFulfill = false
        controller.onDevicesChange = { list in if list.contains(where: { $0.serial == "JP0001" }) { listed.fulfill() } }
        controller.refreshDevices()
        wait(for: [listed], timeout: 8)
        XCTAssertEqual(controller.devices.first?.serial, "JP0001")
        XCTAssertEqual(controller.devices.first?.isUSB, true)
        XCTAssertEqual(controller.status, .idle, "a device listing never starts the mirror")
        XCTAssertTrue(adb.spawned.isEmpty, "no scrcpy server, no getevent")
        XCTAssertTrue(pipeline.posted.isEmpty)
        let listings = adb.calls(containing: "devices").count
        controller.refreshDevices()
        controller.refreshDevices()
        let settled = expectation(description: "control queue drained")
        controller.queue.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(adb.calls(containing: "devices").count, listings, "rate limited to one listing per devicesRefreshInterval")
        XCTAssertEqual(MirrorController.devicesRefreshInterval, 5)
    }

    func testMissingBundledAdbIsReportedNotCrashed() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("daylight-no-vendor-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let controller = MirrorController(settings: Settings.defaults, vendorDirectory: empty, pipeline: FakePipelineControl(), queue: DispatchQueue(label: "mirror-control"))
        controller.start()
        waitForStatus(controller) { if case .error(.scrcpyServerFailed, let detail) = $0 { return detail.contains("bundled adb missing") } else { return false } }
        XCTAssertNil(controller.latestFrameForSave())
        XCTAssertEqual(controller.diagnostics["adb.executable"], "none")
        controller.stop()
    }

    func testSourceContractAndDiagnosticsFromAnotherThread() {
        let controller = makeController(adb: FakeAdb(), pipeline: FakePipelineControl())
        XCTAssertNil(controller.source.latest())
        XCTAssertEqual(controller.source.frameSeed, 0)
        XCTAssertEqual(controller.status, .idle)
        XCTAssertEqual(controller.devices, [])
        let d = controller.diagnostics
        XCTAssertEqual(d["status"], "idle")
        XCTAssertEqual(d["session.size"], "1200x1600")
        XCTAssertEqual(d["crop.portrait"], "top 96 left 0 right 0 bottom 0")
        XCTAssertEqual(d["pinClear"], "both")
        XCTAssertEqual(MirrorController.describe(.mirroring(serial: "S", width: 1200, height: 1600)), "mirroring S 1200x1600")
        XCTAssertEqual(MirrorController.describe(.error(.adbOffline, "S")), "error: The Daylight is connected but not responding. Unplug and plug again.")
        XCTAssertEqual(MirrorController.sessionRetryInitial, 3)
        XCTAssertEqual(MirrorController.sessionRetryMax, 24)
    }
}
