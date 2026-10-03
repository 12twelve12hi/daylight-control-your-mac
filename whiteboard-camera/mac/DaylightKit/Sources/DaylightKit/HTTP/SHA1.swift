import Foundation

/// Pure Swift SHA-1 for the WebSocket accept key (RFC 6455 section 4.2.2). Checked against the golden manifest.
public enum SHA1 {
    public static func hash(_ bytes: UnsafeRawBufferPointer) -> [UInt8] {
        var h0: UInt32 = 0x6745_2301
        var h1: UInt32 = 0xEFCD_AB89
        var h2: UInt32 = 0x98BA_DCFE
        var h3: UInt32 = 0x1032_5476
        var h4: UInt32 = 0xC3D2_E1F0

        var message = [UInt8](bytes)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for i in (0..<8).reversed() {
            message.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i))))
        }

        var w = [UInt32](repeating: 0, count: 80)
        var chunk = 0
        while chunk < message.count {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<80 {
                w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }
            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20:
                    f = (b & c) | (~b & d)
                    k = 0x5A82_7999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9_EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1B_BCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62_C1D6
                }
                let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = rotl(b, 30)
                b = a
                a = temp
            }
            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
            chunk += 64
        }
        var out: [UInt8] = []
        out.reserveCapacity(20)
        for word in [h0, h1, h2, h3, h4] {
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return out
    }

    public static func hash(_ bytes: [UInt8]) -> [UInt8] {
        return bytes.withUnsafeBytes { hash($0) }
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        return (x << n) | (x >> (32 - n))
    }
}
