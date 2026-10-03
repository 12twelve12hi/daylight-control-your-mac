import Foundation

/// Auto-engage state machine (SPEC section 5). Skeleton: the public surface is final, the transitions land in M2.
/// Today it only tracks the pin flag and active contacts, and reports PASSTHROUGH.
public struct EngageGovernor {
    public let config: GovernorConfig
    private var output: GovernorOutput
    private var spring: CriticalSpring
    private var contacts: Set<UUID> = []
    public private(set) var generation: UInt64 = 0

    public init(config: GovernorConfig = GovernorConfig(), now: Double) {
        self.config = config
        self.output = GovernorOutput()
        self.spring = CriticalSpring(k: config.springK, m: 1, position: 0)
    }

    public var snapshot: GovernorOutput {
        var s = output
        s.effects = []
        return s
    }

    public var needsTicks: Bool { return output.state != .passthrough || output.hold != .auto }

    public func nextDeadline(now: Double) -> Double? { return nil }

    public mutating func handle(_ event: GovernorEvent, now: Double) -> GovernorOutput {
        generation += 1
        var effects: [GovernorEffect] = []
        switch event {
        case let .contact(strokeID, pointer, phase, pressure, _):
            if pointer == .stylus && phase == .contact && pressure > 0 { contacts.insert(strokeID) }
        case let .lift(strokeID), let .cancel(strokeID):
            contacts.remove(strokeID)
        case let .clientGone(strokeIDs):
            contacts.subtract(strokeIDs)
        case .allClientsGone:
            contacts.removeAll()
        case let .pin(value):
            let pinned = value < 0 ? !output.pinned : (value > 0)
            if pinned != output.pinned {
                output.pinned = pinned
                effects.append(.pinChanged(pinned))
            }
        case let .hold(mode):
            if mode != output.hold {
                output.hold = mode
                effects.append(.holdChanged(mode))
            }
        case let .layoutHotkey(style):
            output.layout = style
        default:
            break
        }
        output.activeContacts = contacts.count
        output.effects = effects
        return output
    }

    public mutating func tick(now: Double) -> GovernorOutput {
        output.progress = spring.evaluate(at: now)
        output.effects = []
        return output
    }
}
