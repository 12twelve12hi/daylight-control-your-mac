import Foundation
import XCTest
import DaylightKit

/// Drives an `EngageGovernor` with a manual clock stepping 1/30 s. `now` is always `tickIndex / 30` (exact division,
/// never a running sum) so instants like 85.0 s land exactly.
struct GovernorHarness {
    var governor: EngageGovernor
    private(set) var tickIndex: Int = 0
    /// Every effect emitted so far, in order, with the time it was emitted.
    private(set) var effects: [(t: Double, effect: GovernorEffect)] = []
    private(set) var last: GovernorOutput

    static let dt: Double = 1.0 / 30.0

    init(config: GovernorConfig = GovernorConfig()) {
        governor = EngageGovernor(config: config, now: 0)
        last = governor.snapshot
    }

    var now: Double { return Double(tickIndex) / 30.0 }
    var state: GovernorState { return last.state }

    @discardableResult
    mutating func send(_ event: GovernorEvent) -> GovernorOutput {
        let out = governor.handle(event, now: now)
        record(out)
        return out
    }

    /// Advances one frame and ticks.
    @discardableResult
    mutating func tick() -> GovernorOutput {
        tickIndex += 1
        let out = governor.tick(now: now)
        record(out)
        return out
    }

    /// Ticks until `now >= t` (inclusive of the tick at or just past `t`).
    mutating func tickUntil(_ t: Double) {
        while now < t - 1e-9 {
            tick()
        }
    }

    /// Ticks until the state equals `target` or `maxSeconds` elapse; returns the time of arrival or nil.
    mutating func tickUntil(state target: GovernorState, maxSeconds: Double) -> Double? {
        let deadline = now + maxSeconds
        while now < deadline {
            tick()
            if last.state == target { return now }
        }
        return nil
    }

    private mutating func record(_ out: GovernorOutput) {
        last = out
        for e in out.effects {
            effects.append((now, e))
        }
    }

    func count(_ predicate: (GovernorEffect) -> Bool) -> Int {
        return effects.filter { predicate($0.effect) }.count
    }

    var saveCount: Int {
        return count { if case .savePage = $0 { return true } else { return false } }
    }

    var stateChanges: [GovernorEffect] {
        return effects.map { $0.effect }.filter { if case .stateChanged = $0 { return true } else { return false } }
    }

    // MARK: Event builders

    static func stylus(_ id: UUID = UUID(), pressure: Float = 0.5, tool: SolStream.Tool = .pen) -> GovernorEvent {
        return .contact(strokeID: id, pointer: .stylus, phase: .contact, pressure: pressure, tool: tool)
    }

    /// Engages from PASSTHROUGH with one stylus contact and lifts it on the same tick.
    mutating func engageAndLift() -> UUID {
        let id = UUID()
        send(GovernorHarness.stylus(id))
        send(.lift(strokeID: id))
        return id
    }

    /// Engages, lifts, and ticks until LIVE.
    mutating func goLive() {
        _ = engageAndLift()
        XCTAssertEqual(state, .engaging)
        XCTAssertNotNil(tickUntil(state: .live, maxSeconds: 1))
    }
}
