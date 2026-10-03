import AppKit
import AVFoundation
import DaylightKit
import XCTest
@testable import Daylight

final class LaunchArgumentsTests: XCTestCase {
    func testFlags() {
        XCTAssertEqual(LaunchArguments.parse(["Daylight"]), LaunchArguments())
        let parsed = LaunchArguments.parse(["Daylight", "--self-test", "--perf-log", "--latency-probe", "--port", "7790"])
        XCTAssertTrue(parsed.selfTest)
        XCTAssertTrue(parsed.perfLog)
        XCTAssertTrue(parsed.latencyProbe)
        XCTAssertEqual(parsed.port, 7790)
        XCTAssertEqual(LaunchArguments.parse(["Daylight", "--port=7791"]).port, 7791)
        XCTAssertNil(LaunchArguments.parse(["Daylight", "--port", "notanumber"]).port)
    }
}

final class HotkeysTests: XCTestCase {
    func testDefaultsAreSpec14() {
        let defaults = Settings.defaults.hotkeys
        XCTAssertEqual(defaults[.whiteboardOnly]?.keyCode, 0x0D)
        XCTAssertEqual(defaults[.studioSplit]?.keyCode, 0x02)
        XCTAssertEqual(defaults[.keep]?.keyCode, 0x28)
        XCTAssertEqual(defaults[.clear]?.keyCode, 0x08)
        XCTAssertEqual(defaults[.camera]?.keyCode, 0x35)
        let chord: UInt32 = (1 << 8) | (1 << 11) | (1 << 12)
        for action in HotkeyAction.allCases { XCTAssertEqual(defaults[action]?.modifiers, chord) }
        XCTAssertEqual(Hotkeys.describe(defaults[.whiteboardOnly]!), "Ctrl+Opt+Cmd+W")
        XCTAssertEqual(Hotkeys.describe(defaults[.camera]!), "Ctrl+Opt+Cmd+Esc")
        XCTAssertEqual(Hotkeys.title(.keep), "Keep whiteboard")
    }

    func testIDsRoundTripAndSignature() {
        for action in HotkeyAction.allCases {
            XCTAssertEqual(Hotkeys.action(forID: Hotkeys.id(for: action)), action)
        }
        XCTAssertNil(Hotkeys.action(forID: 0))
        XCTAssertNil(Hotkeys.action(forID: 99))
        XCTAssertEqual(Hotkeys.fourCharCode("dylt"), 0x64796C74)
        XCTAssertEqual(Hotkeys.alreadyUsedStatus, -9878)
        let hotkeys = Hotkeys(settings: Settings.defaults)
        XCTAssertEqual(hotkeys.bindings.count, 5)
        XCTAssertTrue(hotkeys.conflicts.isEmpty)
    }

    func testDuplicateChordIsReportedAsAnotherDaylightAction() {
        var bindings = Settings.defaults.hotkeys
        XCTAssertNil(Hotkeys.duplicate(of: .clear, binding: bindings[.clear]!, in: bindings), "the defaults are distinct")
        bindings[.clear] = bindings[.keep]
        XCTAssertEqual(Hotkeys.duplicate(of: .clear, binding: bindings[.clear]!, in: bindings), .keep)
        XCTAssertEqual(Hotkeys.conflictText(.duplicate(.clear, .keep)), "Already used by Keep whiteboard")
        XCTAssertEqual(Hotkeys.conflictText(.alreadyUsed(.clear)), "Already used by another app")
        XCTAssertEqual(Hotkeys.exclusiveOption, 1, "kEventHotKeyExclusive: without it no cross-app conflict is ever reported")
    }

    func testRecorderModifierMapping() {
        XCTAssertEqual(HotkeyRecorder.carbonModifiers([.command, .option, .control]), HotkeyBinding.defaultModifiers)
        XCTAssertEqual(HotkeyRecorder.carbonModifiers([.shift]), 1 << 9)
        XCTAssertEqual(HotkeyRecorder.carbonModifiers([]), 0)
    }

    /// Settings names a recorded chord the way the menu and onboarding do (it used to read "Key 7" for X).
    func testRecorderNamesEveryKeyLikeTheMenu() {
        let x = HotkeyBinding(keyCode: 0x07, modifiers: HotkeyBinding.defaultModifiers)
        XCTAssertEqual(HotkeyRecorder.describe(x), "Ctrl+Opt+Cmd+X")
        XCTAssertEqual(HotkeyRecorder.describe(HotkeyBinding(keyCode: 0x31, modifiers: HotkeyBinding.cmdKey)), "Cmd+Space")
        XCTAssertEqual(HotkeyRecorder.describe(HotkeyBinding(keyCode: 0x00, modifiers: HotkeyBinding.defaultModifiers)), "Ctrl+Opt+Cmd+A")
    }
}

final class OnboardingStepsTests: XCTestCase {
    func testLocationRule() {
        XCTAssertFalse(OnboardingSteps.locationProblem(bundlePath: "/Applications/Daylight.app"))
        XCTAssertTrue(OnboardingSteps.locationProblem(bundlePath: "/Users/mike/Downloads/Daylight.app"))
        XCTAssertTrue(OnboardingSteps.locationProblem(bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/Daylight.app"))
    }

    func testUnsignedBuildBlocksTheExtensionStepWithRow2Text() {
        let rows = OnboardingSteps.rows(OnboardingSteps.Inputs(bundlePath: "/Applications/Daylight.app", signed: false))
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows[0].detail, FailureText.sentence(.unsignedBuild))
        XCTAssertEqual(rows[0].detail, "This is an unsigned test build. The virtual camera cannot be installed on this Mac. Use Daylight > Preview window to see the output.")
        XCTAssertEqual(rows[2].status, .blocked)
        XCTAssertTrue(OnboardingSteps.canFinish(rows), "an unsigned build can still finish onboarding")
    }

    func testMisplacedSignedBuildShowsRow1AndDisablesInstall() {
        var inputs = OnboardingSteps.Inputs(bundlePath: "/Users/mike/Downloads/Daylight.app", signed: true)
        inputs.camera = .granted
        inputs.cameraName = "FaceTime HD Camera"
        let rows = OnboardingSteps.rows(inputs)
        XCTAssertEqual(rows[0].detail, "Move Daylight to your Applications folder, then open it from there.")
        XCTAssertEqual(rows[0].failure, .notInApplications)
        XCTAssertEqual(rows[2].status, .blocked)
        XCTAssertFalse(OnboardingSteps.canFinish(rows))
    }

    func testExtensionStatesProduceTheRightRows() {
        var inputs = OnboardingSteps.Inputs(bundlePath: "/Applications/Daylight.app", signed: true)
        inputs.camera = .granted
        inputs.cameraName = "Cam"
        inputs.extensionState = .awaitingApproval
        var rows = OnboardingSteps.rows(inputs)
        XCTAssertEqual(rows[2].detail, "Approve 'Daylight Camera' in System Settings > General > Login Items & Extensions > Camera Extensions, then click Check again.")
        inputs.modernApprovalPath = false
        rows = OnboardingSteps.rows(inputs)
        XCTAssertTrue(rows[2].detail.contains("Privacy & Security > Security"))
        inputs.extensionState = .needsReboot
        XCTAssertEqual(OnboardingSteps.rows(inputs)[2].detail, "Restart your Mac once to finish installing Daylight Camera.")
        inputs.extensionState = .installed
        XCTAssertEqual(OnboardingSteps.rows(inputs)[2].detail, "Daylight Camera is installed but not found yet. Retrying...")
        inputs.extensionState = .connected
        XCTAssertEqual(OnboardingSteps.rows(inputs)[2].status, .done)
        inputs.extensionState = .failed(.extensionSignatureInvalid, "")
        XCTAssertEqual(OnboardingSteps.rows(inputs)[2].detail, "macOS refused the extension's signature. This build is not notarized.")
        inputs.camera = .denied
        XCTAssertEqual(OnboardingSteps.rows(inputs)[1].detail, "Camera access is off for Daylight.")
        inputs.camera = .granted
        inputs.cameraName = nil
        XCTAssertEqual(OnboardingSteps.rows(inputs)[1].failure, .noWebcam)
        inputs.clientsPending = 1
        XCTAssertEqual(OnboardingSteps.rows(inputs)[4].status, .active)
        inputs.clientsPending = 0
        inputs.clientsAllowed = 1
        XCTAssertEqual(OnboardingSteps.rows(inputs)[3].status, .done)
        XCTAssertEqual(OnboardingSteps.rows(inputs)[4].status, .done)
    }
}

/// APPA-01: Done closes the Welcome window for real, so its 1 s poll (adb, AVFoundation, SMAppService) stops; it used
/// to only order the window out, `windowWillClose` never ran and the poll lived for the whole session.
final class OnboardingWindowTests: XCTestCase {
    func testCloseStopsThePoll() {
        guard Thread.isMainThread else { return }
        let model = OnboardingModel(inputs: OnboardingSteps.Inputs(bundlePath: "/Applications/Daylight.app", signed: true))
        let controller = OnboardingWindowController(model: model)
        var closed = false
        controller.onClose = { closed = true }
        controller.show()
        let polled = expectation(description: "polled while open")
        var polls = 0
        controller.startPolling(every: 0.05) {
            polls += 1
            if polls == 1 { polled.fulfill() }
        }
        wait(for: [polled], timeout: 10)
        XCTAssertTrue(controller.isPolling)
        controller.close()   // what Done's `actions.finish` calls
        XCTAssertTrue(closed, "windowWillClose ran")
        XCTAssertFalse(controller.isPolling, "the poll stops with the window")
        XCTAssertFalse(controller.isVisible)
        controller.show()
        controller.startPolling(every: 1) {}
        XCTAssertTrue(controller.isPolling, "Set up again reopens and polls again")
        controller.close()
        XCTAssertFalse(controller.isPolling)
    }
}

/// APPA-04: one Daylight at a time. The /Applications copy replaces a misplaced one; any other second copy defers to
/// the running one. (Whether LaunchServices starts a second copy from another path is UNVERIFIED on a Mac.)
final class AppDelegateInstanceTests: XCTestCase {
    func testSecondCopyDecision() {
        typealias Copy = AppDelegate.RunningCopy
        let installed = "/Applications/Daylight.app"
        let translocated = "/private/var/folders/x/AppTranslocation/ABC/d/Daylight.app"
        let downloads = "/Users/mike/Downloads/Daylight.app"
        let me = Copy(pid: 10, bundlePath: installed)
        XCTAssertEqual(AppDelegate.instanceDecision(selfPID: 10, selfPath: installed, running: []), .proceed)
        XCTAssertEqual(AppDelegate.instanceDecision(selfPID: 10, selfPath: installed, running: [me]), .proceed, "only this process")
        XCTAssertEqual(AppDelegate.instanceDecision(selfPID: 10, selfPath: installed, running: [me, Copy(pid: 7, bundlePath: translocated)]), .terminateOthers([7]))
        XCTAssertEqual(AppDelegate.instanceDecision(selfPID: 10, selfPath: installed, running: [Copy(pid: 7, bundlePath: downloads), me, Copy(pid: 8, bundlePath: translocated)]), .terminateOthers([7, 8]))
        XCTAssertEqual(AppDelegate.instanceDecision(selfPID: 10, selfPath: translocated, running: [Copy(pid: 7, bundlePath: installed), Copy(pid: 10, bundlePath: translocated)]), .activateOtherAndQuit(7), "a misplaced copy defers")
        XCTAssertEqual(AppDelegate.instanceDecision(selfPID: 10, selfPath: installed, running: [me, Copy(pid: 7, bundlePath: installed)]), .activateOtherAndQuit(7), "same path twice")
        XCTAssertEqual(AppDelegate.instanceDecision(selfPID: 10, selfPath: installed, running: [me, Copy(pid: 7, bundlePath: nil)]), .activateOtherAndQuit(7), "an unknown path is never quit")
        XCTAssertEqual(AppDelegate.instanceDecision(selfPID: 10, selfPath: installed, running: [me, Copy(pid: 7, bundlePath: translocated), Copy(pid: 8, bundlePath: "/Applications/Other/Daylight.app")]), .activateOtherAndQuit(8), "defer to the well-placed copy")
        XCTAssertTrue(AppDelegate.isUnderTest, "the hosted test run skips the guard")
    }
}

/// SPEC 7: the menu's "Whiteboard now" engages without drawing; only the hotkeys toggle.
final class AppModelMenuTests: XCTestCase {
    func testWhiteboardNowFromTheMenuNeverReturnsToTheCamera() {
        XCTAssertEqual(AppModel.whiteboardNowEvent(.studioSplit, snapshot: GovernorOutput(state: .passthrough)), .layoutHotkey(.studioSplit))
        XCTAssertEqual(AppModel.whiteboardNowEvent(.whiteboardOnly, snapshot: GovernorOutput(state: .live, layout: .studioSplit)), .layoutHotkey(.whiteboardOnly), "another layout switches the board")
        XCTAssertEqual(AppModel.whiteboardNowEvent(.studioSplit, snapshot: GovernorOutput(state: .live, layout: .studioSplit)), .engage, "the showing layout only resets the idle timer")
        XCTAssertEqual(AppModel.whiteboardNowEvent(.studioSplit, snapshot: GovernorOutput(state: .engaging, layout: .studioSplit)), .engage)
        XCTAssertEqual(AppModel.whiteboardNowEvent(.studioSplit, snapshot: GovernorOutput(state: .returning, layout: .studioSplit)), .engage, "engage during RETURNING re-engages (SPEC D38)")
    }

    /// APPA-02: the red banner follows the failure that set it and clears when the owner fixes it; row 16 is the port
    /// line only, never a second banner with the same sentence.
    func testBannerClearsWhenTheFailureResolves() {
        let model = AppModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "banner-\(UUID().uuidString)")!, unsignedBuild: false), signed: true, version: "0", build: "0")
        model.noteFailure(.noWebcam, [])
        XCTAssertEqual(model.banner, "No camera found")
        model.setCameraPresent(true)
        XCTAssertNil(model.banner, "row 4 ends when a camera appears")

        model.noteFailure(.cameraAccessDenied, [])
        XCTAssertEqual(model.banner, "Camera access is off for Daylight.")
        model.setCameraPresent(true)
        XCTAssertNotNil(model.banner, "an unrelated resolution leaves it")
        model.noteCameraGranted()
        XCTAssertNil(model.banner)

        model.noteFailure(.extensionNeedsApproval, ["System Settings"])
        XCTAssertNotNil(model.banner)
        model.setExtensionState(.awaitingApproval)
        XCTAssertNotNil(model.banner)
        model.setExtensionState(.installed)
        XCTAssertNil(model.banner, "rows 6 to 12b end once the extension is installed")
        model.noteFailure(.extensionNeedsReboot, [])
        model.setExtensionState(.connected)
        XCTAssertNil(model.banner)

        model.noteFailure(.cameraAccessDenied, [])
        model.noteFailure(.noWebcam, [])
        model.noteCameraGranted()
        XCTAssertEqual(model.banner, "No camera found", "resolving an older failure keeps the newer banner")

        model.clearBanner()
        model.noteFailure(.sinkStreamLayout, [])
        XCTAssertEqual(model.visibleBanner, model.banner)
        model.setSinkStatus(.error(.sinkStreamLayout, ""))
        XCTAssertNotNil(model.banner)
        XCTAssertNil(model.visibleBanner, "the status line already shows that sentence")

        model.clearBanner()
        model.noteFailure(.portInUse, ["7788", "7789"])
        XCTAssertNil(model.banner, "the port line already says it")
        XCTAssertEqual(model.recentFailures.last, "Port 7788 is in use. Daylight is using 7789.", "still in Diagnostics")
    }

    func testCameraPermissionFollowsTheTCCStatus() {
        XCTAssertEqual(AppDelegate.cameraPermission(.authorized), .granted)
        XCTAssertEqual(AppDelegate.cameraPermission(.denied), .denied)
        XCTAssertEqual(AppDelegate.cameraPermission(.restricted), .denied)
        XCTAssertEqual(AppDelegate.cameraPermission(.notDetermined), .notDetermined)
    }
}

/// SPEC B6: every failure row has one case; the rows B shows map to their exact sentences.
final class FailureCoverageTests: XCTestCase {
    func testFortyNineCasesAndTheRowsBTriggers() {
        XCTAssertEqual(FailureText.Case.allCases.count, 49)
        for c in FailureText.Case.allCases where c != .bonjourRenamed {
            XCTAssertFalse(FailureText.sentence(c).isEmpty, "\(c) has owner text")
            XCTAssertFalse(FailureText.logLine(c).isEmpty)
        }
        XCTAssertEqual(FailureText.sentence(.cameraAccessDenied), "Camera access is off for Daylight.")
        XCTAssertEqual(FailureText.sentence(.noWebcam), "No camera found")
        XCTAssertEqual(FailureText.sentence(.portInUse, ["7788", "7789"]), "Port 7788 is in use. Daylight is using 7789.")
        XCTAssertEqual(FailureText.sentence(.portInUse, ["7788"]), "Port 7788 is in use. Quit the other app or change the port in Settings.")
        XCTAssertEqual(FailureText.sentence(.nobodyConnected), "Nobody has connected yet. Same Wi-Fi? Office networks often block this: use USB or Tailscale.")
        XCTAssertEqual(FailureText.sentence(.allowDismissed, ["Mike's DC-1"]), "Allow Mike's DC-1")
        XCTAssertEqual(FailureText.sentence(.saveFailed, ["disk full"]), "Could not save the whiteboard: disk full")
        XCTAssertEqual(FailureText.sentence(.captureIdle), "Webcam capture is paused because no app is viewing Daylight Camera (LED off). It restarts within a second when a call starts.")
        XCTAssertEqual(FailureText.logLine(.captureIdle), "failure.captureIdle (row 33): capture stopped: viewers=0 preview=hidden")
        XCTAssertEqual(AllowClientPanel.prompt(label: "Mike's DC-1", address: "192.168.1.40"), "Allow 'Mike's DC-1' to draw on Daylight Camera? It connected from 192.168.1.40.")
    }

    func testSpecTimeoutsAreTheConstantsTheAppUses() {
        XCTAssertEqual(AllowClientPanel.autoDismissSeconds, 60, "D44")
        XCTAssertEqual(AppDelegate.quitSaveTimeout, 2, "SPEC 12")
        XCTAssertEqual(AppModel.nobodyConnectedSeconds, 60, "row 18")
        XCTAssertEqual(SessionFiles.sessionGapSeconds, 600, "10-minute gap")
    }
}

final class AllowClientPanelTests: XCTestCase {
    func testPanelIsNonActivatingAndFloating() {
        guard Thread.isMainThread else { return }
        let panel = AllowClientPanel()
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "SPEC B5")
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.isVisible)
    }
}

final class DiagnosticsReportTests: XCTestCase {
    func testReportMentionsEveryFact() {
        var facts = DiagnosticsReport.Facts()
        facts.version = "0.1.0"
        facts.build = "12"
        facts.signed = false
        facts.extensionState = "unsignedBuild"
        facts.sinkStatus = "unsigned build (preview only)"
        facts.pipeline.captureIdleReason = "viewers=0 preview=hidden"
        facts.pipeline.firstFrame = "1920x1080 BGRA iosurface=true"
        facts.port = 7789
        facts.addresses = [LocalAddresses.Entry(ip: "100.1.2.3", interface: "utun3", kind: .tailscale)]
        facts.clients = ["Mike's DC-1 (web) 192.168.1.40 allowed active"]
        facts.logLines = ["[app] hello"]
        let text = DiagnosticsReport.text(facts)
        XCTAssertTrue(text.contains("Daylight 0.1.0 (12) signed=false"))
        XCTAssertTrue(text.contains(FailureText.sentence(.captureIdle)))
        XCTAssertTrue(text.contains("100.1.2.3 (utun3, Tailscale)"))
        XCTAssertTrue(text.contains("port=7789"))
        XCTAssertTrue(text.contains("[app] hello"))
        XCTAssertTrue(text.contains("Mike's DC-1 (web)"))
    }
}

/// "Set up over USB" failures: the adb rows 21 to 23 when the tablet is the problem, the real reason otherwise
/// (an install that failed must not read "Is USB debugging on?").
final class USBSetupFailureTests: XCTestCase {
    func testFailuresMapOntoRows21To23OrTheBanner() {
        XCTAssertEqual(AppDelegate.usbSetupFailure(AdbError.noDevice)?.0, .adbNoDevice)
        XCTAssertEqual(AppDelegate.usbSetupFailure(AdbError.deviceNotReady(serial: "JP0001", state: "unauthorized"))?.0, .adbUnauthorized)
        XCTAssertEqual(AppDelegate.usbSetupFailure(AdbError.deviceNotReady(serial: "JP0001", state: "offline"))?.0, .adbOffline)
        XCTAssertEqual(AppDelegate.usbSetupFailure(AdbError.deviceNotReady(serial: "JP0001", state: "recovery"))?.0, .adbNoDevice)
        let install = AdbError.failed(status: 1, detail: "INSTALL_FAILED_OLDER_SDK", command: "-s JP0001 install -r -d x.apk")
        XCTAssertNil(AppDelegate.usbSetupFailure(install))
        XCTAssertNil(AppDelegate.usbSetupFailure(AdbError.executableMissing("/x/adb")))
        XCTAssertNil(AppDelegate.usbSetupFailure(AdbError.timeout(command: "install")))
        XCTAssertEqual(AppDelegate.describeUSBSetupError(install), "adb -s JP0001 install -r -d x.apk failed: INSTALL_FAILED_OLDER_SDK")
        XCTAssertEqual(AppDelegate.describeUSBSetupError(AdbError.failed(status: 3, detail: "", command: "reverse")), "adb reverse failed: exit 3")
        XCTAssertEqual(AppModel.usbSetupFailedText("adb install failed"), "Set up over USB failed: adb install failed")
    }
}
