import Foundation
import XCTest
import DaylightKit

/// Frame-diff engage (Mirror over Wi-Fi, SPEC 13.3 row 37, SPEC F10): the config numbers, the threshold steps, runs
/// against a baseline, the strict gap on media time, the settle window, reprime, release, and end-to-end runs on real
/// 1200 x 1600 BGRA frames through `LumaGrid.sample` (a thin stroke engages; a clock digit, a cursor blink and a lossy
/// frame do not).
final class FrameDiffEngageTests: XCTestCase {
    static let w = 144
    static let h = 192
    static let cells = 144 * 192

    /// A page of luma 200 with the first `ink` cells at 200 - `depth` (ink accumulates like a stroke).
    static func page(ink: Int, depth: Int = 150) -> [UInt8] {
        var g = [UInt8](repeating: 200, count: cells)
        for i in 0..<ink {
            g[i] = UInt8(200 - depth)
        }
        return g
    }

    /// The grid with `count` cells starting at `start` replaced by `value`.
    static func patch(_ base: [UInt8], start: Int, count: Int, value: UInt8) -> [UInt8] {
        var g = base
        for i in start..<(start + count) {
            g[i] = value
        }
        return g
    }

    private func feed(_ e: inout FrameDiffEngage, _ grid: [UInt8], _ now: Double, media: Double? = nil) -> FrameDiffEngage.Edge? {
        return e.feed(grid: grid, width: FrameDiffEngageTests.w, height: FrameDiffEngageTests.h, now: now, mediaTime: media ?? now)
    }

    /// A detector primed with `grid` at t = 0; its settle window ends at 0.5 s.
    private func primed(_ grid: [UInt8] = FrameDiffEngageTests.page(ink: 0), config: FrameDiffEngage.Config = FrameDiffEngage.Config()) -> FrameDiffEngage {
        var e = FrameDiffEngage(config: config)
        XCTAssertNil(feed(&e, grid, 0))
        return e
    }

    func testConfigDefaults() {
        let c = FrameDiffEngage.Config()
        XCTAssertEqual(c.cellDelta, 12)
        XCTAssertEqual(c.changedFraction, 0.002)
        XCTAssertEqual(c.minChangedCells, 1)
        XCTAssertEqual(c.consecutiveFrames, 2)
        XCTAssertEqual(c.maxGapSeconds, 0.2)
        XCTAssertEqual(c.releaseSeconds, 1.0)
        XCTAssertEqual(c.settleSeconds, 0.5)
        XCTAssertEqual(c.referenceCellCount, 3072)
        XCTAssertEqual(c.changedCellThreshold, 7, "ceil(0.002 x 3072 = 6.144)")
        XCTAssertEqual(FrameDiffEngage().config, c)
        XCTAssertFalse(FrameDiffEngage().isDown)
    }

    /// DIFF-A6: every value the Settings stepper offers (0.0005 to 0.05 in steps of 0.0005) is a distinct cell count.
    /// Before, 0.0005 and 0.001 both gave the 4-cell floor.
    func testEveryThresholdStepIsADistinctCellCount() {
        let range = Settings.mirrorDiffThresholdRange
        XCTAssertEqual(range.lowerBound, 0.0005)
        XCTAssertEqual(range.upperBound, 0.05)
        var previous = 0
        var k = 1
        while Double(k) * 0.0005 <= range.upperBound + 1e-12 {
            let n = FrameDiffEngage.Config(changedFraction: Double(k) * 0.0005).changedCellThreshold
            XCTAssertGreaterThan(n, previous, "step \(k)")
            previous = n
            k += 1
        }
        XCTAssertEqual(k - 1, 100, "100 stepper values")
        XCTAssertEqual(FrameDiffEngage.Config(changedFraction: 0.0005).changedCellThreshold, 2)
        XCTAssertEqual(FrameDiffEngage.Config(changedFraction: 0.001).changedCellThreshold, 4)
        XCTAssertEqual(FrameDiffEngage.Config(changedFraction: 0.05).changedCellThreshold, 154)
        XCTAssertEqual(FrameDiffEngage.Config(changedFraction: 0.0005, minChangedCells: 5).changedCellThreshold, 5, "the floor still applies")
        let exact = FrameDiffEngage.Config(changedFraction: 0.0025, referenceCellCount: 1600)
        XCTAssertEqual(exact.changedCellThreshold, 4, "an exact product does not round up")
    }

    func testChangedCellsCountsBothDirectionsAtCellDelta() {
        let base = FrameDiffEngageTests.page(ink: 0)
        XCTAssertEqual(FrameDiffEngage.changedCells(base, base, cellDelta: 12), 0)
        XCTAssertEqual(FrameDiffEngage.changedCells(base, FrameDiffEngageTests.patch(base, start: 0, count: 5, value: 188), cellDelta: 12), 5, "darker by exactly 12")
        XCTAssertEqual(FrameDiffEngage.changedCells(base, FrameDiffEngageTests.patch(base, start: 0, count: 5, value: 212), cellDelta: 12), 5, "lighter by exactly 12")
        XCTAssertEqual(FrameDiffEngage.changedCells(base, FrameDiffEngageTests.patch(base, start: 0, count: 5, value: 189), cellDelta: 12), 0, "11 is below the delta")
        XCTAssertNil(FrameDiffEngage.changedCells(base, [1, 2, 3], cellDelta: 12))
    }

    func testFirstGridOnlyPrimes() {
        var e = FrameDiffEngage()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 500), 0))
        XCTAssertFalse(e.isDown)
    }

    /// A stroke whose frames each move 8 cells engages on the second active frame.
    func testAStrokeEngagesOnTheSecondActiveFrame() {
        var e = primed()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0), "first active frame")
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.0 + 1.0 / 30), .down, "second active frame")
        XCTAssertTrue(e.isDown)
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 24), 1.0 + 2.0 / 30), "no second .down while down")
    }

    /// DIFF-A1: real ink moves a cell or two per frame. The cells add up against the run's baseline, so the 7th frame
    /// that each adds 1 cell engages. Before, each frame had to move 7 cells against the previous frame by itself.
    func testSlowInkAddsUpAgainstTheBaseline() {
        var e = primed()
        for k in 1...6 {
            XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: k), 1.0 + Double(k - 1) / 30), "frame \(k): \(k) cells")
        }
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 7), 1.0 + 6.0 / 30), .down, "7 cells against the baseline")
    }

    /// The status-bar clock: one changed frame, then repeats every 250 ms, the first of them a lossy refinement that
    /// moves 8 more cells by 30 (DIFF-B1). The refinement is 0.25 s after the tick, outside the strict 0.2 s gap.
    /// Before, the inclusive 0.25 s gap made tick plus refinement a run of two changed frames.
    func testAClockTickAndItsRefinementNeverEngage() {
        var e = primed()
        var page = FrameDiffEngageTests.page(ink: 0)
        for minute in 1...3 {
            page = FrameDiffEngageTests.patch(page, start: 10, count: 40, value: minute % 2 == 0 ? 200 : 20)
            let t = Double(minute) * 60
            XCTAssertNil(feed(&e, page, t), "the tick itself")
            let refined = FrameDiffEngageTests.patch(page, start: 1000, count: 8, value: minute % 2 == 0 ? 200 : 230)
            XCTAssertNil(feed(&e, refined, t + 0.25), "the refinement repeat after minute \(minute)")
            page = refined
            for repeatIndex in 2...20 {
                XCTAssertNil(feed(&e, page, t + Double(repeatIndex) * 0.25), "repeat \(repeatIndex) after minute \(minute)")
            }
            XCTAssertNil(e.tick(now: t + 6))
        }
        XCTAssertFalse(e.isDown)
    }

    /// A text cursor (6 cells) blinks every 0.5 s for 10 s with repeats in between: never a run.
    func testACursorBlinkNeverEngages() {
        var e = primed()
        let off = FrameDiffEngageTests.page(ink: 0)
        let on = FrameDiffEngageTests.patch(off, start: 5000, count: 6, value: 10)
        var t = 1.0
        var visible = false
        while t < 11 {
            visible.toggle()
            XCTAssertNil(feed(&e, visible ? on : off, t), "blink at \(t)")
            XCTAssertNil(feed(&e, visible ? on : off, t + 0.25), "repeat at \(t + 0.25)")
            XCTAssertNil(e.tick(now: t + 0.3))
            t += 0.5
        }
        XCTAssertFalse(e.isDown)
    }

    /// One lossy frame (40 cells off by 30) and the clean frame 33 ms later form a run of two active frames, but the
    /// clean frame equals the baseline, so nothing moved. Before, two changed frames within 0.25 s engaged.
    func testALossyFrameFollowedByItsCleanRepeatNeverEngages() {
        let clean = FrameDiffEngageTests.page(ink: 0)
        var e = primed(clean)
        XCTAssertNil(feed(&e, clean, 0.75))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.patch(clean, start: 3000, count: 40, value: 230), 1.0))
        XCTAssertNil(feed(&e, clean, 1.0 + 1.0 / 30))
        XCTAssertNil(feed(&e, clean, 1.25 + 1.0 / 30))
        XCTAssertFalse(e.isDown)
    }

    /// DIFF-B1: the gap is strict. Exactly `maxGapSeconds` apart starts a new run.
    func testTheRunGapIsStrict() {
        let quarter = FrameDiffEngage.Config(maxGapSeconds: 0.25)
        var at = primed(config: quarter)
        XCTAssertNil(feed(&at, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertNil(feed(&at, FrameDiffEngageTests.page(ink: 16), 1.25), "exactly 0.25 s apart: a new run")
        XCTAssertEqual(feed(&at, FrameDiffEngageTests.page(ink: 24), 1.375), .down, "0.125 s after the new run's first frame")
        var inside = primed()
        XCTAssertNil(feed(&inside, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertEqual(feed(&inside, FrameDiffEngageTests.page(ink: 16), 1.1875), .down, "0.1875 s is inside the default 0.2 s")
        var outside = primed()
        XCTAssertNil(feed(&outside, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertNil(feed(&outside, FrameDiffEngageTests.page(ink: 16), 1.25), "0.25 s, the encoder's repeat period")
        XCTAssertFalse(outside.isDown)
    }

    /// DIFF-A3: the run gap is measured on media time (PTS). Two changes 0.6 s apart on the tablet that the network
    /// delivers 5 ms apart do not engage; two frames 33 ms apart on the tablet engage however late the second arrives.
    func testTheRunGapUsesMediaTime() {
        var e = FrameDiffEngage()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 0), 9.0, media: 0.0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 10.000, media: 1.0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 16), 10.005, media: 1.6))
        XCTAssertFalse(e.isDown)
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 24), 11.0, media: 2.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 32), 11.5, media: 2.0 + 1.0 / 30), .down)
    }

    /// Media time that goes backwards (a new stream) ends the run.
    func testMediaTimeGoingBackwardsEndsTheRun() {
        var e = primed()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 5.0, media: 5.0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 16), 5.01, media: 0.1), "PTS restarted: a new run")
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 24), 5.04, media: 0.1 + 1.0 / 30), .down)
    }

    func testUnchangedFramesBetweenChangesDoNotBreakARun() {
        var e = primed()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0625), "an identical frame")
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125), .down, "within 0.2 s of the previous active frame")
    }

    /// DIFF-A4: the first grid of a session opens a 0.5 s settle window. A rotation animation (fully different frames
    /// 33 ms apart) re-primes instead of engaging; after the window a stroke engages normally.
    func testTheSettleWindowAfterASessionStartIgnoresAnAnimation() {
        var e = FrameDiffEngage()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 0), 0))
        var t = 1.0 / 30
        var k = 1
        while t < 0.45 {
            XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: (k % 2) * 20000 + k * 100), t), "animation frame \(k)")
            t += 1.0 / 30
            k += 1
        }
        let settled = FrameDiffEngageTests.page(ink: 20000)
        XCTAssertNil(feed(&e, settled, 0.5))
        XCTAssertNil(feed(&e, settled, 0.75))
        XCTAssertFalse(e.isDown)
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 20008), 1.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 20016), 1.0 + 1.0 / 30), .down)
    }

    func testReleaseAfterOneSecondQuietByTick() {
        var e = primed()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125), .down)
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.5), "repeat")
        XCTAssertNil(e.tick(now: 2.0))
        XCTAssertNil(e.tick(now: 2.124))
        XCTAssertEqual(e.tick(now: 2.125), .up, "1.0 s after the last active frame")
        XCTAssertFalse(e.isDown)
        XCTAssertNil(e.tick(now: 3.0), "one .up only")
    }

    func testReleaseByFeedOfAnUnchangedFrame() {
        var e = primed()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125), .down)
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 16), 2.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 2.125), .up)
    }

    func testActiveFramesWhileDownRefreshTheRelease() {
        var e = primed()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125), .down)
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 17), 1.875), "one more cell of ink while down")
        XCTAssertNil(e.tick(now: 2.125), "the release counts from 1.875 now")
        XCTAssertNil(e.tick(now: 2.874))
        XCTAssertEqual(e.tick(now: 2.875), .up)
    }

    func testReengageNeedsANewRun() {
        var e = primed()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125), .down)
        XCTAssertEqual(e.tick(now: 2.125), .up)
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 24), 5.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 32), 5.125), .down)
    }

    func testAGridOfADifferentSizeOnlyPrimes() {
        var e = primed()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        // Rotation without a reset: a 192 x 144 grid primes, so it is not the second active frame.
        let landscape = [UInt8](repeating: 0, count: 192 * 144)
        XCTAssertNil(e.feed(grid: landscape, width: 192, height: 144, now: 1.0625, mediaTime: 1.0625))
        XCTAssertFalse(e.isDown)
        var inked = landscape
        for i in 0..<8 {
            inked[i] = 200
        }
        XCTAssertNil(e.feed(grid: inked, width: 192, height: 144, now: 2.0, mediaTime: 2.0))
        var more = inked
        for i in 8..<16 {
            more[i] = 200
        }
        XCTAssertEqual(e.feed(grid: more, width: 192, height: 144, now: 2.0625, mediaTime: 2.0625), .down, "no settle window: only init and reset open one")
        // A grid whose count does not match its width x height also only primes.
        XCTAssertNil(e.feed(grid: [1, 2, 3], width: 192, height: 144, now: 2.1, mediaTime: 2.1))
    }

    func testResetForgetsWithoutEmittingAndSettlesAgain() {
        var e = primed()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125), .down)
        e.reset()
        XCTAssertFalse(e.isDown, "reset does not emit .up")
        XCTAssertNil(e.tick(now: 10))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 100), 10), "the first grid after a reset primes")
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 108), 10.0625), "inside the settle window")
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 116), 10.125), "inside the settle window")
        XCTAssertFalse(e.isDown)
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 124), 11.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 132), 11.0625), .down)
    }

    /// DIFF-A2: a crop change re-primes. The shifted grid is not compared with the old one, a held contact stays down
    /// with its release clock running, and nothing is emitted.
    func testReprimeKeepsAHeldContactAndComparesNothingAcrossTheCrop() {
        var e = primed()
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125), .down)
        let shifted = FrameDiffEngageTests.page(ink: 9000, depth: 100)
        e.reprime()
        XCTAssertTrue(e.isDown)
        XCTAssertNil(feed(&e, shifted, 1.2), "primes")
        XCTAssertNil(feed(&e, shifted, 1.45))
        XCTAssertTrue(e.isDown)
        XCTAssertNil(e.tick(now: 2.124))
        XCTAssertEqual(e.tick(now: 2.125), .up, "the release still counts from the last active frame at 1.125")
        // While up: crop steps on a static page never engage, and there is no settle window after a reprime.
        var page = shifted
        for step in 1...6 {
            e.reprime()
            page = FrameDiffEngageTests.page(ink: 9000 + step * 500, depth: 100)
            XCTAssertNil(feed(&e, page, 3.0 + Double(step) / 30), "crop step \(step)")
        }
        XCTAssertFalse(e.isDown)
        XCTAssertNil(feed(&e, FrameDiffEngageTests.patch(page, start: 20000, count: 8, value: 0), 3.3))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.patch(page, start: 20000, count: 16, value: 0), 3.3 + 1.0 / 30), .down)
    }

    func testTickWhileUpDoesNothing() {
        var e = FrameDiffEngage()
        XCTAssertNil(e.tick(now: 0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 0), 0))
        XCTAssertNil(e.tick(now: 100))
    }

    func testCustomConfig() {
        var e = primed(config: FrameDiffEngage.Config(consecutiveFrames: 3, releaseSeconds: 0.5))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 8), 1.0))
        XCTAssertNil(feed(&e, FrameDiffEngageTests.page(ink: 16), 1.125))
        XCTAssertEqual(feed(&e, FrameDiffEngageTests.page(ink: 24), 1.25), .down)
        XCTAssertEqual(e.tick(now: 1.75), .up)
    }

    // MARK: End to end on 1200 x 1600 BGRA frames

    static let streamWidth = 1200
    static let streamHeight = 1600
    /// The default portrait crop: the top 96 of 1600 native px hide the pills.
    static let crop = UVRect(u0: 0, v0: 96.0 / 1600.0, u1: 1, v1: 1)
    static let paper: UInt8 = 235
    static let inkLuma: UInt8 = 25

    /// A 1200 x 1600 BGRA page of luma `paper`.
    static func blankFrame() -> [UInt8] {
        return [UInt8](repeating: paper, count: streamWidth * streamHeight * 4)
    }

    static func setPixel(_ frame: inout [UInt8], _ x: Int, _ y: Int, _ value: UInt8) {
        guard x >= 0, y >= 0, x < streamWidth, y < streamHeight else { return }
        let i = (y * streamWidth + x) * 4
        frame[i] = value
        frame[i + 1] = value
        frame[i + 2] = value
        frame[i + 3] = 255
    }

    /// Inks every pixel whose centre lies within `width` / 2 of the segment (ax, ay)-(bx, by): a line `width` px wide.
    static func drawSegment(_ frame: inout [UInt8], _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, width: Double) {
        let r = width / 2
        let dx = bx - ax
        let dy = by - ay
        let l2 = dx * dx + dy * dy
        let x0 = Int((min(ax, bx) - r - 1).rounded(.down))
        let x1 = Int((max(ax, bx) + r + 1).rounded(.up))
        let y0 = Int((min(ay, by) - r - 1).rounded(.down))
        let y1 = Int((max(ay, by) + r + 1).rounded(.up))
        for y in y0...y1 {
            for x in x0...x1 {
                let px = Double(x) + 0.5
                let py = Double(y) + 0.5
                var t = l2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / l2 : 0
                t = min(max(t, 0), 1)
                let ex = px - (ax + t * dx)
                let ey = py - (ay + t * dy)
                if ex * ex + ey * ey <= r * r {
                    setPixel(&frame, x, y, inkLuma)
                }
            }
        }
    }

    static func fillRect(_ frame: inout [UInt8], x: Int, y: Int, w: Int, h: Int, value: UInt8) {
        for row in y..<(y + h) {
            for col in x..<(x + w) {
                setPixel(&frame, col, row, value)
            }
        }
    }

    static func grid(_ frame: [UInt8]) -> [UInt8] {
        return frame.withUnsafeBytes { raw in
            LumaGrid.sample(bgra: raw, bytesPerRow: streamWidth * 4, width: streamWidth, height: streamHeight, crop: crop, gridWidth: LumaGrid.portraitSize.width, gridHeight: LumaGrid.portraitSize.height)
        }
    }

    private func feedFrame(_ e: inout FrameDiffEngage, _ frame: [UInt8], _ t: Double) -> FrameDiffEngage.Edge? {
        let size = LumaGrid.portraitSize
        return e.feed(grid: FrameDiffEngageTests.grid(frame), width: size.width, height: size.height, now: t, mediaTime: t)
    }

    /// DIFF-A1, the refuter's case: a 3 px diagonal growing 10 px per frame at 30 Hz (300 px/s, real handwriting) on a
    /// 1200 x 1600 stream with the default crop. `.down` within 0.4 s of the first ink; `.up` about 1 s after the line
    /// stops, with the encoder's repeats every 250 ms and the 0.5 s tick. Before, the 48 x 64 centre-pixel grid moved at
    /// most 1 sample per frame against the 7 it needed, so nothing ever engaged.
    func testAThinDiagonalStrokeAtWritingSpeedEngagesWithin0_4sAndReleasesAfterItStops() {
        var frame = FrameDiffEngageTests.blankFrame()
        var e = FrameDiffEngage()
        XCTAssertNil(feedFrame(&e, frame, 0))
        XCTAssertNil(feedFrame(&e, frame, 0.25))
        XCTAssertNil(feedFrame(&e, frame, 0.5))
        XCTAssertNil(feedFrame(&e, frame, 0.75))
        let start = 1.0
        let step = 10.0 / 2.0.squareRoot()
        var x = 300.0
        var y = 400.0
        var downAt: Double?
        var t = start
        for k in 1...30 {
            FrameDiffEngageTests.drawSegment(&frame, x, y, x + step, y + step, width: 3)
            x += step
            y += step
            t = start + Double(k) / 30
            let edge = feedFrame(&e, frame, t)
            if edge == .down {
                XCTAssertNil(downAt, "one .down")
                downAt = t
            } else {
                XCTAssertNil(edge, "frame \(k)")
            }
        }
        guard let down = downAt else {
            XCTFail("a thin stroke at 300 px/s never engaged")
            return
        }
        XCTAssertLessThanOrEqual(down - start, 0.4 + 1e-9, "engaged \(down - start) s after the first ink")
        let stop = t
        var upAt: Double?
        var repeatAt = stop + 0.25
        var tickAt = stop + 0.5
        while upAt == nil, min(repeatAt, tickAt) < stop + 3 {
            if repeatAt <= tickAt {
                if feedFrame(&e, frame, repeatAt) == .up { upAt = repeatAt }
                repeatAt += 0.25
            } else {
                if e.tick(now: tickAt) == .up { upAt = tickAt }
                tickAt += 0.5
            }
        }
        guard let up = upAt else {
            XCTFail("never released")
            return
        }
        XCTAssertGreaterThanOrEqual(up - stop, 1.0 - 1e-9)
        XCTAssertLessThanOrEqual(up - stop, 1.25 + 1e-9)
    }

    /// The same stroke at 100 px/s and 2 px (slow, thin writing; 3.3 px per frame) still engages within 0.6 s.
    func testASlowThinStrokeEngages() {
        var frame = FrameDiffEngageTests.blankFrame()
        var e = FrameDiffEngage()
        XCTAssertNil(feedFrame(&e, frame, 0))
        XCTAssertNil(feedFrame(&e, frame, 0.75))
        let step = 100.0 / 30
        var x = 500.0
        let y = 700.0
        var downAt: Double?
        for k in 1...30 where downAt == nil {
            // A shallow slope, not aligned with a cell row.
            FrameDiffEngageTests.drawSegment(&frame, x, y + Double(k - 1) * 0.6, x + step, y + Double(k) * 0.6, width: 2)
            x += step
            let t = 1.0 + Double(k) / 30
            if feedFrame(&e, frame, t) == .down { downAt = t }
        }
        XCTAssertNotNil(downAt)
        XCTAssertLessThanOrEqual((downAt ?? 99) - 1.0, 0.6 + 1e-9)
    }

    /// Negatives on real frames: a status clock digit inside the crop flips once a minute, a text cursor blinks every
    /// 0.5 s, the encoder repeats every 250 ms. Nothing engages.
    func testAClockDigitAndACursorBlinkOnRealFramesNeverEngage() {
        var frame = FrameDiffEngageTests.blankFrame()
        // Some printed text, so cells are not all blank.
        for line in 0..<10 {
            for word in 0..<12 {
                FrameDiffEngageTests.fillRect(&frame, x: 100 + word * 80, y: 300 + line * 60, w: 60, h: 3, value: 40)
            }
        }
        var e = FrameDiffEngage()
        XCTAssertNil(feedFrame(&e, frame, 0))
        var t = 0.0
        var cursorOn = false
        var events: [FrameDiffEngage.Edge] = []
        for halfSecond in 1...12 {
            t = Double(halfSecond) * 0.5
            cursorOn.toggle()
            FrameDiffEngageTests.fillRect(&frame, x: 600, y: 1000, w: 3, h: 48, value: cursorOn ? FrameDiffEngageTests.inkLuma : FrameDiffEngageTests.paper)
            if halfSecond == 6 {
                // The minute flips: a 60 x 80 px digit is redrawn in the same frame.
                FrameDiffEngageTests.fillRect(&frame, x: 1000, y: 200, w: 60, h: 80, value: FrameDiffEngageTests.paper)
                FrameDiffEngageTests.fillRect(&frame, x: 1010, y: 210, w: 40, h: 8, value: FrameDiffEngageTests.inkLuma)
                FrameDiffEngageTests.fillRect(&frame, x: 1042, y: 210, w: 8, h: 60, value: FrameDiffEngageTests.inkLuma)
            }
            if let edge = feedFrame(&e, frame, t) { events.append(edge) }
            if let edge = feedFrame(&e, frame, t + 0.25) { events.append(edge) }
            if let edge = e.tick(now: t + 0.3) { events.append(edge) }
        }
        XCTAssertEqual(events, [])
        XCTAssertFalse(e.isDown)
    }
}
