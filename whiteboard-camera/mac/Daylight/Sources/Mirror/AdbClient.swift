import DaylightKit
import Foundation
import os

/// What one finished adb command produced.
struct AdbCommandResult {
    var status: Int32
    var stdout: Data
    var stderr: Data

    var succeeded: Bool { return status == 0 }
    var stdoutText: String { return String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { return String(decoding: stderr, as: UTF8.self) }
    /// stderr first, then stdout: adb prints its own errors on stderr and install errors on stdout.
    var errorSummary: String {
        let err = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        return stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AdbError: Error, Equatable {
    case executableMissing(String)
    case launchFailed(String)
    case timeout(command: String)
    case failed(status: Int32, detail: String, command: String)
    case noDevice
    case deviceNotReady(serial: String, state: String)
}

/// The handle of a long-running adb child (`shell getevent -lt`, the scrcpy server shell). `Process` conforms directly;
/// `FakeAdb` hands out fake handles in tests.
protocol AdbProcessHandle: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

extension Process: AdbProcessHandle {}

/// Everything mirror mode needs from adb, so `FakeAdb` can replay canned transcripts (IMPLEMENTATION-PLAN 9 step 3).
protocol AdbRunning: AnyObject {
    /// `tcp:localhost:<port>` in private-port mode (ADB_SERVER_SOCKET in the child environment), nil for the default 5037.
    var serverSocket: String? { get set }
    /// Runs `adb <args>` to completion; `timeout` seconds then terminate.
    func run(_ args: [String], timeout: Double, completion: @escaping (Result<AdbCommandResult, Error>) -> Void)
    /// Spawns `adb <args>` and streams its output; nil when the process could not be launched.
    func spawnStreaming(_ args: [String], onStdout: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) -> AdbProcessHandle?
}

/// The bundled platform-tools adb as a Foundation `Process` (ARCHITECTURE 2.3). Every call runs on `queue` (adb.queue,
/// utility QoS); completions are delivered on that queue too.
final class AdbClient: AdbRunning {
    static let vendorExecutableName = "adb"
    static let scrcpyServerName = "scrcpy-server-v4.1"
    static let log = Logger(subsystem: "com.twelve.daylight", category: "adb")

    let executable: URL
    let queue: DispatchQueue
    private let lock = NSLock()
    private var socket: String?

    var serverSocket: String? {
        get { lock.lock(); defer { lock.unlock() }; return socket }
        set { lock.lock(); socket = newValue; lock.unlock() }
    }

    init(executable: URL, serverSocket: String? = nil, queue: DispatchQueue) {
        self.executable = executable
        self.socket = serverSocket
        self.queue = queue
    }

    /// The seam every mirror path goes through (`MirrorController.ensureAdb`). Since LOOSE_ENDS H1 it resolves the adb
    /// source chosen in Settings > Mirror (read from the persisted settings, so no caller changes) and records the result
    /// for Diagnostics; Bundled is the original behaviour below, bit for bit.
    static func locateExecutable(vendorDirectory: URL, fileManager: FileManager = .default) -> Result<URL, AdbError> {
        let settings = SettingsStore.load(from: .standard)?.validated() ?? Settings.defaults
        let request = AdbSourceRequest(settings: settings, vendorDirectory: vendorDirectory)
        return locateExecutable(request, fileManager: fileManager).map { $0.url }.mapError { $0.adbError }
    }

    /// Resolves one adb source to an executable, its source and version (LOOSE_ENDS H1 (2) to (5)). Never downloads:
    /// Download on first use is started from Settings after the terms are accepted (`AdbDownloader.ensure`).
    /// `recordStatus` false is the Settings preview: it does not change what Diagnostics reports as active (it can still
    /// delete a downloaded copy whose checksum no longer matches, as any resolution does).
    static func locateExecutable(_ request: AdbSourceRequest, fileManager: FileManager = .default, recordStatus: Bool = true) -> Result<AdbLocation, AdbSourceError> {
        let source = request.source.effective(bundledAvailable: request.bundledAvailable)
        let result: Result<AdbLocation, AdbSourceError>
        switch source {
        case .bundled:
            result = locateBundled(vendorDirectory: request.vendorDirectory, fileManager: fileManager)
                .map { AdbLocation(url: $0, source: .bundled, version: "platform-tools \(AdbPins.platformToolsVersion) (bundled)") }
                .mapError { error -> AdbSourceError in
                    if case let .executableMissing(path) = error { return .bundledMissing(path: path) }
                    if case let .launchFailed(detail) = error { return .bundledNotExecutable(detail: detail) }
                    return .bundledNotExecutable(detail: "\(error)")
                }
        case .download:
            if request.termsAcceptedVersion != request.downloader.pins.version {
                result = .failure(.termsNotAccepted(version: request.downloader.pins.version))
            } else {
                result = request.downloader.locateInstalled()
            }
        case .installed:
            result = AdbInstalledProbe.locate(environment: request.environment, home: request.home, homebrew: request.homebrew, fileManager: fileManager, versionOutput: request.versionOutput)
        }
        if recordStatus { AdbSourceStatus.record(result, requested: request.source) }
        switch result {
        case let .success(location):
            let line = "adb source \(location.source.rawValue): \(location.url.path) \(location.version ?? "")"
            log.notice("\(line, privacy: .public)")
        case let .failure(error):
            let line = "adb source \(source.rawValue): \(error.logLine)"
            log.error("\(line, privacy: .public)")
        }
        return result
    }

    /// The bundled adb inside `Resources/Vendor/`. A folder-reference copy normally keeps the executable bit; when it
    /// does not (UNVERIFIED on a notarized bundle), the binary is copied once into Application Support and made
    /// executable there, because chmod inside the bundle would break the signature.
    static func locateBundled(vendorDirectory: URL, fileManager: FileManager = .default) -> Result<URL, AdbError> {
        let bundled = vendorDirectory.appendingPathComponent(vendorExecutableName)
        guard fileManager.fileExists(atPath: bundled.path) else {
            return .failure(.executableMissing(bundled.path))
        }
        if fileManager.isExecutableFile(atPath: bundled.path) { return .success(bundled) }
        do {
            let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent(Settings.applicationSupportFolderName, isDirectory: true)
            try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
            let copy = support.appendingPathComponent(vendorExecutableName)
            if fileManager.fileExists(atPath: copy.path) { try fileManager.removeItem(at: copy) }
            try fileManager.copyItem(at: bundled, to: copy)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
            log.notice("bundled adb was not executable; using a copy at \(copy.path, privacy: .public)")
            return .success(copy)
        } catch {
            return .failure(.launchFailed("adb at \(bundled.path) is not executable and could not be copied: \(error)"))
        }
    }

    /// The port of a `tcp:localhost:<port>` server socket string; 5037 for nil or anything else.
    static func serverPort(fromServerSocket socket: String?) -> UInt16 {
        guard let socket = socket, let colon = socket.lastIndex(of: ":"), let port = UInt16(socket[socket.index(after: colon)...]) else {
            return AdbHostProtocol.defaultPort
        }
        return port
    }

    private func makeProcess(_ args: [String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        if let socket = serverSocket {
            environment["ADB_SERVER_SOCKET"] = socket
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        return process
    }

    func run(_ args: [String], timeout: Double, completion: @escaping (Result<AdbCommandResult, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let process = self.makeProcess(args)
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let command = ([self.executable.lastPathComponent] + args).joined(separator: " ")
            let state = Locked<(stdout: Data, stderr: Data, finished: Bool, timedOut: Bool)>((Data(), Data(), false, false))
            let group = DispatchGroup()
            group.enter()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                state.withLock { $0.stdout = data }
                group.leave()
            }
            DispatchQueue.global(qos: .utility).async {
                let data = err.fileHandleForReading.readDataToEndOfFile()
                state.withLock { $0.stderr = data }
                group.leave()
            }
            group.enter()
            process.terminationHandler = { _ in group.leave() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                group.leave()
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                completion(.failure(AdbError.launchFailed("\(command): \(error)")))
                return
            }
            let watchdog = DispatchWorkItem {
                if process.isRunning {
                    state.withLock { $0.timedOut = true }
                    process.terminate()
                }
            }
            self.queue.asyncAfter(deadline: .now() + timeout, execute: watchdog)
            group.notify(queue: self.queue) {
                watchdog.cancel()
                let s = state.withLock { $0 }
                if s.timedOut {
                    AdbClient.log.notice("timeout after \(timeout, privacy: .public) s: \(command, privacy: .public)")
                    completion(.failure(AdbError.timeout(command: command)))
                    return
                }
                completion(.success(AdbCommandResult(status: process.terminationStatus, stdout: s.stdout, stderr: s.stderr)))
            }
        }
    }

    /// How long `spawnStreaming` waits after the exit for both pipes to reach end of file before it reports the exit.
    static let exitDrainCap: Double = 1

    /// `onExit` comes after stdout and stderr reached end of file and the process exited (at most `exitDrainCap` after
    /// the exit), so the last stderr line, the server's error, is delivered before the exit.
    func spawnStreaming(_ args: [String], onStdout: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) -> AdbProcessHandle? {
        let process = makeProcess(args)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let drain = ExitDrain()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                drain.arrive(.stdoutEnd)
            } else {
                onStdout(data)
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                drain.arrive(.stderrEnd)
            } else {
                onStderr(data)
            }
        }
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            drain.arrive(.exit)
            // Report once both pipes reached end of file, so every byte the child wrote was delivered first; capped,
            // because a grandchild that inherited a pipe can hold it open forever.
            DispatchQueue.global(qos: .utility).async {
                if !drain.wait(timeout: AdbClient.exitDrainCap) {
                    AdbClient.log.notice("adb child exited but a pipe stayed open \(AdbClient.exitDrainCap, privacy: .public) s; reporting the exit")
                }
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                onExit(status)
            }
        }
        do {
            try process.run()
        } catch {
            AdbClient.log.error("could not spawn adb \(args.joined(separator: " "), privacy: .public): \(String(describing: error), privacy: .public)")
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        return process
    }
}

/// The three events `spawnStreaming` waits for before `onExit`: stdout EOF, stderr EOF and the exit, each counted once.
/// A semaphore rather than a DispatchGroup, because a group released with an unbalanced enter (a pipe that never
/// closes) traps.
private final class ExitDrain {
    enum Event: Hashable { case stdoutEnd, stderrEnd, exit }

    private let seen = Locked<Set<Event>>([])
    private let done = DispatchSemaphore(value: 0)

    func arrive(_ event: Event) {
        let complete = seen.withLock { s -> Bool in
            guard s.insert(event).inserted else { return false }
            return s.count == 3
        }
        if complete { done.signal() }
    }

    /// True when all three arrived within `timeout` seconds.
    func wait(timeout: Double) -> Bool {
        return done.wait(timeout: .now() + timeout) == .success
    }
}

/// Splits streamed bytes into lines (for the scrcpy server log and the adb stderr).
struct LineSplitter {
    private var pending = Data()

    mutating func feed(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending.subdata(in: pending.startIndex..<newline)
            if line.last == 0x0D { line.removeLast() }
            lines.append(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    /// Whatever is left without a newline (called at exit).
    mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return line
    }
}
