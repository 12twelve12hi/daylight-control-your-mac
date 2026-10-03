import Foundation

public enum WebSocketError: Error, Equatable {
    case reservedBits
    /// A reserved opcode (0x3 to 0x7 or 0xB to 0xF); RFC 6455 section 5.2 says the endpoint must fail the connection.
    case reservedOpcode(UInt8)
    case unmaskedClientFrame
    case oversize(Int)
    case controlFrameTooLong
    case fragmentedControl
    /// A continuation frame with no message in progress, or a new data frame while one is in progress.
    case badContinuation
}

/// RFC 6455 framing. `parse` reads client frames (masked) from the front of a receive buffer; `encode` writes server
/// frames (never masked).
public struct WebSocketFrame: Equatable {
    public var fin: Bool
    public var opcode: UInt8
    public var payload: [UInt8]

    public static let opcodeContinuation: UInt8 = 0x0
    public static let opcodeText: UInt8 = 0x1
    public static let opcodeBinary: UInt8 = 0x2
    public static let opcodeClose: UInt8 = 0x8
    public static let opcodePing: UInt8 = 0x9
    public static let opcodePong: UInt8 = 0xA

    /// 2 MiB receive buffer per connection (PROTOCOL section 1).
    public static let defaultMaxPayload = 2 * 1024 * 1024
    public static let maxControlPayload = 125

    public init(fin: Bool, opcode: UInt8, payload: [UInt8]) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
    }

    public var isControl: Bool { return opcode >= 0x8 }

    /// Parses one client frame from the start of `buffer`. Returns nil while the frame is incomplete (the buffer is left
    /// alone), otherwise the frame with its payload unmasked (also unmasked in place) and the number of bytes consumed,
    /// which the caller removes from the front of the buffer. Throws on reserved bits, a reserved opcode, an unmasked client frame, a payload
    /// above `maxPayload` (checked from the header, before the payload arrives), a control frame over 125 bytes or a
    /// fragmented control frame.
    public static func parse(_ buffer: inout [UInt8], maxPayload: Int) throws -> (frame: WebSocketFrame, consumed: Int)? {
        if buffer.count < 2 { return nil }
        let b0 = buffer[0]
        let b1 = buffer[1]
        if b0 & 0x70 != 0 { throw WebSocketError.reservedBits }
        let fin = b0 & 0x80 != 0
        let opcode = b0 & 0x0F
        if (opcode >= 0x3 && opcode <= 0x7) || opcode >= 0xB { throw WebSocketError.reservedOpcode(opcode) }
        let masked = b1 & 0x80 != 0
        let lengthCode = Int(b1 & 0x7F)
        var offset = 2
        var length = lengthCode
        if lengthCode == 126 {
            if buffer.count < 4 { return nil }
            length = Int(buffer[2]) << 8 | Int(buffer[3])
            offset = 4
        } else if lengthCode == 127 {
            if buffer.count < 10 { return nil }
            if buffer[2] & 0x80 != 0 { throw WebSocketError.oversize(Int.max) }
            var v: UInt64 = 0
            for i in 2..<10 {
                v = v << 8 | UInt64(buffer[i])
            }
            if v > UInt64(Int.max) { throw WebSocketError.oversize(Int.max) }
            length = Int(v)
            offset = 10
        }
        if length > maxPayload { throw WebSocketError.oversize(length) }
        if opcode >= 0x8 {
            if length > maxControlPayload { throw WebSocketError.controlFrameTooLong }
            if !fin { throw WebSocketError.fragmentedControl }
        }
        if !masked { throw WebSocketError.unmaskedClientFrame }
        if buffer.count < offset + 4 { return nil }
        let key = (buffer[offset], buffer[offset + 1], buffer[offset + 2], buffer[offset + 3])
        offset += 4
        let total = offset + length
        if buffer.count < total { return nil }
        var payload = [UInt8](repeating: 0, count: length)
        var i = 0
        while i < length {
            let k: UInt8
            switch i & 3 {
            case 0: k = key.0
            case 1: k = key.1
            case 2: k = key.2
            default: k = key.3
            }
            let v = buffer[offset + i] ^ k
            payload[i] = v
            buffer[offset + i] = v
            i += 1
        }
        return (WebSocketFrame(fin: fin, opcode: opcode, payload: payload), total)
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

    public static func encode(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(payload.count + 10)
        payload.withUnsafeBytes { encode(opcode: opcode, payload: $0, into: &out) }
        return out
    }

    /// A masked client frame (for tests and the Mac's own test client); `key` is the 4-byte masking key.
    public static func encodeMasked(fin: Bool = true, opcode: UInt8, payload: [UInt8], key: (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(payload.count + 14)
        out.append((fin ? 0x80 : 0x00) | (opcode & 0x0F))
        let n = payload.count
        if n < 126 {
            out.append(0x80 | UInt8(n))
        } else if n <= 0xFFFF {
            out.append(0x80 | 126)
            out.append(UInt8(truncatingIfNeeded: n >> 8))
            out.append(UInt8(truncatingIfNeeded: n))
        } else {
            out.append(0x80 | 127)
            for i in (0..<8).reversed() {
                out.append(UInt8(truncatingIfNeeded: UInt64(n) >> (8 * UInt64(i))))
            }
        }
        out.append(key.0)
        out.append(key.1)
        out.append(key.2)
        out.append(key.3)
        for (i, b) in payload.enumerated() {
            let k: UInt8
            switch i & 3 {
            case 0: k = key.0
            case 1: k = key.1
            case 2: k = key.2
            default: k = key.3
            }
            out.append(b ^ k)
        }
        return out
    }

    public static func encodeClose(code: UInt16, reason: String) -> [UInt8] {
        var payload: [UInt8] = [UInt8(truncatingIfNeeded: code >> 8), UInt8(truncatingIfNeeded: code)]
        payload.append(contentsOf: Array(reason.utf8).prefix(123))
        var out: [UInt8] = []
        payload.withUnsafeBytes { encode(opcode: opcodeClose, payload: $0, into: &out) }
        return out
    }

    /// The close code carried by a close frame's payload (nil when the payload is shorter than 2 bytes).
    public static func closeCode(_ payload: [UInt8]) -> UInt16? {
        if payload.count < 2 { return nil }
        return UInt16(payload[0]) << 8 | UInt16(payload[1])
    }
}

/// Reassembles fragmented data messages (RFC 6455 5.4). Control frames pass through untouched and may interleave.
public struct WebSocketMessageAssembler {
    private var opcode: UInt8?
    private var payload: [UInt8] = []
    public let maxMessage: Int

    public init(maxMessage: Int = WebSocketFrame.defaultMaxPayload) {
        self.maxMessage = maxMessage
    }

    public var isAssembling: Bool { return opcode != nil }

    /// Returns a complete message (a control frame, an unfragmented data frame or the reassembled fragments) or nil
    /// while more fragments are needed. Throws `badContinuation` on a stray continuation or an interleaved data frame,
    /// and `oversize` when the reassembled message would exceed `maxMessage`.
    public mutating func accept(_ frame: WebSocketFrame) throws -> WebSocketFrame? {
        if frame.isControl { return frame }
        if frame.opcode == WebSocketFrame.opcodeContinuation {
            guard let op = opcode else { throw WebSocketError.badContinuation }
            if payload.count + frame.payload.count > maxMessage { throw WebSocketError.oversize(payload.count + frame.payload.count) }
            payload.append(contentsOf: frame.payload)
            if frame.fin {
                let message = WebSocketFrame(fin: true, opcode: op, payload: payload)
                opcode = nil
                payload = []
                return message
            }
            return nil
        }
        if opcode != nil { throw WebSocketError.badContinuation }
        if frame.fin { return frame }
        opcode = frame.opcode
        payload = frame.payload
        return nil
    }
}
