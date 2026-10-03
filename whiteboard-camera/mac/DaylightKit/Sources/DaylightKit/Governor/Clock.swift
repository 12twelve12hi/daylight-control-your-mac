import Foundation

public protocol Clock {
    func now() -> Double
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Double { return Date().timeIntervalSince1970 }
}

/// Deterministic clock for tests.
public final class ManualClock: Clock {
    private var time: Double
    public init(start: Double = 0) { time = start }
    public func now() -> Double { return time }
    public func advance(_ dt: Double) { time += dt }
}
