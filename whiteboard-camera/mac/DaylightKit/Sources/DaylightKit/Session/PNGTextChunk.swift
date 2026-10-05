import Foundation

/// Byte-level PNG text chunks (PNG specification, 3rd edition, sections 5.3, 5.4 and 11.3.3): the saved page carries
/// its own strokes JSON in an uncompressed `iTXt` chunk with the keyword `daylight-strokes`, so a PNG that travels
/// without its `page-NN.json` sidecar still holds the board as strokes (DRAWING-DEEP-DIVE, IDEAS-FROM-OTHER-PROJECTS
/// item 5). Foundation only (no zlib, no ImageIO): the CRC32 is written by hand and the same code runs on Linux.
///
/// `iTXt` is used, not `tEXt`, because `tEXt` text is Latin-1 by definition while the JSON is UTF-8 (a client label
/// such as "Mike's DC-1" may hold any character); `iTXt` with compression flag 0 stores the UTF-8 bytes verbatim.
public enum PNGTextChunk {
    /// The keyword of the strokes chunk in a saved page.
    public static let strokesKeyword = "daylight-strokes"
    /// The eight signature bytes every PNG starts with.
    public static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public enum ChunkError: Error, Equatable {
        /// The data does not start with the PNG signature.
        case badSignature
        /// A chunk header or body runs past the end of the data.
        case truncated
        /// No `IEND` chunk, so there is nowhere to insert before it.
        case noIEND
        /// A keyword must be 1 to 79 printable Latin-1 characters without leading, trailing or double spaces.
        case badKeyword
    }

    public struct Chunk: Equatable {
        public let type: String
        public let data: [UInt8]
        /// Byte offset of the chunk's length field in the PNG.
        public let offset: Int

        public init(type: String, data: [UInt8], offset: Int) {
            self.type = type
            self.data = data
            self.offset = offset
        }
    }

    // MARK: CRC32 (ISO 3309 / ITU-T V.42, as PNG section 5.5 defines it)

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                if c & 1 != 0 {
                    c = 0xEDB8_8320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            table[n] = c
        }
        return table
    }()

    /// CRC32 of `bytes` (the PNG chunk CRC when `bytes` is the chunk type followed by its data).
    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        let table = crcTable
        for byte in bytes {
            let index = Int((c ^ UInt32(byte)) & 0xFF)
            c = table[index] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: Writing

    /// One whole chunk: big-endian length, the 4-byte type, the data, big-endian CRC32 over type and data.
    public static func chunk(type: String, data: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8.prefix(4))
        var out: [UInt8] = []
        out.reserveCapacity(12 + data.count)
        appendUInt32(UInt32(data.count), to: &out)
        out.append(contentsOf: typeBytes)
        out.append(contentsOf: data)
        appendUInt32(crc32(typeBytes + data), to: &out)
        return out
    }

    /// The data of an uncompressed `iTXt` chunk: keyword, NUL, compression flag 0, method 0, empty language tag and
    /// NUL, empty translated keyword and NUL, then the UTF-8 text unchanged.
    public static func iTXtData(keyword: String, text: Data) throws -> [UInt8] {
        let key = try keywordBytes(keyword)
        var out: [UInt8] = key
        let header: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00]
        out.append(contentsOf: header)
        out.append(contentsOf: [UInt8](text))
        return out
    }

    /// `png` with an `iTXt` chunk `keyword` = `text` inserted right before `IEND`. Any text chunk (`iTXt`, `tEXt` or
    /// `zTXt`) with the same keyword is removed first, so inserting twice leaves one chunk.
    public static func inserting(keyword: String, text: Data, into png: Data) throws -> Data {
        let bytes = [UInt8](png)
        let list = try chunks(bytes)
        guard let end = list.last(where: { $0.type == "IEND" }) else { throw ChunkError.noIEND }
        let newChunk = chunk(type: "iTXt", data: try iTXtData(keyword: keyword, text: text))
        var out: [UInt8] = signature
        out.reserveCapacity(bytes.count + newChunk.count)
        for item in list {
            if item.offset == end.offset { out.append(contentsOf: newChunk) }
            if isTextChunk(item.type) && chunkKeyword(item.data) == keyword { continue }
            out.append(contentsOf: bytes[item.offset..<(item.offset + 12 + item.data.count)])
        }
        return Data(out)
    }

    /// `png` without any text chunk (`iTXt`, `tEXt` or `zTXt`) named `keyword`; every other chunk is kept byte for
    /// byte and in order. Used before a saved page goes to the clipboard (review F4), so the copy never carries the
    /// strokes JSON. Throws like `chunks` for data that is not a PNG or is cut off.
    public static func removing(keyword: String, from png: Data) throws -> Data {
        let bytes = [UInt8](png)
        let list = try chunks(bytes)
        var out: [UInt8] = signature
        out.reserveCapacity(bytes.count)
        for item in list {
            if isTextChunk(item.type) && chunkKeyword(item.data) == keyword { continue }
            out.append(contentsOf: bytes[item.offset..<(item.offset + 12 + item.data.count)])
        }
        return Data(out)
    }

    // MARK: Reading

    /// Every chunk in file order (IEND included; anything after IEND is ignored).
    public static func chunks(_ png: Data) throws -> [Chunk] {
        return try chunks([UInt8](png))
    }

    public static func chunks(_ bytes: [UInt8]) throws -> [Chunk] {
        guard bytes.count >= signature.count, Array(bytes[0..<signature.count]) == signature else { throw ChunkError.badSignature }
        var list: [Chunk] = []
        var offset = signature.count
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { throw ChunkError.truncated }
            let length = Int(readUInt32(bytes, at: offset))
            let typeBytes = Array(bytes[(offset + 4)..<(offset + 8)])
            let type = String(decoding: typeBytes, as: UTF8.self)
            let dataStart = offset + 8
            guard length <= bytes.count - dataStart - 4 else { throw ChunkError.truncated }
            let data = Array(bytes[dataStart..<(dataStart + length)])
            list.append(Chunk(type: type, data: data, offset: offset))
            offset = dataStart + length + 4
            if type == "IEND" { break }
        }
        return list
    }

    /// The text of the first `iTXt` (uncompressed) or `tEXt` chunk named `keyword`, as raw bytes; nil when the PNG has
    /// none. Throws `badSignature` for data that is not a PNG and `truncated` for a cut-off file.
    public static func readText(keyword: String, from png: Data) throws -> Data? {
        for item in try chunks(png) {
            guard isTextChunk(item.type), chunkKeyword(item.data) == keyword, let nul = item.data.firstIndex(of: 0) else { continue }
            if item.type == "tEXt" {
                return Data(item.data[(nul + 1)...])
            }
            if item.type == "iTXt" {
                // flag, method, language tag NUL, translated keyword NUL, text.
                var cursor = nul + 1
                guard cursor + 2 <= item.data.count else { continue }
                let compressed = item.data[cursor] != 0
                cursor += 2
                guard let languageEnd = item.data[cursor...].firstIndex(of: 0) else { continue }
                cursor = languageEnd + 1
                guard cursor <= item.data.count, let translatedEnd = item.data[cursor...].firstIndex(of: 0) else { continue }
                cursor = translatedEnd + 1
                if compressed { continue }   // never written by Daylight; reading zlib would need zlib
                return Data(item.data[cursor...])
            }
        }
        return nil
    }

    // MARK: Helpers

    private static func isTextChunk(_ type: String) -> Bool {
        return type == "iTXt" || type == "tEXt" || type == "zTXt"
    }

    /// The Latin-1 keyword before the first NUL of a text chunk's data.
    private static func chunkKeyword(_ data: [UInt8]) -> String? {
        guard let nul = data.firstIndex(of: 0) else { return nil }
        var text = ""
        for byte in data[0..<nul] { text.append(Character(Unicode.Scalar(byte))) }
        return text
    }

    private static func keywordBytes(_ keyword: String) throws -> [UInt8] {
        var out: [UInt8] = []
        for scalar in keyword.unicodeScalars {
            let v = scalar.value
            guard (v >= 32 && v <= 126) || (v >= 161 && v <= 255) else { throw ChunkError.badKeyword }
            out.append(UInt8(v))
        }
        guard !out.isEmpty, out.count <= 79, out.first != 0x20, out.last != 0x20 else { throw ChunkError.badKeyword }
        if keyword.contains("  ") { throw ChunkError.badKeyword }
        return out
    }

    private static func appendUInt32(_ value: UInt32, to out: inout [UInt8]) {
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        let b0 = UInt32(bytes[offset]) << 24
        let b1 = UInt32(bytes[offset + 1]) << 16
        let b2 = UInt32(bytes[offset + 2]) << 8
        let b3 = UInt32(bytes[offset + 3])
        return b0 | b1 | b2 | b3
    }
}
