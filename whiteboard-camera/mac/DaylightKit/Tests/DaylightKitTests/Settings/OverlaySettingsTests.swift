import Foundation
import XCTest
import DaylightKit

/// SPEC 11 Overlay keys (SPEC 6.7, v2, off by default): defaults, clamps, JSON round trip and tolerance, governor mapping.
final class OverlaySettingsTests: XCTestCase {
    func testDefaults() {
        let d = Settings.defaults
        XCTAssertFalse(d.overlayEnabled, "off by default")
        XCTAssertEqual(d.overlayQuality, .fast)
        XCTAssertEqual(d.overlaySmoothing, 0.6)
        XCTAssertEqual(d.overlayFeather, 2)
        XCTAssertFalse(d.overlayHalo)
        XCTAssertEqual(d.overlayScale, 0.28)
        XCTAssertEqual(d.overlayPosition, .bottomRight)
        XCTAssertEqual(d.overlayOpacity, 1.0)
        XCTAssertEqual(Settings.overlaySmoothingRange, 0...0.9)
        XCTAssertEqual(Settings.overlayFeatherRange, 0...8)
        XCTAssertEqual(Settings.overlayScaleRange, 0.15...0.5)
        XCTAssertEqual(Settings.overlayOpacityRange, 0.3...1.0)
        XCTAssertEqual(d, d.validated())
    }

    func testValidatedClamps() {
        var s = Settings.defaults
        s.overlaySmoothing = -1
        s.overlayFeather = -2
        s.overlayScale = 0.01
        s.overlayOpacity = 0
        var v = s.validated()
        XCTAssertEqual(v.overlaySmoothing, 0)
        XCTAssertEqual(v.overlayFeather, 0)
        XCTAssertEqual(v.overlayScale, 0.15)
        XCTAssertEqual(v.overlayOpacity, 0.3)
        s.overlaySmoothing = 5
        s.overlayFeather = 99
        s.overlayScale = 2
        s.overlayOpacity = 7
        v = s.validated()
        XCTAssertEqual(v.overlaySmoothing, 0.9)
        XCTAssertEqual(v.overlayFeather, 8)
        XCTAssertEqual(v.overlayScale, 0.5)
        XCTAssertEqual(v.overlayOpacity, 1.0)
        XCTAssertEqual(v, v.validated())
        s.overlaySmoothing = .nan
        s.overlayScale = .nan
        s.overlayOpacity = .nan
        v = s.validated()
        XCTAssertEqual(v.overlaySmoothing, 0.6, "NaN becomes the default")
        XCTAssertEqual(v.overlayScale, 0.28)
        XCTAssertEqual(v.overlayOpacity, 1.0)
        s = Settings.defaults
        s.overlaySmoothing = 0.3
        s.overlayFeather = 5
        s.overlayScale = 0.4
        s.overlayOpacity = 0.7
        v = s.validated()
        XCTAssertEqual(v.overlaySmoothing, 0.3, "in range stays")
        XCTAssertEqual(v.overlayFeather, 5)
        XCTAssertEqual(v.overlayScale, 0.4)
        XCTAssertEqual(v.overlayOpacity, 0.7)
    }

    func testRoundTripAndKeyNames() throws {
        var s = Settings.defaults
        s.overlayEnabled = true
        s.overlayQuality = .accurate
        s.overlaySmoothing = 0.25
        s.overlayFeather = 4
        s.overlayHalo = true
        s.overlayScale = 0.35
        s.overlayPosition = .topLeft
        s.overlayOpacity = 0.8
        s.preferredLayout = .overlay
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(s)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"overlayEnabled\":true"), text)
        XCTAssertTrue(text.contains("\"overlayQuality\":\"accurate\""), text)
        XCTAssertTrue(text.contains("\"overlayPosition\":\"topLeft\""), text)
        XCTAssertTrue(text.contains("\"overlayFeather\":4"), text)
        XCTAssertTrue(text.contains("\"overlayHalo\":true"), text)
        XCTAssertTrue(text.contains("\"preferredLayout\":2"), text)
        XCTAssertTrue(text.contains("\"overlay\":{\"keyCode\":31,\"modifiers\":6400}"), text)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), s)
        for q in OverlayQuality.allCases {
            for p in OverlayPosition.allCases {
                var t = Settings.defaults
                t.overlayQuality = q
                t.overlayPosition = p
                let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(t))
                XCTAssertEqual(back.overlayQuality, q)
                XCTAssertEqual(back.overlayPosition, p)
            }
        }
    }

    func testMissingKeysKeepDefaults() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"port":7790,"preferredLayout":1,"hotkeys":{"clear":{"keyCode":8,"modifiers":6400}}}"#.utf8))
        XCTAssertEqual(old.port, 7790)
        XCTAssertEqual(old.preferredLayout, .whiteboardOnly)
        XCTAssertFalse(old.overlayEnabled)
        XCTAssertEqual(old.overlayQuality, .fast)
        XCTAssertEqual(old.overlaySmoothing, 0.6)
        XCTAssertEqual(old.overlayFeather, 2)
        XCTAssertFalse(old.overlayHalo)
        XCTAssertEqual(old.overlayScale, 0.28)
        XCTAssertEqual(old.overlayPosition, .bottomRight)
        XCTAssertEqual(old.overlayOpacity, 1.0)
        XCTAssertNil(old.hotkeys[.overlay], "an older blob has no overlay binding")
        XCTAssertEqual(old.validated().hotkeys[.overlay], HotkeyBinding(keyCode: HotkeyBinding.keyO, modifiers: HotkeyBinding.defaultModifiers), "validated() fills it in")
    }

    func testUnknownRawValuesDecodeAsDefaultsWithoutLosingTheRest() throws {
        for raw in [#""ultra""#, #"42"#, #"null"#] {
            let blob = Data(#"{"port":7790,"overlayEnabled":true,"overlayQuality":\#(raw),"overlayPosition":\#(raw),"overlayScale":0.4}"#.utf8)
            let s = try JSONDecoder().decode(Settings.self, from: blob)
            XCTAssertEqual(s.overlayQuality, .fast, raw)
            XCTAssertEqual(s.overlayPosition, .bottomRight, raw)
            XCTAssertTrue(s.overlayEnabled, raw)
            XCTAssertEqual(s.overlayScale, 0.4, raw)
            XCTAssertEqual(s.port, 7790, raw)
        }
        for raw in [#"7"#, #""overlay""#, #"null"#, #"-1"#] {
            let blob = Data(#"{"port":7790,"preferredLayout":\#(raw)}"#.utf8)
            let s = try JSONDecoder().decode(Settings.self, from: blob)
            XCTAssertEqual(s.preferredLayout, .studioSplit, raw)
            XCTAssertEqual(s.port, 7790, raw)
        }
    }

    func testPreferredOverlayNeedsOverlayEnabled() {
        var s = Settings.defaults
        s.preferredLayout = .overlay
        s.overlayEnabled = false
        XCTAssertEqual(GovernorConfig(settings: s).preferredLayout, .studioSplit, "feature off: engage in Studio Split")
        XCTAssertEqual(s.validated().preferredLayout, .overlay, "the stored value stays, so re-enabling restores it")
        s.overlayEnabled = true
        XCTAssertEqual(GovernorConfig(settings: s).preferredLayout, .overlay)
        s.preferredLayout = .whiteboardOnly
        s.overlayEnabled = false
        XCTAssertEqual(GovernorConfig(settings: s).preferredLayout, .whiteboardOnly, "other layouts are unaffected")
        XCTAssertEqual(LayoutStyle.overlay.rawValue, 2)
    }

    func testOverlayHotkeyIsAppendedLast() {
        XCTAssertEqual(HotkeyAction.allCases.firstIndex(of: .overlay), 5, "appended after Camera: hotkey id 6")
        XCTAssertEqual(HotkeyAction.allCases.last, .copyLastPage, "Copy last page came after it: id 7")
        XCTAssertEqual(HotkeyAction.allCases.firstIndex(of: .camera), 4, "existing ids 1 to 5 unchanged")
        XCTAssertEqual(Settings.defaultHotkeys[.overlay], HotkeyBinding(keyCode: 0x1F, modifiers: (1 << 8) | (1 << 11) | (1 << 12)))
    }
}
