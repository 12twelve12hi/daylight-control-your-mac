import DaylightKit
import XCTest
@testable import Daylight

final class ApiRoutesTests: XCTestCase {
    func testHealthzAndInfo() throws {
        let health = ApiRoutes.healthz()
        XCTAssertEqual(health.status, 200)
        XCTAssertEqual(String(decoding: health.body, as: UTF8.self), "ok")
        let dict = ApiRoutes.infoDictionary(version: "0.1.0", build: 42, port: 7789, inkSource: .native, pillStripHeight: 96, origin: "http://100.1.2.3:7789")
        let info = ApiRoutes.info(dict)
        XCTAssertEqual(info.status, 200)
        let json = try JSONSerialization.jsonObject(with: Data(info.body)) as? [String: Any]
        XCTAssertEqual(json?["app"] as? String, "daylight")
        XCTAssertEqual(json?["version"] as? String, "0.1.0")
        XCTAssertEqual((json?["build"] as? NSNumber)?.intValue, 42)
        XCTAssertEqual((json?["port"] as? NSNumber)?.intValue, 7789)
        XCTAssertEqual(json?["inkSource"] as? String, "native")
        XCTAssertEqual((json?["pillStripHeight"] as? NSNumber)?.intValue, 96)
        XCTAssertEqual(json?["secureHint"] as? String, "chrome://flags/#unsafely-treat-insecure-origin-as-secure")
        XCTAssertEqual(json?["origin"] as? String, "http://100.1.2.3:7789")
        let text = String(decoding: info.body, as: UTF8.self)
        XCTAssertTrue(text.contains("\"app\":\"daylight\""), "the web probe greps this exact fragment")
    }

    func testOriginFollowsTheHostHeader() {
        XCTAssertEqual(WebServer.originFromHost("192.168.1.23:7788"), "http://192.168.1.23:7788", "the Wi-Fi tablet is told the address it reached, not the Tailscale one")
        XCTAssertEqual(WebServer.originFromHost(" mikes-mac.local:7789 "), "http://mikes-mac.local:7789")
        XCTAssertEqual(WebServer.originFromHost("[fe80::1]:7788"), "http://[fe80::1]:7788")
        XCTAssertNil(WebServer.originFromHost(""))
        XCTAssertNil(WebServer.originFromHost("evil host"))
        XCTAssertNil(WebServer.originFromHost("a.b/c"))
        XCTAssertNil(WebServer.originFromHost("x\r\nSet-Cookie: y"))
        XCTAssertNil(WebServer.originFromHost(String(repeating: "a", count: 300)))
    }

    func testOriginMatchesHost() {
        XCTAssertTrue(WebServer.originMatchesHost(origin: "http://127.0.0.1:7788", host: "127.0.0.1:7788"), "the page under adb reverse")
        XCTAssertTrue(WebServer.originMatchesHost(origin: "http://192.168.1.23:7790", host: "192.168.1.23:7790"), "the Wi-Fi tablet on a scanned port")
        XCTAssertTrue(WebServer.originMatchesHost(origin: "http://Mac.local:7788", host: "mac.local:7788"))
        XCTAssertTrue(WebServer.originMatchesHost(origin: "http://[::1]:7788", host: "[::1]:7788"))
        XCTAssertTrue(WebServer.originMatchesHost(origin: "http://127.0.0.1", host: "127.0.0.1:80"), "http defaults to port 80")
        XCTAssertTrue(WebServer.originMatchesHost(origin: nil, host: "127.0.0.1:7788"), "native clients send no Origin")
        XCTAssertTrue(WebServer.originMatchesHost(origin: nil, host: nil))
        XCTAssertFalse(WebServer.originMatchesHost(origin: "https://evil.example", host: "127.0.0.1:7788"))
        XCTAssertFalse(WebServer.originMatchesHost(origin: "http://127.0.0.1:8080", host: "127.0.0.1:7788"), "another local server's page")
        XCTAssertFalse(WebServer.originMatchesHost(origin: "https://127.0.0.1", host: "127.0.0.1"), "https defaults to 443, the Host header to 80")
        XCTAssertFalse(WebServer.originMatchesHost(origin: "null", host: "127.0.0.1:7788"), "an opaque origin is foreign")
        XCTAssertFalse(WebServer.originMatchesHost(origin: "http://127.0.0.1:7788", host: nil), "an Origin without a Host cannot be checked")
        XCTAssertFalse(WebServer.originMatchesHost(origin: "http://a:b:c", host: "a:1"))
    }

    func testApkRoute() throws {
        XCTAssertEqual(ApiRoutes.apk(url: nil).status, 404)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).apk")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let response = ApiRoutes.apk(url: url)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.headers.contains { $0.0 == "Content-Type" && $0.1 == "application/vnd.android.package-archive" })
        XCTAssertTrue(response.headers.contains { $0.0 == "Content-Disposition" && $0.1 == "attachment; filename=\"DaylightInk.apk\"" })
        XCTAssertEqual(response.body.count, 4)
        let bytes = response.bytes()
        XCTAssertTrue(String(decoding: bytes.prefix(60), as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("Connection: close"))
    }
}

final class StaticFilesTests: XCTestCase {
    func testTraversalAndTypes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("static-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hi".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("assets/a.css"), atomically: true, encoding: .utf8)
        let files = StaticFiles(root: root)
        XCTAssertEqual(files.respond(path: "/").status, 200)
        XCTAssertEqual(files.respond(path: "/index.html").status, 200)
        XCTAssertEqual(files.respond(path: "/../index.html").status, 400)
        XCTAssertEqual(files.respond(path: "/%2e%2e/index.html").status, 400)
        XCTAssertEqual(files.respond(path: "/assets").status, 404, "directories are not served")
        let css = files.respond(path: "/assets/a.css")
        XCTAssertEqual(css.status, 200)
        XCTAssertTrue(css.headers.contains { $0.0 == "Cache-Control" && $0.1 == StaticFiles.immutableCache })
        XCTAssertTrue(css.headers.contains { $0.0 == "Content-Type" && $0.1.hasPrefix("text/css") })
        XCTAssertEqual(StaticFiles.contentType(forExtension: "webmanifest"), "application/manifest+json")
        XCTAssertEqual(StaticFiles.contentType(forExtension: "apk"), "application/vnd.android.package-archive")
        XCTAssertTrue(StaticFiles.contentType(forExtension: "jpg").hasPrefix("image/"), "UTType fallback")
        XCTAssertEqual(StaticFiles.contentType(forExtension: "zzz-unknown"), "application/octet-stream")
        XCTAssertEqual(StaticFiles(root: nil).respond(path: "/").status, 404)
    }
}

final class LocalAddressesTests: XCTestCase {
    func testTailscaleFirstThenLAN() {
        let entries = LocalAddresses.classify([
            ("lo0", "127.0.0.1"),
            ("en0", "192.168.1.23"),
            ("awdl0", "169.254.10.10"),
            ("en5", "169.254.3.4"),
            ("utun3", "100.101.102.103"),
            ("utun4", "10.8.0.2"),
            ("bridge100", "192.168.64.1"),
            ("en1", "10.0.0.7"),
        ])
        XCTAssertEqual(entries.map { $0.ip }, ["100.101.102.103", "192.168.1.23", "10.0.0.7"])
        XCTAssertEqual(entries.first?.kind, .tailscale)
        XCTAssertEqual(entries.first?.interface, "utun3")
        XCTAssertEqual(LocalAddresses.primaryURL(port: 7788, entries: entries), "http://100.101.102.103:7788")
        XCTAssertNil(LocalAddresses.primaryURL(port: 7788, entries: []))
    }

    func testTailscaleRange() {
        XCTAssertTrue(LocalAddresses.isTailscale("100.64.0.1"))
        XCTAssertTrue(LocalAddresses.isTailscale("100.127.255.254"))
        XCTAssertFalse(LocalAddresses.isTailscale("100.63.255.255"))
        XCTAssertFalse(LocalAddresses.isTailscale("100.128.0.1"))
        XCTAssertFalse(LocalAddresses.isTailscale("192.168.1.1"))
        XCTAssertFalse(LocalAddresses.isTailscale("not an ip"))
        _ = LocalAddresses.list()   // must not crash on the runner
        XCTAssertFalse(LocalAddresses.hostname().isEmpty)
    }
}

final class InkConnectionTests: XCTestCase {
    func testSendFramesAndCloses() throws {
        let transport = FakeTransport(address: "192.168.1.40")
        let connection = InkConnection(transport: transport)
        connection.send(.pong(sequence: 7, clientTimeUs: 1), timestampUs: 1_760_000_000_123_456)
        XCTAssertEqual(transport.frames.count, 1)
        var buffer = transport.frames[0]
        // Server frames are unmasked binary frames; decode by hand.
        XCTAssertEqual(buffer[0], 0x82)
        XCTAssertEqual(buffer[1], 32)
        let payload = Array(buffer[2...])
        let decoded = try Codec.decode(payload)
        XCTAssertEqual(decoded.1, .pong(sequence: 7, clientTimeUs: 1))
        connection.close(code: 1008, reason: "not allowed")
        XCTAssertTrue(connection.isClosed)
        XCTAssertTrue(transport.closed)
        buffer = transport.frames[1]
        XCTAssertEqual(buffer[0], 0x88)
        XCTAssertEqual(WebSocketFrame.closeCode(Array(buffer[2...])), 1008)
        connection.send(.pong(sequence: 8, clientTimeUs: 1))
        XCTAssertEqual(transport.frames.count, 2, "nothing is sent after close")
        XCTAssertFalse(connection.isLoopback)
        XCTAssertEqual(connection.label, "192.168.1.40")
        XCTAssertTrue(FakeTransport(address: "127.0.0.1").isLoopback)
    }
}

/// A byte pipe the tests control (ARCHITECTURE 10: golden bytes straight into the router).
final class FakeTransport: InkTransport {
    let remoteAddress: String
    var isLoopback: Bool
    private(set) var frames: [[UInt8]] = []
    private(set) var closed = false

    init(address: String) {
        remoteAddress = address
        isLoopback = address.hasPrefix("127.") || address == "::1"
    }

    func sendRaw(_ bytes: [UInt8]) {
        frames.append(bytes)
    }

    func closeTransport() {
        closed = true
    }

    /// Decoded SolStream messages the server sent on this transport, in order.
    var messages: [Message] {
        var out: [Message] = []
        for frame in frames where frame.first == 0x82 {
            var payload: [UInt8]
            if frame[1] < 126 { payload = Array(frame[2...]) } else if frame[1] == 126 { payload = Array(frame[4...]) } else { payload = Array(frame[10...]) }
            if let decoded = try? Codec.decode(payload) { out.append(decoded.1) }
        }
        return out
    }

    var states: [StateReport] {
        return messages.compactMap { m in
            if case let .state(s) = m { return s }
            return nil
        }
    }

    var acks: [SolStream.AckStatus] {
        return messages.compactMap { m in
            if case let .handshakeAck(_, _, _, status) = m { return status }
            return nil
        }
    }

    var closeCode: UInt16? {
        for frame in frames where frame.first == 0x88 { return WebSocketFrame.closeCode(Array(frame[2...])) }
        return nil
    }
}
