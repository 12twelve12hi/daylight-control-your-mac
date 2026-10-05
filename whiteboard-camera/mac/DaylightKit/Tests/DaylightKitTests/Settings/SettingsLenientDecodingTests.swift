import Foundation
import XCTest
import DaylightKit

/// LOOSE_ENDS J5: a value a newer build wrote for an enum key (a case this build does not know) falls back to that
/// key's default, and every other key keeps its stored value. Before J5 only `adbSource` did; any other enum key
/// threw, the whole blob failed and the app started from the defaults after a downgrade.
final class SettingsLenientDecodingTests: XCTestCase {
    /// Every enum key set away from its default, so a fallback to the default is visible.
    static func stored() -> Settings {
        var s = Settings.defaults
        s.inkSource = .native
        s.preferredLayout = .whiteboardOnly
        s.mirrorPinClearMode = .pills
        s.mirrorPillsPosition = .bottom
        s.adbServerMode = .privatePort
        s.adbSource = .installed
        s.mirrorTransport = .wifiStream
        s.hotkeys[.clear] = HotkeyBinding(keyCode: 9, modifiers: 256)
        s.port = 7790
        s.idleTimeoutSeconds = 120
        s.adbTermsAcceptedVersion = "37.0.0"
        s.mirrorStreamBitRate = 5_000_000
        return s
    }

    private func encoded(_ s: Settings) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(s), as: UTF8.self)
    }

    private func decode(_ json: String) throws -> Settings {
        return try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    func testAnUnknownValueForEveryEnumKeyFallsBackToThatKeysDefaultOnly() throws {
        let stored = SettingsLenientDecodingTests.stored()
        let json = try encoded(stored)
        XCTAssertEqual(try decode(json), stored, "known values decode exactly")
        let d = Settings.defaults
        // (stored fragment, a newer build's fragment, the expected settings: stored with only that key at its default)
        let cases: [(String, String, (inout Settings) -> Void)] = [
            (#""inkSource":1,"#, #""inkSource":7,"#, { $0.inkSource = d.inkSource }),
            (#""preferredLayout":1,"#, #""preferredLayout":9,"#, { $0.preferredLayout = d.preferredLayout }),
            (#""mirrorPinClearMode":"pills""#, #""mirrorPinClearMode":"voice""#, { $0.mirrorPinClearMode = d.mirrorPinClearMode }),
            (#""mirrorPillsPosition":"bottom""#, #""mirrorPillsPosition":"left""#, { $0.mirrorPillsPosition = d.mirrorPillsPosition }),
            (#""adbServerMode":"privatePort""#, #""adbServerMode":"remote""#, { $0.adbServerMode = d.adbServerMode }),
            (#""adbSource":"installed""#, #""adbSource":"brew""#, { $0.adbSource = d.adbSource }),
            (#""mirrorTransport":"wifiStream""#, #""mirrorTransport":"bluetooth""#, { $0.mirrorTransport = d.mirrorTransport }),
        ]
        for (old, new, reset) in cases {
            XCTAssertTrue(json.contains(old), "fixture: \(old) in \(json)")
            let newer = json.replacingOccurrences(of: old, with: new)
            var expected = stored
            reset(&expected)
            XCTAssertEqual(try decode(newer), expected, new)
        }
    }

    func testAWrongJSONTypeForAnEnumKeyAlsoFallsBack() throws {
        let stored = SettingsLenientDecodingTests.stored()
        let json = try encoded(stored)
        var expected = stored
        expected.inkSource = Settings.defaults.inkSource
        expected.mirrorTransport = Settings.defaults.mirrorTransport
        let newer = json
            .replacingOccurrences(of: #""inkSource":1,"#, with: #""inkSource":"native","#)
            .replacingOccurrences(of: #""mirrorTransport":"wifiStream""#, with: #""mirrorTransport":2"#)
        XCTAssertNotEqual(newer, json)
        XCTAssertEqual(try decode(newer), expected)
    }

    func testAnUnknownHotkeyActionIsDroppedAndTheKnownOnesStay() throws {
        let stored = SettingsLenientDecodingTests.stored()
        let json = try encoded(stored)
        let old = #""hotkeys":{"#
        XCTAssertTrue(json.contains(old))
        let newer = json.replacingOccurrences(of: old, with: #""hotkeys":{"annotate":{"keyCode":0,"modifiers":6400},"#)
        XCTAssertEqual(try decode(newer), stored, "the unknown action is dropped, the known bindings stay")
        let malformed = try decode(#"{"port":7790,"hotkeys":{"clear":"Ctrl+C"}}"#)
        XCTAssertEqual(malformed.hotkeys, Settings.defaultHotkeys, "a malformed hotkeys value falls back to the defaults")
        XCTAssertEqual(malformed.port, 7790)
    }

    /// A blob from a build before `copyLastPage` (six actions, Clear rebound) keeps its bindings; `validated()` adds
    /// Ctrl+Opt+Cmd+P. A rebound Copy last page is stored under its raw value and reads back.
    func testAStoredHotkeyMapWithoutCopyLastPageGetsTheDefaultChord() throws {
        let older = #"{"port":7790,"hotkeys":{"whiteboardOnly":{"keyCode":13,"modifiers":6400},"studioSplit":{"keyCode":2,"modifiers":6400},"keep":{"keyCode":40,"modifiers":6400},"clear":{"keyCode":9,"modifiers":256},"camera":{"keyCode":53,"modifiers":6400},"overlay":{"keyCode":31,"modifiers":6400}}}"#
        let s = try decode(older)
        XCTAssertEqual(s.port, 7790)
        XCTAssertEqual(s.hotkeys.count, 6)
        XCTAssertNil(s.hotkeys[.copyLastPage], "an older blob has no Copy last page binding")
        XCTAssertEqual(s.hotkeys[.clear], HotkeyBinding(keyCode: 9, modifiers: 256))
        let validated = s.validated()
        XCTAssertEqual(validated.hotkeys[.copyLastPage], HotkeyBinding(keyCode: 0x23, modifiers: HotkeyBinding.defaultModifiers), "validated() fills it in")
        XCTAssertEqual(validated.hotkeys[.clear], HotkeyBinding(keyCode: 9, modifiers: 256), "the rebound Clear stays")

        var rebound = validated
        rebound.hotkeys[.copyLastPage] = HotkeyBinding(keyCode: 0x0B, modifiers: HotkeyBinding.defaultModifiers)
        let json = try encoded(rebound)
        XCTAssertTrue(json.contains(#""copyLastPage":{"keyCode":11,"modifiers":6400}"#), json)
        XCTAssertEqual(try decode(json), rebound)
    }
}
