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

    /// Polls `condition` until it holds or `timeout` passes (a condition wait, not a fixed window).
    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
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
    /// Swift enum description; a missing bundled adb keeps row 25's wording and raises nothing else. `bundledAvailable`
    /// is set, so a DAYLIGHT_BUNDLE_ADB=0 host app (Bundled resolves as Download there) runs it the same (ADB-A5).
    func testAdbSourceFailureRaisesItsOwnRowAndAReadableStatus() {
        var settings = Settings.defaults
        settings.adbServerMode = .shared
        settings.adbSource = .download
        settings.adbTermsAcceptedVersion = nil
        let controller = MirrorController(settings: settings, vendorDirectory: vendor, pipeline: FakePipelineControl(), queue: DispatchQueue(label: "mirror-control"))
        controller.bundledAvailable = true
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
        bundled.bundledAvailable = true
        let other = Locked<[FailureText.Case]>([])
        bundled.onFailure = { failure, _ in other.withLock { $0.append(failure) } }
        let missing = vendor.appendingPathComponent(AdbClient.vendorExecutableName).path
        bundled.start()
        waitForStatus(bundled) { $0 == .error(.scrcpyServerFailed, "bundled adb missing at \(missing) (run make fetch-tools)") }
        XCTAssertEqual(other.withLock { $0 }, [], "a missing bundled adb is row 25 only, as before H1")
        bundled.stop()
    }

    /// ADB-A5: a build without a bundled adb resolves Bundled as Download, whatever the test host's Info.plist says.
    /// Before the seam the controller read the host app's `DaylightBundlesAdb`, so this could not be expressed.
    func testABuildWithoutBundledAdbResolvesBundledAsDownload() {
        var settings = Settings.defaults
        settings.adbServerMode = .shared
        settings.adbSource = .bundled
        settings.adbTermsAcceptedVersion = nil
        let controller = MirrorController(settings: settings, vendorDirectory: vendor, pipeline: FakePipelineControl(), queue: DispatchQueue(label: "mirror-control-no-bundled"))
        controller.bundledAvailable = false
        let raised = Locked<[FailureText.Case]>([])
        let row39 = expectation(description: "row 39")
        controller.onFailure = { failure, _ in
            raised.withLock { $0.append(failure) }
            if failure == .adbTermsDeclined { row39.fulfill() }
        }
        controller.start()
        wait(for: [row39], timeout: 8)
        waitForStatus(controller) { $0 == .error(.scrcpyServerFailed, FailureText.sentence(.adbTermsDeclined)) }
        XCTAssertEqual(raised.withLock { $0 }, [.adbTermsDeclined])
        controller.stop()
    }

    /// A downloader in a temporary folder with the shipped version, and a way to "finish" its download: a fake adb
    /// script (empty `devices -l`) plus the manifest `locateInstalled` checks.
    private func makeDownloader() -> (AdbDownloader, () throws -> URL) {
        let directory = vendor.deletingLastPathComponent().appendingPathComponent("platform-tools", isDirectory: true)
        let pins = AdbPins(version: AdbPins.platformToolsVersion, sha256: String(repeating: "a", count: 64), url: URL(fileURLWithPath: "/nonexistent.zip"))
        let downloader = AdbDownloader(directory: directory, pins: pins)
        let install = { () throws -> URL in
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = "#!/bin/sh\nif [ \"$1\" = version ]; then echo 'Android Debug Bridge version 1.0.41'; fi\nexit 0\n"
            try script.write(to: downloader.executable, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloader.executable.path)
            let sha = AdbSHA256.hex(of: downloader.executable) ?? ""
            let manifest = AdbDownloadManifest(version: pins.version, zipSHA256: pins.sha256, adbSHA256: sha)
            try JSONEncoder().encode(manifest).write(to: downloader.manifestURL)
            return downloader.executable
        }
        return (downloader, install)
    }

    /// LOOSE_ENDS J2: a new adb source applies while mirror mode runs, without a relaunch. Download without accepted
    /// terms fails (row 39); accepting the terms with the download in place stops, forgets the failed resolution and
    /// starts again with the downloaded adb. Before J2 the controller kept `adbUnavailable` and the error until a relaunch,
    /// so the `.noDevice` wait timed out.
    func testANewAdbSourceAppliesWithoutARelaunch() throws {
        var settings = Settings.defaults
        settings.adbServerMode = .shared
        settings.adbSource = .download
        settings.adbTermsAcceptedVersion = nil
        let controller = MirrorController(settings: settings, vendorDirectory: vendor, pipeline: FakePipelineControl(), queue: DispatchQueue(label: "mirror-control-j2"))
        controller.bundledAvailable = true   // the final Bundled step expects "bundled adb missing" on every build (ADB-A5)
        controller.trackerTuning = (pollInterval: 0.05, useTrackSocket: false)
        let (downloader, install) = makeDownloader()
        controller.adbDownloader = downloader
        controller.start()
        waitForStatus(controller) { $0 == .error(.scrcpyServerFailed, FailureText.sentence(.adbTermsDeclined)) }
        XCTAssertEqual(controller.diagnostics["adb.executable"], "none")

        let adbURL = try install()
        settings.adbTermsAcceptedVersion = AdbPins.platformToolsVersion
        controller.updateSettings(settings)
        waitForStatus(controller) { $0 == .noDevice }
        XCTAssertEqual(controller.diagnostics["adb.executable"], adbURL.path, "the downloaded adb is in use")
        XCTAssertEqual(controller.diagnostics["adb.mode"], "shared 5037")

        // Back to Bundled (missing in the test vendor folder): applies at once as well.
        settings.adbSource = .bundled
        controller.updateSettings(settings)
        waitForStatus(controller) { if case .error(.scrcpyServerFailed, let detail) = $0 { return detail.contains("bundled adb missing") } else { return false } }
        XCTAssertEqual(controller.diagnostics["adb.executable"], "none")
        controller.stop()
        waitForStatus(controller) { $0 == .idle }
    }

    /// LOOSE_ENDS J2: the Settings tab stores the accepted terms before its download finishes. The controller then
    /// reports "not downloaded yet" and picks the download up when it lands, with no further settings change. Before J2
    /// nothing looked again, so the `.noDevice` wait timed out.
    func testAFinishedDownloadAppliesWithoutASettingsChange() throws {
        var settings = Settings.defaults
        settings.adbServerMode = .shared
        settings.adbSource = .download
        settings.adbTermsAcceptedVersion = AdbPins.platformToolsVersion
        let controller = MirrorController(settings: settings, vendorDirectory: vendor, pipeline: FakePipelineControl(), queue: DispatchQueue(label: "mirror-control-j2-poll"))
        controller.trackerTuning = (pollInterval: 0.05, useTrackSocket: false)
        controller.adbDownloadPollInterval = 0.1
        let (downloader, install) = makeDownloader()
        controller.adbDownloader = downloader
        controller.start()
        let notYet = AdbSourceError.notDownloaded(version: AdbPins.platformToolsVersion).sentence
        waitForStatus(controller) { $0 == .error(.scrcpyServerFailed, notYet) }
        let adbURL = try install()
        waitForStatus(controller) { $0 == .noDevice }
        XCTAssertEqual(controller.diagnostics["adb.executable"], adbURL.path)
        XCTAssertEqual(MirrorController.adbDownloadPollInterval, 2)
        controller.stop()
        waitForStatus(controller) { $0 == .idle }
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
        // The session and the pen watcher stop on their own queues after .idle: wait for the children, not 0.3 s.
        XCTAssertTrue(waitUntil(10) { adb.spawned.allSatisfy { !$0.isRunning } }, "every child is terminated when the session ends")
        XCTAssertEqual(pipeline.posted.last, .penContact(down: false), "the session end lifts the pen for the governor")
    }

    func testSessionWithoutADummyByteIsRow25() {
        let adb = FakeAdb()
        adb.respond(containing: ["devices"], with: FakeAdb.ok("JP0001   device transport_id:1\n"))
        adb.respond(containing: ["getevent", "-pl"], with: FakeAdb.ok(StylusFixtures.listingWithoutPen))
        let pipeline = FakePipelineControl()
        let controller = makeController(adb: adb, pipeline: pipeline)
        let failures = Locked<[FailureText.Case]>([])
        let row28 = DispatchSemaphore(value: 0)
        controller.onFailure = { failure, _ in
            failures.withLock { $0.append(failure) }
            if failure == .noPenDevice { row28.signal() }
        }
        // The pen probe and the dummy-byte timeout race; a session that ended first drops the probe's row 28 (by
        // design). When the scrcpy server child is spawned, the mirror queue (where the dummy-byte attempts and their
        // socket callbacks run; row 28 never passes through it) is held until row 28 arrived, so the order the test
        // asserts is certain. Bounded: at most 10 s.
        let mirrorQueue = controller.mirrorQueue
        adb.onSpawn = { args, _ in
            if args.contains("app_process") { mirrorQueue.async { _ = row28.wait(timeout: .now() + 10) } }
        }
        controller.start()
        waitForStatus(controller, timeout: 25) { if case .error(.scrcpyServerFailed, _) = $0 { return true } else { return false } }
        // Row 25 is raised and the pen lifted right after the status change, the children end on their own queues.
        XCTAssertTrue(waitUntil(10) {
            failures.withLock { $0 }.contains(.scrcpyServerFailed) && !pipeline.posted.isEmpty && adb.spawned.allSatisfy { !$0.isRunning }
        }, "row 25, the pen lift and the terminated children")
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
        controller.bundledAvailable = true   // the bundled source on every build (ADB-A5)
        controller.start()
        waitForStatus(controller) { if case .error(.scrcpyServerFailed, let detail) = $0 { return detail.contains("bundled adb missing") } else { return false } }
        XCTAssertNil(controller.latestFrameForSave())
        XCTAssertEqual(controller.diagnostics["adb.executable"], "none")
        controller.stop()
    }

    // MARK: Transport switches and the pen watcher (hardening round 3)

    private static let usbDaylight = "JP0001   device usb:1-1 product:daylight model:Daylight_DC_1 device:dc1 transport_id:1\n"

    /// Runs one decoded Wi-Fi frame through frame-difference engage, as `frameDecoded` does (mirror.queue).
    private func decodeOneWifiFrame(_ controller: MirrorController) {
        let source = controller.wifiSource
        let buffer = FrameDiffEngageHostedTests.makeBuffer()
        source.mirrorQueue.sync { source.engage(buffer: buffer, uv: FrameDiffEngageHostedTests.fullCrop, orientation: .portrait, now: 0) }
    }

    private func switchTransport(_ controller: MirrorController, to transport: MirrorTransport) {
        var settings = controller.settings
        settings.mirrorTransport = transport
        controller.updateSettings(settings)
        controller.queue.sync {}   // transportChanged ran
        controller.queue.sync {}   // and every hop it queued behind itself
    }

    /// USB-A1/B2: with adb unresolved there is no tracker, and a transport switch set "no device" over the adb error
    /// (the status was the only place a missing bundled adb was named), and nothing located adb again. Before the fix
    /// each case ended on `.noDevice`.
    func testATransportSwitchWithoutAdbKeepsTheCause() {
        let declined = FailureText.sentence(.adbTermsDeclined)
        let missing = vendor.appendingPathComponent(AdbClient.vendorExecutableName).path
        let bundledMissing = "bundled adb missing at \(missing) (run make fetch-tools)"
        let cases: [(AdbSource, MirrorTransport, String)] = [
            (.download, .usb, declined),
            (.download, .wifiStream, declined),
            (.bundled, .usb, bundledMissing),
        ]
        for (index, (source, first, expected)) in cases.enumerated() {
            var settings = Settings.defaults
            settings.adbServerMode = .shared
            settings.adbSource = source
            settings.adbTermsAcceptedVersion = nil
            settings.mirrorTransport = first
            let controller = MirrorController(settings: settings, vendorDirectory: vendor, pipeline: FakePipelineControl(), queue: DispatchQueue(label: "mirror-control-a1-\(index)"))
            controller.bundledAvailable = true
            let resolved = expectation(description: "adb resolution failed, case \(index)")
            resolved.assertForOverFulfill = false
            controller.onLog = { line in if line.contains("status: error") { resolved.fulfill() } }
            controller.start()
            wait(for: [resolved], timeout: 8)
            if first == .usb {
                switchTransport(controller, to: .wifiStream)
            }
            switchTransport(controller, to: .usb)
            XCTAssertEqual(controller.status, .error(.scrcpyServerFailed, expected), "case \(index): the cause stays in the status")
            XCTAssertEqual(controller.diagnostics["adb.executable"], "none", "case \(index)")
            controller.stop()
            controller.queue.sync {}
        }
    }

    /// USB-A2/B3: the USB slot kept the last USB frame across a transport switch, so after Wi-Fi and back the old
    /// picture was shown and saved as this session's. Before the fix both reads returned the published buffer.
    func testATransportSwitchDropsTheUSBFrame() {
        let adb = FakeAdb()
        adb.respond(containing: ["version"], with: FakeAdb.ok("Android Debug Bridge version 1.0.41\n"))
        let controller = makeController(adb: adb, pipeline: FakePipelineControl())
        controller.start()
        waitForStatus(controller) { $0 == .noDevice }
        guard let usb = controller.source as? MirrorSource else { return XCTFail("the USB source is a MirrorSource") }
        usb.publish(FrameDiffEngageHostedTests.makeBuffer(), ptsUs: 1)
        XCTAssertNotNil(controller.latestFrameForSave())
        switchTransport(controller, to: .wifiStream)
        XCTAssertNil(controller.latestFrameForSave(), "the Wi-Fi slot holds nothing yet")
        switchTransport(controller, to: .usb)
        XCTAssertNil(controller.latestFrameForSave(), "the USB frame from before the switch is not saved")
        XCTAssertNil(controller.activeSource.latest(), "nor shown")
        controller.stop()
    }

    /// USB-A2/B3, the Wi-Fi half: the Wi-Fi slot kept its last frame across a switch to USB, so a later switch back
    /// showed and saved that old picture before any new stream. Before the fix both reads returned the buffer.
    func testASwitchToUSBDropsTheWifiFrame() {
        let adb = FakeAdb()
        adb.respond(containing: ["version"], with: FakeAdb.ok("Android Debug Bridge version 1.0.41\n"))
        let controller = makeController(adb: adb, pipeline: FakePipelineControl())
        controller.start()
        waitForStatus(controller) { $0 == .noDevice }
        switchTransport(controller, to: .wifiStream)
        controller.wifiSource.publishForTesting(FrameDiffEngageHostedTests.makeBuffer(), ptsUs: 1)
        XCTAssertNotNil(controller.latestFrameForSave(), "the Wi-Fi frame is the active picture")
        switchTransport(controller, to: .usb)
        XCTAssertNil(controller.wifiSource.latest(), "dropped on the switch to USB")
        switchTransport(controller, to: .wifiStream)
        XCTAssertNil(controller.latestFrameForSave(), "the old Wi-Fi frame is not saved")
        XCTAssertNil(controller.activeSource.latest(), "nor shown")
        controller.stop()
    }

    /// USB-A3/B5: a `.watching` hop queued behind `endSession` set the pen present with no watcher, which disabled
    /// frame-difference engage until the next session. The control queue is held while the probe answers so the hop
    /// lands after `stop()`. Before the fix `penWatcherPresent()` was true at the end.
    func testAStaleWatchingFromAStoppedPenWatcherIsIgnored() {
        let adb = FakeAdb()
        adb.respond(containing: ["devices"], with: FakeAdb.ok(MirrorControllerTests.usbDaylight))
        let probeEntered = DispatchSemaphore(value: 0)
        let probeGate = DispatchSemaphore(value: 0)
        adb.respond { args in
            guard args.contains("-pl") else { return nil }
            probeEntered.signal()
            _ = probeGate.wait(timeout: .now() + 10)
            return FakeAdb.ok(StylusFixtures.listingWithPen)
        }
        var settings = Settings.defaults
        settings.mirrorTransport = .wifiStream
        let controller = makeController(settings: settings, adb: adb, pipeline: FakePipelineControl())
        let spawned = expectation(description: "getevent spawned")
        adb.onSpawn = { args, _ in if args.contains("-lt") { spawned.fulfill() } }
        controller.start()
        XCTAssertEqual(probeEntered.wait(timeout: .now() + 8), .success, "the pen probe started")
        let controlGate = DispatchSemaphore(value: 0)
        controller.queue.async { _ = controlGate.wait(timeout: .now() + 10) }
        controller.stop()
        probeGate.signal()
        wait(for: [spawned], timeout: 8)
        controlGate.signal()
        // The watcher's stop runs on the stylus queue after the block that queued `.watching`, so once the child is
        // terminated that hop is on the control queue; one drain runs it.
        XCTAssertTrue(waitUntil(10) { adb.spawned.allSatisfy { !$0.isRunning } }, "the stopped watcher ends its child")
        controller.queue.sync {}
        XCTAssertFalse(controller.wifiSource.penWatcherPresent(), "a stopped watcher never marks the pen present")
    }

    /// USB-B4: in the Wi-Fi transport a DC-1 also listed over TCP (listed first) hid the USB one, so no pen watcher
    /// started. Before the fix nothing was spawned.
    func testWifiTransportWatchesTheUSBPenWhenATCPDaylightIsListedFirst() {
        let adb = FakeAdb()
        adb.respond(containing: ["devices"], with: FakeAdb.ok("192.168.1.40:5555 device product:daylight model:Daylight_DC_1 device:dc1 transport_id:2\n" + MirrorControllerTests.usbDaylight))
        adb.respond(containing: ["getevent", "-pl"], with: FakeAdb.ok(StylusFixtures.listingWithPen))
        var settings = Settings.defaults
        settings.mirrorTransport = .wifiStream
        let controller = makeController(settings: settings, adb: adb, pipeline: FakePipelineControl())
        let spawned = expectation(description: "getevent on the USB serial")
        spawned.assertForOverFulfill = false
        adb.onSpawn = { args, _ in
            if args == ["-s", "JP0001", "shell", "-T", "getevent", "-lt", "/dev/input/event3"] { spawned.fulfill() }
        }
        controller.start()
        wait(for: [spawned], timeout: 8)
        XCTAssertFalse(adb.calls.contains { $0.contains("192.168.1.40:5555") && $0.contains("getevent") }, "never the TCP device")
        controller.stop()
    }

    /// USB-B6 and DIFF-B4: a DC-1 without a pen node in the Wi-Fi transport. Row 28 ("auto-engage does not work") was
    /// raised although frame difference engages there; row 37 is the one that applies, raised once the probe settled.
    /// Before the fix row 28 was in the list.
    func testWifiTransportWithoutAPenNodeRaisesRow37NotRow28() {
        let adb = FakeAdb()
        adb.respond(containing: ["devices"], with: FakeAdb.ok(MirrorControllerTests.usbDaylight))
        adb.respond(containing: ["getevent", "-pl"], with: FakeAdb.ok(StylusFixtures.listingWithoutPen))
        var settings = Settings.defaults
        settings.mirrorTransport = .wifiStream
        let controller = makeController(settings: settings, adb: adb, pipeline: FakePipelineControl())
        let failures = Locked<[FailureText.Case]>([])
        let row37 = expectation(description: "row 37")
        controller.onFailure = { failure, _ in
            failures.withLock { $0.append(failure) }
            if failure == .wifiStreamFrameDiffEngage { row37.fulfill() }
        }
        let probed = expectation(description: "probe answered")
        probed.assertForOverFulfill = false
        controller.onLog = { line in if line.contains("getevent -pl devices:") { probed.fulfill() } }
        controller.start()
        decodeOneWifiFrame(controller)
        wait(for: [probed], timeout: 8)
        controller.stylusQueue.sync {}   // the probe result block, which queued the status hop, finished
        controller.queue.sync {}         // the status hop ran
        wait(for: [row37], timeout: 8)
        XCTAssertFalse(failures.withLock { $0 }.contains(.noPenDevice), "no row 28 in the Wi-Fi transport")
        XCTAssertEqual(failures.withLock { $0 }.filter { $0 == .wifiStreamFrameDiffEngage }.count, 1)
        controller.stop()
    }

    /// DIFF-B4: a decoded Wi-Fi frame that won the race against the USB pen probe raised row 37 ("plug in USB") with
    /// the cable in, and nothing ever withdrew it. Now it waits for the probe and is resolved when the pen watcher
    /// starts. Before the fix row 37 was raised at once (and `onResolve` did not exist).
    func testRow37WaitsForThePenProbeAndIsResolvedWhenThePenWatcherStarts() {
        let adb = FakeAdb()
        adb.respond(containing: ["devices"], with: FakeAdb.ok(MirrorControllerTests.usbDaylight))
        let probeEntered = DispatchSemaphore(value: 0)
        let probeGate = DispatchSemaphore(value: 0)
        adb.respond { args in
            guard args.contains("-pl") else { return nil }
            probeEntered.signal()
            _ = probeGate.wait(timeout: .now() + 10)
            return FakeAdb.ok(StylusFixtures.listingWithPen)
        }
        var settings = Settings.defaults
        settings.mirrorTransport = .wifiStream
        let controller = makeController(settings: settings, adb: adb, pipeline: FakePipelineControl())
        let failures = Locked<[FailureText.Case]>([])
        controller.onFailure = { failure, _ in failures.withLock { $0.append(failure) } }
        let resolved = expectation(description: "row 37 resolved")
        resolved.assertForOverFulfill = false
        controller.onResolve = { cases in if cases.contains(.wifiStreamFrameDiffEngage) { resolved.fulfill() } }
        controller.start()
        XCTAssertEqual(probeEntered.wait(timeout: .now() + 8), .success, "the pen probe started")
        decodeOneWifiFrame(controller)
        controller.queue.sync {}   // the source's row 37 hop ran
        XCTAssertFalse(failures.withLock { $0 }.contains(.wifiStreamFrameDiffEngage), "held while the probe runs")
        probeGate.signal()
        wait(for: [resolved], timeout: 8)
        XCTAssertTrue(controller.wifiSource.penWatcherPresent())
        controller.queue.sync {}
        XCTAssertFalse(failures.withLock { $0 }.contains(.wifiStreamFrameDiffEngage), "the pen watcher started: never raised")
        controller.stop()
    }

    /// DIFF-A5/B5: a getevent that ended (and could not be restarted) left the pen marked present, so frame difference
    /// stayed suppressed with no pen events. Before the fix `penWatcherPresent()` stayed true and the first wait timed
    /// out. The restarted child makes the pen the engage source again.
    func testADeadGeteventNoLongerSuppressesFrameDifference() {
        let adb = FakeAdb()
        adb.respond(containing: ["devices"], with: FakeAdb.ok(MirrorControllerTests.usbDaylight))
        adb.respond(containing: ["getevent", "-pl"], with: FakeAdb.ok(StylusFixtures.listingWithPen))
        var settings = Settings.defaults
        settings.mirrorTransport = .wifiStream
        let controller = makeController(settings: settings, adb: adb, pipeline: FakePipelineControl())
        let spawned = expectation(description: "getevent spawned")
        spawned.assertForOverFulfill = false
        adb.onSpawn = { args, _ in if args.contains("-lt") { spawned.fulfill() } }
        controller.start()
        wait(for: [spawned], timeout: 8)
        XCTAssertTrue(waitUntil(8) { controller.wifiSource.penWatcherPresent() }, "the pen is the engage source")
        guard let child = adb.spawned.first(where: { $0.args.contains("-lt") }) else { return XCTFail("no getevent child") }
        adb.canSpawn = false
        child.exit(1)
        XCTAssertTrue(waitUntil(10) { !controller.wifiSource.penWatcherPresent() }, "no getevent runs: frame difference engages")
        adb.canSpawn = true
        XCTAssertTrue(waitUntil(20) { controller.wifiSource.penWatcherPresent() }, "the restarted getevent is the engage source again")
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
