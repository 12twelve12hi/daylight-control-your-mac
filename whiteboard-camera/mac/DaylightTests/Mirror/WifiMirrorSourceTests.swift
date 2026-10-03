import CoreVideo
import DaylightKit
import Foundation
import XCTest
@testable import Daylight

/// Records what the Mac sends to one ink connection (already WebSocket-framed).
final class RecordingInkTransport: InkTransport {
    let remoteAddress: String
    let isLoopback: Bool
    private let lock = NSLock()
    private var frames: [[UInt8]] = []

    init(address: String = "192.168.1.40") {
        remoteAddress = address
        isLoopback = address.hasPrefix("127.")
    }

    func sendRaw(_ bytes: [UInt8]) {
        lock.lock()
        frames.append(bytes)
        lock.unlock()
    }

    /// Called on each `closeTransport()` (the real server tears the socket down after the final message was processed).
    var onCloseTransport: (() -> Void)?

    func closeTransport() {
        onCloseTransport?()
    }

    var sent: [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    /// The MIRROR_CONTROL messages among the sent frames (server frames are unmasked).
    var controls: [MirrorStream.Control] {
        return sent.compactMap { frame -> MirrorStream.Control? in
            guard frame.count >= 2 else { return nil }
            let short = Int(frame[1] & 0x7F)
            let offset = short == 126 ? 4 : (short == 127 ? 10 : 2)
            guard frame.count > offset, let decoded = try? MirrorStream.decode(Array(frame[offset...])) else { return nil }
            if case let .control(control) = decoded.message { return control }
            return nil
        }
    }

    var commands: [MirrorStream.Command] { return controls.map { $0.command } }
}

/// The Wi-Fi mirror transport (PROTOCOL 14) through the ingest entry point AppDelegate wires: START only to a
/// connection that announced MIRROR_STATUS, the recorded fixture decoded into the source with the USB crop rule,
/// STOP on a transport change, the 2 s stall rule, newest HELLO wins, rows 34, 35 and 38.
final class WifiMirrorSourceTests: XCTestCase {
    let ink = DispatchQueue(label: "com.twelve.daylight.tests.wifi.ink")
    let now = Locked(100.0)

    static func wifiSettings() -> Settings {
        var s = Settings.defaults
        s.inkSource = .mirror
        s.mirrorTransport = .wifiStream
        return s
    }

    func makeSource(_ settings: Settings = WifiMirrorSourceTests.wifiSettings()) -> WifiMirrorSource {
        let clock = now
        return WifiMirrorSource(settings: settings, inkQueue: ink, clock: { clock.withLock { $0 } }, autoTick: false)
    }

    func makeConnection(role: SolStream.Role = .ink, label: String = "DC-1", allowed: Bool = true) -> (InkConnection, RecordingInkTransport) {
        let transport = RecordingInkTransport()
        let c = InkConnection(transport: transport)
        c.identity = Identity(role: role, clientID: "id-\(label)", label: label)
        c.allowed = allowed
        return (c, transport)
    }

    @discardableResult
    func feed(_ source: WifiMirrorSource, _ c: InkConnection, _ message: MirrorStream.Message) -> Bool {
        let bytes = MirrorStream.encode(message, timestampUs: 1_000)
        return ink.sync { source.ingest(bytes, from: c, hostTimeNs: 1) }
    }

    func drain(_ source: WifiMirrorSource) {
        ink.sync {}
        source.mirrorQueue.sync {}
        ink.sync {}
    }

    func tick(_ source: WifiMirrorSource, at t: Double) {
        now.withLock { $0 = t }
        ink.sync { source.tick() }
        drain(source)
    }

    static let idle = MirrorStream.Status(state: .idle, flags: [], fpsX10: 0, width: 0, height: 0, bitrateBps: 0, sentBps: 0)
    static func status(_ state: MirrorStream.State, width: UInt16 = 0, height: UInt16 = 0) -> MirrorStream.Status {
        return MirrorStream.Status(state: state, flags: [.projectionHeld], fpsX10: 300, width: width, height: height, bitrateBps: 7_000_000, sentBps: 6_543_210)
    }

    // MARK: Routing and START

    func testNonMirrorOpcodesGoToTheRouter() {
        let source = makeSource()
        let (c, _) = makeConnection()
        let ping = Codec.encode(.ping(sequence: 1, clientTimeUs: 2), timestampUs: 3)
        XCTAssertFalse(ink.sync { source.ingest(ping, from: c, hostTimeNs: 1) })
        XCTAssertFalse(ink.sync { source.ingest([0xDA, 0x01], from: c, hostTimeNs: 1) }, "a short frame is the router's to reject")
        XCTAssertTrue(feed(source, c, .status(WifiMirrorSourceTests.idle)))
    }

    func testStartOnlyToAConnectionThatAnnouncedStatusWithProtocolDefaults() {
        let source = makeSource()
        source.setActive(true)
        let (c, transport) = makeConnection()
        feed(source, c, .packet(.session(width: 1200, height: 1600)))
        drain(source)
        XCTAssertTrue(transport.sent.isEmpty, "no MIRROR_CONTROL before MIRROR_STATUS (PROTOCOL 14.3)")
        feed(source, c, .status(WifiMirrorSourceTests.idle))
        drain(source)
        XCTAssertEqual(transport.controls, [MirrorStream.Control.start(maxSize: 1600, bitrateBps: 7_000_000, maxFps: 30, keyIntervalMs: 2000)])
        XCTAssertEqual(source.status, .connecting(serial: "DC-1"))
        feed(source, c, .status(WifiMirrorSourceTests.idle))
        drain(source)
        XCTAssertEqual(transport.controls.count, 1, "START once per connection and parameters")
    }

    func testStartCarriesTheClampedSettings() {
        var s = WifiMirrorSourceTests.wifiSettings()
        s.mirrorStreamMaxSize = 1000   // rounded down to a multiple of 16: 992
        s.mirrorStreamBitRate = 4_000_000
        s.mirrorStreamMaxFps = 24
        s.mirrorStreamKeyIntervalMs = 1000
        let source = makeSource(s)
        source.setActive(true)
        let (c, transport) = makeConnection()
        feed(source, c, .status(WifiMirrorSourceTests.idle))
        drain(source)
        XCTAssertEqual(transport.controls.first, MirrorStream.Control.start(maxSize: 992, bitrateBps: 4_000_000, maxFps: 24, keyIntervalMs: 1000))
        s.mirrorStreamMaxFps = 15
        source.updateSettings(s)
        drain(source)
        XCTAssertEqual(transport.controls.last?.maxFps, 15, "changed parameters re-send START")
        XCTAssertEqual(transport.controls.count, 2)
    }

    func testMirrorFamilyFromPendingDeniedOrWebConnectionsIsDropped() {
        let source = makeSource()
        source.setActive(true)
        let (pending, pendingTransport) = makeConnection(allowed: false)
        pending.pending = true
        let (denied, deniedTransport) = makeConnection(label: "denied")
        denied.denied = true
        let (web, webTransport) = makeConnection(role: .web, label: "web")
        let fresh = InkConnection(transport: RecordingInkTransport())
        for c in [pending, denied, web, fresh] {
            XCTAssertTrue(feed(source, c, .status(WifiMirrorSourceTests.idle)), "consumed, never handed to the router")
        }
        drain(source)
        XCTAssertTrue(pendingTransport.sent.isEmpty)
        XCTAssertTrue(deniedTransport.sent.isEmpty)
        XCTAssertTrue(webTransport.sent.isEmpty)
        XCTAssertEqual(source.diagnostics["wifi.connections"], "0 capable of 0")
        for role in [SolStream.Role.overlay, .test] {
            let (c, transport) = makeConnection(role: role, label: role.rawValue)
            feed(source, c, .status(WifiMirrorSourceTests.idle))
            drain(source)
            XCTAssertEqual(transport.commands.last, .start, "role \(role.rawValue) may stream")
        }
    }

    // MARK: The recorded fixture end to end

    func testFixtureStreamDecodesIntoTheSourceWithTheUSBCropRule() throws {
        let stream = try H264DecoderTests.fixture("testsrc-320x240-6f")
        let sets = AnnexB.parameterSets(stream)
        let probe = H264Decoder(queue: DispatchQueue(label: "probe"))
        do {
            try probe.setParameterSets(sps: [sets.sps[0]], pps: [sets.pps[0]])
        } catch {
            throw XCTSkip("no H.264 decoder on this runner (\(error))")
        }
        probe.invalidate()
        var s = WifiMirrorSourceTests.wifiSettings()
        s.mirrorPinClearMode = .pills   // pills on: the top inset applies (without pills it is 0, CropInsets.effective)
        s.mirrorCropInsetsLandscape = CropInsets(top: 120, left: 160, right: 160, bottom: 0)
        let source = makeSource(s)
        let events = Locked<[GovernorEvent]>([])
        source.onGovernorEvent = { e in events.withLock { $0.append(e) } }
        source.setActive(true)
        let (c, transport) = makeConnection()
        feed(source, c, .status(WifiMirrorSourceTests.idle))
        feed(source, c, .hello(deviceName: "DC-1", codecID: ScrcpyDemuxer.codecH264))
        feed(source, c, .packet(.session(width: 320, height: 240)))
        feed(source, c, .status(WifiMirrorSourceTests.status(.streaming, width: 320, height: 240)))
        var config: [UInt8] = []
        config += [0, 0, 0, 1] + sets.sps[0] + [0, 0, 0, 1] + sets.pps[0]
        feed(source, c, .packet(.media(ptsFlags: ScrcpyDemuxer.flagConfig, annexB: config)))
        let units = H264DecoderTests.accessUnits(stream)
        XCTAssertEqual(units.count, 6)
        for (index, unit) in units.enumerated() {
            let flags = unit.keyFrame ? ScrcpyDemuxer.flagKeyFrame : 0
            feed(source, c, .packet(.media(ptsFlags: flags | UInt64(index) * 33_333, annexB: unit.annexB)))
            now.withLock { $0 += 1.0 / 30 }
        }
        drain(source)
        XCTAssertEqual(source.frameSeed, 6, "one seed step per decoded frame")
        XCTAssertEqual(source.frameCount, 6)
        let latest = try XCTUnwrap(source.latest())
        XCTAssertEqual(CVPixelBufferGetWidth(latest.buffer), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(latest.buffer), 240)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(latest.buffer), kCVPixelFormatType_32BGRA)
        XCTAssertEqual(latest.orientation, .landscape, "orientation from the session packet")
        // Landscape native 1600x1200: 160/1600 = 0.1, 120/1200 = 0.1, (1600-160)/1600 = 0.9.
        XCTAssertEqual(latest.uv.u0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(latest.uv.v0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(latest.uv.u1, 0.9, accuracy: 1e-9)
        XCTAssertEqual(latest.uv.v1, 1.0, accuracy: 1e-9)
        let usb = MirrorSource.geometry(sessionWidth: 320, sessionHeight: 240, portrait: s.mirrorCropInsetsPortrait, landscape: s.mirrorCropInsetsLandscape, pillsEnabled: true)
        XCTAssertEqual(latest.uv, usb.uv, "the same crop rule as the USB MirrorSource")
        XCTAssertEqual(latest.aspect, usb.aspect, accuracy: 1e-9)
        XCTAssertEqual(source.status, .mirroring(serial: "DC-1", width: 320, height: 240))
        XCTAssertEqual(transport.commands, [.start])
        let d = source.diagnostics
        XCTAssertEqual(d["wifi.streamSize"], "320x240")
        XCTAssertEqual(d["wifi.bitrate"], "sent 6543210 bps (encoder 7000000 bps)")
        XCTAssertEqual(d["wifi.fps"]?.hasPrefix("tablet 30.0, decoded "), true)
        XCTAssertNotEqual(d["wifi.decodeLatencyMs"], "none")
        XCTAssertEqual(d["wifi.engageSource"], "frame difference")
        XCTAssertEqual(d["wifi.tabletState"], "streaming (projection held)")
        XCTAssertEqual(d["wifi.streamer"], "DC-1")

        // PROTOCOL 14.5: the connection closes while streaming; the last frame stays, status idle.
        ink.sync { source.forget(c) }
        drain(source)
        XCTAssertNotNil(source.latest())
        XCTAssertEqual(source.frameSeed, 6)
        XCTAssertEqual(source.status, .idle)
        // START goes to the next capable connection.
        let (next, nextTransport) = makeConnection(label: "DC-1 again")
        feed(source, next, .status(WifiMirrorSourceTests.idle))
        drain(source)
        XCTAssertEqual(nextTransport.commands, [.start])
    }

    // MARK: Transport changes through the controller

    func testStopOnTransportChangeAndStartAgain() {
        let adb = FakeAdb()
        adb.respond { args in args == ["devices", "-l"] ? FakeAdb.ok("") : nil }
        adb.respond(containing: ["version"], with: FakeAdb.ok("Android Debug Bridge version 1.0.41\n"))
        let vendor = FileManager.default.temporaryDirectory.appendingPathComponent("daylight-wifi-\(UUID().uuidString)/Vendor", isDirectory: true)
        try? FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vendor.deletingLastPathComponent()) }
        var s = WifiMirrorSourceTests.wifiSettings()
        s.adbServerMode = .shared
        let control = DispatchQueue(label: "wifi-control")
        let controller = MirrorController(settings: s, vendorDirectory: vendor, pipeline: FakePipelineControl(), queue: control, adb: adb, wifiQueue: ink)
        controller.trackerTuning = (pollInterval: 0.05, useTrackSocket: false)
        XCTAssertTrue(controller.activeSource === controller.wifiSource)
        controller.start()
        control.sync {}
        drain(controller.wifiSource)
        let (c, transport) = makeConnection()
        feed(controller.wifiSource, c, .status(WifiMirrorSourceTests.idle))
        drain(controller.wifiSource)
        XCTAssertEqual(transport.commands, [.start])
        s.mirrorTransport = .usb
        controller.updateSettings(s)
        control.sync {}
        control.sync {}
        drain(controller.wifiSource)
        XCTAssertEqual(transport.commands, [.start, .stop], "STOP when the transport changes away")
        XCTAssertTrue(controller.activeSource === controller.source, "the pipeline samples the USB source again")
        XCTAssertEqual(controller.wifiSource.status, .idle)
        s.mirrorTransport = .wifiStream
        controller.updateSettings(s)
        control.sync {}
        control.sync {}
        drain(controller.wifiSource)
        XCTAssertEqual(transport.commands, [.start, .stop, .start])
        XCTAssertEqual(controller.diagnostics["transport"], "wifiStream")
        controller.stop()
        control.sync {}
        drain(controller.wifiSource)
        XCTAssertEqual(transport.commands, [.start, .stop, .start, .stop], "STOP when the ink source leaves Mirror")
        controller.releaseWifiStream()
        XCTAssertEqual(transport.commands.last, .release, "RELEASE on quit")
    }

    /// LOOSE_ENDS J3: quit sends RELEASE, closes the connection right behind it and waits until the server reports it
    /// closed (which it does only after the final message was processed), at most the bound. Before J3 `release()`
    /// only queued the frame: no close frame, `closeTransport` was never called, so the order and flushed checks fail.
    func testReleaseOnQuitWaitsUntilTheServerClosedTheConnection() {
        let source = makeSource()
        let (c, transport) = makeConnection()
        feed(source, c, .status(WifiMirrorSourceTests.idle))
        drain(source)
        let forgotten = Locked(false)
        let ink = self.ink
        transport.onCloseTransport = {
            // Like WebServer: the close completes on the network queue, then the app hands it to ink.queue.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                ink.async {
                    source.forget(c)
                    forgotten.withLock { $0 = true }
                }
            }
        }
        XCTAssertTrue(source.release(timeout: 10), "the server reported the connection closed")
        XCTAssertTrue(forgotten.withLock { $0 }, "release returned only after forget")
        XCTAssertEqual(transport.commands.last, .release)
        let opcodes = transport.sent.map { $0[0] & 0x0F }
        XCTAssertEqual(Array(opcodes.suffix(2)), [WebSocketFrame.opcodeBinary, WebSocketFrame.opcodeClose], "RELEASE, then the close frame behind it")
        XCTAssertTrue(c.isClosed)
        XCTAssertTrue(source.release(), "nothing left to release returns at once")
        XCTAssertEqual(WifiMirrorSource.releaseFlushTimeout, 0.3)
    }

    /// LOOSE_ENDS J3: a server that never reports the close holds quit for the bound only.
    func testReleaseOnQuitIsBounded() {
        let source = makeSource()
        let (c, transport) = makeConnection()
        feed(source, c, .status(WifiMirrorSourceTests.idle))
        drain(source)
        let start = Date()
        XCTAssertFalse(source.release(timeout: 0.2), "never confirmed")
        let waited = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(waited, 0.19)
        XCTAssertLessThan(waited, 5, "bounded; the upper limit only guards against an unbounded wait on a loaded runner")
        XCTAssertEqual(transport.commands.last, .release)
    }

    // MARK: PROTOCOL 14.5 rules

    func testStallRequestsAKeyFrameAfterTwoSecondsAndEveryTwoSeconds() {
        XCTAssertEqual(MirrorStreamReceiver.stallSeconds, 2.0)
        XCTAssertEqual(WifiMirrorSource.tickInterval, 0.5)
        let source = makeSource()
        let failures = Locked<[FailureText.Case]>([])
        source.onFailure = { f, _ in failures.withLock { $0.append(f) } }
        source.setActive(true)
        let (c, transport) = makeConnection()
        now.withLock { $0 = 100 }
        feed(source, c, .status(WifiMirrorSourceTests.idle))
        feed(source, c, .hello(deviceName: "DC-1", codecID: ScrcpyDemuxer.codecH264))
        feed(source, c, .packet(.session(width: 1200, height: 1600)))
        feed(source, c, .status(WifiMirrorSourceTests.status(.streaming, width: 1200, height: 1600)))
        drain(source)
        tick(source, at: 101.9)
        XCTAssertEqual(transport.commands, [.start], "no stall before 2 s")
        tick(source, at: 102.1)
        XCTAssertEqual(transport.commands, [.start, .requestKeyFrame])
        XCTAssertEqual(source.status, .error(.wifiStreamStalled, "DC-1"))
        tick(source, at: 103.0)
        XCTAssertEqual(transport.commands, [.start, .requestKeyFrame], "not again within 2 s")
        tick(source, at: 104.3)
        XCTAssertEqual(transport.commands, [.start, .requestKeyFrame, .requestKeyFrame], "again every 2 s")
        XCTAssertEqual(failures.withLock { $0 }.filter { $0 == .wifiStreamStalled }.count, 1, "row 36 shown once per stall")
    }

    func testNewestHelloWinsAndTheOlderConnectionGetsStop() {
        let source = makeSource()
        source.setActive(true)
        let (a, aTransport) = makeConnection(label: "A")
        let (b, bTransport) = makeConnection(label: "B")
        feed(source, a, .status(WifiMirrorSourceTests.idle))
        feed(source, a, .hello(deviceName: "DC-1", codecID: ScrcpyDemuxer.codecH264))
        drain(source)
        XCTAssertEqual(source.diagnostics["wifi.streamer"], "A")
        feed(source, b, .status(WifiMirrorSourceTests.idle))
        drain(source)
        XCTAssertEqual(bTransport.commands, [.start], "the newest capable connection gets START")
        feed(source, b, .hello(deviceName: "DC-1", codecID: ScrcpyDemuxer.codecH264))
        drain(source)
        XCTAssertEqual(aTransport.commands, [.start, .stop], "the older stream gets STOP")
        XCTAssertEqual(source.diagnostics["wifi.streamer"], "B")
        feed(source, a, .packet(.session(width: 1600, height: 1200)))
        drain(source)
        XCTAssertNotEqual(source.diagnostics["wifi.streamSize"], "1600x1200", "packets of the older stream are ignored")
    }

    func testMediaPacketWithAWrongSizeFieldRequestsAKeyFrameAtMostOncePerSecond() {
        XCTAssertEqual(MirrorStreamReceiver.keyFrameRequestMinInterval, 1.0)
        let source = makeSource()
        source.setActive(true)
        let (c, transport) = makeConnection()
        now.withLock { $0 = 100 }
        feed(source, c, .status(WifiMirrorSourceTests.idle))
        feed(source, c, .hello(deviceName: "DC-1", codecID: ScrcpyDemuxer.codecH264))
        var bad = MirrorStream.encode(.packet(.media(ptsFlags: 0, annexB: [0, 0, 0, 1, 0x65, 0x88])), timestampUs: 1)
        bad[16 + 11] = bad[16 + 11] &+ 1   // the u32 BE size no longer equals n
        XCTAssertTrue(ink.sync { source.ingest(bad, from: c, hostTimeNs: 1) })
        now.withLock { $0 = 100.5 }
        XCTAssertTrue(ink.sync { source.ingest(bad, from: c, hostTimeNs: 1) })
        drain(source)
        XCTAssertEqual(transport.commands, [.start, .requestKeyFrame], "once within a second")
        now.withLock { $0 = 101.1 }
        XCTAssertTrue(ink.sync { source.ingest(bad, from: c, hostTimeNs: 1) })
        drain(source)
        XCTAssertEqual(transport.commands, [.start, .requestKeyFrame, .requestKeyFrame])
    }

    func testPausedAnnounceGetsStartAndUnsupportedNeverDoes() {
        let source = makeSource()
        source.setActive(true)
        // A projection that survived a Wi-Fi drop announces PAUSED (4): START streams without new consent.
        let (paused, pausedTransport) = makeConnection(role: .overlay, label: "paused")
        feed(source, paused, .status(WifiMirrorSourceTests.status(.paused)))
        drain(source)
        XCTAssertEqual(pausedTransport.commands, [.start])
        // UNSUPPORTED (8): connected but cannot mirror, row 35, never START, even as the newest connection.
        let (old, oldTransport) = makeConnection(role: .overlay, label: "old build")
        feed(source, old, .status(WifiMirrorSourceTests.status(.unsupported)))
        drain(source)
        XCTAssertTrue(oldTransport.sent.isEmpty)
        XCTAssertEqual(source.status, .error(.wifiStreamEncoderUnavailable, "old build"))
        XCTAssertEqual(MirrorStream.State.paused.rawValue, 4)
    }

    /// Finder W1: START, the owner cancels the consent dialog (row 34), then taps Share in Daylight Ink and allows it.
    /// The tablet now holds the projection and waits in PAUSED. Before the fix the Mac only set its status to idle:
    /// `startedWith` still matched, so START was never sent again (commands stayed `[.start]`, status `.idle`).
    func testPausedAfterADenialAndShareGetsStartAgain() {
        let source = makeSource()
        source.setActive(true)
        let (c, transport) = makeConnection()
        feed(source, c, .status(WifiMirrorSourceTests.idle))
        for state in [MirrorStream.State.consentNeeded, .consentDenied, .consentNeeded, .paused] {
            feed(source, c, .status(WifiMirrorSourceTests.status(state)))
        }
        drain(source)
        XCTAssertEqual(transport.commands, [.start, .start], "PAUSED with the projection held gets START again")
        XCTAssertEqual(source.status, .connecting(serial: "DC-1"))
        feed(source, c, .status(WifiMirrorSourceTests.status(.paused)))
        drain(source)
        XCTAssertEqual(transport.commands, [.start, .start], "a repeated PAUSED report is not a change")
    }

    /// Finder W1, the second path: streaming, then the notification's Stop (PROJECTION_ENDED), then Share (PAUSED).
    func testPausedAfterAProjectionEndedGetsStartAgain() {
        let source = makeSource()
        source.setActive(true)
        let (c, transport) = makeConnection()
        feed(source, c, .status(WifiMirrorSourceTests.idle))
        feed(source, c, .hello(deviceName: "DC-1", codecID: ScrcpyDemuxer.codecH264))
        for state in [MirrorStream.State.starting, .streaming, .projectionEnded, .consentNeeded, .paused] {
            feed(source, c, .status(WifiMirrorSourceTests.status(state)))
        }
        drain(source)
        XCTAssertEqual(transport.commands, [.start, .start])
    }

    /// The W1 guard: a stream that a newer HELLO replaced was STOPped on purpose; its PAUSED report gets no START
    /// (the newer connection sent HELLO without announcing, so the older one is still the newest capable).
    func testPausedAfterNewestHelloWinsGetsNoStart() {
        let source = makeSource()
        source.setActive(true)
        let (a, aTransport) = makeConnection(label: "A")
        let (b, _) = makeConnection(label: "B")
        feed(source, a, .status(WifiMirrorSourceTests.idle))
        feed(source, a, .hello(deviceName: "DC-1", codecID: ScrcpyDemuxer.codecH264))
        feed(source, a, .status(WifiMirrorSourceTests.status(.streaming)))
        feed(source, b, .hello(deviceName: "DC-1", codecID: ScrcpyDemuxer.codecH264))
        drain(source)
        XCTAssertEqual(aTransport.commands, [.start, .stop])
        feed(source, a, .status(WifiMirrorSourceTests.status(.paused)))
        drain(source)
        XCTAssertEqual(aTransport.commands, [.start, .stop], "no ping-pong with newest HELLO wins")
        XCTAssertEqual(source.diagnostics["wifi.streamer"], "B")
    }

    /// After quit (RELEASE closes every capable connection) a late PAUSED report sends nothing.
    func testPausedAfterReleaseSendsNothing() {
        let source = makeSource()
        source.setActive(true)
        let (c, transport) = makeConnection()
        feed(source, c, .status(WifiMirrorSourceTests.idle))
        drain(source)
        XCTAssertFalse(source.release(timeout: 0.05))
        feed(source, c, .status(WifiMirrorSourceTests.status(.paused)))
        drain(source)
        XCTAssertEqual(transport.commands, [.start, .release])
    }

    func testHelloWhileInactiveGetsStop() {
        let source = makeSource()
        let (c, transport) = makeConnection()
        feed(source, c, .status(WifiMirrorSourceTests.idle))
        feed(source, c, .hello(deviceName: "DC-1", codecID: ScrcpyDemuxer.codecH264))
        drain(source)
        XCTAssertEqual(transport.commands, [.stop])
    }

    func testRow38FiveSecondsWithoutACapableConnection() {
        XCTAssertEqual(WifiMirrorSource.noTabletSeconds, 5)
        let source = makeSource()
        let failures = Locked<[FailureText.Case]>([])
        source.onFailure = { f, _ in failures.withLock { $0.append(f) } }
        now.withLock { $0 = 100 }
        source.setActive(true)
        drain(source)
        XCTAssertEqual(source.status, .noDevice)
        tick(source, at: 104.9)
        XCTAssertEqual(source.status, .noDevice)
        tick(source, at: 105.0)
        XCTAssertEqual(source.status, .error(.wifiStreamNoTablet, ""))
        tick(source, at: 106.0)
        XCTAssertEqual(failures.withLock { $0 }, [.wifiStreamNoTablet], "reported once")
        let (c, transport) = makeConnection()
        feed(source, c, .status(WifiMirrorSourceTests.idle))
        drain(source)
        XCTAssertEqual(transport.commands, [.start])
        XCTAssertEqual(source.status, .connecting(serial: "DC-1"))
    }

    func testConsentDeniedIsRow34AndEncoderUnavailableIsRow35() {
        let source = makeSource()
        let failures = Locked<[(FailureText.Case, [String])]>([])
        source.onFailure = { f, args in failures.withLock { $0.append((f, args)) } }
        source.setActive(true)
        let (c, _) = makeConnection()
        feed(source, c, .status(WifiMirrorSourceTests.idle))
        feed(source, c, .status(WifiMirrorSourceTests.status(.consentNeeded)))   // state 1
        drain(source)
        XCTAssertEqual(source.status, .connecting(serial: "DC-1, waiting for consent on the tablet"))
        XCTAssertEqual(source.diagnostics["wifi.tabletState"], "waiting for consent on the tablet (projection held)")
        feed(source, c, .status(WifiMirrorSourceTests.status(.consentDenied)))   // state 5
        drain(source)
        XCTAssertEqual(source.status, .error(.wifiStreamConsentDenied, "DC-1"))
        feed(source, c, .status(WifiMirrorSourceTests.status(.encoderUnavailable)))   // state 6
        drain(source)
        XCTAssertEqual(source.status, .error(.wifiStreamEncoderUnavailable, "DC-1"))
        let (d, _) = makeConnection(label: "old build")
        feed(source, d, .status(WifiMirrorSourceTests.status(.unsupported)))   // state 8
        drain(source)
        XCTAssertEqual(source.status, .error(.wifiStreamEncoderUnavailable, "old build"))
        let list = failures.withLock { $0 }
        XCTAssertEqual(list.map { $0.0 }, [.wifiStreamConsentDenied, .wifiStreamEncoderUnavailable, .wifiStreamEncoderUnavailable])
        XCTAssertEqual(list[1].1, ["DC-1", "6"])
        XCTAssertEqual(list[2].1, ["old build", "8"])
        XCTAssertEqual(MirrorStream.State.consentDenied.rawValue, 5)
        XCTAssertEqual(MirrorStream.State.encoderUnavailable.rawValue, 6)
        XCTAssertEqual(MirrorStream.State.unsupported.rawValue, 8)
    }
}
