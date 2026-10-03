import Foundation
import XCTest
import DaylightKit

/// PROTOCOL 14.5 receiver rules for one connection: HELLO starts a fresh demuxer, PACKET before HELLO is logged once,
/// malformed packets reset the demuxer and request a key frame at most once per second, the 2 s stall rule repeats.
final class MirrorStreamReceiverTests: XCTestCase {
    typealias R = MirrorStreamReceiver
    func testConstants() {
        XCTAssertEqual(R.stallSeconds, 2.0)
        XCTAssertEqual(R.keyFrameRequestMinInterval, 1.0)
    }

    func testHelloStartsAStreamAndPacketsFlow() {
        var r = R()
        XCTAssertFalse(r.hasHello)
        XCTAssertEqual(r.receive(F.hello, now: 0), [
            .streamStarted(deviceName: "DC-1"),
            .packet(.deviceMeta(name: "DC-1")),
            .packet(.codec(id: F.h264)),
        ])
        XCTAssertTrue(r.hasHello)
        XCTAssertEqual(r.deviceName, "DC-1")
        XCTAssertEqual(r.receive(F.session, now: 0.01), [.packet(.session(width: 1200, height: 1600))])
        XCTAssertEqual(r.receive(F.config, now: 0.02), [.packet(.config(annexB: F.sps))])
        XCTAssertEqual(r.receive(F.frame(33333, key: true), now: 0.03), [.packet(.frame(ptsUs: 33333, keyFrame: true, annexB: F.idr))])
        XCTAssertEqual(r.receive(F.frame(66666), now: 0.06), [.packet(.frame(ptsUs: 66666, keyFrame: false, annexB: F.delta))])
    }

    func testSecondHelloResetsTheDemuxer() {
        var r = R()
        _ = r.receive(F.hello, now: 0)
        _ = r.receive(F.session, now: 0)
        let out = r.receive(.hello(deviceName: "DC-1 rotated", codecID: F.h264), now: 1)
        XCTAssertEqual(out, [.streamStarted(deviceName: "DC-1 rotated"), .packet(.deviceMeta(name: "DC-1 rotated")), .packet(.codec(id: F.h264))])
        XCTAssertEqual(r.receive(.packet(.session(width: 1600, height: 1200)), now: 1.1), [.packet(.session(width: 1600, height: 1200))])
    }

    func testPacketBeforeHelloIsLoggedOnceThenDroppedSilently() {
        var r = R()
        let first = r.receive(F.session, now: 0)
        XCTAssertEqual(first.count, 1)
        guard case .log = first[0] else { return XCTFail("expected one log, got \(first)") }
        XCTAssertEqual(r.receive(F.frame(1), now: 0.1), [], "dropped silently")
        XCTAssertEqual(r.receive(F.config, now: 0.2), [])
        XCTAssertFalse(r.hasHello)
        // A HELLO then makes packets flow.
        _ = r.receive(F.hello, now: 0.3)
        XCTAssertEqual(r.receive(F.session, now: 0.4), [.packet(.session(width: 1200, height: 1600))])
    }

    /// Finder P14-A1 / W6: a rejected HELLO used to emit `.streamStarted` first, so the app let it take over the stream.
    func testHelloWithACodecErrorIsRejected() {
        var r = R()
        let out = r.receive(.hello(deviceName: "DC-1", codecID: 1), now: 0)
        XCTAssertEqual(out.first, .helloRejected(deviceName: "DC-1", codecID: 1))
        XCTAssertFalse(out.contains(.streamStarted(deviceName: "DC-1")), "a rejected HELLO starts no stream")
        XCTAssertEqual(out.count, 2)
        guard case .log = out[1] else { return XCTFail("expected a log, got \(out)") }
        XCTAssertFalse(r.hasHello)
        XCTAssertEqual(r.receive(F.session, now: 0.1).count, 1, "packet before a valid HELLO: one log")
    }

    func testRejectedHelloAfterAStreamEndsThatStream() {
        var r = started()
        let out = r.receive(.hello(deviceName: "DC-1", codecID: 0), now: 1)
        XCTAssertEqual(out.first, .helloRejected(deviceName: "DC-1", codecID: 0))
        XCTAssertFalse(r.hasHello)
        XCTAssertEqual(packets(r.receive(F.frame(5, key: true), now: 1.1)), [], "no packets until a valid HELLO")
    }

    // MARK: Malformed packets (size field mismatch, session with payload)

    private func started() -> R {
        var r = R()
        _ = r.receive(F.hello, now: 0)
        _ = r.receive(F.session, now: 0)
        _ = r.receive(F.config, now: 0)
        return r
    }

    private func sends(_ out: [R.Output]) -> [MirrorStream.Control] {
        var result: [MirrorStream.Control] = []
        for o in out {
            if case let .send(c) = o { result.append(c) }
        }
        return result
    }

    private func packets(_ out: [R.Output]) -> [ScrcpyPacket] {
        var result: [ScrcpyPacket] = []
        for o in out {
            if case let .packet(p) = o { result.append(p) }
        }
        return result
    }

    func testSizeFieldMismatchResetsAndRequestsAKeyFrame() {
        var r = started()
        let out = r.receive(frame: F.sizeMismatch, now: 10)
        XCTAssertEqual(sends(out), [.requestKeyFrame])
        XCTAssertTrue(out.contains(.discontinuity), "the decode side waits for a key frame")
        XCTAssertEqual(packets(out), [], "dropped")
        // The demuxer is usable right after the reset: the next valid packet comes through.
        XCTAssertEqual(r.receive(frame: MirrorStream.encode(F.frame(5, key: true), timestampUs: 0), now: 10.1), [.packet(.frame(ptsUs: 5, keyFrame: true, annexB: F.idr))])
    }

    func testSessionWithPayloadResetsAndRequestsAKeyFrame() {
        var r = started()
        let out = r.receive(frame: F.sessionWithPayload, now: 10)
        XCTAssertEqual(sends(out), [.requestKeyFrame])
        XCTAssertEqual(packets(out), [])
        XCTAssertEqual(r.receive(F.session, now: 10.2), [.packet(.session(width: 1200, height: 1600))])
    }

    func testKeyFrameRequestsAreRateLimitedToOncePerSecond() {
        var r = started()
        XCTAssertEqual(sends(r.receive(frame: F.sizeMismatch, now: 10.0)), [.requestKeyFrame])
        let second = r.receive(frame: F.sessionWithPayload, now: 10.5)
        XCTAssertEqual(sends(second), [], "0.5 s later: no second request")
        XCTAssertTrue(second.contains(.discontinuity), "every reset is a discontinuity, even without a new request")
        XCTAssertEqual(sends(r.receive(frame: F.sizeMismatch, now: 10.999)), [])
        XCTAssertEqual(sends(r.receive(frame: F.sizeMismatch, now: 11.0)), [.requestKeyFrame], "1 s after the last request")
        XCTAssertEqual(sends(r.receive(frame: F.sizeMismatch, now: 11.5)), [])
        XCTAssertEqual(sends(r.receive(frame: F.sizeMismatch, now: 12.25)), [.requestKeyFrame])
    }

    func testDemuxerErrorOnADecodedMessageAlsoResets() {
        var r = started()
        // An empty media packet built in code: the demuxer reports badPacketSize(0).
        let out = r.receive(.packet(.media(ptsFlags: 0, annexB: [])), now: 3)
        XCTAssertEqual(sends(out), [.requestKeyFrame])
        XCTAssertEqual(r.receive(F.frame(9), now: 3.1), [.packet(.frame(ptsUs: 9, keyFrame: false, annexB: F.delta))])
    }

    func testMalformedPacketBeforeHelloIsOnlyLogged() {
        var r = R()
        let out = r.receive(frame: F.sizeMismatch, now: 0)
        XCTAssertEqual(sends(out), [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(r.receive(frame: F.sizeMismatch, now: 0.5), [], "packet before HELLO is logged once")
    }

    func testNonMirrorFrameProducesNothing() {
        var r = started()
        let state = [UInt8](repeating: 0, count: 16)
        var w = ByteWriter()
        w.u8(0xDA)
        w.u8(0x01)
        w.u16(0x0070)
        w.u32(16)
        w.u64(0)
        w.bytes(state)
        XCTAssertEqual(r.receive(frame: w.storage, now: 0), [])
    }

    func testFramesThroughTheRawPathMatchDecodedMessages() {
        var r = R()
        let out = r.receive(frame: MirrorStream.encode(F.hello, timestampUs: 0), now: 0)
        XCTAssertEqual(out.first, R.Output.streamStarted(deviceName: "DC-1"))
        XCTAssertEqual(r.receive(frame: MirrorStream.encode(.status(F.streaming), timestampUs: 0), now: 0), [.status(F.streaming)])
        XCTAssertEqual(r.lastStatus, F.streaming)
    }

    // MARK: Stall rule (2.0 s, repeated every 2.0 s)

    func testStallFiresAtTwoSecondsAndRepeats() {
        var r = started()
        XCTAssertEqual(r.receive(.status(F.streaming), now: 0), [.status(F.streaming)])
        _ = r.receive(F.frame(1, key: true), now: 1.0)
        XCTAssertEqual(r.tick(now: 2.0), [])
        XCTAssertEqual(r.tick(now: 2.999), [])
        XCTAssertEqual(r.tick(now: 3.0), [.stalled, .send(.requestKeyFrame)], "2.0 s after the last packet")
        XCTAssertEqual(r.tick(now: 3.5), [])
        XCTAssertEqual(r.tick(now: 4.999), [])
        XCTAssertEqual(r.tick(now: 5.0), [.stalled, .send(.requestKeyFrame)], "again 2 s later")
        XCTAssertEqual(r.tick(now: 7.0), [.stalled, .send(.requestKeyFrame)])
        // A packet ends the stall; the timer restarts from it.
        _ = r.receive(F.frame(2), now: 7.5)
        XCTAssertEqual(r.tick(now: 9.0), [])
        XCTAssertEqual(r.tick(now: 9.5), [.stalled, .send(.requestKeyFrame)])
    }

    func testNoStallUnlessTheLastStatusSaysStreaming() {
        var r = started()
        XCTAssertEqual(r.tick(now: 100), [], "no status yet")
        _ = r.receive(.status(MirrorStream.Status(state: .paused, flags: .projectionHeld)), now: 100)
        XCTAssertEqual(r.tick(now: 200), [], "PAUSED never stalls")
        _ = r.receive(.status(F.streaming), now: 200)
        XCTAssertEqual(r.tick(now: 201.5), [], "the timer starts when STREAMING begins")
        XCTAssertEqual(r.tick(now: 202), [.stalled, .send(.requestKeyFrame)])
        _ = r.receive(.status(MirrorStream.Status(state: .projectionEnded)), now: 203)
        XCTAssertEqual(r.tick(now: 210), [])
    }

    func testStatusRepeatsDoNotRestartTheStallTimer() {
        var r = started()
        _ = r.receive(.status(F.streaming), now: 0)
        _ = r.receive(.status(F.streaming), now: 1)
        _ = r.receive(.status(F.streaming), now: 1.9)
        XCTAssertEqual(r.tick(now: 2.0), [.stalled, .send(.requestKeyFrame)], "1 Hz STREAMING reports are not packets")
    }

    func testStallRequestCountsForTheRateLimit() {
        var r = started()
        _ = r.receive(.status(F.streaming), now: 0)
        XCTAssertEqual(r.tick(now: 2.0), [.stalled, .send(.requestKeyFrame)])
        XCTAssertEqual(sends(r.receive(frame: F.sizeMismatch, now: 2.5)), [], "within 1 s of the stall request")
        XCTAssertEqual(sends(r.receive(frame: F.sizeMismatch, now: 3.0)), [.requestKeyFrame])
    }

    /// Finder P14-A2(b): a malformed non-packet message (here a 15-byte MIRROR_STATUS, then an unknown state) was
    /// logged on every frame; PROTOCOL 9 says once per connection.
    func testMalformedStatusIsLoggedOncePerReceiver() {
        var r = R()
        var short = MirrorStream.encode(.status(F.streaming), timestampUs: 0)
        short.removeLast()
        short[4] = UInt8(MirrorStream.statusLength - 1)
        let first = r.receive(frame: short, now: 0)
        XCTAssertEqual(first.count, 1)
        guard case .log = first[0] else { return XCTFail("expected one log, got \(first)") }
        XCTAssertEqual(r.receive(frame: short, now: 1), [], "the same error again: silent")
        var unknown = MirrorStream.encode(.status(F.streaming), timestampUs: 0)
        unknown[SolStream.headerLength] = 9
        XCTAssertEqual(r.receive(frame: unknown, now: 2), [], "any later decode error: silent")
    }

    func testControlFromAClientIsLoggedOnce() {
        var r = R()
        XCTAssertEqual(r.receive(.control(.stop), now: 0).count, 1)
        XCTAssertEqual(r.receive(.control(.stop), now: 1), [])
    }

    func testReset() {
        var r = started()
        _ = r.receive(.status(F.streaming), now: 0)
        r.reset()
        XCTAssertFalse(r.hasHello)
        XCTAssertNil(r.lastStatus)
        XCTAssertNil(r.deviceName)
        XCTAssertEqual(r.tick(now: 100), [])
        XCTAssertEqual(r.receive(F.session, now: 100).count, 1, "packet before HELLO logs again after a reset")
    }
}

private enum F {
    static let h264: UInt32 = 0x6832_3634
    static let sps: [UInt8] = [0, 0, 0, 1, 0x67, 0x42, 0x80, 0x28, 0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80]
    static let idr: [UInt8] = [0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00]
    static let delta: [UInt8] = [0, 0, 0, 1, 0x41, 0x9A, 0x02, 0x0C]

    static let hello = MirrorStream.Message.hello(deviceName: "DC-1", codecID: h264)
    static let session = MirrorStream.Message.packet(.session(width: 1200, height: 1600))
    static let config = MirrorStream.Message.packet(.config(annexB: sps))
    static func frame(_ pts: UInt64, key: Bool = false) -> MirrorStream.Message {
        return .packet(.frame(ptsUs: pts, keyFrame: key, annexB: key ? idr : delta))
    }
    static let streaming = MirrorStream.Status(state: .streaming, flags: .projectionHeld, fpsX10: 300, width: 1200, height: 1600, bitrateBps: 7_000_000, sentBps: 1_000_000)


    static func rawFrame(payload: [UInt8]) -> [UInt8] {
        var w = ByteWriter()
        w.u8(0xDA)
        w.u8(0x01)
        w.u16(0x0081)
        w.u32(UInt32(payload.count))
        w.u64(0)
        w.bytes(payload)
        return w.storage
    }

    static let sizeMismatch: [UInt8] = rawFrame(payload: [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 9, 1, 2, 3])
    static let sessionWithPayload: [UInt8] = rawFrame(payload: [0x80, 0, 0, 0, 0, 0, 0x04, 0xB0, 0, 0, 0x06, 0x40, 0xAA])

}
