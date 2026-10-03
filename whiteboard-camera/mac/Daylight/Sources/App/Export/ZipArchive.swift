import Foundation

/// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320), the checksum every ZIP entry carries.
enum CRC32 {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        return table
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// A store-only ZIP writer (APPNOTE 6.3: local headers, central directory, end record; no compression, no ZIP64, no
/// data descriptors). Deterministic: the same entries and date give the same bytes. The diagnostics export stays far
/// below the 4 GiB limit of the classic format (the whole zip is capped at 16 MiB).
struct ZipWriter {
    private(set) var bytes = Data()
    private var central = Data()
    private(set) var count = 0
    private let dosTime: UInt16
    private let dosDate: UInt16

    /// Every entry carries `date` as its modification time, in `timeZone` (ZIP stores local time without a zone).
    init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, c.year ?? 1980))
        dosTime = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        dosDate = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
    }

    mutating func add(_ name: String, _ data: Data) {
        let nameBytes = Data(name.utf8)
        let crc = CRC32.checksum(data)
        let offset = UInt32(bytes.count)
        // Local file header.
        ZipWriter.put32(&bytes, 0x0403_4B50)
        ZipWriter.put16(&bytes, 20)          // version needed
        ZipWriter.put16(&bytes, 0x0800)      // flags: UTF-8 names
        ZipWriter.put16(&bytes, 0)           // method: stored
        ZipWriter.put16(&bytes, dosTime)
        ZipWriter.put16(&bytes, dosDate)
        ZipWriter.put32(&bytes, crc)
        ZipWriter.put32(&bytes, UInt32(data.count))
        ZipWriter.put32(&bytes, UInt32(data.count))
        ZipWriter.put16(&bytes, UInt16(nameBytes.count))
        ZipWriter.put16(&bytes, 0)           // extra length
        bytes.append(nameBytes)
        bytes.append(data)
        // Central directory record.
        ZipWriter.put32(&central, 0x0201_4B50)
        ZipWriter.put16(&central, 0x0314)    // made by: Unix, 2.0
        ZipWriter.put16(&central, 20)
        ZipWriter.put16(&central, 0x0800)
        ZipWriter.put16(&central, 0)
        ZipWriter.put16(&central, dosTime)
        ZipWriter.put16(&central, dosDate)
        ZipWriter.put32(&central, crc)
        ZipWriter.put32(&central, UInt32(data.count))
        ZipWriter.put32(&central, UInt32(data.count))
        ZipWriter.put16(&central, UInt16(nameBytes.count))
        ZipWriter.put16(&central, 0)         // extra length
        ZipWriter.put16(&central, 0)         // comment length
        ZipWriter.put16(&central, 0)         // disk number
        ZipWriter.put16(&central, 0)         // internal attributes
        ZipWriter.put32(&central, 0o100644 << 16)   // external attributes: a regular file, rw-r--r--
        ZipWriter.put32(&central, offset)
        central.append(nameBytes)
        count += 1
    }

    /// The complete archive: the entries, the central directory and the end record.
    func finish() -> Data {
        var out = bytes
        let centralOffset = UInt32(out.count)
        out.append(central)
        ZipWriter.put32(&out, 0x0605_4B50)
        ZipWriter.put16(&out, 0)
        ZipWriter.put16(&out, 0)
        ZipWriter.put16(&out, UInt16(count))
        ZipWriter.put16(&out, UInt16(count))
        ZipWriter.put32(&out, UInt32(central.count))
        ZipWriter.put32(&out, centralOffset)
        ZipWriter.put16(&out, 0)             // comment length
        return out
    }

    static func put16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    static func put32(_ data: inout Data, _ value: UInt32) {
        var v = value
        for _ in 0..<4 {
            data.append(UInt8(v & 0xFF))
            v >>= 8
        }
    }
}

enum ZipReadError: Error, Equatable {
    case noEndRecord
    case truncated(String)
    case badSignature(String)
    case unsupportedMethod(String, Int)
    case crcMismatch(String)
}

/// Reads a store-only archive back through its central directory (the export's tests and the self-test probe).
enum ZipReader {
    struct Entry: Equatable {
        let name: String
        let data: Data
        let crc: UInt32
    }

    static func entries(_ archive: Data) throws -> [Entry] {
        let bytes = [UInt8](archive)
        guard bytes.count >= 22 else { throw ZipReadError.noEndRecord }
        var end = -1
        var i = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65535)
        while i >= lowest {
            if read32(bytes, i) == 0x0605_4B50 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { throw ZipReadError.noEndRecord }
        let total = Int(read16(bytes, end + 10))
        let centralSize = Int(read32(bytes, end + 12))
        let centralOffset = Int(read32(bytes, end + 16))
        guard centralOffset + centralSize <= end else { throw ZipReadError.truncated("central directory") }
        var entries: [Entry] = []
        var p = centralOffset
        for _ in 0..<total {
            guard p + 46 <= end else { throw ZipReadError.truncated("central record") }
            guard read32(bytes, p) == 0x0201_4B50 else { throw ZipReadError.badSignature("central record at \(p)") }
            let method = Int(read16(bytes, p + 10))
            let crc = read32(bytes, p + 16)
            let compressed = Int(read32(bytes, p + 20))
            let nameLength = Int(read16(bytes, p + 28))
            let extraLength = Int(read16(bytes, p + 30))
            let commentLength = Int(read16(bytes, p + 32))
            let localOffset = Int(read32(bytes, p + 42))
            guard p + 46 + nameLength <= end else { throw ZipReadError.truncated("name") }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            guard method == 0 else { throw ZipReadError.unsupportedMethod(name, method) }
            guard localOffset + 30 <= bytes.count, read32(bytes, localOffset) == 0x0403_4B50 else { throw ZipReadError.badSignature("local header of \(name)") }
            let localName = Int(read16(bytes, localOffset + 26))
            let localExtra = Int(read16(bytes, localOffset + 28))
            let start = localOffset + 30 + localName + localExtra
            guard start + compressed <= bytes.count else { throw ZipReadError.truncated(name) }
            let data = Data(bytes[start..<(start + compressed)])
            guard CRC32.checksum(data) == crc else { throw ZipReadError.crcMismatch(name) }
            entries.append(Entry(name: name, data: data, crc: crc))
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func read16(_ b: [UInt8], _ i: Int) -> UInt16 {
        return UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func read32(_ b: [UInt8], _ i: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(b[i + k]) << (8 * UInt32(k)) }
        return v
    }
}
