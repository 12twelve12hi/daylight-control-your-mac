import Foundation

public enum Hex {
    private static let digits: [Character] = Array("0123456789abcdef")

    public static func encode(_ bytes: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return out
    }

    public static func decode(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        if chars.count % 2 != 0 { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48            // 0-9
        case 97...102: return c - 97 + 10      // a-f
        case 65...70: return c - 65 + 10       // A-F
        default: return nil
        }
    }
}
