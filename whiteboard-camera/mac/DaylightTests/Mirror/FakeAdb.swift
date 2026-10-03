import DaylightKit
import Foundation
@testable import Daylight

/// A scripted adb (IMPLEMENTATION-PLAN section 10): canned `run` results chosen by the first responder that answers,
/// recorded calls, and fake long-running children the test feeds with transcript bytes.
final class FakeAdb: AdbRunning {
    typealias Responder = ([String]) -> AdbCommandResult?

    var serverSocket: String?
    let queue = DispatchQueue(label: "com.twelve.daylight.tests.fake-adb")
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var children: [FakeAdbProcess] = []
    private var responderList: [Responder] = []
    /// Called right after a child is spawned so the test can script its output.
    var onSpawn: (([String], FakeAdbProcess) -> Void)?
    var defaultResult = FakeAdb.ok("")
    /// When false, `spawnStreaming` returns nil (launch failure).
    var canSpawn = true

    static func ok(_ stdout: String) -> AdbCommandResult {
        return AdbCommandResult(status: 0, stdout: Data(stdout.utf8), stderr: Data())
    }

    static func fail(_ status: Int32, _ stderr: String) -> AdbCommandResult {
        return AdbCommandResult(status: status, stdout: Data(), stderr: Data(stderr.utf8))
    }

    func respond(_ responder: @escaping Responder) {
        lock.lock()
        responderList.append(responder)
        lock.unlock()
    }

    /// Answers every call whose arguments contain all the given tokens.
    func respond(containing tokens: [String], with result: AdbCommandResult) {
        respond { args in tokens.allSatisfy { args.contains($0) } ? result : nil }
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func calls(containing token: String) -> [[String]] {
        return calls.filter { $0.contains(token) }
    }

    var spawned: [FakeAdbProcess] {
        lock.lock()
        defer { lock.unlock() }
        return children
    }

    func run(_ args: [String], timeout: Double, completion: @escaping (Result<AdbCommandResult, Error>) -> Void) {
        lock.lock()
        recorded.append(args)
        let responders = responderList
        let fallback = defaultResult
        lock.unlock()
        var result = fallback
        for responder in responders.reversed() {
            if let answer = responder(args) {
                result = answer
                break
            }
        }
        queue.async { completion(.success(result)) }
    }

    func spawnStreaming(_ args: [String], onStdout: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) -> AdbProcessHandle? {
        lock.lock()
        recorded.append(args)
        let allowed = canSpawn
        lock.unlock()
        guard allowed else { return nil }
        let child = FakeAdbProcess(args: args, onStdout: onStdout, onStderr: onStderr, onExit: onExit)
        lock.lock()
        children.append(child)
        lock.unlock()
        onSpawn?(args, child)
        return child
    }
}

final class FakeAdbProcess: AdbProcessHandle {
    let args: [String]
    private let onStdout: (Data) -> Void
    private let onStderr: (Data) -> Void
    private let onExit: (Int32) -> Void
    private let lock = NSLock()
    private var running = true
    private(set) var terminateCalls = 0

    init(args: [String], onStdout: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) {
        self.args = args
        self.onStdout = onStdout
        self.onStderr = onStderr
        self.onExit = onExit
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var wasTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminateCalls > 0
    }

    func emitStdout(_ text: String) {
        guard isRunning else { return }
        onStdout(Data(text.utf8))
    }

    func emitStderr(_ text: String) {
        guard isRunning else { return }
        onStderr(Data(text.utf8))
    }

    func exit(_ status: Int32) {
        lock.lock()
        let was = running
        running = false
        lock.unlock()
        if was { onExit(status) }
    }

    /// Like a real child: terminate ends it and the exit callback fires.
    func terminate() {
        lock.lock()
        terminateCalls += 1
        lock.unlock()
        exit(15)
    }
}

/// Records every governor event the mirror component posts.
final class FakePipelineControl: PipelineControl {
    private let lock = NSLock()
    private var events: [GovernorEvent] = []
    var onPost: ((GovernorEvent) -> Void)?
    var onStateForClients: ((StateReport) -> Void)?

    func post(_ event: GovernorEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
        onPost?(event)
    }

    var posted: [GovernorEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var governorSnapshot: GovernorOutput { return GovernorOutput() }
    func setViewerCount(_ n: Int) {}
    func setPreviewVisible(_ visible: Bool) {}
    func setSinkConnected(_ connected: Bool) {}
}

/// The `getevent -pl` listing of a Wacom tablet plus a finger touchscreen, in the getevent.c shape.
enum StylusFixtures {
    static let listingWithPen = """
    add device 1: /dev/input/event3
      name:     "Wacom I2C Digitizer"
      events:
        KEY (0001): BTN_TOOL_PEN          BTN_TOOL_RUBBER       BTN_TOUCH             BTN_STYLUS
                    BTN_STYLUS2
        ABS (0003): ABS_X                 : value 0, min 0, max 21600, fuzz 0, flat 0, resolution 100
                    ABS_Y                 : value 0, min 0, max 16200, fuzz 0, flat 0, resolution 100
                    ABS_PRESSURE          : value 0, min 0, max 4095, fuzz 0, flat 0, resolution 0
      input props:
        INPUT_PROP_DIRECT
    add device 2: /dev/input/event4
      name:     "fts_ts"
      events:
        KEY (0001): BTN_TOUCH             BTN_TOOL_FINGER
        ABS (0003): ABS_MT_SLOT           : value 0, min 0, max 9, fuzz 0, flat 0, resolution 0
                    ABS_MT_POSITION_X     : value 0, min 0, max 1199, fuzz 0, flat 0, resolution 0
                    ABS_MT_POSITION_Y     : value 0, min 0, max 1599, fuzz 0, flat 0, resolution 0
                    ABS_PRESSURE          : value 0, min 0, max 255, fuzz 0, flat 0, resolution 0
      input props:
        INPUT_PROP_DIRECT

    """

    static let listingWithoutPen = """
    add device 1: /dev/input/event4
      name:     "fts_ts"
      events:
        KEY (0001): BTN_TOUCH             BTN_TOOL_FINGER
        ABS (0003): ABS_MT_SLOT           : value 0, min 0, max 9, fuzz 0, flat 0, resolution 0
                    ABS_PRESSURE          : value 0, min 0, max 255, fuzz 0, flat 0, resolution 0
      input props:
        INPUT_PROP_DIRECT

    """

    /// One report of `getevent -lt` lines with the given timestamp in seconds.
    static func report(_ seconds: Double, _ lines: [(String, String, String)]) -> String {
        let stamp = String(format: "[%12.6f]", seconds)
        var text = ""
        for (type, code, value) in lines {
            text += "\(stamp) \(type.padding(toLength: 12, withPad: " ", startingAt: 0)) \(code.padding(toLength: 20, withPad: " ", startingAt: 0)) \(value)\n"
        }
        text += "\(stamp) EV_SYN       SYN_REPORT           00000000\n"
        return text
    }

    static func penDown(at t: Double) -> String {
        return report(t, [("EV_KEY", "BTN_TOOL_PEN", "DOWN"), ("EV_ABS", "ABS_X", "00001234"), ("EV_ABS", "ABS_Y", "00002345"), ("EV_KEY", "BTN_TOUCH", "DOWN"), ("EV_ABS", "ABS_PRESSURE", "00000800")])
    }

    static func penMove(at t: Double) -> String {
        return report(t, [("EV_ABS", "ABS_X", "00001240"), ("EV_ABS", "ABS_PRESSURE", "00000900")])
    }

    static func penUp(at t: Double) -> String {
        return report(t, [("EV_KEY", "BTN_TOUCH", "UP"), ("EV_ABS", "ABS_PRESSURE", "00000000")])
    }

    static func penAway(at t: Double) -> String {
        return report(t, [("EV_KEY", "BTN_TOOL_PEN", "UP")])
    }

    static func sideButton(_ down: Bool, at t: Double) -> String {
        return report(t, [("EV_KEY", "BTN_STYLUS", down ? "DOWN" : "UP")])
    }
}
