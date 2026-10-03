import Foundation
import XCTest
import DaylightKit

/// Every case in protocol/golden/solstream-v1.json decodes to the right message and, unless decode-only,
/// re-encodes byte for byte (docs/PROTOCOL.md section 12 test contract).
final class GoldenVectorTests: XCTestCase {
    struct Manifest: Decodable {
        let version: Int
        let timestamp_us: UInt64
        let stroke_id: String
        let page_id: String
        let websocket: WebSocketVectors
        let cases: [Case]
    }

    struct WebSocketVectors: Decodable {
        let sha1_abc: String
        let key: String
        let accept: String
    }

    struct Case: Decodable {
        let name: String
        let opcode: UInt16
        let direction: String
        let decode_only: Bool
        let hex: String
    }

    private func loadManifest() throws -> Manifest {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "solstream-v1", withExtension: "json"), "golden manifest missing from the test bundle")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private func vector(_ name: String, in manifest: Manifest) throws -> Case {
        return try XCTUnwrap(manifest.cases.first { $0.name == name }, "no golden case named \(name)")
    }

    private func decode(_ c: Case) throws -> (Header, Message) {
        let bytes = try XCTUnwrap(Hex.decode(c.hex), "bad hex in case \(c.name)")
        return try Codec.decode(bytes)
    }

    func testManifestShape() throws {
        let m = try loadManifest()
        XCTAssertEqual(m.version, 1)
        XCTAssertEqual(m.timestamp_us, 1_760_000_000_123_456)
        XCTAssertEqual(m.cases.count, 26)
        XCTAssertEqual(m.stroke_id, "00010203-0405-0607-0809-0a0b0c0d0e0f")
    }

    func testEveryCaseDecodesAndRoundTrips() throws {
        let m = try loadManifest()
        for c in m.cases {
            let bytes = try XCTUnwrap(Hex.decode(c.hex), c.name)
            let (header, message) = try Codec.decode(bytes)
            XCTAssertEqual(header.opcode, c.opcode, c.name)
            XCTAssertEqual(message.opcode.rawValue, c.opcode, c.name)
            XCTAssertEqual(header.timestampUs, m.timestamp_us, c.name)
            XCTAssertEqual(Int(header.payloadLength), bytes.count - SolStream.headerLength, c.name)
            if !c.decode_only {
                let encoded = Codec.encode(message, timestampUs: header.timestampUs)
                XCTAssertEqual(Hex.encode(encoded), c.hex, "re-encode of \(c.name) differs")
            }
        }
    }

    func testStrokeChunkPointsAndDeltaSaturation() throws {
        let m = try loadManifest()
        let (_, message) = try decode(try vector("stroke_chunk_3pts", in: m))
        guard case let .strokeChunk(id, points) = message else { return XCTFail("not a stroke chunk: \(message)") }
        XCTAssertEqual(id.uuidString.lowercased(), m.stroke_id)
        XCTAssertEqual(points, [
            SolStream.Point(x32: 336, y32: -104, pressure: 186, deltaMs: 0),
            SolStream.Point(x32: 3200, y32: 6408, pressure: 51, deltaMs: 8),
            SolStream.Point(x32: 38399, y32: 51168, pressure: 255, deltaMs: 65535),
        ])
        XCTAssertEqual(points[0].x, 10.5)
        XCTAssertEqual(points[0].y, -3.25)
        XCTAssertEqual(SolStream.Point(x: 1199.96875, y: 1599.0, pressure: 1.0, deltaMs: 70000), points[2])
    }

    func testHandshakeNameIsUTF8AndParsesAsIdentity() throws {
        let m = try loadManifest()
        let (_, message) = try decode(try vector("handshake", in: m))
        guard case let .handshake(w, h, dpi, name) = message else { return XCTFail("not a handshake") }
        XCTAssertEqual(w, 1200)
        XCTAssertEqual(h, 1600)
        XCTAssertEqual(dpi, 200)
        XCTAssertEqual(name, "web;6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b;Mike\u{2019}s DC-1")
        let identity = try XCTUnwrap(Identity(name: name))
        XCTAssertEqual(identity.role, .web)
        XCTAssertEqual(identity.clientID, "6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b")
        XCTAssertEqual(identity.label, "Mike\u{2019}s DC-1")
        XCTAssertNil(Identity(name: "no-semicolons"))
    }

    func testLegacy25ByteStrokeStartDefaults() throws {
        let m = try loadManifest()
        let (_, message) = try decode(try vector("stroke_start_legacy25", in: m))
        guard case let .strokeStart(s) = message else { return XCTFail("not a stroke start") }
        XCTAssertEqual(s.tool, .pen)
        XCTAssertEqual(s.colorARGB, 0xFF11_1111)
        XCTAssertEqual(s.baseWidth, 3.2, accuracy: 1e-6)
        XCTAssertEqual(s.pointer, .stylus)
        XCTAssertEqual(s.phase, .contact)
        XCTAssertEqual(s.pressure, 0.5)
        XCTAssertTrue(s.engages)
    }

    func testStateLivePinnedFields() throws {
        let m = try loadManifest()
        let (_, message) = try decode(try vector("state_live_pinned", in: m))
        guard case let .state(s) = message else { return XCTFail("not a state") }
        XCTAssertEqual(s.governor, GovernorState.live.rawValue)
        XCTAssertEqual(s.flags, 0x0D)
        XCTAssertTrue(s.flagSet.contains(.pinned))
        XCTAssertTrue(s.flagSet.contains(.clientAllowed))
        XCTAssertTrue(s.flagSet.contains(.clientIsActiveSource))
        XCTAssertFalse(s.flagSet.contains(.preWarning))
        XCTAssertEqual(s.mode, HoldMode.auto.rawValue)
        XCTAssertEqual(s.inkSource, InkSource.native.rawValue)
        XCTAssertEqual(s.progress, 1.0)
        XCTAssertEqual(s.msToReturn, StateReport.noReturnScheduled)
        XCTAssertEqual(s.strokeCount, 3)
        XCTAssertEqual(s.undoDepth, 3)
        XCTAssertEqual(s.redoDepth, 0)
    }

    func testClearCanvasEmptyFormMeansCurrentPage() throws {
        let m = try loadManifest()
        let (_, message) = try decode(try vector("clear_canvas_empty", in: m))
        XCTAssertEqual(message, .clearCanvas(pageID: nil, clientTimeUs: nil))
    }

    func testMalformedInputs() throws {
        let m = try loadManifest()
        let commit = try XCTUnwrap(Hex.decode(try vector("stroke_commit", in: m).hex))

        var badMagic = commit
        badMagic[0] = 0x00
        XCTAssertThrowsError(try Codec.decode(badMagic)) { XCTAssertEqual($0 as? CodecError, .badMagic(0)) }

        var badVersion = commit
        badVersion[1] = 0x02
        XCTAssertThrowsError(try Codec.decode(badVersion)) { XCTAssertEqual($0 as? CodecError, .badVersion(2)) }

        let truncated = Array(commit.prefix(10))
        XCTAssertThrowsError(try Codec.decode(truncated)) { XCTAssertEqual($0 as? CodecError, .truncated(needed: 16, have: 10)) }

        let shortByOne = Array(commit.dropLast())
        XCTAssertThrowsError(try Codec.decode(shortByOne)) { XCTAssertEqual($0 as? CodecError, .lengthMismatch(declared: 20, actual: 19)) }

        var unknown = try XCTUnwrap(Hex.decode(try vector("ping", in: m).hex))
        unknown[2] = 0x7F
        unknown[3] = 0x00
        XCTAssertThrowsError(try Codec.decode(unknown)) { XCTAssertEqual($0 as? CodecError, .unknownOpcode(0x007F)) }
        let lenient = try unknown.withUnsafeBytes { try Codec.decodeLenient($0) }
        XCTAssertEqual(lenient.0.opcode, 0x007F)
        XCTAssertNil(lenient.1)

        // A chunk with count 0 is a limit violation, not a crash.
        var emptyChunk: [UInt8] = []
        var writer = ByteWriter()
        writer.u8(SolStream.magic)
        writer.u8(SolStream.version)
        writer.u16(SolStream.Opcode.strokeChunk.rawValue)
        writer.u32(18)
        writer.u64(0)
        writer.uuid(UUID())
        writer.u16(0)
        emptyChunk = writer.storage
        XCTAssertThrowsError(try Codec.decode(emptyChunk)) {
            XCTAssertEqual($0 as? CodecError, .limitExceeded(opcode: 0x0011, value: 0, max: SolStream.maxPointsPerChunk))
        }
    }

    func testWebSocketAcceptKeyAndSHA1() throws {
        let m = try loadManifest()
        XCTAssertEqual(Hex.encode(SHA1.hash(Array("abc".utf8))), m.websocket.sha1_abc)
        XCTAssertEqual(HTTPRequest.webSocketAccept(forKey: m.websocket.key), m.websocket.accept)
        // A message longer than one SHA-1 block exercises the chunk loop.
        let long = Array(String(repeating: "a", count: 1000).utf8)
        XCTAssertEqual(Hex.encode(SHA1.hash(long)), "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }
}
