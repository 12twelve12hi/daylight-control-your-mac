import Foundation

/// Point-to-segment distance and the eraser hit test (PROTOCOL 6.8: distance <= radius + width / 2).
public enum Geometry {
    /// Squared distance from `point` to the closed segment `a`-`b`.
    public static func distanceSquared(point: (Double, Double), segment a: (Double, Double), b: (Double, Double)) -> Double {
        let dx = b.0 - a.0
        let dy = b.1 - a.1
        let lengthSquared = dx * dx + dy * dy
        var t = 0.0
        if lengthSquared > 0 {
            t = ((point.0 - a.0) * dx + (point.1 - a.1) * dy) / lengthSquared
            t = min(max(t, 0), 1)
        }
        let px = a.0 + t * dx - point.0
        let py = a.1 + t * dy - point.1
        return px * px + py * py
    }

    /// Squared distance between two segments (zero when they cross).
    public static func segmentDistanceSquared(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double), _ d: (Double, Double)) -> Double {
        if segmentsIntersect(a, b, c, d) { return 0 }
        return min(
            min(distanceSquared(point: a, segment: c, b: d), distanceSquared(point: b, segment: c, b: d)),
            min(distanceSquared(point: c, segment: a, b: b), distanceSquared(point: d, segment: a, b: b)))
    }

    static func segmentsIntersect(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double), _ d: (Double, Double)) -> Bool {
        func cross(_ o: (Double, Double), _ p: (Double, Double), _ q: (Double, Double)) -> Double {
            return (p.0 - o.0) * (q.1 - o.1) - (p.1 - o.1) * (q.0 - o.0)
        }
        let d1 = cross(c, d, a)
        let d2 = cross(c, d, b)
        let d3 = cross(a, b, c)
        let d4 = cross(a, b, d)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return true }
        return false
    }

    /// True when the eraser segment `a`-`b` with `radius` touches the stroke: some stroke segment (or its single point)
    /// lies within `radius + width / 2` of the eraser segment, width taken at the nearer stroke point.
    public static func strokeHit(_ s: Stroke, segment a: (Double, Double), b: (Double, Double), radius: Double) -> Bool {
        let pts = s.points
        if pts.isEmpty { return false }
        if pts.count == 1 {
            let p = (pts[0].x, pts[0].y)
            let reach = radius + s.width(at: 0) / 2
            return distanceSquared(point: p, segment: a, b: b) <= reach * reach
        }
        for i in 1..<pts.count {
            let p0 = (pts[i - 1].x, pts[i - 1].y)
            let p1 = (pts[i].x, pts[i].y)
            let reach = radius + max(s.width(at: i - 1), s.width(at: i)) / 2
            if segmentDistanceSquared(p0, p1, a, b) <= reach * reach { return true }
        }
        return false
    }
}
