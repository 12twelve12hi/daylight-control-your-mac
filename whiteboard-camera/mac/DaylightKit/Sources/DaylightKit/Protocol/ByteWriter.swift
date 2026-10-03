import Foundation

/// Little-endian writer into a growable byte array.
public struct ByteWriter {
    public private(set) var storage: [UInt8]

    public init(reserving: Int = 64) {
        storage = []
        storage.reserveCapacity(reserving)
    }

    public var count: Int { return storage.count }

    public mutating func u8(_ v: UInt8) {
        storage.append(v)
    }

    public mutating func i8(_ v: Int8) {
        storage.append(UInt8(bitPattern: v))
    }

    public mutating func u16(_ v: UInt16) {
        storage.append(UInt8(truncatingIfNeeded: v))
        storage.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    public mutating func u32(_ v: UInt32) {
        for i in 0..<4 {
            storage.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))))
        }
    }

    public mutating func i32(_ v: Int32) {
        u32(UInt32(bitPattern: v))
    }

    public mutating func u64(_ v: UInt64) {
        for i in 0..<8 {
            storage.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))))
        }
    }

    public mutating func f32(_ v: Float) {
        u32(v.bitPattern)
    }

    public mutating func uuid(_ v: UUID) {
        let raw = v.uuid
        let rawBytes = withUnsafeBytes(of: raw) { Array($0) }
        storage.append(contentsOf: rawBytes)
    }

    public mutating func bytes(_ v: [UInt8]) {
        storage.append(contentsOf: v)
    }

    /// Overwrites 4 bytes at `at` (used to patch payload_len after the payload is written).
    public mutating func patchU32(_ v: UInt32, at index: Int) {
        for i in 0..<4 {
            storage[index + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))
        }
    }
}
