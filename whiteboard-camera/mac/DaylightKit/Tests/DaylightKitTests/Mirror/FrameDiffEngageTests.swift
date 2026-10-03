import Foundation
import XCTest
import DaylightKit

/// Frame-diff engage (Mirror over Wi-Fi, SPEC 13.3 row 37): the config numbers, the changed-frame threshold, the
/// clock-tick case, a continuous stroke, the gap and release timing, priming and reset.
final class FrameDiffEngageTests: XCTestCase {
    static let w = 48
    static let h = 64
    static let cells = 48 * 64

    /// A 48 x 64 page of luma 200 with the first `ink` cells at 200 - `depth` (ink accumulates like a stroke).
    static func page(ink: Int, depth: Int = 150) -> [UInt8] {
        var g = [UInt8](repeating: 200, count: cells)
        for i in 0..<ink {
            g[i] = UInt8(200 - depth)
        }
        return g
    }

    /// The page with `count` cells starting at `start` replaced by `value`.
    static func patch(_ base: [UInt8], start: Int, count: Int, value: UInt8) -> [UInt8] {
        var g = base
        for i in start..<(start + count) {
            g[i] = value
        }
        return g
    }

    private func feed(_ e: inout FrameDiffEngage, _ grid: [UInt8], _ now: Double) -> FrameDiffEngage.Edge? {
        return e.feed(grid: grid, width: FrameDiffEngageTests.w, height: FrameDiffEngageTests.h, now: now)
    }

    func testConfigDefaults() {
        let c = FrameDiffEngage.Config()
        XCTAssertEqual(c.cellDelta, 24)
        XCTAssertEqual(c.changedFraction, 0.002)
        XCTAssertEqual(c.minChangedCells, 4)
        XCTAssertEqual(c.consecutiveFrames, 2)
        XCTAssertEqual(c.maxGapSeconds, 0.25)
        XCTAssertEqual(c.releaseSeconds, 1.0)
        XCTAssertEqual(FrameDiffEngage().config, c)
        XCTAssertFalse(FrameDiffEngage().isDown)
    }

    func testChangedCellThreshold() {
        let c = FrameDiffEngage.Config()
        XCTAssertEqual(c.changedCellThreshold(cellCount: 48 * 64), 7, "ceil(0.002 x 3072 = 6.144) = 7")
        XCTAssertEqual(c.changedCellThreshold(cellCount: 100), 4, "minChangedCells wins on a small grid")
        XCTAssertEqual(c.changedCellThreshold(cellCount: 5000), 10, "an exact product does not round up")
        let exact = FrameDiffEngage.Config(changedFraction: 0.0025, minChangedCells: 0)
        XCTAssertEqual(exact.changedCellThreshold(cellCount: 1600), 4)
        XCTAssertEqual(exact.changedCellThreshold(cellCount: 1601), 5)
    }

    func testChangedCellsCountsBothDirectionsAtCellDelta() {
        let base = FrameDiffEngageTests.page(ink: 0)
        XCTAssertEqual(FrameDiffEngage.changedCells(base, base, cellDelta: 24), 0)
        XCTAssertEqual(FrameDiffEngage.changedCells(base, FrameDiffEngageTests.patch(base, start: 0, count: 5, value: 176), cellDelta: 24), 5, "darker by exactly 24")
        XCTAssertEqual(FrameDiffEngage.changedCells(base, FrameDiffEngageTests.patch(base, start: 0, count: 5, value: 224), cellDelta: 24), 5, "lighter by exactly 24")
        XCTAssertEqual(FrameDiffEngage.changedCells(base, FrameDiffEngageTests.patch(base, start: 0, count: 5, value: 177), cellDelta: 24), 0, "23 is below the delta")
        XCTAssertNil(FrameDiffEngage.changedCells(base, [1, 2, 3], cellDelta: 24))
    }

    func testFirstGridOnlyPrimes() {
        var e = FrameDiffEngage()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 500), 0))
        XCTAssertFalse(e.isDown)
    }

    /// The status-bar clock: one changed frame followed by identical repeats (the encoder repeats the frame every 250 ms)
    /// never engages, minute after minute.
    func testClockTickNeverEngages() {
        var e = FrameDiffEngage()
        var page = FrameDiffEngageTests.page(ink: 0)
        XCTAssertNil(feed(&e, page, 0))
        var t = 0.0
        for minute in 1...3 {
            page = FrameDiffEngageTests.patch(page, start: 10, count: 12, value: minute % 2 == 0 ? 200 : 20)
            t = Double(minute) * 60
            XCTAssertNil(feed(&e, page, t), "the tick itself")
            for repeatIndex in 1...20 {
                XCTAssertNil(feed(&e, page, t + Double(repeatIndex) * 0.25), "repeat \(repeatIndex) after minute \(minute)")
            }
            XCTAssertNil(e.tick(now: t + 6))
        }
        XCTAssertFalse(e.isDown)
    }

    /// A continuous stroke at 30 fps: every frame adds 8 cells of ink, so it engages on the second changed frame.
    func testContinuousStrokeEngagesOnTheSecondChangedFrame() {
        var e = FrameDiffEngage()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0), "first changed frame")
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.0 + 1.0 / 30), .down, "second changed frame")
        XCTAssertTrue(e.isDown)
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 24), 1.0 + 2.0 / 30), "no second .down while down")
    }

    func testThresholdBoundaryOnTheDefaultGrid() {
        // 6 changed cells: below ceil(6.144) = 7.
        var below = FrameDiffEngage()
        XCTAssertNil(feed(&below, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&below, FrameDiffEngageTests.page(ink: 6), 1.0))
        XCTAssertNil(feed(&below, FrameDiffEngageTests.page(ink: 12), 1.125))
        XCTAssertNil(feed(&below, FrameDiffEngageTests.page(ink: 18), 1.25))
        XCTAssertFalse(below.isDown)
        // 7 changed cells: at the threshold.
        var at = FrameDiffEngage()
        XCTAssertNil(feed(&at, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&at, FrameDiffEngageTests.page(ink: 7), 1.0))
        XCTAssertEqual(feed(&at, FrameDiffEngageTests.page(ink: 14), 1.125), .down)
    }

    func testCellDeltaBoundary() {
        var weak = FrameDiffEngage()
        XCTAssertNil(feed(&weak, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&weak, FrameDiffEngageTests.page(ink: 10, depth: 23), 1.0))
        XCTAssertNil(feed(&weak, FrameDiffEngageTests.page(ink: 20, depth: 23), 1.1))
        XCTAssertFalse(weak.isDown, "a 23-level change is noise")
        var strong = FrameDiffEngage()
        XCTAssertNil(feed(&strong, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&strong, FrameDiffEngageTests.page(ink: 10, depth: 24), 1.0))
        XCTAssertEqual(feed(&strong, FrameDiffEngageTests.page(ink: 20, depth: 24), 1.1), .down)
    }

    func testMaxGapBoundary() {
        var inside = FrameDiffEngage()
        XCTAssertNil(feed(&inside, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&inside, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertEqual(feed(&inside, FrameDiffEngageTests.page(ink: 16), 1.25), .down, "exactly 0.25 s apart")
        var outside = FrameDiffEngage()
        XCTAssertNil(feed(&outside, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&outside, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertNil(feed(&outside, FrameDiffEngageTests.page(ink: 16), 1.375), "0.375 s apart: starts a new run")
        XCTAssertEqual(feed(&outside, FrameDiffEngageTests.page(ink: 24), 1.5), .down, "0.125 s after the new run's first frame")
    }

    func testUnchangedFramesBetweenChangesDoNotBreakARun() {
        var e = FrameDiffEngage()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0625), "an identical frame")
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125), .down, "within 0.25 s of the previous changed frame")
    }

    func testReleaseAfterOneSecondQuietByTick() {
        var e = FrameDiffEngage()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125), .down)
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.5), "repeat")
        XCTAssertNil(e.tick(now: 2.0))
        XCTAssertNil(e.tick(now: 2.124))
        XCTAssertEqual(e.tick(now: 2.125), .up, "1.0 s after the last changed frame")
        XCTAssertFalse(e.isDown)
        XCTAssertNil(e.tick(now: 3.0), "one .up only")
    }

    func testReleaseByFeedOfAnUnchangedFrame() {
        var e = FrameDiffEngage()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125), .down)
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 16), 2.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 2.125), .up)
    }

    func testChangedFramesWhileDownRefreshTheRelease() {
        var e = FrameDiffEngage()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125), .down)
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 24), 1.875), "a later stroke while down")
        XCTAssertNil(e.tick(now: 2.125), "the release counts from 1.875 now")
        XCTAssertNil(e.tick(now: 2.874))
        XCTAssertEqual(e.tick(now: 2.875), .up)
    }

    func testReengageNeedsTwoNewChangedFrames() {
        var e = FrameDiffEngage()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125), .down)
        XCTAssertEqual(e.tick(now: 2.125), .up)
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 24), 5.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 32), 5.125), .down)
    }

    func testAGridOfADifferentSizeOnlyPrimes() {
        var e = FrameDiffEngage()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        // Rotation: a 64 x 48 grid primes, so it is not the second changed frame.
        let landscape = [UInt8](repeating: 0, count: 64 * 48)
        XCTAssertNil(e.feed(grid: landscape, width: 64, height: 48, now: 1.0625))
        XCTAssertFalse(e.isDown)
        var inked = landscape
        for i in 0..<8 {
            inked[i] = 200
        }
        XCTAssertNil(e.feed(grid: inked, width: 64, height: 48, now: 2.0))
        var more = inked
        for i in 8..<16 {
            more[i] = 200
        }
        XCTAssertEqual(e.feed(grid: more, width: 64, height: 48, now: 2.0625), .down)
        // A grid whose count does not match its width x height also only primes.
        XCTAssertNil(e.feed(grid: [1, 2, 3], width: 64, height: 48, now: 2.1))
    }

    func testResetForgetsWithoutEmitting() {
        var e = FrameDiffEngage()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125), .down)
        e.reset()
        XCTAssertFalse(e.isDown, "reset does not emit .up")
        XCTAssertNil(e.tick(now: 10))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 100), 10), "the first grid after a reset primes")
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 108), 10.0625))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 116), 10.125), .down)
    }

    func testTickWhileUpDoesNothing() {
        var e = FrameDiffEngage()
        XCTAssertNil(e.tick(now: 0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(e.tick(now: 100))
    }

    func testCustomConfig() {
        var e = FrameDiffEngage(config: FrameDiffEngage.Config(consecutiveFrames: 3, releaseSeconds: 0.5))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 24), 1.25), .down)
        XCTAssertEqual(e.tick(now: 1.75), .up)
    }
}
