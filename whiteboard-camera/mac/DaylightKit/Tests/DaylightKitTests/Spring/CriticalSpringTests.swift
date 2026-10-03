import XCTest
import DaylightKit

final class CriticalSpringTests: XCTestCase {
    func testSettlesWithinBudgetWithoutOvershoot() {
        var spring = CriticalSpring(k: 1200, m: 1, position: 0)
        XCTAssertEqual(spring.omega, 1200.0.squareRoot(), accuracy: 1e-9)
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

    func testSnap() {
        var spring = CriticalSpring()
        spring.snap(to: 1, at: 3)
        XCTAssertEqual(spring.evaluate(at: 10), 1)
        XCTAssertTrue(spring.isSettled)
    }
}
