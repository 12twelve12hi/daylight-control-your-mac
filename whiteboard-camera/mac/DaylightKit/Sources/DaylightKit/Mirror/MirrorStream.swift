import Foundation

/// The mirror stream family of SolStream (docs/PROTOCOL.md section 14, LOOSE_ENDS A9): Daylight Ink captures the
/// tablet screen and sends the scrcpy 4.1 video-socket bytes inside SolStream frames on its existing WebSocket.
///
/// Byte order: the 16-byte SolStream header is little-endian; the scrcpy parts (MIRROR_HELLO's codec id and the whole
/// 12-byte MIRROR_PACKET header) are BIG-endian; MIRROR_STATUS and MIRROR_CONTROL are little-endian payloads.
public enum MirrorStream {
    public static let opcodeControl: UInt16 = 0x0071
    public static let opcodeHello: UInt16 = 0x0080
    public static let opcodePacket: UInt16 = 0x0081
    public static let opcodeStatus: UInt16 = 0x0082

    /// Payload sizes (PROTOCOL 14.1 to 14.4).
    public static let helloLength = 68
    public static let statusLength = 16
    public static let controlLength = 12
    /// The 12-byte scrcpy packet header at the start of every MIRROR_PACKET.
    public static let packetHeaderLength = 12
    /// The 64-byte NUL-padded device name of MIRROR_HELLO (at most 63 name bytes).
    public static let deviceNameFieldLength = 64
    public static let maxDeviceNameBytes = 63

    /// The SolStream payload cap (1 MiB) minus the 12-byte scrcpy header.
    public static let maxAnnexBBytes = 1_048_564

    /// True for 0x0071 and 0x0080...0x008F (the whole mirror family, including the reserved opcodes).
    public static func isMirrorOpcode(_ opcode: UInt16) -> Bool {
        return opcode == opcodeControl || (opcode >= 0x0080 && opcode <= 0x008F)
    }

    /// Reads bytes 2...3 of a raw SolStream frame (little-endian); nil when the frame is shorter than 16 bytes or the
    /// magic or version is wrong.
    public static func peekOpcode(_ frame: [UInt8]) -> UInt16? {
        guard frame.count >= SolStream.headerLength, frame[0] == SolStream.magic, frame[1] == SolStream.version else { return nil }
        return UInt16(frame[2]) | (UInt16(frame[3]) << 8)
    }

    /// MIRROR_STATUS state byte (PROTOCOL 14.3).
    public enum State: UInt8 {
        case idle = 0
        case consentNeeded = 1
        case starting = 2
        case streaming = 3
        case paused = 4
        case consentDenied = 5
        case encoderUnavailable = 6
        case projectionEnded = 7
        case unsupported = 8
    }

    /// MIRROR_STATUS flags byte (PROTOCOL 14.3). Unknown bits are kept so a status round-trips.
    public struct StatusFlags: OptionSet, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let projectionHeld = StatusFlags(rawValue: 1)
        public static let thermalReduced = StatusFlags(rawValue: 2)
        public static let powerSave = StatusFlags(rawValue: 4)
        public static let backpressure = StatusFlags(rawValue: 8)
    }

    /// MIRROR_STATUS (0x0082), client to server, 16 bytes `<BBHHHII`.
    public struct Status: Equatable {
        public var state: State
        public var flags: StatusFlags
        public var fpsX10: UInt16
        public var width: UInt16
        public var height: UInt16
        public var bitrateBps: UInt32
        public var sentBps: UInt32

        public init(state: State, flags: StatusFlags = [], fpsX10: UInt16 = 0, width: UInt16 = 0, height: UInt16 = 0, bitrateBps: UInt32 = 0, sentBps: UInt32 = 0) {
            self.state = state
            self.flags = flags
            self.fpsX10 = fpsX10
            self.width = width
            self.height = height
            self.bitrateBps = bitrateBps
            self.sentBps = sentBps
        }
    }

    /// MIRROR_CONTROL command byte (PROTOCOL 14.4).
    public enum Command: UInt8 {
        case stop = 0
        case start = 1
        case requestKeyFrame = 2
        case release = 3
    }

    /// MIRROR_CONTROL (0x0071), server to client, 12 bytes `<BBHIHH`.
    public struct Control: Equatable {
        public var command: Command
        public var maxSize: UInt16
        public var bitrateBps: UInt32
        public var maxFps: UInt16
        public var keyIntervalMs: UInt16

        public init(command: Command, maxSize: UInt16 = 0, bitrateBps: UInt32 = 0, maxFps: UInt16 = 0, keyIntervalMs: UInt16 = 0) {
            self.command = command
            self.maxSize = maxSize
            self.bitrateBps = bitrateBps
            self.maxFps = maxFps
            self.keyIntervalMs = keyIntervalMs
        }

        // PROTOCOL 14.4 defaults and ranges.
        public static let defaultMaxSize: UInt16 = 1600
        public static let maxSizeRange: ClosedRange<UInt16> = 320...1600
        public static let maxSizeStep: UInt16 = 16
        public static let defaultBitrateBps: UInt32 = 7_000_000
        public static let bitrateRange: ClosedRange<UInt32> = 1_000_000...8_000_000
        public static let defaultMaxFps: UInt16 = 30
        public static let maxFpsRange: ClosedRange<UInt16> = 1...30
        public static let defaultKeyIntervalMs: UInt16 = 2000
        public static let keyIntervalRange: ClosedRange<UInt16> = 500...10000

        public static func start(maxSize: UInt16, bitrateBps: UInt32, maxFps: UInt16, keyIntervalMs: UInt16) -> Control {
            return Control(command: .start, maxSize: maxSize, bitrateBps: bitrateBps, maxFps: maxFps, keyIntervalMs: keyIntervalMs)
        }

        public static let stop = Control(command: .stop)
        public static let requestKeyFrame = Control(command: .requestKeyFrame)
        public static let release = Control(command: .release)

        /// PROTOCOL 14.4: 0 means the default; max_size clamped to 320...1600 and rounded down to a multiple of 16;
        /// bit rate 1,000,000...8,000,000 (default 7,000,000); fps 1...30 (default 30); key interval 500...10000 ms
        /// (default 2000). The parameters matter for START only: STOP, REQUEST_KEY_FRAME and RELEASE resolve to zeros.
        public func resolved() -> Control {
            guard command == .start else { return Control(command: command) }
            var size = maxSize == 0 ? Control.defaultMaxSize : Control.clamp(maxSize, Control.maxSizeRange)
            size -= size % Control.maxSizeStep
            let bitrate = bitrateBps == 0 ? Control.defaultBitrateBps : Control.clamp(bitrateBps, Control.bitrateRange)
            let fps = maxFps == 0 ? Control.defaultMaxFps : Control.clamp(maxFps, Control.maxFpsRange)
            let key = keyIntervalMs == 0 ? Control.defaultKeyIntervalMs : Control.clamp(keyIntervalMs, Control.keyIntervalRange)
            return Control(command: .start, maxSize: size, bitrateBps: bitrate, maxFps: fps, keyIntervalMs: key)
        }

        static func clamp<T: Comparable>(_ v: T, _ r: ClosedRange<T>) -> T {
            return min(max(v, r.lowerBound), r.upperBound)
        }
    }

    /// The payload of MIRROR_PACKET: a scrcpy session packet or a media packet (PROTOCOL 14.2).
    public enum Packet: Equatable {
        /// Session packet (byte 0 bit 7 set, n = 0): the encoder's output size.
        case session(width: UInt32, height: UInt32)
        /// Media packet: `ptsFlags` (bit 62 config, bit 61 key frame, low 61 bits PTS in microseconds) and Annex-B bytes.
        case media(ptsFlags: UInt64, annexB: [UInt8])

        /// A codec-config packet (SPS and PPS).
        public static func config(ptsUs: UInt64 = 0, annexB: [UInt8]) -> Packet {
            return .media(ptsFlags: ScrcpyDemuxer.flagConfig | (ptsUs & ScrcpyDemuxer.ptsMask), annexB: annexB)
        }

        /// One access unit.
        public static func frame(ptsUs: UInt64, keyFrame: Bool, annexB: [UInt8]) -> Packet {
            var flags = ptsUs & ScrcpyDemuxer.ptsMask
            if keyFrame { flags |= ScrcpyDemuxer.flagKeyFrame }
            return .media(ptsFlags: flags, annexB: annexB)
        }
    }

    public enum Message: Equatable {
        case hello(deviceName: String, codecID: UInt32)
        case packet(Packet)
        case status(Status)
        case control(Control)

        public var opcode: UInt16 {
            switch self {
            case .hello: return MirrorStream.opcodeHello
            case .packet: return MirrorStream.opcodePacket
            case .status: return MirrorStream.opcodeStatus
            case .control: return MirrorStream.opcodeControl
            }
        }
    }

    public enum DecodeError: Error, Equatable {
        /// Not a mirror-family opcode, or a reserved one (0x0083...0x008F) this build does not know (ignored like any unknown opcode).
        case notMirror
        case tooShort
        case badMagicOrVersion
        /// payload_len differs from frame.count - 16.
        case lengthMismatch
        /// HELLO not 68 bytes, STATUS not 16, CONTROL not 12, PACKET under 12; `size` is the payload length.
        case wrongSize(opcode: UInt16, size: Int)
        /// A media packet whose `size` field differs from the Annex-B byte count n.
        case sizeFieldMismatch(declared: UInt32, actual: Int)
        /// A session packet with n > 0.
        case sessionWithPayload
        /// A media packet with n = 0.
        case emptyMedia
        case unknownState(UInt8)
        case unknownCommand(UInt8)
        /// payload_len over the 1 MiB SolStream cap.
        case tooLarge
    }

    // MARK: Decode

    /// Whole frame (16-byte little-endian header plus payload) to a message.
    public static func decode(_ frame: [UInt8]) throws -> (timestampUs: UInt64, message: Message) {
        guard frame.count >= SolStream.headerLength else { throw DecodeError.tooShort }
        guard frame[0] == SolStream.magic, frame[1] == SolStream.version else { throw DecodeError.badMagicOrVersion }
        let opcode = UInt16(frame[2]) | (UInt16(frame[3]) << 8)
        guard opcode == opcodeControl || opcode == opcodeHello || opcode == opcodePacket || opcode == opcodeStatus else {
            throw DecodeError.notMirror
        }
        let declared = readLE32(frame, at: 4)
        guard declared <= UInt32(SolStream.maxPayload) else { throw DecodeError.tooLarge }
        guard Int(declared) == frame.count - SolStream.headerLength else { throw DecodeError.lengthMismatch }
        let timestamp = UInt64(readLE32(frame, at: 8)) | (UInt64(readLE32(frame, at: 12)) << 32)
        let p = SolStream.headerLength
        let size = frame.count - p

        switch opcode {
        case opcodeHello:
            guard size == helloLength else { throw DecodeError.wrongSize(opcode: opcode, size: size) }
            var nameBytes: [UInt8] = []
            for i in 0..<deviceNameFieldLength {
                let b = frame[p + i]
                if b == 0 { break }
                nameBytes.append(b)
            }
            let name = String(decoding: nameBytes, as: UTF8.self)
            let codec = readBE32(frame, at: p + deviceNameFieldLength)
            return (timestamp, .hello(deviceName: name, codecID: codec))

        case opcodePacket:
            guard size >= packetHeaderLength else { throw DecodeError.wrongSize(opcode: opcode, size: size) }
            let n = size - packetHeaderLength
            if frame[p] & ScrcpyDemuxer.flagSession != 0 {
                guard n == 0 else { throw DecodeError.sessionWithPayload }
                return (timestamp, .packet(.session(width: readBE32(frame, at: p + 4), height: readBE32(frame, at: p + 8))))
            }
            let ptsFlags = (UInt64(readBE32(frame, at: p)) << 32) | UInt64(readBE32(frame, at: p + 4))
            let declaredSize = readBE32(frame, at: p + 8)
            guard n > 0 else { throw DecodeError.emptyMedia }
            guard Int(declaredSize) == n else { throw DecodeError.sizeFieldMismatch(declared: declaredSize, actual: n) }
            guard n <= maxAnnexBBytes else { throw DecodeError.tooLarge }
            let annexB = Array(frame[(p + packetHeaderLength)...])
            return (timestamp, .packet(.media(ptsFlags: ptsFlags, annexB: annexB)))

        case opcodeStatus:
            guard size == statusLength else { throw DecodeError.wrongSize(opcode: opcode, size: size) }
            guard let state = State(rawValue: frame[p]) else { throw DecodeError.unknownState(frame[p]) }
            let status = Status(
                state: state,
                flags: StatusFlags(rawValue: frame[p + 1]),
                fpsX10: readLE16(frame, at: p + 2),
                width: readLE16(frame, at: p + 4),
                height: readLE16(frame, at: p + 6),
                bitrateBps: readLE32(frame, at: p + 8),
                sentBps: readLE32(frame, at: p + 12)
            )
            return (timestamp, .status(status))

        default:
            guard size == controlLength else { throw DecodeError.wrongSize(opcode: opcode, size: size) }
            guard let command = Command(rawValue: frame[p]) else { throw DecodeError.unknownCommand(frame[p]) }
            let control = Control(
                command: command,
                maxSize: readLE16(frame, at: p + 2),
                bitrateBps: readLE32(frame, at: p + 4),
                maxFps: readLE16(frame, at: p + 8),
                keyIntervalMs: readLE16(frame, at: p + 10)
            )
            return (timestamp, .control(control))
        }
    }

    // MARK: Encode

    /// Message to a whole frame with the header (magic 0xDA, version 1, little-endian header).
    public static func encode(_ message: Message, timestampUs: UInt64) -> [UInt8] {
        let payload = payloadBytes(message)
        var w = ByteWriter(reserving: SolStream.headerLength + payload.count)
        w.u8(SolStream.magic)
        w.u8(SolStream.version)
        w.u16(message.opcode)
        w.u32(UInt32(payload.count))
        w.u64(timestampUs)
        w.bytes(payload)
        return w.storage
    }

    /// The scrcpy bytes a HELLO or PACKET contributes to the demuxer stream (HELLO: 68 bytes; PACKET: 12 + n); nil for
    /// status and control.
    public static func scrcpyBytes(_ message: Message) -> [UInt8]? {
        switch message {
        case .hello, .packet: return payloadBytes(message)
        case .status, .control: return nil
        }
    }

    /// The UTF-8 bytes of `name` truncated to at most 63 bytes without splitting a scalar (PROTOCOL 14.1).
    public static func truncatedDeviceName(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        for scalar in name.unicodeScalars {
            let encoded = Array(String(scalar).utf8)
            if out.count + encoded.count > maxDeviceNameBytes { break }
            out.append(contentsOf: encoded)
        }
        return out
    }

    static func payloadBytes(_ message: Message) -> [UInt8] {
        var w = ByteWriter(reserving: 64)
        switch message {
        case let .hello(deviceName, codecID):
            let name = truncatedDeviceName(deviceName)
            w.bytes(name)
            w.bytes([UInt8](repeating: 0, count: deviceNameFieldLength - name.count))
            w.bytes(ScrcpyStreamBuilder.u32(codecID))
        case let .packet(.session(width, height)):
            w.bytes([ScrcpyDemuxer.flagSession, 0, 0, 0])
            w.bytes(ScrcpyStreamBuilder.u32(width))
            w.bytes(ScrcpyStreamBuilder.u32(height))
        case let .packet(.media(ptsFlags, annexB)):
            w.bytes(ScrcpyStreamBuilder.u64(ptsFlags))
            w.bytes(ScrcpyStreamBuilder.u32(UInt32(truncatingIfNeeded: annexB.count)))
            w.bytes(annexB)
        case let .status(s):
            w.u8(s.state.rawValue)
            w.u8(s.flags.rawValue)
            w.u16(s.fpsX10)
            w.u16(s.width)
            w.u16(s.height)
            w.u32(s.bitrateBps)
            w.u32(s.sentBps)
        case let .control(c):
            w.u8(c.command.rawValue)
            w.u8(0)
            w.u16(c.maxSize)
            w.u32(c.bitrateBps)
            w.u16(c.maxFps)
            w.u16(c.keyIntervalMs)
        }
        return w.storage
    }

    // MARK: Byte helpers

    static func readLE16(_ b: [UInt8], at i: Int) -> UInt16 {
        return UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    static func readLE32(_ b: [UInt8], at i: Int) -> UInt32 {
        return UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    static func readBE32(_ b: [UInt8], at i: Int) -> UInt32 {
        return (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }
}

extension Settings {
    /// The MIRROR_CONTROL START these settings ask for, already resolved (PROTOCOL 14.4).
    public var mirrorStreamStartControl: MirrorStream.Control {
        let v = validated()
        return MirrorStream.Control.start(
            maxSize: UInt16(clamping: v.mirrorStreamMaxSize),
            bitrateBps: UInt32(clamping: v.mirrorStreamBitRate),
            maxFps: UInt16(clamping: v.mirrorStreamMaxFps),
            keyIntervalMs: UInt16(clamping: v.mirrorStreamKeyIntervalMs)
        ).resolved()
    }

    /// The frame-diff engage configuration: the defaults with `mirrorDiffThreshold` as `changedFraction`.
    public var frameDiffEngageConfig: FrameDiffEngage.Config {
        return FrameDiffEngage.Config(changedFraction: validated().mirrorDiffThreshold)
    }
}
