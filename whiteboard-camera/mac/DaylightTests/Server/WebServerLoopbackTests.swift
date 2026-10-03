import DaylightKit
import Foundation
import Metal
import Network
import XCTest
@testable import Daylight

/// SPEC B2: the golden round trip through the real `NWListener` on 127.0.0.1 with `URLSessionWebSocketTask`, a 2 MiB
/// frame closing with 1009, and the pending (ACK 1, bit2 clear) branch with loopback trust switched off.
final class WebServerLoopbackTests: XCTestCase {
    private var pipeline: FramePipeline!
    private var router: InkRouter!
    private var server: WebServer!
    private var registryURL: URL!
    private let ioQueue = DispatchQueue(label: "test.io")
    private let inkQueue = DispatchQueue(label: "test.ink")
    private let netQueue = DispatchQueue(label: "test.net")
    private var port: UInt16 = 0
    private var webRoot: URL!
    /// Every InkConnection the server opened, held weakly (touched on netQueue only).
    private var openedInk: [WeakInk] = []
    /// Lag injection: after the first STROKE_START, every later message waits 50 ms on this serial queue before it is
    /// handed to inkQueue. Per-socket order is kept, so the PONG barrier stays sound while a STATE that STROKE_START
    /// alone produces runs well ahead of the CHUNK and COMMIT.
    private let lagQueue = DispatchQueue(label: "test.lag")

    final class WeakInk {
        weak var value: InkConnection?
        init(_ value: InkConnection) { self.value = value }
    }

    private func startStack(trustLoopback: Bool, lagAfterStrokeStart: Bool = false) throws {
        let sink = FakeSink()
        pipeline = try FramePipeline(sink: sink, settings: Settings.defaults, telemetry: Telemetry(), device: MTLCreateSystemDefaultDevice(), capture: nil)
        registryURL = FileManager.default.temporaryDirectory.appendingPathComponent("clients-\(UUID().uuidString).json")
        let registry = ClientRegistry(fileURL: registryURL, ioQueue: ioQueue, trustLoopback: trustLoopback)
        let rasterizer = InkRasterizer(surfaces: pipeline.surfaces)
        router = InkRouter(pipeline: pipeline, rasterizer: rasterizer, registry: registry, saver: nil, settings: Settings.defaults, queue: inkQueue)
        let p = pipeline!
        let r = router!
        p.onStateForClients = { [inkQueue] report in inkQueue.async { r.receiveState(report) } }
        webRoot = FileManager.default.temporaryDirectory.appendingPathComponent("web-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: webRoot.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try "<!doctype html><title>Daylight</title>".write(to: webRoot.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "console.log(1)".write(to: webRoot.appendingPathComponent("assets/app-abc123.js"), atomically: true, encoding: .utf8)
        try "{}".write(to: webRoot.appendingPathComponent("manifest.webmanifest"), atomically: true, encoding: .utf8)
        let config = WebServer.Config(webRoot: webRoot, apkURL: nil, preferredPort: 0, bonjourName: nil, loopbackOnly: true, scanPorts: false)
        server = WebServer(config: config, info: { ["version": "test", "port": 0] }, queue: netQueue)
        server.onInkClientOpened = { [weak self, inkQueue] c in
            self?.openedInk.append(WeakInk(c))
            inkQueue.async { r.clientOpened(c) }
        }
        server.onInkClientClosed = { [inkQueue] c in inkQueue.async { r.clientClosed(c) } }
        if lagAfterStrokeStart {
            var lagging = false
            server.onInkMessage = { [inkQueue, lagQueue] c, bytes, ns in
                if lagging {
                    lagQueue.async {
                        Thread.sleep(forTimeInterval: 0.05)
                        inkQueue.async { r.handle(bytes, from: c, hostTimeNs: ns) }
                    }
                    return
                }
                if InkRouter.headerOpcode(bytes) == SolStream.Opcode.strokeStart.rawValue { lagging = true }
                inkQueue.async { r.handle(bytes, from: c, hostTimeNs: ns) }
            }
        } else {
            server.onInkMessage = { [inkQueue] c, bytes, ns in inkQueue.async { r.handle(bytes, from: c, hostTimeNs: ns) } }
        }
        let ready = expectation(description: "listener ready")
        server.onReady = { [weak self] bound in
            self?.port = bound
            ready.fulfill()
        }
        server.start()
        wait(for: [ready], timeout: 5)
        XCTAssertNotEqual(port, 0)
    }

    override func tearDown() {
        server?.stop()
        netQueue.sync {}
        pipeline?.shutdown()
        if let url = registryURL { try? FileManager.default.removeItem(at: url) }
        if let root = webRoot { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    private func get(_ path: String) -> (status: Int, headers: [String: String], body: Data)? {
        let done = expectation(description: "GET \(path)")
        var result: (Int, [String: String], Data)?
        let task = URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)\(path)")!) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields { headers["\(key)".lowercased()] = "\(value)" }
                result = (http.statusCode, headers, data ?? Data())
            }
            done.fulfill()
        }
        task.resume()
        wait(for: [done], timeout: 5)
        return result
    }

    func testGoldenRoundTripOverLoopback() throws {
        try startStack(trustLoopback: true)
        let client = SelfTest.Client(url: URL(string: "ws://127.0.0.1:\(port)/ink")!)
        client.connect()
        client.send(SelfTest.Golden.handshake)
        let ack = client.wait(where: { $0.header.knownOpcode == .handshakeAck }, timeout: 5)
        XCTAssertNotNil(ack, client.errorText ?? "no ACK")
        let expected = Array(Hex.decode(SelfTest.Golden.handshakeAckOk)![16...])
        XCTAssertEqual(ack.map { Array($0.bytes[16...]) }, expected, "ACK 0 for a loopback client; header timestamp differs")
        XCTAssertEqual(client.openedProtocol, SolStream.subprotocol, "the server echoes solstream.v1")
        let state = client.wait(where: { $0.header.knownOpcode == .state }, timeout: 3)
        if case let .state(s)? = state?.message {
            XCTAssertTrue(s.flagSet.contains(.clientAllowed), "STATE right after ACK 0 carries bit2")
            XCTAssertTrue(s.flagSet.contains(.clientIsActiveSource), "a web client is the active source for ink source web")
            XCTAssertEqual(s.governor, 0)
        } else {
            XCTFail("no STATE after the ACK")
        }
        client.send(SelfTest.Golden.strokeStart)
        client.send(SelfTest.Golden.strokeChunk3)
        client.send(SelfTest.Golden.strokeCommit)
        assertStrokeLanded(client)
        client.send(SelfTest.Golden.undoCurrentPage)
        let undone = client.wait(where: { m in
            if case let .state(s)? = m.message { return s.undoDepth == 0 && s.redoDepth == 1 }
            return false
        }, timeout: 3)
        XCTAssertNotNil(undone)
        inkQueue.sync {}
        XCTAssertEqual(CanvasSurfaces.pixel(pipeline.surfaces.ink, x: 650, y: 900).a, 0, "undo redraws the dirty rectangle")
        // PING is answered with the same payload.
        client.send("da01fe001000000040e2cfeeb5400600070000000000000040e2cfeeb5400600")
        let pong = client.wait(where: { $0.header.knownOpcode == .pong }, timeout: 3)
        if case let .pong(sequence, t)? = pong?.message {
            XCTAssertEqual(sequence, 7)
            XCTAssertEqual(t, 1_760_000_000_123_456)
        } else {
            XCTFail("no PONG")
        }
        client.close()
    }

    /// The checks after the golden stroke. STROKE_START alone engages the governor and produces a STATE, so a STATE is
    /// no proof that CHUNK and COMMIT were handled: the commit's own STATE (undo_depth 1) and the PONG barrier are.
    private func assertStrokeLanded(_ client: SelfTest.Client, file: StaticString = #filePath, line: UInt = #line) {
        var sawEngaged = false
        var sawCommitted = false
        let barrier = client.barrier(sequence: 1, timeout: 10) { s in
            if s.governor == 1 || s.governor == 2 { sawEngaged = true }
            if s.undoDepth == 1 && s.strokeCount == 1 { sawCommitted = true }
        }
        XCTAssertTrue(barrier, "PONG after the stroke", file: file, line: line)
        XCTAssertTrue(sawCommitted, "STATE reports undo_depth 1 after the commit", file: file, line: line)
        if !sawEngaged {
            sawEngaged = client.wait(where: { m in
                if case let .state(s)? = m.message { return s.governor == 1 || s.governor == 2 }
                return false
            }, timeout: 3) != nil
        }
        XCTAssertTrue(sawEngaged, "STATE with governor 1 after the stroke", file: file, line: line)
        inkQueue.sync {}
        XCTAssertEqual(router.store.committedCount, 1, file: file, line: line)
        XCTAssertGreaterThan(CanvasSurfaces.pixel(pipeline.surfaces.ink, x: 650, y: 900).a, 0, "ink along the stroke", file: file, line: line)
    }

    func testStrokeChecksHoldWhenChunkAndCommitLagBehindTheEngagedState() throws {
        try startStack(trustLoopback: true, lagAfterStrokeStart: true)
        let client = SelfTest.Client(url: URL(string: "ws://127.0.0.1:\(port)/ink")!)
        client.connect()
        client.send(SelfTest.Golden.handshake)
        XCTAssertNotNil(client.wait(where: { $0.header.knownOpcode == .handshakeAck }, timeout: 5))
        client.send(SelfTest.Golden.strokeStart)
        client.send(SelfTest.Golden.strokeChunk3)
        client.send(SelfTest.Golden.strokeCommit)
        assertStrokeLanded(client)
        client.close()
    }

    func testClosedInkConnectionIsReleased() throws {
        try startStack(trustLoopback: true)
        let client = SelfTest.Client(url: URL(string: "ws://127.0.0.1:\(port)/ink")!)
        client.connect()
        client.send(SelfTest.Golden.handshake)
        XCTAssertNotNil(client.wait(where: { $0.header.knownOpcode == .handshakeAck }, timeout: 5))
        let opened = netQueue.sync { openedInk }
        XCTAssertEqual(opened.count, 1)
        XCTAssertNotNil(opened.first?.value)
        client.close()
        XCTAssertTrue(waitUntil(10) { inkQueue.sync { router.connections.isEmpty } }, "the router saw the close")
        netQueue.sync {}
        inkQueue.sync {}
        XCTAssertTrue(waitUntil(10) { opened.first?.value == nil }, "the HTTPConnection and InkConnection pair is freed after the close")
    }

    /// Index just past the first CRLF CRLF, or nil.
    private static func headEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i + 4
        }
        return nil
    }

    /// A raw upgrade with a chosen Origin, then the golden HANDSHAKE as a masked frame; returns the ACK status.
    private func handshakeStatus(origin: String) -> SolStream.AckStatus? {
        let connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let rawQueue = DispatchQueue(label: "test.raw")
        let lock = NSLock()
        var received: [UInt8] = []
        let arrived = DispatchSemaphore(value: 0)
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data = data {
                    lock.lock()
                    received.append(contentsOf: data)
                    lock.unlock()
                }
                arrived.signal()
                if error == nil && !isComplete { receive() }
            }
        }
        connection.start(queue: rawQueue)
        receive()
        defer { connection.cancel() }
        let head = "GET /ink HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: solstream.v1\r\nOrigin: \(origin)\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let deadline = Date().addingTimeInterval(10)
        var sentHandshake = false
        while Date() < deadline {
            lock.lock()
            let bytes = received
            lock.unlock()
            if let end = WebServerLoopbackTests.headEnd(bytes) {
                if !sentHandshake {
                    XCTAssertTrue(String(decoding: bytes[..<end], as: UTF8.self).hasPrefix("HTTP/1.1 101"))
                    let frame = WebSocketFrame.encodeMasked(opcode: WebSocketFrame.opcodeBinary, payload: Hex.decode(SelfTest.Golden.handshake)!, key: (1, 2, 3, 4))
                    connection.send(content: Data(frame), completion: .contentProcessed { _ in })
                    sentHandshake = true
                }
                // Server frames are unmasked and short here: 0x82, a 7-bit length, then the payload.
                var offset = end
                while offset + 2 <= bytes.count {
                    let length = Int(bytes[offset + 1] & 0x7F)
                    guard length < 126, offset + 2 + length <= bytes.count else { break }
                    let payload = Array(bytes[(offset + 2)..<(offset + 2 + length)])
                    if bytes[offset] == 0x82, let decoded = try? Codec.decode(payload), case let .handshakeAck(_, _, _, status) = decoded.1 {
                        return status
                    }
                    offset += 2 + length
                }
            }
            _ = arrived.wait(timeout: .now() + 0.5)
        }
        return nil
    }

    func testForeignOriginOverLoopbackNeedsAllow() throws {
        try startStack(trustLoopback: true)
        XCTAssertEqual(handshakeStatus(origin: "https://evil.example"), .pendingApproval, "a page from another origin is a network client: Allow panel")
        inkQueue.sync {}
        XCTAssertNil(router.registry.lookup(id: "6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b"), "nothing is remembered for it")
        XCTAssertEqual(handshakeStatus(origin: "http://127.0.0.1:\(port)"), .ok, "the Mac's own page over loopback is still trusted")
    }

    func testTwoMiBFrameClosesWith1009() throws {
        try startStack(trustLoopback: true)
        let client = SelfTest.Client(url: URL(string: "ws://127.0.0.1:\(port)/ink")!)
        client.connect()
        client.send(SelfTest.Golden.handshake)
        XCTAssertNotNil(client.wait(where: { $0.header.knownOpcode == .handshakeAck }, timeout: 5))
        let huge = Data(count: 2 * 1024 * 1024 + 64)
        let closed = expectation(description: "closed")
        client.sendRaw(huge) { _ in }
        client.onClose = { code in
            XCTAssertEqual(code, 1009)
            closed.fulfill()
        }
        wait(for: [closed], timeout: 10)
    }

    func testUnknownClientIsPendingWhenLoopbackIsNotTrusted() throws {
        try startStack(trustLoopback: false)
        let client = SelfTest.Client(url: URL(string: "ws://127.0.0.1:\(port)/ink")!)
        client.connect()
        client.send(SelfTest.Golden.handshake)
        let ack = client.wait(where: { $0.header.knownOpcode == .handshakeAck }, timeout: 5)
        if case let .handshakeAck(_, _, _, status)? = ack?.message {
            XCTAssertEqual(status, .pendingApproval, "ACK 1 for an unknown client")
        } else {
            XCTFail("no ACK")
        }
        let state = client.wait(where: { $0.header.knownOpcode == .state }, timeout: 3)
        if case let .state(s)? = state?.message {
            XCTAssertFalse(s.flagSet.contains(.clientAllowed), "bit2 clear while pending")
        } else {
            XCTFail("no STATE while pending")
        }
        // Ink from a pending client is decoded and dropped; the socket stays open.
        client.send(SelfTest.Golden.strokeStart)
        client.send(SelfTest.Golden.strokeChunk3)
        client.send(SelfTest.Golden.strokeCommit)
        XCTAssertTrue(client.barrier(sequence: 3, timeout: 10), "PONG after the dropped ink")
        inkQueue.sync {}
        XCTAssertEqual(router.store.committedCount, 0)
        XCTAssertEqual(pipeline.governorSnapshot.state, .passthrough)
        // Allow from the Mac side: ACK 0 and STATE with bit2.
        let pending = inkQueue.sync { router.pendingConnections }
        XCTAssertEqual(pending.count, 1)
        inkQueue.async { [router] in router?.allow(connectionID: pending[0].id) }
        let okAck = client.wait(where: { m in
            if case let .handshakeAck(_, _, _, status)? = m.message { return status == .ok }
            return false
        }, timeout: 3)
        XCTAssertNotNil(okAck)
        let allowed = client.wait(where: { m in
            if case let .state(s)? = m.message { return s.flagSet.contains(.clientAllowed) }
            return false
        }, timeout: 3)
        XCTAssertNotNil(allowed)
        client.close()
    }

    func testHTTPRoutesAndStaticFiles() throws {
        try startStack(trustLoopback: true)
        let health = get("/healthz")
        XCTAssertEqual(health?.status, 200)
        XCTAssertEqual(health.map { String(decoding: $0.body, as: UTF8.self) }, "ok")
        let info = get("/api/info")
        XCTAssertEqual(info?.status, 200)
        XCTAssertEqual(info?.headers["content-type"], "application/json")
        let json = try JSONSerialization.jsonObject(with: info!.body) as? [String: Any]
        XCTAssertEqual(json?["app"] as? String, "daylight")
        XCTAssertEqual(json?["origin"] as? String, "http://127.0.0.1:\(port)", "the origin is the Host the client used")
        let index = get("/")
        XCTAssertEqual(index?.status, 200)
        XCTAssertTrue(index?.headers["content-type"]?.hasPrefix("text/html") ?? false)
        XCTAssertEqual(index?.headers["cache-control"], "no-cache")
        let asset = get("/assets/app-abc123.js")
        XCTAssertEqual(asset?.status, 200)
        XCTAssertEqual(asset?.headers["cache-control"], StaticFiles.immutableCache)
        XCTAssertTrue(asset?.headers["content-type"]?.hasPrefix("text/javascript") ?? false)
        let manifest = get("/manifest.webmanifest")
        XCTAssertEqual(manifest?.headers["content-type"], "application/manifest+json")
        XCTAssertEqual(get("/missing.txt")?.status, 404)
        XCTAssertEqual(get("/daylight-ink.apk")?.status, 404, "no APK in this build")
        let traversal = get("/..%2F..%2Fetc/passwd")?.status ?? 0
        XCTAssertTrue(traversal == 400 || traversal == 404, "traversal refused, got \(traversal)")
    }

    func testConstantsMatchTheProtocol() {
        XCTAssertEqual(WebServer.defaultPort, 7788)
        XCTAssertEqual(WebServer.portRange, 7788...7799)
        XCTAssertEqual(WebServer.serviceType, "_daylight-camera._tcp")
        XCTAssertEqual(WebServer.serviceType.count, "_daylight-camera._tcp".count)
        XCTAssertEqual(WebServer.handshakeTimeout, 5)
        XCTAssertEqual(WebServer.idleTimeout, 30)
        XCTAssertEqual(WebServer.maxFrame, 2 * 1024 * 1024)
    }
}
