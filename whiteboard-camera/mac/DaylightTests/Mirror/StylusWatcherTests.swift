import DaylightKit
import Foundation
import XCTest
@testable import Daylight

/// A `getevent` transcript through `FakeAdb` becomes transitions and gestures in order; no pen node is row 28; EOF
/// releases the contact and restarts with backoff.
final class StylusWatcherTests: XCTestCase {
    private func makeWatcher(listing: String, adb: FakeAdb) -> StylusWatcher {
        adb.respond(containing: ["getevent", "-pl"], with: FakeAdb.ok(listing))
        return StylusWatcher(adb: adb, serial: "JP0001", queue: DispatchQueue(label: "stylus"), gestures: SideButtonGestures(), backoffInitial: 0.05, backoffMax: 0.2, sideButtonSanitySeconds: 30)
    }

    func testProbeFindsThePenNodeAndStreamsIt() {
        let adb = FakeAdb()
        let watcher = makeWatcher(listing: StylusFixtures.listingWithPen, adb: adb)
        let watching = expectation(description: "watching")
        let transitions = Locked<[StylusTransition]>([])
        let gestures = Locked<[SideButtonGesture]>([])
        let gotDouble = expectation(description: "double press")
        let penUp = expectation(description: "contact up")
        // The gesture can fire before the sixth transition (side1Up at 11.4 s) is appended (run 37149301627), so the
        // count is read only after all six arrived.
        let sixTransitions = expectation(description: "six transitions")
        watcher.onStatus = { status in
            if case let .watching(path, name, pressureMax) = status {
                XCTAssertEqual(path, "/dev/input/event3")
                XCTAssertEqual(name, "Wacom I2C Digitizer")
                XCTAssertEqual(pressureMax, 4095)
                watching.fulfill()
            }
        }
        watcher.onTransition = { transition in
            let count = transitions.withLock { list -> Int in list.append(transition); return list.count }
            if case .contactUp = transition { penUp.fulfill() }
            if count == 6 { sixTransitions.fulfill() }
        }
        watcher.onGesture = { gesture in
            gestures.withLock { $0.append(gesture) }
            if gesture == .doublePress { gotDouble.fulfill() }
        }
        watcher.start()
        wait(for: [watching], timeout: 5)
        XCTAssertEqual(adb.calls.first, ["-s", "JP0001", "shell", "-T", "getevent", "-pl"])
        XCTAssertEqual(adb.spawned.first?.args, ["-s", "JP0001", "shell", "-T", "getevent", "-lt", "/dev/input/event3"])
        guard let child = adb.spawned.first else { return XCTFail("no getevent child") }
        // Hover, contact, motion, lift (split across writes), then a double press of the side button.
        child.emitStdout(StylusFixtures.report(10.0, [("EV_KEY", "BTN_TOOL_PEN", "DOWN"), ("EV_ABS", "ABS_X", "00000100")]))
        let down = StylusFixtures.penDown(at: 10.1)
        child.emitStdout(String(down.prefix(40)))
        child.emitStdout(String(down.dropFirst(40)))
        child.emitStdout(StylusFixtures.penMove(at: 10.2))
        child.emitStdout(StylusFixtures.penUp(at: 10.5))
        wait(for: [penUp], timeout: 5)
        child.emitStdout(StylusFixtures.sideButton(true, at: 11.0))
        child.emitStdout(StylusFixtures.sideButton(false, at: 11.1))
        child.emitStdout(StylusFixtures.sideButton(true, at: 11.3))
        child.emitStdout(StylusFixtures.sideButton(false, at: 11.4))
        wait(for: [gotDouble, sixTransitions], timeout: 5)
        let seen = transitions.withLock { $0 }
        XCTAssertEqual(seen.count, 6, "\(seen)")
        guard case let .contactDown(sample)? = seen.first else { return XCTFail("contactDown first, got \(seen)") }
        XCTAssertEqual(sample.tsUs, 10_100_000)
        XCTAssertEqual(sample.pressure, 2048.0 / 4095.0, accuracy: 1e-9)
        XCTAssertEqual(sample.x, 0x1234)
        guard case .contactUp? = seen.dropFirst().first else { return XCTFail("contactUp second") }
        XCTAssertEqual(seen[2], .side1Down(tsUs: 11_000_000))
        XCTAssertEqual(seen[3], .side1Up(tsUs: 11_100_000))
        XCTAssertEqual(seen[4], .side1Down(tsUs: 11_300_000))
        XCTAssertEqual(seen[5], .side1Up(tsUs: 11_400_000))
        XCTAssertEqual(gestures.withLock { $0 }, [.doublePress])
        XCTAssertEqual(watcher.sideButtonEventsSeen, 4)
        XCTAssertNil(watcher.diagnostics["pen.node"], "the node key belongs to the controller's diagnostics")
        XCTAssertTrue(watcher.diagnostics["pen.status"]?.hasPrefix("watching /dev/input/event3") ?? false)
        watcher.stop()
    }

    func testLongPressFiresFromTheTimerWhileHeld() {
        let adb = FakeAdb()
        let watcher = makeWatcher(listing: StylusFixtures.listingWithPen, adb: adb)
        let watching = expectation(description: "watching")
        watcher.onStatus = { if case .watching = $0 { watching.fulfill() } }
        let long = expectation(description: "long press")
        let started = Locked(Date())
        watcher.onGesture = { gesture in
            XCTAssertEqual(gesture, .longPress)
            let elapsed = Date().timeIntervalSince(started.withLock { $0 })
            XCTAssertGreaterThan(elapsed, 0.6, "fires about 700 ms after the press, not before")
            long.fulfill()
        }
        watcher.start()
        wait(for: [watching], timeout: 5)
        guard let child = adb.spawned.first else { return XCTFail("no child") }
        started.withLock { $0 = Date() }
        child.emitStdout(StylusFixtures.sideButton(true, at: 50.0))
        wait(for: [long], timeout: 5)
        // The release after a long press is silent.
        let silent = expectation(description: "silent release")
        silent.isInverted = true
        watcher.onGesture = { _ in silent.fulfill() }
        child.emitStdout(StylusFixtures.sideButton(false, at: 51.0))
        wait(for: [silent], timeout: 0.3)
        watcher.stop()
    }

    func testNoPenNodeIsRow28() {
        let adb = FakeAdb()
        let watcher = makeWatcher(listing: StylusFixtures.listingWithoutPen, adb: adb)
        let none = expectation(description: "no pen")
        let logs = Locked<[String]>([])
        watcher.onLog = { line in logs.withLock { $0.append(line) } }
        watcher.onStatus = { status in
            if case let .noPenDevice(names) = status {
                XCTAssertEqual(names, ["fts_ts (/dev/input/event4)"])
                none.fulfill()
            }
        }
        watcher.start()
        wait(for: [none], timeout: 5)
        XCTAssertTrue(adb.spawned.isEmpty, "nothing is streamed without a pen node")
        XCTAssertTrue(logs.withLock { $0 }.contains { $0.hasPrefix("getevent -pl devices:") })
        XCTAssertEqual(FailureText.sentence(.noPenDevice), "Pen events not found on this Daylight. Mirror works, but auto-engage and the pen button do not. Use the pills or the Whiteboard hotkey.")
        watcher.stop()
    }

    func testEOFReleasesTheContactAndRestarts() {
        let adb = FakeAdb()
        let watcher = makeWatcher(listing: StylusFixtures.listingWithPen, adb: adb)
        let watching = expectation(description: "watching")
        watching.assertForOverFulfill = false
        watcher.onStatus = { if case .watching = $0 { watching.fulfill() } }
        let released = expectation(description: "contactUp on EOF")
        watcher.onTransition = { if case .contactUp = $0 { released.fulfill() } }
        watcher.start()
        wait(for: [watching], timeout: 5)
        guard let child = adb.spawned.first else { return XCTFail("no child") }
        child.emitStdout(StylusFixtures.penDown(at: 1.0))
        child.exit(0)
        wait(for: [released], timeout: 5)
        let respawned = expectation(description: "respawned")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { respawned.fulfill() }
        wait(for: [respawned], timeout: 5)
        XCTAssertGreaterThanOrEqual(adb.spawned.count, 2, "restarted after the backoff")
        XCTAssertGreaterThanOrEqual(watcher.restarts, 1)
        XCTAssertEqual(adb.calls(containing: "-pl").count, 1, "the node is remembered; no second probe")
        watcher.stop()
    }

    func testSideButtonSanityAfterThirtySecondsOfInking() {
        let adb = FakeAdb()
        adb.respond(containing: ["getevent", "-pl"], with: FakeAdb.ok(StylusFixtures.listingWithPen))
        let watcher = StylusWatcher(adb: adb, serial: "S", queue: DispatchQueue(label: "stylus"), gestures: SideButtonGestures(), backoffInitial: 0.05, backoffMax: 0.1, sideButtonSanitySeconds: 30)
        let watching = expectation(description: "watching")
        watcher.onStatus = { if case .watching = $0 { watching.fulfill() } }
        watcher.start()
        wait(for: [watching], timeout: 5)
        let silent = expectation(description: "28b")
        watcher.onStatus = { if $0 == .sideButtonSilent { silent.fulfill() } }
        guard let child = adb.spawned.first else { return XCTFail("no child") }
        // Three strokes of 12 s each on the device clock: 36 s of inking, no BTN_STYLUS ever.
        for i in 0..<3 {
            let t = Double(i) * 20
            child.emitStdout(StylusFixtures.penDown(at: 100 + t))
            child.emitStdout(StylusFixtures.penUp(at: 112 + t))
        }
        wait(for: [silent], timeout: 5)
        XCTAssertEqual(FailureText.sentence(.noSideButtonEvents), "Pen button events not seen; use the pills.")
        watcher.stop()
    }
}
