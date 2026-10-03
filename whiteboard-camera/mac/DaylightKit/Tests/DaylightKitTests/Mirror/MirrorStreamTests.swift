import Foundation
import XCTest
import DaylightKit

/// PROTOCOL 14 (mirror stream family): every `mirror_cases` golden vector decodes to its fields and, unless decode-only,
/// re-encodes byte for byte; the HELLO and PACKET payloads demux as one scrcpy 4.1 stream; the hand-written edge cases.
final class MirrorStreamTests: XCTestCase {
    struct Manifest: Decodable {
        let version: Int
        let timestamp_us: UInt64
        let mirror_cases: [Case]
    }

    struct Fields: Decodable {
        let device_name: String?
        let codec_id: UInt32?
        let kind: String?
        let width: UInt32?
        let height: UInt32?
        let pts_us: UInt64?
        let key_frame: Bool?
        let annex_b: String?
        let state: UInt8?
        let flags: UInt8?
        let fps_x10: UInt16?
        let bitrate_bps: UInt32?
        let sent_bps: UInt32?
        let command: UInt8?
        let max_size: UInt16?
        let max_fps: UInt16?
        let key_interval_ms: UInt16?
    }

    struct Case: Decodable {
        let name: String
        let opcode: UInt16
        let direction: String
        let decode_only: Bool
        let hex: String
        let fields: Fields
    }

    private func loadManifest() throws -> Manifest {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "solstream-v1", withExtension: "json"), "golden manifest missing from the test bundle")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private func bytes(_ c: Case) throws -> [UInt8] {
        return try XCTUnwrap(Hex.decode(c.hex), "bad hex in case \(c.name)")
    }

    /// The message a case's `fields` describe.
    private func expectedMessage(_ c: Case) throws -> MirrorStream.Message {
        let f = c.fields
        switch c.opcode {
        case MirrorStream.opcodeHello:
            return .hello(deviceName: try XCTUnwrap(f.device_name), codecID: try XCTUnwrap(f.codec_id))
        case MirrorStream.opcodePacket:
            let kind = try XCTUnwrap(f.kind, c.name)
            if kind == "session" {
                return .packet(.session(width: try XCTUnwrap(f.width), height: try XCTUnwrap(f.height)))
            }
            let annexB = try XCTUnwrap(Hex.decode(try XCTUnwrap(f.annex_b)), c.name)
            let pts = try XCTUnwrap(f.pts_us)
            if kind == "config" {
                return .packet(.config(ptsUs: pts, annexB: annexB))
            }
            XCTAssertEqual(kind, "frame", c.name)
            return .packet(.frame(ptsUs: pts, keyFrame: try XCTUnwrap(f.key_frame), annexB: annexB))
        case MirrorStream.opcodeStatus:
            let state = try XCTUnwrap(MirrorStream.State(rawValue: try XCTUnwrap(f.state)), c.name)
            let status = MirrorStream.Status(
                state: state,
                flags: MirrorStream.StatusFlags(rawValue: try XCTUnwrap(f.flags)),
                fpsX10: try XCTUnwrap(f.fps_x10),
                width: UInt16(try XCTUnwrap(f.width)),
                height: UInt16(try XCTUnwrap(f.height)),
                bitrateBps: try XCTUnwrap(f.bitrate_bps),
                sentBps: try XCTUnwrap(f.sent_bps)
            )
            return .status(status)
        default:
            XCTAssertEqual(c.opcode, MirrorStream.opcodeControl, c.name)
            let command = try XCTUnwrap(MirrorStream.Command(rawValue: try XCTUnwrap(f.command)), c.name)
            let control = MirrorStream.Control(
                command: command,
                maxSize: try XCTUnwrap(f.max_size),
                bitrateBps: try XCTUnwrap(f.bitrate_bps),
                maxFps: try XCTUnwrap(f.max_fps),
                keyIntervalMs: try XCTUnwrap(f.key_interval_ms)
            )
            return .control(control)
        }
    }

    // MARK: Golden vectors (PROTOCOL 14.6)

    func testMirrorCasesShape() throws {
        let m = try loadManifest()
        XCTAssertEqual(m.version, 1)
        XCTAssertEqual(m.mirror_cases.map { $0.name }, [
            "mirror_hello", "mirror_packet_session", "mirror_packet_config", "mirror_packet_key_frame", "mirror_packet_delta",
            "mirror_status_streaming", "mirror_status_consent_denied", "mirror_control_start", "mirror_control_stop",
            "mirror_control_key_frame",
        ])
        for c in m.mirror_cases {
            XCTAssertTrue(MirrorStream.isMirrorOpcode(c.opcode), c.name)
            XCTAssertEqual(c.direction, c.opcode == MirrorStream.opcodeControl ? "s2c" : "c2s", c.name)
        }
    }

    func testEveryMirrorCaseDecodesToItsFieldsAndRoundTrips() throws {
        let m = try loadManifest()
        for c in m.mirror_cases {
            let frame = try bytes(c)
            XCTAssertEqual(MirrorStream.peekOpcode(frame), c.opcode, c.name)
            let decoded = try MirrorStream.decode(frame)
            XCTAssertEqual(decoded.timestampUs, m.timestamp_us, c.name)
            XCTAssertEqual(decoded.message, try expectedMessage(c), c.name)
            XCTAssertEqual(decoded.message.opcode, c.opcode, c.name)
            if !c.decode_only {
                XCTAssertEqual(Hex.encode(MirrorStream.encode(decoded.message, timestampUs: m.timestamp_us)), c.hex, "re-encode of \(c.name) differs")
                XCTAssertEqual(Hex.encode(MirrorStream.encode(try expectedMessage(c), timestampUs: m.timestamp_us)), c.hex, "encode from the fields of \(c.name) differs")
            }
        }
    }

    func testGoldenFieldValues() throws {
        let m = try loadManifest()
        let byName = Dictionary(uniqueKeysWithValues: m.mirror_cases.map { ($0.name, $0) })
        let hello = try MirrorStream.decode(try bytes(try XCTUnwrap(byName["mirror_hello"])))
        XCTAssertEqual(hello.message, .hello(deviceName: "DC-1", codecID: 0x6832_3634))
        XCTAssertEqual(try bytes(try XCTUnwrap(byName["mirror_hello"])).count, 16 + 68)
        let session = try MirrorStream.decode(try bytes(try XCTUnwrap(byName["mirror_packet_session"])))
        XCTAssertEqual(session.message, .packet(.session(width: 1200, height: 1600)))
        let status = try MirrorStream.decode(try bytes(try XCTUnwrap(byName["mirror_status_streaming"])))
        XCTAssertEqual(status.message, .status(MirrorStream.Status(state: .streaming, flags: .projectionHeld, fpsX10: 300, width: 1200, height: 1600, bitrateBps: 7_000_000, sentBps: 6_543_210)))
        let denied = try MirrorStream.decode(try bytes(try XCTUnwrap(byName["mirror_status_consent_denied"])))
        XCTAssertEqual(denied.message, .status(MirrorStream.Status(state: .consentDenied, bitrateBps: 7_000_000)))
        let start = try MirrorStream.decode(try bytes(try XCTUnwrap(byName["mirror_control_start"])))
        XCTAssertEqual(start.message, .control(.start(maxSize: 1600, bitrateBps: 7_000_000, maxFps: 30, keyIntervalMs: 2000)))
        let stop = try MirrorStream.decode(try bytes(try XCTUnwrap(byName["mirror_control_stop"])))
        XCTAssertEqual(stop.message, .control(.stop))
        let key = try MirrorStream.decode(try bytes(try XCTUnwrap(byName["mirror_control_key_frame"])))
        XCTAssertEqual(key.message, .control(.requestKeyFrame))
        XCTAssertEqual(Hex.encode(MirrorStream.encode(.control(.stop), timestampUs: m.timestamp_us)), try XCTUnwrap(byName["mirror_control_stop"]).hex)
    }

    /// PROTOCOL 14: the concatenated payloads of HELLO, session, config, key and delta are one scrcpy 4.1 video stream
    /// for `ScrcpyDemuxer(expectsDummyByte: false)`.
    func testHelloAndPacketsDemuxAsOneScrcpyStream() throws {
        let m = try loadManifest()
        let names = ["mirror_hello", "mirror_packet_session", "mirror_packet_config", "mirror_packet_key_frame", "mirror_packet_delta"]
        var stream: [UInt8] = []
        for name in names {
            let c = try XCTUnwrap(m.mirror_cases.first { $0.name == name }, name)
            let message = try MirrorStream.decode(try bytes(c)).message
            let scrcpy = try XCTUnwrap(MirrorStream.scrcpyBytes(message), name)
            let frame = try bytes(c)
            XCTAssertEqual(scrcpy, Array(frame[16...]), "\(name): the scrcpy bytes are the whole payload")
            stream += scrcpy
        }
        var demuxer = ScrcpyDemuxer(expectsDummyByte: false)
        var out: [ScrcpyPacket] = []
        try demuxer.feed(stream) { out.append($0) }
        let config: [UInt8] = try XCTUnwrap(Hex.decode("0000000167428028da0280bf0000000168ce3c80"))
        let key: [UInt8] = try XCTUnwrap(Hex.decode("0000000165888400ffaa"))
        let delta: [UInt8] = try XCTUnwrap(Hex.decode("00000001419a020c"))
        XCTAssertEqual(out, [
            .deviceMeta(name: "DC-1"),
            .codec(id: 0x6832_3634),
            .session(width: 1200, height: 1600),
            .config(annexB: config),
            .frame(ptsUs: 33333, keyFrame: true, annexB: key),
            .frame(ptsUs: 66666, keyFrame: false, annexB: delta),
        ])
        XCTAssertEqual(demuxer.pendingByteCount, 0)

        XCTAssertNil(MirrorStream.scrcpyBytes(.status(MirrorStream.Status(state: .idle))))
        XCTAssertNil(MirrorStream.scrcpyBytes(.control(.stop)))
        XCTAssertEqual(MirrorStream.scrcpyBytes(.hello(deviceName: "DC-1", codecID: 0x6832_3634))?.count, 68)
        XCTAssertEqual(MirrorStream.scrcpyBytes(.packet(.frame(ptsUs: 1, keyFrame: false, annexB: [1, 2, 3])))?.count, 15)
        XCTAssertEqual(MirrorStream.scrcpyBytes(.packet(.session(width: 1, height: 2)))?.count, 12)
    }

    // MARK: Opcodes and constants

    func testOpcodesAndFamily() {
        XCTAssertEqual(MirrorStream.opcodeControl, 0x0071)
        XCTAssertEqual(MirrorStream.opcodeHello, 0x0080)
        XCTAssertEqual(MirrorStream.opcodePacket, 0x0081)
        XCTAssertEqual(MirrorStream.opcodeStatus, 0x0082)
        XCTAssertTrue(MirrorStream.isMirrorOpcode(0x0071))
        XCTAssertTrue(MirrorStream.isMirrorOpcode(0x0080))
        XCTAssertTrue(MirrorStream.isMirrorOpcode(0x0083))
        XCTAssertTrue(MirrorStream.isMirrorOpcode(0x008F))
        XCTAssertFalse(MirrorStream.isMirrorOpcode(0x0070), "STATE is v1")
        XCTAssertFalse(MirrorStream.isMirrorOpcode(0x0072))
        XCTAssertFalse(MirrorStream.isMirrorOpcode(0x007F))
        XCTAssertFalse(MirrorStream.isMirrorOpcode(0x0090))
        XCTAssertFalse(MirrorStream.isMirrorOpcode(0x00FE))
        XCTAssertEqual(MirrorStream.maxAnnexBBytes, 1_048_564)
        XCTAssertEqual(MirrorStream.maxAnnexBBytes, SolStream.maxPayload - 12)
        XCTAssertEqual(MirrorStream.State.unsupported.rawValue, 8)
        XCTAssertEqual(MirrorStream.State.consentNeeded.rawValue, 1)
        XCTAssertEqual(MirrorStream.State.projectionEnded.rawValue, 7)
        XCTAssertEqual(MirrorStream.StatusFlags.projectionHeld.rawValue, 1)
        XCTAssertEqual(MirrorStream.StatusFlags.thermalReduced.rawValue, 2)
        XCTAssertEqual(MirrorStream.StatusFlags.powerSave.rawValue, 4)
        XCTAssertEqual(MirrorStream.StatusFlags.backpressure.rawValue, 8)
        XCTAssertEqual(MirrorStream.Command.release.rawValue, 3)
    }

    func testPeekOpcode() {
        let frame = MirrorStream.encode(.control(.stop), timestampUs: 1)
        XCTAssertEqual(MirrorStream.peekOpcode(frame), 0x0071)
        XCTAssertNil(MirrorStream.peekOpcode(Array(frame.prefix(15))), "shorter than the header")
        var badMagic = frame
        badMagic[0] = 0xDB
        XCTAssertNil(MirrorStream.peekOpcode(badMagic))
        var badVersion = frame
        badVersion[1] = 2
        XCTAssertNil(MirrorStream.peekOpcode(badVersion))
        var big = frame
        big[2] = 0x34
        big[3] = 0x12
        XCTAssertEqual(MirrorStream.peekOpcode(big), 0x1234, "little-endian")
    }

    // MARK: Control.resolved (PROTOCOL 14.4 clamping table)

    func testControlResolvedClampingTable() {
        typealias C = MirrorStream.Control
        // (maxSize in, out)
        let sizes: [(UInt16, UInt16)] = [(0, 1600), (1, 320), (319, 320), (320, 320), (321, 320), (335, 320), (336, 336), (1000, 992), (1599, 1584), (1600, 1600), (1601, 1600), (65535, 1600)]
        for (input, expected) in sizes {
            XCTAssertEqual(C.start(maxSize: input, bitrateBps: 0, maxFps: 0, keyIntervalMs: 0).resolved().maxSize, expected, "max_size \(input)")
        }
        let rates: [(UInt32, UInt32)] = [(0, 7_000_000), (1, 1_000_000), (999_999, 1_000_000), (1_000_000, 1_000_000), (4_000_000, 4_000_000), (8_000_000, 8_000_000), (8_000_001, 8_000_000), (UInt32.max, 8_000_000)]
        for (input, expected) in rates {
            XCTAssertEqual(C.start(maxSize: 0, bitrateBps: input, maxFps: 0, keyIntervalMs: 0).resolved().bitrateBps, expected, "bitrate \(input)")
        }
        let fps: [(UInt16, UInt16)] = [(0, 30), (1, 1), (24, 24), (30, 30), (31, 30), (120, 30)]
        for (input, expected) in fps {
            XCTAssertEqual(C.start(maxSize: 0, bitrateBps: 0, maxFps: input, keyIntervalMs: 0).resolved().maxFps, expected, "fps \(input)")
        }
        let keys: [(UInt16, UInt16)] = [(0, 2000), (1, 500), (499, 500), (500, 500), (2000, 2000), (10000, 10000), (10001, 10000), (65535, 10000)]
        for (input, expected) in keys {
            XCTAssertEqual(C.start(maxSize: 0, bitrateBps: 0, maxFps: 0, keyIntervalMs: input).resolved().keyIntervalMs, expected, "key interval \(input)")
        }
        XCTAssertEqual(C.start(maxSize: 0, bitrateBps: 0, maxFps: 0, keyIntervalMs: 0).resolved(), C.start(maxSize: 1600, bitrateBps: 7_000_000, maxFps: 30, keyIntervalMs: 2000), "all defaults")
        XCTAssertEqual(C.start(maxSize: 1600, bitrateBps: 7_000_000, maxFps: 30, keyIntervalMs: 2000).resolved().command, .start)
        // STOP, REQUEST_KEY_FRAME and RELEASE send zeros.
        XCTAssertEqual(C.stop, C(command: .stop, maxSize: 0, bitrateBps: 0, maxFps: 0, keyIntervalMs: 0))
        XCTAssertEqual(C.requestKeyFrame, C(command: .requestKeyFrame))
        XCTAssertEqual(C.release, C(command: .release))
        XCTAssertEqual(C.stop.resolved(), C.stop)
        XCTAssertEqual(C(command: .release, maxSize: 1000, bitrateBps: 5, maxFps: 9, keyIntervalMs: 9).resolved(), C.release, "parameters matter for START only")
    }

    func testControlAndStatusLittleEndianLayout() throws {
        let start = MirrorStream.encode(.control(.start(maxSize: 0x0102, bitrateBps: 0x0304_0506, maxFps: 0x0708, keyIntervalMs: 0x090A)), timestampUs: 0)
        XCTAssertEqual(Array(start[16...]), [0x01, 0x00, 0x02, 0x01, 0x06, 0x05, 0x04, 0x03, 0x08, 0x07, 0x0A, 0x09])
        let release = MirrorStream.encode(.control(.release), timestampUs: 0)
        XCTAssertEqual(Array(release[16...]), [3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let status = MirrorStream.Status(state: .paused, flags: [.projectionHeld, .backpressure], fpsX10: 0x0102, width: 0x0304, height: 0x0506, bitrateBps: 0x0708_090A, sentBps: 0x0B0C_0D0E)
        let frame = MirrorStream.encode(.status(status), timestampUs: 0)
        XCTAssertEqual(frame.count, 32)
        XCTAssertEqual(Array(frame[16...]), [0x04, 0x09, 0x02, 0x01, 0x04, 0x03, 0x06, 0x05, 0x0A, 0x09, 0x08, 0x07, 0x0E, 0x0D, 0x0C, 0x0B])
        XCTAssertEqual(try MirrorStream.decode(frame).message, .status(status))
        var unknownFlags = frame
        unknownFlags[17] = 0xF0
        guard case let .status(s) = try MirrorStream.decode(unknownFlags).message else { return XCTFail("not a status") }
        XCTAssertEqual(s.flags.rawValue, 0xF0, "unknown flag bits are kept")
    }

    func testPacketBigEndianLayout() throws {
        let frame = MirrorStream.encode(.packet(.frame(ptsUs: 0x0102_0304_0506, keyFrame: true, annexB: [0xAA, 0xBB])), timestampUs: 0)
        XCTAssertEqual(Array(frame[16...]), [0x20, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB])
        XCTAssertEqual(Array(frame[4..<8]), [14, 0, 0, 0], "payload_len little-endian")
        let config = MirrorStream.Packet.config(annexB: [1])
        XCTAssertEqual(config, .media(ptsFlags: 1 << 62, annexB: [1]))
        let session = MirrorStream.encode(.packet(.session(width: 1600, height: 1200)), timestampUs: 0)
        XCTAssertEqual(Array(session[16...]), [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x40, 0x00, 0x00, 0x04, 0xB0])
    }

    // MARK: HELLO name (PROTOCOL 14.1)

    func testHelloNameTruncatesTo63BytesOnAUTF8Boundary() throws {
        let sixtyThree = String(repeating: "a", count: 63)
        XCTAssertEqual(MirrorStream.truncatedDeviceName(sixtyThree).count, 63)
        XCTAssertEqual(MirrorStream.truncatedDeviceName(sixtyThree + "b"), Array(sixtyThree.utf8), "64 ASCII bytes keep 63")
        // 62 ASCII + a 2-byte scalar = 64 bytes: the scalar would end at byte 64, so it is dropped whole.
        let twoByte = String(repeating: "a", count: 62) + "\u{00E9}"
        XCTAssertEqual(MirrorStream.truncatedDeviceName(twoByte), Array(String(repeating: "a", count: 62).utf8))
        // 61 ASCII + a 2-byte scalar = 63 bytes: fits exactly.
        let fits = String(repeating: "a", count: 61) + "\u{00E9}"
        XCTAssertEqual(MirrorStream.truncatedDeviceName(fits).count, 63)
        // 61 ASCII + a 3-byte scalar = 64 bytes: 61 remain.
        let threeByte = String(repeating: "a", count: 61) + "\u{20AC}"
        XCTAssertEqual(MirrorStream.truncatedDeviceName(threeByte).count, 61)
        // 60 ASCII + a 4-byte scalar = 64 bytes: 60 remain.
        let fourByte = String(repeating: "a", count: 60) + "\u{1F58A}"
        XCTAssertEqual(MirrorStream.truncatedDeviceName(fourByte).count, 60)

        let frame = MirrorStream.encode(.hello(deviceName: threeByte, codecID: 0x6832_3634), timestampUs: 7)
        XCTAssertEqual(frame.count, 16 + 68)
        XCTAssertEqual(frame[16 + 61], 0, "NUL padding after the truncated name")
        XCTAssertEqual(frame[16 + 63], 0, "byte 63 is always NUL")
        XCTAssertEqual(Array(frame[(16 + 64)...]), [0x68, 0x32, 0x36, 0x34], "codec id big-endian")
        XCTAssertEqual(try MirrorStream.decode(frame).message, .hello(deviceName: String(repeating: "a", count: 61), codecID: 0x6832_3634))
        XCTAssertEqual(try MirrorStream.decode(MirrorStream.encode(.hello(deviceName: "Mike\u{2019}s DC-1", codecID: 1), timestampUs: 0)).message, .hello(deviceName: "Mike\u{2019}s DC-1", codecID: 1))
    }

    // MARK: Decode errors

    private func frame(opcode: UInt16, payload: [UInt8]) -> [UInt8] {
        var w = ByteWriter()
        w.u8(0xDA)
        w.u8(0x01)
        w.u16(opcode)
        w.u32(UInt32(payload.count))
        w.u64(1)
        w.bytes(payload)
        return w.storage
    }

    private func assertDecodeError(_ bytes: [UInt8], _ expected: MirrorStream.DecodeError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try MirrorStream.decode(bytes), file: file, line: line) { error in
            XCTAssertEqual(error as? MirrorStream.DecodeError, expected, file: file, line: line)
        }
    }

    func testMediaPacketSizeFieldMismatch() {
        // pts_flags 0, size 5, but n = 3.
        let payload: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 1, 2, 3]
        assertDecodeError(frame(opcode: 0x0081, payload: payload), .sizeFieldMismatch(declared: 5, actual: 3))
        let short: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 2, 3]
        assertDecodeError(frame(opcode: 0x0081, payload: short), .sizeFieldMismatch(declared: 2, actual: 3))
    }

    func testSessionPacketWithPayload() {
        let payload: [UInt8] = [0x80, 0, 0, 0, 0, 0, 0x04, 0xB0, 0, 0, 0x06, 0x40, 0xFF]
        assertDecodeError(frame(opcode: 0x0081, payload: payload), .sessionWithPayload)
    }

    func testOtherDecodeErrors() {
        assertDecodeError([0xDA, 0x01, 0x81, 0x00], .tooShort)
        var bad = frame(opcode: 0x0071, payload: [UInt8](repeating: 0, count: 12))
        bad[0] = 0x00
        assertDecodeError(bad, .badMagicOrVersion)
        assertDecodeError(frame(opcode: 0x0070, payload: [UInt8](repeating: 0, count: 12)), .notMirror)
        assertDecodeError(frame(opcode: 0x0083, payload: []), .notMirror)
        var mismatch = frame(opcode: 0x0071, payload: [UInt8](repeating: 0, count: 12))
        mismatch.append(0)
        assertDecodeError(mismatch, .lengthMismatch)
        var huge = frame(opcode: 0x0081, payload: [UInt8](repeating: 0, count: 12))
        huge[4] = 0x01
        huge[5] = 0x00
        huge[6] = 0x10
        huge[7] = 0x00
        assertDecodeError(huge, .tooLarge)
        assertDecodeError(frame(opcode: 0x0080, payload: [UInt8](repeating: 0, count: 67)), .wrongSize(opcode: 0x0080, size: 67))
        assertDecodeError(frame(opcode: 0x0081, payload: [UInt8](repeating: 0, count: 11)), .wrongSize(opcode: 0x0081, size: 11))
        assertDecodeError(frame(opcode: 0x0082, payload: [UInt8](repeating: 0, count: 17)), .wrongSize(opcode: 0x0082, size: 17))
        assertDecodeError(frame(opcode: 0x0071, payload: [UInt8](repeating: 0, count: 11)), .wrongSize(opcode: 0x0071, size: 11))
        assertDecodeError(frame(opcode: 0x0081, payload: [UInt8](repeating: 0, count: 12)), .emptyMedia)
        var status = [UInt8](repeating: 0, count: 16)
        status[0] = 9
        assertDecodeError(frame(opcode: 0x0082, payload: status), .unknownState(9))
        var control = [UInt8](repeating: 0, count: 12)
        control[0] = 4
        assertDecodeError(frame(opcode: 0x0071, payload: control), .unknownCommand(4))
    }

    func testTimestampRoundTrips() throws {
        let t: UInt64 = 0x0102_0304_0506_0708
        let bytes = MirrorStream.encode(.control(.requestKeyFrame), timestampUs: t)
        XCTAssertEqual(Array(bytes[8..<16]), [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(try MirrorStream.decode(bytes).timestampUs, t)
    }
}
