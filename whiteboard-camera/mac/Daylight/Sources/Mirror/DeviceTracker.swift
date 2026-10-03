import DaylightKit
import Foundation
import Network
import os

/// Watches the adb device list (ARCHITECTURE 6 item 2): `host:track-devices` on a raw TCP socket to the chosen server,
/// parsed by `AdbDevicesParser`; when the socket cannot be opened, `adb devices -l` every 2 s. The first `devices -l`
/// run also spawns the server when none is running.
final class DeviceTracker {
    static let log = Logger(subsystem: "com.twelve.daylight", category: "adb")

    let adb: AdbRunning
    let queue: DispatchQueue
    let pollInterval: Double
    let useTrackSocket: Bool
    var onDevices: (([AdbDevice]) -> Void)?
    var onLog: ((String) -> Void)?

    private let state = Locked<(devices: [AdbDevice], running: Bool, generation: Int, tracking: Bool)>(([], false, 0, false))
    private var connection: NWConnection?

    init(adb: AdbRunning, queue: DispatchQueue, pollInterval: Double = 2, useTrackSocket: Bool = true) {
        self.adb = adb
        self.queue = queue
        self.pollInterval = pollInterval
        self.useTrackSocket = useTrackSocket
    }

    var devices: [AdbDevice] { return state.withLock { $0.devices } }
    var isRunning: Bool { return state.withLock { $0.running } }
    /// True while the `host:track-devices` socket delivers lists (false while polling).
    var isTracking: Bool { return state.withLock { $0.tracking } }

    func start() {
        let generation: Int = state.withLock { s in
            if s.running { return -1 }
            s.running = true
            s.generation += 1
            return s.generation
        }
        guard generation >= 0 else { return }
        queue.async { [weak self] in self?.poll(generation: generation, thenTrack: self?.useTrackSocket ?? false) }
    }

    func stop() {
        state.withLock { s in
            s.running = false
            s.tracking = false
            s.generation += 1
        }
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        return state.withLock { $0.running && $0.generation == generation }
    }

    private func publish(_ list: [AdbDevice]) {
        let changed: Bool = state.withLock { s in
            if s.devices == list { return false }
            s.devices = list
            return true
        }
        if changed { onDevices?(list) }
    }

    // MARK: Polling

    private func poll(generation: Int, thenTrack: Bool) {
        guard isCurrent(generation) else { return }
        adb.run(["devices", "-l"], timeout: 15) { [weak self] result in
            guard let self = self, self.isCurrent(generation) else { return }
            switch result {
            case let .success(output):
                self.publish(AdbDevicesParser.parse(output.stdoutText))
                if thenTrack {
                    self.openTrackSocket(generation: generation)
                    return
                }
            case let .failure(error):
                self.onLog?("adb devices -l failed: \(error)")
            }
            self.queue.asyncAfter(deadline: .now() + self.pollInterval) { [weak self] in self?.poll(generation: generation, thenTrack: false) }
        }
    }

    // MARK: host:track-devices

    private func openTrackSocket(generation: Int) {
        let port = AdbClient.serverPort(fromServerSocket: adb.serverSocket)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            fallBackToPolling(generation: generation, reason: "bad port \(port)")
            return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 2
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: nwPort, using: parameters)
        self.connection = connection
        var parser = AdbHostProtocol.ReplyParser()
        var gotOkay = false
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self, self.isCurrent(generation) else { return }
                if let data = data, !data.isEmpty {
                    var lists: [String] = []
                    var failure: String?
                    parser.feed(Array(data)) { reply in
                        switch reply {
                        case .okay: gotOkay = true
                        case let .payload(text): lists.append(text)
                        case let .fail(reason): failure = reason
                        }
                    }
                    if let reason = failure {
                        self.fallBackToPolling(generation: generation, reason: "host:track-devices FAIL \(reason)")
                        return
                    }
                    for list in lists { self.publish(AdbDevicesParser.parse(list)) }
                    if gotOkay { self.state.withLock { $0.tracking = true } }
                }
                if isComplete || error != nil {
                    self.fallBackToPolling(generation: generation, reason: error.map { "\($0)" } ?? "closed")
                } else {
                    receive()
                }
            }
        }
        connection.stateUpdateHandler = { [weak self] connectionState in
            guard let self = self, self.isCurrent(generation) else { return }
            switch connectionState {
            case .ready:
                connection.send(content: Data(AdbHostProtocol.encodeRequest(AdbHostProtocol.hostTrackDevices)), completion: .contentProcessed { error in
                    if let error = error {
                        self.fallBackToPolling(generation: generation, reason: "send \(error)")
                        return
                    }
                    receive()
                })
            case let .failed(error):
                self.fallBackToPolling(generation: generation, reason: "\(error)")
            case let .waiting(error):
                self.fallBackToPolling(generation: generation, reason: "waiting \(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func fallBackToPolling(generation: Int, reason: String) {
        guard isCurrent(generation) else { return }
        let wasTracking = state.withLock { s -> Bool in
            let was = s.tracking
            s.tracking = false
            return was
        }
        connection?.cancel()
        connection = nil
        onLog?("host:track-devices \(wasTracking ? "ended" : "unavailable") (\(reason)); polling adb devices -l every \(pollInterval) s")
        queue.asyncAfter(deadline: .now() + pollInterval) { [weak self] in self?.poll(generation: generation, thenTrack: false) }
    }

    // MARK: Device choice

    /// SPEC 11 `mirrorDeviceSerial` overrides; otherwise a device that looks like a DC-1, preferring one in state
    /// `device`; otherwise the first ready device; otherwise the first device of any state (so the owner sees
    /// "unauthorized" or "offline" instead of nothing).
    static func chooseDaylight(_ devices: [AdbDevice], preferredSerial: String?) -> AdbDevice? {
        if let serial = preferredSerial, let match = devices.first(where: { $0.serial == serial }) { return match }
        let daylights = devices.filter { $0.looksLikeDaylight }
        if let ready = daylights.first(where: { $0.isReady }) { return ready }
        if let any = daylights.first { return any }
        if let ready = devices.first(where: { $0.isReady }) { return ready }
        return devices.first
    }
}
