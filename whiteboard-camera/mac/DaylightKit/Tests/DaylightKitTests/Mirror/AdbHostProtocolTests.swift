import Foundation
import XCTest
import DaylightKit

/// The adb smart-socket framing used by `AdbServerPolicy` (host:version) and `DeviceTracker` (host:track-devices).
final class AdbHostProtocolTests: XCTestCase {
    func testRequestFraming() {
        XCTAssertEqual(String(decoding: AdbHostProtocol.encodeRequest("host:version"), as: UTF8.self), "000chost:version")
        XCTAssertEqual(String(decoding: AdbHostProtocol.encodeRequest("host:track-devices"), as: UTF8.self), "0012host:track-devices")
        XCTAssertEqual(AdbHostProtocol.encodeRequest("").count, 4)
        XCTAssertEqual(AdbHostProtocol.defaultPort, 5037)
    }

    func testOkayWithOneFramedPayload() {
        var p = AdbHostProtocol.ReplyParser()
        var replies: [AdbHostProtocol.Reply] = []
        p.feed(Array("OKAY00040029".utf8)) { replies.append($0) }
        XCTAssertEqual(replies, [.okay, .payload("0029")])
        XCTAssertEqual(AdbDevicesParser.parseHostVersion("0029"), 41)
    }

    func testTrackDevicesStreamAcrossChunks() {
        var p = AdbHostProtocol.ReplyParser()
        var replies: [AdbHostProtocol.Reply] = []
        let list1 = "0123456789ABCDEF\tdevice\n"
        let list2 = "0123456789ABCDEF\tdevice\nDC1XYZ\tunauthorized\n"
        let stream = "OKAY" + hex4(list1.utf8.count) + list1 + hex4(list2.utf8.count) + list2 + "0000"
        let bytes = Array(stream.utf8)
        var i = 0
        while i < bytes.count {
            let end = min(bytes.count, i + 3)
            p.feed(Array(bytes[i..<end])) { replies.append($0) }
            i = end
        }
        XCTAssertEqual(replies, [.okay, .payload(list1), .payload(list2), .payload("")])
        XCTAssertEqual(AdbDevicesParser.parse(list2).count, 2)
    }

    func testFailWithReason() {
        var p = AdbHostProtocol.ReplyParser()
        var replies: [AdbHostProtocol.Reply] = []
        p.feed(Array("FAIL".utf8)) { replies.append($0) }
        XCTAssertEqual(replies, [], "the reason is not complete yet")
        p.feed(Array("0007unknown".utf8)) { replies.append($0) }
        XCTAssertEqual(replies, [.fail(reason: "unknown")])
    }

    private func hex4(_ n: Int) -> String {
        var s = String(n, radix: 16)
        while s.count < 4 { s = "0" + s }
        return s
    }
}
