import XCTest
import DaylightKit

/// Acceptance A7: masked frames at payload lengths 0, 125, 126, 65535, 65536; fragmentation; control frames; oversize;
/// reserved bits; unmasked client frame.
final class WebSocketFrameTests: XCTestCase {
    private let key: (UInt8, UInt8, UInt8, UInt8) = (0x37, 0xFA, 0x21, 0x3D)

    private func payload(_ n: Int) -> [UInt8] {
        return (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
    }

    private func parse(_ bytes: [UInt8], maxPayload: Int = WebSocketFrame.defaultMaxPayload) throws -> (frame: WebSocketFrame, consumed: Int)? {
        var buffer = bytes
        return try WebSocketFrame.parse(&buffer, maxPayload: maxPayload)
    }

    func testRFC6455ExampleFrames() throws {
        // RFC 6455 section 5.7: a single-frame masked text message "Hello".
        let hello: [UInt8] = [0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58]
        let parsed = try XCTUnwrap(try parse(hello))
        XCTAssertEqual(parsed.consumed, 11)
        XCTAssertTrue(parsed.frame.fin)
        XCTAssertEqual(parsed.frame.opcode, WebSocketFrame.opcodeText)
        XCTAssertEqual(parsed.frame.payload, Array("Hello".utf8))
        // Unmasked in place too.
        var buffer = hello
        _ = try WebSocketFrame.parse(&buffer, maxPayload: 1000)
        XCTAssertEqual(Array(buffer[6...]), Array("Hello".utf8))
        // Our masked encoder reproduces the RFC bytes.
        XCTAssertEqual(WebSocketFrame.encodeMasked(opcode: WebSocketFrame.opcodeText, payload: Array("Hello".utf8), key: key), hello)
    }

    func testMaskedFramesAtEveryLengthBoundary() throws {
        for n in [0, 1, 125, 126, 127, 65535, 65536, 100_000] {
            let data = payload(n)
            let bytes = WebSocketFrame.encodeMasked(opcode: WebSocketFrame.opcodeBinary, payload: data, key: key)
            let headerLength = n < 126 ? 6 : (n <= 0xFFFF ? 8 : 14)
            XCTAssertEqual(bytes.count, headerLength + n, "header size for \(n)")
            let parsed = try XCTUnwrap(try parse(bytes + [0xFF, 0xEE]), "length \(n)")
            XCTAssertEqual(parsed.consumed, bytes.count, "consumed for \(n)")
            XCTAssertEqual(parsed.frame.payload, data, "payload for \(n)")
            XCTAssertEqual(parsed.frame.opcode, WebSocketFrame.opcodeBinary)
            XCTAssertTrue(parsed.frame.fin)
        }
        // The length encodings themselves.
        XCTAssertEqual(Array(WebSocketFrame.encodeMasked(opcode: 2, payload: payload(125), key: key).prefix(2)), [0x82, 0xFD])
        XCTAssertEqual(Array(WebSocketFrame.encodeMasked(opcode: 2, payload: payload(126), key: key).prefix(4)), [0x82, 0xFE, 0x00, 0x7E])
        XCTAssertEqual(Array(WebSocketFrame.encodeMasked(opcode: 2, payload: payload(65535), key: key).prefix(4)), [0x82, 0xFE, 0xFF, 0xFF])
        XCTAssertEqual(Array(WebSocketFrame.encodeMasked(opcode: 2, payload: payload(65536), key: key).prefix(10)), [0x82, 0xFF, 0, 0, 0, 0, 0, 1, 0, 0])
    }

    func testIncompleteFramesReturnNilWithoutTouchingTheBuffer() throws {
        let full = WebSocketFrame.encodeMasked(opcode: WebSocketFrame.opcodeBinary, payload: payload(300), key: key)
        for cut in [0, 1, 2, 3, 5, 7, 8, 100, full.count - 1] {
            var buffer = Array(full.prefix(cut))
            let copy = buffer
            XCTAssertNil(try WebSocketFrame.parse(&buffer, maxPayload: 1_000_000), "cut at \(cut)")
            XCTAssertEqual(buffer, copy)
        }
        XCTAssertNotNil(try parse(full))
    }

    func testFrameSplitAcrossReadsThenCompletes() throws {
        let frame = WebSocketFrame.encodeMasked(opcode: WebSocketFrame.opcodeBinary, payload: payload(2000), key: key)
        var buffer: [UInt8] = []
        var result: (frame: WebSocketFrame, consumed: Int)?
        var offset = 0
        while result == nil {
            let end = min(frame.count, offset + 333)
            buffer.append(contentsOf: frame[offset..<end])
            offset = end
            result = try WebSocketFrame.parse(&buffer, maxPayload: 1_000_000)
            if offset == frame.count { break }
        }
        let r = try XCTUnwrap(result)
        XCTAssertEqual(r.consumed, frame.count)
        XCTAssertEqual(r.frame.payload, payload(2000))
    }

    func testTwoFramesInOneBuffer() throws {
        let a = WebSocketFrame.encodeMasked(opcode: WebSocketFrame.opcodeBinary, payload: [1, 2, 3], key: key)
        let b = WebSocketFrame.encodeMasked(opcode: WebSocketFrame.opcodePing, payload: [9], key: key)
        var buffer = a + b
        let first = try XCTUnwrap(try WebSocketFrame.parse(&buffer, maxPayload: 100))
        XCTAssertEqual(first.frame.payload, [1, 2, 3])
        buffer.removeFirst(first.consumed)
        let second = try XCTUnwrap(try WebSocketFrame.parse(&buffer, maxPayload: 100))
        XCTAssertEqual(second.frame.opcode, WebSocketFrame.opcodePing)
        XCTAssertEqual(second.frame.payload, [9])
        buffer.removeFirst(second.consumed)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testFragmentationFlagsAndReassembly() throws {
        let part1 = WebSocketFrame.encodeMasked(fin: false, opcode: WebSocketFrame.opcodeBinary, payload: [1, 2], key: key)
        let part2 = WebSocketFrame.encodeMasked(fin: false, opcode: WebSocketFrame.opcodeContinuation, payload: [3], key: key)
        let ping = WebSocketFrame.encodeMasked(opcode: WebSocketFrame.opcodePing, payload: [], key: key)
        let part3 = WebSocketFrame.encodeMasked(fin: true, opcode: WebSocketFrame.opcodeContinuation, payload: [4, 5], key: key)
        let f1 = try XCTUnwrap(try parse(part1)).frame
        XCTAssertFalse(f1.fin)
        XCTAssertEqual(f1.opcode, WebSocketFrame.opcodeBinary)
        let f2 = try XCTUnwrap(try parse(part2)).frame
        XCTAssertEqual(f2.opcode, WebSocketFrame.opcodeContinuation)
        let fp = try XCTUnwrap(try parse(ping)).frame
        let f3 = try XCTUnwrap(try parse(part3)).frame
        XCTAssertTrue(f3.fin)

        var assembler = WebSocketMessageAssembler(maxMessage: 1000)
        XCTAssertNil(try assembler.accept(f1))
        XCTAssertTrue(assembler.isAssembling)
        XCTAssertNil(try assembler.accept(f2))
        XCTAssertEqual(try assembler.accept(fp), fp, "control frames interleave")
        let message = try XCTUnwrap(try assembler.accept(f3))
        XCTAssertEqual(message, WebSocketFrame(fin: true, opcode: WebSocketFrame.opcodeBinary, payload: [1, 2, 3, 4, 5]))
        XCTAssertFalse(assembler.isAssembling)
        // Unfragmented frames pass straight through.
        let whole = WebSocketFrame(fin: true, opcode: WebSocketFrame.opcodeBinary, payload: [7])
        XCTAssertEqual(try assembler.accept(whole), whole)
        // Errors.
        XCTAssertThrowsError(try assembler.accept(f2)) { XCTAssertEqual($0 as? WebSocketError, .badContinuation) }
        var a2 = WebSocketMessageAssembler(maxMessage: 1000)
        _ = try a2.accept(f1)
        XCTAssertThrowsError(try a2.accept(f1)) { XCTAssertEqual($0 as? WebSocketError, .badContinuation) }
        var small = WebSocketMessageAssembler(maxMessage: 3)
        _ = try small.accept(f1)
        XCTAssertThrowsError(try small.accept(f3)) { XCTAssertEqual($0 as? WebSocketError, .oversize(4)) }
    }

    func testControlFrames() throws {
        let close = WebSocketFrame.encodeMasked(opcode: WebSocketFrame.opcodeClose, payload: [0x03, 0xE8, 0x62, 0x79, 0x65], key: key)
        let frame = try XCTUnwrap(try parse(close)).frame
        XCTAssertTrue(frame.isControl)
        XCTAssertEqual(WebSocketFrame.closeCode(frame.payload), 1000)
        XCTAssertEqual(Array(frame.payload[2...]), Array("bye".utf8))
        XCTAssertNil(WebSocketFrame.closeCode([0x03]))
        let pong = WebSocketFrame.encodeMasked(opcode: WebSocketFrame.opcodePong, payload: payload(125), key: key)
        XCTAssertEqual(try XCTUnwrap(try parse(pong)).frame.payload.count, 125)
        // Control frames above 125 bytes and fragmented control frames are rejected.
        let long = WebSocketFrame.encodeMasked(opcode: WebSocketFrame.opcodePing, payload: payload(126), key: key)
        XCTAssertThrowsError(try parse(long)) { XCTAssertEqual($0 as? WebSocketError, .controlFrameTooLong) }
        let fragmented = WebSocketFrame.encodeMasked(fin: false, opcode: WebSocketFrame.opcodePing, payload: [1], key: key)
        XCTAssertThrowsError(try parse(fragmented)) { XCTAssertEqual($0 as? WebSocketError, .fragmentedControl) }
    }

    func testOversizeRejectedFromTheHeader() throws {
        // A 16-bit length over the cap fails before the payload arrives.
        let header: [UInt8] = [0x82, 0xFE, 0x10, 0x00, 1, 2, 3, 4]
        XCTAssertThrowsError(try parse(header, maxPayload: 4095)) { XCTAssertEqual($0 as? WebSocketError, .oversize(4096)) }
        // A 64-bit length of 2 MiB + 1 against the 2 MiB cap.
        let big = 2 * 1024 * 1024 + 1
        var header64: [UInt8] = [0x82, 0xFF]
        for i in (0..<8).reversed() { header64.append(UInt8(truncatingIfNeeded: UInt64(big) >> (8 * UInt64(i)))) }
        XCTAssertThrowsError(try parse(header64)) { XCTAssertEqual($0 as? WebSocketError, .oversize(big)) }
        // The top bit of a 64-bit length is never valid.
        let absurd: [UInt8] = [0x82, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertThrowsError(try parse(absurd)) { XCTAssertEqual($0 as? WebSocketError, .oversize(Int.max)) }
        // Exactly the cap is fine.
        let ok = WebSocketFrame.encodeMasked(opcode: 2, payload: payload(4096), key: key)
        XCTAssertNotNil(try parse(ok, maxPayload: 4096))
    }

    func testReservedBitsAndUnmaskedClientFrames() {
        for rsv: UInt8 in [0x40, 0x20, 0x10, 0x70] {
            let bytes: [UInt8] = [0x82 | rsv, 0x81, 1, 2, 3, 4, 0x55]
            XCTAssertThrowsError(try parse(bytes)) { XCTAssertEqual($0 as? WebSocketError, .reservedBits) }
        }
        let unmasked: [UInt8] = [0x82, 0x03, 1, 2, 3]
        XCTAssertThrowsError(try parse(unmasked)) { XCTAssertEqual($0 as? WebSocketError, .unmaskedClientFrame) }
        // A server-encoded frame is unmasked by design, so the parser (a server) refuses it.
        let server = WebSocketFrame.encode(opcode: WebSocketFrame.opcodeBinary, payload: [1, 2, 3])
        XCTAssertEqual(server, [0x82, 0x03, 1, 2, 3])
        XCTAssertThrowsError(try parse(server))
    }

    func testServerEncoding() {
        XCTAssertEqual(WebSocketFrame.encode(opcode: 2, payload: payload(126)).prefix(4), [0x82, 126, 0x00, 0x7E])
        XCTAssertEqual(WebSocketFrame.encode(opcode: 2, payload: payload(65536)).prefix(10), [0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0])
        let close = WebSocketFrame.encodeClose(code: 1009, reason: "too big")
        XCTAssertEqual(Array(close.prefix(4)), [0x88, 9, 0x03, 0xF1])
        XCTAssertEqual(WebSocketFrame.closeCode(Array(close[2...])), 1009)
        let longReason = WebSocketFrame.encodeClose(code: 1002, reason: String(repeating: "x", count: 500))
        XCTAssertEqual(longReason[1], 125, "close payload capped at 125 bytes")
    }
}
