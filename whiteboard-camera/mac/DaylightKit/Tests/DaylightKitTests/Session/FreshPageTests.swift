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

    // MARK: Review F1, F2, F6: a settled zero, a board off the air, the wake, the deferred lift

    private func board(_ state: GovernorState = .passthrough, pinned: Bool = false, hold: HoldMode = .auto, age: Double = 3600, penOnGlass: Bool = false) -> FreshPage.Board {
        return FreshPage.Board(state: state, pinned: pinned, hold: hold, hasInk: true, penOnGlass: penOnGlass, newestInkAt: drawn.addingTimeInterval(-age))
    }

    func testTheSettledZeroIsThreeSeconds() {
        XCTAssertEqual(FreshPage.settledZeroSeconds, 3)
        XCTAssertTrue(FreshPage.zeroIsSettled(zeroSince: nil, now: drawn), "0 since launch")
        XCTAssertFalse(FreshPage.zeroIsSettled(zeroSince: drawn, now: drawn.addingTimeInterval(2.9)))
        XCTAssertTrue(FreshPage.zeroIsSettled(zeroSince: drawn, now: drawn.addingTimeInterval(3)))
        XCTAssertFalse(FreshPage.zeroIsSettled(zeroSince: drawn, now: drawn.addingTimeInterval(-60)), "the wall clock moved backwards")
    }

    /// The sink's revalidate reconnect and a Zoom video toggle report 1, 0, 1 inside one call: never a new call.
    func testABounceWithinThreeSecondsIsNoNewCall() {
        var viewers = FreshPage.Viewers()
        XCTAssertTrue(viewers.update(1, at: drawn), "the first viewer after launch")
        XCTAssertFalse(viewers.update(0, at: drawn.addingTimeInterval(600)))
        XCTAssertEqual(viewers.zeroSince, drawn.addingTimeInterval(600))
        XCTAssertFalse(viewers.update(1, at: drawn.addingTimeInterval(602)), "a 0 of 2 s is a bounce")
        XCTAssertNil(viewers.zeroSince)
        XCTAssertFalse(viewers.update(0, at: drawn.addingTimeInterval(700)))
        XCTAssertFalse(viewers.update(2, at: drawn.addingTimeInterval(702.9)), "2.9 s is still a bounce")
    }

    func testAZeroThatLastsThreeSecondsMakesTheNextViewerANewCall() {
        var viewers = FreshPage.Viewers()
        _ = viewers.update(1, at: drawn)
        _ = viewers.update(0, at: drawn.addingTimeInterval(10))
        XCTAssertFalse(viewers.update(0, at: drawn.addingTimeInterval(12)), "a repeated 0 keeps the time it began")
        XCTAssertEqual(viewers.zeroSince, drawn.addingTimeInterval(10))
        XCTAssertTrue(viewers.update(1, at: drawn.addingTimeInterval(13)))
        XCTAssertFalse(viewers.update(2, at: drawn.addingTimeInterval(20)), "a second viewer joining is no new call")
        XCTAssertFalse(viewers.update(1, at: drawn.addingTimeInterval(30)))
    }

    func testOnlyABoardOffTheAirGetsAFreshPage() {
        let now = drawn
        XCTAssertEqual(FreshPage.decide(newCall: true, board: board(), now: now), .start, "PASSTHROUGH with stale ink")
        XCTAssertEqual(FreshPage.decide(newCall: false, board: board(), now: now), .keep, "no new call")
        XCTAssertEqual(FreshPage.decide(newCall: true, board: board(.live), now: now), .keep, "LIVE")
        XCTAssertEqual(FreshPage.decide(newCall: true, board: board(.engaging), now: now), .keep, "ENGAGING")
        XCTAssertEqual(FreshPage.decide(newCall: true, board: board(.returning), now: now), .keep, "RETURNING")
        XCTAssertEqual(FreshPage.decide(newCall: true, board: board(pinned: true), now: now), .keep, "pinned")
        XCTAssertEqual(FreshPage.decide(newCall: true, board: board(hold: .whiteboard), now: now), .keep, "Hold Whiteboard")
        XCTAssertEqual(FreshPage.decide(newCall: true, board: board(hold: .split), now: now), .keep, "Hold Split")
        XCTAssertEqual(FreshPage.decide(newCall: true, board: board(hold: .camera), now: now), .start, "Hold Camera shows the camera only")
        XCTAssertEqual(FreshPage.decide(newCall: true, board: board(age: 60), now: now), .keep, "PASSTHROUGH with fresh ink")
        XCTAssertEqual(FreshPage.decide(newCall: true, board: board(age: 600), now: now), .keep, "exactly 10:00")
        XCTAssertEqual(FreshPage.decide(newCall: true, board: FreshPage.Board(hasInk: false, newestInkAt: drawn.addingTimeInterval(-3600)), now: now), .keep, "empty page")
        XCTAssertTrue(FreshPage.boardIsOffAir(state: .passthrough, pinned: false, hold: .auto))
        XCTAssertFalse(FreshPage.boardIsOffAir(state: .passthrough, pinned: true, hold: .auto))
    }

    /// Review F6: an open stroke defers the new call to its lift instead of dropping it.
    func testAnOpenStrokeDefersTheNewCall() {
        XCTAssertEqual(FreshPage.decide(newCall: true, board: board(penOnGlass: true), now: drawn), .waitForLift)
        XCTAssertEqual(FreshPage.decide(newCall: true, board: board(.live, penOnGlass: true), now: drawn), .keep, "a board on the air is kept, not deferred")
    }

    /// Review F2: the watcher reports changes only. A wake with a 0 starts the zero at the wake at the latest; a wake
    /// while a call holds the camera does nothing.
    func testAWakeCountsOnlyWhenTheCountIsZero() {
        var running = FreshPage.Viewers()
        _ = running.update(1, at: drawn)
        let wake = drawn.addingTimeInterval(8 * 3600)
        running.noteWake(currentCount: 1, at: wake)
        XCTAssertEqual(running.count, 1)
        XCTAssertFalse(running.update(2, at: wake.addingTimeInterval(1)), "a second app opening the camera mid-call after the wake")

        var ended = FreshPage.Viewers()
        _ = ended.update(1, at: drawn)
        _ = ended.update(0, at: drawn.addingTimeInterval(60))
        ended.noteWake(currentCount: 0, at: wake)
        XCTAssertEqual(ended.zeroSince, drawn.addingTimeInterval(60), "a known 0 keeps its earlier start")
        XCTAssertTrue(ended.update(1, at: wake.addingTimeInterval(0.5)), "the call ended last night: the morning's first viewer is a new call")

        var missed = FreshPage.Viewers()
        _ = missed.update(1, at: drawn)
        missed.noteWake(currentCount: 0, at: wake)
        XCTAssertEqual(missed.count, 0)
        XCTAssertEqual(missed.zeroSince, wake, "the zero started at the wake")
        XCTAssertFalse(missed.update(1, at: wake.addingTimeInterval(1)))
        _ = missed.update(0, at: wake.addingTimeInterval(2))
        XCTAssertTrue(missed.update(1, at: wake.addingTimeInterval(5)))
    }
}
