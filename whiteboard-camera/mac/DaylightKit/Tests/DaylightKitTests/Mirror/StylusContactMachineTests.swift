import Foundation
import XCTest
import DaylightKit

/// SPEC F1: contact edges only on `SYN_REPORT`, hover emits nothing, eraser and side buttons are distinguished.
final class StylusContactMachineTests: XCTestCase {
    private func key(_ code: String, _ value: String, ts: UInt64 = 0) -> EvdevEvent { return EvdevEvent(tsUs: ts, type: "EV_KEY", code: code, value: value) }
    private func abs(_ code: String, _ value: Int, ts: UInt64 = 0) -> EvdevEvent {
        var hex = String(UInt32(bitPattern: Int32(value)), radix: 16)
        while hex.count < 8 { hex = "0" + hex }
        return EvdevEvent(tsUs: ts, type: "EV_ABS", code: code, value: hex)
    }
    private func syn(ts: UInt64 = 0) -> EvdevEvent { return EvdevEvent(tsUs: ts, type: "EV_SYN", code: "SYN_REPORT", value: "00000000") }

    func testEdgesOnlyOnSynReport() {
        var m = StylusContactMachine(pressureMax: 4095)
        XCTAssertEqual(m.apply(key("BTN_TOOL_PEN", "DOWN")), [])
        XCTAssertEqual(m.apply(abs("ABS_X", 100)), [])
        XCTAssertEqual(m.apply(abs("ABS_Y", 200)), [])
        XCTAssertEqual(m.apply(key("BTN_TOUCH", "DOWN")), [], "no edge before the report")
        XCTAssertEqual(m.apply(abs("ABS_PRESSURE", 2048)), [])
        let out = m.apply(syn(ts: 5_000_000))
        XCTAssertEqual(out.count, 1)
        guard case let .contactDown(sample)? = out.first else { return XCTFail("contactDown expected, got \(out)") }
        XCTAssertTrue(sample.inRange)
        XCTAssertTrue(sample.touching)
        XCTAssertEqual(sample.x, 100)
        XCTAssertEqual(sample.y, 200)
        XCTAssertEqual(sample.pressure, 2048.0 / 4095.0, accuracy: 1e-9)
        XCTAssertEqual(sample.tsUs, 5_000_000)
        // Motion while touching: nothing.
        XCTAssertEqual(m.apply(abs("ABS_X", 101)), [])
        XCTAssertEqual(m.apply(abs("ABS_PRESSURE", 3000)), [])
        XCTAssertEqual(m.apply(syn(ts: 5_010_000)), [])
        // Lift.
        XCTAssertEqual(m.apply(key("BTN_TOUCH", "UP")), [])
        XCTAssertEqual(m.apply(abs("ABS_PRESSURE", 0)), [])
        let up = m.apply(syn(ts: 5_020_000))
        guard case let .contactUp(upSample)? = up.first, up.count == 1 else { return XCTFail("contactUp expected, got \(up)") }
        XCTAssertFalse(upSample.touching)
        XCTAssertTrue(upSample.inRange, "the pen still hovers")
    }

    func testHoverEmitsNothing() {
        var m = StylusContactMachine(pressureMax: 4095)
        _ = m.apply(key("BTN_TOOL_PEN", "DOWN"))
        XCTAssertEqual(m.apply(syn()), [])
        for x in 0..<50 {
            _ = m.apply(abs("ABS_X", x))
            _ = m.apply(abs("ABS_DISTANCE", 20))
            XCTAssertEqual(m.apply(syn()), [])
        }
        _ = m.apply(key("BTN_TOOL_PEN", "UP"))
        XCTAssertEqual(m.apply(syn()), [])
        XCTAssertFalse(m.current.penContact)
    }

    func testEraserIsDistinguishedFromThePenTip() {
        var m = StylusContactMachine(pressureMax: 4095)
        _ = m.apply(key("BTN_TOOL_RUBBER", "DOWN"))
        _ = m.apply(key("BTN_TOUCH", "DOWN"))
        _ = m.apply(abs("ABS_PRESSURE", 1000))
        let down = m.apply(syn(ts: 1))
        guard case .eraserDown? = down.first, down.count == 1 else { return XCTFail("eraserDown expected, got \(down)") }
        _ = m.apply(key("BTN_TOUCH", "UP"))
        let up = m.apply(syn(ts: 2))
        guard case .eraserUp? = up.first, up.count == 1 else { return XCTFail("eraserUp expected, got \(up)") }
        _ = m.apply(key("BTN_TOOL_RUBBER", "UP"))
        XCTAssertEqual(m.apply(syn(ts: 3)), [])
    }

    func testSideButtonsAreSeparateEdges() {
        var m = StylusContactMachine(pressureMax: 4095)
        _ = m.apply(key("BTN_TOOL_PEN", "DOWN"))
        _ = m.apply(key("BTN_STYLUS", "DOWN"))
        XCTAssertEqual(m.apply(syn(ts: 10)), [.side1Down(tsUs: 10)])
        _ = m.apply(key("BTN_STYLUS", "UP"))
        XCTAssertEqual(m.apply(syn(ts: 20)), [.side1Up(tsUs: 20)])
        _ = m.apply(key("BTN_STYLUS2", "DOWN"))
        XCTAssertEqual(m.apply(syn(ts: 30)), [.side2Down(tsUs: 30)])
        _ = m.apply(key("BTN_STYLUS2", "UP"))
        _ = m.apply(key("BTN_TOUCH", "DOWN"))
        let both = m.apply(syn(ts: 40))
        XCTAssertEqual(both.count, 2)
        guard case .contactDown? = both.first else { return XCTFail("contact edge first") }
        XCTAssertEqual(both[1], .side2Up(tsUs: 40))
    }

    func testPressureClampsAndRawValuesParse() {
        var m = StylusContactMachine(pressureMax: 1023)
        _ = m.apply(key("BTN_TOOL_PEN", "DOWN"))
        _ = m.apply(key("BTN_TOUCH", "DOWN"))
        _ = m.apply(EvdevEvent(tsUs: 0, type: "EV_ABS", code: "ABS_PRESSURE", value: "000007ff"))
        let out = m.apply(syn())
        guard case let .contactDown(sample)? = out.first else { return XCTFail() }
        XCTAssertEqual(sample.pressure, 1, "2047 over a 1023 max clamps to 1")
        XCTAssertEqual(StylusContactMachine(pressureMax: 0).pressureMax, 1, "a zero max never divides by zero")
    }

    func testResetReleasesEverything() {
        var m = StylusContactMachine(pressureMax: 4095)
        _ = m.apply(key("BTN_TOOL_PEN", "DOWN"))
        _ = m.apply(key("BTN_TOUCH", "DOWN"))
        _ = m.apply(key("BTN_STYLUS", "DOWN"))
        _ = m.apply(syn(ts: 1))
        let out = m.reset(tsUs: 2)
        XCTAssertEqual(out.count, 2)
        guard case .contactUp? = out.first else { return XCTFail("contactUp expected") }
        XCTAssertEqual(out[1], .side1Up(tsUs: 2))
        XCTAssertEqual(m.reset(tsUs: 3), [])
    }
}
