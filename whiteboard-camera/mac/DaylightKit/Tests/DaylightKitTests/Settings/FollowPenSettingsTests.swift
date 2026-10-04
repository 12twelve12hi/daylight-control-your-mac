import Foundation
import XCTest
import DaylightKit

/// `followPen` (Settings > Advanced "Follow the pen on camera", handoff vp-ink-legibility R2): off by default, a blob
/// written before the key existed decodes to false with every other key kept, and true survives the JSON round trip.
final class FollowPenSettingsTests: XCTestCase {
    func testDefaultIsOffAndValidatedKeepsIt() {
        XCTAssertFalse(Settings.defaults.followPen, "off by default")
        XCTAssertFalse(Settings().followPen)
        var s = Settings.defaults
        s.followPen = true
        XCTAssertTrue(s.validated().followPen, "validated() leaves the switch alone")
        XCTAssertEqual(Settings.defaults, Settings.defaults.validated())
    }

    func testABlobWithoutTheKeyDecodesToFalse() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"port":7790,"overlayEnabled":true,"perfLog":true}"#.utf8))
        XCTAssertFalse(old.followPen, "an older blob has no followPen key")
        XCTAssertEqual(old.port, 7790, "the other keys are kept")
        XCTAssertTrue(old.overlayEnabled)
        XCTAssertTrue(old.perfLog)
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).followPen)
    }

    func testRoundTripKeepsTrueUnderItsKeyName() throws {
        var s = Settings.defaults
        s.followPen = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]   // the encoder SettingsStore.persist uses
        let data = try encoder.encode(s)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"followPen\":true"), text)
        let back = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertTrue(back.followPen)
        XCTAssertEqual(back, s)
        let offData = try encoder.encode(Settings.defaults)
        let off = String(decoding: offData, as: UTF8.self)
        XCTAssertTrue(off.contains("\"followPen\":false"), "the default is written too, so a later read sees the key: \(off)")
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data(off.utf8)).followPen)
    }
}
