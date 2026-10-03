import XCTest
import DaylightKit

final class HTTPRequestTests: XCTestCase {
    func testParsesUpgradeRequest() throws {
        let raw = "GET /ink?host=100.64.1.2 HTTP/1.1\r\nHost: mac:7788\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: solstream.v1, other\r\n\r\nleftover"
        let bytes = Array(raw.utf8)
        let parsed = try bytes.withUnsafeBytes { try HTTPRequest.parse($0) }
        let (request, consumed) = try XCTUnwrap(parsed)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/ink")
        XCTAssertEqual(request.query["host"], "100.64.1.2")
        XCTAssertTrue(request.isWebSocketUpgrade)
        XCTAssertEqual(request.webSocketProtocols, ["solstream.v1", "other"])
        XCTAssertEqual(consumed, bytes.count - "leftover".utf8.count)
    }

    func testIncompleteHeadReturnsNil() throws {
        let bytes = Array("GET / HTTP/1.1\r\nHost: x\r\n".utf8)
        let parsed = try bytes.withUnsafeBytes { try HTTPRequest.parse($0) }
        XCTAssertNil(parsed)
    }

    func testWebRootPathRejectsTraversal() {
        XCTAssertEqual(WebRootPath.resolve("/"), "index.html")
        XCTAssertEqual(WebRootPath.resolve("/assets/app-abc.js"), "assets/app-abc.js")
        XCTAssertNil(WebRootPath.resolve("/../etc/passwd"))
        XCTAssertNil(WebRootPath.resolve("/%2e%2e/secret"))
        XCTAssertEqual(MIME.type(forExtension: "webmanifest"), "application/manifest+json")
    }

    func testServerFrameEncoding() {
        var out: [UInt8] = []
        let payload: [UInt8] = [1, 2, 3]
        payload.withUnsafeBytes { WebSocketFrame.encode(opcode: WebSocketFrame.opcodeBinary, payload: $0, into: &out) }
        XCTAssertEqual(out, [0x82, 0x03, 1, 2, 3])
        let close = WebSocketFrame.encodeClose(code: 1002, reason: "bad")
        XCTAssertEqual(Array(close.prefix(4)), [0x88, 0x05, 0x03, 0xEA])
    }
}
