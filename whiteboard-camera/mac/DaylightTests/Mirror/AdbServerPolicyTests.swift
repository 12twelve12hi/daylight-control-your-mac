import DaylightKit
import Foundation
import Network
import XCTest
@testable import Daylight

/// SPEC F5: never `kill-server`; shared 5037 when versions match or nobody answers; private port otherwise (row 24).
final class AdbServerPolicyTests: XCTestCase {
    private func decide(mode: AdbServerMode, theirs: Int?, ourVersionOutput: String?) -> AdbServerPolicy.Decision? {
        let adb = FakeAdb()
        if let text = ourVersionOutput {
            adb.respond(containing: ["version"], with: FakeAdb.ok(text))
        } else {
            adb.respond(containing: ["version"], with: FakeAdb.fail(1, "no such file"))
        }
        let done = expectation(description: "decision")
        var decision: AdbServerPolicy.Decision?
        AdbServerPolicy.decide(bundled: adb, mode: mode, privatePort: 27180, probe: { completion in completion(theirs) }) { d in
            decision = d
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(adb.calls.contains { $0.contains("kill-server") }, "never kill-server")
        return decision
    }

    func testSharedWhenNobodyAnswers() {
        XCTAssertEqual(decide(mode: .auto, theirs: nil, ourVersionOutput: "Android Debug Bridge version 1.0.41\nVersion 37.0.0-14910828\n"), .shared5037)
    }

    func testSharedWhenVersionsMatch() {
        XCTAssertEqual(decide(mode: .auto, theirs: 41, ourVersionOutput: "Android Debug Bridge version 1.0.41\nVersion 37.0.0-14910828\n"), .shared5037)
    }

    func testConflictGoesPrivate() {
        let decision = decide(mode: .auto, theirs: 40, ourVersionOutput: "Android Debug Bridge version 1.0.41\n")
        XCTAssertEqual(decision, .conflict(theirVersion: 40, ours: 41, privatePort: 27180))
        XCTAssertEqual(decision?.serverSocket, "tcp:localhost:27180")
        XCTAssertEqual(decision?.isConflict, true)
        XCTAssertEqual(FailureText.sentence(.adbVersionClash), "Another adb is running (Android Studio?). Daylight is using its own copy; a tablet already claimed by the other adb will not be visible.")
        XCTAssertTrue(FailureText.logLine(.adbVersionClash, ["40", "41"]).hasSuffix("host:version mismatch 40 vs 41"), "row 24 log line with the arguments substituted")
    }

    func testUnreadableOwnVersionSharesTheDefaultSocket() {
        XCTAssertEqual(decide(mode: .auto, theirs: 40, ourVersionOutput: nil), .shared5037)
        XCTAssertEqual(decide(mode: .auto, theirs: 40, ourVersionOutput: "garbage"), .shared5037)
    }

    func testForcedModes() {
        XCTAssertEqual(decide(mode: .shared, theirs: 40, ourVersionOutput: nil), .shared5037)
        XCTAssertEqual(decide(mode: .privatePort, theirs: nil, ourVersionOutput: nil), .privatePort(27180))
        XCTAssertEqual(AdbServerPolicy.Decision.privatePort(27180).serverSocket, "tcp:localhost:27180")
        XCTAssertNil(AdbServerPolicy.Decision.shared5037.serverSocket)
        XCTAssertEqual(AdbClient.serverPort(fromServerSocket: "tcp:localhost:27180"), 27180)
        XCTAssertEqual(AdbClient.serverPort(fromServerSocket: nil), 5037)
        XCTAssertEqual(AdbClient.serverPort(fromServerSocket: "nonsense"), 5037)
        XCTAssertEqual(Settings.defaults.adbPrivatePort, 27180)
    }

    func testProbeOfAClosedPortAnswersNil() {
        let done = expectation(description: "probe")
        // A port nobody listens on (ephemeral range, bound and released first).
        let port = AdbServerPolicyTests.freePort()
        AdbServerPolicy.probeDefaultServer(port: port, queue: DispatchQueue(label: "probe"), timeout: 2) { version in
            XCTAssertNil(version)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testProbeReadsTheVersionFromAFakeServer() throws {
        let queue = DispatchQueue(label: "fake-adb-server")
        let listener = try NWListener(using: .tcp, on: .any)
        var connections: [NWConnection] = []
        listener.newConnectionHandler = { connection in
            connections.append(connection)
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "000chost:version")
                connection.send(content: Data("OKAY00040029".utf8), completion: .contentProcessed { _ in })
            }
        }
        let ready = expectation(description: "listener")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        guard let port = listener.port?.rawValue else { return XCTFail("no port") }
        let done = expectation(description: "probe")
        AdbServerPolicy.probeDefaultServer(port: port, queue: DispatchQueue(label: "probe"), timeout: 3) { version in
            XCTAssertEqual(version, 41)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        listener.cancel()
    }

    static func freePort() -> UInt16 {
        // Bind an ephemeral port, read it back, close: the OS will not reuse it for a moment.
        let listener = try? NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "free-port")
        let ready = DispatchSemaphore(value: 0)
        var port: UInt16 = 49_999
        listener?.stateUpdateHandler = { state in
            if case .ready = state {
                port = listener?.port?.rawValue ?? port
                ready.signal()
            }
            if case .failed = state { ready.signal() }
        }
        listener?.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        listener?.cancel()
        return port
    }
}
