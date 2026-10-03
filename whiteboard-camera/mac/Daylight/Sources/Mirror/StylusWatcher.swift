import DaylightKit
import Foundation
import os

/// The pen watcher (ARCHITECTURE 6 item 7): `getevent -pl` once to find the Wacom node, then a long-running
/// `getevent -lt /dev/input/eventN` through `EvdevParser`, `StylusContactMachine` and `SideButtonGestures`. Restarts
/// with backoff 0.5 s doubling to 8 s on EOF and releases every switch first so no contact stays latched. After 30 s
/// of inking without a single side-button event it reports `sideButtonSilent` (failure row 28b). Runs on `queue`
/// (stylus.queue); the adb pipe bytes hop onto it.
final class StylusWatcher {
    enum Status: Equatable {
        case idle
        case probing
        case watching(path: String, name: String, pressureMax: Int)
        case noPenDevice([String])
        case sideButtonSilent
        case error(String)
    }

    static let log = Logger(subsystem: "com.twelve.daylight", category: "stylus")
    static let probeTimeout: Double = 20

    let adb: AdbRunning
    let serial: String
    let queue: DispatchQueue
    let backoffInitial: Double
    let backoffMax: Double
    let sideButtonSanitySeconds: Double

    var onTransition: ((StylusTransition) -> Void)?
    var onGesture: ((SideButtonGesture) -> Void)?
    var onStatus: ((Status) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var status: Status = .idle
    private(set) var capabilitiesListing: String?
    private(set) var penNode: EvdevCapabilities?
    private(set) var restarts = 0
    private(set) var eventsSeen: UInt64 = 0
    private(set) var sideButtonEventsSeen: UInt64 = 0

    private var gestures: SideButtonGestures
    private var parser = EvdevParser()
    private var machine = StylusContactMachine(pressureMax: EvdevCapabilitiesParser.defaultPressureMax)
    private var child: AdbProcessHandle?
    private var running = false
    private var generation = 0
    private var backoff: Double
    private var streamStartedAt: Double = 0
    private var timerToken = 0
    private var contactStartedAt: UInt64?
    private var inkingUs: UInt64 = 0
    private var sideButtonReported = false
    private var lastEventTsUs: UInt64 = 0

    init(adb: AdbRunning, serial: String, queue: DispatchQueue, gestures: SideButtonGestures, backoffInitial: Double = 0.5, backoffMax: Double = 8, sideButtonSanitySeconds: Double = 30) {
        self.adb = adb
        self.serial = serial
        self.queue = queue
        self.gestures = gestures
        self.backoffInitial = backoffInitial
        self.backoffMax = backoffMax
        self.sideButtonSanitySeconds = sideButtonSanitySeconds
        backoff = backoffInitial
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.running else { return }
            self.running = true
            self.generation += 1
            self.probe(generation: self.generation)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.running = false
            self.generation += 1
            if let child = self.child {
                if child.isRunning { child.terminate() }
                self.child = nil
            }
            self.release()
            self.setStatus(.idle)
        }
    }

    /// Replaces the gesture windows (Settings change); a press in flight is dropped.
    func updateGestures(_ gestures: SideButtonGestures) {
        queue.async { [weak self] in self?.gestures = gestures }
    }

    private func setStatus(_ new: Status) {
        guard new != status else { return }
        status = new
        onStatus?(new)
    }

    // MARK: Probe

    private func probe(generation: Int) {
        guard running, generation == self.generation else { return }
        setStatus(.probing)
        adb.run(["-s", serial, "shell", "-T", "getevent", "-pl"], timeout: StylusWatcher.probeTimeout) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                guard self.running, generation == self.generation else { return }
                switch result {
                case let .success(output):
                    let listing = output.stdoutText
                    self.capabilitiesListing = listing
                    let devices = EvdevCapabilitiesParser.parse(listing)
                    let names = devices.map { "\($0.name) (\($0.path))" }
                    self.onLog?("getevent -pl devices: \(names)")
                    guard let pen = EvdevCapabilitiesParser.penNode(devices) else {
                        self.onLog?(FailureText.logLine(.noPenDevice, ["\(names)"]))
                        self.setStatus(.noPenDevice(names))
                        return
                    }
                    self.penNode = pen
                    self.machine = StylusContactMachine(pressureMax: pen.pressureMax)
                    self.parser = EvdevParser()
                    self.setStatus(.watching(path: pen.path, name: pen.name, pressureMax: pen.pressureMax))
                    self.onLog?("pen node \(pen.path) \"\(pen.name)\" pressureMax=\(pen.pressureMax) keys=\(pen.keys.sorted()) abs=\(pen.abs.keys.sorted())")
                    if !pen.hasSideButton {
                        self.onLog?("pen node reports no BTN_STYLUS or BTN_STYLUS2; the side button gestures may never fire (row 28b)")
                    }
                    self.spawn(path: pen.path, generation: generation)
                case let .failure(error):
                    self.setStatus(.error("getevent -pl failed: \(error)"))
                    self.scheduleRestart(generation: generation)
                }
            }
        }
    }

    // MARK: Stream

    private func spawn(path: String, generation: Int) {
        guard running, generation == self.generation else { return }
        streamStartedAt = ProcessInfo.processInfo.systemUptime
        let handle = adb.spawnStreaming(["-s", serial, "shell", "-T", "getevent", "-lt", path], onStdout: { [weak self] data in
            self?.queue.async { self?.consume(data, generation: generation) }
        }, onStderr: { [weak self] data in
            self?.queue.async {
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { self?.onLog?("getevent stderr: \(text)") }
            }
        }, onExit: { [weak self] status in
            self?.queue.async { self?.streamEnded(status: status, generation: generation) }
        })
        guard let child = handle else {
            setStatus(.error("could not spawn getevent"))
            scheduleRestart(generation: generation)
            return
        }
        self.child = child
    }

    private func consume(_ data: Data, generation: Int) {
        guard running, generation == self.generation else { return }
        var transitions: [StylusTransition] = []
        data.withUnsafeBytes { raw in
            parser.feed(raw) { event in
                eventsSeen += 1
                if event.tsUs > 0 { lastEventTsUs = event.tsUs }
                transitions.append(contentsOf: machine.apply(event))
            }
        }
        for transition in transitions { handle(transition) }
    }

    private func handle(_ transition: StylusTransition) {
        switch transition {
        case let .contactDown(sample):
            contactStartedAt = sample.tsUs
        case let .contactUp(sample):
            if let start = contactStartedAt, sample.tsUs >= start {
                inkingUs &+= sample.tsUs - start
                contactStartedAt = nil
                checkSideButtonSanity()
            }
        case let .side1Down(ts), let .side2Down(ts):
            sideButtonEventsSeen += 1
            if let gesture = gestures.down(tsUs: ts) { onGesture?(gesture) }
            armLongPressTimer(eventTs: ts)
        case let .side1Up(ts), let .side2Up(ts):
            sideButtonEventsSeen += 1
            timerToken += 1
            if let gesture = gestures.up(tsUs: ts) { onGesture?(gesture) }
        default:
            break
        }
        onTransition?(transition)
    }

    /// One-shot timer at `pendingDeadline()`: the device stamps are monotonic microseconds, so the delay is the
    /// difference to the stamp of the press itself.
    private func armLongPressTimer(eventTs: UInt64) {
        timerToken += 1
        let token = timerToken
        guard let deadline = gestures.pendingDeadline() else { return }
        let delayUs = deadline > eventTs ? deadline - eventTs : 0
        queue.asyncAfter(deadline: .now() + Double(delayUs) / 1_000_000) { [weak self] in
            guard let self = self, self.running, token == self.timerToken else { return }
            if let gesture = self.gestures.timerFired(tsUs: deadline) { self.onGesture?(gesture) }
        }
    }

    private func checkSideButtonSanity() {
        guard !sideButtonReported, sideButtonEventsSeen == 0 else { return }
        if Double(inkingUs) / 1_000_000 >= sideButtonSanitySeconds {
            sideButtonReported = true
            onLog?(FailureText.logLine(.noSideButtonEvents))
            onStatus?(.sideButtonSilent)
        }
    }

    /// Opens every switch (stream ended or stopped) so the governor sees the pen lift.
    private func release() {
        timerToken += 1
        let ts = lastEventTsUs
        let transitions = machine.reset(tsUs: ts)
        for transition in transitions { onTransition?(transition) }
        contactStartedAt = nil
    }

    private func streamEnded(status: Int32, generation: Int) {
        guard running, generation == self.generation else { return }
        child = nil
        release()
        let lived = ProcessInfo.processInfo.systemUptime - streamStartedAt
        onLog?("getevent ended with status \(status) after \(String(format: "%.1f", lived)) s; restarting in \(backoff) s")
        if lived > 30 { backoff = backoffInitial }
        scheduleRestart(generation: generation)
    }

    private func scheduleRestart(generation: Int) {
        guard running, generation == self.generation else { return }
        restarts += 1
        let delay = backoff
        backoff = min(backoffMax, backoff * 2)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.running, generation == self.generation else { return }
            if let pen = self.penNode {
                self.machine = StylusContactMachine(pressureMax: pen.pressureMax)
                self.parser = EvdevParser()
                self.setStatus(.watching(path: pen.path, name: pen.name, pressureMax: pen.pressureMax))
                self.spawn(path: pen.path, generation: generation)
            } else {
                self.probe(generation: generation)
            }
        }
    }

    var diagnostics: [String: String] {
        var d: [String: String] = [:]
        switch status {
        case .idle: d["pen.status"] = "idle"
        case .probing: d["pen.status"] = "probing"
        case let .watching(path, name, pressureMax): d["pen.status"] = "watching \(path) \"\(name)\" pressureMax=\(pressureMax)"
        case let .noPenDevice(names): d["pen.status"] = "no pen node among \(names)"
        case .sideButtonSilent: d["pen.status"] = "watching, no side button events after \(Int(sideButtonSanitySeconds)) s of inking"
        case let .error(text): d["pen.status"] = "error: \(text)"
        }
        d["pen.events"] = "\(eventsSeen)"
        d["pen.sideButtonEvents"] = "\(sideButtonEventsSeen)"
        d["pen.restarts"] = "\(restarts)"
        return d
    }
}
