import CoreVideo
import DaylightKit
import Foundation
import os
import QuartzCore

/// The second mirror transport (PROTOCOL 14, LOOSE_ENDS A9): Daylight Ink streams the tablet screen as scrcpy 4.1
/// video bytes over its own `/ink` WebSocket. This class is both the ingest (one `MirrorStreamReceiver` per
/// connection, the PROTOCOL 14.5 rules, MIRROR_CONTROL to the tablet) and a `MirrorFrameSource` the pipeline samples
/// with the same crop rule as the USB `MirrorSource` (it keeps one internally as its frame slot).
///
/// Threading: GCD serial queues only. `ingest`, `forget`, `tick` and every MIRROR_CONTROL send run on `inkQueue`
/// (the router's ink.queue, where `InkConnection` fields are safe to read). Decoding, the luma grid and the
/// frame-difference engage run on `mirrorQueue`. Status changes are made on `inkQueue`; `latest()`, `status` and
/// `diagnostics` are readable from any thread.
final class WifiMirrorSource: MirrorFrameSource {
    static let log = Logger(subsystem: "com.twelve.daylight", category: "mirror.wifi")
    /// SPEC 13.3 row 38: no capable connection this long after the transport became active.
    static let noTabletSeconds: Double = 5
    /// The receiver stall rule and the engage release are checked on this cadence (PROTOCOL 14.5).
    static let tickInterval: Double = 0.5
    /// Moving-average weight of the decode latency (submit to output callback).
    static let latencyWeight: Double = 0.1
    /// Quit waits at most this long for RELEASE to reach the network stack (LOOSE_ENDS J3).
    static let releaseFlushTimeout: Double = 0.3
    /// A decode error requests a key frame at most this often (PROTOCOL 14.5, decoder error row).
    static let keyFrameRequestInterval: Double = 1
    /// STOP then START after rejected parameter sets at most this often (the row 27 interval).
    static let restartInterval: Double = H264Decoder.keyFrameRestartSeconds

    enum EngageSource: String {
        case pen = "pen (USB getevent)"
        case frameDiff = "frame difference"
        case none = "none"
    }

    /// The roles that may carry the mirror family (PROTOCOL 14: the Daylight Ink canvas, its pills, and test).
    static func mayStream(_ c: InkConnection) -> Bool {
        guard c.identity != nil, c.allowed, !c.denied, let role = c.role else { return false }
        return role == .ink || role == .overlay || role == .test
    }

    /// The START parameters from the settings, clamped and defaulted by PROTOCOL 14.4.
    static func startControl(_ s: Settings) -> MirrorStream.Control {
        return MirrorStream.Control.start(
            maxSize: UInt16(clamping: s.mirrorStreamMaxSize),
            bitrateBps: UInt32(clamping: s.mirrorStreamBitRate),
            maxFps: UInt16(clamping: s.mirrorStreamMaxFps),
            keyIntervalMs: UInt16(clamping: s.mirrorStreamKeyIntervalMs)).resolved()
    }

    /// The luma grid for a decoded frame: 48 x 64 portrait, 64 x 48 landscape.
    static func gridSize(_ orientation: StudioLayout.CanvasOrientation) -> (width: Int, height: Int) {
        let p = LumaGrid.portraitSize
        return orientation == .portrait ? (p.width, p.height) : (p.height, p.width)
    }

    /// Samples a BGRA pixel buffer inside `crop` (read-only lock); nil for any other pixel format.
    static func lumaGrid(_ buffer: CVPixelBuffer, crop: UVRect, gridWidth: Int, gridHeight: Int) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let raw = UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
        return LumaGrid.sample(bgra: raw, bytesPerRow: bytesPerRow, width: width, height: height, crop: crop, gridWidth: gridWidth, gridHeight: gridHeight)
    }

    static func frameDiffConfig(_ s: Settings) -> FrameDiffEngage.Config {
        var config = FrameDiffEngage.Config()
        config.changedFraction = s.mirrorDiffThreshold
        return config
    }

    static func describe(_ state: MirrorStream.State) -> String {
        switch state {
        case .idle: return "idle"
        case .consentNeeded: return "waiting for consent on the tablet"
        case .starting: return "starting"
        case .streaming: return "streaming"
        case .paused: return "paused"
        case .consentDenied: return "consent denied"
        case .encoderUnavailable: return "encoder unavailable"
        case .projectionEnded: return "projection ended"
        case .unsupported: return "unsupported"
        }
    }

    static func describe(_ control: MirrorStream.Control) -> String {
        switch control.command {
        case .start: return "START \(control.maxSize) px \(control.bitrateBps) bps \(control.maxFps) fps key \(control.keyIntervalMs) ms"
        case .stop: return "STOP"
        case .requestKeyFrame: return "REQUEST_KEY_FRAME"
        case .release: return "RELEASE"
        }
    }

    /// One connection that sent a mirror-family message (ink.queue only).
    private final class Peer {
        let connection: InkConnection
        var receiver = MirrorStreamReceiver()
        /// Order of the announce (first MIRROR_STATUS) or the latest MIRROR_HELLO; nil until MIRROR_STATUS arrived.
        var order: UInt64?
        var startedWith: MirrorStream.Control?
        var lastState: MirrorStream.State?
        var stalled = false
        /// Its latest MIRROR_HELLO was rejected (codec 0, 1 or unknown): never the start target until a valid HELLO.
        var helloRejected = false
        init(_ connection: InkConnection) { self.connection = connection }
        var id: UUID { return connection.id }
        var label: String { return connection.label }
        var capable: Bool { return order != nil && !connection.isClosed }
    }

    private struct Diag {
        var active = false
        var tabletState = "none"
        var sentBps: UInt32 = 0
        var bitrateBps: UInt32 = 0
        var tabletFpsX10: UInt16 = 0
        var decodedFps = 0
        var latencyMs: Double?
        var engageSource = EngageSource.none
        var streamWidth = 0
        var streamHeight = 0
        var connections = 0
        var capable = 0
        var streamer = "none"
        var deviceName = ""
        var frames: UInt64 = 0
        var decodeErrors: UInt64 = 0
    }

    let inkQueue: DispatchQueue
    let mirrorQueue: DispatchQueue
    private let slot: MirrorSource
    private let clock: () -> Double
    private let autoTick: Bool

    var onGovernorEvent: ((GovernorEvent) -> Void)?
    /// Status changes (called on ink.queue).
    var onStatusChange: ((MirrorStatus) -> Void)?
    /// Failure rows for the menu, like `MirrorController.onFailure` (called on ink.queue or mirror.queue).
    var onFailure: ((FailureText.Case, [String]) -> Void)?
    var onLog: ((String) -> Void)?
    /// True while the USB getevent pen watcher runs for a DC-1 (read on mirror.queue): then frame-difference edges
    /// are ignored and the pen is the engage source.
    var penWatcherPresent: () -> Bool = { false }
    /// The controller hooks these so `start()` and `stop()` through the `MirrorFrameSource` contract reach it.
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    // ink.queue state
    private var settings: Settings
    private var peers: [UUID: Peer] = [:]
    private var nextOrder: UInt64 = 0
    private var streamerID: UUID?
    private var active = false
    private var noCapableSince: Double?
    private var noTabletReported = false
    private var droppedLogged: Set<UUID> = []
    /// The connections `release(timeout:)` closed and waits for; `forget` signals once the last one is gone.
    private var releaseFlush: (done: DispatchSemaphore, ids: Set<UUID>)?
    private var timer: DispatchSourceTimer?
    private var sessionSize: (w: Int, h: Int)?
    /// Counts MIRROR_HELLOs that started a stream; results from the decode side carry it (finder W7).
    private var streamGeneration: UInt64 = 0

    // mirror.queue state
    private var decoder: H264Decoder?
    private var frameDiff: FrameDiffEngage
    private var diffConfig: FrameDiffEngage.Config
    private var frameDiffNoticeShown = false
    private var decodedTimes: [Double] = []
    private var submitTime: Double = 0
    private var streamLabel = ""
    private var decodeErrorLogged = false
    /// The stream generation the current decoder belongs to.
    private var decoderGeneration: UInt64 = 0
    private var lastKeyFrameRequestAt: Double?
    private var lastRestartAt: Double?

    private let statusBox = Locked<MirrorStatus>(.idle)
    private let diagBox = Locked(Diag())

    init(settings: Settings, inkQueue: DispatchQueue, mirrorQueue: DispatchQueue? = nil, clock: @escaping () -> Double = { CACurrentMediaTime() }, autoTick: Bool = true) {
        let validated = settings.validated()
        self.settings = validated
        self.inkQueue = inkQueue
        self.mirrorQueue = mirrorQueue ?? DispatchQueue(label: "com.twelve.daylight.mirror.wifi", qos: .userInteractive)
        self.clock = clock
        self.autoTick = autoTick
        slot = MirrorSource(settings: validated)
        diffConfig = WifiMirrorSource.frameDiffConfig(validated)
        frameDiff = FrameDiffEngage(config: diffConfig)
        inkQueue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        timer?.cancel()
    }

    // MARK: MirrorFrameSource

    var frameSeed: UInt64 { return slot.frameSeed }

    func latest() -> (buffer: CVPixelBuffer, uv: UVRect, aspect: Double, orientation: StudioLayout.CanvasOrientation)? {
        return slot.latest()
    }

    func latestForSave() -> (buffer: CVPixelBuffer, uv: UVRect)? {
        return slot.latestForSave()
    }

    func start() { onStart?() }
    func stop() { onStop?() }

    var status: MirrorStatus { return statusBox.withLock { $0 } }

    /// Decoded frames since launch.
    var frameCount: UInt64 { return slot.frameCount }

    var diagnostics: [String: String] {
        let d = diagBox.withLock { $0 }
        var out: [String: String] = [:]
        out["wifi.active"] = "\(d.active)"
        out["wifi.status"] = MirrorController.describe(status)
        out["wifi.tabletState"] = d.tabletState
        out["wifi.bitrate"] = "sent \(d.sentBps) bps (encoder \(d.bitrateBps) bps)"
        out["wifi.fps"] = String(format: "tablet %.1f, decoded %d", Double(d.tabletFpsX10) / 10, d.decodedFps)
        out["wifi.decodeLatencyMs"] = d.latencyMs.map { String(format: "%.2f", $0) } ?? "none"
        out["wifi.engageSource"] = d.engageSource.rawValue
        out["wifi.streamSize"] = d.streamWidth > 0 ? "\(d.streamWidth)x\(d.streamHeight)" : "none"
        out["wifi.connections"] = "\(d.capable) capable of \(d.connections)"
        out["wifi.streamer"] = d.streamer
        if !d.deviceName.isEmpty { out["wifi.deviceModel"] = d.deviceName }
        out["wifi.frames"] = "\(d.frames)"
        out["wifi.decodeErrors"] = "\(d.decodeErrors)"
        return out
    }

    // MARK: Settings and activation

    /// Crop insets apply at once; stream parameters re-send START to the streaming tablet; the change threshold
    /// rebuilds the engage detector (releasing a held contact first).
    func updateSettings(_ newSettings: Settings) {
        let validated = newSettings.validated()
        slot.updateSettings(validated)
        inkQueue.async { [weak self] in
            guard let self = self else { return }
            self.settings = validated
            self.reconcile()
        }
        mirrorQueue.async { [weak self] in
            guard let self = self else { return }
            let config = WifiMirrorSource.frameDiffConfig(validated)
            guard config != self.diffConfig else { return }
            self.diffConfig = config
            self.endEngage()
            self.frameDiff = FrameDiffEngage(config: config)
        }
    }

    /// Active while the ink source is Mirror and the transport is Wi-Fi: START to the newest capable connection.
    /// Inactive: STOP to every connection that was started, status idle.
    func setActive(_ on: Bool) {
        inkQueue.async { [weak self] in self?.applyActive(on) }
    }

    private func applyActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        diagBox.withLock { $0.active = on }
        if on {
            log("Wi-Fi mirror transport active")
            noCapableSince = clock()
            noTabletReported = false
            mirrorQueue.async { [weak self] in self?.frameDiffNoticeShown = false }
            startTimer()
            setStatus(.noDevice)
            reconcile()
        } else {
            log("Wi-Fi mirror transport inactive")
            for peer in sortedPeers() where peer.startedWith != nil {
                send(.stop, to: peer)
                peer.startedWith = nil
            }
            streamerID = nil
            noCapableSince = nil
            stopTimer()
            mirrorQueue.async { [weak self] in self?.endEngage() }
            updatePeerDiag()
            setStatus(.idle)
        }
    }

    /// RELEASE to every capable connection (quit): the tablet stops the encoder and releases the projection.
    ///
    /// LOOSE_ENDS J3: quit stops the server right after this, and the process may exit before a queued frame left.
    /// So each capable connection is closed right behind its RELEASE (code 1001, as the server's own stop would), and
    /// the caller waits at most `timeout` until the server reports every one of them closed (`forget`). The server
    /// closes a connection only after its final message was processed by the network stack, and a connection sends in
    /// order, so that report means RELEASE was handed to the socket. Returns true when it was, false on the timeout
    /// (or when called on ink.queue, where `forget` runs and so nothing can be awaited).
    @discardableResult
    func release(timeout: Double = WifiMirrorSource.releaseFlushTimeout) -> Bool {
        let done = DispatchSemaphore(value: 0)
        var awaited = 0
        let body = { [weak self] in
            guard let self = self else { return }
            let capable = self.sortedPeers().filter { $0.capable }
            self.streamerID = nil
            guard !capable.isEmpty else { return }
            awaited = capable.count
            self.releaseFlush = (done, Set(capable.map { $0.id }))
            for peer in capable {
                self.send(.release, to: peer)
                peer.startedWith = nil
                peer.connection.close(code: 1001, reason: "Daylight quit")
            }
        }
        if DispatchQueue.getSpecific(key: queueKey) == true {
            body()
            return awaited == 0
        }
        inkQueue.sync(execute: body)
        guard awaited > 0 else { return true }
        let flushed = done.wait(timeout: .now() + timeout) == .success
        log(flushed ? "mirror stream: RELEASE flushed to \(awaited) connection(s)" : "mirror stream: RELEASE not confirmed within \(Int(timeout * 1000)) ms")
        return flushed
    }

    /// Per instance, so `release()` knows whether it already runs on ink.queue.
    private let queueKey = DispatchSpecificKey<Bool>()

    // MARK: Ingest (ink.queue)

    /// The routing entry point (ink.queue): true when the frame belongs to the mirror family and was consumed
    /// (handled or dropped); false hands it to `InkRouter.handle` unchanged.
    @discardableResult
    func ingest(_ bytes: [UInt8], from c: InkConnection, hostTimeNs: UInt64) -> Bool {
        guard let opcode = MirrorStream.peekOpcode(bytes), MirrorStream.isMirrorOpcode(opcode) else { return false }
        c.lastRxHostTimeNs = hostTimeNs
        guard WifiMirrorSource.mayStream(c) else {
            // PROTOCOL 14.5: from a pending, denied, unhandshaken or web connection the mirror family is dropped.
            if !droppedLogged.contains(c.id) {
                droppedLogged.insert(c.id)
                log("mirror stream: opcode 0x\(String(opcode, radix: 16)) from \(c.label) (\(c.role?.rawValue ?? "no handshake"), allowed=\(c.allowed)) dropped")
            }
            return true
        }
        let peer: Peer
        if let existing = peers[c.id] {
            peer = existing
        } else {
            peer = Peer(c)
            peers[c.id] = peer
        }
        var announced = false
        let outputs: [MirrorStreamReceiver.Output]
        do {
            let message = try MirrorStream.decode(bytes).message
            if case .control = message {
                log("mirror stream: MIRROR_CONTROL from \(c.label) dropped (server to client only)")
                return true
            }
            if case .status = message, peer.order == nil {
                nextOrder += 1
                peer.order = nextOrder
                announced = true
                log("mirror stream: \(peer.label) announced the capability")
            }
            outputs = peer.receiver.receive(message, now: clock())
        } catch let error as MirrorStream.DecodeError {
            // A size field that differs from n or a session packet with a payload: the receiver resets the demuxer
            // and requests a key frame (at most once per second, PROTOCOL 14.5).
            outputs = peer.receiver.receive(decodeError: error, opcode: opcode, now: clock())
        } catch {
            log("mirror stream: opcode 0x\(String(opcode, radix: 16)) from \(c.label) dropped (\(error))")
            return true
        }
        handle(outputs, from: peer)
        if announced {
            updatePeerDiag()
            reconcile()
        }
        return true
    }

    /// The connection closed (ink.queue; call before `InkRouter.clientClosed`). PROTOCOL 14.5: the source keeps the
    /// last frame, status idle, START goes to the next capable connection.
    func forget(_ c: InkConnection) {
        droppedLogged.remove(c.id)
        if let flush = releaseFlush, flush.ids.contains(c.id) {
            let rest = flush.ids.subtracting([c.id])
            releaseFlush = rest.isEmpty ? nil : (flush.done, rest)
            if rest.isEmpty { flush.done.signal() }
        }
        guard peers[c.id] != nil else { return }
        let wasStatusTarget = statusTarget()?.id == c.id
        guard let peer = peers.removeValue(forKey: c.id) else { return }
        if streamerID == peer.id {
            streamerID = nil
            log("mirror stream: \(peer.label) closed while streaming; the last frame stays")
            mirrorQueue.async { [weak self] in self?.endEngage() }
            if active { setStatus(.idle) }
        } else if wasStatusTarget, active {
            // Its row 34 or 35 (or "waiting for consent") no longer applies; reconcile picks the next connection.
            setStatus(.idle)
        }
        updatePeerDiag()
        if active { reconcile() }
    }

    /// The 0.5 s cadence (ink.queue): the receiver stall rule, row 38, and the engage release.
    func tick() {
        let now = clock()
        for peer in sortedPeers() {
            handle(peer.receiver.tick(now: now), from: peer)
        }
        if active, let since = noCapableSince, !noTabletReported, now - since >= WifiMirrorSource.noTabletSeconds {
            noTabletReported = true
            log(FailureText.logLine(.wifiStreamNoTablet))
            setStatus(.error(.wifiStreamNoTablet, ""))
            onFailure?(.wifiStreamNoTablet, [])
        }
        mirrorQueue.async { [weak self] in
            guard let self = self else { return }
            self.updateDecodedFps(now: now)
            if let edge = self.frameDiff.tick(now: now) { self.emitEdge(edge) }
        }
    }

    private func handle(_ outputs: [MirrorStreamReceiver.Output], from peer: Peer) {
        for output in outputs {
            if case let .streamStarted(name) = output { helloFrom(peer, deviceName: name) }
        }
        for output in outputs {
            switch output {
            case let .packet(packet):
                guard active, streamerID == peer.id else { continue }
                let label = peer.label
                mirrorQueue.async { [weak self] in self?.decodePacket(packet, label: label) }
            case let .status(status):
                statusFrom(peer, status)
            case let .send(control):
                send(control, to: peer)
            case .stalled:
                stalled(peer)
            case let .log(text):
                log("mirror stream \(peer.label): \(text)")
            case let .helloRejected(name, codecID):
                helloRejected(peer, deviceName: name, codecID: codecID)
            case .discontinuity:
                // The demuxer was reset (PROTOCOL 14.5): frames until the requested key frame may miss references.
                guard active, streamerID == peer.id else { continue }
                mirrorQueue.async { [weak self] in self?.decoder?.awaitKeyFrame() }
            case .streamStarted:
                break
            }
        }
    }

    private func helloFrom(_ peer: Peer, deviceName: String) {
        guard active else {
            log("mirror stream: MIRROR_HELLO from \(peer.label) while the Wi-Fi transport is inactive; STOP")
            send(.stop, to: peer)
            return
        }
        nextOrder += 1
        if peer.order != nil { peer.order = nextOrder }
        if let oldID = streamerID, oldID != peer.id, let old = peers[oldID] {
            log("mirror stream: newest stream wins: \(peer.label) replaces \(old.label)")
            send(.stop, to: old)
            old.startedWith = nil
        }
        streamerID = peer.id
        peer.stalled = false
        peer.helloRejected = false
        sessionSize = nil
        log("mirror stream: MIRROR_HELLO from \(peer.label) (\(deviceName))")
        diagBox.withLock { $0.deviceName = deviceName }
        updatePeerDiag()
        streamGeneration += 1
        let label = peer.label
        let generation = streamGeneration
        mirrorQueue.async { [weak self] in self?.resetDecoder(label: label, generation: generation) }
        setStatus(.connecting(serial: peer.label))
    }

    /// A MIRROR_HELLO the receiver rejected (finder W6): the stream is not started and does not replace the current
    /// one. STOP ends the useless encoder; row 35 when the Mac was starting this connection.
    private func helloRejected(_ peer: Peer, deviceName: String, codecID: UInt32) {
        let wasTarget = startTarget()?.id == peer.id
        peer.helloRejected = true
        log("mirror stream: MIRROR_HELLO from \(peer.label) (\(deviceName)) with codec id \(codecID) rejected; STOP")
        send(.stop, to: peer)
        if streamerID == peer.id {
            // Its previous stream ended with this HELLO; the last frame stays.
            streamerID = nil
            mirrorQueue.async { [weak self] in self?.endEngage() }
        }
        updatePeerDiag()
        guard active else { return }
        if wasTarget || statusTarget()?.id == peer.id {
            let args = [peer.label, "codec \(codecID)"]
            setStatus(.error(.wifiStreamEncoderUnavailable, peer.label))
            onFailure?(.wifiStreamEncoderUnavailable, args)
        }
        reconcile()
    }

    private func statusFrom(_ peer: Peer, _ s: MirrorStream.Status) {
        let changed = peer.lastState != s.state
        peer.lastState = s.state
        let isTarget = peer.id == statusTarget()?.id
        if isTarget {
            diagBox.withLock { d in
                var flags: [String] = []
                if s.flags.contains(.projectionHeld) { flags.append("projection held") }
                if s.flags.contains(.thermalReduced) { flags.append("thermal reduced") }
                if s.flags.contains(.powerSave) { flags.append("power save") }
                if s.flags.contains(.backpressure) { flags.append("backpressure") }
                d.tabletState = WifiMirrorSource.describe(s.state) + (flags.isEmpty ? "" : " (" + flags.joined(separator: ", ") + ")")
                d.sentBps = s.sentBps
                d.bitrateBps = s.bitrateBps
                d.tabletFpsX10 = s.fpsX10
            }
        }
        if changed { log("mirror stream: \(peer.label) state \(WifiMirrorSource.describe(s.state)) flags 0x\(String(s.flags.rawValue, radix: 16))") }
        // A connection whose HELLO was rejected keeps its row 35; its PAUSED (after the STOP) must not START it again.
        guard active, isTarget, changed, !peer.helloRejected else { return }
        switch s.state {
        case .consentDenied:
            log(FailureText.logLine(.wifiStreamConsentDenied, [peer.label]))
            setStatus(.error(.wifiStreamConsentDenied, peer.label))
            onFailure?(.wifiStreamConsentDenied, [peer.label])
        case .encoderUnavailable, .unsupported:
            let args = [peer.label, "\(s.state.rawValue)"]
            log(FailureText.logLine(.wifiStreamEncoderUnavailable, args))
            setStatus(.error(.wifiStreamEncoderUnavailable, peer.label))
            onFailure?(.wifiStreamEncoderUnavailable, args)
        case .consentNeeded:
            // The tablet shows its "Share screen" prompt; with notifications denied it can wait here (PROTOCOL 14.3).
            setStatus(.connecting(serial: "\(peer.label), waiting for consent on the tablet"))
        case .starting, .idle:
            setStatus(.connecting(serial: peer.label))
        case .streaming:
            if let size = sessionSize, peer.id == streamerID {
                setStatus(.mirroring(serial: peer.label, width: size.w, height: size.h))
            } else {
                setStatus(.connecting(serial: peer.label))
            }
        case .paused, .projectionEnded:
            setStatus(.idle)
        }
        // PROTOCOL 14.5: PAUSED on the connection the Mac would START means the tablet holds a projection and waits for
        // START (the owner shared after a denial or a notification Stop, or the Mac's own STOP). `startedWith` still
        // says START was sent, so reconcile alone would never send it again. Not for a connection whose stream another
        // HELLO replaced (that one was STOPped on purpose; re-starting it would ping-pong with newest-HELLO-wins).
        if s.state == .paused, streamerID == nil || streamerID == peer.id, startTarget()?.id == peer.id {
            log("mirror stream: \(peer.label) paused with the projection held; START again")
            peer.startedWith = nil
            reconcile()
        }
    }

    private func stalled(_ peer: Peer) {
        guard active, peer.id == streamerID else { return }
        let seconds = "\(Int(MirrorStreamReceiver.stallSeconds))"
        log(FailureText.logLine(.wifiStreamStalled, [seconds, peer.label]))
        setStatus(.error(.wifiStreamStalled, peer.label))
        if !peer.stalled {
            peer.stalled = true
            onFailure?(.wifiStreamStalled, [seconds, peer.label])
        }
    }

    /// Called on ink.queue when a frame decoded while the status was not "mirroring" (first frame, after a stall).
    /// A frame of an earlier stream (decoded after the next HELLO was handled) is ignored (finder W7).
    private func frameArrived(width: Int, height: Int, generation: UInt64) {
        guard active, generation == streamGeneration, let id = streamerID, let peer = peers[id] else { return }
        peer.stalled = false
        sessionSize = (width, height)
        setStatus(.mirroring(serial: peer.label, width: width, height: height))
    }

    private func newestCapable() -> Peer? {
        return peers.values.filter { $0.capable }.max { ($0.order ?? 0) < ($1.order ?? 0) }
    }

    /// The connection whose MIRROR_STATUS drives the status: the streamer, else the start target. Only when no
    /// connection can capture does an UNSUPPORTED one report (row 35), so a newer connection that cannot capture never
    /// hides the consent or encoder state of the one the Mac started (finder W3).
    private func statusTarget() -> Peer? {
        if let id = streamerID, let streamer = peers[id] { return streamer }
        return startTarget() ?? newestCapable()
    }

    /// The connection START goes to: the newest capable one that can capture. A tablet that announced UNSUPPORTED
    /// (state 8) or whose HELLO was rejected counts as present (no row 38) but is never started.
    private func startTarget() -> Peer? {
        return peers.values.filter { $0.capable && $0.lastState != .unsupported && !$0.helloRejected }.max { ($0.order ?? 0) < ($1.order ?? 0) }
    }

    private func sortedPeers() -> [Peer] {
        return peers.values.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
    }

    /// START to the newest capable connection while active (again when the stream parameters changed).
    private func reconcile() {
        guard active else { return }
        guard newestCapable() != nil else {
            if noCapableSince == nil { noCapableSince = clock() }
            return
        }
        noCapableSince = nil
        noTabletReported = false
        guard let target = startTarget() else { return }
        let wanted = WifiMirrorSource.startControl(settings)
        guard target.startedWith != wanted else { return }
        send(wanted, to: target)
        target.startedWith = wanted
        if case .mirroring = status, streamerID == target.id { return }
        setStatus(.connecting(serial: target.label))
    }

    /// A decode error on the current stream (ink.queue): ask the streamer for a key frame.
    private func requestKeyFrame(generation: UInt64) {
        guard active, generation == streamGeneration, let id = streamerID, let peer = peers[id] else { return }
        send(.requestKeyFrame, to: peer)
    }

    /// Row 27 over Wi-Fi (ink.queue): STOP then START the streamer, which answers with a new MIRROR_HELLO and config,
    /// and the decoder is built again.
    private func restartStream(generation: UInt64, reason: String) {
        guard active, generation == streamGeneration, let id = streamerID, let peer = peers[id] else { return }
        log("mirror stream: \(reason); STOP then START to \(peer.label) (row 27)")
        send(.stop, to: peer)
        peer.startedWith = nil
        reconcile()
    }

    /// MIRROR_CONTROL, only to a connection that announced itself with MIRROR_STATUS (PROTOCOL 14.3).
    private func send(_ control: MirrorStream.Control, to peer: Peer) {
        guard peer.capable else {
            log("mirror stream: \(WifiMirrorSource.describe(control)) for \(peer.label) not sent (no MIRROR_STATUS yet)")
            return
        }
        let payload = MirrorStream.encode(.control(control), timestampUs: InkConnection.nowUs())
        peer.connection.transport.sendRaw(WebSocketFrame.encode(opcode: WebSocketFrame.opcodeBinary, payload: payload))
        if control.command != .requestKeyFrame { log("mirror stream: \(WifiMirrorSource.describe(control)) to \(peer.label)") }
    }

    private func setStatus(_ new: MirrorStatus) {
        let old = statusBox.withLock { s -> MirrorStatus in
            let previous = s
            s = new
            return previous
        }
        guard old != new else { return }
        log("wifi status: \(MirrorController.describe(new))")
        onStatusChange?(new)
    }

    private func updatePeerDiag() {
        let all = peers.values
        let streamer = streamerID.flatMap { peers[$0]?.label } ?? "none"
        let count = all.count
        let capable = all.filter { $0.capable }.count
        diagBox.withLock { d in
            d.connections = count
            d.capable = capable
            d.streamer = streamer
        }
    }

    private func startTimer() {
        guard autoTick, timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: inkQueue)
        t.schedule(deadline: .now() + WifiMirrorSource.tickInterval, repeating: WifiMirrorSource.tickInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func log(_ line: String) {
        WifiMirrorSource.log.notice("\(line, privacy: .public)")
        onLog?(line)
    }

    // MARK: Decode (mirror.queue)

    private func resetDecoder(label: String, generation: UInt64) {
        decoder?.invalidate()
        let decoder = H264Decoder(queue: mirrorQueue, clock: clock)
        decoder.onLog = { [weak self] line in self?.log(line) }
        decoder.onFrame = { [weak self] buffer, pts in self?.frameDecoded(buffer, ptsUs: pts) }
        self.decoder = decoder
        decoderGeneration = generation
        lastKeyFrameRequestAt = nil
        streamLabel = label
        decodeErrorLogged = false
        endEngage()
    }

    private func decodePacket(_ packet: ScrcpyPacket, label: String) {
        switch packet {
        case let .deviceMeta(name):
            diagBox.withLock { $0.deviceName = name }
        case .codec:
            break
        case let .session(width, height):
            slot.setSessionSize(width: Int(width), height: Int(height))
            diagBox.withLock { d in
                d.streamWidth = Int(width)
                d.streamHeight = Int(height)
            }
            endEngage()   // a new grid size primes the detector again
        case let .config(annexB):
            guard let decoder = decoder else { return }
            let sets = AnnexB.parameterSets(annexB)
            do {
                try decoder.setParameterSets(sps: sets.sps, pps: sets.pps)
            } catch {
                decodeFailed(error, label: label)
                // The tablet sends config once per encoder start: without a new one every frame fails (.noFormat).
                let now = clock()
                if lastRestartAt.map({ now - $0 >= WifiMirrorSource.restartInterval }) ?? true {
                    lastRestartAt = now
                    decoder.resetKeyFrameWait()
                    restart(reason: "parameter sets rejected (\(error))")
                }
            }
        case let .frame(ptsUs, keyFrame, annexB):
            guard let decoder = decoder else { return }
            submitTime = clock()
            do {
                try decoder.decode(annexB: annexB, ptsUs: ptsUs, keyFrame: keyFrame)
            } catch {
                decodeFailed(error, label: label)
            }
            let now = clock()
            if decoder.shouldRestartServer(now: now) {
                decoder.resetKeyFrameWait()
                lastRestartAt = now
                restart(reason: "no decodable key frame for \(Int(H264Decoder.keyFrameRestartSeconds)) s")
            }
        }
    }

    /// Hands a row 27 restart of the current stream to ink.queue (mirror.queue).
    private func restart(reason: String) {
        let generation = decoderGeneration
        inkQueue.async { [weak self] in self?.restartStream(generation: generation, reason: reason) }
    }

    private func decodeFailed(_ error: Error, label: String) {
        diagBox.withLock { $0.decodeErrors += 1 }
        if !decodeErrorLogged {
            decodeErrorLogged = true
            log(FailureText.logLine(.decoderError, ["\(error)"]))
        }
        let generation = decoderGeneration
        var wantsKeyFrame = false
        if let decodeError = error as? H264DecoderError {
            switch decodeError {
            case .decode, .output:
                // PROTOCOL 14.5: drop until a key frame and ask for one now, not at the next periodic IDR.
                let now = clock()
                if lastKeyFrameRequestAt.map({ now - $0 >= WifiMirrorSource.keyFrameRequestInterval }) ?? true {
                    lastKeyFrameRequestAt = now
                    wantsKeyFrame = true
                }
            default:
                break
            }
        }
        inkQueue.async { [weak self] in
            guard let self = self, self.active, generation == self.streamGeneration else { return }
            self.setStatus(.error(.decoderError, "\(error)"))
            if wantsKeyFrame { self.requestKeyFrame(generation: generation) }
        }
    }

    private func frameDecoded(_ buffer: CVPixelBuffer, ptsUs: UInt64) {
        let now = clock()
        let latency = (now - submitTime) * 1000
        slot.publish(buffer, ptsUs: ptsUs)
        decodedTimes.append(now)
        updateDecodedFps(now: now)
        diagBox.withLock { d in
            d.frames &+= 1
            d.latencyMs = d.latencyMs.map { $0 + (latency - $0) * WifiMirrorSource.latencyWeight } ?? latency
        }
        if decodeErrorLogged { decodeErrorLogged = false }
        var mirroring = false
        if case .mirroring = status { mirroring = true }
        if !mirroring {
            let size = slot.sessionSize
            let generation = decoderGeneration
            inkQueue.async { [weak self] in self?.frameArrived(width: size.w, height: size.h, generation: generation) }
        }
        if let geometry = slot.latest() {
            engage(buffer: buffer, uv: geometry.uv, orientation: geometry.orientation, now: now)
        }
    }

    private func updateDecodedFps(now: Double) {
        while let first = decodedTimes.first, now - first > 1 { decodedTimes.removeFirst() }
        let fps = decodedTimes.count
        diagBox.withLock { $0.decodedFps = fps }
    }

    // MARK: Engage (mirror.queue)

    /// Frame-difference engage for one decoded frame (mirror.queue). With the USB pen watcher present the pen is the
    /// engage source and the frame difference is ignored (a contact it holds is released first).
    func engage(buffer: CVPixelBuffer, uv: UVRect, orientation: StudioLayout.CanvasOrientation, now: Double) {
        if penWatcherPresent() {
            diagBox.withLock { $0.engageSource = .pen }
            endEngage()
            return
        }
        diagBox.withLock { $0.engageSource = .frameDiff }
        if !frameDiffNoticeShown {
            frameDiffNoticeShown = true
            log(FailureText.logLine(.wifiStreamFrameDiffEngage))
            onFailure?(.wifiStreamFrameDiffEngage, [])
        }
        let size = WifiMirrorSource.gridSize(orientation)
        guard let grid = WifiMirrorSource.lumaGrid(buffer, crop: uv, gridWidth: size.width, gridHeight: size.height) else { return }
        if let edge = frameDiff.feed(grid: grid, width: size.width, height: size.height, now: now) { emitEdge(edge) }
    }

    /// Forgets the previous grid; a contact the detector held is released with `penContact(down: false)`.
    private func endEngage() {
        let wasDown = frameDiff.isDown
        frameDiff.reset()
        if wasDown { onGovernorEvent?(.penContact(down: false)) }
    }

    private func emitEdge(_ edge: FrameDiffEngage.Edge) {
        onGovernorEvent?(.penContact(down: edge == .down))
    }

    /// Test hook (mirror.queue): the detector's contact state.
    var frameDiffIsDown: Bool { return frameDiff.isDown }
}
