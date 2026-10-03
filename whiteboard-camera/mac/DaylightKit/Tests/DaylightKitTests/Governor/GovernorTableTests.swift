import Foundation
import XCTest
import DaylightKit

/// SPEC 5.2: one test per transition-table row that the scenario tests do not already pin.
final class GovernorTableTests: XCTestCase {
    // PASSTHROUGH rows

    func testPassthroughPenContactEngagesWithSentinel() {
        var h = GovernorHarness()
        let out = h.send(.penContact(down: true))
        XCTAssertEqual(out.state, .engaging)
        XCTAssertEqual(out.activeContacts, 1)
        XCTAssertNotNil(h.tickUntil(state: .live, maxSeconds: 1))
        XCTAssertEqual(h.last.msToReturn, StateReport.noReturnScheduled, "pen down freezes the timer")
        XCTAssertEqual(h.send(.penContact(down: false)).activeContacts, 0)
        XCTAssertEqual(h.last.msToReturn, 90_000)
    }

    func testPassthroughEngageAndHotkeyBlockedByHoldCamera() {
        var h = GovernorHarness()
        XCTAssertEqual(h.send(.hold(.camera)).effects, [.holdChanged(.camera)])
        XCTAssertEqual(h.send(.engage).state, .passthrough)
        XCTAssertEqual(h.send(.layoutHotkey(.studioSplit)).state, .passthrough)
        let contact = h.send(GovernorHarness.stylus())
        XCTAssertEqual(contact.state, .passthrough, "auto-engage disarmed")
        XCTAssertEqual(contact.activeContacts, 1, "ink is still recorded")
        XCTAssertTrue(h.governor.needsTicks, "a hold mode keeps the clock running")
        h.send(.hold(.auto))
        XCTAssertEqual(h.send(.engage).state, .engaging)
    }

    func testPassthroughHoldSplitEngagesWithLayout() {
        var h = GovernorHarness()
        let out = h.send(.hold(.split))
        XCTAssertEqual(out.state, .engaging)
        XCTAssertEqual(out.hold, .split)
        XCTAssertEqual(out.layout, .studioSplit)
        XCTAssertEqual(out.effects, [.holdChanged(.split), .stateChanged(from: .passthrough, to: .engaging)])
        var h2 = GovernorHarness()
        XCTAssertEqual(h2.send(.hold(.whiteboard)).layout, .whiteboardOnly)
    }

    func testPassthroughClearSavesOnlyWhenDirty() {
        var h = GovernorHarness()
        XCTAssertTrue(h.send(.clear).effects.isEmpty)
        h.send(.hold(.camera))
        let id = UUID()
        h.send(GovernorHarness.stylus(id))
        h.send(.motion(strokeID: id))
        h.send(.lift(strokeID: id))
        XCTAssertEqual(h.send(.clear).effects, [.savePage(reason: .cleared), .clearCanvas])
        XCTAssertEqual(h.state, .passthrough)
    }

    func testPassthroughBookkeepingEvents() {
        var h = GovernorHarness()
        let id = UUID()
        h.send(GovernorHarness.stylus(id, tool: .eraser))
        for event in [GovernorEvent.motion(strokeID: id), .activity, .returnNow] {
            let out = h.send(event)
            XCTAssertEqual(out.state, .passthrough)
            XCTAssertTrue(out.effects.isEmpty)
        }
        XCTAssertEqual(h.send(.cancel(strokeID: id)).activeContacts, 0)
        XCTAssertEqual(h.tick().state, .passthrough)
        XCTAssertNil(h.governor.nextDeadline(now: h.now))
    }

    func testAutoEngageOffTracksButNeverEngages() {
        var config = GovernorConfig()
        config.autoEngage = false
        var h = GovernorHarness(config: config)
        XCTAssertEqual(h.send(GovernorHarness.stylus()).state, .passthrough)
        XCTAssertEqual(h.send(.penContact(down: true)).state, .passthrough)
        XCTAssertEqual(h.send(.pin(1)).state, .engaging, "manual engage still works")
    }

    // ENGAGING rows

    func testEngagingTracksAndRefreshesActivity() {
        var h = GovernorHarness()
        let id = UUID()
        h.send(GovernorHarness.stylus(id))
        h.tick()
        let b = UUID()
        XCTAssertEqual(h.send(GovernorHarness.stylus(b)).activeContacts, 2)
        XCTAssertTrue(h.send(.motion(strokeID: id)).effects.isEmpty)
        XCTAssertTrue(h.send(.activity).effects.isEmpty)
        XCTAssertEqual(h.send(.lift(strokeID: id)).activeContacts, 1)
        XCTAssertEqual(h.send(.lift(strokeID: b)).activeContacts, 0)
        XCTAssertEqual(h.state, .engaging)
        XCTAssertEqual(h.send(.pin(1)).effects, [.pinChanged(true)])
        XCTAssertEqual(h.state, .engaging)
    }

    func testEngagingClearReturnsUnlessPinned() {
        var h = GovernorHarness()
        _ = h.engageAndLift()
        h.tick()
        let out = h.send(.clear)
        XCTAssertEqual(out.effects, [.savePage(reason: .cleared), .clearCanvas, .stateChanged(from: .engaging, to: .returning)])
        var p = GovernorHarness()
        _ = p.engageAndLift()
        p.send(.pin(1))
        XCTAssertEqual(p.send(.clear).state, .engaging)
    }

    func testEngagingReturnNowAndHoldCamera() {
        var h = GovernorHarness()
        _ = h.engageAndLift()
        h.send(.pin(1))
        let out = h.send(.returnNow)
        XCTAssertEqual(out.state, .returning)
        XCTAssertFalse(out.pinned)
        XCTAssertEqual(out.effects, [.pinChanged(false), .stateChanged(from: .engaging, to: .returning)])
        var c = GovernorHarness()
        _ = c.engageAndLift()
        let held = c.send(.hold(.camera))
        XCTAssertEqual(held.state, .returning)
        XCTAssertEqual(held.hold, .camera)
        XCTAssertTrue(held.effects.contains(.holdChanged(.camera)))
    }

    func testEngagingLayoutHotkeyToggleAndSwitch() {
        var h = GovernorHarness()
        _ = h.engageAndLift()
        XCTAssertEqual(h.send(.layoutHotkey(.whiteboardOnly)).state, .engaging, "a different layout keeps sliding")
        XCTAssertEqual(h.last.layout, .whiteboardOnly)
        XCTAssertEqual(h.send(.layoutHotkey(.whiteboardOnly)).state, .returning, "the same layout toggles off")
    }

    func testEngagingHoldAuto() {
        var h = GovernorHarness()
        h.send(.hold(.split))
        XCTAssertEqual(h.send(.hold(.auto)).effects, [.holdChanged(.auto)])
        XCTAssertEqual(h.state, .engaging)
    }

    // LIVE rows

    func testLiveLiftAndCancelRefreshActivity() {
        var h = GovernorHarness()
        h.goLive()
        let id = UUID()
        h.send(GovernorHarness.stylus(id))
        h.tickUntil(50)
        h.send(.cancel(strokeID: id))
        XCTAssertEqual(h.last.msToReturn, 90_000)
        h.tickUntil(50 + 90)
        XCTAssertEqual(h.state, .returning)
    }

    func testLiveEngageOnlyRefreshesActivity() {
        var h = GovernorHarness()
        h.goLive()
        h.tickUntil(60)
        let out = h.send(.engage)
        XCTAssertEqual(out.state, .live)
        XCTAssertTrue(out.effects.isEmpty)
        XCTAssertEqual(out.msToReturn, 90_000)
    }

    func testLiveEngageOrHoldAutoDuringPreWarningCancelsIt() {
        // Menu "Whiteboard now" with the current layout posts engage; menu "Hold > Auto" while already auto posts
        // hold(auto). Both reset the idle timer, so the pre-warning must go off with it (no 90 s of amber breathing).
        for event in [GovernorEvent.engage, .hold(.auto)] {
            var h = GovernorHarness()
            h.goLive()
            h.tickUntil(86)
            XCTAssertTrue(h.last.preWarning)
            let out = h.send(event)
            XCTAssertEqual(out.state, .live)
            XCTAssertEqual(out.effects, [.preWarningCancelled], "\(event)")
            XCTAssertFalse(out.preWarning)
            XCTAssertEqual(out.breath, 0)
            XCTAssertEqual(out.msToReturn, 90_000)
            h.tickUntil(170.9)
            XCTAssertFalse(h.last.preWarning, "no warning before 85 s of new idle")
            h.tickUntil(171.0)
            let starts = h.effects.filter { $0.effect == .preWarningStarted }
            XCTAssertEqual(starts.count, 2, "a fresh pre-warning 85 s after the reset")
            XCTAssertEqual(starts.last?.t ?? 0, 171.0, accuracy: 1e-9)
            XCTAssertEqual(h.tickUntil(state: .returning, maxSeconds: 6) ?? 0, 176.0, accuracy: 1e-9)
        }
    }

    func testLiveHoldCancelsPreWarning() {
        var h = GovernorHarness()
        h.goLive()
        h.tickUntil(86)
        XCTAssertTrue(h.last.preWarning)
        let out = h.send(.hold(.split))
        XCTAssertFalse(out.preWarning)
        XCTAssertEqual(out.effects.count, 2, "both effects are emitted")
        XCTAssertTrue(out.effects.contains(.preWarningCancelled))
        XCTAssertTrue(out.effects.contains(.holdChanged(.split)))
    }

    func testLivePinCancelsPreWarning() {
        var h = GovernorHarness()
        h.goLive()
        h.tickUntil(86)
        let out = h.send(.pin(1))
        XCTAssertFalse(out.preWarning)
        XCTAssertTrue(out.effects.contains(.preWarningCancelled))
        XCTAssertTrue(out.effects.contains(.pinChanged(true)))
    }

    func testLiveHoldCameraReturns() {
        var h = GovernorHarness()
        h.goLive()
        h.send(.pin(1))
        let out = h.send(.hold(.camera))
        XCTAssertEqual(out.state, .returning)
        XCTAssertFalse(out.pinned)
        XCTAssertEqual(out.hold, .camera)
        XCTAssertNotNil(h.tickUntil(state: .passthrough, maxSeconds: 1))
        XCTAssertTrue(h.governor.needsTicks, "hold camera keeps ticking in passthrough")
    }

    // RETURNING rows

    func testReturningMotionOfActiveIdReengages() {
        var h = GovernorHarness()
        h.goLive()
        let id = UUID()
        h.send(GovernorHarness.stylus(id))
        h.send(.returnNow)   // return with a pen down
        XCTAssertEqual(h.state, .returning)
        XCTAssertEqual(h.send(.motion(strokeID: UUID())).state, .returning, "an unknown id is bookkeeping")
        XCTAssertEqual(h.send(.motion(strokeID: id)).state, .engaging, "ink wins")
    }

    func testReturningInkUnderHoldCameraDoesNotReengage() {
        // Hold: Camera picked while a pen is on the glass: the next chunk of that stroke must not bring the board back.
        var h = GovernorHarness()
        h.goLive()
        let id = UUID()
        h.send(GovernorHarness.stylus(id))
        let held = h.send(.hold(.camera))
        XCTAssertEqual(held.state, .returning)
        XCTAssertEqual(held.hold, .camera)
        XCTAssertEqual(h.send(.motion(strokeID: id)).state, .returning, "ink does not win against hold camera")
        XCTAssertTrue(h.last.effects.isEmpty)
        XCTAssertEqual(h.send(GovernorHarness.stylus()).state, .returning, "a new contact is recorded only")
        XCTAssertEqual(h.last.activeContacts, 2)
        XCTAssertEqual(h.send(.penContact(down: true)).state, .returning)
        XCTAssertEqual(h.send(.eraserContact(down: true)).state, .returning)
        XCTAssertNotNil(h.tickUntil(state: .passthrough, maxSeconds: 1))
        XCTAssertEqual(h.last.hold, .camera)
        XCTAssertEqual(h.last.activeContacts, 0, "completion clears the contacts")
        // Explicit requests still re-engage under hold camera (D38): pin keeps it.
        var p = GovernorHarness()
        p.goLive()
        p.send(.hold(.camera))
        XCTAssertEqual(p.send(.pin(1)).state, .engaging)
        XCTAssertTrue(p.last.pinned)
    }

    func testExplicitEngageUnderHoldCameraReleasesTheHold() {
        // (A) Pin from PASSTHROUGH under hold camera brings the board up and releases the hold, so unpinning gives a
        // fresh 90 s (SPEC 7) instead of a board that never returns.
        var h = GovernorHarness()
        h.send(.hold(.camera))
        let pinned = h.send(.pin(-1))
        XCTAssertEqual(pinned.state, .engaging)
        XCTAssertTrue(pinned.pinned)
        XCTAssertEqual(pinned.hold, .auto)
        XCTAssertTrue(pinned.effects.contains(.holdChanged(.auto)))
        XCTAssertNotNil(h.tickUntil(state: .live, maxSeconds: 1))
        let unpinned = h.send(.pin(-1))
        XCTAssertFalse(unpinned.pinned)
        XCTAssertEqual(unpinned.msToReturn, 90_000)
        let t0 = h.now
        XCTAssertEqual(h.tickUntil(state: .returning, maxSeconds: 91) ?? 0, t0 + 90, accuracy: 1.5 / 30)

        // (B) Hold: Camera from LIVE starts the return; an explicit engage during it re-engages and releases the hold.
        var b = GovernorHarness()
        b.goLive()
        XCTAssertEqual(b.send(.hold(.camera)).state, .returning)
        let engaged = b.send(.engage)
        XCTAssertEqual(engaged.state, .engaging)
        XCTAssertEqual(engaged.hold, .auto)
        XCTAssertTrue(engaged.effects.contains(.holdChanged(.auto)))
        let t1 = b.now
        XCTAssertNotNil(b.tickUntil(state: .live, maxSeconds: 1))
        b.tickUntil(t1 + 84.9)
        XCTAssertFalse(b.last.preWarning)
        b.tickUntil(t1 + 85.1)
        XCTAssertTrue(b.last.preWarning, "the idle timer runs again")

        // (C) The layout hotkey during a Hold: Camera return does the same.
        var c = GovernorHarness()
        c.goLive()
        c.send(.hold(.camera))
        let hotkey = c.send(.layoutHotkey(.whiteboardOnly))
        XCTAssertEqual(hotkey.state, .engaging)
        XCTAssertEqual(hotkey.layout, .whiteboardOnly)
        XCTAssertEqual(hotkey.hold, .auto)
        XCTAssertTrue(hotkey.effects.contains(.holdChanged(.auto)))
    }

    func testConfigPreferredLayoutDrivesEngage() {
        var settings = Settings.defaults
        settings.preferredLayout = .whiteboardOnly
        let config = GovernorConfig(settings: settings)
        XCTAssertEqual(config.preferredLayout, .whiteboardOnly)
        XCTAssertNotEqual(config, GovernorConfig(settings: Settings.defaults), "a layout change alone is a config change (applied in PASSTHROUGH or on the next return)")
        var h = GovernorHarness(config: config)
        XCTAssertEqual(h.last.layout, .whiteboardOnly)
        let out = h.send(GovernorHarness.stylus())
        XCTAssertEqual(out.state, .engaging)
        XCTAssertEqual(out.layout, .whiteboardOnly, "a pen touch engages in the Settings layout")
        XCTAssertEqual(GovernorHarness().last.layout, .studioSplit, "the default stays Studio Split")
    }

    func testReturningInkWithAutoEngageOffDoesNotReengage() {
        var config = GovernorConfig()
        config.autoEngage = false
        var h = GovernorHarness(config: config)
        h.send(.pin(1))
        XCTAssertNotNil(h.tickUntil(state: .live, maxSeconds: 1))
        h.send(.returnNow)
        XCTAssertEqual(h.state, .returning)
        let id = UUID()
        XCTAssertEqual(h.send(GovernorHarness.stylus(id)).state, .returning, "auto-engage off: ink is recorded, the return continues")
        XCTAssertEqual(h.last.activeContacts, 1)
        XCTAssertEqual(h.send(.motion(strokeID: id)).state, .returning)
        XCTAssertEqual(h.send(.penContact(down: true)).state, .returning)
        XCTAssertEqual(h.send(.engage).state, .engaging, "an explicit engage still re-engages")
    }

    func testReturningPinOffAndToggleWhenPinned() {
        var h = GovernorHarness()
        h.goLive()
        h.send(.returnNow)
        XCTAssertEqual(h.send(.pin(0)).state, .returning)
        XCTAssertTrue(h.last.effects.isEmpty)
        XCTAssertEqual(h.send(.pin(-1)).state, .engaging, "toggle while unpinned keeps it")
        h.send(.returnNow)   // engaging -> returning, pinned cleared
        XCTAssertFalse(h.last.pinned)
    }

    func testReturningHoldSplitReengages() {
        var h = GovernorHarness()
        h.goLive()
        h.send(.returnNow)
        let out = h.send(.hold(.whiteboard))
        XCTAssertEqual(out.state, .engaging)
        XCTAssertEqual(out.layout, .whiteboardOnly)
        XCTAssertEqual(out.hold, .whiteboard)
    }

    func testReturningClearSavesWithoutTransition() {
        var h = GovernorHarness()
        h.goLive()
        h.send(.returnNow)
        let out = h.send(.clear)
        XCTAssertEqual(out.state, .returning)
        XCTAssertEqual(out.effects, [.savePage(reason: .cleared), .clearCanvas])
        XCTAssertNotNil(h.tickUntil(state: .passthrough, maxSeconds: 1))
        XCTAssertEqual(h.saveCount, 1, "already saved by the clear")
    }

    func testReturningBookkeepingEvents() {
        var h = GovernorHarness()
        h.goLive()
        let id = UUID()
        h.send(GovernorHarness.stylus(id))
        h.send(.returnNow)
        XCTAssertTrue(h.send(.returnNow).effects.isEmpty)
        XCTAssertEqual(h.send(.lift(strokeID: id)).activeContacts, 0)
        XCTAssertEqual(h.send(.hold(.camera)).effects, [.holdChanged(.camera)])
        XCTAssertEqual(h.state, .returning)
    }

    func testReturningCompletionClearsPinAndContacts() {
        var h = GovernorHarness()
        h.goLive()
        let id = UUID()
        h.send(GovernorHarness.stylus(id))
        h.send(.returnNow)
        h.send(.pin(0))
        XCTAssertNotNil(h.tickUntil(state: .passthrough, maxSeconds: 1))
        XCTAssertEqual(h.last.activeContacts, 0)
        XCTAssertFalse(h.last.pinned)
        XCTAssertEqual(h.governor.generation, 4, "engage, live, returning, passthrough")
    }

    // Generation and deadlines

    func testGenerationIncrementsOnEveryStateChange() {
        var h = GovernorHarness()
        XCTAssertEqual(h.governor.generation, 0)
        _ = h.engageAndLift()
        XCTAssertEqual(h.governor.generation, 1)
        h.send(.activity)
        XCTAssertEqual(h.governor.generation, 1, "bookkeeping does not bump it")
        XCTAssertNotNil(h.tickUntil(state: .live, maxSeconds: 1))
        XCTAssertEqual(h.governor.generation, 2)
        h.send(.returnNow)
        XCTAssertEqual(h.governor.generation, 3)
        h.send(GovernorHarness.stylus())
        XCTAssertEqual(h.governor.generation, 4)
    }

    func testNextDeadline() {
        var h = GovernorHarness()
        XCTAssertNil(h.governor.nextDeadline(now: 0))
        _ = h.engageAndLift()
        XCTAssertEqual(h.governor.nextDeadline(now: 0.1), 0.1)
        XCTAssertNotNil(h.tickUntil(state: .live, maxSeconds: 1))
        XCTAssertEqual(h.governor.nextDeadline(now: h.now) ?? 0, 85.0, accuracy: 1e-9)
        h.tickUntil(86)
        XCTAssertEqual(h.governor.nextDeadline(now: h.now), h.now, "the breath animates")
        h.send(.pin(1))
        XCTAssertNil(h.governor.nextDeadline(now: h.now))
    }

    func testSnapshotCarriesNoEffects() {
        var h = GovernorHarness()
        h.send(.pin(1))
        XCTAssertTrue(h.governor.snapshot.effects.isEmpty)
        XCTAssertEqual(h.governor.snapshot.state, .engaging)
        XCTAssertTrue(h.governor.snapshot.pinned)
    }
}
