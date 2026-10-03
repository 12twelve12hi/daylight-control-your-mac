import Foundation

public enum ScrcpyPacket: Equatable {
    case deviceMeta(name: String)
    case codec(id: UInt32)
    case session(width: UInt32, height: UInt32)
    case config(annexB: [UInt8])
    case frame(ptsUs: UInt64, keyFrame: Bool, annexB: [UInt8])
}

public enum ScrcpyError: Error, Equatable {
    case codecDisabled
    case codecConfigError
    case unknownCodec(UInt32)
    case badPacketSize(UInt32)
}

/// Parses the scrcpy 4.1 video socket (dummy byte, device meta, codec id, session, frame headers). Lands in M5.
public struct ScrcpyDemuxer {
    public private(set) var expectsDummyByte = true
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: UnsafeRawBufferPointer, emit: (ScrcpyPacket) -> Void) throws {
        buffer.append(contentsOf: bytes)
        // M5: demux buffer into packets.
    }
}

public enum AnnexB {
    public static func nalUnits(_ annexB: UnsafeRawBufferPointer) -> [Range<Int>] { return [] }
    public static func containsIDR(_ annexB: UnsafeRawBufferPointer) -> Bool { return false }
}
