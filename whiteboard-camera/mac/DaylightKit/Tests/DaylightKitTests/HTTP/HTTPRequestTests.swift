import XCTest
import DaylightKit

/// Acceptance A7 (HTTP side): request split across reads, lower-cased headers, traversal strings rejected, accept key.
final class HTTPRequestTests: XCTestCase {
    func testParsesUpgradeRequest() throws {
        let raw = "GET /ink?host=100.64.1.2 HTTP/1.1\r\nHost: mac:7788\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: solstream.v1, other\r\n\r\nleftover"
        let bytes = Array(raw.utf8)
        let parsed = try bytes.withUnsafeBytes { try HTTPRequest.parse($0) }
        let (request, consumed) = try XCTUnwrap(parsed)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/ink")
        XCTAssertEqual(request.query["host"], "100.64.1.2")
        XCTAssertTrue(request.isWebSocketUpgrade)
        XCTAssertEqual(request.webSocketKey, "dGhlIHNhbXBsZSBub25jZQ==")
        XCTAssertEqual(request.webSocketVersion, 13)
        XCTAssertEqual(request.webSocketProtocols, ["solstream.v1", "other"])
        XCTAssertEqual(consumed, bytes.count - "leftover".utf8.count)
    }

    func testHeadersAreLowerCasedAndTrimmed() throws {
        let raw = "GET / HTTP/1.1\r\nHOST:   mac   \r\nx-Custom-Thing: Value With Caps\r\nContent-Type:text/plain\r\n\r\n"
        let (request, _) = try XCTUnwrap(try HTTPRequest.parse(Array(raw.utf8)))
        XCTAssertEqual(request.headers["host"], "mac")
        XCTAssertEqual(request.headers["x-custom-thing"], "Value With Caps", "values keep their case")
        XCTAssertEqual(request.headers["content-type"], "text/plain")
        XCTAssertNil(request.headers["HOST"])
        XCTAssertFalse(request.isWebSocketUpgrade)
    }

    func testRequestSplitAcrossReads() throws {
        let raw = "GET /healthz HTTP/1.1\r\nHost: mac\r\nConnection: close\r\n\r\n"
        let bytes = Array(raw.utf8)
        var buffer: [UInt8] = []
        var result: (request: HTTPRequest, consumed: Int)?
        for b in bytes {
            buffer.append(b)
            result = try HTTPRequest.parse(buffer)
            if result != nil {
                XCTAssertEqual(buffer.count, bytes.count, "complete only at the last byte")
            }
        }
        let r = try XCTUnwrap(result)
        XCTAssertEqual(r.request.path, "/healthz")
        XCTAssertEqual(r.consumed, bytes.count)
    }

    func testIncompleteHeadReturnsNil() throws {
        let bytes = Array("GET / HTTP/1.1\r\nHost: x\r\n".utf8)
        XCTAssertNil(try HTTPRequest.parse(bytes))
        XCTAssertNil(try HTTPRequest.parse([]))
        XCTAssertNil(try HTTPRequest.parse(Array("GET".utf8)))
    }

    func testBadRequestLineAndHugeHead() {
        XCTAssertThrowsError(try HTTPRequest.parse(Array("GARBAGE\r\n\r\n".utf8))) { XCTAssertEqual($0 as? HTTPError, .badRequestLine) }
        XCTAssertThrowsError(try HTTPRequest.parse(Array("GET / FTP/1\r\n\r\n".utf8))) { XCTAssertEqual($0 as? HTTPError, .badRequestLine) }
        let huge = Array(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPRequest.maxHeadLength + 10)).utf8)
        XCTAssertThrowsError(try HTTPRequest.parse(huge)) { XCTAssertEqual($0 as? HTTPError, .headTooLarge) }
    }

    func testQueryDecoding() throws {
        let (request, _) = try XCTUnwrap(try HTTPRequest.parse(Array("GET /?scenario=pending&host=100.64.1.2%3A7788&flag HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertEqual(request.path, "/")
        XCTAssertEqual(request.query["scenario"], "pending")
        XCTAssertEqual(request.query["host"], "100.64.1.2:7788")
        XCTAssertEqual(request.query["flag"], "")
    }

    func testWebSocketUpgradeNeedsConnectionUpgrade() throws {
        let noConnection = "GET /ink HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: abc\r\n\r\n"
        XCTAssertFalse(try XCTUnwrap(try HTTPRequest.parse(Array(noConnection.utf8))).request.isWebSocketUpgrade)
        let keepAlive = "GET /ink HTTP/1.1\r\nUpgrade: WebSocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: abc\r\n\r\n"
        XCTAssertTrue(try XCTUnwrap(try HTTPRequest.parse(Array(keepAlive.utf8))).request.isWebSocketUpgrade)
        XCTAssertEqual(try XCTUnwrap(try HTTPRequest.parse(Array(keepAlive.utf8))).request.webSocketProtocols, [])
    }

    func testWebRootPathRejectsTraversal() {
        XCTAssertEqual(WebRootPath.resolve("/"), "index.html")
        XCTAssertEqual(WebRootPath.resolve(""), "index.html")
        XCTAssertEqual(WebRootPath.resolve("/assets/app-abc.js"), "assets/app-abc.js")
        XCTAssertEqual(WebRootPath.resolve("//assets///x.css"), "assets/x.css")
        XCTAssertEqual(WebRootPath.resolve("/./manifest.webmanifest"), "manifest.webmanifest")
        XCTAssertNil(WebRootPath.resolve("/../etc/passwd"))
        XCTAssertNil(WebRootPath.resolve("/%2e%2e/secret"))
        XCTAssertNil(WebRootPath.resolve("/assets/%2E%2E/%2e%2e/etc/passwd"))
        XCTAssertNil(WebRootPath.resolve("/a/..%2fb"))
        XCTAssertNil(WebRootPath.resolve("/a\\b"))
        XCTAssertNil(WebRootPath.resolve("/a%00b"))
        XCTAssertNil(WebRootPath.resolve("/%zz"), "bad percent encoding")
        XCTAssertEqual(MIME.type(forExtension: "webmanifest"), "application/manifest+json")
        XCTAssertEqual(MIME.type(forExtension: "APK"), "application/vnd.android.package-archive")
        XCTAssertEqual(MIME.type(forExtension: "js"), "text/javascript; charset=utf-8")
        XCTAssertNil(MIME.type(forExtension: "exe"))
    }

    func testStatusTextAndResponse() {
        XCTAssertEqual(HTTPRequest.statusText(403), "Forbidden")
        XCTAssertEqual(HTTPRequest.statusText(405), "Method Not Allowed")
        XCTAssertEqual(HTTPRequest.statusText(413), "Payload Too Large")
        XCTAssertEqual(HTTPRequest.statusText(426), "Upgrade Required")
        XCTAssertEqual(HTTPRequest.statusText(404), "Not Found")
        XCTAssertEqual(HTTPRequest.statusText(999), "Unknown")
        let response = HTTPRequest.response(status: 200, headers: [("Content-Type", "text/plain")], body: Array("ok".utf8))
        XCTAssertEqual(String(decoding: response, as: UTF8.self), "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
    }

    func testAcceptKeyAndUpgradeResponse() {
        XCTAssertEqual(HTTPRequest.webSocketAccept(forKey: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        XCTAssertEqual(Hex.encode(SHA1.hash(Array("abc".utf8))), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(Hex.encode(SHA1.hash([])), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(Hex.encode(SHA1.hash(Array(String(repeating: "a", count: 55).utf8))), "c1c8bbdc22796e28c0e15163d20899b65621d65a", "55 bytes: padding spills into a second block")
        XCTAssertEqual(Hex.encode(SHA1.hash(Array(String(repeating: "a", count: 64).utf8))), "0098ba824b5c16427bd7a1122a5a442a25ec644d")
        let with = String(decoding: HTTPRequest.upgradeResponse(accept: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", subprotocol: "solstream.v1"), as: UTF8.self)
        XCTAssertEqual(with, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nSec-WebSocket-Protocol: solstream.v1\r\n\r\n")
        let without = String(decoding: HTTPRequest.upgradeResponse(accept: "x", subprotocol: nil), as: UTF8.self)
        XCTAssertFalse(without.contains("Sec-WebSocket-Protocol"))
        XCTAssertTrue(without.hasSuffix("\r\n\r\n"))
    }
}
