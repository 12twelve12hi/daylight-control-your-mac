import Foundation
import XCTest
import DaylightKit

/// SPEC F1: lines with and without the device prefix parse; partial lines across reads; timestamps; noise ignored.
final class EvdevParserTests: XCTestCase {
    func testLabelledLineWithTimestamp() {
        let e = EvdevParser.parseLine("[   12345.678901] EV_KEY       BTN_TOUCH            DOWN                ")
        XCTAssertEqual(e, EvdevEvent(tsUs: 12_345_678_901, type: "EV_KEY", code: "BTN_TOUCH", value: "DOWN"))
        XCTAssertEqual(e?.numericValue, 1)
    }

    func testLineWithDevicePrefix() {
        let e = EvdevParser.parseLine("/dev/input/event3: [    1.000002] EV_ABS       ABS_PRESSURE         00000fff            ")
        XCTAssertEqual(e, EvdevEvent(tsUs: 1_000_002, type: "EV_ABS", code: "ABS_PRESSURE", value: "00000fff"))
        XCTAssertEqual(e?.numericValue, 4095)
    }

    func testLineWithoutTimestamp() {
        let e = EvdevParser.parseLine("EV_SYN       SYN_REPORT           00000000")
        XCTAssertEqual(e, EvdevEvent(tsUs: 0, type: "EV_SYN", code: "SYN_REPORT", value: "00000000"))
        XCTAssertEqual(e?.isSynReport, true)
    }

    func testRawHexLineWithoutLabels() {
        let e = EvdevParser.parseLine("0001 014a 00000001")
        XCTAssertEqual(e, EvdevEvent(tsUs: 0, type: "0001", code: "014a", value: "00000001"))
        XCTAssertEqual(e?.numericValue, 1)
    }

    func testNegativeHexValue() {
        let e = EvdevParser.parseLine("[0.000000] EV_ABS ABS_MT_TRACKING_ID ffffffff")
        XCTAssertEqual(e?.numericValue, -1)
    }

    func testNoiseLinesAreIgnored() {
        XCTAssertNil(EvdevParser.parseLine("add device 1: /dev/input/event3"))
        XCTAssertNil(EvdevParser.parseLine("  name:     \"Wacom I2C Digitizer\""))
        XCTAssertNil(EvdevParser.parseLine(""))
        XCTAssertNil(EvdevParser.parseLine("could not get driver version for /dev/input/mouse0, Not a typewriter"))
        XCTAssertNil(EvdevParser.parseLine("/dev/input/event3: [ 1.0 ] EV_KEY"))
    }

    func testPartialLinesAcrossReads() {
        var parser = EvdevParser()
        var events: [EvdevEvent] = []
        let text = "[   10.000100] EV_KEY       BTN_TOOL_PEN         DOWN\n[   10.000100] EV_KEY       BTN_TOUCH            DOWN\r\n[   10.000100] EV_SYN       SYN_REPORT           00000000\n"
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            let end = min(bytes.count, i + 5)
            Array(bytes[i..<end]).withUnsafeBytes { raw in parser.feed(raw) { events.append($0) } }
            i = end
        }
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].code, "BTN_TOOL_PEN")
        XCTAssertEqual(events[1].code, "BTN_TOUCH")
        XCTAssertEqual(events[1].tsUs, 10_000_100)
        XCTAssertTrue(events[2].isSynReport)
        // A trailing fragment waits for its newline.
        parser.feed("[   11.5] EV_KEY  BTN_TOUCH  UP") { _ in XCTFail("no newline yet") }
        parser.feed("\n") { events.append($0) }
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[3].tsUs, 11_500_000)
        XCTAssertEqual(events[3].numericValue, 0)
    }
}
