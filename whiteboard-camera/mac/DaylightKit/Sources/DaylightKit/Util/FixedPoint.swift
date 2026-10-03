import Foundation

/// Canvas units <-> the x32 fixed-point wire format; pressure quantisation. Rounding is half away from zero.
public enum FixedPoint {
    public static func toX32(_ v: Double) -> Int32 {
        let scaled = (v * 32).rounded()
        if scaled >= Double(Int32.max) { return Int32.max }
        if scaled <= Double(Int32.min) { return Int32.min }
        return Int32(scaled)
    }

    public static func fromX32(_ v: Int32) -> Double {
        return Double(v) / 32.0
    }

    public static func quantizePressure(_ p: Double) -> UInt8 {
        let clamped = min(max(p, 0), 1)
        return UInt8((clamped * 255).rounded())
    }
}
