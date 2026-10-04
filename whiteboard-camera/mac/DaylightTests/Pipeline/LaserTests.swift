import CoreGraphics
import DaylightKit
import IOSurface
import Metal
import XCTest
@testable import Daylight

/// Laser pointer on the camera board (LOOSE_ENDS F3): a LASER_POINT leaves no stroke in the store, nothing on the
/// canvas surfaces and nothing in the saved PNG; it is drawn over the canvas quad as a fading dot and is gone after
/// its decay.
final class LaserTests: XCTestCase {
    private func pngBytes(_ store: StrokeStore) throws -> Data {
        let image = try XCTUnwrap(PNGExporter.render(store))
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        return data
    }

    private func layerIsEmpty(_ surface: IOSurfaceRef, width: Int, height: Int) -> Bool {
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) where CanvasSurfaces.pixel(surface, x: x, y: y).a != 0 { return false }
        }
        return true
    }

    func testLaserLeavesNoStrokeNoPixelsAndNothingInTheSavedPNG() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let rasterizer = InkRasterizer(surfaces: surfaces)
        let store = StrokeStore()
        let blank = try pngBytes(store)
        for i in 0..<20 {
            rasterizer.laser(x: 400 + Double(i) * 10, y: 600, intensity: 1, decay: 0.5, now: Double(i) * 0.016)
        }
        XCTAssertEqual(surfaces.laser.withLock { $0.samples.count }, 20, "the trail has the samples")
        XCTAssertEqual(store.committedCount, 0, "no stroke in the store")
        XCTAssertEqual(store.undoDepth, 0, "nothing to undo")
        XCTAssertTrue(layerIsEmpty(surfaces.ink, width: surfaces.width, height: surfaces.height), "nothing on the ink layer")
        XCTAssertTrue(layerIsEmpty(surfaces.highlight, width: surfaces.width, height: surfaces.height), "nothing on the highlight layer")
        XCTAssertEqual(rasterizer.stats.locks, 0, "the canvas surfaces were never locked")
        XCTAssertEqual(try pngBytes(store), blank, "the saved PNG is the blank page")
        XCTAssertTrue(surfaces.activity.drain().boxes.isEmpty, "the laser is not ink for follow the pen")
    }

    func testDotsArePlacedThroughTheFrameAndFade() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let rasterizer = InkRasterizer(surfaces: surfaces)
        rasterizer.laser(x: 600, y: 800, intensity: 1, decay: 0.5, now: 100)
        let frame = StudioLayout.frame(progress: 1, layout: .whiteboardOnly, orientation: .portrait, canvasAspect: 0.75)
        let dots = FramePipeline.laserDots(surfaces: surfaces, frame: frame, layers: true, now: 100)
        XCTAssertEqual(dots.count, 1)
        XCTAssertEqual(dots[0].rect.x + dots[0].rect.w / 2, 960, accuracy: 1e-6, "page centre is the output centre")
        XCTAssertEqual(dots[0].rect.y + dots[0].rect.h / 2, 540, accuracy: 1e-6)
        XCTAssertEqual(dots[0].alpha, 1, accuracy: 1e-9)
        XCTAssertTrue(FramePipeline.laserDots(surfaces: surfaces, frame: frame, layers: false, now: 100).isEmpty, "never over a mirror picture")
        XCTAssertTrue(FramePipeline.laserDots(surfaces: surfaces, frame: StudioLayout.passthrough(), layers: true, now: 100).isEmpty, "never in passthrough")
        XCTAssertEqual(FramePipeline.laserDots(surfaces: surfaces, frame: frame, layers: true, now: 100.25).first?.alpha ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertTrue(FramePipeline.laserDots(surfaces: surfaces, frame: frame, layers: true, now: 100.5).isEmpty, "gone after 0.5 s")
    }

    func testCompositorDrawsTheDotOverThePageAndNothingAfterTheDecay() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("MTLCreateSystemDefaultDevice() is nil on this machine")
        }
        let compositor = try Compositor(device: device)
        let surfaces = try CanvasSurfaces(device: device)
        let pool = try OutputPool()
        let presenter = SelfTest.gradientBuffer(width: 1920, height: 1080)!
        let rasterizer = InkRasterizer(surfaces: surfaces)
        rasterizer.laser(x: 600, y: 800, intensity: 1, decay: 0.5, now: 0)
        let frame = StudioLayout.frame(progress: 1, layout: .whiteboardOnly, orientation: .portrait, canvasAspect: 0.75)
        let target = pool.acquire()!
        defer { pool.release(target) }
        let live = FramePipeline.laserDots(surfaces: surfaces, frame: frame, layers: true, now: 0)
        _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: frame, laser: live), into: target)
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 960, 540), LaserTrail.color, tolerance: 8), "the dot: " + SelfTest.describe(SelfTest.pixel(target, 960, 540)))
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 960, 560), Tokens.paperBg), "paper beyond the dot")
        // Review F3: the output stays opaque. The dot quad spans 960 +- 6.075 px: (965, 540) is on the soft edge and
        // (954, 534) is a corner of the quad outside the disc, where the fragment's alpha is 0.
        XCTAssertEqual(SelfTest.pixel(target, 960, 540).a, 255, "opaque at the dot centre")
        XCTAssertEqual(SelfTest.pixel(target, 965, 540).a, 255, "opaque on the dot edge: " + SelfTest.describe(SelfTest.pixel(target, 965, 540)))
        XCTAssertEqual(SelfTest.pixel(target, 954, 534).a, 255, "opaque in the corner of the dot quad")
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 954, 534), Tokens.paperBg, tolerance: 8), "the corner shows the paper: " + SelfTest.describe(SelfTest.pixel(target, 954, 534)))
        // Half faded (alpha 0.5 at 0.25 s): the colour is between dot and paper, the alpha is still 255.
        let fading = FramePipeline.laserDots(surfaces: surfaces, frame: frame, layers: true, now: 0.25)
        XCTAssertEqual(fading.first?.alpha ?? 0, 0.5, accuracy: 1e-9)
        _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: frame, laser: fading), into: target)
        let half = SelfTest.pixel(target, 960, 540)
        XCTAssertEqual(half.a, 255, "opaque while the dot fades: " + SelfTest.describe(half))
        XCTAssertFalse(SelfTest.matches(half, LaserTrail.color, tolerance: 8), "a fading dot is lighter than the full one")
        XCTAssertFalse(SelfTest.matches(half, Tokens.paperBg, tolerance: 8), "but still visible")
        XCTAssertEqual(SelfTest.pixel(target, 963, 540).a, 255, "opaque on the fading dot's edge")
        let later = FramePipeline.laserDots(surfaces: surfaces, frame: frame, layers: true, now: 0.6)
        XCTAssertTrue(later.isEmpty)
        _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: frame, laser: later), into: target)
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 960, 540), Tokens.paperBg), "faded: only paper")
        XCTAssertEqual(SelfTest.pixel(target, 960, 540).a, 255, "opaque after the fade")
    }

    /// Review F5: dots are clipped to the canvas quad, not the panel. A dot on the page's left edge (Whiteboard Only:
    /// the page spans x 555 to 1365, the left border line is the column x 555) shows only on the page: the cream margin
    /// and the border line keep their colours.
    func testCompositorClipsTheDotToThePage() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("MTLCreateSystemDefaultDevice() is nil on this machine")
        }
        let compositor = try Compositor(device: device)
        let surfaces = try CanvasSurfaces(device: device)
        let pool = try OutputPool()
        let presenter = SelfTest.gradientBuffer(width: 1920, height: 1080)!
        let rasterizer = InkRasterizer(surfaces: surfaces)
        rasterizer.laser(x: 0, y: 800, intensity: 1, decay: 0.5, now: 0)
        let frame = StudioLayout.frame(progress: 1, layout: .whiteboardOnly, orientation: .portrait, canvasAspect: 0.75)
        XCTAssertEqual(frame.canvas?.dest.x ?? 0, 555, accuracy: 1e-9)
        let dots = FramePipeline.laserDots(surfaces: surfaces, frame: frame, layers: true, now: 0)
        XCTAssertEqual(dots.count, 1)
        XCTAssertLessThan(dots[0].rect.x, 550, "the dot quad reaches into the margin")
        let target = pool.acquire()!
        defer { pool.release(target) }
        _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: frame, laser: dots), into: target)
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 558, 540), LaserTrail.color, tolerance: 8), "the dot on the page: " + SelfTest.describe(SelfTest.pixel(target, 558, 540)))
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 551, 540), Tokens.surfaceCream), "the margin stays cream: " + SelfTest.describe(SelfTest.pixel(target, 551, 540)))
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 555, 540), Tokens.borderSubtle), "the border line stays on top: " + SelfTest.describe(SelfTest.pixel(target, 555, 540)))
        for x in [551, 555, 558] { XCTAssertEqual(SelfTest.pixel(target, x, 540).a, 255, "opaque at x \(x)") }
    }
}
