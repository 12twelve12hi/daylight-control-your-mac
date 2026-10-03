import Foundation

public struct RateLimiter {
    public var minInterval: Double
    private var last: Double?

    public init(minInterval: Double) {
        self.minInterval = minInterval
    }

    public mutating func allow(now: Double) -> Bool {
        if let last = last, now - last < minInterval { return false }
        last = now
        return true
    }
}
