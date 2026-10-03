import Foundation

/// The PROTOCOL 14.5 rules for ONE connection as a pure state machine (time injected, seconds on any monotonic clock).
///
/// - MIRROR_HELLO starts a stream: a fresh `ScrcpyDemuxer(expectsDummyByte: false)` gets its 68 bytes, and
///   `.streamStarted` is followed by the demuxer's `.deviceMeta` and `.codec` packets.
/// - MIRROR_PACKET feeds its 12 + n bytes to that demuxer; every emitted `ScrcpyPacket` becomes `.packet`.
/// - MIRROR_PACKET before any MIRROR_HELLO: one `.log`, then dropped silently.
/// - A demuxer error, a media packet whose `size` differs from n, or a session packet with n > 0: dropped, the demuxer
///   is reset (re-primed with the last HELLO, no packets re-emitted) and `.send(.requestKeyFrame)` is emitted at most
///   once per `keyFrameRequestMinInterval`.
/// - Stall: while the last MIRROR_STATUS said STREAMING and no MIRROR_PACKET came for `stallSeconds`,
///   `tick` emits `[.stalled, .send(.requestKeyFrame)]`, and again every `stallSeconds` while it lasts.
public struct MirrorStreamReceiver {
    public enum Output: Equatable {
        case packet(ScrcpyPacket)
        case status(MirrorStream.Status)
        case send(MirrorStream.Control)
        case stalled
        case log(String)
        case streamStarted(deviceName: String)
    }

    public static let stallSeconds = 2.0
    public static let keyFrameRequestMinInterval = 1.0

    public private(set) var lastStatus: MirrorStream.Status?
    public private(set) var hasHello: Bool = false
    /// The device name of the current stream's HELLO.
    public private(set) var deviceName: String?

    private var demuxer: ScrcpyDemuxer?
    private var helloBytes: [UInt8]?
    private var lastPacketAt: Double?
    private var streamingSince: Double?
    private var lastStallAt: Double?
    private var lastKeyFrameRequestAt: Double?
    private var loggedPacketBeforeHello = false
    private var loggedControlFromClient = false

    public init() {}

    /// Feeds one decoded message.
    public mutating func receive(_ message: MirrorStream.Message, now: Double) -> [Output] {
        switch message {
        case let .hello(name, codecID):
            return receiveHello(name: name, codecID: codecID, message: message, now: now)
        case .packet:
            return receivePacket(message, now: now)
        case let .status(status):
            if status.state == .streaming && lastStatus?.state != .streaming {
                streamingSince = now
                lastStallAt = nil
            }
            lastStatus = status
            return [.status(status)]
        case .control:
            if loggedControlFromClient { return [] }
            loggedControlFromClient = true
            return [.log("mirror stream: MIRROR_CONTROL from a client dropped")]
        }
    }

    /// Feeds one raw SolStream frame of the mirror family: decodes it and applies the PROTOCOL 14.5 rules, including the
    /// ones that only a decode error can reveal (size field mismatch, session packet with payload). A frame that is not
    /// a mirror message returns no output.
    public mutating func receive(frame: [UInt8], now: Double) -> [Output] {
        do {
            let decoded = try MirrorStream.decode(frame)
            return receive(decoded.message, now: now)
        } catch let error as MirrorStream.DecodeError {
            return receive(decodeError: error, opcode: MirrorStream.peekOpcode(frame), now: now)
        } catch {
            return [.log("mirror stream: frame dropped (\(error))")]
        }
    }

    /// Applies the rule for a frame `MirrorStream.decode` rejected. A malformed MIRROR_PACKET of a started stream resets
    /// the demuxer and requests a key frame (rate limited); everything else is logged and dropped.
    public mutating func receive(decodeError: MirrorStream.DecodeError, opcode: UInt16?, now: Double) -> [Output] {
        if decodeError == .notMirror { return [] }
        let log = Output.log("mirror stream: frame dropped (\(decodeError))")
        guard opcode == MirrorStream.opcodePacket else { return [log] }
        guard hasHello else { return packetBeforeHello() }
        return [log] + resetDemuxerAndRequestKeyFrame(now: now)
    }

    /// The stall rule (PROTOCOL 14.5).
    public mutating func tick(now: Double) -> [Output] {
        guard let status = lastStatus, status.state == .streaming else { return [] }
        var reference = -Double.infinity
        if let t = lastPacketAt { reference = max(reference, t) }
        if let t = streamingSince { reference = max(reference, t) }
        if let t = lastStallAt { reference = max(reference, t) }
        guard now - reference >= MirrorStreamReceiver.stallSeconds else { return [] }
        lastStallAt = now
        lastKeyFrameRequestAt = now
        return [.stalled, .send(MirrorStream.Control.requestKeyFrame)]
    }

    public mutating func reset() {
        self = MirrorStreamReceiver()
    }

    // MARK: Private

    private mutating func receiveHello(name: String, codecID: UInt32, message: MirrorStream.Message, now: Double) -> [Output] {
        let bytes = MirrorStream.scrcpyBytes(message) ?? []
        var fresh = ScrcpyDemuxer(expectsDummyByte: false)
        var out: [Output] = [.streamStarted(deviceName: name)]
        do {
            try fresh.feed(bytes) { out.append(.packet($0)) }
        } catch {
            hasHello = false
            demuxer = nil
            helloBytes = nil
            deviceName = nil
            out.append(.log("mirror stream: HELLO from \(name) rejected (\(error)), codec id \(codecID)"))
            return out
        }
        demuxer = fresh
        helloBytes = bytes
        hasHello = true
        deviceName = name
        lastPacketAt = now
        lastStallAt = nil
        return out
    }

    private mutating func receivePacket(_ message: MirrorStream.Message, now: Double) -> [Output] {
        guard hasHello, var current = demuxer, let bytes = MirrorStream.scrcpyBytes(message) else { return packetBeforeHello() }
        lastPacketAt = now
        var out: [Output] = []
        do {
            try current.feed(bytes) { out.append(.packet($0)) }
            demuxer = current
        } catch {
            out.append(.log("mirror stream: packet dropped (\(error))"))
            out.append(contentsOf: resetDemuxerAndRequestKeyFrame(now: now))
        }
        return out
    }

    private mutating func packetBeforeHello() -> [Output] {
        if loggedPacketBeforeHello { return [] }
        loggedPacketBeforeHello = true
        return [.log("mirror stream: MIRROR_PACKET before MIRROR_HELLO dropped")]
    }

    private mutating func resetDemuxerAndRequestKeyFrame(now: Double) -> [Output] {
        var fresh = ScrcpyDemuxer(expectsDummyByte: false)
        if let bytes = helloBytes {
            try? fresh.feed(bytes) { _ in }
        }
        demuxer = fresh
        if let last = lastKeyFrameRequestAt, now - last < MirrorStreamReceiver.keyFrameRequestMinInterval {
            return []
        }
        lastKeyFrameRequestAt = now
        return [.send(MirrorStream.Control.requestKeyFrame)]
    }
}
