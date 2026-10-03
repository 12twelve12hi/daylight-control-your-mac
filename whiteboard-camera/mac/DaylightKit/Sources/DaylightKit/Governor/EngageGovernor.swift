import Foundation

/// The engage and return state machine (SPEC section 5): a pure value with injected monotonic time, driven by the
/// pipeline under one lock. `handle` and `tick` return the output snapshot plus the effects the pipeline consumes.
/// The governor owns no timers: the pipeline calls `tick(now:)` at 30 Hz while `needsTicks` is true.
///
/// Dirtiness is tracked heuristically here (ink since the last save, ink since the last clear) so that `savePage` and
/// `clearCanvas` are emitted only when they can matter; the saver re-checks `StrokeStore.isDirty` before writing.
public struct EngageGovernor {
    public let config: GovernorConfig
    public private(set) var state: GovernorState = .passthrough
    public private(set) var generation: UInt64 = 0

    private var spring: CriticalSpring
    private var pinned = false
    private var hold: HoldMode = .auto
    private var preferredLayout: LayoutStyle
    private var activeContacts: Set<UUID> = []
    private var lastActivity: Double
    private var engageStart: Double
    /// The current engage was caused by a stroke (an ink row), not by a pin, a hold, a hotkey or the menu: only such
    /// an engage may snap back on a cancel (SPEC 5.4).
    private var strokeCausedEngage = false
    private var preWarningFired = false
    private var preWarningStart: Double = 0
    private var lastNow: Double
    /// Ink since the last save (the page may need saving).
    private var inkDirty = false
    /// Ink since the last clear (the canvas may need clearing).
    private var hasInk = false
    /// Mirror mode: one sentinel id while BTN_TOUCH is down.
    private let penSentinel = UUID()

    public init(config: GovernorConfig = GovernorConfig(), now: Double) {
        self.config = config
        preferredLayout = config.preferredLayout
        spring = CriticalSpring(k: config.springK, m: 1, position: 0)
        spring.snap(to: 0, at: now)
        lastActivity = now
        engageStart = now
        lastNow = now
    }

    // MARK: Public surface

    public var snapshot: GovernorOutput { return output(now: lastNow, effects: []) }

    /// The pipeline ticks while a slide runs or a hold mode is active.
    public var needsTicks: Bool { return state != .passthrough || hold != .auto }

    public var pinnedState: Bool { return pinned }
    public var holdState: HoldMode { return hold }
    public var layout: LayoutStyle { return preferredLayout }
    public var activeContactCount: Int { return activeContacts.count }

    /// The next instant something can happen without input (for the optional `deadlineIdle` flag, SPEC D34):
    /// `now` while a slide or the pre-warning animates, the pre-warning or return instant while LIVE and idle, nil otherwise.
    public func nextDeadline(now: Double) -> Double? {
        switch state {
        case .passthrough:
            return nil
        case .engaging, .returning:
            return now
        case .live:
            if preWarningFired { return now }
            guard isIdle else { return nil }
            let returnAt = lastActivity + config.idleTimeout
            let warnAt = lastActivity + config.idleTimeout - config.preWarningLead
            if config.preWarningLead > 0 && warnAt > now { return warnAt }
            return returnAt
        }
    }

    public mutating func tick(now: Double) -> GovernorOutput {
        lastNow = max(now, lastNow)
        var effects: [GovernorEffect] = []
        spring.evaluate(at: now)
        switch state {
        case .passthrough:
            break
        case .engaging:
            if spring.isSettled {
                spring.snap(to: 1, at: now)
                transition(to: .live, effects: &effects)
            }
        case .live:
            if isIdle {
                let idle = now - lastActivity
                if idle >= config.idleTimeout {
                    startReturn(now: now, effects: &effects)
                } else if config.preWarningLead > 0 && idle >= config.idleTimeout - config.preWarningLead && !preWarningFired {
                    preWarningFired = true
                    preWarningStart = now
                    effects.append(.preWarningStarted)
                }
            }
        case .returning:
            if spring.isSettled {
                spring.snap(to: 0, at: now)
                activeContacts.removeAll()
                if pinned {
                    pinned = false
                    effects.append(.pinChanged(false))
                }
                cancelPreWarning(&effects)
                if inkDirty {
                    inkDirty = false
                    effects.append(.savePage(reason: .returned))
                }
                transition(to: .passthrough, effects: &effects)
            }
        }
        return output(now: now, effects: effects)
    }

    public mutating func handle(_ event: GovernorEvent, now: Double) -> GovernorOutput {
        lastNow = max(now, lastNow)
        var effects: [GovernorEffect] = []
        spring.evaluate(at: now)

        // Rows that read "any state": contacts are dropped, nothing transitions. When the drop removes the last contact
        // of an ENGAGING or LIVE board the idle timer restarts from now (as lift and cancel do), so a contact that was
        // open for longer than idleTimeout cannot return the board on the next tick with no pre-warning.
        switch event {
        case .sourceChanged, .allClientsGone:
            let had = !activeContacts.isEmpty
            activeContacts.removeAll()
            noteContactsDropped(hadContacts: had, now: now)
            return output(now: now, effects: effects)
        case let .clientGone(ids):
            let had = !activeContacts.isEmpty
            activeContacts.subtract(ids)
            noteContactsDropped(hadContacts: had, now: now)
            return output(now: now, effects: effects)
        default:
            break
        }

        switch state {
        case .passthrough: handlePassthrough(event, now: now, effects: &effects)
        case .engaging: handleEngaging(event, now: now, effects: &effects)
        case .live: handleLive(event, now: now, effects: &effects)
        case .returning: handleReturning(event, now: now, effects: &effects)
        }
        return output(now: now, effects: effects)
    }

    // MARK: Guards

    /// STYLUS of SPEC 5.2: stylus, contact, pressure above zero, and not the eraser unless `engageOnEraser`.
    private func isEngagingStylus(pointer: SolStream.PointerType, phase: SolStream.Phase, pressure: Float, tool: SolStream.Tool) -> Bool {
        return isStylusContact(pointer: pointer, phase: phase, pressure: pressure) && (tool != .eraser || config.engageOnEraser)
    }

    /// A stylus contact with pressure of any tool (tracked as an active contact; the eraser counts as activity, D36).
    private func isStylusContact(pointer: SolStream.PointerType, phase: SolStream.Phase, pressure: Float) -> Bool {
        return pointer == .stylus && phase == .contact && pressure > 0
    }

    private var isIdle: Bool { return hold == .auto && !pinned && activeContacts.isEmpty }

    private var autoEngageArmed: Bool { return config.autoEngage && hold != .camera }

    // MARK: Per-state handlers

    private mutating func handlePassthrough(_ event: GovernorEvent, now: Double, effects: inout [GovernorEffect]) {
        switch event {
        case let .contact(id, pointer, phase, pressure, tool):
            guard isStylusContact(pointer: pointer, phase: phase, pressure: pressure) else { return }   // dropped
            activeContacts.insert(id)
            markInk()
            if tool == .eraser && !config.engageOnEraser { return }
            if autoEngageArmed { engage(now: now, byStroke: true, effects: &effects) }
        case let .penContact(down):
            if down {
                activeContacts.insert(penSentinel)
                markInk()
                if autoEngageArmed { engage(now: now, byStroke: true, effects: &effects) }
            } else {
                activeContacts.remove(penSentinel)
            }
        case let .eraserContact(down):
            if down && config.engageOnEraser {
                markInk()
                if autoEngageArmed { engage(now: now, byStroke: true, effects: &effects) }
            }
        case let .pin(value):
            if value == 0 { return }
            setPinned(true, effects: &effects)
            engage(now: now, byStroke: false, effects: &effects)
        case .engage:
            if hold != .camera { engage(now: now, byStroke: false, effects: &effects) }
        case let .layoutHotkey(style):
            if hold != .camera {
                preferredLayout = style
                engage(now: now, byStroke: false, effects: &effects)
            }
        case let .hold(mode):
            setHold(mode, effects: &effects)
            if let forced = mode.forcedLayout {
                preferredLayout = forced
                engage(now: now, byStroke: false, effects: &effects)
            }
        case .clear:
            clearPage(&effects)
        case let .motion(id):
            if activeContacts.contains(id) { markInk() }
        case let .lift(id), let .cancel(id):
            activeContacts.remove(id)
        case .activity:
            markInk()
        case .returnNow, .sourceChanged, .clientGone, .allClientsGone:
            break
        }
    }

    private mutating func handleEngaging(_ event: GovernorEvent, now: Double, effects: inout [GovernorEffect]) {
        switch event {
        case let .cancel(id):
            let others = activeContacts.subtracting([id])
            // Snap back only when the stroke itself caused the engage: a pin, a forced hold, a hotkey or the menu
            // asked for the board regardless of the stroke, and PASSTHROUGH must never carry `pinned` or a forced hold.
            if now - engageStart < config.snapBackWindow && spring.position < config.snapBackMaxProgress && others.isEmpty
                && !pinned && hold == .auto && strokeCausedEngage {
                activeContacts.remove(id)
                spring.snap(to: 0, at: now)
                transition(to: .passthrough, effects: &effects)   // snap-back, no save
            } else {
                activeContacts.remove(id)
                lastActivity = now
            }
        case let .contact(id, pointer, phase, pressure, _):
            guard isStylusContact(pointer: pointer, phase: phase, pressure: pressure) else { return }
            activeContacts.insert(id)
            markInk()
            lastActivity = now
        case let .motion(id):
            if activeContacts.contains(id) { markInk() }
            lastActivity = now
        case .activity:
            markInk()
            lastActivity = now
        case let .penContact(down):
            if down {
                activeContacts.insert(penSentinel)
                markInk()
            } else {
                activeContacts.remove(penSentinel)
            }
            lastActivity = now
        case let .eraserContact(down):
            if down { lastActivity = now }
        case let .lift(id):
            activeContacts.remove(id)
            lastActivity = now
        case let .pin(value):
            applyPin(value, effects: &effects)
        case .clear:
            clearPage(&effects)
            if !pinned { startReturn(now: now, effects: &effects) }
        case .returnNow:
            setPinned(false, effects: &effects)
            startReturn(now: now, effects: &effects)
        case let .layoutHotkey(style):
            if style == preferredLayout {
                setPinned(false, effects: &effects)
                startReturn(now: now, effects: &effects)
            } else {
                preferredLayout = style
            }
        case let .hold(mode):
            switch mode {
            case .camera:
                setPinned(false, effects: &effects)
                setHold(.camera, effects: &effects)
                startReturn(now: now, effects: &effects)
            case .auto:
                setHold(.auto, effects: &effects)
                lastActivity = now
            case .split, .whiteboard:
                setHold(mode, effects: &effects)
                if let forced = mode.forcedLayout { preferredLayout = forced }
            }
        case .engage:
            lastActivity = now
        case .sourceChanged, .clientGone, .allClientsGone:
            break
        }
    }

    private mutating func handleLive(_ event: GovernorEvent, now: Double, effects: inout [GovernorEffect]) {
        switch event {
        case let .contact(id, pointer, phase, pressure, _):
            guard isStylusContact(pointer: pointer, phase: phase, pressure: pressure) else { return }
            activeContacts.insert(id)
            markInk()
            touch(now: now, effects: &effects)
        case let .motion(id):
            if activeContacts.contains(id) { markInk() }
            touch(now: now, effects: &effects)
        case .activity:
            markInk()
            touch(now: now, effects: &effects)
        case let .penContact(down):
            if down {
                activeContacts.insert(penSentinel)
                markInk()
                touch(now: now, effects: &effects)
            } else {
                activeContacts.remove(penSentinel)
                lastActivity = now
            }
        case let .eraserContact(down):
            if down { touch(now: now, effects: &effects) }
        case let .lift(id), let .cancel(id):
            activeContacts.remove(id)
            lastActivity = now
        case let .pin(value):
            let was = pinned
            applyPin(value, effects: &effects)
            if was && !pinned { lastActivity = now }
            cancelPreWarning(&effects)
        case .clear:
            clearPage(&effects)
            if !pinned {
                startReturn(now: now, effects: &effects)
            } else {
                lastActivity = now
            }
        case .returnNow:
            setPinned(false, effects: &effects)
            startReturn(now: now, effects: &effects)
        case .engage:
            touch(now: now, effects: &effects)
        case let .layoutHotkey(style):
            if style == preferredLayout {
                setPinned(false, effects: &effects)
                startReturn(now: now, effects: &effects)
            } else {
                preferredLayout = style
            }
        case let .hold(mode):
            switch mode {
            case .camera:
                setPinned(false, effects: &effects)
                setHold(.camera, effects: &effects)
                startReturn(now: now, effects: &effects)
            case .auto:
                setHold(.auto, effects: &effects)
                touch(now: now, effects: &effects)
            case .split, .whiteboard:
                setHold(mode, effects: &effects)
                if let forced = mode.forcedLayout { preferredLayout = forced }
                cancelPreWarning(&effects)
            }
        case .sourceChanged, .clientGone, .allClientsGone:
            break
        }
    }

    /// Ink rows re-engage ("ink wins") only while auto-engage is armed: with `hold == .camera` or `autoEngage == false`
    /// the return runs to completion and the ink is only recorded, as from PASSTHROUGH. Pin, engage, the layout hotkey
    /// and hold(split or whiteboard) are explicit requests and re-engage regardless (D38).
    private mutating func handleReturning(_ event: GovernorEvent, now: Double, effects: inout [GovernorEffect]) {
        switch event {
        case let .contact(id, pointer, phase, pressure, _):
            guard isStylusContact(pointer: pointer, phase: phase, pressure: pressure) else { return }
            activeContacts.insert(id)
            markInk()
            if autoEngageArmed { reengage(now: now, byStroke: true, effects: &effects) }
        case let .motion(id):
            if activeContacts.contains(id) {
                markInk()
                if autoEngageArmed { reengage(now: now, byStroke: true, effects: &effects) }
            }
        case let .penContact(down):
            if down {
                activeContacts.insert(penSentinel)
                markInk()
                if autoEngageArmed { reengage(now: now, byStroke: true, effects: &effects) }
            } else {
                activeContacts.remove(penSentinel)
            }
        case let .eraserContact(down):
            if down && autoEngageArmed { reengage(now: now, byStroke: true, effects: &effects) }   // D36: eraser contact cancels a return
        case let .pin(value):
            if value == 1 || (value < 0 && !pinned) {
                setPinned(true, effects: &effects)
                reengage(now: now, byStroke: false, effects: &effects)
            } else {
                setPinned(false, effects: &effects)
            }
        case .engage:
            reengage(now: now, byStroke: false, effects: &effects)
        case let .layoutHotkey(style):
            preferredLayout = style
            reengage(now: now, byStroke: false, effects: &effects)
        case let .hold(mode):
            switch mode {
            case .split, .whiteboard:
                setHold(mode, effects: &effects)
                if let forced = mode.forcedLayout { preferredLayout = forced }
                reengage(now: now, byStroke: false, effects: &effects)
            case .camera:
                setHold(.camera, effects: &effects)
            case .auto:
                setHold(.auto, effects: &effects)
            }
        case .clear:
            clearPage(&effects)
        case let .lift(id), let .cancel(id):
            activeContacts.remove(id)
        case .activity:
            markInk()
            lastActivity = now
        case .returnNow, .sourceChanged, .clientGone, .allClientsGone:
            break
        }
    }

    // MARK: Transitions

    private mutating func transition(to next: GovernorState, effects: inout [GovernorEffect]) {
        let from = state
        state = next
        generation &+= 1
        effects.append(.stateChanged(from: from, to: next))
    }

    /// PASSTHROUGH -> ENGAGING (the first row of SPEC 5.2). `byStroke` is true only for the ink rows. Only an explicit
    /// request (a pin) reaches here under hold camera; it brings the board up, so it releases the hold to auto.
    private mutating func engage(now: Double, byStroke: Bool, effects: inout [GovernorEffect]) {
        guard state == .passthrough else { return }
        if hold == .camera { setHold(.auto, effects: &effects) }
        strokeCausedEngage = byStroke
        spring.retarget(1, at: now)
        engageStart = now
        lastActivity = now
        transition(to: .engaging, effects: &effects)
    }

    /// ENGAGING or LIVE -> RETURNING.
    private mutating func startReturn(now: Double, effects: inout [GovernorEffect]) {
        guard state == .engaging || state == .live else { return }
        spring.retarget(0, at: now)
        cancelPreWarning(&effects)
        transition(to: .returning, effects: &effects)
    }

    /// RETURNING -> ENGAGING from the current position and velocity (no discontinuity). Only an explicit request (pin,
    /// engage, layout hotkey) reaches here under hold camera; it brings the board up, so it releases the hold to auto.
    private mutating func reengage(now: Double, byStroke: Bool, effects: inout [GovernorEffect]) {
        guard state == .returning else { return }
        if hold == .camera { setHold(.auto, effects: &effects) }
        strokeCausedEngage = byStroke
        spring.retarget(1, at: now)
        engageStart = now
        lastActivity = now
        transition(to: .engaging, effects: &effects)
    }

    /// After an any-state contact drop: a board that just lost its last contact gets a fresh idle period. A drop that
    /// removes nothing (the set was already empty) leaves the timer alone.
    private mutating func noteContactsDropped(hadContacts: Bool, now: Double) {
        if hadContacts && activeContacts.isEmpty && (state == .engaging || state == .live) {
            lastActivity = max(lastActivity, now)
        }
    }

    private mutating func touch(now: Double, effects: inout [GovernorEffect]) {
        lastActivity = now
        cancelPreWarning(&effects)
    }

    private mutating func cancelPreWarning(_ effects: inout [GovernorEffect]) {
        if preWarningFired {
            preWarningFired = false
            effects.append(.preWarningCancelled)
        }
    }

    private mutating func applyPin(_ value: Int8, effects: inout [GovernorEffect]) {
        let next = value < 0 ? !pinned : (value > 0)
        setPinned(next, effects: &effects)
    }

    private mutating func setPinned(_ value: Bool, effects: inout [GovernorEffect]) {
        if pinned != value {
            pinned = value
            effects.append(.pinChanged(value))
        }
    }

    private mutating func setHold(_ mode: HoldMode, effects: inout [GovernorEffect]) {
        if hold != mode {
            hold = mode
            effects.append(.holdChanged(mode))
        }
    }

    private mutating func markInk() {
        inkDirty = true
        hasInk = true
    }

    /// Clear (SPEC section 7): save when dirty, clear when the page has ink; no transition here.
    private mutating func clearPage(_ effects: inout [GovernorEffect]) {
        if inkDirty {
            inkDirty = false
            effects.append(.savePage(reason: .cleared))
        }
        if hasInk {
            hasInk = false
            effects.append(.clearCanvas)
        }
    }

    // MARK: Output

    private func output(now: Double, effects: [GovernorEffect]) -> GovernorOutput {
        let msToReturn: UInt32
        switch state {
        case .live:
            if isIdle {
                let remaining = max(0, config.idleTimeout - (now - lastActivity))
                msToReturn = UInt32(min(remaining * 1000, Double(StateReport.noReturnScheduled - 1)).rounded())
            } else {
                msToReturn = StateReport.noReturnScheduled
            }
        case .returning:
            msToReturn = 0
        case .passthrough, .engaging:
            msToReturn = StateReport.noReturnScheduled
        }
        let breath = preWarningFired ? GovernorOutput.breathWeight(secondsSincePreWarning: now - preWarningStart) : 0
        return GovernorOutput(
            state: state,
            progress: spring.position,
            pinned: pinned,
            hold: hold,
            layout: preferredLayout,
            preWarning: preWarningFired,
            breath: breath,
            msToReturn: msToReturn,
            activeContacts: activeContacts.count,
            effects: effects)
    }
}
