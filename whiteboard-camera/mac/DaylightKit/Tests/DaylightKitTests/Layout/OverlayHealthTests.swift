import XCTest
import DaylightKit

/// SPEC 6.7 and 13.3 rows 48 and 49: the Overlay fallback state machine.
final class OverlayHealthTests: XCTestCase {
    func testStartsAsRectangleUntilTheFirstMask() {
        let h = OverlayHealth()
        XCTAssertEqual(h.consecutiveFailures, 0)
        XCTAssertNil(h.fallbackReason)
        XCTAssertNil(h.lastMaskAt)
        XCTAssertNil(h.lastCoverage)
        XCTAssertEqual(h.presentation(now: 0), .rectangle, "no mask yet")
    }

    func testGoodMaskIsMatte() {
        var h = OverlayHealth()
        XCTAssertEqual(h.segmented(coverage: 0.2, now: 10), [])
        XCTAssertEqual(h.lastMaskAt, 10)
        XCTAssertEqual(h.lastCoverage, 0.2)
        XCTAssertEqual(h.presentation(now: 10), .matte)
        XCTAssertEqual(h.presentation(now: 10.5), .matte, "exactly 0.5 s old is not stale")
    }

    func testStaleMaskAfterHalfASecondIsRectangle() {
        var h = OverlayHealth()
        _ = h.segmented(coverage: 0.2, now: 10)
        XCTAssertEqual(h.presentation(now: 10.51), .rectangle)
        _ = h.segmented(coverage: 0.2, now: 10.6)
        XCTAssertEqual(h.presentation(now: 10.7), .matte, "a new mask brings the matte back")
    }

    func testFourteenFailuresDoNotFallBackTheFifteenthDoesOnce() {
        var h = OverlayHealth()
        for i in 1...14 {
            XCTAssertEqual(h.failed(reason: "boom", now: Double(i)), [], "failure \(i)")
            XCTAssertNotEqual(h.presentation(now: Double(i)), .fellBack)
        }
        XCTAssertEqual(h.consecutiveFailures, 14)
        XCTAssertEqual(h.failed(reason: "boom", now: 15), [.fellBack(reason: "boom")])
        XCTAssertEqual(h.consecutiveFailures, 15)
        XCTAssertEqual(h.fallbackReason, "boom")
        XCTAssertEqual(h.presentation(now: 15), .fellBack)
        // Latched: no second .fellBack, and a good mask does not undo it.
        XCTAssertEqual(h.failed(reason: "again", now: 16), [])
        XCTAssertEqual(h.segmented(coverage: 0.5, now: 17), [])
        XCTAssertEqual(h.segmented(coverage: 0.001, now: 17.1), [], "no coverage effects while fallen back")
        XCTAssertEqual(h.presentation(now: 17.1), .fellBack)
        XCTAssertEqual(h.fallbackReason, "boom")
        h.reset()
        XCTAssertEqual(h, OverlayHealth())
        XCTAssertEqual(h.presentation(now: 18), .rectangle)
        XCTAssertNil(h.fallbackReason)
    }

    func testASuccessResetsTheFailureCounter() {
        var h = OverlayHealth()
        for i in 0..<14 { _ = h.failed(reason: "x", now: Double(i)) }
        XCTAssertEqual(h.segmented(coverage: 0.3, now: 14), [])
        XCTAssertEqual(h.consecutiveFailures, 0)
        for i in 0..<14 { XCTAssertEqual(h.failed(reason: "x", now: 15 + Double(i)), []) }
        XCTAssertNil(h.fallbackReason, "28 failures, but never 15 in a row")
        XCTAssertEqual(h.failed(reason: "x", now: 30), [.fellBack(reason: "x")])
    }

    func testLowCoverageShowsTheRectangleOnceAndRestores() {
        var h = OverlayHealth()
        XCTAssertEqual(h.segmented(coverage: 0.3, now: 0), [])
        XCTAssertEqual(h.presentation(now: 0), .matte)
        XCTAssertEqual(h.segmented(coverage: 0.009, now: 0.1), [.lowCoverage(0.009)])
        XCTAssertEqual(h.presentation(now: 0.1), .rectangle)
        XCTAssertEqual(h.segmented(coverage: 0.005, now: 0.2), [], "once per transition")
        XCTAssertEqual(h.segmented(coverage: 0.0, now: 0.3), [])
        XCTAssertEqual(h.presentation(now: 0.3), .rectangle)
        XCTAssertEqual(h.segmented(coverage: 0.01, now: 0.4), [.matteRestored], "back at the minimum")
        XCTAssertEqual(h.presentation(now: 0.4), .matte)
        XCTAssertEqual(h.segmented(coverage: 0.2, now: 0.5), [])
        XCTAssertEqual(h.segmented(coverage: 0.009, now: 0.6), [.lowCoverage(0.009)], "a new transition reports again")
    }

    func testFirstMaskBelowTheMinimumReportsLowCoverage() {
        var h = OverlayHealth()
        XCTAssertEqual(h.segmented(coverage: 0.009, now: 0), [.lowCoverage(0.009)])
        XCTAssertEqual(h.presentation(now: 0), .rectangle)
        XCTAssertEqual(h.segmented(coverage: .nan, now: 0.1), [], "NaN counts as low")
        XCTAssertEqual(h.presentation(now: 0.1), .rectangle)
    }

    func testFailuresDoNotChangeTheLastMask() {
        var h = OverlayHealth()
        _ = h.segmented(coverage: 0.3, now: 1)
        _ = h.failed(reason: "x", now: 1.1)
        XCTAssertEqual(h.presentation(now: 1.2), .matte, "the newest mask is still fresh")
        XCTAssertEqual(h.presentation(now: 1.6), .rectangle, "then it goes stale")
    }
}
