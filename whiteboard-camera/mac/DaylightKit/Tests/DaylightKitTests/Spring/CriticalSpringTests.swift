import XCTest
import DaylightKit

/// SPEC 5.3 and acceptance A4: closed-form values, settle time, retarget continuity, Euler divergence at 1/30 s.
final class CriticalSpringTests: XCTestCase {
    func testOmegaAndSettlesWithinBudgetWithoutOvershoot() {
        var spring = CriticalSpring(k: 1200, m: 1, position: 0)
        XCTAssertEqual(spring.omega, 1200.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(spring.omega, 34.641, accuracy: 1e-3)
        spring.retarget(1, at: 0)
        var previous = 0.0
        var t = 0.0
        while t <= 0.5 {
            let x = spring.evaluate(at: t)
            XCTAssertGreaterThanOrEqual(x + 1e-12, previous, "critically damped springs never reverse")
            XCTAssertLessThanOrEqual(x, 1.0 + 1e-9, "no overshoot")
            previous = x
            t += 1.0 / 30.0
        }
        spring.evaluate(at: 0.1)
        XCTAssertFalse(spring.isSettled, "still moving at 100 ms")
        spring.evaluate(at: 0.333)
        XCTAssertTrue(spring.isSettled, "settled within the 333 ms budget")
        XCTAssertEqual(spring.position, 1, accuracy: 0.01)
    }

    /// From rest, 0 to 1: x(0.100) = 0.8603, x(0.150) = 0.9657, x(0.200) = 0.9922, x(0.250) = 0.9983, x(0.333) = 0.99988.
    func testClosedFormValuesWithin1e4() {
        var spring = CriticalSpring(k: 1200, m: 1, position: 0)
        spring.retarget(1, at: 0)
        let expected: [(Double, Double)] = [(0.100, 0.8603), (0.150, 0.9657), (0.200, 0.9922), (0.250, 0.9983), (0.333, 0.99988)]
        for (t, x) in expected {
            XCTAssertEqual(spring.evaluate(at: t), x, accuracy: 1e-4, "x(\(t))")
        }
    }

    /// Frame values at 30 fps: 0.321, 0.671, 0.860, 0.945, 0.979, 0.992, 0.997, then settled (8 distinct frames).
    func testFrameValuesAt30fps() {
        var spring = CriticalSpring(k: 1200, m: 1, position: 0)
        spring.retarget(1, at: 0)
        let frames = [0.321, 0.671, 0.860, 0.945, 0.979, 0.992, 0.997]
        for (i, x) in frames.enumerated() {
            XCTAssertEqual(spring.evaluate(at: Double(i + 1) / 30), x, accuracy: 1e-3, "frame \(i + 1)")
            XCTAssertFalse(spring.isSettled, "frame \(i + 1) is still a distinct frame")
        }
        spring.evaluate(at: 8.0 / 30)
        XCTAssertTrue(spring.isSettled, "the eighth frame is settled")
    }

    /// The oracle rule (|x - T| < 0.01 and |v| < 0.05) settles at 0.251 s; a 30 Hz tick sees it within one tick.
    func testSettlesAt251msWithinOneTick() {
        var spring = CriticalSpring(k: 1200, m: 1, position: 0)
        spring.retarget(1, at: 0)
        spring.evaluate(at: 0.250)
        XCTAssertFalse(spring.isSettled)
        spring.evaluate(at: 0.252)
        XCTAssertTrue(spring.isSettled)
        var settledTick: Int?
        for i in 1...30 {
            spring.evaluate(at: Double(i) / 30)
            if spring.isSettled {
                settledTick = i
                break
            }
        }
        XCTAssertEqual(settledTick, 8)
        XCTAssertLessThan(Double(settledTick ?? 0) / 30 - 0.251, 1.0 / 30)
    }

    func testRetargetKeepsPositionAndVelocity() {
        var spring = CriticalSpring(k: 1200, m: 1, position: 0)
        spring.retarget(1, at: 0)
        spring.evaluate(at: 0.05)
        let x = spring.position
        let v = spring.velocity
        spring.retarget(0, at: 0.05)
        XCTAssertEqual(spring.position, x, accuracy: 1e-12)
        XCTAssertEqual(spring.velocity, v, accuracy: 1e-12)
        XCTAssertEqual(spring.target, 0)
        // Continuity: the position an instant later is within velocity * dt of the position before.
        let after = spring.evaluate(at: 0.05 + 1e-6)
        XCTAssertEqual(after, x + v * 1e-6, accuracy: 1e-9)
    }

    func testMatchesEulerReferenceWithSmallSteps() {
        var spring = CriticalSpring(k: 1200, m: 1, position: 0)
        spring.retarget(1, at: 0)
        var x = 0.0
        var v = 0.0
        let dt = 0.0001
        var t = 0.0
        while t < 0.2 {
            eulerReferenceStep(x: &x, v: &v, target: 1, dt: dt, k: 1200, m: 1)
            t += dt
        }
        spring.evaluate(at: t)
        XCTAssertEqual(spring.position, x, accuracy: 1e-3)
    }

    /// Semi-implicit Euler at 1/30 s is unstable (c dt = 2.31): the position magnitude exceeds 2 within 10 steps.
    func testEulerAt30HzDiverges() {
        var x = 0.0
        var v = 0.0
        var diverged = false
        for _ in 0..<10 {
            eulerReferenceStep(x: &x, v: &v, target: 1, dt: 1.0 / 30, k: 1200, m: 1)
            if abs(x) > 2 {
                diverged = true
                break
            }
        }
        XCTAssertTrue(diverged, "Euler at 1/30 s must blow up; it is never used for rendering")
    }

    /// With 14.4 ms substeps Euler stays bounded and converges to the same rest value as the closed form.
    func testEulerWithSubstepsStaysBounded() {
        var x = 0.0
        var v = 0.0
        var t = 0.0
        var spring = CriticalSpring(k: 1200, m: 1, position: 0)
        spring.retarget(1, at: 0)
        while t < 0.5 {
            eulerReferenceStep(x: &x, v: &v, target: 1, dt: 0.0144, k: 1200, m: 1)
            t += 0.0144
            XCTAssertLessThan(abs(x), 1.5)
        }
        XCTAssertEqual(x, spring.evaluate(at: t), accuracy: 1e-3)
    }

    func testSnap() {
        var spring = CriticalSpring()
        spring.snap(to: 1, at: 3)
        XCTAssertEqual(spring.evaluate(at: 10), 1)
        XCTAssertTrue(spring.isSettled)
        XCTAssertEqual(spring.velocity, 0)
    }

    func testSlowerSpringTakesTheFullBudget() {
        var spring = CriticalSpring(k: 600, m: 1, position: 0)
        spring.retarget(1, at: 0)
        spring.evaluate(at: 0.251)
        XCTAssertFalse(spring.isSettled, "k = 600 is not settled at 251 ms")
        spring.evaluate(at: 0.36)
        XCTAssertTrue(spring.isSettled, "k = 600 settles around the 333 ms budget")
    }
}
