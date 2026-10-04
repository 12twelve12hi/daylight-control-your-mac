import CoreGraphics
import DaylightKit
import Foundation
import IOSurface

/// `--self-test` probes for the share window (docs/product/TOO-SMALL.md section 8) and the follow-the-pen geometry
/// (section 7). No window and no GPU: the renderer is CoreGraphics on two IOSurfaces this probe writes itself.
enum ShareSelfTest {
    static func run(report: SelfTest.Report) {
        let surfaces: CanvasSurfaces
        do {
            surfaces = try CanvasSurfaces(device: nil)
        } catch {
            report.check("share: canvas surfaces", false, "\(error)")
            return
        }
        let before = ShareWindowController.key(for: .layers(surfaces))
        fill(surfaces.ink, x: 100, y: 100, size: 10, bgra: (0x11, 0x11, 0x11, 0xFF))
        fill(surfaces.highlight, x: 500, y: 500, size: 10, bgra: (0x00, 0x80, 0x80, 0x80))
        surfaces.noteWrite()
        report.check("share: a canvas write changes the render key", ShareWindowController.key(for: .layers(surfaces)) != before)
        guard let rendered = ShareWindowController.render(.layers(surfaces)) else {
            report.check("share: renders the page", false)
            return
        }
        let image = rendered.0
        report.check("share: page is 1200x1600 at aspect 0.75", image.width == 1200 && image.height == 1600 && abs(rendered.1 - 0.75) < 1e-9, "\(image.width)x\(image.height) aspect \(rendered.1)")
        let ink = ShareCanvasRenderer.pixel(image, x: 105, y: 105)
        report.check("share: ink at (105, 105) is ink black", close(ink, (0x11, 0x11, 0x11)), describe(ink))
        let paper = ShareCanvasRenderer.pixel(image, x: 600, y: 800)
        let p = Tokens.paperBg
        report.check("share: paper at (600, 800)", close(paper, (byte(p.b), byte(p.g), byte(p.r))), describe(paper))
        // Highlighter multiplied under the ink like daylight_canvas: paper * ((1 - a) + rgb) with a = rgb(r, g) = 0.5.
        let hl = ShareCanvasRenderer.pixel(image, x: 505, y: 505)
        let a = 128.0 / 255.0
        let expected = (byte(p.b * (1 - a)), byte(p.g * (1 - a + a)), byte(p.r * (1 - a + a)))
        report.check("share: highlighter multiplied at (505, 505)", close(hl, expected, tolerance: 4), "\(describe(hl)) want \(expected)")
        let size = ShareWindowController.contentSize(aspect: 0.75, visible: CGSize(width: 1512, height: 944))
        report.check("share: window 85 % of a 1512x944 screen at 3:4 is 602x802", size == CGSize(width: 602, height: 802), "\(size)")
        let zone = PixelRect(x: 0, y: 0, w: 1280, h: 1080)
        let quad = FollowRegion.quad(FollowRegion.fullPage(canvasWidth: 1200, canvasHeight: 1600, zone: zone), canvasWidth: 1200, canvasHeight: 1600, zone: zone)
        report.check("follow: full page equals the Studio Split paper (235, 0, 810, 1080)", near(quad.dest, StudioLayout.fit(aspect: 0.75, into: zone)), "\(quad.dest)")
    }

    static func fill(_ surface: IOSurfaceRef, x: Int, y: Int, size: Int, bgra: (UInt8, UInt8, UInt8, UInt8)) {
        IOSurfaceLock(surface, [], nil)
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let stride = IOSurfaceGetBytesPerRow(surface)
        for row in y..<(y + size) {
            for col in x..<(x + size) {
                let o = row * stride + col * 4
                base[o] = bgra.0
                base[o + 1] = bgra.1
                base[o + 2] = bgra.2
                base[o + 3] = bgra.3
            }
        }
        IOSurfaceUnlock(surface, [], nil)
    }

    static func near(_ a: PixelRect, _ b: PixelRect) -> Bool {
        return abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 && abs(a.w - b.w) < 1e-6 && abs(a.h - b.h) < 1e-6
    }

    static func byte(_ v: Double) -> Int {
        return Int((v * 255).rounded())
    }

    static func close(_ p: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)?, _ want: (Int, Int, Int), tolerance: Int = 2) -> Bool {
        guard let p = p else { return false }
        return abs(Int(p.b) - want.0) <= tolerance && abs(Int(p.g) - want.1) <= tolerance && abs(Int(p.r) - want.2) <= tolerance
    }

    static func describe(_ p: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)?) -> String {
        guard let p = p else { return "no pixel" }
        return "b=\(p.b) g=\(p.g) r=\(p.r) a=\(p.a)"
    }
}
