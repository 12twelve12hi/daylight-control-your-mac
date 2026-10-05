import Foundation
import XCTest
import DaylightKit

/// DRAWING-DEEP-DIVE D6: a fresh page when a new call opens Daylight Camera on a page older than 10 minutes.
final class FreshPageTests: XCTestCase {
    private let drawn = Date(timeIntervalSince1970: 1_791_036_309)   // 2026-10-03T14:05:09Z

    private func start(_ previous: Int, _ viewers: Int, hasInk: Bool = true, age: Double, penOnGlass: Bool = false) -> Bool {
        return FreshPage.shouldStart(previousViewers: previous, viewers: viewers, hasInk: hasInk, newestInkAt: drawn, now: drawn.addingTimeInterval(age), penOnGlass: penOnGlass)
    }

    func testTheIdleSpanIsTenMinutes() {
        XCTAssertEqual(FreshPage.idleSeconds, 600)
    }

    func testAPageOlderThanTenMinutesStartsFreshWhenTheFirstViewerArrives() {
        XCTAssertFalse(start(0, 1, age: 9 * 60 + 59), "9:59 keeps the page")
        XCTAssertFalse(start(0, 1, age: 600), "exactly 10:00 is not older than 10 minutes")
        XCTAssertTrue(start(0, 1, age: 10 * 60 + 1), "10:01 starts a fresh page")
        XCTAssertTrue(start(0, 2, age: 10 * 60 + 1), "two apps opening the camera at once is still a new call")
        XCTAssertTrue(start(0, 1, age: 9 * 3600), "a page from last night (the Mac slept) is old")
    }

    func testAnEmptyPageNeverStartsFresh() {
        XCTAssertFalse(start(0, 1, hasInk: false, age: 3600))
        XCTAssertFalse(FreshPage.shouldStart(previousViewers: 0, viewers: 1, hasInk: true, newestInkAt: nil, now: drawn), "no ink time known")
    }

    func testOnlyTheZeroToOneTransitionCounts() {
        XCTAssertFalse(start(1, 2, age: 3600), "a second viewer joining a running call keeps the page")
        XCTAssertFalse(start(1, 1, age: 3600), "a repeated count is no transition")
        XCTAssertFalse(start(2, 0, age: 3600), "the call ending keeps the page")
        XCTAssertFalse(start(0, 0, age: 3600))
    }

    func testAPenOnTheGlassAndABackwardsClockKeepThePage() {
        XCTAssertFalse(start(0, 1, age: 3600, penOnGlass: true))
        XCTAssertFalse(start(0, 1, age: -3600), "the wall clock moved backwards")
    }
}
