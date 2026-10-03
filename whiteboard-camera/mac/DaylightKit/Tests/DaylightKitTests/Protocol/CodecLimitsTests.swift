import Foundation
import XCTest
import DaylightKit

/// PROTOCOL sections 6, 9 and 10 beyond the golden file: ACK statuses 2 and 3, the "read the first 20 bytes" STATE rule,
/// the size limits, the rejected 26-byte STROKE_START, and odd-offset point reads.
final class CodecLimitsTests: XCTestCase {
    private let ts: UInt64 = 1_760_000_000_123_456

    private func frame(_ opcode: UInt16, _ payload: [UInt8]) -> [UInt8] {
        var w = ByteWriter()
        w.u8(SolStream.magic)
        w.u8(SolStream.version)
        w.u16(opcode)
        w.u32(UInt32(payload.count))
        w.u64(ts)
        w.bytes(payload)
        return w.storage
    }

    func testAckDeniedAndUnsupportedRoundTrip() throws {
        let denied = Codec.encode(.handshakeAck(width: 1920, height: 1080, fps: 30, status: .denied), timestampUs: ts)
        XCTAssertEqual(Hex.encode(denied), "da0102001000000040e2cfeeb540060080070000380400001e00000002000000")
        XCTAssertEqual(try Codec.decode(denied).1, .handshakeAck(width: 1920, height: 1080, fps: 30, status: .denied))
        let unsupported = Codec.encode(.handshakeAck(width: 1920, height: 1080, fps: 30, status: .unsupported), timestampUs: ts)
        XCTAssertEqual(Hex.encode(unsupported), "da0102001000000040e2cfeeb540060080070000380400001e00000003000000")
        XCTAssertEqual(try Codec.decode(unsupported).1, .handshakeAck(width: 1920, height: 1080, fps: 30, status: .unsupported))
        var bad = unsupported
        bad[28] = 9
        XCTAssertThrowsError(try Codec.decode(bad)) {
            XCTAssertEqual($0 as? CodecError, .badPayload(opcode: 2, reason: "unknown ack status 9"))
        }
    }

    func testStateLongerThan20BytesReadsTheFirst20() throws {
        let report = StateReport(governor: 2, flags: 0x0D, mode: 0, inkSource: 1, progress: 1.0, msToReturn: 0xFFFF_FFFF, pageIndex: 0, strokeCount: 3, undoDepth: 3, redoDepth: 0)
        var payload = Array(Codec.encode(.state(report), timestampUs: ts)[16...])
        XCTAssertEqual(payload.count, 20)
        payload += [0xAA, 0xBB, 0xCC, 0xDD]   // a v1-compatible appended field
        let (header, message) = try Codec.decode(frame(0x0070, payload))
        XCTAssertEqual(header.payloadLength, 24)
        XCTAssertEqual(message, .state(report))
        XCTAssertThrowsError(try Codec.decode(frame(0x0070, Array(payload.prefix(19))))) {
            XCTAssertEqual($0 as? CodecError, .badPayload(opcode: 0x70, reason: "state shorter than 20 bytes"))
        }
    }

    func testHandshakeNameLimits() {
        func handshake(nameLength: Int, declared: Int? = nil) -> [UInt8] {
            var w = ByteWriter()
            w.f32(1200)
            w.f32(1600)
            w.f32(200)
            w.u16(UInt16(declared ?? nameLength))
            w.bytes([UInt8](repeating: 0x61, count: nameLength))
            return frame(0x0001, w.storage)
        }
        XCTAssertThrowsError(try Codec.decode(handshake(nameLength: 0))) {
            XCTAssertEqual($0 as? CodecError, .limitExceeded(opcode: 1, value: 0, max: 200))
        }
        XCTAssertThrowsError(try Codec.decode(handshake(nameLength: 201))) {
            XCTAssertEqual($0 as? CodecError, .limitExceeded(opcode: 1, value: 201, max: 200))
        }
        XCTAssertNoThrow(try Codec.decode(handshake(nameLength: 200)))
        XCTAssertThrowsError(try Codec.decode(handshake(nameLength: 10, declared: 12))) {
            XCTAssertEqual($0 as? CodecError, .badPayload(opcode: 1, reason: "name_len 12 but 10 bytes follow"))
        }
        XCTAssertThrowsError(try Codec.decode(frame(0x0001, [1, 2, 3])))
    }

    func testChunkAndEraseLimits() {
        var chunk = ByteWriter()
        chunk.uuid(UUID())
        chunk.u16(4097)
        chunk.bytes([UInt8](repeating: 0, count: 11 * 4097))
        XCTAssertThrowsError(try Codec.decode(frame(0x0011, chunk.storage))) {
            XCTAssertEqual($0 as? CodecError, .limitExceeded(opcode: 0x11, value: 4097, max: 4096))
        }
        var full = ByteWriter()
        full.uuid(UUID())
        full.u16(4096)
        full.bytes([UInt8](repeating: 0, count: 11 * 4096))
        XCTAssertNoThrow(try Codec.decode(frame(0x0011, full.storage)), "4096 points is the limit, not over it")
        var short = ByteWriter()
        short.uuid(UUID())
        short.u16(2)
        short.bytes([UInt8](repeating: 0, count: 11))
        XCTAssertThrowsError(try Codec.decode(frame(0x0011, short.storage))) {
            XCTAssertEqual($0 as? CodecError, .badPayload(opcode: 0x11, reason: "count 2 needs 22 bytes, have 11"))
        }
        var erase = ByteWriter()
        for _ in 0..<5 { erase.f32(1) }
        erase.u16(1025)
        erase.bytes([UInt8](repeating: 0, count: 16 * 1025))
        XCTAssertThrowsError(try Codec.decode(frame(0x0020, erase.storage))) {
            XCTAssertEqual($0 as? CodecError, .limitExceeded(opcode: 0x20, value: 1025, max: 1024))
        }
        var empty = ByteWriter()
        for _ in 0..<5 { empty.f32(1) }
        empty.u16(0)
        XCTAssertEqual(try Codec.decode(frame(0x0020, empty.storage)).1, .eraseStrokes(x1: 1, y1: 1, x2: 1, y2: 1, radius: 1, ids: []), "an empty id list is legal")
    }

    func testPayloadOverOneMiBIsALimitError() {
        var w = ByteWriter()
        w.u8(SolStream.magic)
        w.u8(SolStream.version)
        w.u16(0x0011)
        w.u32(UInt32(SolStream.maxPayload + 1))
        w.u64(ts)
        XCTAssertThrowsError(try w.storage.withUnsafeBytes { try Codec.decodeHeader($0) }) {
            XCTAssertEqual($0 as? CodecError, .limitExceeded(opcode: 0x11, value: SolStream.maxPayload + 1, max: SolStream.maxPayload))
        }
    }

    func testOracle26ByteStrokeStartIsRejected() {
        var w = ByteWriter()
        w.uuid(UUID())
        w.u16(0)          // the oracle's <16sHIf form
        w.u32(0xFF11_1111)
        w.f32(3.2)
        XCTAssertEqual(w.count, 26)
        XCTAssertThrowsError(try Codec.decode(frame(0x0010, w.storage))) {
            XCTAssertEqual($0 as? CodecError, .badPayload(opcode: 0x10, reason: "payload is 26 bytes, expected [25, 31]"))
        }
    }

    func testBadEnumValuesAreBadPayload() {
        var w = ByteWriter()
        w.uuid(UUID())
        w.u8(7)   // unknown tool
        w.u32(0)
        w.f32(1)
        w.u8(0)
        w.u8(1)
        w.f32(1)
        XCTAssertThrowsError(try Codec.decode(frame(0x0010, w.storage))) {
            XCTAssertEqual($0 as? CodecError, .badPayload(opcode: 0x10, reason: "unknown tool 7"))
        }
        var pin = ByteWriter()
        pin.i8(2)
        pin.u64(ts)
        XCTAssertThrowsError(try Codec.decode(frame(0x0061, pin.storage))) {
            XCTAssertEqual($0 as? CodecError, .badPayload(opcode: 0x61, reason: "pin value 2 not in -1...1"))
        }
    }

    func testOddOffsetPointReadsAssembleBytes() throws {
        // Points start at offset 16 + 18 = 34 and are 11 bytes each, so the second point's i32 fields sit at odd offsets.
        let points = [SolStream.Point(x32: 0x0102_0304, y32: -2, pressure: 200, deltaMs: 0x1234), SolStream.Point(x32: Int32.min, y32: Int32.max, pressure: 0, deltaMs: 65535)]
        let id = UUID()
        let bytes = Codec.encode(.strokeChunk(id: id, points: points), timestampUs: ts)
        // Shift the whole frame by one byte inside a larger buffer and decode through a rebased pointer.
        let shifted = [UInt8(0)] + bytes
        let decoded = try shifted.withUnsafeBytes { raw -> (Header, Message) in
            try Codec.decode(UnsafeRawBufferPointer(rebasing: raw[1...]))
        }
        XCTAssertEqual(decoded.1, .strokeChunk(id: id, points: points))
        XCTAssertEqual(decoded.0.timestampUs, ts)
    }

    func testEncodeIntoAppendsToAReusableBuffer() {
        var out: [UInt8] = [0xEE]
        Codec.encode(.ping(sequence: 7, clientTimeUs: ts), timestampUs: ts, into: &out)
        Codec.encode(.pong(sequence: 7, clientTimeUs: ts), timestampUs: ts, into: &out)
        XCTAssertEqual(out.count, 1 + 32 + 32)
        XCTAssertEqual(Hex.encode(Array(out[1..<33])), "da01fe001000000040e2cfeeb5400600070000000000000040e2cfeeb5400600")
        XCTAssertEqual(Hex.encode(Array(out[33...])), "da01ff001000000040e2cfeeb5400600070000000000000040e2cfeeb5400600")
    }

    func testConstants() {
        XCTAssertEqual(SolStream.serviceType, "_daylight-camera._tcp")
        XCTAssertEqual(SolStream.serviceType.dropFirst().split(separator: ".").first?.count, 15, "exactly 15 characters after the underscore (Bonjour limit)")
        XCTAssertEqual(SolStream.subprotocol, "solstream.v1")
        XCTAssertEqual(SolStream.defaultPort, 7788)
        XCTAssertEqual(SolStream.headerLength, 16)
        XCTAssertEqual(SolStream.pointLength, 11)
        XCTAssertEqual(SolStream.maxPayload, 1_048_576)
        XCTAssertEqual(SolStream.canvasWidth, 1200)
        XCTAssertEqual(SolStream.canvasHeight, 1600)
        XCTAssertEqual(SolStream.targetFPS, 30)
        XCTAssertEqual(SolStream.Opcode.undo.rawValue, 0x0014)
        XCTAssertEqual(SolStream.Opcode.redo.rawValue, 0x0015)
        XCTAssertEqual(SolStream.Opcode.state.rawValue, 0x0070)
        XCTAssertEqual(SolStream.Opcode.togglePin.rawValue, 0x0061)
        XCTAssertNil(SolStream.Opcode(rawValue: 0x0003), "CLIENT_HELLO was rejected")
    }
}
