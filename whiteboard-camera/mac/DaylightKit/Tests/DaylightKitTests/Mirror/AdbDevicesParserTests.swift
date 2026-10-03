import Foundation
import XCTest
import DaylightKit

/// SPEC F1: the official example, serials with spaces, `*` noise lines and all states; `parseHostVersion`.
final class AdbDevicesParserTests: XCTestCase {
    func testOfficialExample() {
        let out = "List of devices attached\n0a388e93      device usb:1-1 product:razor model:Nexus_7 device:flo transport_id:1\n\n"
        let devices = AdbDevicesParser.parse(out)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0], AdbDevice(serial: "0a388e93", state: "device", model: "Nexus_7", product: "razor", transportID: 1))
        XCTAssertTrue(devices[0].isUSB)
        XCTAssertTrue(devices[0].isReady)
        XCTAssertFalse(devices[0].looksLikeDaylight)
    }

    func testNoiseLinesAndSerialsWithSpaces() {
        let out = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        adb server version (41) doesn't match this client (40); killing...
        List of devices attached
        JP12 ab cd         unauthorized usb:2-3 transport_id:7
        192.168.1.40:5555  device product:daylight_dc1 model:Daylight_DC_1 device:dc1 transport_id:8
        emulator-5554      offline transport_id:9

        """
        let devices = AdbDevicesParser.parse(out)
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices[0].serial, "JP12 ab cd")
        XCTAssertEqual(devices[0].state, "unauthorized")
        XCTAssertEqual(devices[0].transportID, 7)
        XCTAssertTrue(devices[0].looksLikeDaylight, "serial starts with JP")
        XCTAssertEqual(devices[1].serial, "192.168.1.40:5555")
        XCTAssertFalse(devices[1].isUSB)
        XCTAssertEqual(devices[1].model, "Daylight_DC_1")
        XCTAssertEqual(devices[1].product, "daylight_dc1")
        XCTAssertTrue(devices[1].looksLikeDaylight)
        XCTAssertEqual(devices[2], AdbDevice(serial: "emulator-5554", state: "offline", model: nil, product: nil, transportID: 9))
    }

    func testAllStatesParse() {
        for state in ["device", "offline", "unauthorized", "bootloader", "host", "recovery", "rescue", "sideload", "authorizing", "connecting", "detached"] {
            let device = AdbDevicesParser.parseLine("SERIAL123   \(state) transport_id:3")
            XCTAssertEqual(device?.state, state)
            XCTAssertEqual(device?.serial, "SERIAL123")
        }
        XCTAssertEqual(AdbDevicesParser.parseLine("0123456789ABCDEF\tno permissions transport_id:2")?.state, "no permissions")
        XCTAssertNil(AdbDevicesParser.parseLine("daemon started successfully"), "an unknown state is not a device")
        XCTAssertNil(AdbDevicesParser.parseLine("device"), "a state alone is not a device")
    }

    func testTrackDevicesShortFormat() {
        let devices = AdbDevicesParser.parse("0123456789ABCDEF\tdevice\nDC1XYZ\tunauthorized\n")
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].serial, "0123456789ABCDEF")
        XCTAssertEqual(devices[1].serial, "DC1XYZ")
        XCTAssertTrue(devices[1].looksLikeDaylight)
        XCTAssertEqual(AdbDevicesParser.parse("").count, 0)
    }

    func testModelHeuristic() {
        XCTAssertTrue(AdbDevice(serial: "X", state: "device", model: "DC-1").looksLikeDaylight)
        XCTAssertTrue(AdbDevice(serial: "X", state: "device", model: "daylight").looksLikeDaylight)
        XCTAssertFalse(AdbDevice(serial: "X", state: "device", model: "Pixel_7").looksLikeDaylight)
    }

    func testParseHostVersion() {
        XCTAssertEqual(AdbDevicesParser.parseHostVersion("Android Debug Bridge version 1.0.41\nVersion 37.0.0-14910828\nInstalled as /x/adb\nRunning on Darwin 24.5.0\n"), 41)
        XCTAssertEqual(AdbDevicesParser.parseHostVersion("OKAY00040029"), 41)
        XCTAssertEqual(AdbDevicesParser.parseHostVersion("0029"), 41)
        XCTAssertEqual(AdbDevicesParser.parseHostVersion("00040029"), 41)
        XCTAssertNil(AdbDevicesParser.parseHostVersion("FAIL0005nope!"))
        XCTAssertNil(AdbDevicesParser.parseHostVersion(""))
    }
}
