import Foundation
import XCTest
import DaylightKit

/// `getevent -pl` parsing and the pen-node ranking (BTN_TOOL_PEN plus a pressure axis; a node without ABS_MT_SLOT first,
/// then a pen-like name, then listing order).
final class EvdevCapabilitiesTests: XCTestCase {
    /// Shape from getevent.c `print_possible_events` (labels in columns of four, ABS one per line) for a Wacom digitizer,
    /// a multitouch finger screen and a key device.
    static let listing = """
    add device 1: /dev/input/event3
      name:     "Wacom I2C Digitizer"
      events:
        KEY (0001): BTN_TOOL_PEN          BTN_TOOL_RUBBER       BTN_TOUCH             BTN_STYLUS*
                    BTN_STYLUS2
        ABS (0003): ABS_X                 : value 0, min 0, max 21600, fuzz 0, flat 0, resolution 100
                    ABS_Y                 : value 0, min 0, max 16200, fuzz 0, flat 0, resolution 100
                    ABS_PRESSURE          : value 0, min 0, max 4095, fuzz 0, flat 0, resolution 0
                    ABS_DISTANCE          : value 0, min 0, max 255, fuzz 0, flat 0, resolution 0
      input props:
        INPUT_PROP_DIRECT
    add device 2: /dev/input/event4
      name:     "fts_ts"
      events:
        KEY (0001): BTN_TOUCH             BTN_TOOL_FINGER
        ABS (0003): ABS_MT_SLOT           : value 0, min 0, max 9, fuzz 0, flat 0, resolution 0
                    ABS_MT_POSITION_X     : value 0, min 0, max 1199, fuzz 0, flat 0, resolution 0
                    ABS_MT_POSITION_Y     : value 0, min 0, max 1599, fuzz 0, flat 0, resolution 0
                    ABS_MT_TRACKING_ID    : value 0, min 0, max 65535, fuzz 0, flat 0, resolution 0
                    ABS_PRESSURE          : value 0, min 0, max 255, fuzz 0, flat 0, resolution 0
      input props:
        INPUT_PROP_DIRECT
    add device 3: /dev/input/event0
      name:     "mtk-kpd"
      events:
        KEY (0001): KEY_VOLUMEDOWN        KEY_VOLUMEUP          KEY_POWER
      input props:
        <none>
    could not get driver version for /dev/input/mouse0, Not a typewriter

    """

    func testParsesEveryDevice() {
        let devices = EvdevCapabilitiesParser.parse(EvdevCapabilitiesTests.listing)
        XCTAssertEqual(devices.count, 3)
        let wacom = devices[0]
        XCTAssertEqual(wacom.path, "/dev/input/event3")
        XCTAssertEqual(wacom.name, "Wacom I2C Digitizer")
        XCTAssertEqual(wacom.keys, ["BTN_TOOL_PEN", "BTN_TOOL_RUBBER", "BTN_TOUCH", "BTN_STYLUS", "BTN_STYLUS2"], "the * of a held key is stripped and the continuation line counts")
        XCTAssertEqual(wacom.abs["ABS_X"], EvdevCapabilities.AxisRange(min: 0, max: 21600))
        XCTAssertEqual(wacom.abs["ABS_PRESSURE"], EvdevCapabilities.AxisRange(min: 0, max: 4095))
        XCTAssertEqual(wacom.abs["ABS_DISTANCE"]?.max, 255)
        XCTAssertNil(wacom.abs["ABS_MT_SLOT"])
        XCTAssertEqual(wacom.props, ["INPUT_PROP_DIRECT"])
        XCTAssertEqual(wacom.pressureMax, 4095)
        XCTAssertTrue(wacom.hasSideButton)
        let touch = devices[1]
        XCTAssertEqual(touch.name, "fts_ts")
        XCTAssertNotNil(touch.abs["ABS_MT_SLOT"])
        XCTAssertEqual(touch.abs["ABS_MT_POSITION_Y"]?.max, 1599)
        let keys = devices[2]
        XCTAssertEqual(keys.keys, ["KEY_VOLUMEDOWN", "KEY_VOLUMEUP", "KEY_POWER"])
        XCTAssertTrue(keys.props.isEmpty, "<none> is not a prop")
        XCTAssertEqual(keys.pressureMax, EvdevCapabilitiesParser.defaultPressureMax)
    }

    func testPenNodeRule() {
        let devices = EvdevCapabilitiesParser.parse(EvdevCapabilitiesTests.listing)
        let pen = EvdevCapabilitiesParser.penNode(devices)
        XCTAssertEqual(pen?.path, "/dev/input/event3")
        XCTAssertNil(EvdevCapabilitiesParser.penNode(Array(devices[1...])), "a multitouch node without BTN_TOOL_PEN is not the pen")
        XCTAssertEqual(EvdevCapabilitiesParser.penNodeChoice(devices)?.reason, "dedicated pen node named like a pen")
        XCTAssertNil(EvdevCapabilitiesParser.penNode([]))
        // Two candidates: the one whose name says so wins.
        let generic = EvdevCapabilities(path: "/dev/input/event7", name: "generic", keys: ["BTN_TOOL_PEN"], abs: ["ABS_PRESSURE": .init(min: 0, max: 1023)])
        let wacom = EvdevCapabilities(path: "/dev/input/event8", name: "Wacom Pen", keys: ["BTN_TOOL_PEN"], abs: ["ABS_PRESSURE": .init(min: 0, max: 4095)])
        XCTAssertEqual(EvdevCapabilitiesParser.penNode([generic, wacom])?.path, "/dev/input/event8")
        XCTAssertEqual(EvdevCapabilitiesParser.penNode([generic])?.pressureMax, 1023)
    }

    /// A listing without a dedicated digitizer: one multitouch node carries BTN_TOOL_PEN and ABS_MT_PRESSURE (a pen
    /// multiplexed with the fingers). Before the ranking this was rejected outright (row 28 with the pen events present).
    static let combinedListing = """
    add device 1: /dev/input/event2
      name:     "goodix_ts"
      events:
        KEY (0001): BTN_TOOL_PEN          BTN_TOOL_FINGER       BTN_TOUCH             BTN_STYLUS
        ABS (0003): ABS_MT_SLOT           : value 0, min 0, max 9, fuzz 0, flat 0, resolution 0
                    ABS_MT_POSITION_X     : value 0, min 0, max 1599, fuzz 0, flat 0, resolution 0
                    ABS_MT_POSITION_Y     : value 0, min 0, max 2559, fuzz 0, flat 0, resolution 0
                    ABS_MT_TRACKING_ID    : value 0, min 0, max 65535, fuzz 0, flat 0, resolution 0
                    ABS_MT_PRESSURE       : value 0, min 0, max 1023, fuzz 0, flat 0, resolution 0
      input props:
        INPUT_PROP_DIRECT
    add device 2: /dev/input/event0
      name:     "mtk-kpd"
      events:
        KEY (0001): KEY_VOLUMEDOWN        KEY_VOLUMEUP          KEY_POWER

    """

    func testCombinedNodeIsChosenWhenNoDedicatedPenNodeExists() {
        let devices = EvdevCapabilitiesParser.parse(EvdevCapabilitiesTests.combinedListing)
        XCTAssertEqual(devices.count, 2)
        let choice = EvdevCapabilitiesParser.penNodeChoice(devices)
        XCTAssertEqual(choice?.node.path, "/dev/input/event2")
        XCTAssertEqual(choice?.reason, "multitouch node; the pen shares the finger touchscreen node")
        XCTAssertTrue(choice?.node.isMultitouch ?? false)
        XCTAssertEqual(choice?.node.pressureAxis, "ABS_MT_PRESSURE")
        XCTAssertEqual(choice?.node.pressureMax, 1023, "ABS_MT_PRESSURE stands in for ABS_PRESSURE")
        XCTAssertTrue(choice?.node.hasSideButton ?? false)
        // The machine built from it gates contact on pressure.
        let machine = StylusContactMachine(node: devices[0])
        XCTAssertEqual(machine.pressureMax, 1023)
        XCTAssertTrue(machine.contactRequiresPressure)
        XCTAssertFalse(StylusContactMachine(node: EvdevCapabilitiesParser.parse(EvdevCapabilitiesTests.listing)[0]).contactRequiresPressure, "a dedicated Wacom node keeps the plain BTN_TOUCH rule")
    }

    func testDedicatedNodeBeatsCombinedNodeWhateverTheNames() {
        let combinedNamedPen = EvdevCapabilities(path: "/dev/input/event2", name: "Wacom Pen and Touch", keys: ["BTN_TOOL_PEN", "BTN_TOUCH"], abs: ["ABS_MT_SLOT": .init(min: 0, max: 9), "ABS_MT_PRESSURE": .init(min: 0, max: 1023)])
        let dedicatedUnnamed = EvdevCapabilities(path: "/dev/input/event5", name: "generic_input", keys: ["BTN_TOOL_PEN", "BTN_TOUCH"], abs: ["ABS_PRESSURE": .init(min: 0, max: 4095)])
        let choice = EvdevCapabilitiesParser.penNodeChoice([combinedNamedPen, dedicatedUnnamed])
        XCTAssertEqual(choice?.node.path, "/dev/input/event5", "no ABS_MT_SLOT outranks a pen-like name")
        XCTAssertEqual(choice?.reason, "dedicated pen node")
        // Two multitouch candidates: the pen-like name wins, then listing order.
        let combinedPlain = EvdevCapabilities(path: "/dev/input/event3", name: "fts_ts", keys: ["BTN_TOOL_PEN"], abs: ["ABS_MT_SLOT": .init(min: 0, max: 9), "ABS_MT_PRESSURE": .init(min: 0, max: 255)])
        XCTAssertEqual(EvdevCapabilitiesParser.penNode([combinedPlain, combinedNamedPen])?.path, "/dev/input/event2")
        XCTAssertEqual(EvdevCapabilitiesParser.penNodeChoice([combinedPlain, combinedNamedPen])?.reason, "multitouch node named like a pen; the pen shares the finger touchscreen node")
        let combinedPlain2 = EvdevCapabilities(path: "/dev/input/event4", name: "fts_ts2", keys: ["BTN_TOOL_PEN"], abs: ["ABS_MT_SLOT": .init(min: 0, max: 9), "ABS_MT_PRESSURE": .init(min: 0, max: 255)])
        XCTAssertEqual(EvdevCapabilitiesParser.penNode([combinedPlain, combinedPlain2])?.path, "/dev/input/event3", "listing order breaks the tie")
        // A pen node without any pressure axis is still not a candidate.
        let noPressure = EvdevCapabilities(path: "/dev/input/event6", name: "Wacom Pen", keys: ["BTN_TOOL_PEN"], abs: ["ABS_X": .init(min: 0, max: 100)])
        XCTAssertNil(EvdevCapabilitiesParser.penNode([noPressure]))
        XCTAssertNil(noPressure.pressureAxis)
        XCTAssertEqual(noPressure.pressureMax, EvdevCapabilitiesParser.defaultPressureMax)
    }

    func testCRLFListingParsesLikeLF() {
        let crlf = EvdevCapabilitiesTests.listing.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(EvdevCapabilitiesParser.parse(crlf), EvdevCapabilitiesParser.parse(EvdevCapabilitiesTests.listing), "adb shell without -T emits CRLF")
    }

    func testEmptyAndGarbageInput() {
        XCTAssertEqual(EvdevCapabilitiesParser.parse("").count, 0)
        XCTAssertEqual(EvdevCapabilitiesParser.parse("error: device offline\n").count, 0)
        let noEvents = EvdevCapabilitiesParser.parse("add device 1: /dev/input/event9\n  name:     \"x\"\n")
        XCTAssertEqual(noEvents.count, 1)
        XCTAssertEqual(noEvents[0].name, "x")
        XCTAssertTrue(noEvents[0].keys.isEmpty)
    }
}
