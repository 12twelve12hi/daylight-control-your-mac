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

    /// The bundled adb inside `Resources/Vendor/`. A folder-reference copy normally keeps the executable bit; when it
    /// does not (UNVERIFIED on a notarized bundle), the binary is copied once into Application Support and made
    /// executable there, because chmod inside the bundle would break the signature.
    static func locateExecutable(vendorDirectory: URL, fileManager: FileManager = .default) -> Result<URL, AdbError> {
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

    func spawnStreaming(_ args: [String], onStdout: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) -> AdbProcessHandle? {
        let process = makeProcess(args)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                onStdout(data)
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                onStderr(data)
            }
        }
        process.terminationHandler = { finished in
            // Give the readability handlers their final drain, then report.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                onExit(finished.terminationStatus)
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
