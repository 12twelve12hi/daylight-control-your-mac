import Foundation

/// Critically damped spring (m = 1, k = 1200 -> omega about 34.6, visually settled in about 250 ms).
/// Closed form from the last retarget: x(t) = T + (A + B t) e^(-omega t), with A = x0 - T and B = v0 + omega A.
public struct CriticalSpring: Equatable {
    public let omega: Double
    public private(set) var position: Double
    public private(set) var velocity: Double
    public private(set) var target: Double
    private var startPosition: Double
    private var startVelocity: Double
    private var startTime: Double

    public init(k: Double = 1200, m: Double = 1, position: Double = 0) {
        omega = (k / m).squareRoot()
        self.position = position
        velocity = 0
        target = position
        startPosition = position
        startVelocity = 0
        startTime = 0
    }

    /// Changes the target keeping the current position and velocity as the new initial conditions.
    public mutating func retarget(_ newTarget: Double, at now: Double) {
        evaluate(at: now)
        target = newTarget
        startPosition = position
        startVelocity = velocity
        startTime = now
    }

    public mutating func snap(to value: Double, at now: Double) {
        position = value
        velocity = 0
        target = value
        startPosition = value
        startVelocity = 0
        startTime = now
    }

    @discardableResult
    public mutating func evaluate(at now: Double) -> Double {
        let t = max(0, now - startTime)
        let a = startPosition - target
        let b = startVelocity + omega * a
        let decay = exp(-omega * t)
        position = target + (a + b * t) * decay
        velocity = (b - omega * (a + b * t)) * decay
        return position
    }

    public var isSettled: Bool {
        return abs(position - target) < 0.01 && abs(velocity) < 0.05
    }
}

/// Explicit Euler step of the same spring, for tests that compare against the closed form.
public func eulerReferenceStep(x: inout Double, v: inout Double, target: Double, dt: Double, k: Double, m: Double) {
    let omega = (k / m).squareRoot()
    let c = 2 * omega * m
    let acceleration = (-k * (x - target) - c * v) / m
    v += acceleration * dt
    x += v * dt
}
