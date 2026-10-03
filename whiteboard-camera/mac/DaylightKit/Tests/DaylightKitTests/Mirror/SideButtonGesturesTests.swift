import Foundation
import XCTest
import DaylightKit

/// SPEC F1 and section 7: double at 0 and 0.3 s, none at 0 and 0.5 s, long press at 0.7 s, swap setting.
final class SideButtonGesturesTests: XCTestCase {
    private let s: UInt64 = 1_000_000

    func testDefaultsMatchSpec() {
        let g = SideButtonGestures()
        XCTAssertEqual(g.doublePressWindowUs, 400_000)
        XCTAssertEqual(g.longPressUs, 700_000)
        XCTAssertEqual(SideButtonGestures(doublePressWindowMs: 400, longPressMs: 700), Settings.defaults.sideButtonGestures)
    }

    func testDoublePressAtZeroAndPoint3Seconds() {
        var g = SideButtonGestures()
        XCTAssertNil(g.down(tsUs: 0))
        XCTAssertNil(g.up(tsUs: s / 10))
        XCTAssertEqual(g.down(tsUs: 3 * s / 10), .doublePress)
        XCTAssertNil(g.pendingDeadline(), "the second press of a double is never a long press")
        XCTAssertNil(g.up(tsUs: 4 * s / 10))
        XCTAssertNil(g.timerFired(tsUs: 2 * s))
    }

    func testNoDoublePressAtZeroAndPoint5Seconds() {
        var g = SideButtonGestures()
        XCTAssertNil(g.down(tsUs: 0))
        XCTAssertNil(g.up(tsUs: s / 10))
        XCTAssertNil(g.down(tsUs: 5 * s / 10))
        XCTAssertNil(g.up(tsUs: 6 * s / 10))
        // Exactly at the window edge counts.
        XCTAssertEqual(g.down(tsUs: 6 * s / 10 + 300_000), .doublePress)
    }

    func testLongPressAtPoint7SecondsFromTheTimer() {
        var g = SideButtonGestures()
        XCTAssertNil(g.down(tsUs: 10 * s))
        XCTAssertEqual(g.pendingDeadline(), 10 * s + 700_000)
        XCTAssertNil(g.timerFired(tsUs: 10 * s + 699_999))
        XCTAssertEqual(g.timerFired(tsUs: 10 * s + 700_000), .longPress)
        XCTAssertNil(g.pendingDeadline(), "reported once")
        XCTAssertNil(g.timerFired(tsUs: 10 * s + 900_000))
        XCTAssertNil(g.up(tsUs: 11 * s), "the release of a long press is not a short press")
        XCTAssertNil(g.down(tsUs: 11 * s + 100_000), "and it never starts a double")
    }

    func testLongPressDetectedOnReleaseWithoutATimer() {
        var g = SideButtonGestures()
        XCTAssertNil(g.down(tsUs: 0))
        XCTAssertEqual(g.up(tsUs: 700_000), .longPress)
        XCTAssertNil(g.down(tsUs: 800_000))
        XCTAssertNil(g.up(tsUs: 850_000), "a short press after a long press is a single press")
    }

    func testShortPressIsNothingByItself() {
        var g = SideButtonGestures()
        XCTAssertNil(g.down(tsUs: 0))
        XCTAssertNil(g.up(tsUs: 100_000))
        XCTAssertNil(g.down(tsUs: 5 * s))
        XCTAssertNil(g.up(tsUs: 5 * s + 100_000))
    }

    func testCustomWindows() {
        var g = SideButtonGestures(doublePressWindowMs: 250, longPressMs: 1000)
        XCTAssertNil(g.down(tsUs: 0))
        XCTAssertNil(g.up(tsUs: 50_000))
        XCTAssertNil(g.down(tsUs: 300_000), "300 ms is outside a 250 ms window")
        XCTAssertNil(g.timerFired(tsUs: 300_000 + 999_999))
        XCTAssertEqual(g.timerFired(tsUs: 300_000 + 1_000_000), .longPress)
    }

    func testSwapSetting() {
        XCTAssertEqual(SideButtonGestures.action(for: .doublePress, swap: false), .pin)
        XCTAssertEqual(SideButtonGestures.action(for: .longPress, swap: false), .clear)
        XCTAssertEqual(SideButtonGestures.action(for: .doublePress, swap: true), .clear)
        XCTAssertEqual(SideButtonGestures.action(for: .longPress, swap: true), .pin)
    }

    func testDuplicateDownIsIgnored() {
        var g = SideButtonGestures()
        XCTAssertNil(g.down(tsUs: 0))
        XCTAssertNil(g.down(tsUs: 100_000))
        XCTAssertEqual(g.pendingDeadline(), 700_000, "the first down keeps its deadline")
        XCTAssertNil(g.up(tsUs: 200_000))
        XCTAssertNil(g.up(tsUs: 300_000), "an up without a down is nothing")
    }
}
