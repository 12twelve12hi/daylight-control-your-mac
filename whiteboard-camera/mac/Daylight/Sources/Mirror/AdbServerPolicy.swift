import DaylightKit
import Foundation
import Network
import os

/// Which adb server the bundled client talks to (ARCHITECTURE 6 item 1, SPEC F5): probe `127.0.0.1:5037` with
/// `000chost:version`; nobody answers -> the default socket (our client spawns its own server on 5037); the same
/// protocol version as ours -> shared; a different one -> our own server on a private port through `ADB_SERVER_SOCKET`
/// plus failure row 24. Never `kill-server`.
enum AdbServerPolicy {
    enum Decision: Equatable {
        case shared5037
        case privatePort(UInt16)
        case conflict(theirVersion: Int, ours: Int, privatePort: UInt16)

        /// The `ADB_SERVER_SOCKET` value for the bundled client; nil means the default 5037.
        var serverSocket: String? {
            switch self {
            case .shared5037: return nil
            case let .privatePort(port): return "tcp:localhost:\(port)"
            case let .conflict(_, _, port): return "tcp:localhost:\(port)"
            }
        }

        var isConflict: Bool {
            if case .conflict = self { return true }
            return false
        }

        var diagnosticsText: String {
            switch self {
            case .shared5037: return "shared 5037"
            case let .privatePort(port): return "private tcp:localhost:\(port)"
            case let .conflict(theirs, ours, port): return "private tcp:localhost:\(port) (another adb on 5037 speaks version \(theirs), ours is \(ours))"
            }
        }
    }

    /// Answers the protocol version of a server on 5037, or nil when nothing answers within the timeout.
    typealias Probe = (_ completion: @escaping (Int?) -> Void) -> Void

    static let probeTimeout: Double = 1.0
    static let log = Logger(subsystem: "com.twelve.daylight", category: "adb")

    static func decide(bundled: AdbRunning, mode: AdbServerMode, privatePort: UInt16, probe: Probe? = nil, completion: @escaping (Decision) -> Void) {
        switch mode {
        case .shared:
            completion(.shared5037)
        case .privatePort:
            completion(.privatePort(privatePort))
        case .auto:
            let runProbe: Probe = probe ?? { done in probeDefaultServer(queue: DispatchQueue(label: "com.twelve.daylight.adb.probe"), completion: done) }
            runProbe { theirs in
                guard let theirs = theirs else {
                    completion(.shared5037)
                    return
                }
                bundled.run(["version"], timeout: 10) { result in
                    switch result {
                    case let .success(output):
                        guard let ours = AdbDevicesParser.parseHostVersion(output.stdoutText) else {
                            log.notice("could not read the bundled adb version; sharing 5037")
                            completion(.shared5037)
                            return
                        }
                        if ours == theirs {
                            completion(.shared5037)
                        } else {
                            log.notice("\(FailureText.logLine(.adbVersionClash, ["\(theirs)", "\(ours)"]), privacy: .public)")
                            completion(.conflict(theirVersion: theirs, ours: ours, privatePort: privatePort))
                        }
                    case .failure:
                        log.notice("bundled adb version check failed; sharing 5037")
                        completion(.shared5037)
                    }
                }
            }
        }
    }

    /// Raw TCP probe of the default server (research-scrcpy-adb 3.1): `000chost:version` -> `OKAY` + hex4 + hex version.
    static func probeDefaultServer(port: UInt16 = AdbHostProtocol.defaultPort, queue: DispatchQueue, timeout: Double = probeTimeout, completion: @escaping (Int?) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(nil)
            return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 1
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: nwPort, using: parameters)
        let done = Locked(false)
        var parser = AdbHostProtocol.ReplyParser()
        func finish(_ version: Int?) {
            let first = done.withLock { was -> Bool in
                if was { return false }
                was = true
                return true
            }
            guard first else { return }
            connection.cancel()
            completion(version)
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, isComplete, error in
                if let data = data, !data.isEmpty {
                    var version: Int?
                    var failed = false
                    parser.feed(Array(data)) { reply in
                        switch reply {
                        case .okay: break
                        case let .payload(text): version = AdbDevicesParser.parseHostVersion(text)
                        case .fail: failed = true
                        }
                    }
                    if let version = version { finish(version); return }
                    if failed { finish(nil); return }
                }
                if isComplete || error != nil {
                    finish(nil)
                } else {
                    receive()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(AdbHostProtocol.encodeRequest(AdbHostProtocol.hostVersion)), completion: .contentProcessed { error in
                    if error != nil { finish(nil); return }
                    receive()
                })
            case .failed, .cancelled:
                finish(nil)
            case .waiting:
                // Connection refused: no server on 5037.
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }
}
