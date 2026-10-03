import DaylightKit
import Foundation
import Network
import XCTest
@testable import Daylight

/// SPEC F2 end to end with a fake adb and a real loopback server that speaks the scrcpy 4.1 byte layout: the exact
/// argument lists in order, the dummy byte with retries, `forward --remove` after connecting, the demuxed packets,
/// `terminate()` on stop, and the `[server] ERROR:` path.
final class ScrcpySessionTests: XCTestCase {
    static let serverURL = URL(fileURLWithPath: "/Applications/Daylight.app/Contents/Resources/Vendor/scrcpy-server-v4.1")

    /// A loopback server that writes the synthetic stream to every client.
    final class FakeScrcpyServer {
        let listener: NWListener
        let queue = DispatchQueue(label: "fake-scrcpy-server")
        var connections: [NWConnection] = []
        let payload: Data

        init(payload: [UInt8]) throws {
            self.payload = Data(payload)
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() -> UInt16? {
            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                connection.send(content: self.payload, completion: .contentProcessed { _ in })
            }
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
                if case .failed = state { ready.signal() }
            }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 5)
            return listener.port?.rawValue
        }

        func stop() {
            listener.cancel()
            for connection in connections { connection.cancel() }
        }
    }

    static func stream() -> [UInt8] {
        var s: [UInt8] = ScrcpyStreamBuilder.dummyByte()
        s += ScrcpyStreamBuilder.deviceMeta(name: "DC-1")
        s += ScrcpyStreamBuilder.codec()
        s += ScrcpyStreamBuilder.session(width: 1200, height: 1600)
        s += ScrcpyStreamBuilder.config(annexB: [0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE])
        s += ScrcpyStreamBuilder.frame(ptsUs: 100, keyFrame: true, annexB: [0, 0, 0, 1, 0x65, 0x88])
        s += ScrcpyStreamBuilder.frame(ptsUs: 133, keyFrame: false, annexB: [0, 0, 0, 1, 0x41, 0x9A])
        s += ScrcpyStreamBuilder.session(width: 1600, height: 1200)
        s += ScrcpyStreamBuilder.config(annexB: [0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE])
        s += ScrcpyStreamBuilder.frame(ptsUs: 2000, keyFrame: true, annexB: [0, 0, 0, 1, 0x65, 0x88])
        return s
    }

    /// Polls `condition` until it holds or `timeout` passes (a condition wait, not a fixed window).
    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    func testCommandOrderDummyByteAndPackets() throws {
        let server = try FakeScrcpyServer(payload: ScrcpySessionTests.stream())
        guard let port = server.start() else { return XCTFail("no server port") }
        defer { server.stop() }
        let adb = FakeAdb()
        let config = ScrcpySession.Config(serial: "JP0001", maxSize: 1600, bitRate: 8_000_000, maxFps: 30, localPort: port)
        let session = ScrcpySession(adb: adb, server: ScrcpySessionTests.serverURL, config: config, queue: DispatchQueue(label: "mirror"), dummyByteAttempts: 20, dummyByteRetryInterval: 0.05)
        let packets = Locked<[ScrcpyPacket]>([])
        let gotAll = expectation(description: "nine packets")
        let connected = expectation(description: "connected")
        session.onConnected = { connected.fulfill() }
        session.onPacket = { packet in
            let count = packets.withLock { list -> Int in
                list.append(packet)
                return list.count
            }
            if count == 9 { gotAll.fulfill() }
        }
        session.onExit = { error in XCTFail("unexpected exit \(String(describing: error))") }
        session.start()
        wait(for: [connected, gotAll], timeout: 10)
        let received = packets.withLock { $0 }
        XCTAssertEqual(received[0], .deviceMeta(name: "DC-1"))
        XCTAssertEqual(received[1], .codec(id: 0x6832_3634))
        XCTAssertEqual(received[2], .session(width: 1200, height: 1600))
        guard case .config = received[3] else { return XCTFail("config") }
        guard case let .frame(pts, key, _) = received[4] else { return XCTFail("frame") }
        XCTAssertEqual(pts, 100)
        XCTAssertTrue(key)
        XCTAssertEqual(received[6], .session(width: 1600, height: 1200))
        XCTAssertEqual(session.deviceName, "DC-1")
        XCTAssertEqual(session.boundPort, port)
        XCTAssertEqual(session.dummyByteAttemptsUsed, 1, "the server was already listening")
        // Commands in order: push, forward, shell, forward --remove.
        let calls = adb.calls
        XCTAssertEqual(calls.count, 4, "\(calls)")
        XCTAssertEqual(calls[0], ["-s", "JP0001", "push", ScrcpySessionTests.serverURL.path, "/data/local/tmp/scrcpy-server.jar"])
        XCTAssertEqual(calls[1], ["-s", "JP0001", "forward", "tcp:\(port)", "localabstract:scrcpy"])
        XCTAssertEqual(calls[2], ScrcpyLaunch(serial: "JP0001", localPort: port).shellArguments)
        XCTAssertEqual(calls[2].joined(separator: " "), "-s JP0001 shell CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 4.1 log_level=info tunnel_forward=true video=true audio=false control=false cleanup=false video_codec=h264 max_size=1600 video_bit_rate=8000000 max_fps=30 send_device_meta=true send_frame_meta=true send_stream_meta=true send_dummy_byte=true")
        XCTAssertEqual(calls[3], ["-s", "JP0001", "forward", "--remove", "tcp:\(port)"], "the forward is removed once the socket is up")
        XCTAssertEqual(adb.spawned.count, 1)
        XCTAssertTrue(adb.spawned[0].isRunning)
        session.stop()
        XCTAssertTrue(waitUntil(10) { adb.spawned[0].wasTerminated && !session.isRunning }, "stop terminates the adb shell child")
        XCTAssertFalse(session.isRunning)
    }

    func testDummyByteIsRetriedUntilTheServerListens() throws {
        let server = try FakeScrcpyServer(payload: ScrcpySessionTests.stream())
        let port = AdbServerPolicyTests.freePort()
        let adb = FakeAdb()
        let config = ScrcpySession.Config(serial: "S", localPort: port)
        let session = ScrcpySession(adb: adb, server: ScrcpySessionTests.serverURL, config: config, queue: DispatchQueue(label: "mirror"), dummyByteAttempts: 60, dummyByteRetryInterval: 0.05)
        let connected = expectation(description: "connected")
        session.onConnected = { connected.fulfill() }
        session.onExit = { error in XCTFail("unexpected exit \(String(describing: error))") }
        session.start()
        // The server comes up late, on the port the session is already retrying: once the first attempt failed and
        // the second began (a condition, not a 0.4 s guess that a slow runner could overtake).
        XCTAssertTrue(waitUntil(10) { session.dummyByteAttemptsUsed >= 2 }, "the session retries while nothing listens")
        let listener = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { connection in
            connection.start(queue: server.queue)
            connection.send(content: server.payload, completion: .contentProcessed { _ in })
        }
        listener?.start(queue: server.queue)
        ScrcpySessionTests.lateListeners.append(listener)
        wait(for: [connected], timeout: 15)
        XCTAssertGreaterThan(session.dummyByteAttemptsUsed, 1, "at least one retry happened before the server listened")
        XCTAssertEqual(session.boundPort, port)
        session.stop()
        ScrcpySessionTests.lateListeners.forEach { $0?.cancel() }
        ScrcpySessionTests.lateListeners.removeAll()
    }

    static var lateListeners: [NWListener?] = []

    func testDummyByteTimeoutEndsTheSession() {
        let adb = FakeAdb()
        let port = AdbServerPolicyTests.freePort()
        let session = ScrcpySession(adb: adb, server: ScrcpySessionTests.serverURL, config: ScrcpySession.Config(serial: "S", localPort: port), queue: DispatchQueue(label: "mirror"), dummyByteAttempts: 3, dummyByteRetryInterval: 0.05)
        let exited = expectation(description: "exit")
        session.onExit = { error in
            guard case let .dummyByteTimeout(attempts)? = error as? ScrcpySessionError else { return XCTFail("\(String(describing: error))") }
            XCTAssertEqual(attempts, 3)
            exited.fulfill()
        }
        session.start()
        wait(for: [exited], timeout: 10)
        XCTAssertEqual(session.dummyByteAttemptsUsed, 3)
        XCTAssertTrue(adb.spawned.first?.wasTerminated ?? false, "the server child is terminated on failure")
        XCTAssertEqual(adb.calls(containing: "--remove").count, 1, "the forward is removed on failure too")
    }

    func testServerErrorLineBecomesRow25() {
        let adb = FakeAdb()
        adb.onSpawn = { _, child in
            child.emitStderr("[server] WARN: Unknown server option: x\n")
            child.emitStderr("[server] ERROR: Could not create encoder\n")
            child.exit(1)
        }
        let session = ScrcpySession(adb: adb, server: ScrcpySessionTests.serverURL, config: ScrcpySession.Config(serial: "S", localPort: AdbServerPolicyTests.freePort()), queue: DispatchQueue(label: "mirror"), dummyByteAttempts: 100, dummyByteRetryInterval: 0.1)
        let logs = Locked<[String]>([])
        session.onServerLog = { line in logs.withLock { $0.append(line) } }
        let exited = expectation(description: "exit")
        session.onExit = { error in
            guard case let .serverExited(status, firstError)? = error as? ScrcpySessionError else { return XCTFail("\(String(describing: error))") }
            XCTAssertEqual(status, 1)
            XCTAssertEqual(firstError, "[server] ERROR: Could not create encoder")
            XCTAssertEqual(FailureText.sentence(.scrcpyServerFailed, [(error as! ScrcpySessionError).detail]), "The screen mirror could not start: [server] ERROR: Could not create encoder")
            exited.fulfill()
        }
        session.start()
        wait(for: [exited], timeout: 10)
        XCTAssertTrue(logs.withLock { $0 }.contains("[server] WARN: Unknown server option: x"))
    }

    func testForwardFallsBackToTheNextPort() throws {
        let server = try FakeScrcpyServer(payload: ScrcpySessionTests.stream())
        guard let port = server.start() else { return XCTFail("no server port") }
        defer { server.stop() }
        let adb = FakeAdb()
        let busy = port - 1
        adb.respond { args in args.contains("forward") && args.contains("tcp:\(busy)") && !args.contains("--remove") ? FakeAdb.fail(1, "cannot bind") : nil }
        let session = ScrcpySession(adb: adb, server: ScrcpySessionTests.serverURL, config: ScrcpySession.Config(serial: "S", localPort: busy), queue: DispatchQueue(label: "mirror"), dummyByteAttempts: 20, dummyByteRetryInterval: 0.05)
        let connected = expectation(description: "connected")
        session.onConnected = { connected.fulfill() }
        session.start()
        wait(for: [connected], timeout: 10)
        XCTAssertEqual(session.boundPort, port)
        XCTAssertEqual(adb.calls(containing: "forward").filter { !$0.contains("--remove") }.count, 2)
        XCTAssertEqual(adb.calls(containing: "--remove").first, ["-s", "S", "forward", "--remove", "tcp:\(port)"])
        session.stop()
    }

    func testPushFailureStopsEarly() {
        let adb = FakeAdb()
        adb.respond(containing: ["push"], with: FakeAdb.fail(1, "adb: error: failed to copy"))
        let session = ScrcpySession(adb: adb, server: ScrcpySessionTests.serverURL, config: ScrcpySession.Config(serial: "S"), queue: DispatchQueue(label: "mirror"))
        let exited = expectation(description: "exit")
        session.onExit = { error in
            guard case let .pushFailed(detail)? = error as? ScrcpySessionError else { return XCTFail("\(String(describing: error))") }
            XCTAssertTrue(detail.contains("failed to copy"))
            exited.fulfill()
        }
        session.start()
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(adb.calls.count, 1)
        XCTAssertTrue(adb.spawned.isEmpty)
    }

    func testConfigFromSettings() {
        var settings = Settings.defaults
        settings.mirrorMaxSize = Settings.lowBandwidthMirror.maxSize
        settings.mirrorBitRate = Settings.lowBandwidthMirror.bitRate
        settings.mirrorMaxFps = Settings.lowBandwidthMirror.maxFps
        let config = ScrcpySession.Config(serial: "S", settings: settings)
        XCTAssertEqual(config, ScrcpySession.Config(serial: "S", maxSize: 1200, bitRate: 4_000_000, maxFps: 24, localPort: 27183))
        XCTAssertEqual(ScrcpySession.forwardPortAttempts, 16, "27183 then 27184...27199")
        XCTAssertEqual(Int(ScrcpyLaunch.defaultLocalPort) + ScrcpySession.forwardPortAttempts, Int(ScrcpyLaunch.lastLocalPort))
    }
}
