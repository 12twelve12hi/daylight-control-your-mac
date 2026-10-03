import DaylightKit
import Foundation
import XCTest
@testable import Daylight

/// Device tracking through the `devices -l` fallback with a fake adb, and the DC-1 choice rule.
final class DeviceTrackerTests: XCTestCase {
    func testPollingPublishesChangesOnly() {
        let adb = FakeAdb()
        let listing = Locked("List of devices attached\nJP0001   device usb:1-1 product:daylight model:Daylight_DC_1 device:dc1 transport_id:1\n")
        adb.respond { args in args == ["devices", "-l"] ? FakeAdb.ok(listing.withLock { $0 }) : nil }
        let tracker = DeviceTracker(adb: adb, queue: DispatchQueue(label: "tracker"), pollInterval: 0.05, useTrackSocket: false)
        let first = expectation(description: "first list")
        let second = expectation(description: "second list")
        let seen = Locked<[[AdbDevice]]>([])
        tracker.onDevices = { list in
            let count = seen.withLock { lists -> Int in
                lists.append(list)
                return lists.count
            }
            if count == 1 { first.fulfill() }
            if count == 2 { second.fulfill() }
        }
        tracker.start()
        wait(for: [first], timeout: 5)
        XCTAssertEqual(tracker.devices.first?.serial, "JP0001")
        XCTAssertEqual(tracker.devices.first?.model, "Daylight_DC_1")
        XCTAssertFalse(tracker.isTracking, "polling, not the track socket")
        listing.withLock { $0 = "JP0001   unauthorized usb:1-1 transport_id:1\n" }
        wait(for: [second], timeout: 5)
        XCTAssertEqual(tracker.devices.first?.state, "unauthorized")
        // Unchanged lists are not republished: after a few more polls the count stays at 2.
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 5)
        XCTAssertEqual(seen.withLock { $0.count }, 2)
        XCTAssertGreaterThan(adb.calls(containing: "devices").count, 3, "it keeps polling")
        tracker.stop()
        XCTAssertFalse(tracker.isRunning)
    }

    func testStartIsIdempotentAndStopEndsPolling() {
        let adb = FakeAdb()
        adb.respond(containing: ["devices"], with: FakeAdb.ok(""))
        let tracker = DeviceTracker(adb: adb, queue: DispatchQueue(label: "tracker"), pollInterval: 0.05, useTrackSocket: false)
        tracker.start()
        tracker.start()
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 5)
        tracker.stop()
        let before = adb.calls.count
        let later = expectation(description: "later")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { later.fulfill() }
        wait(for: [later], timeout: 5)
        XCTAssertLessThanOrEqual(adb.calls.count, before + 1, "at most one in-flight poll after stop")
    }

    func testChooseDaylight() {
        let pixel = AdbDevice(serial: "ABC", state: "device", model: "Pixel_7")
        let daylightOffline = AdbDevice(serial: "JP0002", state: "offline", model: "Daylight_DC_1")
        let daylightReady = AdbDevice(serial: "DC1X", state: "device", model: "DC-1")
        let wifi = AdbDevice(serial: "192.168.1.40:5555", state: "device", model: "Daylight_DC_1")
        XCTAssertEqual(DeviceTracker.chooseDaylight([pixel, daylightOffline, daylightReady], preferredSerial: nil)?.serial, "DC1X", "a ready DC-1 beats an offline one and a Pixel")
        XCTAssertEqual(DeviceTracker.chooseDaylight([pixel, daylightOffline], preferredSerial: nil)?.serial, "JP0002", "an offline DC-1 is still the DC-1 (row 23)")
        XCTAssertEqual(DeviceTracker.chooseDaylight([pixel], preferredSerial: nil)?.serial, "ABC", "else the first ready device")
        XCTAssertEqual(DeviceTracker.chooseDaylight([AdbDevice(serial: "X", state: "unauthorized")], preferredSerial: nil)?.state, "unauthorized", "else the first device of any state (row 22)")
        XCTAssertEqual(DeviceTracker.chooseDaylight([daylightReady, pixel], preferredSerial: "ABC")?.serial, "ABC", "mirrorDeviceSerial overrides")
        XCTAssertEqual(DeviceTracker.chooseDaylight([wifi, daylightReady], preferredSerial: nil)?.serial, "192.168.1.40:5555", "first ready DC-1 in list order")
        XCTAssertNil(DeviceTracker.chooseDaylight([], preferredSerial: "ABC"))
    }
}
