import CoreMediaIO
import DaylightKit
import XCTest
@testable import Daylight

/// The pure rules of the device walk (sink is streams[1], directions logged), the four-character codes and the
/// viewers property parser, plus one real walk on the runner (no Daylight Camera there: nil, no crash).
final class CMIOLocatorTests: XCTestCase {
    static let deviceUUID = UUID(uuidString: "AB51C6BA-17FD-4A67-BE3A-06A8540BA6AA")!

    func testFourCharacterCodes() {
        XCTAssertEqual(CMIOProperties.fourCC("dlvw"), 0x646C_7677)
        XCTAssertEqual(CMIOProperties.fourCCString(0x646C_7677), "dlvw")
        XCTAssertEqual(CMIOProperties.fourCC("sdir"), UInt32(truncatingIfNeeded: kCMIOStreamPropertyDirection), "the SDK selector 'sdir'")
        XCTAssertEqual(CMIOProperties.fourCC("dev#"), UInt32(truncatingIfNeeded: kCMIOHardwarePropertyDevices))
        XCTAssertEqual(CMIOProperties.fourCC("uid "), UInt32(truncatingIfNeeded: kCMIODevicePropertyDeviceUID))
        XCTAssertEqual(CMIOProperties.fourCC("stm#"), UInt32(truncatingIfNeeded: kCMIODevicePropertyStreams))
        XCTAssertEqual(CMIOProperties.fourCC("bad"), 0)
        XCTAssertEqual(ViewerWatcher.propertySelector, CMIOProperties.fourCC("dlvw"))
        let address = CMIOProperties.address(selector: ViewerWatcher.propertySelector)
        XCTAssertEqual(address.mSelector, 0x646C_7677)
        XCTAssertEqual(address.mScope, CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal))
        XCTAssertEqual(address.mElement, CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    func testSinkIsTheSecondStreamAndSourceTheFirst() {
        XCTAssertEqual(CMIODeviceLocator.sinkStreamIndex(streamCount: 2, directions: [1, 0]), 1)
        XCTAssertEqual(CMIODeviceLocator.sinkStreamIndex(streamCount: 2, directions: [0, 1]), 1, "stream order wins over the UNVERIFIED direction value (LOOSE_ENDS E2)")
        XCTAssertEqual(CMIODeviceLocator.sinkStreamIndex(streamCount: 3, directions: [1, 0, 0]), 1)
        XCTAssertNil(CMIODeviceLocator.sinkStreamIndex(streamCount: 1, directions: [1]), "one stream: no sink (row 14)")
        XCTAssertNil(CMIODeviceLocator.sinkStreamIndex(streamCount: 0, directions: []))
        XCTAssertEqual(CMIODeviceLocator.sourceStreamIndex(streamCount: 2), 0)
        XCTAssertEqual(CMIODeviceLocator.sourceStreamIndex(streamCount: 1), 0)
        XCTAssertNil(CMIODeviceLocator.sourceStreamIndex(streamCount: 0))
    }

    func testDirectionExpectationIsOnlyLogged() {
        XCTAssertFalse(CMIODeviceLocator.directionsLookUnexpected([1, 0]))
        XCTAssertTrue(CMIODeviceLocator.directionsLookUnexpected([0, 1]))
        XCTAssertTrue(CMIODeviceLocator.directionsLookUnexpected([UInt32.max, UInt32.max]))
        XCTAssertFalse(CMIODeviceLocator.directionsLookUnexpected([1]), "nothing to compare")
        let layout = CMIODeviceLocator.layoutDescription(streams: [41, 42], directions: [1, UInt32.max])
        XCTAssertEqual(layout.ids, "[41, 42]")
        XCTAssertEqual(layout.directions, "[1, ?]")
        XCTAssertEqual(FailureText.logLine(.sinkStreamLayout, [layout.ids, layout.directions]), "failure.sinkStreamLayout (row 14): streams=[41, 42] directions=[1, ?]")
    }

    func testRealWalkOnThisMacFindsNoDaylightCameraWithoutTheExtension() {
        let locator = CMIODeviceLocator(deviceUUID: CMIOLocatorTests.deviceUUID)
        let uids = locator.deviceUIDs()
        print("camera-tests: CMIO device UIDs on this Mac: \(uids)")
        let found = locator.locate()
        if let found = found {
            // Only on a Mac where the owner's signed extension is active.
            print("camera-tests: Daylight Camera found: device=\(found.device) streams=\(found.streams) directions=\(found.directions)")
            XCTAssertGreaterThanOrEqual(found.streams.count, 2)
        } else {
            XCTAssertFalse(uids.contains(CMIOLocatorTests.deviceUUID.uuidString), "the fixed UUID is absent from the device list when locate() says nil")
        }
        XCTAssertEqual(FailureText.logLine(.sinkDeviceNotFound, [CMIOLocatorTests.deviceUUID.uuidString, uids.description]).hasPrefix("failure.sinkDeviceNotFound (row 13): sink: no CMIO device with UID AB51C6BA"), true)
    }

    func testViewersPropertyParser() {
        XCTAssertEqual(ViewerWatcher.parseCount(.string("sc=1")), 1)
        XCTAssertEqual(ViewerWatcher.parseCount(.string("sc=12")), 12)
        XCTAssertEqual(ViewerWatcher.parseCount(.string("0")), 0)
        XCTAssertEqual(ViewerWatcher.parseCount(.string("3")), 3)
        XCTAssertNil(ViewerWatcher.parseCount(.string("sc=")))
        XCTAssertNil(ViewerWatcher.parseCount(.string("")))
        XCTAssertEqual(ViewerWatcher.parseCount(.number(2)), 2)
        XCTAssertNil(ViewerWatcher.parseCount(.number(-1)))
        XCTAssertNil(ViewerWatcher.parseCount(.unsupported(size: 16)))
        XCTAssertEqual(ViewerWatcher.pollInterval, 1, "SPEC: 1 Hz poll fallback, always on")
    }

    /// Finding 04: a failed property read no longer forgets the stream (which re-registered a listener block every
    /// second on the fallback path); the stream only changes when the device is gone or carries a new source stream id.
    func testFailedReadKeepsTheStreamUnlessTheDeviceChanged() {
        XCTAssertEqual(ViewerWatcher.streamAfterFailedRead(current: 41, located: 41), 41, "same stream: keep it, no new listener")
        XCTAssertEqual(ViewerWatcher.streamAfterFailedRead(current: 41, located: 51), 51, "the extension was replaced: follow the new id")
        XCTAssertNil(ViewerWatcher.streamAfterFailedRead(current: 41, located: nil), "device gone: re-locate on the next poll")
    }

    func testWatcherWithoutTheDeviceReportsZeroOnceAndNeverCrashes() {
        let queue = DispatchQueue(label: "camera-tests.viewers")
        let locator = CMIODeviceLocator(deviceUUID: UUID())
        let watcher = ViewerWatcher(locator: locator, queue: queue)
        var reports: [Int] = []
        let lock = NSLock()
        watcher.onViewerCount = { count in lock.lock(); reports.append(count); lock.unlock() }
        watcher.start()
        let polled = expectation(description: "two polls")
        queue.asyncAfter(deadline: .now() + 0.3) { watcher.poll(); watcher.poll(); polled.fulfill() }
        wait(for: [polled], timeout: 5)
        XCTAssertEqual(watcher.viewerCount, 0)
        XCTAssertEqual(watcher.listenerRegistrations, 0, "no stream, no read succeeded: no listener block is registered")
        lock.lock()
        XCTAssertTrue(reports.isEmpty, "zero is the initial state; nothing changed, nothing reported")
        lock.unlock()
        watcher.stop()
        let stopped = expectation(description: "stopped")
        queue.async { stopped.fulfill() }
        wait(for: [stopped], timeout: 5)
    }
}
