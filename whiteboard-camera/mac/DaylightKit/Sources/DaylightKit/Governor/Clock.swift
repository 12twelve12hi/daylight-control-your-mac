import Foundation

/// Seconds on a monotonic clock. The governor itself takes `now` as a parameter; this protocol is for callers.
public protocol Clock {
    func now() -> Double
}

/// Monotonic seconds since boot (`ProcessInfo.systemUptime`, Foundation on both platforms). Never wall-clock:
/// the idle timer must not jump when the Mac's clock is adjusted. B feeds `CACurrentMediaTime()` directly on
/// the render path and uses this only off it.
public struct SystemClock: Clock {
    public init() {}
    public func now() -> Double { return ProcessInfo.processInfo.systemUptime }
}

/// Deterministic clock for tests.
public final class ManualClock: Clock {
    private var time: Double
    public init(start: Double = 0) { time = start }
    public func now() -> Double { return time }
    public func advance(_ dt: Double) { time += dt }
    public func set(_ t: Double) { time = t }
}
