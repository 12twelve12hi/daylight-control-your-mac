import XCTest
import DaylightKit

final class GeometryTests: XCTestCase {
    func testPointToSegmentDistance() {
        XCTAssertEqual(Geometry.distanceSquared(point: (0, 5), segment: (0, 0), b: (10, 0)), 25)
        XCTAssertEqual(Geometry.distanceSquared(point: (5, 5), segment: (0, 0), b: (10, 0)), 25, "interior projection")
        XCTAssertEqual(Geometry.distanceSquared(point: (-3, 4), segment: (0, 0), b: (10, 0)), 25, "clamped to the start")
        XCTAssertEqual(Geometry.distanceSquared(point: (13, 4), segment: (0, 0), b: (10, 0)), 25, "clamped to the end")
        XCTAssertEqual(Geometry.distanceSquared(point: (3, 4), segment: (0, 0), b: (0, 0)), 25, "degenerate segment")
        XCTAssertEqual(Geometry.distanceSquared(point: (5, 0), segment: (0, 0), b: (10, 0)), 0)
    }

    func testSegmentDistance() {
        XCTAssertEqual(Geometry.segmentDistanceSquared((0, 0), (10, 0), (5, -5), (5, 5)), 0, "crossing")
        XCTAssertEqual(Geometry.segmentDistanceSquared((0, 0), (10, 0), (0, 3), (10, 3)), 9, "parallel")
        XCTAssertEqual(Geometry.segmentDistanceSquared((0, 0), (10, 0), (12, 0), (20, 0)), 4, "collinear gap")
        XCTAssertEqual(Geometry.segmentDistanceSquared((0, 0), (0, 0), (3, 4), (3, 4)), 25, "two points")
    }

    func testStrokeHitAtTheRadiusEdge() {
        var s = Stroke(id: UUID(), style: .pen)
        s.append([SolStream.Point(x: 100, y: 100, pressure: 1, deltaMs: 0), SolStream.Point(x: 200, y: 100, pressure: 1, deltaMs: 10)])
        // width 4.64 at pressure 1 -> reach = radius + 2.32; the eraser runs 30 px below the stroke.
        XCTAssertFalse(Geometry.strokeHit(s, segment: (100, 130), b: (200, 130), radius: 27.67))
        XCTAssertTrue(Geometry.strokeHit(s, segment: (100, 130), b: (200, 130), radius: 27.69))
        XCTAssertTrue(Geometry.strokeHit(s, segment: (150, 50), b: (150, 150), radius: 0), "crossing needs no radius")
        var dot = Stroke(id: UUID(), style: .pen)
        dot.append([SolStream.Point(x: 0, y: 0, pressure: 0, deltaMs: 0)])
        // width 1.76 at pressure 0 -> reach = radius + 0.88
        XCTAssertTrue(Geometry.strokeHit(dot, segment: (0, 10), b: (10, 10), radius: 9.13))
        XCTAssertFalse(Geometry.strokeHit(dot, segment: (0, 10), b: (10, 10), radius: 9.11))
        XCTAssertFalse(Geometry.strokeHit(Stroke(id: UUID(), style: .pen), segment: (0, 0), b: (1, 1), radius: 100), "no points")
    }

    func testCatmullRomBezierControls() {
        let p0 = (0.0, 0.0), p1 = (10.0, 0.0), p2 = (20.0, 10.0), p3 = (30.0, 30.0)
        let c = CatmullRom.bezierControls(p0: p0, p1: p1, p2: p2, p3: p3)
        XCTAssertEqual(c.c1.0, 10 + 20.0 / 6, accuracy: 1e-12)
        XCTAssertEqual(c.c1.1, 10.0 / 6, accuracy: 1e-12)
        XCTAssertEqual(c.c2.0, 20 - 20.0 / 6, accuracy: 1e-12)
        XCTAssertEqual(c.c2.1, 10 - 30.0 / 6, accuracy: 1e-12)
        // The Bezier equals the Catmull-Rom basis form at every t (the research note's numeric check).
        var t = 0.0
        while t <= 1.0 {
            let cr = CatmullRom.point(p0: p0, p1: p1, p2: p2, p3: p3, t: t)
            let bz = CatmullRom.bezierPoint(p1: p1, c1: c.c1, c2: c.c2, p2: p2, t: t)
            XCTAssertEqual(cr.0, bz.0, accuracy: 1e-9, "x at t = \(t)")
            XCTAssertEqual(cr.1, bz.1, accuracy: 1e-9, "y at t = \(t)")
            t += 0.125
        }
        XCTAssertEqual(CatmullRom.point(p0: p0, p1: p1, p2: p2, p3: p3, t: 0.5).0, 15, accuracy: 1e-12)
        XCTAssertEqual(CatmullRom.point(p0: p0, p1: p1, p2: p2, p3: p3, t: 0.5).1, 3.75, accuracy: 1e-12)
        // Random quads.
        var seed: UInt64 = 42
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53) * 1600
        }
        for _ in 0..<200 {
            let q0 = (next(), next()), q1 = (next(), next()), q2 = (next(), next()), q3 = (next(), next())
            let k = CatmullRom.bezierControls(p0: q0, p1: q1, p2: q2, p3: q3)
            for u in [0.0, 0.3, 0.5, 0.77, 1.0] {
                let cr = CatmullRom.point(p0: q0, p1: q1, p2: q2, p3: q3, t: u)
                let bz = CatmullRom.bezierPoint(p1: q1, c1: k.c1, c2: k.c2, p2: q2, t: u)
                XCTAssertEqual(cr.0, bz.0, accuracy: 1e-8)
                XCTAssertEqual(cr.1, bz.1, accuracy: 1e-8)
            }
        }
    }
}
