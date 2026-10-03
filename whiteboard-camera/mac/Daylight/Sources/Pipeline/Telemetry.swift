import DaylightKit
import Foundation
import os

/// Signposts for the hot paths (SPEC section 15: `capture`, `composite`, `ink.apply`, `sink.push`, `decode`) and the
/// `--perf-log` line printed once per second. Nothing here asserts a wall time.
final class Telemetry {
    static let subsystem = "com.twelve.daylight"

    let signposter = OSSignposter(subsystem: Telemetry.subsystem, category: "perf")
    let log = Logger(subsystem: Telemetry.subsystem, category: "perf")
    var perfLog: Bool
    /// Where the perf line goes (stdout by default; tests capture it).
    var sink: ((String) -> Void)?

    private let ring = Locked<[String]>([])

    init(perfLog: Bool = false) {
        self.perfLog = perfLog
    }

    func begin(_ name: StaticString) -> OSSignpostIntervalState {
        return signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    func end(_ state: OSSignpostIntervalState, _ name: StaticString) {
        signposter.endInterval(name, state)
    }

    /// One line per second: `perf mode=<m> fps=<n> dropped=<n> cpu_ms=<x> gpu_ms=<x> inflight=<n> zerocopy=<bool> capture=<running|idle>`.
    static func perfLine(_ s: PipelineStats) -> String {
        let capture = s.capturing ? "running" : "idle"
        return String(
            format: "perf mode=%@ fps=%.1f dropped=%llu cpu_ms=%.3f gpu_ms=%.3f inflight=%ld zerocopy=%@ capture=%@ viewers=%ld",
            s.mode, s.fps, s.dropped, s.cpuMsPerFrame, s.gpuMsPerFrame, s.inFlight, s.passthroughZeroCopy ? "true" : "false", capture, s.viewers)
    }

    func emit(_ s: PipelineStats) {
        guard perfLog else { return }
        let line = Telemetry.perfLine(s)
        if let sink = sink { sink(line) } else { print(line) }
        remember(line)
    }

    /// The last 200 lines this process logged through `Telemetry.note` (Diagnostics shows them).
    func remember(_ line: String) {
        ring.withLock { lines in
            lines.append(line)
            if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        }
    }

    var recentLines: [String] {
        return ring.withLock { $0 }
    }

    /// Log through the unified log and remember the line for Diagnostics.
    func note(_ category: String, _ message: String) {
        Logger(subsystem: Telemetry.subsystem, category: category).notice("\(message, privacy: .public)")
        remember("[\(category)] \(message)")
    }
}

struct PipelineStats {
    var mode: String = "passthrough"
    var fps: Double = 0
    var cpuMsPerFrame: Double = 0
    var gpuMsPerFrame: Double = 0
    var dropped: UInt64 = 0
    var inFlight: Int = 0
    var passthroughZeroCopy: Bool = true
    var capturing: Bool = false
    var captureIdleReason: String? = nil
    var viewers: Int = 0
    var pushed: UInt64 = 0
    var firstFrame: String? = nil
    var cameraAttached: Bool = false
    var sinkConnected: Bool = false
}
