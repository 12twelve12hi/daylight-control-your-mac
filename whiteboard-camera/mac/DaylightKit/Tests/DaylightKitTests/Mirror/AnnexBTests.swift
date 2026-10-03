import Foundation
import XCTest
import DaylightKit

/// SPEC F1: `AnnexB` splits 3- and 4-byte start codes, trims trailing zeros, extracts SPS/PPS, converts to AVCC.
/// The SPS and PPS bytes are those of `mac/DaylightTests/Mirror/Fixtures/testsrc-320x240-6f.h264`.
final class AnnexBTests: XCTestCase {
    static let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x0D, 0xD9, 0x01, 0x41, 0xFB, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x03, 0xC0, 0xF1, 0x42, 0xA4, 0x80]
    static let pps: [UInt8] = [0x68, 0xCB, 0x83, 0xCB, 0x20]

    func testSplitsFourByteStartCodes() {
        let config: [UInt8] = [0, 0, 0, 1] + AnnexBTests.sps + [0, 0, 0, 1] + AnnexBTests.pps
        let ranges = AnnexB.nalUnits(config)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(Array(config[ranges[0]]), AnnexBTests.sps, "the trailing zero of the next start code is trimmed")
        XCTAssertEqual(Array(config[ranges[1]]), AnnexBTests.pps)
    }

    func testSplitsThreeByteStartCodesAndMixedForms() {
        let slice: [UInt8] = [0x41, 0x9A, 0x02, 0x3F]
        let au: [UInt8] = [0, 0, 1, 0x09, 0xF0] + [0, 0, 0, 1] + slice + [0, 0, 1] + [0x06, 0x05, 0x01]
        let ranges = AnnexB.nalUnits(au)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(Array(au[ranges[0]]), [0x09, 0xF0])
        XCTAssertEqual(Array(au[ranges[1]]), slice)
        XCTAssertEqual(Array(au[ranges[2]]), [0x06, 0x05, 0x01])
    }

    func testTrailingZerosAreTrimmedAndLeadingGarbageIgnored() {
        let au: [UInt8] = [0xFF, 0xEE] + [0, 0, 1] + [0x65, 0x88, 0x00, 0x00]
        let ranges = AnnexB.nalUnits(au)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(Array(au[ranges[0]]), [0x65, 0x88])
        XCTAssertEqual(AnnexB.nalUnits([UInt8]()).count, 0)
        XCTAssertEqual(AnnexB.nalUnits([0, 0, 1]).count, 0, "an empty NAL is dropped")
    }

    func testParameterSetsPickTypes7And8() {
        let config: [UInt8] = [0, 0, 0, 1, 0x09, 0x10] + [0, 0, 0, 1] + AnnexBTests.sps + [0, 0, 0, 1] + AnnexBTests.pps + [0, 0, 1, 0x06, 0x01]
        let sets = AnnexB.parameterSets(config)
        XCTAssertEqual(sets.sps, [AnnexBTests.sps])
        XCTAssertEqual(sets.pps, [AnnexBTests.pps])
        XCTAssertEqual(AnnexB.nalType(AnnexBTests.sps[0]), 7)
        XCTAssertEqual(AnnexB.nalType(AnnexBTests.pps[0]), 8)
        XCTAssertTrue(AnnexB.containsParameterSets(config))
        XCTAssertFalse(AnnexB.containsParameterSets([0, 0, 1, 0x41, 0x02]))
    }

    func testToAVCCWritesFourByteBigEndianLengths() {
        let au: [UInt8] = [0, 0, 0, 1] + AnnexBTests.sps + [0, 0, 1] + AnnexBTests.pps
        let avcc = AnnexB.toAVCC(au)
        XCTAssertEqual(avcc.count, 4 + 24 + 4 + 5)
        XCTAssertEqual(Array(avcc[0..<4]), [0, 0, 0, 24])
        XCTAssertEqual(Array(avcc[4..<28]), AnnexBTests.sps)
        XCTAssertEqual(Array(avcc[28..<32]), [0, 0, 0, 5])
        XCTAssertEqual(Array(avcc[32..<37]), AnnexBTests.pps)
        XCTAssertEqual(AnnexB.avccLengthPrefix, 4)
        var big = [UInt8](repeating: 0x33, count: 70_000)
        big[0] = 0x65
        let bigAVCC = AnnexB.toAVCC([0, 0, 0, 1] + big)
        XCTAssertEqual(Array(bigAVCC[0..<4]), [0x00, 0x01, 0x11, 0x70])
    }

    func testContainsIDR() {
        XCTAssertTrue(AnnexB.containsIDR([0, 0, 0, 1, 0x06, 0x01, 0, 0, 1, 0x65, 0x88]))
        XCTAssertFalse(AnnexB.containsIDR([0, 0, 0, 1, 0x41, 0x9A]))
        XCTAssertFalse(AnnexB.containsIDR([UInt8]()))
    }
}
