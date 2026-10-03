import XCTest
import DaylightKit

/// SPEC 6.7 Presenter Overlay geometry: every number, s = 0 equals passthrough, the morph, the blur weights.
final class OverlayLayoutTests: XCTestCase {
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

    func testConstants() {
        XCTAssertEqual(OverlayLayout.defaultHeightFraction, 0.28)
        XCTAssertEqual(OverlayLayout.margin, 32)
        XCTAssertEqual(OverlayLayout.sourceSquare, 1080)
        XCTAssertEqual(OverlayLayout.minimumCoverage, 0.01)
        XCTAssertEqual(OverlayLayout.failureLimit, 15)
        XCTAssertEqual(OverlayLayout.staleMaskSeconds, 0.5)
        let d = OverlayLayout.Config.default
        XCTAssertEqual(d, OverlayLayout.Config(heightFraction: 0.28, position: .bottomRight, opacity: 1, halo: false))
        XCTAssertEqual(OverlayPosition.allCases, [.bottomRight, .bottomLeft, .topRight, .topLeft])
        XCTAssertEqual(OverlayQuality.allCases.map { $0.rawValue }, ["fast", "balanced", "accurate"])
    }

    func testTargetRectsForAllFourCornersAtDefaultSize() {
        func target(_ p: OverlayPosition) -> PixelRect {
            return OverlayLayout.targetRect(config: OverlayLayout.Config(position: p))
        }
        assertRect(target(.bottomRight), rect(1585.6, 745.6, 302.4, 302.4), "bottomRight")
        assertRect(target(.bottomLeft), rect(32, 745.6, 302.4, 302.4), "bottomLeft")
        assertRect(target(.topRight), rect(1585.6, 32, 302.4, 302.4), "topRight")
        assertRect(target(.topLeft), rect(32, 32, 302.4, 302.4), "topLeft")
        let big = OverlayLayout.targetRect(config: OverlayLayout.Config(heightFraction: 0.5))
        assertRect(big, rect(1920 - 32 - 540, 1080 - 32 - 540, 540, 540), "L = heightFraction * 1080")
    }

    func testCutoutAtZeroIsTheFullFrame() {
        for p in OverlayPosition.allCases {
            let c = OverlayLayout.cutout(progress: 0, config: OverlayLayout.Config(position: p, opacity: 0.5, halo: true))
            assertRect(c.dest, rect(0, 0, 1920, 1080), "\(p)")
            XCTAssertEqual(c.uv, UVRect.full, "\(p)")
            XCTAssertEqual(c.maskStrength, 0)
            XCTAssertEqual(c.opacity, 1, "opacity 1 at s = 0: pixel-identical to passthrough")
            XCTAssertEqual(c.halo, true)
        }
        XCTAssertEqual(OverlayLayout.cutout(progress: -1, config: .default), OverlayLayout.cutout(progress: 0, config: .default), "clamped")
        XCTAssertEqual(OverlayLayout.cutout(progress: 2, config: .default), OverlayLayout.cutout(progress: 1, config: .default), "clamped")
    }

    func testCutoutAtHalfProgress() {
        let c = OverlayLayout.cutout(progress: 0.5, config: .default)
        assertRect(c.dest, rect(792.8, 372.8, 960, 691.2), "cw = 1500, k = 0.64")
        XCTAssertEqual(c.uv.u0, 0.109375, accuracy: 1e-12)
        XCTAssertEqual(c.uv.u1, 1 - 0.109375, accuracy: 1e-12)
        XCTAssertEqual(c.uv.v0, 0)
        XCTAssertEqual(c.uv.v1, 1)
        XCTAssertEqual(c.maskStrength, 0.5)
        XCTAssertEqual(c.opacity, 1)
        let faded = OverlayLayout.cutout(progress: 0.5, config: OverlayLayout.Config(opacity: 0.4))
        XCTAssertEqual(faded.opacity, 0.7, accuracy: 1e-12, "opacity = 1 + (opacity - 1) s")
    }

    func testCutoutAtOneIsTheCentralSquare() {
        let c = OverlayLayout.cutout(progress: 1, config: .default)
        assertRect(c.dest, rect(1585.6, 745.6, 302.4, 302.4))
        XCTAssertEqual(c.uv.u0, 0.21875, accuracy: 1e-12)
        XCTAssertEqual(c.uv.u1, 0.78125, accuracy: 1e-12)
        XCTAssertEqual(c.uv.u0 * 1920, 420, accuracy: 1e-9, "the central 1080 px square")
        XCTAssertEqual(c.uv.u1 * 1920, 1500, accuracy: 1e-9)
        XCTAssertEqual(c.uv.v0, 0)
        XCTAssertEqual(c.uv.v1, 1)
        XCTAssertEqual(c.maskStrength, 1)
        XCTAssertEqual(c.opacity, 1)
        XCTAssertEqual(OverlayLayout.cutout(progress: 1, config: OverlayLayout.Config(opacity: 0.3)).opacity, 0.3, accuracy: 1e-12)
    }

    func testTheMorphNeverDistorts() {
        var s = 0.0
        while s <= 1.0 {
            for p in OverlayPosition.allCases {
                let c = OverlayLayout.cutout(progress: s, config: OverlayLayout.Config(position: p))
                let sourceAspect = (c.uv.u1 - c.uv.u0) * 1920 / ((c.uv.v1 - c.uv.v0) * 1080)
                XCTAssertEqual(c.dest.w / c.dest.h, sourceAspect, accuracy: 1e-9, "s = \(s) \(p)")
            }
            s += 0.05
        }
    }

    func testFramePanelEqualsWhiteboardOnly() {
        for orientation in [StudioLayout.CanvasOrientation.portrait, .landscape] {
            for s in [0.0, 0.25, 0.5, 1.0] {
                let wb = StudioLayout.frame(progress: s, layout: .whiteboardOnly, orientation: orientation, canvasAspect: orientation.aspect, breath: 0.3)
                let f = OverlayLayout.frame(progress: s, orientation: orientation, canvasAspect: orientation.aspect, breath: 0.3, config: .default)
                XCTAssertEqual(f.canvas, wb.canvas, "\(orientation) s = \(s)")
                XCTAssertEqual(f.canvasClip, wb.canvasClip)
                XCTAssertEqual(f.borders, wb.borders)
                XCTAssertEqual(f.dividerColor, wb.dividerColor)
                XCTAssertNil(f.presenter, "no full-frame presenter quad at any s")
                XCTAssertNil(f.divider, "no divider")
                XCTAssertEqual(f.dividerAlpha, 0)
                XCTAssertEqual(f.overlay, OverlayLayout.cutout(progress: s, config: .default))
                XCTAssertNil(wb.overlay, "other layouts carry no cutout")
            }
        }
        let slide = OverlayLayout.frame(progress: 0.25, orientation: .portrait, canvasAspect: 0.75, config: .default)
        assertRect(slide.canvasClip, rect(0, 0, 1920 * 0.25, 1080), "panel slides in from the left with ox = 1920 (s - 1)")
        assertRect(slide.canvas?.dest, rect(555 + 1920 * (0.25 - 1), 0, 810, 1080))
    }

    func testStudioLayoutDelegatesWithTheDefaultConfig() {
        for s in [0.0, 0.5, 1.0] {
            let viaStudio = StudioLayout.frame(progress: s, layout: .overlay, orientation: .portrait, canvasAspect: 0.75, breath: 0)
            let direct = OverlayLayout.frame(progress: s, orientation: .portrait, canvasAspect: 0.75, breath: 0, config: .default)
            XCTAssertEqual(viaStudio, direct, "s = \(s)")
        }
        XCTAssertNil(StudioLayout.passthrough().overlay)
        XCTAssertNil(StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .portrait, canvasAspect: 0.75).overlay)
    }

    func testConfigFromSettingsIsValidated() {
        var s = Settings.defaults
        XCTAssertEqual(OverlayLayout.Config(settings: s), OverlayLayout.Config.default)
        s.overlayScale = 0.4
        s.overlayPosition = .topLeft
        s.overlayOpacity = 0.5
        s.overlayHalo = true
        XCTAssertEqual(OverlayLayout.Config(settings: s), OverlayLayout.Config(heightFraction: 0.4, position: .topLeft, opacity: 0.5, halo: true))
        s.overlayScale = 3
        s.overlayOpacity = 0
        let clamped = OverlayLayout.Config(settings: s)
        XCTAssertEqual(clamped.heightFraction, 0.5)
        XCTAssertEqual(clamped.opacity, 0.3)
    }

    func testSmoothedFormula() {
        XCTAssertEqual(OverlayLayout.smoothed(previous: 1, new: 0, smoothing: 0.6), 0.6, accuracy: 1e-12)
        XCTAssertEqual(OverlayLayout.smoothed(previous: 0.2, new: 0.8, smoothing: 0.6), 0.6 * 0.2 + 0.4 * 0.8, accuracy: 1e-12)
        XCTAssertEqual(OverlayLayout.smoothed(previous: 0.2, new: 0.8, smoothing: 0), 0.8, accuracy: 1e-12, "0 means no smoothing")
        XCTAssertEqual(OverlayLayout.smoothed(previous: 0.2, new: 0.8, smoothing: 0.9), 0.9 * 0.2 + 0.1 * 0.8, accuracy: 1e-12)
    }

    func testFeatherWeights() {
        XCTAssertEqual(OverlayLayout.featherWeights(radius: 0), [1])
        XCTAssertEqual(OverlayLayout.featherWeights(radius: -3), [1])
        for r in 1...8 {
            let w = OverlayLayout.featherWeights(radius: r)
            XCTAssertEqual(w.count, 2 * r + 1, "r = \(r)")
            XCTAssertEqual(Double(w.reduce(0, +)), 1, accuracy: 1e-6, "r = \(r)")
            for i in 0..<w.count {
                XCTAssertEqual(w[i], w[w.count - 1 - i], "symmetric r = \(r)")
                XCTAssertGreaterThan(w[i], 0)
            }
            XCTAssertEqual(w[r], w.max(), "the centre tap is the largest")
        }
        // sigma = max(r, 1) / 2: r = 2 gives sigma 1, weights proportional to exp(-x^2 / 2).
        let w2 = OverlayLayout.featherWeights(radius: 2)
        let raw = [-2.0, -1, 0, 1, 2].map { exp(-($0 * $0) / 2) }
        let sum = raw.reduce(0, +)
        for i in 0..<5 {
            XCTAssertEqual(Double(w2[i]), raw[i] / sum, accuracy: 1e-6)
        }
    }

    func testHaloColourIsAmber() {
        XCTAssertEqual(OverlayLayout.haloColor, RGBA(hex: 0xD97706))
        XCTAssertEqual(OverlayLayout.haloColor, Tokens.amber)
    }
}
