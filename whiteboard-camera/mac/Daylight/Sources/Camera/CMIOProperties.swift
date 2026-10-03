import CoreMediaIO
import Foundation
import os

/// Thin wrappers over the CoreMediaIO C property API (OBS plugin-main.mm, ldenoue ViewController.swift): sizes,
/// arrays of object ids, strings, UInt32 values and the custom viewers property. Every call is synchronous and cheap.
enum CMIOProperties {
    static let log = Logger(subsystem: "com.twelve.daylight", category: "cmio")

    /// Four ASCII characters packed big-endian, the CoreMediaIO selector convention ('dlvw'); 0 for a bad input.
    static func fourCC(_ code: String) -> UInt32 {
        let scalars = Array(code.utf8)
        guard scalars.count == 4 else { return 0 }
        return (UInt32(scalars[0]) << 24) | (UInt32(scalars[1]) << 16) | (UInt32(scalars[2]) << 8) | UInt32(scalars[3])
    }

    /// The four characters of a selector, for logs.
    static func fourCCString(_ value: UInt32) -> String {
        let bytes = [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        return String(decoding: bytes, as: UTF8.self)
    }

    static func address(selector: UInt32) -> CMIOObjectPropertyAddress {
        return CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func address<S: BinaryInteger>(_ selector: S) -> CMIOObjectPropertyAddress {
        return address(selector: UInt32(truncatingIfNeeded: selector))
    }

    static func hasProperty(_ object: CMIOObjectID, selector: UInt32) -> Bool {
        var address = self.address(selector: selector)
        return CMIOObjectHasProperty(object, &address)
    }

    static func dataSize(_ object: CMIOObjectID, selector: UInt32) -> UInt32? {
        var address = self.address(selector: selector)
        var size: UInt32 = 0
        let status = CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { return nil }
        return size
    }

    /// An array-of-UInt32 property (`kCMIOHardwarePropertyDevices`, `kCMIODevicePropertyStreams`).
    static func objectIDs<S: BinaryInteger>(_ object: CMIOObjectID, selector: S) -> [CMIOObjectID] {
        let sel = UInt32(truncatingIfNeeded: selector)
        guard let size = dataSize(object, selector: sel), size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        var address = self.address(selector: sel)
        let status = CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids)
        guard status == noErr else { return [] }
        let filled = Int(used) / MemoryLayout<CMIOObjectID>.size
        return Array(ids.prefix(filled))
    }

    /// A CFString property (`kCMIODevicePropertyDeviceUID`). The reference comes back +1 and Swift adopts it, the
    /// ldenoue and OBS shape.
    static func string<S: BinaryInteger>(_ object: CMIOObjectID, selector: S) -> String? {
        let sel = UInt32(truncatingIfNeeded: selector)
        guard let size = dataSize(object, selector: sel), Int(size) == MemoryLayout<CFString?>.size else { return nil }
        var value: CFString? = nil
        var used: UInt32 = 0
        var address = self.address(selector: sel)
        let status = CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value)
        guard status == noErr, let string = value else { return nil }
        return string as String
    }

    /// A UInt32 property (`kCMIOStreamPropertyDirection`).
    static func uint32<S: BinaryInteger>(_ object: CMIOObjectID, selector: S) -> UInt32? {
        let sel = UInt32(truncatingIfNeeded: selector)
        guard let size = dataSize(object, selector: sel), size == 4 else { return nil }
        var value: UInt32 = 0
        var used: UInt32 = 0
        var address = self.address(selector: sel)
        let status = CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value)
        guard status == noErr else { return nil }
        return value
    }

    /// What a custom extension property read produced.
    enum CustomValue: Equatable {
        case number(Int)
        case string(String)
        case unsupported(size: Int)
    }

    /// Reads a custom property published by a CMIOExtension stream. The verified transport (ldenoue) is a CFString
    /// reference; a 4-byte value is read as UInt32 and a CFNumber reference as a number. Other sizes are reported.
    static func customValue(_ object: CMIOObjectID, fourCC: UInt32) -> CustomValue? {
        guard hasProperty(object, selector: fourCC), let size = dataSize(object, selector: fourCC) else { return nil }
        var address = self.address(selector: fourCC)
        var used: UInt32 = 0
        if size == 4 {
            var value: UInt32 = 0
            guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value) == noErr else { return nil }
            return .number(Int(value))
        }
        if Int(size) == MemoryLayout<CFTypeRef?>.size {
            var value: CFTypeRef? = nil
            guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value) == noErr, let ref = value else { return nil }
            let typeID = CFGetTypeID(ref)
            if typeID == CFStringGetTypeID() {
                return .string((ref as! CFString) as String)
            }
            if typeID == CFNumberGetTypeID() {
                return .number((ref as! NSNumber).intValue)
            }
            return .unsupported(size: Int(size))
        }
        return .unsupported(size: Int(size))
    }
}
