import Foundation
import XCTest
import DaylightKit

/// The strokes JSON inside the saved PNG: CRC32, chunk layout, insert and read back, files without the chunk.
final class PNGTextChunkTests: XCTestCase {
    /// A valid 1x1 RGB PNG (IHDR, IDAT, IEND), 69 bytes, written by Python's zlib and struct.
    private let tinyPNGHex = "89504e470d0a1a0a0000000d4948445200000001000000010802000000907753de0000000c49444154789c63f8cfc0000003010100c9fe92ef0000000049454e44ae426082"

    private var tinyPNG: Data {
        return Data(Hex.decode(tinyPNGHex)!)
    }

    func testCRC32KnownVectors() {
        XCTAssertEqual(PNGTextChunk.crc32(Array("IEND".utf8)), 0xAE42_6082)
        XCTAssertEqual(PNGTextChunk.crc32(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(PNGTextChunk.crc32([]), 0)
    }

    func testChunkLayoutIsLengthTypeDataCRC() {
        let iend = PNGTextChunk.chunk(type: "IEND", data: [])
        XCTAssertEqual(iend, Hex.decode("0000000049454e44ae426082")!)
        let ihdrData = Hex.decode("00000001000000010802000000")!
        XCTAssertEqual(PNGTextChunk.chunk(type: "IHDR", data: ihdrData), Hex.decode("0000000d" + "49484452" + "00000001000000010802000000" + "907753de")!)
    }

    func testReadsTheChunksOfARealPNG() throws {
        let list = try PNGTextChunk.chunks(tinyPNG)
        XCTAssertEqual(list.map { $0.type }, ["IHDR", "IDAT", "IEND"])
        XCTAssertEqual(list[0].data.count, 13)
        XCTAssertEqual(list[0].offset, 8)
    }

    func testInsertThenReadBackRoundTrips() throws {
        let json = Data("{\n  \"schema\" : \"daylight-whiteboard-strokes/1\",\n  \"clientLabel\" : \"Mike's DC-1 é\"\n}".utf8)
        let out = try PNGTextChunk.inserting(keyword: PNGTextChunk.strokesKeyword, text: json, into: tinyPNG)
        XCTAssertEqual(Array(out.prefix(8)), PNGTextChunk.signature)
        let list = try PNGTextChunk.chunks(out)
        XCTAssertEqual(list.map { $0.type }, ["IHDR", "IDAT", "iTXt", "IEND"], "inserted right before IEND")
        XCTAssertEqual(out.count, tinyPNG.count + 12 + "daylight-strokes".utf8.count + 5 + json.count)
        // Every chunk's CRC is valid (type + data), big-endian at the end of the chunk.
        let bytes = [UInt8](out)
        for item in list {
            let crcStart = item.offset + 8 + item.data.count
            var stored: UInt32 = 0
            for i in 0..<4 {
                stored = (stored << 8) | UInt32(bytes[crcStart + i])
            }
            XCTAssertEqual(stored, PNGTextChunk.crc32(Array(item.type.utf8) + item.data), item.type)
        }
        let text = try PNGTextChunk.readText(keyword: PNGTextChunk.strokesKeyword, from: out)
        XCTAssertEqual(text, json, "byte for byte")
        // The iTXt header: keyword, NUL, flag 0, method 0, empty language tag, empty translated keyword.
        let itxt = list[2].data
        let header = Array("daylight-strokes".utf8) + [UInt8](repeating: 0, count: 5)
        XCTAssertEqual(Array(itxt.prefix(header.count)), header)
    }

    func testInsertingTwiceKeepsOneChunk() throws {
        let first = try PNGTextChunk.inserting(keyword: "daylight-strokes", text: Data("one".utf8), into: tinyPNG)
        let second = try PNGTextChunk.inserting(keyword: "daylight-strokes", text: Data("two".utf8), into: first)
        XCTAssertEqual(try PNGTextChunk.chunks(second).map { $0.type }, ["IHDR", "IDAT", "iTXt", "IEND"])
        XCTAssertEqual(try PNGTextChunk.readText(keyword: "daylight-strokes", from: second), Data("two".utf8))
    }

    func testPNGWithoutTheChunkReadsNil() throws {
        XCTAssertNil(try PNGTextChunk.readText(keyword: PNGTextChunk.strokesKeyword, from: tinyPNG))
        let other = try PNGTextChunk.inserting(keyword: "Comment", text: Data("hello".utf8), into: tinyPNG)
        XCTAssertNil(try PNGTextChunk.readText(keyword: PNGTextChunk.strokesKeyword, from: other), "another keyword is not ours")
        XCTAssertEqual(try PNGTextChunk.readText(keyword: "Comment", from: other), Data("hello".utf8))
    }

    func testReadsAPlainTEXtChunk() throws {
        var bytes = Array(Hex.decode(tinyPNGHex)!.prefix(8 + 25 + 24))
        bytes += PNGTextChunk.chunk(type: "tEXt", data: Array("daylight-strokes".utf8) + [0x00] + Array("{}".utf8))
        bytes += PNGTextChunk.chunk(type: "IEND", data: [])
        XCTAssertEqual(try PNGTextChunk.readText(keyword: "daylight-strokes", from: Data(bytes)), Data("{}".utf8))
    }

    func testInvalidSignatureIsRejected() {
        var bytes = Hex.decode(tinyPNGHex)!
        bytes[1] = 0x51
        XCTAssertThrowsError(try PNGTextChunk.readText(keyword: "daylight-strokes", from: Data(bytes))) { error in
            XCTAssertEqual(error as? PNGTextChunk.ChunkError, .badSignature)
        }
        XCTAssertThrowsError(try PNGTextChunk.inserting(keyword: "daylight-strokes", text: Data(), into: Data([0x89, 0x50]))) { error in
            XCTAssertEqual(error as? PNGTextChunk.ChunkError, .badSignature)
        }
    }

    func testTruncatedAndMissingIENDAreErrors() {
        let bytes = Hex.decode(tinyPNGHex)!
        XCTAssertThrowsError(try PNGTextChunk.chunks(Data(bytes.prefix(bytes.count - 2)))) { error in
            XCTAssertEqual(error as? PNGTextChunk.ChunkError, .truncated)
        }
        XCTAssertThrowsError(try PNGTextChunk.inserting(keyword: "k", text: Data(), into: Data(bytes.prefix(bytes.count - 12)))) { error in
            XCTAssertEqual(error as? PNGTextChunk.ChunkError, .noIEND)
        }
    }

    func testKeywordRules() {
        XCTAssertThrowsError(try PNGTextChunk.iTXtData(keyword: "", text: Data()))
        XCTAssertThrowsError(try PNGTextChunk.iTXtData(keyword: " lead", text: Data()))
        XCTAssertThrowsError(try PNGTextChunk.iTXtData(keyword: String(repeating: "k", count: 80), text: Data()))
        XCTAssertNoThrow(try PNGTextChunk.iTXtData(keyword: String(repeating: "k", count: 79), text: Data()))
    }

    /// Review F4: the clipboard copy of a saved page drops the strokes chunk and keeps everything else byte for byte.
    func testRemovingTheStrokesChunkGivesBackTheImage() throws {
        let withComment = try PNGTextChunk.inserting(keyword: "Comment", text: Data("hello".utf8), into: tinyPNG)
        let saved = try PNGTextChunk.inserting(keyword: PNGTextChunk.strokesKeyword, text: Data("{\"clientLabel\" : \"Mike's DC-1\"}".utf8), into: withComment)
        let stripped = try PNGTextChunk.removing(keyword: PNGTextChunk.strokesKeyword, from: saved)
        XCTAssertNil(try PNGTextChunk.readText(keyword: PNGTextChunk.strokesKeyword, from: stripped))
        XCTAssertEqual(stripped, withComment, "every other chunk kept, in order")
        XCTAssertEqual(try PNGTextChunk.readText(keyword: "Comment", from: stripped), Data("hello".utf8))
        XCTAssertEqual(try PNGTextChunk.removing(keyword: PNGTextChunk.strokesKeyword, from: tinyPNG), tinyPNG, "nothing to remove")
        var plain = Array(Hex.decode(tinyPNGHex)!.prefix(8 + 25 + 24))
        plain += PNGTextChunk.chunk(type: "tEXt", data: Array("daylight-strokes".utf8) + [0x00] + Array("{}".utf8))
        plain += PNGTextChunk.chunk(type: "IEND", data: [])
        XCTAssertEqual(try PNGTextChunk.removing(keyword: "daylight-strokes", from: Data(plain)), tinyPNG, "a tEXt chunk of that keyword goes too")
        XCTAssertThrowsError(try PNGTextChunk.removing(keyword: "daylight-strokes", from: Data("not a png".utf8)))
    }
}
