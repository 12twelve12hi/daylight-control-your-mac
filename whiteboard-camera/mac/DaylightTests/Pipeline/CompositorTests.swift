import DaylightKit
import Metal
import XCTest
@testable import Daylight

/// SPEC B1 and B3 render probes. Skipped (with the reason in the log) when the runner has no Metal device.
final class CompositorTests: XCTestCase {
    private func makeDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("MTLCreateSystemDefaultDevice() is nil on this machine; compositing is first tested on the owner's Mac")
        }
        return device
    }

    func testStudioSplitAtHalfProgressProbesCreamPaperDividerAndPresenter() throws {
        let device = try makeDevice()
        let compositor = try Compositor(device: device)
        let surfaces = try CanvasSurfaces(device: device)
        let pool = try OutputPool()
        let presenter = SelfTest.gradientBuffer(width: 1920, height: 1080)!
        // One stroke so the canvas quad has ink to show.
        var store = StrokeStore()
        let id = UUID()
        _ = store.start(StrokeStart(id: id, tool: .pen, colorARGB: 0xFF11_1111, baseWidth: 40, pointer: .stylus, phase: .contact, pressure: 1))
        let op = store.append(id: id, points: [SolStream.Point(x: 100, y: 800, pressure: 1, deltaMs: 0), SolStream.Point(x: 1100, y: 800, pressure: 1, deltaMs: 5)], now: 1)!
        InkRasterizer(surfaces: surfaces).apply(op, store: store)
        let target = pool.acquire()!
        defer { pool.release(target) }
        let frame = StudioLayout.frame(progress: 0.5, layout: .studioSplit, orientation: .portrait, canvasAspect: 0.75, breath: 0)
        let gpu = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: frame), into: target)
        print("compositor: studio split s=0.5 gpu \(gpu * 1000) ms")
        // d = 640: panel offset -640, canvas x in [-405, 405): paper at x=200; cream in [405, 640); presenter from 640.
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 200, 100), Tokens.paperBg), SelfTest.describe(SelfTest.pixel(target, 200, 100)))
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 520, 540), Tokens.surfaceCream), SelfTest.describe(SelfTest.pixel(target, 520, 540)))
        // The ink stroke at canvas y=800 (of 1600) maps to output y=540; canvas x=600 maps to -405 + 600 * 0.675 = 0.
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 200, 540), Tokens.inkBlack, tolerance: 40), "ink under the slot: " + SelfTest.describe(SelfTest.pixel(target, 200, 540)))
        XCTAssertTrue(SelfTest.close(SelfTest.pixel(target, 1000, 540), SelfTest.pixel(presenter, 680, 540)), "presenter crop is 1:1, no scaling")
        let divider = SelfTest.pixel(target, 639, 540)
        XCTAssertLessThan(Int(divider.r), 160, "divider at half alpha darkens the presenter: " + SelfTest.describe(divider))
    }

    /// Review 4 CI-1 (the crash frame of mac-26 run 37189486118): a frame in flight released its CVMetalTextures on
    /// Metal's completion queue after its Compositor, and the CVMetalTextureCache with it, was gone, and CoreVideo wrote
    /// into the freed cache (EXC_BAD_ACCESS in CVMetalTextureCache::bufferBackingNotInUse). Every frame here outlives
    /// its Compositor; each completion must run and the process must survive the textures' release.
    func testFramesInFlightOutliveTheirCompositor() throws {
        let device = try makeDevice()
        let surfaces = try CanvasSurfaces(device: device)
        let presenter = SelfTest.gradientBuffer(width: 1920, height: 1080)!
        let frame = StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .portrait, canvasAspect: 0.75, breath: 0)
        let done = DispatchGroup()
        for _ in 0..<40 {
            let pool = try OutputPool()
            let target = try XCTUnwrap(pool.acquire())
            var compositor: Compositor? = try Compositor(device: device)
            done.enter()
            compositor?.render(Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: frame), into: target) { _ in
                pool.release(target)
                done.leave()
            }
            compositor = nil
        }
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success, "every frame in flight completes after its Compositor is gone")
    }

    func testProgressZeroEqualsThePresenterInput() throws {
        let device = try makeDevice()
        let compositor = try Compositor(device: device)
        let surfaces = try CanvasSurfaces(device: device)
        let pool = try OutputPool()
        let presenter = SelfTest.gradientBuffer(width: 1920, height: 1080)!
        let target = pool.acquire()!
        defer { pool.release(target) }
        let frame = StudioLayout.frame(progress: 0, layout: .studioSplit, orientation: .portrait, canvasAspect: 0.75, breath: 0)
        _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: frame), into: target)
        for (x, y) in [(0, 0), (100, 100), (960, 540), (1800, 1000), (1919, 1079)] {
            XCTAssertTrue(SelfTest.close(SelfTest.pixel(target, x, y), SelfTest.pixel(presenter, x, y), tolerance: 1), "(\(x), \(y)) \(SelfTest.describe(SelfTest.pixel(target, x, y))) vs \(SelfTest.describe(SelfTest.pixel(presenter, x, y)))")
        }
    }

    func testStudioSplitAtFullProgress() throws {
        let device = try makeDevice()
        let compositor = try Compositor(device: device)
        let surfaces = try CanvasSurfaces(device: device)
        let pool = try OutputPool()
        let presenter = SelfTest.gradientBuffer(width: 1920, height: 1080)!
        let target = pool.acquire()!
        defer { pool.release(target) }
        let frame = StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .portrait, canvasAspect: 0.75, breath: 0)
        _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: frame), into: target)
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 100, 540), Tokens.surfaceCream))
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 1100, 540), Tokens.surfaceCream))
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 640, 540), Tokens.paperBg))
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 1279, 540), Tokens.inkBlack))
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 1280, 540), Tokens.inkBlack))
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 235, 540), Tokens.borderSubtle, tolerance: 60), "border line at 235: " + SelfTest.describe(SelfTest.pixel(target, 235, 540)))
        XCTAssertTrue(SelfTest.close(SelfTest.pixel(target, 1600, 540), SelfTest.pixel(presenter, 960, 540)))
        XCTAssertTrue(SelfTest.close(SelfTest.pixel(target, 1281, 300), SelfTest.pixel(presenter, 641, 300)))
    }

    func testLandscapeMirrorFrameAndWhiteboardOnly() throws {
        let device = try makeDevice()
        let compositor = try Compositor(device: device)
        let pool = try OutputPool()
        let presenter = SelfTest.gradientBuffer(width: 1920, height: 1080)!
        let mirror = FakeMirrorSource(width: 1600, height: 1200)
        let target = pool.acquire()!
        defer { pool.release(target) }
        let latest = mirror.latest()!
        let frame = StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: latest.orientation, canvasAspect: latest.aspect, breath: 0)
        XCTAssertEqual(frame.divider?.x, 1439, "landscape divider (SPEC 6.4)")
        _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .mirror(latest.buffer, uv: latest.uv), frame: frame), into: target)
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 1439, 540), Tokens.inkBlack))
        XCTAssertTrue(SelfTest.close(SelfTest.pixel(target, 1600, 540), SelfTest.pixel(presenter, 880, 540)), "landscape presenter source x in [720, 1200)")
        let picture = SelfTest.pixel(target, 720, 540)
        XCTAssertFalse(SelfTest.matches(picture, Tokens.surfaceCream), "the mirror picture is drawn in the slot")
        let whiteboard = StudioLayout.frame(progress: 1, layout: .whiteboardOnly, orientation: .portrait, canvasAspect: 0.75, breath: 0)
        _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .none, frame: whiteboard), into: target)
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 300, 540), Tokens.surfaceCream))
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 960, 540), Tokens.paperBg))
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 1600, 540), Tokens.surfaceCream))
    }

    func testAmberBreathTintsTheDivider() throws {
        let device = try makeDevice()
        let compositor = try Compositor(device: device)
        let pool = try OutputPool()
        let presenter = SelfTest.gradientBuffer(width: 1920, height: 1080)!
        let target = pool.acquire()!
        defer { pool.release(target) }
        let frame = StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .portrait, canvasAspect: 0.75, breath: 1)
        _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .none, frame: frame), into: target)
        XCTAssertTrue(SelfTest.matches(SelfTest.pixel(target, 1279, 540), Tokens.amber), SelfTest.describe(SelfTest.pixel(target, 1279, 540)))
    }

    func testQuadVerticesAndScissorMath() {
        let verts = Compositor.quadVertices(dest: PixelRect(x: 0, y: 0, w: 1920, h: 1080), uv: .full)
        XCTAssertEqual(verts.count, 24)
        XCTAssertEqual(verts[0], -1)
        XCTAssertEqual(verts[1], 1)
        XCTAssertEqual(verts[23], 1)
        let scissor = Compositor.scissor(PixelRect(x: -10, y: 0, w: 650, h: 1080), width: 1920, height: 1080)!
        XCTAssertEqual(scissor.x, 0)
        XCTAssertEqual(scissor.width, 640)
        XCTAssertNil(Compositor.scissor(PixelRect(x: 0, y: 0, w: 0, h: 1080), width: 1920, height: 1080))
        XCTAssertEqual(Compositor.fourcc(kCVPixelFormatType_32BGRA), "BGRA")
    }

    /// Camera line weight (D14) through the real compositor: a 1 px tablet stroke reaches the 1080p output at least
    /// 2.5 px wide (bilinear minification of the 0.675 canvas scale costs at most a tenth of a pixel), so a call app's
    /// 720p downscale still gets 1.7 px; a 6 px stroke keeps its own width (6 x 0.675 = 4.05 output px).
    func testCameraLineWeightReachesTheOutput() throws {
        let device = try makeDevice()
        let compositor = try Compositor(device: device)
        let surfaces = try CanvasSurfaces(device: device)
        let pool = try OutputPool()
        let presenter = SelfTest.gradientBuffer(width: 1920, height: 1080)!
        var store = StrokeStore()
        let rasterizer = InkRasterizer(surfaces: surfaces)
        for (base, y) in [(Float(1), 400.5), (Float(6), 1200.5)] {
            let id = UUID()
            _ = store.start(StrokeStart(id: id, tool: .pen, colorARGB: 0xFF11_1111, baseWidth: base, pointer: .stylus, phase: .contact, pressure: 0.5))
            rasterizer.apply(store.append(id: id, points: [SolStream.Point(x: 100, y: y, pressure: 0.5, deltaMs: 0), SolStream.Point(x: 1100, y: y, pressure: 0.5, deltaMs: 5)], now: 1)!, store: store)
        }
        let target = pool.acquire()!
        defer { pool.release(target) }
        let frame = StudioLayout.frame(progress: 1, layout: .whiteboardOnly, orientation: .portrait, canvasAspect: 0.75, breath: 0)
        _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: frame), into: target)
        // The page fills the output height: canvas y maps to y * 1080 / 1600; canvas x = 600 is the output's centre.
        func outputCoverage(centreRow: Int) -> Double {
            let paper = Tokens.paperBg.r * 255, ink = Tokens.inkBlack.r * 255
            return ((centreRow - 15)...(centreRow + 15)).reduce(0.0) { sum, y in
                sum + max(0, (paper - Double(SelfTest.pixel(target, 960, y).r)) / (paper - ink))
            }
        }
        let thin = outputCoverage(centreRow: 270)
        let wide = outputCoverage(centreRow: 810)
        print("hosted-test: camera line weight: 1 px stroke covers \(thin) output px at 1080p (\(thin * 720 / 1080) at 720p); 6 px stroke \(wide)")
        XCTAssertGreaterThanOrEqual(thin, 2.5 - 0.1, "2.5 output px at 1080p")
        XCTAssertGreaterThanOrEqual(thin * 720 / 1080, 2.5 * 720 / 1080 - 0.07, "1.7 output px at 720p")
        XCTAssertEqual(wide, 6 * 1080 / 1600, accuracy: 0.15, "a 6 px stroke is unchanged")
    }
}

