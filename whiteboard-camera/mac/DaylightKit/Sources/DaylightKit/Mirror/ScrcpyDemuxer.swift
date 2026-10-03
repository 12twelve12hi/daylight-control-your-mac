import Foundation

/// One unit of the scrcpy 4.1 video socket (ARCHITECTURE 6 item 4, research-scrcpy-adb section 1.4).
public enum ScrcpyPacket: Equatable {
    /// The 64-byte `Build.MODEL` field, NUL padding removed.
    case deviceMeta(name: String)
    /// The 4-byte codec id (`0x68323634` is "h264").
    case codec(id: UInt32)
    /// A 12-byte session packet: the encoder's output size. Re-sent on every capture change (rotation, encoder fallback).
    case session(width: UInt32, height: UInt32)
    /// A codec-config packet: SPS and PPS in Annex-B form.
    case config(annexB: [UInt8])
    /// One encoded access unit in Annex-B form; `ptsUs` is `MediaCodec.BufferInfo.presentationTimeUs`.
    case frame(ptsUs: UInt64, keyFrame: Bool, annexB: [UInt8])
}

public enum ScrcpyError: Error, Equatable {
    /// Codec id 0: the device explicitly disabled the stream.
    case codecDisabled
    /// Codec id 1: a configuration error on the device (stop).
    case codecConfigError
    /// Any codec id other than h264 (this app negotiates `video_codec=h264` only).
    case unknownCodec(UInt32)
    /// A media packet header with a zero (or absurd) payload size.
    case badPacketSize(UInt32)
}

/// Parses the scrcpy 4.1 video socket incrementally. Every multi-byte integer is big-endian. Order on the wire:
/// dummy byte `0x00`, 64-byte device meta, 4-byte codec id, then 12-byte headers. A header whose byte 0 has bit 7 set
/// is a session packet (bytes 4...7 width, 8...11 height); otherwise it is `u64 pts_flags` (bit 62 config, bit 61 key
/// frame, low 61 bits PTS in microseconds) and `u32 size` followed by `size` payload bytes.
///
/// `feed` accepts any chunking (1 byte at a time or whole segments) and emits packets as soon as they are complete.
public struct ScrcpyDemuxer {
    public static let deviceMetaLength = 64
    public static let headerLength = 12
    public static let codecH264: UInt32 = 0x6832_3634
    public static let flagSession: UInt8 = 0x80
    public static let flagConfig: UInt64 = 1 << 62
    public static let flagKeyFrame: UInt64 = 1 << 61
    public static let ptsMask: UInt64 = (1 << 61) - 1
    /// Larger payloads than this are treated as a framing error (a 1600x1200 key frame is well under 2 MiB).
    public static let maxPacketSize: UInt32 = 16 * 1024 * 1024

    private enum Stage: Equatable {
        case dummyByte
        case deviceMeta
        case codec
        case header
        case payload(ptsFlags: UInt64, size: Int)
    }

    public private(set) var expectsDummyByte: Bool
    private var stage: Stage
    private var buffer: [UInt8] = []
    private var consumed = 0

    /// `expectsDummyByte` is false when the caller already read the `0x00` liveness byte itself (ScrcpySession does).
    public init(expectsDummyByte: Bool = true) {
        self.expectsDummyByte = expectsDummyByte
        stage = expectsDummyByte ? .dummyByte : .deviceMeta
    }

    /// Number of buffered bytes not yet turned into a packet.
    public var pendingByteCount: Int { return buffer.count - consumed }

    public mutating func feed(_ bytes: UnsafeRawBufferPointer, emit: (ScrcpyPacket) -> Void) throws {
        if !bytes.isEmpty { buffer.append(contentsOf: bytes) }
        try drain(emit: emit)
    }

    public mutating func feed(_ bytes: [UInt8], emit: (ScrcpyPacket) -> Void) throws {
        buffer.append(contentsOf: bytes)
        try drain(emit: emit)
    }

    private mutating func drain(emit: (ScrcpyPacket) -> Void) throws {
        while true {
            let available = buffer.count - consumed
            switch stage {
            case .dummyByte:
                guard available >= 1 else { compact(); return }
                consumed += 1
                expectsDummyByte = false
                stage = .deviceMeta
            case .deviceMeta:
                guard available >= ScrcpyDemuxer.deviceMetaLength else { compact(); return }
                let slice = buffer[consumed..<(consumed + ScrcpyDemuxer.deviceMetaLength)]
                consumed += ScrcpyDemuxer.deviceMetaLength
                let nameBytes = Array(slice.prefix { $0 != 0 })
                emit(.deviceMeta(name: String(decoding: nameBytes, as: UTF8.self)))
                stage = .codec
            case .codec:
                guard available >= 4 else { compact(); return }
                let id = ScrcpyDemuxer.readU32(buffer, at: consumed)
                consumed += 4
                switch id {
                case 0: throw ScrcpyError.codecDisabled
                case 1: throw ScrcpyError.codecConfigError
                case ScrcpyDemuxer.codecH264: break
                default: throw ScrcpyError.unknownCodec(id)
                }
                emit(.codec(id: id))
                stage = .header
            case .header:
                guard available >= ScrcpyDemuxer.headerLength else { compact(); return }
                let first = buffer[consumed]
                if first & ScrcpyDemuxer.flagSession != 0 {
                    let width = ScrcpyDemuxer.readU32(buffer, at: consumed + 4)
                    let height = ScrcpyDemuxer.readU32(buffer, at: consumed + 8)
                    consumed += ScrcpyDemuxer.headerLength
                    emit(.session(width: width, height: height))
                } else {
                    let ptsFlags = ScrcpyDemuxer.readU64(buffer, at: consumed)
                    let size = ScrcpyDemuxer.readU32(buffer, at: consumed + 8)
                    guard size > 0, size <= ScrcpyDemuxer.maxPacketSize else { throw ScrcpyError.badPacketSize(size) }
                    consumed += ScrcpyDemuxer.headerLength
                    stage = .payload(ptsFlags: ptsFlags, size: Int(size))
                }
            case let .payload(ptsFlags, size):
                guard available >= size else { compact(); return }
                let payload = Array(buffer[consumed..<(consumed + size)])
                consumed += size
                stage = .header
                if ptsFlags & ScrcpyDemuxer.flagConfig != 0 {
                    emit(.config(annexB: payload))
                } else {
                    emit(.frame(ptsUs: ptsFlags & ScrcpyDemuxer.ptsMask, keyFrame: ptsFlags & ScrcpyDemuxer.flagKeyFrame != 0, annexB: payload))
                }
            }
        }
    }

    /// Drops consumed bytes once they dominate the buffer, so a long session does not grow memory.
    private mutating func compact() {
        if consumed == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            consumed = 0
        } else if consumed > 65536 && consumed > buffer.count / 2 {
            buffer.removeFirst(consumed)
            consumed = 0
        }
    }

    static func readU32(_ b: [UInt8], at i: Int) -> UInt32 {
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    static func readU64(_ b: [UInt8], at i: Int) -> UInt64 {
        return UInt64(readU32(b, at: i)) << 32 | UInt64(readU32(b, at: i + 4))
    }
}

/// Builds the bytes the scrcpy 4.1 server writes, for tests and for a fake server (the inverse of `ScrcpyDemuxer`).
public enum ScrcpyStreamBuilder {
    public static func dummyByte() -> [UInt8] { return [0x00] }

    public static func deviceMeta(name: String) -> [UInt8] {
        var bytes = Array(name.utf8.prefix(ScrcpyDemuxer.deviceMetaLength - 1))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: ScrcpyDemuxer.deviceMetaLength - bytes.count))
        return bytes
    }

    public static func codec(id: UInt32 = ScrcpyDemuxer.codecH264) -> [UInt8] {
        return u32(id)
    }

    public static func session(width: UInt32, height: UInt32, clientResized: Bool = false) -> [UInt8] {
        return [ScrcpyDemuxer.flagSession, 0, 0, clientResized ? 1 : 0] + u32(width) + u32(height)
    }

    public static func config(annexB: [UInt8]) -> [UInt8] {
        return u64(ScrcpyDemuxer.flagConfig) + u32(UInt32(annexB.count)) + annexB
    }

    public static func frame(ptsUs: UInt64, keyFrame: Bool, annexB: [UInt8]) -> [UInt8] {
        var flags = ptsUs & ScrcpyDemuxer.ptsMask
        if keyFrame { flags |= ScrcpyDemuxer.flagKeyFrame }
        return u64(flags) + u32(UInt32(annexB.count)) + annexB
    }

    public static func u32(_ v: UInt32) -> [UInt8] {
        return [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    public static func u64(_ v: UInt64) -> [UInt8] {
        return u32(UInt32(v >> 32)) + u32(UInt32(v & 0xFFFF_FFFF))
    }
}
