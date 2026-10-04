import Foundation
import XCTest
import DaylightKit

/// Cross-language fuzz parity (protocol/fuzz/README.md): every case of fuzz-corpus.json through the Swift codec. The
/// Mac decodes and encodes every opcode, so every frame gets the corpus decision exactly, and every accepted frame
/// re-encodes byte for byte to the case's canonical encoding. Dispatch follows the server: Codec.decodeLenient first
/// (header rules and the v1 messages), then MirrorStream.decode for the four mirror opcodes (PROTOCOL 14).
final class FuzzCorpusTests: XCTestCase {
    struct Corpus: Decodable {
        let version: Int
        let generator: String
        let opcodes: [UInt16]
        let cases: [Case]
    }

    struct Case: Decodable {
        let name: String
        let kind: String
        let opcode: UInt16
        let hex: String?
        let pad: Int?
        let expect: String
        let layer: String?
        let canonical: String?
        let canonical_pad: Int?
        let finding: String?
    }

    /// Cases this codec is known to get wrong, each naming its finding; the test fails if one of them starts to pass.
    static let knownDivergent: [String: String] = [:]

    private func loadCorpus() throws -> Corpus {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fuzz-corpus", withExtension: "json"), "fuzz corpus missing from the test bundle")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Corpus.self, from: data)
    }

    private static func bytes(_ hex: String, pad: Int) -> [UInt8]? {
        guard var out = Hex.decode(hex) else { return nil }
        if pad > 0 { out.append(contentsOf: repeatElement(UInt8(0), count: pad)) }
        return out
    }

    /// The decision the Mac takes on one frame and, for an accepted one, its re-encoding with the frame's timestamp.
    static func decide(_ frame: [UInt8]) -> (decision: String, reencoded: [UInt8]?) {
        let decoded: (Header, Message?)
        do {
            decoded = try frame.withUnsafeBytes { try Codec.decodeLenient($0) }
        } catch {
            return ("reject", nil)
        }
        let header = decoded.0
        if let message = decoded.1 {
            return ("accept", Codec.encode(message, timestampUs: header.timestampUs))
        }
        let op = header.opcode
        let mirror = op == MirrorStream.opcodeControl || op == MirrorStream.opcodeHello || op == MirrorStream.opcodePacket || op == MirrorStream.opcodeStatus
        guard mirror else { return ("ignore", nil) }
        do {
            let m = try MirrorStream.decode(frame)
            return ("accept", MirrorStream.encode(m.message, timestampUs: m.timestampUs))
        } catch {
            return ("reject", nil)
        }
    }

    private static func problems(_ c: Case) -> [String] {
        var out: [String] = []
        guard let hex = c.hex, let frame = bytes(hex, pad: c.pad ?? 0) else { return ["bad hex"] }
        let result = decide(frame)
        if result.decision != c.expect {
            out.append("expected \(c.expect), got \(result.decision)")
        }
        if c.expect == "accept", let reencoded = result.reencoded {
            let padding = c.canonical_pad ?? c.pad ?? 0
            guard let canonicalHex = c.canonical, let canonical = bytes(canonicalHex, pad: padding) else { return out + ["bad canonical"] }
            if reencoded != canonical {
                let got = Hex.encode(Array(reencoded.prefix(64)))
                let want = Hex.encode(Array(canonical.prefix(64)))
                out.append("re-encode \(got) (\(reencoded.count) bytes) != canonical \(want) (\(canonical.count) bytes)")
            }
        }
        return out
    }

    func testCorpusShape() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.version, 1)
        XCTAssertEqual(corpus.generator, "gen_fuzz.py")
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 500)
        for op in corpus.opcodes {
            XCTAssertTrue(corpus.cases.contains { $0.opcode == op && $0.expect == "accept" }, "no valid case for opcode \(op)")
        }
        let names = Set(corpus.cases.map { $0.name })
        for name in FuzzCorpusTests.knownDivergent.keys {
            XCTAssertTrue(names.contains(name), "knownDivergent names a case the corpus lacks: \(name)")
        }
    }

    func testSwiftCodecAgreesWithTheFuzzCorpus() throws {
        let corpus = try loadCorpus()
        var failures: [String] = []
        var checked = 0
        for c in corpus.cases where c.expect != "encode_reject" {
            checked += 1
            let found = FuzzCorpusTests.problems(c)
            if let known = FuzzCorpusTests.knownDivergent[c.name] {
                if found.isEmpty {
                    failures.append("\(c.name): listed as divergent (\(known)) but now agrees; remove it from knownDivergent")
                }
            } else if !found.isEmpty {
                let finding = c.finding.map { " [\($0)]" } ?? ""
                failures.append("\(c.name)\(finding): \(found.joined(separator: "; "))")
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 500)
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
    }
}
