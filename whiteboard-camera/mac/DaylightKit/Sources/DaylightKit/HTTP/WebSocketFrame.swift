import Foundation

public enum WebSocketError: Error, Equatable {
    case reservedBits
    case unmaskedClientFrame
    case oversize(Int)
    case controlFrameTooLong
    case fragmentedControl
}

/// RFC 6455 framing. Skeleton: server-side encode is real; parse lands with the server in M3.
public struct WebSocketFrame: Equatable {
    public var fin: Bool
    public var opcode: UInt8
    public var payload: [UInt8]

    public static let opcodeText: UInt8 = 0x1
    public static let opcodeBinary: UInt8 = 0x2
    public static let opcodeClose: UInt8 = 0x8
    public static let opcodePing: UInt8 = 0x9
    public static let opcodePong: UInt8 = 0xA

    public init(fin: Bool, opcode: UInt8, payload: [UInt8]) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
    }

    public static func parse(_ buffer: inout [UInt8], maxPayload: Int) throws -> (frame: WebSocketFrame, consumed: Int)? {
        return nil   // M3
    }

    /// Server frames are never masked.
    public static func encode(opcode: UInt8, payload: UnsafeRawBufferPointer, into out: inout [UInt8]) {
        out.append(0x80 | (opcode & 0x0F))
        let n = payload.count
        if n < 126 {
            out.append(UInt8(n))
        } else if n <= 0xFFFF {
            out.append(126)
            out.append(UInt8(truncatingIfNeeded: n >> 8))
            out.append(UInt8(truncatingIfNeeded: n))
        } else {
            out.append(127)
            for i in (0..<8).reversed() {
                out.append(UInt8(truncatingIfNeeded: UInt64(n) >> (8 * UInt64(i))))
            }
        }
        out.append(contentsOf: payload)
    }

    public static func encodeClose(code: UInt16, reason: String) -> [UInt8] {
        var payload: [UInt8] = [UInt8(truncatingIfNeeded: code >> 8), UInt8(truncatingIfNeeded: code)]
        payload.append(contentsOf: Array(reason.utf8).prefix(123))
        var out: [UInt8] = []
        payload.withUnsafeBytes { encode(opcode: opcodeClose, payload: $0, into: &out) }
        return out
    }
}
