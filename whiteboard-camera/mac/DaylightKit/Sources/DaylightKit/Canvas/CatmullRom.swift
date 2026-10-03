import Foundation

/// Uniform Catmull-Rom (tension 0.5) through p1..p2 as a cubic Bezier (research-mac-pipeline section 7, approach B).
/// Approach A (straight segments with round caps) ships first; this is the tested helper for the smoother variant.
public enum CatmullRom {
    /// `c1 = p1 + (p2 - p0) / 6`, `c2 = p2 - (p3 - p1) / 6`.
    public static func bezierControls(p0: (Double, Double), p1: (Double, Double), p2: (Double, Double), p3: (Double, Double)) -> (c1: (Double, Double), c2: (Double, Double)) {
        let c1 = (p1.0 + (p2.0 - p0.0) / 6, p1.1 + (p2.1 - p0.1) / 6)
        let c2 = (p2.0 - (p3.0 - p1.0) / 6, p2.1 - (p3.1 - p1.1) / 6)
        return (c1, c2)
    }

    /// The Catmull-Rom segment p1..p2 evaluated at `t` in 0...1 (basis-matrix form), for tests and for callers that
    /// flatten instead of stroking Beziers.
    public static func point(p0: (Double, Double), p1: (Double, Double), p2: (Double, Double), p3: (Double, Double), t: Double) -> (Double, Double) {
        func axis(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
            let t2 = t * t
            let t3 = t2 * t
            return 0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return (axis(p0.0, p1.0, p2.0, p3.0), axis(p0.1, p1.1, p2.1, p3.1))
    }

    /// The cubic Bezier p1, c1, c2, p2 at `t`.
    public static func bezierPoint(p1: (Double, Double), c1: (Double, Double), c2: (Double, Double), p2: (Double, Double), t: Double) -> (Double, Double) {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return (a * p1.0 + b * c1.0 + c * c2.0 + d * p2.0, a * p1.1 + b * c1.1 + c * c2.1 + d * p2.1)
    }
}
