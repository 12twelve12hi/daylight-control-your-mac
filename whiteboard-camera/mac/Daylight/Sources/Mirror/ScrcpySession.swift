import DaylightKit
import Foundation
import Network
import os

enum ScrcpySessionError: Error {
    case pushFailed(String)
    case forwardFailed(String)
    /// The `adb shell app_process` child ended before the video socket came up; `firstError` is the first `[server] ERROR:` line.
    case serverExited(status: Int32, firstError: String?)
    /// The dummy byte never arrived within the retry budget.
    case dummyByteTimeout(attempts: Int)
    case connectionFailed(String)
    case stream(ScrcpyError)
    case socketClosed

    /// Owner-facing detail for failure row 25 (`FailureText.sentence(.scrcpyServerFailed, [detail])`).
    var detail: String {
        switch self {
        case let .pushFailed(text): return "adb push failed: \(text)"
        case let .forwardFailed(text): return "adb forward failed: \(text)"
        case let .serverExited(status, firstError): return firstError ?? "server exited with status \(status)"
        case let .dummyByteTimeout(attempts): return "no answer from the server after \(attempts) attempts"
        case let .connectionFailed(text): return "connection failed: \(text)"
        case let .stream(error): return "stream error: \(error)"
        case .socketClosed: return "the video socket closed"
        }
    }
}

/// One scrcpy-server run (ARCHITECTURE 6 item 3, SPEC F2): push, forward (27183...27199), the exact 4.1 shell line,
/// the dummy byte with 100 x 100 ms retries, `forward --remove` once connected, the demuxed packets, `terminate()` on
/// stop. Everything runs on `queue` (mirror.queue).
final class ScrcpySession {
    struct Config: Equatable {
        var serial: String
        var maxSize = 1600
        var bitRate = 8_000_000
        var maxFps = 30
        var localPort: UInt16 = ScrcpyLaunch.defaultLocalPort

        init(serial: String, maxSize: Int = 1600, bitRate: Int = 8_000_000, maxFps: Int = 30, localPort: UInt16 = ScrcpyLaunch.defaultLocalPort) {
            self.serial = serial
            self.maxSize = maxSize
            self.bitRate = bitRate
            self.maxFps = maxFps
            self.localPort = localPort
        }

        init(serial: String, settings: Settings) {
            self.init(serial: serial, maxSize: settings.mirrorMaxSize, bitRate: settings.mirrorBitRate, maxFps: settings.mirrorMaxFps)
        }
    }

    static let log = Logger(subsystem: "com.twelve.daylight", category: "scrcpy")
    /// How many consecutive forward ports are tried after `localPort`.
    static let forwardPortAttempts = 16

    let adb: AdbRunning
    let server: URL
    let config: Config
    let queue: DispatchQueue
    let dummyByteAttempts: Int
    let dummyByteRetryInterval: Double

    var onPacket: ((ScrcpyPacket) -> Void)?
    var onServerLog: ((String) -> Void)?
    /// An unexpected end (never called after `stop()`).
    var onExit: ((Error?) -> Void)?
    var onConnected: (() -> Void)?

    private(set) var boundPort: UInt16 = 0
    private(set) var dummyByteAttemptsUsed = 0
    private(set) var isConnected = false
    private(set) var isRunning = false
    private(set) var deviceName: String?
    private(set) var firstServerError: String?
    private var stopped = false
    private var forwardActive = false
    private var child: AdbProcessHandle?
    private var connection: NWConnection?
    private var demuxer = ScrcpyDemuxer(expectsDummyByte: false)
    private var stdoutLines = LineSplitter()
    private var stderrLines = LineSplitter()
    private(set) var bytesReceived: UInt64 = 0
    private(set) var packetsReceived: UInt64 = 0

    init(adb: AdbRunning, server: URL, config: Config, queue: DispatchQueue, dummyByteAttempts: Int = ScrcpyLaunch.dummyByteAttempts, dummyByteRetryInterval: Double = ScrcpyLaunch.dummyByteRetryInterval) {
        self.adb = adb
        self.server = server
        self.config = config
        self.queue = queue
        self.dummyByteAttempts = dummyByteAttempts
        self.dummyByteRetryInterval = dummyByteRetryInterval
    }

    var launch: ScrcpyLaunch {
        return ScrcpyLaunch(serial: config.serial, maxSize: config.maxSize, bitRate: config.bitRate, maxFps: config.maxFps, localPort: boundPort == 0 ? config.localPort : boundPort)
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.isRunning, !self.stopped else { return }
            self.isRunning = true
            self.push()
        }
    }

    /// Captures `self` strongly on purpose: the controller drops its reference right after calling `stop()`, and the
    /// child must still be terminated.
    func stop() {
        queue.async {
            self.stopped = true
            self.isRunning = false
            self.connection?.cancel()
            self.connection = nil
            if let child = self.child {
                if child.isRunning { child.terminate() }
                self.child = nil
            }
            self.removeForwardIfNeeded()
        }
    }

    // MARK: Steps

    private func push() {
        let args = launch.pushArguments(serverPath: server.path)
        adb.run(args, timeout: 60) { [weak self] result in
            guard let self = self, !self.stopped else { return }
            switch result {
            case let .success(output) where output.succeeded:
                self.forward(portIndex: 0)
            case let .success(output):
                self.finish(.pushFailed(output.errorSummary))
            case let .failure(error):
                self.finish(.pushFailed("\(error)"))
            }
        }
    }

    private func forward(portIndex: Int) {
        // 27183 then 27184...27199 with the default port (ARCHITECTURE 6 item 3); the same 16 tries from any other base.
        let candidate = Int(config.localPort) + portIndex
        guard portIndex <= ScrcpySession.forwardPortAttempts, let port = UInt16(exactly: candidate) else {
            finish(.forwardFailed("no free local port between \(config.localPort) and \(Int(config.localPort) + ScrcpySession.forwardPortAttempts)"))
            return
        }
        let probe = ScrcpyLaunch(serial: config.serial, maxSize: config.maxSize, bitRate: config.bitRate, maxFps: config.maxFps, localPort: port)
        adb.run(probe.forwardArguments, timeout: 15) { [weak self] result in
            guard let self = self, !self.stopped else { return }
            switch result {
            case let .success(output) where output.succeeded:
                self.boundPort = port
                self.forwardActive = true
                self.spawnServer()
            case let .success(output):
                ScrcpySession.log.notice("forward tcp:\(port) failed: \(output.errorSummary, privacy: .public)")
                self.forward(portIndex: portIndex + 1)
            case let .failure(error):
                self.finish(.forwardFailed("\(error)"))
            }
        }
    }

    private func spawnServer() {
        let args = launch.shellArguments
        onServerLog?("launch: adb \(args.joined(separator: " "))")
        let handle = adb.spawnStreaming(args, onStdout: { [weak self] data in
            self?.queue.async { self?.serverOutput(data, stderr: false) }
        }, onStderr: { [weak self] data in
            self?.queue.async { self?.serverOutput(data, stderr: true) }
        }, onExit: { [weak self] status in
            self?.queue.async { self?.serverExited(status: status) }
        })
        guard let child = handle else {
            finish(.serverExited(status: -1, firstError: "could not launch adb shell"))
            return
        }
        self.child = child
        connect(attempt: 1)
    }

    private func serverOutput(_ data: Data, stderr: Bool) {
        let lines = stderr ? stderrLines.feed(data) : stdoutLines.feed(data)
        for line in lines where !line.isEmpty {
            if firstServerError == nil, line.hasPrefix(ScrcpyLaunch.serverErrorPrefix) {
                firstServerError = line
            }
            onServerLog?(line)
        }
    }

    private func serverExited(status: Int32) {
        if let rest = stdoutLines.flush() { serverOutput(Data((rest + "\n").utf8), stderr: false) }
        if let rest = stderrLines.flush() { serverOutput(Data((rest + "\n").utf8), stderr: true) }
        guard !stopped else { return }
        child = nil
        if isConnected {
            finish(firstServerError != nil ? .serverExited(status: status, firstError: firstServerError) : .socketClosed)
        } else {
            finish(.serverExited(status: status, firstError: firstServerError))
        }
    }

    // MARK: Video socket

    private func connect(attempt: Int) {
        guard !stopped, child != nil else { return }
        guard attempt <= dummyByteAttempts else {
            finish(.dummyByteTimeout(attempts: dummyByteAttempts))
            return
        }
        dummyByteAttemptsUsed = attempt
        guard let port = NWEndpoint.Port(rawValue: boundPort) else {
            finish(.connectionFailed("bad port \(boundPort)"))
            return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 2
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let current = connection, current === self.connection, !self.stopped else { return }
            switch state {
            case .ready:
                self.readDummyByte(connection: current, attempt: attempt)
            case .failed, .waiting:
                self.retry(after: current, attempt: attempt)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func readDummyByte(connection: NWConnection, attempt: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, isComplete, error in
            guard let self = self, connection === self.connection, !self.stopped else { return }
            if let data = data, let first = data.first {
                if first == 0 {
                    self.connected(connection: connection)
                } else {
                    // Not a scrcpy socket; treat as a failed attempt.
                    self.retry(after: connection, attempt: attempt)
                }
                return
            }
            _ = isComplete
            _ = error
            // adb accepts the local connection before the server listens and then closes it: retry.
            self.retry(after: connection, attempt: attempt)
        }
    }

    private func retry(after connection: NWConnection, attempt: Int) {
        guard connection === self.connection else { return }
        connection.cancel()
        self.connection = nil
        queue.asyncAfter(deadline: .now() + dummyByteRetryInterval) { [weak self] in
            self?.connect(attempt: attempt + 1)
        }
    }

    private func connected(connection: NWConnection) {
        isConnected = true
        ScrcpySession.log.notice("video socket up on 127.0.0.1:\(self.boundPort) after \(self.dummyByteAttemptsUsed) attempt(s)")
        removeForwardIfNeeded()
        onConnected?()
        receiveLoop(connection: connection)
    }

    private func receiveLoop(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, connection === self.connection, !self.stopped else { return }
            if let data = data, !data.isEmpty {
                self.bytesReceived += UInt64(data.count)
                do {
                    try data.withUnsafeBytes { raw in
                        try self.demuxer.feed(raw) { packet in
                            self.packetsReceived += 1
                            if case let .deviceMeta(name) = packet { self.deviceName = name }
                            self.onPacket?(packet)
                        }
                    }
                } catch let error as ScrcpyError {
                    self.finish(.stream(error))
                    return
                } catch {
                    self.finish(.connectionFailed("\(error)"))
                    return
                }
            }
            if let error = error {
                self.finish(.connectionFailed("\(error)"))
            } else if isComplete {
                self.finish(.socketClosed)
            } else {
                self.receiveLoop(connection: connection)
            }
        }
    }

    // MARK: End

    private func removeForwardIfNeeded() {
        guard forwardActive else { return }
        forwardActive = false
        adb.run(launch.forwardRemoveArguments, timeout: 10) { result in
            if case let .success(output) = result, !output.succeeded {
                ScrcpySession.log.notice("forward --remove: \(output.errorSummary, privacy: .public)")
            }
        }
    }

    private func finish(_ error: ScrcpySessionError) {
        guard !stopped else { return }
        stopped = true
        isRunning = false
        connection?.cancel()
        connection = nil
        if let child = child {
            if child.isRunning { child.terminate() }
            self.child = nil
        }
        removeForwardIfNeeded()
        ScrcpySession.log.notice("session ended: \(error.detail, privacy: .public)")
        onExit?(error)
    }
}
