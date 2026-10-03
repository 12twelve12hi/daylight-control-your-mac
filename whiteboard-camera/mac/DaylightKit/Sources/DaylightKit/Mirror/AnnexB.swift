import Foundation

/// H.264 Annex-B helpers (research-scrcpy-adb section 6.1): start codes `00 00 01` and `00 00 00 01`, NAL type in the
/// low five bits of the first NAL byte, AVCC = 4-byte big-endian length prefixes for VideoToolbox.
public enum AnnexB {
    public static let nalTypeNonIDRSlice: UInt8 = 1
    public static let nalTypeIDR: UInt8 = 5
    public static let nalTypeSEI: UInt8 = 6
    public static let nalTypeSPS: UInt8 = 7
    public static let nalTypePPS: UInt8 = 8
    public static let nalTypeAUD: UInt8 = 9
    /// `NALUnitHeaderLength` for `CMVideoFormatDescriptionCreateFromH264ParameterSets` and the AVCC prefix size.
    public static let avccLengthPrefix = 4

    /// Ranges of every NAL unit payload (after its start code, trailing zero bytes trimmed, empty NALs dropped).
    /// Bytes before the first start code are ignored.
    public static func nalUnits(_ annexB: UnsafeRawBufferPointer) -> [Range<Int>] {
        let n = annexB.count
        var starts: [Int] = []
        var i = 0
        while i + 2 < n {
            if annexB[i] == 0 && annexB[i + 1] == 0 && annexB[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(starts.count)
        for (k, start) in starts.enumerated() {
            var end = k + 1 < starts.count ? starts[k + 1] - 3 : n
            // The last byte of a NAL unit is never 0x00 (H.264 7.4.1), so the zero of a 4-byte start code is trimmed.
            while end > start && annexB[end - 1] == 0 { end -= 1 }
            if end > start { ranges.append(start..<end) }
        }
        return ranges
    }

    public static func nalUnits(_ annexB: [UInt8]) -> [Range<Int>] {
        return annexB.withUnsafeBytes { nalUnits($0) }
    }

    public static func nalType(_ firstByte: UInt8) -> UInt8 {
        return firstByte & 0x1F
    }

    /// SPS (type 7) and PPS (type 8) NAL units of a config packet, in stream order, with emulation prevention bytes intact.
    public static func parameterSets(_ config: UnsafeRawBufferPointer) -> (sps: [[UInt8]], pps: [[UInt8]]) {
        var sps: [[UInt8]] = []
        var pps: [[UInt8]] = []
        for range in nalUnits(config) {
            let bytes = Array(UnsafeRawBufferPointer(rebasing: config[range]))
            switch nalType(bytes[0]) {
            case nalTypeSPS: sps.append(bytes)
            case nalTypePPS: pps.append(bytes)
            default: break
            }
        }
        return (sps, pps)
    }

    public static func parameterSets(_ config: [UInt8]) -> (sps: [[UInt8]], pps: [[UInt8]]) {
        return config.withUnsafeBytes { parameterSets($0) }
    }

    /// Every NAL unit prefixed with its 4-byte big-endian length (the AVCC sample layout VideoToolbox expects).
    public static func toAVCC(_ annexB: UnsafeRawBufferPointer) -> [UInt8] {
        let ranges = nalUnits(annexB)
        var out: [UInt8] = []
        out.reserveCapacity(annexB.count + ranges.count * avccLengthPrefix)
        for range in ranges {
            let length = UInt32(range.count)
            out.append(UInt8(length >> 24 & 0xFF))
            out.append(UInt8(length >> 16 & 0xFF))
            out.append(UInt8(length >> 8 & 0xFF))
            out.append(UInt8(length & 0xFF))
            out.append(contentsOf: UnsafeRawBufferPointer(rebasing: annexB[range]))
        }
        return out
    }

    public static func toAVCC(_ annexB: [UInt8]) -> [UInt8] {
        return annexB.withUnsafeBytes { toAVCC($0) }
    }

    /// True when the access unit holds an IDR slice (NAL type 5).
    public static func containsIDR(_ annexB: UnsafeRawBufferPointer) -> Bool {
        for range in nalUnits(annexB) where nalType(annexB[range.lowerBound]) == nalTypeIDR { return true }
        return false
    }

    public static func containsIDR(_ annexB: [UInt8]) -> Bool {
        return annexB.withUnsafeBytes { containsIDR($0) }
    }

    /// True when the buffer holds an SPS or PPS (a config packet or an in-band parameter set).
    public static func containsParameterSets(_ annexB: [UInt8]) -> Bool {
        let sets = parameterSets(annexB)
        return !sets.sps.isEmpty || !sets.pps.isEmpty
    }
}
