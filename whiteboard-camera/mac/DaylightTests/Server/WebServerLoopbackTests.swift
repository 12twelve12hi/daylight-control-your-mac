import DaylightKit
import Foundation
import Metal
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

    private func startStack(trustLoopback: Bool) throws {
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
        server.onInkClientOpened = { [inkQueue] c in inkQueue.async { r.clientOpened(c) } }
        server.onInkClientClosed = { [inkQueue] c in inkQueue.async { r.clientClosed(c) } }
        server.onInkMessage = { [inkQueue] c, bytes, ns in inkQueue.async { r.handle(bytes, from: c, hostTimeNs: ns) } }
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
        let engaged = client.wait(where: { m in
            if case let .state(s)? = m.message { return s.governor == 1 || s.governor == 2 }
            return false
        }, timeout: 3)
        XCTAssertNotNil(engaged, "STATE with governor 1 after the stroke")
        inkQueue.sync {}
        XCTAssertEqual(router.store.committedCount, 1)
        XCTAssertGreaterThan(CanvasSurfaces.pixel(pipeline.surfaces.ink, x: 650, y: 900).a, 0, "ink along the stroke")
        let committed = client.wait(where: { m in
            if case let .state(s)? = m.message { return s.undoDepth == 1 && s.strokeCount == 1 }
            return false
        }, timeout: 3)
        XCTAssertNotNil(committed, "STATE reports undo_depth 1 after the commit")
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
        Thread.sleep(forTimeInterval: 0.3)
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
