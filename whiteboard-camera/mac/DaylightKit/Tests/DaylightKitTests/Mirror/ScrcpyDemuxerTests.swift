import Foundation
import XCTest
import DaylightKit

/// SPEC F1: the demuxer yields the same packets for a synthetic stream chunked at 1, 7 and 1460 bytes, re-emits a
/// session on rotation, and reports codec ids 0 and 1 as errors.
final class ScrcpyDemuxerTests: XCTestCase {
    /// The fixture's SPS and PPS (testsrc 320x240, baseline) as the config packet payload.
    static let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x0D, 0xD9, 0x01, 0x41, 0xFB, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x03, 0xC0, 0xF1, 0x42, 0xA4, 0x80]
    static let pps: [UInt8] = [0x68, 0xCB, 0x83, 0xCB, 0x20]
    static let startCode: [UInt8] = [0, 0, 0, 1]

    static func syntheticStream(dummy: Bool = true) -> [UInt8] {
        var s: [UInt8] = []
        if dummy { s += ScrcpyStreamBuilder.dummyByte() }
        s += ScrcpyStreamBuilder.deviceMeta(name: "Daylight DC-1")
        s += ScrcpyStreamBuilder.codec()
        s += ScrcpyStreamBuilder.session(width: 1200, height: 1600)
        s += ScrcpyStreamBuilder.config(annexB: startCode + sps + startCode + pps)
        var idr = [UInt8](repeating: 0xAB, count: 3000)
        idr[0] = 0x65
        s += ScrcpyStreamBuilder.frame(ptsUs: 1_000_000, keyFrame: true, annexB: startCode + idr)
        var p = [UInt8](repeating: 0x11, count: 200)
        p[0] = 0x41
        s += ScrcpyStreamBuilder.frame(ptsUs: 1_033_333, keyFrame: false, annexB: startCode + p)
        // Rotation: a new session, a new config, a key frame.
        s += ScrcpyStreamBuilder.session(width: 1600, height: 1200)
        s += ScrcpyStreamBuilder.config(annexB: startCode + sps + startCode + pps)
        s += ScrcpyStreamBuilder.frame(ptsUs: 2_000_000, keyFrame: true, annexB: startCode + idr)
        return s
    }

    static func demux(_ bytes: [UInt8], chunk: Int, dummy: Bool = true) throws -> [ScrcpyPacket] {
        var demuxer = ScrcpyDemuxer(expectsDummyByte: dummy)
        var out: [ScrcpyPacket] = []
        var i = 0
        while i < bytes.count {
            let end = min(bytes.count, i + chunk)
            let slice = Array(bytes[i..<end])
            try slice.withUnsafeBytes { raw in try demuxer.feed(raw) { out.append($0) } }
            i = end
        }
        XCTAssertEqual(demuxer.pendingByteCount, 0, "every byte was consumed")
        return out
    }

    func testWholeStreamYieldsPacketsInOrder() throws {
        let packets = try ScrcpyDemuxerTests.demux(ScrcpyDemuxerTests.syntheticStream(), chunk: 1 << 20)
        XCTAssertEqual(packets.count, 9)
        XCTAssertEqual(packets[0], .deviceMeta(name: "Daylight DC-1"))
        XCTAssertEqual(packets[1], .codec(id: 0x6832_3634))
        XCTAssertEqual(packets[2], .session(width: 1200, height: 1600))
        guard case let .config(annexB) = packets[3] else { return XCTFail("config expected, got \(packets[3])") }
        XCTAssertEqual(annexB.count, 4 + 24 + 4 + 5)
        guard case let .frame(pts, key, payload) = packets[4] else { return XCTFail("frame expected") }
        XCTAssertEqual(pts, 1_000_000)
        XCTAssertTrue(key)
        XCTAssertEqual(payload.count, 3004)
        XCTAssertEqual(payload[4], 0x65)
        guard case let .frame(pts2, key2, payload2) = packets[5] else { return XCTFail("frame expected") }
        XCTAssertEqual(pts2, 1_033_333)
        XCTAssertFalse(key2)
        XCTAssertEqual(payload2.count, 204)
        XCTAssertEqual(packets[6], .session(width: 1600, height: 1200), "the session is re-emitted on rotation")
        guard case .config = packets[7] else { return XCTFail("a config packet follows the new session") }
        guard case let .frame(pts3, key3, _) = packets[8] else { return XCTFail("frame expected") }
        XCTAssertEqual(pts3, 2_000_000)
        XCTAssertTrue(key3)
    }

    func testChunkingAt1And7And1460BytesYieldsTheSamePackets() throws {
        let stream = ScrcpyDemuxerTests.syntheticStream()
        let whole = try ScrcpyDemuxerTests.demux(stream, chunk: stream.count)
        for chunk in [1, 7, 1460] {
            let chunked = try ScrcpyDemuxerTests.demux(stream, chunk: chunk)
            XCTAssertEqual(chunked, whole, "chunk size \(chunk)")
        }
    }

    func testDummyByteIsOptional() throws {
        let withoutDummy = ScrcpyDemuxerTests.syntheticStream(dummy: false)
        let packets = try ScrcpyDemuxerTests.demux(withoutDummy, chunk: 3, dummy: false)
        XCTAssertEqual(packets.count, 9)
        var d = ScrcpyDemuxer()
        XCTAssertTrue(d.expectsDummyByte)
        try d.feed([0x00]) { _ in XCTFail("the dummy byte is not a packet") }
        XCTAssertFalse(d.expectsDummyByte)
        XCTAssertEqual(d.pendingByteCount, 0)
    }

    func testCodecIdZeroAndOneAreErrors() {
        for (id, expected) in [(UInt32(0), ScrcpyError.codecDisabled), (UInt32(1), ScrcpyError.codecConfigError), (UInt32(0x6832_3635), ScrcpyError.unknownCodec(0x6832_3635))] {
            var d = ScrcpyDemuxer(expectsDummyByte: false)
            let bytes = ScrcpyStreamBuilder.deviceMeta(name: "x") + ScrcpyStreamBuilder.codec(id: id)
            var emitted: [ScrcpyPacket] = []
            XCTAssertThrowsError(try d.feed(bytes) { emitted.append($0) }) { error in
                XCTAssertEqual(error as? ScrcpyError, expected)
            }
            XCTAssertEqual(emitted, [.deviceMeta(name: "x")])
        }
    }

    func testZeroPacketSizeIsAFramingError() {
        var d = ScrcpyDemuxer(expectsDummyByte: false)
        let bytes = ScrcpyStreamBuilder.deviceMeta(name: "x") + ScrcpyStreamBuilder.codec() + ScrcpyStreamBuilder.u64(5) + ScrcpyStreamBuilder.u32(0)
        XCTAssertThrowsError(try d.feed(bytes) { _ in }) { error in
            XCTAssertEqual(error as? ScrcpyError, .badPacketSize(0))
        }
    }

    func testHeaderBitsMatchTheScrcpySource() {
        // Streamer.java: PACKET_FLAG_SESSION = 1 << 63, CONFIG = 1 << 62, KEY_FRAME = 1 << 61.
        XCTAssertEqual(ScrcpyDemuxer.flagSession, 0x80)
        XCTAssertEqual(ScrcpyDemuxer.flagConfig, 0x4000_0000_0000_0000)
        XCTAssertEqual(ScrcpyDemuxer.flagKeyFrame, 0x2000_0000_0000_0000)
        XCTAssertEqual(ScrcpyDemuxer.ptsMask, 0x1FFF_FFFF_FFFF_FFFF)
        XCTAssertEqual(ScrcpyDemuxer.codecH264, 0x6832_3634)
        XCTAssertEqual(ScrcpyDemuxer.deviceMetaLength, 64)
        XCTAssertEqual(ScrcpyDemuxer.headerLength, 12)
        let header = ScrcpyStreamBuilder.frame(ptsUs: 0x0123_4567_89AB, keyFrame: true, annexB: [0x65])
        XCTAssertEqual(Array(header.prefix(12)), [0x20, 0x00, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0x00, 0x00, 0x00, 0x01])
        let session = ScrcpyStreamBuilder.session(width: 1200, height: 1600)
        XCTAssertEqual(session, [0x80, 0, 0, 0, 0, 0, 0x04, 0xB0, 0, 0, 0x06, 0x40])
    }

    func testDeviceMetaIsTruncatedAndPadded() throws {
        let long = String(repeating: "D", count: 100)
        let meta = ScrcpyStreamBuilder.deviceMeta(name: long)
        XCTAssertEqual(meta.count, 64)
        XCTAssertEqual(meta[63], 0)
        var d = ScrcpyDemuxer(expectsDummyByte: false)
        var names: [String] = []
        try d.feed(meta) { if case let .deviceMeta(name) = $0 { names.append(name) } }
        XCTAssertEqual(names, [String(repeating: "D", count: 63)])
    }

    func testLongSessionDoesNotGrowTheBuffer() throws {
        var d = ScrcpyDemuxer(expectsDummyByte: false)
        try d.feed(ScrcpyStreamBuilder.deviceMeta(name: "x") + ScrcpyStreamBuilder.codec() + ScrcpyStreamBuilder.session(width: 8, height: 8)) { _ in }
        var frames = 0
        let payload = [UInt8](repeating: 0x41, count: 50_000)
        for i in 0..<200 {
            let bytes = ScrcpyStreamBuilder.frame(ptsUs: UInt64(i), keyFrame: false, annexB: payload)
            // Feed in two halves so the buffer always carries a partial packet.
            try d.feed(Array(bytes[0..<30_000])) { _ in }
            try d.feed(Array(bytes[30_000...])) { if case .frame = $0 { frames += 1 } }
        }
        XCTAssertEqual(frames, 200)
        XCTAssertEqual(d.pendingByteCount, 0)
    }
}
