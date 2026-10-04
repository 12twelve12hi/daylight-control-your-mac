import DaylightKit
import Foundation

/// What one bounded command produced: at most `maxBytes` of its combined stdout and stderr (the newest bytes when it
/// wrote more), its exit status, and whether the timeout ended it.
struct CommandResult: Equatable {
    var output: Data
    /// nil when the process never started (`launchError` says why), had to be killed, or died of a signal.
    var exitStatus: Int32?
    /// The signal that ended the process when it was not the timeout's (a crash: 11 for SIGSEGV).
    var signal: Int32?
    var timedOut: Bool
    /// The command wrote more than `maxBytes`; `output` holds the last `maxBytes`.
    var truncated: Bool
    /// Every byte the command wrote, kept or not.
    var totalBytes: Int
    var launchError: String?

    init(output: Data = Data(), exitStatus: Int32? = 0, signal: Int32? = nil, timedOut: Bool = false, truncated: Bool = false, totalBytes: Int? = nil, launchError: String? = nil) {
        self.output = output
        self.exitStatus = exitStatus
        self.signal = signal
        self.timedOut = timedOut
        self.truncated = truncated
        self.totalBytes = totalBytes ?? output.count
        self.launchError = launchError
    }

    var text: String { return String(decoding: output, as: UTF8.self) }
}

/// Runs an external command for the diagnostics export (`log show`, `systemextensionsctl list`, `adb version`, the
/// app's own `--self-test`). Blocking: call it on the export queue, never on main. Tests pass a fake.
protocol CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: Double, maxBytes: Int) -> CommandResult
}

/// `Process` with a `DispatchWorkItem` that terminates it at the timeout (and kills it 3 s later if it ignored
/// SIGTERM). Output is drained on a utility thread so a chatty command never blocks on a full pipe; only the newest
/// `maxBytes` are kept in memory.
final class ProcessCommandRunner: CommandRunning {
    static let killGrace: Double = 3

    func run(_ executable: String, _ arguments: [String], timeout: Double, maxBytes: Int) -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return CommandResult(exitStatus: nil, launchError: "\(executable) is not executable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = Locked<TailBuffer>(TailBuffer(limit: maxBytes))
        let reading = DispatchGroup()
        reading.enter()
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                collected.withLock { $0.append(chunk) }
            }
            reading.leave()
        }
        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForWriting.close()
            _ = reading.wait(timeout: .now() + 1)
            return CommandResult(exitStatus: nil, launchError: "\(error.localizedDescription)")
        }
        let timedOut = Locked(false)
        let terminate = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        let pid = process.processIdentifier
        let forceKill = DispatchWorkItem {
            guard process.isRunning else { return }
            _ = Darwin.kill(pid, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: terminate)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + ProcessCommandRunner.killGrace, execute: forceKill)
        process.waitUntilExit()
        terminate.cancel()
        forceKill.cancel()
        // A grandchild could hold the pipe open; take what arrived and move on.
        _ = reading.wait(timeout: .now() + 2)
        let buffer = collected.withLock { $0 }
        let didTimeOut = timedOut.withLock { $0 }
        // terminationStatus is the signal number when the reason is uncaughtSignal (finder DX-2).
        let crashed = !didTimeOut && process.terminationReason == .uncaughtSignal
        let status: Int32? = (didTimeOut || crashed) ? nil : process.terminationStatus
        let signal: Int32? = crashed ? process.terminationStatus : nil
        return CommandResult(
            output: buffer.data, exitStatus: status, signal: signal, timedOut: didTimeOut,
            truncated: buffer.total > buffer.data.count, totalBytes: buffer.total, launchError: nil)
    }
}

/// Keeps the newest `limit` bytes of a stream in whole chunks, trimmed once at the end.
struct TailBuffer {
    let limit: Int
    private var chunks: [Data] = []
    private var kept = 0
    private(set) var total = 0

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    mutating func append(_ chunk: Data) {
        total += chunk.count
        chunks.append(chunk)
        kept += chunk.count
        while let first = chunks.first, kept - first.count >= limit {
            kept -= first.count
            chunks.removeFirst()
        }
    }

    var data: Data {
        var out = Data()
        out.reserveCapacity(kept)
        for chunk in chunks { out.append(chunk) }
        if out.count > limit { out = Data(out.suffix(limit)) }
        return out
    }
}
