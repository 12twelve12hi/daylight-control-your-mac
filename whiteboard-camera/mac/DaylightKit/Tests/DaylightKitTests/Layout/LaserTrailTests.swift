import XCTest
import DaylightKit

/// Laser pointer (LOOSE_ENDS F3): samples fade linearly over their decay (0.5 s by default), shrink to half their
/// radius, are capped and validated, and map through the canvas quad like the ink does.
final class LaserTrailTests: XCTestCase {
    func testDotFadesOverItsDecayAndIsForgotten() {
        var trail = LaserTrail()
        trail.add(x: 600, y: 800, intensity: 1, decay: 0.5, now: 10)
        var dots = trail.dots(at: 10)
        XCTAssertEqual(dots, [LaserTrail.Dot(x: 600, y: 800, radius: LaserTrail.radius, alpha: 1)])
        dots = trail.dots(at: 10.25)
        XCTAssertEqual(dots.first?.alpha ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(dots.first?.radius ?? 0, LaserTrail.radius * 0.75, accuracy: 1e-9)
        XCTAssertTrue(trail.dots(at: 10.5).isEmpty, "gone after the decay")
        XCTAssertTrue(trail.isEmpty, "and forgotten")
    }

    func testIntensityScalesAndDefaultsApply() {
        var trail = LaserTrail()
        trail.add(x: 10, y: 10, intensity: 0.5, decay: 0, now: 0)
        XCTAssertEqual(trail.samples.first?.decay, LaserTrail.defaultDecay, "decay 0 means the 0.5 s default")
        XCTAssertEqual(trail.dots(at: 0).first?.alpha ?? 0, 0.5, accuracy: 1e-9)
        trail.add(x: 10, y: 10, intensity: 4, decay: 100, now: 0)
        XCTAssertEqual(trail.samples.last?.intensity, 1)
        XCTAssertEqual(trail.samples.last?.decay, LaserTrail.maxDecay)
        trail.add(x: 10, y: 10, intensity: .nan, decay: .infinity, now: 0)
        XCTAssertEqual(trail.samples.last?.decay, LaserTrail.defaultDecay)
        let count = trail.samples.count
        trail.add(x: 10, y: 10, intensity: 0, decay: 0.5, now: 0)
        trail.add(x: -1, y: 10, intensity: 1, decay: 0.5, now: 0)
        trail.add(x: 10, y: 1601, intensity: 1, decay: 0.5, now: 0)
        trail.add(x: .nan, y: 10, intensity: 1, decay: 0.5, now: 0)
        XCTAssertEqual(trail.samples.count, count, "zero intensity, off-canvas and non-finite samples are dropped")
    }

    func testTrailKeepsTheNewestSamples() {
        var trail = LaserTrail()
        for i in 0..<(LaserTrail.capacity + 10) { trail.add(x: Double(i), y: 1, intensity: 1, decay: 0.5, now: Double(i) * 0.001) }
        XCTAssertEqual(trail.samples.count, LaserTrail.capacity)
        XCTAssertEqual(trail.samples.last?.x, Double(LaserTrail.capacity + 9))
        let dots = trail.dots(at: 0.06)
        XCTAssertGreaterThan(dots.last!.alpha, dots.first!.alpha, "older samples are fainter: a trail")
    }

    func testPlaceMapsThroughTheCanvasQuad() {
        let dot = LaserTrail.Dot(x: 600, y: 800, radius: 10, alpha: 1)
        // Whiteboard Only at rest: the page at x 555, 810 x 1080.
        let full = QuadSpec(dest: PixelRect(x: 555, y: 0, w: 810, h: 1080), uv: .full)
        let r = LaserTrail.place(dot, through: full)!
        XCTAssertEqual(r.x + r.w / 2, 960, accuracy: 1e-9)
        XCTAssertEqual(r.y + r.h / 2, 540, accuracy: 1e-9)
        XCTAssertEqual(r.w, 2 * 10 * 0.675, accuracy: 1e-9)
        // A followed quad showing the top-left quarter of the page magnified.
        let zoomed = QuadSpec(dest: PixelRect(x: 0, y: 0, w: 1200, h: 1600), uv: UVRect(u0: 0, v0: 0, u1: 0.5, v1: 0.5))
        let z = LaserTrail.place(LaserTrail.Dot(x: 300, y: 400, radius: 10, alpha: 1), through: zoomed)!
        XCTAssertEqual(z.x + z.w / 2, 600, accuracy: 1e-9)
        XCTAssertEqual(z.w, 40, accuracy: 1e-9)
        XCTAssertNil(LaserTrail.place(dot, through: zoomed), "outside the visible part")
    }
}
