import XCTest
import DaylightKit

/// SPEC section 6 and acceptance A5: every number, and s = 0 equals passthrough for the presenter.
final class LayoutTests: XCTestCase {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PixelRect {
        return PixelRect(x: x, y: y, w: w, h: h)
    }

    private func assertRect(_ a: PixelRect?, _ b: PixelRect, accuracy: Double = 1e-9, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let a = a else { return XCTFail("nil rect \(message)", file: file, line: line) }
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "x \(message)", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "y \(message)", file: file, line: line)
        XCTAssertEqual(a.w, b.w, accuracy: accuracy, "w \(message)", file: file, line: line)
        XCTAssertEqual(a.h, b.h, accuracy: accuracy, "h \(message)", file: file, line: line)
    }

    // 6.1 Static Studio Split, portrait canvas

    func testStaticStudioSplitPortrait() throws {
        let f = StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .portrait, canvasAspect: 3.0 / 4.0, breath: 0)
        assertRect(f.canvas?.dest, rect(235, 0, 810, 1080), "canvas")
        XCTAssertEqual(f.canvas?.uv, UVRect.full)
        assertRect(f.canvasClip, rect(0, 0, 1280, 1080), "studio zone")
        XCTAssertEqual(f.borders.count, 2)
        assertRect(f.borders[0], rect(235, 0, 1, 1080), "left border")
        assertRect(f.borders[1], rect(1045, 0, 1, 1080), "right border")
        assertRect(f.divider, rect(1279, 0, 2, 1080), "divider")
        XCTAssertEqual(f.dividerAlpha, 1)
        XCTAssertEqual(f.dividerColor, Tokens.inkBlack)
        let presenter = try XCTUnwrap(f.presenter)
        assertRect(presenter.dest, rect(1280, 0, 640, 1080), "presenter column")
        XCTAssertEqual(presenter.uv.u0, 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(presenter.uv.u1, 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(presenter.uv.v0, 0)
        XCTAssertEqual(presenter.uv.v1, 1)
        XCTAssertEqual(presenter.uv.u0 * 1920, 640, accuracy: 1e-9, "source x from 640")
        XCTAssertEqual(presenter.uv.u1 * 1920, 1280, accuracy: 1e-9, "source x to 1280 (640 px, no scaling)")
    }

    func testClipSpaceValuesAtS1() {
        let f = StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .portrait, canvasAspect: 3.0 / 4.0)
        let canvas = StudioLayout.clip(f.canvas!.dest)
        XCTAssertEqual(canvas.l, -0.75521, accuracy: 1e-5)
        XCTAssertEqual(canvas.t, 1)
        XCTAssertEqual(canvas.r, 0.08854, accuracy: 1e-5)
        XCTAssertEqual(canvas.b, -1)
        let presenter = StudioLayout.clip(f.presenter!.dest)
        XCTAssertEqual(presenter.l, 0.33333, accuracy: 1e-5)
        XCTAssertEqual(presenter.r, 1)
        let divider = StudioLayout.clip(f.divider!)
        XCTAssertEqual(divider.l, 0.33229, accuracy: 1e-5)
        XCTAssertEqual(divider.r, 0.33438, accuracy: 1e-5)
        // Conversion formulas.
        let c = StudioLayout.clip(PixelRect(x: 0, y: 0, w: 1920, h: 1080))
        XCTAssertEqual(c.l, -1)
        XCTAssertEqual(c.t, 1)
        XCTAssertEqual(c.r, 1)
        XCTAssertEqual(c.b, -1)
    }

    // 6.2 Animation

    func testProgressZeroEqualsPassthroughForThePresenter() {
        let p = StudioLayout.passthrough()
        for layout in [LayoutStyle.studioSplit, .whiteboardOnly] {
            for orientation in [StudioLayout.CanvasOrientation.portrait, .landscape] {
                let f = StudioLayout.frame(progress: 0, layout: layout, orientation: orientation, canvasAspect: orientation.aspect)
                XCTAssertEqual(f.presenter, p.presenter, "\(layout) \(orientation)")
                XCTAssertEqual(f.canvasClip?.w ?? -1, 0, "nothing of the panel is visible at s = 0")
                XCTAssertEqual(f.dividerAlpha, 0)
            }
        }
        assertRect(p.presenter?.dest, rect(0, 0, 1920, 1080))
        XCTAssertEqual(p.presenter?.uv, UVRect.full)
        XCTAssertNil(p.canvas)
        XCTAssertNil(p.canvasClip)
        XCTAssertNil(p.divider)
        XCTAssertTrue(p.borders.isEmpty)
    }

    func testAnimationAtHalfProgress() throws {
        let s = 0.5
        let d = 1280 * s
        let f = StudioLayout.frame(progress: s, layout: .studioSplit, orientation: .portrait, canvasAspect: 3.0 / 4.0)
        let presenter = try XCTUnwrap(f.presenter)
        assertRect(presenter.dest, rect(d, 0, 1920 - d, 1080), "presenter dest")
        XCTAssertEqual(presenter.uv.u0, d / 3840, accuracy: 1e-12)
        XCTAssertEqual(presenter.uv.u1, 1 - d / 3840, accuracy: 1e-12)
        XCTAssertEqual((presenter.uv.u1 - presenter.uv.u0) * 1920, presenter.dest.w, accuracy: 1e-9, "no scaling at any s")
        let ox = d - 1280
        assertRect(f.canvas?.dest, rect(235 + ox, 0, 810, 1080), "canvas moves with the panel")
        assertRect(f.borders[0], rect(235 + ox, 0, 1, 1080))
        assertRect(f.borders[1], rect(1045 + ox, 0, 1, 1080))
        assertRect(f.canvasClip, rect(0, 0, d, 1080), "scissor")
        assertRect(f.divider, rect(d - 1, 0, 2, 1080))
        XCTAssertEqual(f.dividerAlpha, s)
    }

    func testPresenterNeverScalesDuringTheSlide() {
        var s = 0.0
        while s <= 1.0 {
            let f = StudioLayout.frame(progress: s, layout: .studioSplit, orientation: .portrait, canvasAspect: 0.75)
            let p = f.presenter!
            XCTAssertEqual((p.uv.u1 - p.uv.u0) * 1920, p.dest.w, accuracy: 1e-9, "s = \(s)")
            XCTAssertEqual(p.dest.h, 1080)
            s += 0.05
        }
    }

    func testPreWarningOnlyChangesTheDividerColour() {
        let plain = StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .portrait, canvasAspect: 0.75, breath: 0)
        let warm = StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .portrait, canvasAspect: 0.75, breath: 1)
        XCTAssertEqual(warm.presenter, plain.presenter)
        XCTAssertEqual(warm.canvas, plain.canvas)
        XCTAssertEqual(warm.divider, plain.divider)
        XCTAssertEqual(warm.borders, plain.borders)
        XCTAssertEqual(plain.dividerColor, Tokens.inkBlack)
        XCTAssertEqual(warm.dividerColor, Tokens.amber)
        let half = StudioLayout.amberBreath(weight: 0.5)
        XCTAssertEqual(half.r, (Tokens.inkBlack.r + Tokens.amber.r) / 2, accuracy: 1e-12)
        XCTAssertEqual(half.g, (Tokens.inkBlack.g + Tokens.amber.g) / 2, accuracy: 1e-12)
        XCTAssertEqual(half.b, (Tokens.inkBlack.b + Tokens.amber.b) / 2, accuracy: 1e-12)
        XCTAssertEqual(half.a, 1)
        XCTAssertEqual(StudioLayout.amberBreath(weight: 2), Tokens.amber, "clamped")
        XCTAssertEqual(StudioLayout.amberBreath(weight: -1), Tokens.inkBlack)
    }

    // 6.3 Whiteboard Only

    func testWhiteboardOnlyPortrait() {
        let f = StudioLayout.frame(progress: 1, layout: .whiteboardOnly, orientation: .portrait, canvasAspect: 0.75)
        assertRect(f.canvas?.dest, rect(555, 0, 810, 1080), "canvas")
        assertRect(f.borders[0], rect(555, 0, 1, 1080))
        assertRect(f.borders[1], rect(1365, 0, 1, 1080))
        XCTAssertNil(f.presenter, "no presenter")
        XCTAssertNil(f.divider, "no divider")
        XCTAssertEqual(f.dividerAlpha, 0)
        assertRect(f.canvasClip, rect(0, 0, 1920, 1080))
    }

    func testWhiteboardOnlySlideEntersFromTheLeft() {
        let s = 0.25
        let ox = 1920 * (s - 1)
        let f = StudioLayout.frame(progress: s, layout: .whiteboardOnly, orientation: .portrait, canvasAspect: 0.75)
        assertRect(f.canvas?.dest, rect(555 + ox, 0, 810, 1080))
        assertRect(f.canvasClip, rect(0, 0, 1920 * s, 1080), "the panel covers the left quarter")
        XCTAssertEqual(f.presenter, StudioLayout.passthrough().presenter, "the presenter is still under the panel")
    }

    // 6.4 Landscape canvas

    func testLandscapeStudioSplit() throws {
        let f = StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .landscape, canvasAspect: 4.0 / 3.0)
        assertRect(f.canvas?.dest, rect(0, 0, 1440, 1080), "canvas")
        let presenter = try XCTUnwrap(f.presenter)
        assertRect(presenter.dest, rect(1440, 0, 480, 1080), "presenter dest")
        XCTAssertEqual(presenter.uv.u0 * 1920, 720, accuracy: 1e-9, "source x from 720")
        XCTAssertEqual(presenter.uv.u1 * 1920, 1200, accuracy: 1e-9, "source x to 1200 (central 480 px)")
        assertRect(f.divider, rect(1439, 0, 2, 1080))
        assertRect(f.canvasClip, rect(0, 0, 1440, 1080))
        // Animation with d = 1440 s.
        let half = StudioLayout.frame(progress: 0.5, layout: .studioSplit, orientation: .landscape, canvasAspect: 4.0 / 3.0)
        assertRect(half.presenter?.dest, rect(720, 0, 1200, 1080))
        XCTAssertEqual(half.presenter!.uv.u0 * 1920, 360, accuracy: 1e-9)
        XCTAssertEqual(half.presenter!.uv.u1 * 1920, 1560, accuracy: 1e-9)
        assertRect(half.canvas?.dest, rect(-720, 0, 1440, 1080))
    }

    func testLandscapeWhiteboardOnly() {
        let f = StudioLayout.frame(progress: 1, layout: .whiteboardOnly, orientation: .landscape, canvasAspect: 4.0 / 3.0)
        assertRect(f.canvas?.dest, rect(240, 0, 1440, 1080), "canvas")
        assertRect(f.borders[0], rect(240, 0, 1, 1080))
        assertRect(f.borders[1], rect(1680, 0, 1, 1080))
    }

    func testAspectFitting43IntoThePortraitSlotIsNotDone() {
        // Aspect-fitting 4:3 into the 810x1080 slot would give a 608 px tall picture; the landscape layout avoids it.
        let fitted = StudioLayout.fit(aspect: 4.0 / 3.0, into: PixelRect(x: 235, y: 0, w: 810, h: 1080))
        XCTAssertEqual(fitted.h, 607.5, accuracy: 1e-9)
        let landscape = StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .landscape, canvasAspect: 4.0 / 3.0)
        XCTAssertEqual(landscape.canvas?.dest.h, 1080)
    }

    func testOrientationFromSize() {
        XCTAssertEqual(StudioLayout.CanvasOrientation(width: 1200, height: 1600), .portrait)
        XCTAssertEqual(StudioLayout.CanvasOrientation(width: 1600, height: 1200), .landscape)
        XCTAssertEqual(StudioLayout.CanvasOrientation.portrait.zoneWidth, 1280)
        XCTAssertEqual(StudioLayout.CanvasOrientation.landscape.zoneWidth, 1440)
    }

    // 6.5 Mirror crop fit

    func testMirrorCropFit() {
        // Default portrait crop 1200x1504 (top 96 px removed) fits at scale 0.675 to 810x1015 with about 32 px bars.
        let aspect = 1200.0 / 1504.0
        let f = StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .portrait, canvasAspect: aspect)
        let canvas = f.canvas!.dest
        XCTAssertEqual(canvas.w, 810, accuracy: 1e-9)
        XCTAssertEqual(canvas.h, 1015.2, accuracy: 1e-9)
        XCTAssertEqual(canvas.w / 1200, 0.675, accuracy: 1e-9, "scale")
        XCTAssertEqual(canvas.y, (1080 - 1015.2) / 2, accuracy: 1e-9, "about 32 px cream bars top and bottom")
        XCTAssertEqual(canvas.x, 235, accuracy: 1e-9)
        XCTAssertEqual(f.borders[0].x, 235, "borders stay at the paper slot")
    }

    // fit

    func testFit() {
        let slot = PixelRect(x: 0, y: 0, w: 1280, h: 1080)
        assertRect(StudioLayout.fit(aspect: 0.75, into: slot), rect(235, 0, 810, 1080), "3:4 height-limited")
        assertRect(StudioLayout.fit(aspect: 4.0 / 3.0, into: PixelRect(x: 0, y: 0, w: 1440, h: 1080)), rect(0, 0, 1440, 1080), "4:3 exact")
        assertRect(StudioLayout.fit(aspect: 4.0 / 3.0, into: PixelRect(x: 0, y: 0, w: 1920, h: 1080)), rect(240, 0, 1440, 1080), "4:3 into full width")
        assertRect(StudioLayout.fit(aspect: 2, into: PixelRect(x: 0, y: 0, w: 100, h: 100)), rect(0, 25, 100, 50), "width-limited")
    }

    func testTokens() {
        XCTAssertEqual(Tokens.inkBlack, RGBA(hex: 0x111111))
        XCTAssertEqual(Tokens.paperBg, RGBA(hex: 0xFAF8F5))
        XCTAssertEqual(Tokens.surfaceCream, RGBA(hex: 0xEAE5DC))
        XCTAssertEqual(Tokens.borderSubtle, RGBA(hex: 0xCDC6B8))
        XCTAssertEqual(Tokens.amber, RGBA(hex: 0xD97706))
        XCTAssertEqual(Tokens.amber.r, 0xD9 / 255.0, accuracy: 1e-12)
        XCTAssertEqual(Tokens.amber.g, 0x77 / 255.0, accuracy: 1e-12)
        XCTAssertEqual(Tokens.amber.b, 0x06 / 255.0, accuracy: 1e-12)
    }
}
