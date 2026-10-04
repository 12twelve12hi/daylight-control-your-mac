import XCTest
import DaylightKit

/// Follow the pen in the layout frame: the full page reproduces today's frames (slide included), a zoomed quad moves
/// with the slide, and the border lines follow the quad's edges only while those lie inside the zone.
final class FollowFrameTests: XCTestCase {
    private func assertRect(_ a: PixelRect?, _ b: PixelRect?, accuracy: Double = 0.01, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let a = a, let b = b else { return XCTAssertTrue(a == nil && b == nil, "nil mismatch \(message)", file: file, line: line) }
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "x \(message)", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "y \(message)", file: file, line: line)
        XCTAssertEqual(a.w, b.w, accuracy: accuracy, "w \(message)", file: file, line: line)
        XCTAssertEqual(a.h, b.h, accuracy: accuracy, "h \(message)", file: file, line: line)
    }

    private func assertFrame(_ a: StudioLayout.Frame, _ b: StudioLayout.Frame, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        assertRect(a.canvas?.dest, b.canvas?.dest, "canvas dest \(message)", file: file, line: line)
        XCTAssertEqual(a.canvas?.uv.u0 ?? -1, b.canvas?.uv.u0 ?? -1, accuracy: 1e-5, message, file: file, line: line)
        XCTAssertEqual(a.canvas?.uv.u1 ?? -1, b.canvas?.uv.u1 ?? -1, accuracy: 1e-5, message, file: file, line: line)
        XCTAssertEqual(a.canvas?.uv.v0 ?? -1, b.canvas?.uv.v0 ?? -1, accuracy: 1e-5, message, file: file, line: line)
        XCTAssertEqual(a.canvas?.uv.v1 ?? -1, b.canvas?.uv.v1 ?? -1, accuracy: 1e-5, message, file: file, line: line)
        XCTAssertEqual(a.borders.count, b.borders.count, "border count \(message)", file: file, line: line)
        for (x, y) in zip(a.borders, b.borders) { assertRect(x, y, "border \(message)", file: file, line: line) }
        XCTAssertEqual(a.presenter, b.presenter, message, file: file, line: line)
        XCTAssertEqual(a.divider, b.divider, message, file: file, line: line)
        XCTAssertEqual(a.canvasClip, b.canvasClip, message, file: file, line: line)
    }

    func testRestZones() {
        XCTAssertEqual(FollowFrame.restZone(layout: .studioSplit), PixelRect(x: 0, y: 0, w: 1280, h: 1080))
        XCTAssertEqual(FollowFrame.restZone(layout: .whiteboardOnly), PixelRect(x: 0, y: 0, w: 1920, h: 1080))
        XCTAssertNil(FollowFrame.restZone(layout: .overlay))
        XCTAssertEqual(FollowFrame.slideOffset(layout: .studioSplit, progress: 0.5), -640)
        XCTAssertEqual(FollowFrame.slideOffset(layout: .whiteboardOnly, progress: 0.25), -1440)
        XCTAssertEqual(FollowFrame.slideOffset(layout: .whiteboardOnly, progress: 1), 0)
    }

    func testFullPageReproducesTodaysFramesThroughTheSlide() {
        for layout in [LayoutStyle.studioSplit, .whiteboardOnly] {
            let zone = FollowFrame.restZone(layout: layout)!
            let quad = FollowRegion.quad(FollowRegion.fullPage(canvasWidth: 1200, canvasHeight: 1600, zone: zone), canvasWidth: 1200, canvasHeight: 1600, zone: zone)
            for progress in [0.1, 0.5, 0.9, 1.0] {
                let frame = StudioLayout.frame(progress: progress, layout: layout, orientation: .portrait, canvasAspect: 0.75)
                let followed = FollowFrame.apply(quad, to: frame, layout: layout, progress: progress)
                assertFrame(followed, frame, "\(layout) at \(progress)")
            }
        }
    }

    func testZoomedQuadMovesWithTheSlideAndDropsCoveredBorders() {
        let zone = FollowFrame.restZone(layout: .whiteboardOnly)!
        let zoomed = FollowRegion.clamp(FollowRegion.View(cx: 300, cy: 400, zoom: 10), canvasWidth: 1200, canvasHeight: 1600, zone: zone)
        XCTAssertEqual(zoomed.zoom, 0.675 * 2.5, accuracy: 1e-12, "FP1 cap")
        let quad = FollowRegion.quad(zoomed, canvasWidth: 1200, canvasHeight: 1600, zone: zone)
        let rest = FollowFrame.apply(quad, to: StudioLayout.frame(progress: 1, layout: .whiteboardOnly, orientation: .portrait, canvasAspect: 0.75), layout: .whiteboardOnly, progress: 1)
        // 1920 / 1.6875 = 1137.8 canvas px of a 1200 px page: the quad fills the frame width and no page edge shows.
        assertRect(rest.canvas?.dest, quad.dest)
        assertRect(quad.dest, PixelRect(x: 0, y: 0, w: 1920, h: 1080))
        XCTAssertTrue(rest.borders.isEmpty, "no page edge inside the zone, no border line")
        // At zoom 1 the page (1200 output px) is narrower than the frame: both lines sit on the quad's edges.
        let wide = FollowRegion.quad(FollowRegion.clamp(FollowRegion.View(cx: 300, cy: 400, zoom: 1), canvasWidth: 1200, canvasHeight: 1600, zone: zone), canvasWidth: 1200, canvasHeight: 1600, zone: zone)
        let two = FollowFrame.apply(wide, to: StudioLayout.frame(progress: 1, layout: .whiteboardOnly, orientation: .portrait, canvasAspect: 0.75), layout: .whiteboardOnly, progress: 1)
        XCTAssertEqual(two.borders.count, 2)
        XCTAssertEqual(two.borders[0].x, 360, accuracy: 1e-9)
        XCTAssertEqual(two.borders[1].x, 1560, accuracy: 1e-9)
        let sliding = FollowFrame.apply(quad, to: StudioLayout.frame(progress: 0.5, layout: .whiteboardOnly, orientation: .portrait, canvasAspect: 0.75), layout: .whiteboardOnly, progress: 0.5)
        XCTAssertEqual(sliding.canvas!.dest.x, quad.dest.x - 960, accuracy: 1e-9)
        XCTAssertEqual(sliding.canvas!.uv, quad.uv)
    }

    func testStudioSplitZoomFillsTheZoneWithoutBorders() {
        let zone = FollowFrame.restZone(layout: .studioSplit)!
        let view = FollowRegion.clamp(FollowRegion.View(cx: 600, cy: 800, zoom: 10), canvasWidth: 1200, canvasHeight: 1600, zone: zone)
        let quad = FollowRegion.quad(view, canvasWidth: 1200, canvasHeight: 1600, zone: zone)
        let frame = FollowFrame.apply(quad, to: StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .portrait, canvasAspect: 0.75), layout: .studioSplit, progress: 1)
        assertRect(frame.canvas?.dest, zone)
        XCTAssertTrue(frame.borders.isEmpty)
        XCTAssertEqual(frame.divider, StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .portrait, canvasAspect: 0.75).divider, "the divider is untouched")
    }

    func testOverlayAndPassthroughAreNeverFollowed() {
        let quad = QuadSpec(dest: PixelRect(x: 0, y: 0, w: 10, h: 10), uv: .full)
        let overlay = StudioLayout.frame(progress: 1, layout: .overlay, orientation: .portrait, canvasAspect: 0.75)
        XCTAssertEqual(FollowFrame.apply(quad, to: overlay, layout: .overlay, progress: 1), overlay)
        let passthrough = StudioLayout.passthrough()
        XCTAssertEqual(FollowFrame.apply(quad, to: passthrough, layout: .whiteboardOnly, progress: 1), passthrough)
    }

    /// The scripted sequence of the charter on the frame the compositor gets: no zoom on the first stroke, zoom in
    /// after FP6, full page after FP7 without ink, an immediate snap on Clear.
    func testScriptedInkSequence() {
        let layout = LayoutStyle.whiteboardOnly
        let zone = FollowFrame.restZone(layout: layout)!
        var camera = FollowCamera(canvasWidth: 1200, canvasHeight: 1600, zone: zone, now: 0)
        let base = StudioLayout.frame(progress: 1, layout: layout, orientation: .portrait, canvasAspect: 0.75)
        func frame(_ now: Double) -> StudioLayout.Frame {
            return FollowFrame.apply(camera.quad(now: now), to: base, layout: layout, progress: 1)
        }
        let corner = PixelRect(x: 100, y: 100, w: 200, h: 60)
        camera.noteInk(corner, at: 0)
        assertFrame(frame(0), base, "first stroke: no jump")
        camera.noteInk(corner, at: 1)
        assertFrame(frame(2.4), base, "before FP6")
        _ = frame(2.6)
        XCTAssertFalse(camera.isFullPage, "zooming in after FP6")
        let zoomed = frame(4.6)
        XCTAssertGreaterThan(zoomed.canvas!.dest.w, base.canvas!.dest.w * 2, "magnified")
        XCTAssertLessThan(zoomed.canvas!.uv.u1, 1, "a part of the page")
        _ = frame(31.5)
        XCTAssertTrue(camera.isFullPage, "FP7: 30 s without ink returns")
        assertFrame(frame(33.5), base, "settled on the full page")
        camera.noteInk(corner, at: 40)
        camera.noteInk(corner, at: 41)
        _ = frame(41)
        _ = frame(43.6)
        XCTAssertFalse(camera.isFullPage)
        _ = frame(44)
        camera.reset(at: 44)
        XCTAssertTrue(camera.isFullPage)
        assertFrame(frame(44), base, "Clear snaps at once")
    }
}
