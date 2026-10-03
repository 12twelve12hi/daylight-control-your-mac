import Foundation

/// Little-endian reader that assembles bytes (never loads through an unaligned pointer).
public struct ByteReader {
    private let buffer: UnsafeRawBufferPointer
    private var offset: Int

    public init(_ bytes: UnsafeRawBufferPointer) {
        self.buffer = bytes
        self.offset = 0
    }

    public var remaining: Int { return buffer.count - offset }
    public var position: Int { return offset }

    private mutating func need(_ n: Int) throws {
        if remaining < n { throw CodecError.truncated(needed: n, have: remaining) }
    }

    public mutating func u8() throws -> UInt8 {
        try need(1)
        let v = buffer[offset]
        offset += 1
        return v
    }

    public mutating func i8() throws -> Int8 {
        return Int8(bitPattern: try u8())
    }

    public mutating func u16() throws -> UInt16 {
        try need(2)
        let v = UInt16(buffer[offset]) | (UInt16(buffer[offset + 1]) << 8)
        offset += 2
        return v
    }

    public mutating func u32() throws -> UInt32 {
        try need(4)
        var v: UInt32 = 0
        for i in 0..<4 {
            v |= UInt32(buffer[offset + i]) << (8 * UInt32(i))
        }
        offset += 4
        return v
    }

    public mutating func i32() throws -> Int32 {
        return Int32(bitPattern: try u32())
    }

    public mutating func u64() throws -> UInt64 {
        try need(8)
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(buffer[offset + i]) << (8 * UInt64(i))
        }
        offset += 8
        return v
    }

    public mutating func f32() throws -> Float {
        return Float(bitPattern: try u32())
    }

    public mutating func uuid() throws -> UUID {
        try need(16)
        var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let start = offset
        let src = buffer
        withUnsafeMutableBytes(of: &raw) { dst in
            for i in 0..<16 {
                dst[i] = src[start + i]
            }
        }
        offset += 16
        return UUID(uuid: raw)
    }

    public mutating func bytes(_ n: Int) throws -> [UInt8] {
        try need(n)
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = buffer[offset + i]
        }
        offset += n
        return out
    }
}
