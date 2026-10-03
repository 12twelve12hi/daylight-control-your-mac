import CoreVideo
import DaylightKit
import Metal
import XCTest
@testable import Daylight

/// SPEC 6.7 compositor pixels with synthetic r8 masks (OverlaySelfTest.splitMask: 1 where u < 0.5). Skipped without a
/// Metal device, like the other render tests.
final class OverlayCompositorTests: XCTestCase {
    private struct Rig {
        let device: MTLDevice
        let compositor: Compositor
        let surfaces: CanvasSurfaces
        let pool: OutputPool
        let presenter: CVPixelBuffer
        let mask: MTLTexture

        func render(_ frame: StudioLayout.Frame, overlay: Compositor.OverlayInput?) -> CVPixelBuffer {
            let target = pool.acquire()!
            _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: frame, overlay: overlay), into: target)
            pool.release(target)
            return target
        }
    }

    private func rig() throws -> Rig {
        let device = try OverlayFakes.device()
        return Rig(
            device: device,
            compositor: try Compositor(device: device),
            surfaces: try CanvasSurfaces(device: device),
            pool: try OutputPool(),
            presenter: SelfTest.gradientBuffer(width: 1920, height: 1080)!,
            mask: OverlaySelfTest.splitMask(device: device)!)
    }

    private func describe(_ buffer: CVPixelBuffer, _ p: (x: Int, y: Int)) -> String {
        return "(\(p.x), \(p.y)) " + SelfTest.describe(SelfTest.pixel(buffer, p.x, p.y))
    }

    func testProgressZeroIsIdenticalToPassthrough() throws {
        let r = try rig()
        let overlay = r.render(OverlaySelfTest.frame(progress: 0), overlay: Compositor.OverlayInput(mask: r.mask))
        let passthrough = r.render(StudioLayout.passthrough(), overlay: nil)
        for (x, y) in [(0, 0), (100, 100), (960, 540), (1300, 700), (1800, 1000), (1919, 1079)] {
            XCTAssertTrue(SelfTest.close(SelfTest.pixel(overlay, x, y), SelfTest.pixel(passthrough, x, y), tolerance: 0), "s = 0 \(describe(overlay, (x, y))) vs passthrough \(describe(passthrough, (x, y)))")
            XCTAssertTrue(SelfTest.close(SelfTest.pixel(overlay, x, y), SelfTest.pixel(r.presenter, x, y), tolerance: 1))
        }
    }

    func testFullProgressMatteLeftClearRightAndPaper() throws {
        let r = try rig()
        let frame = OverlaySelfTest.frame(progress: 1)
        let cutout = try XCTUnwrap(frame.overlay)
        XCTAssertEqual(cutout.dest.x, 1585.6, accuracy: 1e-9, "bottom right at the defaults")
        let target = r.render(frame, overlay: Compositor.OverlayInput(mask: r.mask))
        let left = OverlaySelfTest.point(in: cutout, fx: 0.25, fy: 0.5)
        let source = OverlaySelfTest.sourcePoint(cutout, x: left.x, y: left.y)
        XCTAssertTrue(SelfTest.close(SelfTest.pixel(target, left.x, left.y), SelfTest.pixel(r.presenter, source.x, source.y), tolerance: 3), "matte shows the presenter: \(describe(target, left)) vs source \(describe(r.presenter, source))")
        let right = OverlaySelfTest.point(in: cutout, fx: 0.75, fy: 0.5)
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, right.x, right.y), Tokens.surfaceCream), "clear half shows the cream: \(describe(target, right))")
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 960, 540), Tokens.paperBg), "paper: \(describe(target, (960, 540)))")
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 100, 100), Tokens.surfaceCream), "no full-frame presenter quad")
    }

    func testMaskStrengthZeroDrawsTheCameraRectangle() throws {
        let r = try rig()
        var frame = OverlaySelfTest.frame(progress: 1)
        frame.overlay?.maskStrength = 0
        let cutout = try XCTUnwrap(frame.overlay)
        let target = r.render(frame, overlay: Compositor.OverlayInput(mask: r.mask))
        let right = OverlaySelfTest.point(in: cutout, fx: 0.75, fy: 0.5)
        let source = OverlaySelfTest.sourcePoint(cutout, x: right.x, y: right.y)
        XCTAssertTrue(SelfTest.close(SelfTest.pixel(target, right.x, right.y), SelfTest.pixel(r.presenter, source.x, source.y), tolerance: 3), "maskStrength 0 ignores the mask: \(describe(target, right))")
        // No mask at all (missing or stale) is the same rectangle through the 1x1 white mask.
        let unmasked = r.render(OverlaySelfTest.frame(progress: 1), overlay: Compositor.OverlayInput(mask: nil))
        XCTAssertTrue(SelfTest.close(SelfTest.pixel(unmasked, right.x, right.y), SelfTest.pixel(r.presenter, source.x, source.y), tolerance: 3), "nil mask: \(describe(unmasked, right))")
    }

    func testHaloShowsAtTheMaskEdgeOnlyWhenEnabled() throws {
        let r = try rig()
        let haloFrame = OverlaySelfTest.frame(progress: 1, config: OverlayLayout.Config(halo: true))
        let cutout = try XCTUnwrap(haloFrame.overlay)
        let p = (x: Int(OverlaySelfTest.edgeX(cutout).rounded(.up)) + 4, y: OverlaySelfTest.point(in: cutout, fx: 0.5, fy: 0.5).y)
        let on = r.render(haloFrame, overlay: Compositor.OverlayInput(mask: r.mask))
        let amber = SelfTest.pixel(on, p.x, p.y)
        XCTAssertTrue(SelfTest.matches(amber, OverlayLayout.haloColor, tolerance: 40), "amber ring just outside the person: \(describe(on, p))")
        XCTAssertGreaterThan(Int(amber.r), Int(amber.b) + 100, "amber-ish")
        let off = r.render(OverlaySelfTest.frame(progress: 1), overlay: Compositor.OverlayInput(mask: r.mask))
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(off, p.x, p.y), Tokens.surfaceCream), "no halo when disabled: \(describe(off, p))")
        // Far from the edge the halo changes nothing.
        let far = OverlaySelfTest.point(in: cutout, fx: 0.95, fy: 0.5)
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(on, far.x, far.y), Tokens.surfaceCream), "outside the ring: \(describe(on, far))")
    }

    func testHalfOpacityMixesPresenterAndBackground() throws {
        let r = try rig()
        let frame = OverlaySelfTest.frame(progress: 1, config: OverlayLayout.Config(opacity: 0.5))
        let cutout = try XCTUnwrap(frame.overlay)
        XCTAssertEqual(cutout.opacity, 0.5, accuracy: 1e-9)
        let target = r.render(frame, overlay: Compositor.OverlayInput(mask: r.mask))
        let left = OverlaySelfTest.point(in: cutout, fx: 0.25, fy: 0.5)
        let source = SelfTest.pixel(r.presenter, OverlaySelfTest.sourcePoint(cutout, x: left.x, y: left.y).x, OverlaySelfTest.sourcePoint(cutout, x: left.x, y: left.y).y)
        let cream = Tokens.surfaceCream
        let got = SelfTest.pixel(target, left.x, left.y)
        func mixed(_ a: UInt8, _ b: Double) -> Int { return Int((Double(a) + b * 255) / 2 + 0.5) }
        XCTAssertLessThanOrEqual(abs(Int(got.r) - mixed(source.r, cream.r)), 4, describe(target, left))
        XCTAssertLessThanOrEqual(abs(Int(got.g) - mixed(source.g, cream.g)), 4, describe(target, left))
        XCTAssertLessThanOrEqual(abs(Int(got.b) - mixed(source.b, cream.b)), 4, describe(target, left))
    }

    func testOverlayFrameGeometryHasNoPresenterQuadAndNoDivider() {
        let frame = OverlaySelfTest.frame(progress: 0.5)
        XCTAssertNil(frame.presenter)
        XCTAssertEqual(frame.dividerAlpha, 0)
        XCTAssertNotNil(frame.overlay)
        XCTAssertNil(StudioLayout.passthrough().overlay, "passthrough never carries a cutout")
        XCTAssertNil(StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .portrait, canvasAspect: 0.75).overlay)
        XCTAssertEqual(MemoryLayout<Compositor.OverlayUniforms>.stride, 32, "matches OverlayUniforms in OverlayShaders.metal")
    }
}
