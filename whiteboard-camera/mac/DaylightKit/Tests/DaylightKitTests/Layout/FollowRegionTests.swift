import XCTest
import DaylightKit

/// Follow the pen (docs/product/TOO-SMALL.md section 7): every FP number, the full page equals today's layouts, the
/// clamp, and the hysteresis (no jump on the first stroke, immediate follow at the edge, idle return, reset).
final class FollowRegionTests: XCTestCase {
    private let w = 1200.0
    private let h = 1600.0
    /// The Studio Split zone of a portrait canvas at s = 1 and the Whiteboard Only zone (SPEC 6).
    private let split = PixelRect(x: 0, y: 0, w: 1280, h: 1080)
    private let whole = PixelRect(x: 0, y: 0, w: 1920, h: 1080)

    private func assertRect(_ a: PixelRect, _ b: PixelRect, accuracy: Double = 1e-9, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "x \(message)", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "y \(message)", file: file, line: line)
        XCTAssertEqual(a.w, b.w, accuracy: accuracy, "w \(message)", file: file, line: line)
        XCTAssertEqual(a.h, b.h, accuracy: accuracy, "h \(message)", file: file, line: line)
    }

    private func assertView(_ a: FollowRegion.View, _ b: FollowRegion.View, accuracy: Double = 1e-9, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.cx, b.cx, accuracy: accuracy, "cx \(message)", file: file, line: line)
        XCTAssertEqual(a.cy, b.cy, accuracy: accuracy, "cy \(message)", file: file, line: line)
        XCTAssertEqual(a.zoom, b.zoom, accuracy: accuracy, "zoom \(message)", file: file, line: line)
    }

    func testConstants() {
        XCTAssertEqual(FollowRegion.maxMagnification, 2.5, "FP1")
        XCTAssertEqual(FollowRegion.padding, 0.06, "FP2")
        XCTAssertEqual(FollowRegion.activitySeconds, 20, "FP3")
        XCTAssertEqual(FollowRegion.edgeMargin, 0.05, "FP4")
        XCTAssertEqual(FollowRegion.zoomInFactor, 1.25, "FP5")
        XCTAssertEqual(FollowRegion.zoomInDelaySeconds, 2.5, "FP6")
        XCTAssertEqual(FollowRegion.idleReturnSeconds, 30, "FP7")
        XCTAssertEqual(FollowRegion.springK, 60, "FP8")
        XCTAssertEqual(FollowRegion.minimumExtent, 0.10, "FP9")
        let d = FollowRegion.Config.default
        XCTAssertEqual(d, FollowRegion.Config(maxMagnification: 2.5, padding: 0.06, activitySeconds: 20, edgeMargin: 0.05, zoomInFactor: 1.25, zoomInDelaySeconds: 2.5, idleReturnSeconds: 30, springK: 60, minimumExtent: 0.10))
    }

    func testFullPageEqualsTodaysLayoutsInBothZones() {
        for zone in [split, whole] {
            let full = FollowRegion.fullPage(canvasWidth: w, canvasHeight: h, zone: zone)
            XCTAssertEqual(full.zoom, 0.675, accuracy: 1e-12, "1080 / 1600")
            let q = FollowRegion.quad(full, canvasWidth: w, canvasHeight: h, zone: zone)
            assertRect(q.dest, StudioLayout.fit(aspect: StudioLayout.portraitAspect, into: zone), accuracy: 1e-9, "zone \(zone)")
            XCTAssertEqual(q.uv.u0, 0, accuracy: 1e-12)
            XCTAssertEqual(q.uv.v0, 0, accuracy: 1e-12)
            XCTAssertEqual(q.uv.u1, 1, accuracy: 1e-12)
            XCTAssertEqual(q.uv.v1, 1, accuracy: 1e-12)
        }
        // The Studio Split paper is 810 x 1080 centred in the 1280 zone (SPEC 6.1).
        let q = FollowRegion.quad(FollowRegion.fullPage(canvasWidth: w, canvasHeight: h, zone: split), canvasWidth: w, canvasHeight: h, zone: split)
        assertRect(q.dest, PixelRect(x: 235, y: 0, w: 810, h: 1080), accuracy: 1e-9)
    }

    func testClampKeepsZoomBetweenFullPageAndMaxMagnification() {
        let low = FollowRegion.clamp(FollowRegion.View(cx: 600, cy: 800, zoom: 0.1), canvasWidth: w, canvasHeight: h, zone: split)
        XCTAssertEqual(low.zoom, 0.675, accuracy: 1e-12)
        let high = FollowRegion.clamp(FollowRegion.View(cx: 600, cy: 800, zoom: 50), canvasWidth: w, canvasHeight: h, zone: split)
        XCTAssertEqual(high.zoom, 0.675 * 2.5, accuracy: 1e-12, "FP1")
    }

    func testClampKeepsTheVisibleRectangleOnTheCanvas() {
        let z = 0.675 * 2.5
        let corner = FollowRegion.clamp(FollowRegion.View(cx: -500, cy: -500, zoom: z), canvasWidth: w, canvasHeight: h, zone: split)
        let r = FollowRegion.visible(corner, zone: split)
        XCTAssertEqual(r.x, 0, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0, accuracy: 1e-9)
        let far = FollowRegion.clamp(FollowRegion.View(cx: 5000, cy: 5000, zoom: z), canvasWidth: w, canvasHeight: h, zone: split)
        let s = FollowRegion.visible(far, zone: split)
        XCTAssertEqual(s.x + s.w, w, accuracy: 1e-9)
        XCTAssertEqual(s.y + s.h, h, accuracy: 1e-9)
        // A zoomed view fills the whole zone with a canvas sub-rectangle.
        let q = FollowRegion.quad(corner, canvasWidth: w, canvasHeight: h, zone: split)
        assertRect(q.dest, split, accuracy: 1e-9)
        XCTAssertEqual(q.uv.u0, 0, accuracy: 1e-12)
        XCTAssertEqual(q.uv.v0, 0, accuracy: 1e-12)
        XCTAssertEqual(q.uv.u1, (1280 / z) / w, accuracy: 1e-12)
        XCTAssertEqual(q.uv.v1, (1080 / z) / h, accuracy: 1e-12)
    }

    func testAxisWiderThanTheCanvasStaysCentred() {
        // Whole zone at a zoom where the visible width (1920 / 1.2 = 1600) is wider than the canvas: centred in x.
        let v = FollowRegion.clamp(FollowRegion.View(cx: 100, cy: 100, zoom: 1.2), canvasWidth: w, canvasHeight: h, zone: whole)
        XCTAssertEqual(v.cx, 600, accuracy: 1e-12)
        XCTAssertEqual(v.cy, 1080 / 1.2 / 2, accuracy: 1e-12, "y clamps to the top edge")
        let q = FollowRegion.quad(v, canvasWidth: w, canvasHeight: h, zone: whole)
        XCTAssertEqual(q.dest.x, (1920 - 1200 * 1.2) / 2, accuracy: 1e-9, "cream margins left and right")
        XCTAssertEqual(q.dest.w, 1200 * 1.2, accuracy: 1e-9)
        XCTAssertEqual(q.dest.h, 1080, accuracy: 1e-9)
    }

    func testFitPadsTheBoxAndWidensATinyOne() {
        let free = FollowRegion.Config(maxMagnification: 100)
        // FP9 and FP2: a dot becomes 120 px wide plus 72 px on each side = 264 px; 1080 / 264 limits the zoom.
        let dot = FollowRegion.fit(PixelRect(x: 600, y: 800, w: 0, h: 0), canvasWidth: w, canvasHeight: h, zone: split, config: free)
        XCTAssertEqual(dot.zoom, 1080.0 / 264.0, accuracy: 1e-12)
        // A 600 x 200 line of writing: (600 + 144) wide limits the zoom in the 1280 x 1080 zone.
        let line = FollowRegion.fit(PixelRect(x: 300, y: 700, w: 600, h: 200), canvasWidth: w, canvasHeight: h, zone: split, config: free)
        XCTAssertEqual(line.zoom, 1280.0 / 744.0, accuracy: 1e-12)
        XCTAssertEqual(line.cx, 600, accuracy: 1e-12)
        XCTAssertEqual(line.cy, 800, accuracy: 1e-12)
        // With the default FP1 cap the same line is shown at 2.5 x the full page at most.
        let capped = FollowRegion.fit(PixelRect(x: 300, y: 700, w: 100, h: 50), canvasWidth: w, canvasHeight: h, zone: split)
        XCTAssertEqual(capped.zoom, 0.675 * 2.5, accuracy: 1e-12)
        // The whole page as the box gives the full page zoom.
        let page = FollowRegion.fit(PixelRect(x: 0, y: 0, w: w, h: h), canvasWidth: w, canvasHeight: h, zone: split)
        assertView(page, FollowRegion.fullPage(canvasWidth: w, canvasHeight: h, zone: split))
    }

    func testFollowGainsLegibilityInATile() {
        // A 320 px wide gallery tile shows the 1920 px frame at 1/6: the full page paper is 135 px wide there.
        let tileScale = 320.0 / 1920.0
        let fullPaperWidth = w * 0.675 * tileScale
        XCTAssertEqual(fullPaperWidth, 135, accuracy: 1e-9)
        // At the FP1 cap the paper's detail is 2.5 times larger on the far side: 337.5 tile px per page width.
        let capped = FollowRegion.fit(PixelRect(x: 500, y: 700, w: 50, h: 20), canvasWidth: w, canvasHeight: h, zone: split)
        XCTAssertEqual(w * capped.zoom * tileScale, 337.5, accuracy: 1e-9)
    }

    func testNoJumpOnTheFirstStrokeThenZoomAfterTheDelay() {
        var cam = FollowCamera(canvasWidth: w, canvasHeight: h, zone: split, now: 0)
        let full = FollowRegion.fullPage(canvasWidth: w, canvasHeight: h, zone: split)
        cam.noteInk(PixelRect(x: 400, y: 700, w: 300, h: 100), at: 0)
        cam.update(now: 0)
        XCTAssertEqual(cam.target, full, "FP6: the first stroke does not move the camera")
        cam.update(now: 2.4)
        XCTAssertEqual(cam.target, full)
        cam.update(now: 2.5)
        XCTAssertNotEqual(cam.target, full, "FP6: zooms after 2.5 s")
        XCTAssertGreaterThanOrEqual(cam.target.zoom, full.zoom * 1.25, "FP5")
        // The spring then settles on the target (FP8).
        let settled = cam.update(now: 4.5)
        assertView(settled, cam.target, accuracy: 1e-2)
    }

    func testZoomInWaitsForAContinuousRun() {
        var cam = FollowCamera(canvasWidth: w, canvasHeight: h, zone: split, now: 0)
        let full = FollowRegion.fullPage(canvasWidth: w, canvasHeight: h, zone: split)
        // A box that only allows 1.11 x the full page (1080 / 1444 against 0.675, below FP5) never starts the timer.
        let wide = PixelRect(x: 40, y: 150, w: 1120, h: 1300)
        cam.noteInk(wide, at: 0)
        for t in stride(from: 0.0, through: 10.0, by: 0.5) { cam.update(now: t) }
        XCTAssertEqual(cam.target, full)
    }

    func testInkPastTheEdgeMovesTheCameraAtOnce() {
        var cam = FollowCamera(canvasWidth: w, canvasHeight: h, zone: split, now: 0)
        cam.noteInk(PixelRect(x: 100, y: 100, w: 300, h: 80), at: 0)
        cam.update(now: 0)
        cam.update(now: 2.5)
        let zoomed = cam.target
        let seen = FollowRegion.visible(zoomed, zone: split)
        XCTAssertGreaterThan(seen.y + seen.h, 0)
        XCTAssertLessThan(seen.y + seen.h, 1400, "zoomed into the top of the page")
        // A new line far below: FP4 moves the camera on the very next update, no delay.
        cam.noteInk(PixelRect(x: 100, y: 1400, w: 300, h: 80), at: 3)
        cam.update(now: 3)
        XCTAssertNotEqual(cam.target, zoomed)
        let now = FollowRegion.visible(cam.target, zone: split)
        XCTAssertGreaterThanOrEqual(now.y + now.h, 1480 - 1e-9, "the new ink is in view")
    }

    func testInkAtThePageEdgeOfAFullPageViewIsInside() {
        let full = FollowRegion.fullPage(canvasWidth: w, canvasHeight: h, zone: split)
        let seen = FollowRegion.intersect(FollowRegion.visible(full, zone: split), PixelRect(x: 0, y: 0, w: w, h: h))
        assertRect(seen, PixelRect(x: 0, y: 0, w: w, h: h), accuracy: 1e-9)
        let grown = FollowRegion.expandToCanvasEdges(seen, canvas: PixelRect(x: 0, y: 0, w: w, h: h), margin: 10)
        XCTAssertTrue(FollowRegion.contains(grown, PixelRect(x: 0, y: 0, w: 50, h: 1600), margin: 10))
    }

    func testIdleReturnsToTheFullPageAfterThirtySeconds() {
        var cam = FollowCamera(canvasWidth: w, canvasHeight: h, zone: split, now: 0)
        let full = FollowRegion.fullPage(canvasWidth: w, canvasHeight: h, zone: split)
        cam.noteInk(PixelRect(x: 400, y: 700, w: 300, h: 100), at: 0)
        cam.update(now: 0)
        cam.update(now: 2.5)
        XCTAssertNotEqual(cam.target, full)
        cam.update(now: 20.5)
        XCTAssertNil(cam.activeBox, "FP3: the box left the 20 s window")
        XCTAssertNotEqual(cam.target, full, "between 20 s and 30 s the camera stays")
        cam.update(now: 29.9)
        XCTAssertNotEqual(cam.target, full)
        cam.update(now: 30)
        XCTAssertEqual(cam.target, full, "FP7")
    }

    func testResetSnapsToTheFullPage() {
        var cam = FollowCamera(canvasWidth: w, canvasHeight: h, zone: split, now: 0)
        cam.noteInk(PixelRect(x: 400, y: 700, w: 300, h: 100), at: 0)
        cam.update(now: 0)
        cam.update(now: 2.5)
        cam.update(now: 3)
        cam.reset(at: 3)
        let full = FollowRegion.fullPage(canvasWidth: w, canvasHeight: h, zone: split)
        assertView(cam.update(now: 3), full, accuracy: 1e-9)
        XCTAssertTrue(cam.isFullPage)
        XCTAssertNil(cam.activeBox)
    }

    func testEveryAnimatedFrameStaysClamped() {
        var cam = FollowCamera(canvasWidth: w, canvasHeight: h, zone: split, now: 0)
        cam.noteInk(PixelRect(x: 20, y: 20, w: 100, h: 60), at: 0)
        cam.update(now: 0)
        cam.update(now: 2.5)
        cam.noteInk(PixelRect(x: 1050, y: 1500, w: 100, h: 60), at: 3)
        let z0 = 0.675
        var t = 3.0
        while t < 6 {
            let v = cam.update(now: t)
            XCTAssertGreaterThanOrEqual(v.zoom, z0 - 1e-9)
            XCTAssertLessThanOrEqual(v.zoom, z0 * 2.5 + 1e-9)
            let q = FollowRegion.quad(v, canvasWidth: w, canvasHeight: h, zone: split)
            XCTAssertGreaterThanOrEqual(q.uv.u0, -1e-12)
            XCTAssertGreaterThanOrEqual(q.uv.v0, -1e-12)
            XCTAssertLessThanOrEqual(q.uv.u1, 1 + 1e-12)
            XCTAssertLessThanOrEqual(q.uv.v1, 1 + 1e-12)
            XCTAssertGreaterThanOrEqual(q.dest.x, split.x - 1e-9)
            XCTAssertLessThanOrEqual(q.dest.x + q.dest.w, split.x + split.w + 1e-9)
            t += 1.0 / 30.0
        }
    }

    func testGeometryChangeRefitsTheActiveBox() {
        var cam = FollowCamera(canvasWidth: w, canvasHeight: h, zone: split, now: 0)
        let box = PixelRect(x: 400, y: 700, w: 300, h: 100)
        cam.noteInk(box, at: 0)
        cam.setGeometry(canvasWidth: w, canvasHeight: h, zone: whole, at: 1)
        assertView(cam.target, FollowRegion.fit(box, canvasWidth: w, canvasHeight: h, zone: whole))
        assertView(cam.update(now: 1), cam.target, accuracy: 1e-9, "snapped, no animation across a layout change")
    }

    func testHelpers() {
        XCTAssertNil(FollowRegion.boundingBox(xs: [], ys: []))
        XCTAssertEqual(FollowRegion.boundingBox(xs: [3, 1, 2], ys: [5, 9, 7]), PixelRect(x: 1, y: 5, w: 2, h: 4))
        XCTAssertEqual(FollowRegion.union(PixelRect(x: 0, y: 0, w: 1, h: 1), PixelRect(x: 2, y: 3, w: 1, h: 1)), PixelRect(x: 0, y: 0, w: 3, h: 4))
        XCTAssertEqual(FollowRegion.intersect(PixelRect(x: 0, y: 0, w: 2, h: 2), PixelRect(x: 1, y: 1, w: 5, h: 5)), PixelRect(x: 1, y: 1, w: 1, h: 1))
        XCTAssertEqual(FollowRegion.intersect(PixelRect(x: 0, y: 0, w: 1, h: 1), PixelRect(x: 5, y: 5, w: 1, h: 1)).w, 0)
        XCTAssertTrue(FollowRegion.contains(PixelRect(x: 0, y: 0, w: 10, h: 10), PixelRect(x: 2, y: 2, w: 6, h: 6), margin: 2))
        XCTAssertFalse(FollowRegion.contains(PixelRect(x: 0, y: 0, w: 10, h: 10), PixelRect(x: 1, y: 2, w: 6, h: 6), margin: 2))
    }
}
