import Foundation
import XCTest
import DaylightKit

/// Acceptance A8: `Settings.validated()` clamps every range of SPEC section 11; defaults; JSON tolerance.
final class SettingsTests: XCTestCase {
    func testDefaultsMatchSpec11() {
        let d = Settings.defaults
        XCTAssertFalse(d.onboardingDone)
        XCTAssertEqual(d.onboardingVersion, 1)
        XCTAssertNil(d.cameraUniqueID)
        XCTAssertEqual(d.inkSource, .web)
        XCTAssertEqual(d.preferredLayout, .studioSplit)
        XCTAssertEqual(d.holdMode, .auto)
        XCTAssertTrue(d.autoEngage)
        XCTAssertEqual(d.idleTimeoutSeconds, 90)
        XCTAssertEqual(d.preWarningSeconds, 5)
        XCTAssertEqual(d.springK, 1200)
        XCTAssertFalse(d.engageOnEraser)
        XCTAssertEqual(d.port, 7788)
        XCTAssertNil(d.bonjourName)
        XCTAssertTrue(d.trustLoopback)
        XCTAssertEqual(d.mirrorPinClearMode, .both)
        XCTAssertEqual(d.sideButtonDoublePressMs, 400)
        XCTAssertEqual(d.sideButtonLongPressMs, 700)
        XCTAssertFalse(d.sideButtonSwap)
        XCTAssertEqual(d.mirrorCropInsetsPortrait, CropInsets(top: 96, left: 0, right: 0, bottom: 0))
        XCTAssertEqual(d.mirrorCropInsetsLandscape, CropInsets(top: 72, left: 0, right: 0, bottom: 0))
        XCTAssertEqual(d.pillStripHeight, 96)
        XCTAssertEqual(d.mirrorPillsPosition, .top)
        XCTAssertEqual(d.mirrorMaxSize, 1600)
        XCTAssertEqual(d.mirrorBitRate, 8_000_000)
        XCTAssertEqual(d.mirrorMaxFps, 30)
        XCTAssertNil(d.mirrorDeviceSerial)
        XCTAssertEqual(d.adbServerMode, .auto)
        XCTAssertEqual(d.adbPrivatePort, 27180)
        XCTAssertFalse(d.mirrorOverWiFi)
        XCTAssertEqual(d.viewerIdleStopSeconds, 60)
        XCTAssertNil(d.saveDirectory)
        XCTAssertTrue(d.saveStrokesJSON)
        XCTAssertEqual(d.autosaveSeconds, 60)
        XCTAssertFalse(d.previewOnLaunch)
        XCTAssertTrue(d.previewFloats)
        XCTAssertFalse(d.frameReuse)
        XCTAssertFalse(d.deadlineIdle)
        XCTAssertFalse(d.perfLog)
        XCTAssertEqual(Settings.userDefaultsKey, "com.twelve.daylight.settings.v1")
        XCTAssertEqual(Settings.lowBandwidthMirror.maxSize, 1200)
        XCTAssertEqual(Settings.lowBandwidthMirror.bitRate, 4_000_000)
        XCTAssertEqual(Settings.lowBandwidthMirror.maxFps, 24)
        XCTAssertEqual(d, d.validated(), "the defaults are already valid")
    }

    func testDefaultHotkeysAreCtrlOptCmdWDKCEsc() {
        let h = Settings.defaults.hotkeys
        let mods: UInt32 = (1 << 8) | (1 << 11) | (1 << 12)
        XCTAssertEqual(mods, 6400)
        XCTAssertEqual(h[.whiteboardOnly], HotkeyBinding(keyCode: 0x0D, modifiers: mods))
        XCTAssertEqual(h[.studioSplit], HotkeyBinding(keyCode: 0x02, modifiers: mods))
        XCTAssertEqual(h[.keep], HotkeyBinding(keyCode: 0x28, modifiers: mods))
        XCTAssertEqual(h[.clear], HotkeyBinding(keyCode: 0x08, modifiers: mods))
        XCTAssertEqual(h[.camera], HotkeyBinding(keyCode: 0x35, modifiers: mods))
        XCTAssertEqual(h[.overlay], HotkeyBinding(keyCode: 0x1F, modifiers: mods), "Ctrl+Opt+Cmd+O (SPEC 14)")
        XCTAssertEqual(HotkeyBinding.keyO, 0x1F)
        XCTAssertEqual(h.count, HotkeyAction.allCases.count)
        XCTAssertEqual(HotkeyAction.allCases.map { $0.rawValue }, ["whiteboardOnly", "studioSplit", "keep", "clear", "camera", "overlay"], "new actions are appended so hotkey ids 1 to 5 stay")
    }

    func testValidatedClampsEveryRange() {
        var s = Settings.defaults
        s.idleTimeoutSeconds = 5
        s.preWarningSeconds = -3
        s.springK = 10
        s.viewerIdleStopSeconds = 1
        s.autosaveSeconds = 2
        s.port = 80
        var v = s.validated()
        XCTAssertEqual(v.idleTimeoutSeconds, 15)
        XCTAssertEqual(v.preWarningSeconds, 0)
        XCTAssertEqual(v.springK, 300)
        XCTAssertEqual(v.viewerIdleStopSeconds, 10)
        XCTAssertEqual(v.autosaveSeconds, 15)
        XCTAssertEqual(v.port, 7788, "a privileged port falls back to the default")

        s.idleTimeoutSeconds = 100_000
        s.preWarningSeconds = 99
        s.springK = 1e9
        s.viewerIdleStopSeconds = 100_000
        s.autosaveSeconds = 100_000
        s.port = 65535
        v = s.validated()
        XCTAssertEqual(v.idleTimeoutSeconds, 600)
        XCTAssertEqual(v.preWarningSeconds, 30)
        XCTAssertEqual(v.springK, 2400)
        XCTAssertEqual(v.viewerIdleStopSeconds, 600)
        XCTAssertEqual(v.autosaveSeconds, 600)
        XCTAssertEqual(v.port, 65535)

        s = Settings.defaults
        s.idleTimeoutSeconds = 20
        s.preWarningSeconds = 30
        v = s.validated()
        XCTAssertEqual(v.preWarningSeconds, 19, "preWarningSeconds <= idleTimeoutSeconds - 1")
        s.idleTimeoutSeconds = 15
        s.preWarningSeconds = 15
        XCTAssertEqual(s.validated().preWarningSeconds, 14)

        s = Settings.defaults
        s.springK = .nan
        XCTAssertEqual(s.validated().springK, 300)
        s.springK = 600
        XCTAssertEqual(s.validated().springK, 600, "in range stays")
        s.port = 1024
        XCTAssertEqual(s.validated().port, 1024)
        s.adbPrivatePort = 5
        XCTAssertEqual(s.validated().adbPrivatePort, 27180)
        s.hotkeys = [:]
        XCTAssertEqual(s.validated().hotkeys, Settings.defaultHotkeys, "missing hotkeys come back as defaults")
        s.hotkeys = [.clear: HotkeyBinding(keyCode: 1, modifiers: 2)]
        XCTAssertEqual(s.validated().hotkeys[.clear], HotkeyBinding(keyCode: 1, modifiers: 2), "custom bindings stay")
        XCTAssertEqual(s.validated().hotkeys[.keep], Settings.defaultHotkeys[.keep])
    }

    /// Mirror over Wi-Fi keys (SPEC 11, PROTOCOL 14.4): defaults, clamps, JSON tolerance and the derived START control.
    func testMirrorStreamKeys() throws {
        let d = Settings.defaults
        XCTAssertEqual(d.mirrorTransport, .usb)
        XCTAssertEqual(d.mirrorStreamMaxSize, 1600)
        XCTAssertEqual(d.mirrorStreamBitRate, 7_000_000)
        XCTAssertEqual(d.mirrorStreamMaxFps, 30)
        XCTAssertEqual(d.mirrorStreamKeyIntervalMs, 2000)
        XCTAssertEqual(d.mirrorDiffThreshold, 0.002)
        XCTAssertEqual(MirrorTransport.allCases, [.usb, .wifiStream])
        XCTAssertEqual(MirrorTransport.usb.label, "USB (adb)")
        XCTAssertEqual(MirrorTransport.wifiStream.label, "Wi-Fi (Daylight Ink screen stream)")

        var s = Settings.defaults
        s.mirrorStreamMaxSize = 100
        s.mirrorStreamBitRate = 5
        s.mirrorStreamMaxFps = 0
        s.mirrorStreamKeyIntervalMs = 10
        s.mirrorDiffThreshold = 0.00001
        var v = s.validated()
        XCTAssertEqual(v.mirrorStreamMaxSize, 320)
        XCTAssertEqual(v.mirrorStreamBitRate, 1_000_000)
        XCTAssertEqual(v.mirrorStreamMaxFps, 1)
        XCTAssertEqual(v.mirrorStreamKeyIntervalMs, 500)
        XCTAssertEqual(v.mirrorDiffThreshold, 0.0005)
        s.mirrorStreamMaxSize = 4000
        s.mirrorStreamBitRate = 50_000_000
        s.mirrorStreamMaxFps = 120
        s.mirrorStreamKeyIntervalMs = 60000
        s.mirrorDiffThreshold = 0.9
        v = s.validated()
        XCTAssertEqual(v.mirrorStreamMaxSize, 1600)
        XCTAssertEqual(v.mirrorStreamBitRate, 8_000_000)
        XCTAssertEqual(v.mirrorStreamMaxFps, 30)
        XCTAssertEqual(v.mirrorStreamKeyIntervalMs, 10000)
        XCTAssertEqual(v.mirrorDiffThreshold, 0.05)
        XCTAssertEqual(v, v.validated())
        s.mirrorDiffThreshold = .nan
        XCTAssertEqual(s.validated().mirrorDiffThreshold, 0.002)

        var custom = Settings.defaults
        custom.mirrorTransport = .wifiStream
        custom.mirrorStreamMaxSize = 1200
        custom.mirrorStreamBitRate = 4_000_000
        custom.mirrorStreamMaxFps = 24
        custom.mirrorStreamKeyIntervalMs = 3000
        custom.mirrorDiffThreshold = 0.01
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(custom)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"mirrorTransport\":\"wifiStream\""), text)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), custom)
        let old = try JSONDecoder().decode(Settings.self, from: Data("{\"mirrorMaxSize\":1200}".utf8))
        XCTAssertEqual(old.mirrorTransport, .usb, "a blob from before the Wi-Fi stream keeps the defaults")
        XCTAssertEqual(old.mirrorStreamBitRate, 7_000_000)

        XCTAssertEqual(Settings.defaults.mirrorStreamStartControl, MirrorStream.Control.start(maxSize: 1600, bitrateBps: 7_000_000, maxFps: 30, keyIntervalMs: 2000))
        XCTAssertEqual(custom.mirrorStreamStartControl, MirrorStream.Control.start(maxSize: 1200, bitrateBps: 4_000_000, maxFps: 24, keyIntervalMs: 3000))
        custom.mirrorStreamMaxSize = 1000
        XCTAssertEqual(custom.mirrorStreamStartControl.maxSize, 992, "rounded down to a multiple of 16")
        XCTAssertEqual(custom.frameDiffEngageConfig.changedFraction, 0.01)
        XCTAssertEqual(Settings.defaults.frameDiffEngageConfig, FrameDiffEngage.Config())
    }

    func testValidatedIsIdempotent() {
        var s = Settings.defaults
        s.idleTimeoutSeconds = 5
        s.preWarningSeconds = 40
        s.springK = 5000
        s.port = 0
        let once = s.validated()
        XCTAssertEqual(once, once.validated())
    }

    func testJSONRoundTripOmitsHoldModeAndKeepsEverythingElse() throws {
        var s = Settings.defaults
        s.holdMode = .camera
        s.inkSource = .native
        s.preferredLayout = .whiteboardOnly
        s.cameraUniqueID = "0x1234"
        s.mirrorDeviceSerial = "JP1234"
        s.saveDirectory = URL(fileURLWithPath: "/tmp/Daylight Camera")
        s.hotkeys[.clear] = HotkeyBinding(keyCode: 9, modifiers: 256)
        s.mirrorCropInsetsPortrait = CropInsets(top: 0, left: 1, right: 2, bottom: 3)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(s)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("holdMode"), "holdMode is never persisted: \(text)")
        XCTAssertTrue(text.contains("\"inkSource\":1"), "enums persist as raw values: \(text)")
        XCTAssertTrue(text.contains("\"preferredLayout\":1"))
        XCTAssertTrue(text.contains("\"mirrorPinClearMode\":\"both\""))
        XCTAssertTrue(text.contains("\"clear\":{\"keyCode\":9,\"modifiers\":256}"), "hotkeys keyed by action name: \(text)")
        XCTAssertTrue(text.contains("\"whiteboardOnly\":{\"keyCode\":13,\"modifiers\":6400}"))
        var decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded.holdMode, .auto, "comes back as auto")
        XCTAssertEqual(decoded.saveDirectory?.path, "/tmp/Daylight Camera")
        var expected = s
        expected.holdMode = .auto
        expected.saveDirectory = nil
        decoded.saveDirectory = nil
        XCTAssertEqual(decoded, expected)
    }

    func testDecodingToleratesMissingAndUnknownKeys() throws {
        let json = "{\"inkSource\":2,\"idleTimeoutSeconds\":120,\"futureKey\":true,\"hotkeys\":{\"keep\":{\"keyCode\":40,\"modifiers\":6400}}}"
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.inkSource, .mirror)
        XCTAssertEqual(s.idleTimeoutSeconds, 120)
        XCTAssertEqual(s.preWarningSeconds, 5, "absent keys keep their defaults")
        XCTAssertEqual(s.port, 7788)
        XCTAssertEqual(s.hotkeys.count, 1)
        XCTAssertEqual(s.validated().hotkeys.count, 6)
        let empty = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, Settings.defaults)
    }

    func testGovernorConfigFromSettings() {
        var s = Settings.defaults
        s.idleTimeoutSeconds = 120
        s.preWarningSeconds = 10
        s.springK = 600
        s.engageOnEraser = true
        s.autoEngage = false
        let c = GovernorConfig(settings: s)
        XCTAssertEqual(c.idleTimeout, 120)
        XCTAssertEqual(c.preWarningLead, 10)
        XCTAssertEqual(c.springK, 600)
        XCTAssertTrue(c.engageOnEraser)
        XCTAssertFalse(c.autoEngage)
        XCTAssertEqual(c.snapBackWindow, 0.080)
        XCTAssertEqual(c.snapBackMaxProgress, 0.15)
        let d = GovernorConfig()
        XCTAssertEqual(d, GovernorConfig(settings: Settings.defaults))
        XCTAssertEqual(d.idleTimeout, 90)
        XCTAssertEqual(d.preWarningLead, 5)
    }

    func testHoldModeHelpers() {
        XCTAssertEqual(HoldMode.split.forcedLayout, .studioSplit)
        XCTAssertEqual(HoldMode.whiteboard.forcedLayout, .whiteboardOnly)
        XCTAssertNil(HoldMode.auto.forcedLayout)
        XCTAssertNil(HoldMode.camera.forcedLayout)
        XCTAssertEqual(InkSource.native.displayName, "Daylight Ink")
        XCTAssertEqual(InkSource.native.jsonName, "native")
        XCTAssertEqual(InkSource.mirror.displayName, "mirror")
        XCTAssertTrue(MirrorPinClearMode.both.includesPills)
        XCTAssertTrue(MirrorPinClearMode.both.includesPenButton)
        XCTAssertFalse(MirrorPinClearMode.pills.includesPenButton)
        XCTAssertFalse(MirrorPinClearMode.penButton.includesPills)
    }
}
