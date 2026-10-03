import Foundation
import XCTest
import DaylightKit

/// SPEC section 5.4: one test method per sentence, under a manual clock stepping 1/30 s (acceptance A3).
final class GovernorScenarioTests: XCTestCase {
    // "Engage only on stylus contact with pressure > 0 (finger, palm, hover, pressure 0, mouse rejected)"

    func testEngagesOnStylusContactWithPressure() {
        var h = GovernorHarness()
        let out = h.send(GovernorHarness.stylus(pressure: 0.3))
        XCTAssertEqual(out.state, .engaging)
        XCTAssertEqual(out.effects, [.stateChanged(from: .passthrough, to: .engaging)])
        XCTAssertEqual(out.activeContacts, 1)
        XCTAssertEqual(h.governor.generation, 1)
        XCTAssertTrue(h.governor.needsTicks)
    }

    func testFingerIsRejected() {
        var h = GovernorHarness()
        let out = h.send(.contact(strokeID: UUID(), pointer: .finger, phase: .contact, pressure: 0.9, tool: .pen))
        XCTAssertEqual(out.state, .passthrough)
        XCTAssertEqual(out.activeContacts, 0, "a dropped contact is not tracked")
        XCTAssertTrue(out.effects.isEmpty)
    }

    func testPalmIsRejected() {
        var h = GovernorHarness()
        let out = h.send(.contact(strokeID: UUID(), pointer: .palm, phase: .contact, pressure: 0.9, tool: .pen))
        XCTAssertEqual(out.state, .passthrough)
        XCTAssertEqual(out.activeContacts, 0)
    }

    func testHoverIsRejected() {
        var h = GovernorHarness()
        let out = h.send(.contact(strokeID: UUID(), pointer: .stylus, phase: .hover, pressure: 0.5, tool: .pen))
        XCTAssertEqual(out.state, .passthrough)
        XCTAssertEqual(out.activeContacts, 0)
    }

    func testPressureZeroIsRejected() {
        var h = GovernorHarness()
        let out = h.send(.contact(strokeID: UUID(), pointer: .stylus, phase: .contact, pressure: 0, tool: .pen))
        XCTAssertEqual(out.state, .passthrough)
        XCTAssertEqual(out.activeContacts, 0)
    }

    func testMouseIsRejected() {
        var h = GovernorHarness()
        let out = h.send(.contact(strokeID: UUID(), pointer: .mouse, phase: .contact, pressure: 1, tool: .pen))
        XCTAssertEqual(out.state, .passthrough)
    }

    // "eraser contact engages only with engageOnEraser"

    func testEraserContactDoesNotEngageByDefault() {
        var h = GovernorHarness()
        let id = UUID()
        let out = h.send(GovernorHarness.stylus(id, tool: .eraser))
        XCTAssertEqual(out.state, .passthrough)
        XCTAssertEqual(out.activeContacts, 1, "the id is tracked so lift clears it")
        XCTAssertEqual(h.send(.lift(strokeID: id)).activeContacts, 0)
        XCTAssertEqual(h.send(.eraserContact(down: true)).state, .passthrough)
    }

    func testEraserContactEngagesWithEngageOnEraser() {
        var config = GovernorConfig()
        config.engageOnEraser = true
        var h = GovernorHarness(config: config)
        XCTAssertEqual(h.send(GovernorHarness.stylus(tool: .eraser)).state, .engaging)
        var h2 = GovernorHarness(config: config)
        XCTAssertEqual(h2.send(.eraserContact(down: true)).state, .engaging)
    }

    // "ENGAGING settles to LIVE at 0.251 s (within one tick)"

    func testEngagingSettlesToLiveWithinOneTickOf251ms() throws {
        var h = GovernorHarness()
        _ = h.engageAndLift()
        let arrival = h.tickUntil(state: .live, maxSeconds: 1)
        let t = try XCTUnwrap(arrival)
        XCTAssertGreaterThanOrEqual(t, 0.251 - 1e-9)
        XCTAssertLessThan(t, 0.251 + GovernorHarness.dt)
        XCTAssertEqual(h.last.progress, 1, accuracy: 1e-12, "snapped to 1 on arrival")
        XCTAssertEqual(h.stateChanges.last, .stateChanged(from: .engaging, to: .live))
    }

    // "progress at 0.100 s = 0.8603 within 1e-3"

    func testProgressAt100msIs0_8603() {
        var h = GovernorHarness()
        _ = h.engageAndLift()
        h.tickUntil(0.1)
        XCTAssertEqual(h.now, 0.1, accuracy: 1e-9)
        XCTAssertEqual(h.last.progress, 0.8603, accuracy: 1e-3)
        XCTAssertEqual(h.last.state, .engaging)
    }

    // "snap-back at cancel 60 ms with progress 0.11 -> PASSTHROUGH, cancel at 90 ms stays ENGAGING"

    func testSnapBackAtCancel60msWithProgress0_11() {
        var config = GovernorConfig()
        config.springK = 90   // a slow spring puts progress at about 0.11 after 60 ms (default k is 0.61 there)
        var h = GovernorHarness(config: config)
        let id = UUID()
        h.send(GovernorHarness.stylus(id))
        h.tick()   // 33 ms
        var out = h.governor.handle(.motion(strokeID: id), now: 0.06)
        XCTAssertEqual(out.progress, 0.11, accuracy: 0.01)
        out = h.governor.handle(.cancel(strokeID: id), now: 0.06)
        XCTAssertEqual(out.state, .passthrough)
        XCTAssertEqual(out.progress, 0)
        XCTAssertEqual(out.effects, [.stateChanged(from: .engaging, to: .passthrough)], "no save on snap-back")
        XCTAssertFalse(h.governor.needsTicks)
    }

    func testCancelAt90msStaysEngaging() {
        var config = GovernorConfig()
        config.springK = 90
        var h = GovernorHarness(config: config)
        let id = UUID()
        h.send(GovernorHarness.stylus(id))
        let out = h.governor.handle(.cancel(strokeID: id), now: 0.09)
        XCTAssertEqual(out.state, .engaging)
        XCTAssertEqual(out.activeContacts, 0)
    }

    func testSnapBackNeedsAllOfWindowProgressAndNoOtherContacts() {
        // Default spring: 15 ms is inside the window and under 0.15; 33 ms (one tick) is already at 0.32.
        var h = GovernorHarness()
        let id = UUID()
        h.send(GovernorHarness.stylus(id))
        XCTAssertEqual(h.governor.handle(.cancel(strokeID: id), now: 0.015).state, .passthrough)

        var h2 = GovernorHarness()
        let id2 = UUID()
        h2.send(GovernorHarness.stylus(id2))
        h2.tick()
        XCTAssertEqual(h2.send(.cancel(strokeID: id2)).state, .engaging, "progress 0.32 at 33 ms is past the 0.15 limit")

        var h3 = GovernorHarness()
        let a = UUID()
        let b = UUID()
        h3.send(GovernorHarness.stylus(a))
        h3.send(GovernorHarness.stylus(b))
        XCTAssertEqual(h3.governor.handle(.cancel(strokeID: a), now: 0.015).state, .engaging, "another pen is still down")
    }

    func testSnapBackNeedsAnEngageCausedByTheStroke() {
        // A pin or a forced hold asked for the board regardless of the stroke, so a cancelled dab inside the snap-back
        // window keeps the board coming (PASSTHROUGH must never carry `pinned` or a forced hold).
        var config = GovernorConfig()
        config.springK = 90
        var pinned = GovernorHarness(config: config)
        pinned.send(.pin(1))
        let id = UUID()
        pinned.send(GovernorHarness.stylus(id))
        var out = pinned.governor.handle(.cancel(strokeID: id), now: 0.02)
        XCTAssertEqual(out.state, .engaging, "pinned: no snap-back")
        XCTAssertTrue(out.pinned)
        XCTAssertEqual(out.activeContacts, 0)
        XCTAssertTrue(out.effects.isEmpty)

        var held = GovernorHarness(config: config)
        held.send(.hold(.split))
        let id2 = UUID()
        held.send(GovernorHarness.stylus(id2))
        out = held.governor.handle(.cancel(strokeID: id2), now: 0.02)
        XCTAssertEqual(out.state, .engaging, "forced hold: no snap-back")
        XCTAssertEqual(out.hold, .split)

        var plain = GovernorHarness(config: config)
        let id3 = UUID()
        plain.send(GovernorHarness.stylus(id3))
        out = plain.governor.handle(.cancel(strokeID: id3), now: 0.02)
        XCTAssertEqual(out.state, .passthrough, "the stroke caused the engage: snap-back as before")
        XCTAssertFalse(out.pinned)
        XCTAssertEqual(out.hold, .auto)
    }

    func testSnapBackNeedsTheStrokeThatEngaged() {
        // A stylus contact tracked in PASSTHROUGH without engaging (auto-engage off, or the eraser without
        // engageOnEraser), then a hotkey or the menu brings the board up: cancelling that contact inside the window
        // must not snap the board back (SPEC 5.2: a hotkey brought it up).
        var config = GovernorConfig()
        config.springK = 90
        config.autoEngage = false
        for request in [GovernorEvent.layoutHotkey(.studioSplit), .engage] {
            var h = GovernorHarness(config: config)
            let x = UUID()
            XCTAssertEqual(h.send(GovernorHarness.stylus(x)).state, .passthrough)
            XCTAssertEqual(h.send(request).state, .engaging)
            let out = h.governor.handle(.cancel(strokeID: x), now: 0.02)
            XCTAssertLessThan(out.progress, config.snapBackMaxProgress, "inside the snap-back progress limit")
            XCTAssertEqual(out.state, .engaging, "\(request): no snap-back for a board the stroke did not bring up")
            XCTAssertEqual(out.activeContacts, 0)
        }

        var eraserConfig = GovernorConfig()
        eraserConfig.springK = 90
        var e = GovernorHarness(config: eraserConfig)
        let rub = UUID()
        XCTAssertEqual(e.send(GovernorHarness.stylus(rub, tool: .eraser)).state, .passthrough)
        XCTAssertEqual(e.send(.engage).state, .engaging)
        XCTAssertEqual(e.governor.handle(.cancel(strokeID: rub), now: 0.02).state, .engaging, "eraser stroke, menu engage")

        // After that board comes down, a stroke-caused engage snaps back again.
        var again = GovernorHarness(config: eraserConfig)
        again.send(.engage)
        again.send(.returnNow)
        XCTAssertNotNil(again.tickUntil(state: .passthrough, maxSeconds: 2))
        let y = UUID()
        let start = again.now
        XCTAssertEqual(again.send(GovernorHarness.stylus(y)).state, .engaging)
        XCTAssertEqual(again.governor.handle(.cancel(strokeID: y), now: start + 0.02).state, .passthrough)
    }

    // "pre-warning at exactly 85.0 s, RETURNING at 90.0 s, PASSTHROUGH 0.251 s later with exactly one savePage(.returned)"

    func testPreWarningAt85ReturnAt90PassthroughWithOneSave() throws {
        var h = GovernorHarness()
        h.goLive()
        h.tickUntil(84.9)
        XCTAssertFalse(h.last.preWarning)
        XCTAssertEqual(h.count { $0 == .preWarningStarted }, 0)
        h.tickUntil(85.0)
        XCTAssertEqual(h.now, 85.0, accuracy: 1e-9)
        XCTAssertTrue(h.last.preWarning)
        XCTAssertEqual(h.last.state, .live)
        XCTAssertEqual(h.effects.last?.effect, .preWarningStarted)
        XCTAssertEqual(h.effects.last?.t ?? -1, 85.0, accuracy: 1e-9)
        XCTAssertEqual(h.last.breath, 0, accuracy: 1e-9)
        h.tickUntil(86.0)
        XCTAssertEqual(h.last.breath, 1, accuracy: 1e-9, "0.5 Hz breath peaks one second in")
        h.tickUntil(89.9)
        XCTAssertEqual(h.last.state, .live)
        h.tickUntil(90.0)
        XCTAssertEqual(h.last.state, .returning)
        XCTAssertEqual(h.last.msToReturn, 0)
        XCTAssertFalse(h.last.preWarning)
        XCTAssertTrue(h.effects.contains { $0.effect == .preWarningCancelled && abs($0.t - 90.0) < 1e-9 })
        let arrival = try XCTUnwrap(h.tickUntil(state: .passthrough, maxSeconds: 1))
        XCTAssertEqual(arrival, 90.0 + 0.251, accuracy: GovernorHarness.dt)
        XCTAssertEqual(h.saveCount, 1)
        XCTAssertEqual(h.effects.filter { $0.effect == .savePage(reason: .returned) }.count, 1)
        XCTAssertEqual(h.last.progress, 0)
        XCTAssertEqual(h.last.msToReturn, StateReport.noReturnScheduled)
        XCTAssertFalse(h.governor.needsTicks)
    }

    // "any ink cancels pre-warning"

    func testAnyInkCancelsPreWarning() {
        var h = GovernorHarness()
        h.goLive()
        h.tickUntil(86.0)
        XCTAssertTrue(h.last.preWarning)
        let id = UUID()
        let out = h.send(GovernorHarness.stylus(id))
        XCTAssertFalse(out.preWarning)
        XCTAssertEqual(out.effects, [.preWarningCancelled])
        XCTAssertEqual(out.state, .live)
        XCTAssertEqual(out.msToReturn, StateReport.noReturnScheduled, "pen down: no return scheduled")
        h.send(.lift(strokeID: id))
        XCTAssertEqual(h.last.msToReturn, 90_000)
        // Activity (erase, undo, laser) counts too.
        h.tickUntil(86.0 + 86.0)
        XCTAssertTrue(h.last.preWarning)
        XCTAssertEqual(h.send(.activity).effects, [.preWarningCancelled])
        // And a mirror eraser contact (D36).
        h.tickUntil(h.now + 86.0)
        XCTAssertTrue(h.last.preWarning)
        XCTAssertEqual(h.send(.eraserContact(down: true)).effects, [.preWarningCancelled])
    }

    // "ink mid-return retargets with |progress(t+) - progress(t-)| < 1e-9"

    func testInkMidReturnRetargetsContinuously() {
        var h = GovernorHarness()
        h.goLive()
        h.send(.returnNow)
        XCTAssertEqual(h.state, .returning)
        h.tick()
        h.tick()
        let before = h.last.progress
        XCTAssertGreaterThan(before, 0.2)
        XCTAssertLessThan(before, 0.9)
        let out = h.send(GovernorHarness.stylus())
        XCTAssertEqual(out.state, .engaging)
        XCTAssertEqual(out.progress, before, accuracy: 1e-9)
        XCTAssertEqual(out.effects, [.stateChanged(from: .returning, to: .engaging)])
        // The spring keeps its velocity: the next frame still moves toward the camera before turning (no jump).
        let next = h.tick().progress
        XCTAssertLessThan(abs(next - before), 0.2, "continuous motion after the retarget")
        XCTAssertNotNil(h.tickUntil(state: .live, maxSeconds: 1))
    }

    // "pin during RETURNING -> ENGAGING pinned"

    func testPinDuringReturningReengagesPinned() {
        var h = GovernorHarness()
        h.goLive()
        h.send(.returnNow)
        h.tick()
        let out = h.send(.pin(-1))
        XCTAssertEqual(out.state, .engaging)
        XCTAssertTrue(out.pinned)
        XCTAssertEqual(out.effects, [.pinChanged(true), .stateChanged(from: .returning, to: .engaging)])
        XCTAssertNotNil(h.tickUntil(state: .live, maxSeconds: 1))
        h.tickUntil(400)
        XCTAssertEqual(h.state, .live, "pinned: no return")
        XCTAssertEqual(h.last.msToReturn, StateReport.noReturnScheduled)
    }

    // "engage during RETURNING -> ENGAGING"

    func testEngageDuringReturningReengages() {
        var h = GovernorHarness()
        h.goLive()
        h.send(.returnNow)
        h.tick()
        let out = h.send(.engage)
        XCTAssertEqual(out.state, .engaging)
        XCTAssertFalse(out.pinned)
        XCTAssertEqual(out.effects, [.stateChanged(from: .returning, to: .engaging)])
    }

    // "pin suppresses return at 200 s, unpin returns at unpin + 90 s"

    func testPinSuppressesReturnAndUnpinGivesFresh90s() {
        var h = GovernorHarness()
        h.goLive()
        h.send(.pin(1))
        XCTAssertTrue(h.last.pinned)
        h.tickUntil(200)
        XCTAssertEqual(h.state, .live)
        XCTAssertFalse(h.last.preWarning, "pinned: no pre-warning either")
        let out = h.send(.pin(0))
        XCTAssertFalse(out.pinned)
        XCTAssertEqual(out.effects, [.pinChanged(false)])
        XCTAssertEqual(out.msToReturn, 90_000)
        h.tickUntil(200 + 89.9)
        XCTAssertEqual(h.state, .live)
        h.tickUntil(290.0)
        XCTAssertEqual(h.state, .returning)
    }

    // "pin from PASSTHROUGH engages"

    func testPinFromPassthroughEngages() {
        var h = GovernorHarness()
        let out = h.send(.pin(-1))
        XCTAssertEqual(out.state, .engaging)
        XCTAssertTrue(out.pinned)
        XCTAssertEqual(out.effects, [.pinChanged(true), .stateChanged(from: .passthrough, to: .engaging)])
        var h2 = GovernorHarness()
        XCTAssertEqual(h2.send(.pin(0)).state, .passthrough, "pin off from camera does nothing")
        XCTAssertTrue(h2.last.effects.isEmpty)
    }

    // "pen on glass (start without commit at 80 s) freezes the timer (no return at 300 s)"

    func testPenOnGlassFreezesTheTimer() {
        var h = GovernorHarness()
        h.goLive()
        h.tickUntil(80)
        let id = UUID()
        h.send(GovernorHarness.stylus(id))
        XCTAssertEqual(h.last.msToReturn, StateReport.noReturnScheduled)
        h.tickUntil(300)
        XCTAssertEqual(h.state, .live)
        XCTAssertFalse(h.last.preWarning)
        h.send(.lift(strokeID: id))
        XCTAssertEqual(h.last.msToReturn, 90_000)
        h.tickUntil(300 + 90)
        XCTAssertEqual(h.state, .returning)
    }

    // "clear unpinned -> [savePage, clearCanvas] then RETURNING"

    func testClearUnpinnedSavesClearsAndReturns() {
        var h = GovernorHarness()
        h.goLive()
        let out = h.send(.clear)
        XCTAssertEqual(out.effects, [.savePage(reason: .cleared), .clearCanvas, .stateChanged(from: .live, to: .returning)])
        XCTAssertEqual(out.state, .returning)
        XCTAssertNotNil(h.tickUntil(state: .passthrough, maxSeconds: 1))
        XCTAssertEqual(h.saveCount, 1, "the return after a clear does not save again")
    }

    // "clear pinned -> [savePage, clearCanvas], stays LIVE"

    func testClearPinnedSavesClearsStaysLive() {
        var h = GovernorHarness()
        h.goLive()
        h.send(.pin(1))
        let out = h.send(.clear)
        XCTAssertEqual(out.effects, [.savePage(reason: .cleared), .clearCanvas])
        XCTAssertEqual(out.state, .live)
        XCTAssertTrue(out.pinned)
    }

    // "clear twice on a pinned board saves once"

    func testClearTwiceOnPinnedBoardSavesOnce() {
        var h = GovernorHarness()
        h.goLive()
        h.send(.pin(1))
        h.send(.clear)
        let second = h.send(.clear)
        XCTAssertTrue(second.effects.isEmpty, "nothing dirty, nothing to clear")
        XCTAssertEqual(h.saveCount, 1)
        XCTAssertEqual(h.count { $0 == .clearCanvas }, 1)
    }

    // "clientGone and allClientsGone never change state"

    func testClientGoneNeverChangesState() {
        var h = GovernorHarness()
        h.goLive()
        let id = UUID()
        h.send(GovernorHarness.stylus(id))
        let out = h.send(.clientGone(strokeIDs: [id]))
        XCTAssertEqual(out.state, .live)
        XCTAssertEqual(out.activeContacts, 0)
        XCTAssertTrue(out.effects.isEmpty)
        let out2 = h.send(.allClientsGone)
        XCTAssertEqual(out2.state, .live)
        XCTAssertTrue(out2.effects.isEmpty)
        // The idle timer carries on from the last activity: a Wi-Fi blip does not yank the board away.
        XCTAssertEqual(h.last.msToReturn, 90_000)
        h.tickUntil(h.now + 60)
        XCTAssertEqual(h.state, .live)
        var p = GovernorHarness()
        XCTAssertEqual(p.send(.allClientsGone).state, .passthrough)
        var r = GovernorHarness()
        r.goLive()
        r.send(.returnNow)
        XCTAssertEqual(r.send(.allClientsGone).state, .returning)
    }

    // "sourceChanged clears contacts"

    func testClientGoneAfterALongContactGivesAFreshIdlePeriod() {
        // A pen resting on the glass freezes the timer; when its client drops off, the board gets a full idle period
        // with its pre-warning instead of returning on the next tick.
        var h = GovernorHarness()
        h.goLive()
        h.tickUntil(10)
        let id = UUID()
        h.send(GovernorHarness.stylus(id))
        h.tickUntil(110)
        XCTAssertEqual(h.state, .live, "the open contact freezes the timer")
        XCTAssertEqual(h.last.msToReturn, StateReport.noReturnScheduled)
        let gone = h.send(.clientGone(strokeIDs: [id]))
        XCTAssertEqual(gone.state, .live)
        XCTAssertTrue(gone.effects.isEmpty)
        XCTAssertEqual(gone.msToReturn, 90_000)
        h.tickUntil(194.9)
        XCTAssertEqual(h.state, .live)
        XCTAssertEqual(h.count { $0 == .preWarningStarted }, 0)
        h.tickUntil(195)
        XCTAssertEqual(h.count { $0 == .preWarningStarted }, 1, "pre-warning at 195 s")
        XCTAssertEqual(h.state, .live)
        h.tickUntil(199.9)
        XCTAssertEqual(h.state, .live)
        h.tickUntil(200)
        XCTAssertEqual(h.state, .returning, "return at 200 s")

        // The same for allClientsGone and sourceChanged; a drop that removes nothing leaves the timer alone.
        var a = GovernorHarness()
        a.goLive()
        a.send(GovernorHarness.stylus())
        a.tickUntil(100)
        a.send(.allClientsGone)
        XCTAssertEqual(a.last.msToReturn, 90_000)
        var s = GovernorHarness()
        s.goLive()
        s.send(.penContact(down: true))
        s.tickUntil(100)
        s.send(.sourceChanged(.web))
        XCTAssertEqual(s.last.msToReturn, 90_000)
        var idle = GovernorHarness()
        idle.goLive()
        idle.tickUntil(30)
        let before = idle.last.msToReturn
        idle.send(.clientGone(strokeIDs: [UUID()]))
        XCTAssertEqual(idle.last.msToReturn, before, "no contact removed: the timer carries on")
    }

    func testSourceChangedClearsContacts() {
        var h = GovernorHarness()
        h.goLive()
        h.send(GovernorHarness.stylus())
        h.send(GovernorHarness.stylus())
        XCTAssertEqual(h.last.activeContacts, 2)
        let out = h.send(.sourceChanged(.mirror))
        XCTAssertEqual(out.activeContacts, 0)
        XCTAssertEqual(out.state, .live, "the board stays where it is")
        XCTAssertTrue(out.effects.isEmpty)
    }

    // "hold modes disable the timer and hold(auto) restarts it without touching pinned"

    func testHoldModesDisableTheTimerAndAutoRestartsIt() {
        var h = GovernorHarness()
        h.goLive()
        let out = h.send(.hold(.whiteboard))
        XCTAssertEqual(out.effects, [.holdChanged(.whiteboard)])
        XCTAssertEqual(out.layout, .whiteboardOnly)
        XCTAssertEqual(out.hold, .whiteboard)
        XCTAssertEqual(out.msToReturn, StateReport.noReturnScheduled)
        h.tickUntil(500)
        XCTAssertEqual(h.state, .live)
        XCTAssertFalse(h.last.preWarning)
        XCTAssertFalse(h.last.pinned)
        let auto = h.send(.hold(.auto))
        XCTAssertEqual(auto.effects, [.holdChanged(.auto)])
        XCTAssertFalse(auto.pinned)
        XCTAssertEqual(auto.msToReturn, 90_000)
        XCTAssertEqual(auto.layout, .whiteboardOnly, "the layout keeps the held value")
        h.tickUntil(590)
        XCTAssertEqual(h.state, .returning)
    }

    func testHoldAutoLeavesPinnedUntouched() {
        var h = GovernorHarness()
        h.goLive()
        h.send(.pin(1))
        h.send(.hold(.split))
        let out = h.send(.hold(.auto))
        XCTAssertTrue(out.pinned)
        XCTAssertEqual(out.msToReturn, StateReport.noReturnScheduled)
        h.tickUntil(400)
        XCTAssertEqual(h.state, .live)
    }

    // "layout hotkey toggle semantics"

    func testLayoutHotkeyToggleSemantics() {
        var h = GovernorHarness()
        XCTAssertEqual(h.send(.layoutHotkey(.whiteboardOnly)).state, .engaging, "W from camera engages")
        XCTAssertEqual(h.last.layout, .whiteboardOnly)
        XCTAssertNotNil(h.tickUntil(state: .live, maxSeconds: 1))
        let switched = h.send(.layoutHotkey(.studioSplit))
        XCTAssertEqual(switched.state, .live, "a different layout switches without a slide")
        XCTAssertEqual(switched.layout, .studioSplit)
        XCTAssertTrue(switched.effects.isEmpty)
        h.send(.pin(1))
        let toggled = h.send(.layoutHotkey(.studioSplit))
        XCTAssertEqual(toggled.state, .returning, "the active layout's hotkey returns to camera")
        XCTAssertFalse(toggled.pinned, "unpinning first")
        XCTAssertEqual(toggled.effects, [.pinChanged(false), .stateChanged(from: .live, to: .returning)])
        let back = h.send(.layoutHotkey(.whiteboardOnly))
        XCTAssertEqual(back.state, .engaging, "a hotkey during the return re-engages")
        XCTAssertEqual(back.layout, .whiteboardOnly)
    }

    // "ms_to_return values per state"

    func testMsToReturnPerState() {
        var h = GovernorHarness()
        XCTAssertEqual(h.last.msToReturn, StateReport.noReturnScheduled, "PASSTHROUGH")
        _ = h.engageAndLift()
        XCTAssertEqual(h.last.msToReturn, StateReport.noReturnScheduled, "ENGAGING")
        XCTAssertNotNil(h.tickUntil(state: .live, maxSeconds: 1))
        let elapsed = h.now
        XCTAssertEqual(Double(h.last.msToReturn), (90 - elapsed) * 1000, accuracy: 0.6, "LIVE and idle")
        h.tickUntil(30)
        XCTAssertEqual(h.last.msToReturn, 60_000)
        h.send(.pin(1))
        XCTAssertEqual(h.last.msToReturn, StateReport.noReturnScheduled, "pinned")
        h.send(.pin(0))
        h.send(.hold(.split))
        XCTAssertEqual(h.last.msToReturn, StateReport.noReturnScheduled, "hold mode")
        h.send(.hold(.auto))
        let id = UUID()
        h.send(GovernorHarness.stylus(id))
        XCTAssertEqual(h.last.msToReturn, StateReport.noReturnScheduled, "pen down")
        h.send(.lift(strokeID: id))
        h.send(.returnNow)
        XCTAssertEqual(h.last.msToReturn, 0, "RETURNING")
    }

    // "STATE fields derived from output"

    func testStateReportDerivedFromOutput() {
        var h = GovernorHarness()
        h.goLive()
        h.send(.pin(1))
        let report = h.last.stateReport(clientFlags: [.clientAllowed, .clientIsActiveSource], inkSource: .native, pageIndex: 0, strokeCount: 3, undoDepth: 3, redoDepth: 0)
        XCTAssertEqual(report, StateReport(governor: 2, flags: 0x0D, mode: 0, inkSource: 1, progress: 1.0, msToReturn: 0xFFFF_FFFF, pageIndex: 0, strokeCount: 3, undoDepth: 3, redoDepth: 0), "equals the golden state_live_pinned")
        h.send(.pin(0))
        h.tickUntil(h.now + 86)
        XCTAssertTrue(h.last.preWarning)
        let warn = h.last.stateReport(clientFlags: [.clientAllowed, .cameraAttached, .sinkConnected], inkSource: .web, pageIndex: 1, strokeCount: 12, undoDepth: 12, redoDepth: 2)
        XCTAssertEqual(warn.governor, 2)
        XCTAssertEqual(warn.flags, 0x36)
        XCTAssertLessThanOrEqual(warn.msToReturn, 4_000)
        XCTAssertGreaterThan(warn.msToReturn, 3_900)
        h.send(.hold(.camera))
        let returning = h.last.stateReport(clientFlags: [], inkSource: .mirror, pageIndex: 70_000, strokeCount: 70_000, undoDepth: 1, redoDepth: 0)
        XCTAssertEqual(returning.governor, 3)
        XCTAssertEqual(returning.mode, 3)
        XCTAssertEqual(returning.inkSource, 2)
        XCTAssertEqual(returning.msToReturn, 0)
        XCTAssertEqual(returning.pageIndex, UInt16.max, "saturates")
        XCTAssertEqual(returning.strokeCount, UInt16.max)
        XCTAssertEqual(returning.flags & 0x02, 0, "pre-warning cleared by the hold")
        XCTAssertEqual(GovernorOutput.breathWeight(secondsSincePreWarning: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(GovernorOutput.breathWeight(secondsSincePreWarning: 2.0), 0, accuracy: 1e-9)
    }
}
