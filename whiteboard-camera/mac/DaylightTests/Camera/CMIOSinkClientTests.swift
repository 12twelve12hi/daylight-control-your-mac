import CoreMedia
import DaylightKit
import XCTest
@testable import Daylight

/// The host sink client without a Daylight Camera on the machine: every status path short of `.connected`, pushes
/// never block and report drops, and the installer feed drives rows 12, 12b and 13.
final class CMIOSinkClientTests: XCTestCase {
    static let deviceUUID = UUID(uuidString: "AB51C6BA-17FD-4A67-BE3A-06A8540BA6AA")!
    static let sinkUUID = UUID(uuidString: "4B856AE3-B992-490B-8DC5-1F2A9475D6E7")!

    private func makeClient(queue: DispatchQueue) -> CMIOSinkClient {
        let client = CMIOSinkClient(deviceUUID: CMIOSinkClientTests.deviceUUID, sinkUUID: CMIOSinkClientTests.sinkUUID, queue: queue)
        client.retryInterval = 0.2
        return client
    }

    private func drain(_ queue: DispatchQueue) {
        let done = expectation(description: "queue drained")
        queue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testConstantsMatchTheSpec() {
        XCTAssertEqual(CMIOSinkClient.retryInterval, 2, "row 13: retry loop every 2 s")
        XCTAssertEqual(CMIOSinkClient.notFoundFollowUpDelay, 30, "row 13: second sentence after 30 s")
    }

    func testPushBeforeStartDropsWithoutBlocking() throws {
        let client = makeClient(queue: DispatchQueue(label: "camera-tests.sink"))
        XCTAssertEqual(client.status, .notInstalled)
        XCTAssertFalse(client.isConnected)
        XCTAssertNil(client.queueCountAndCapacity)
        let feeder = SinkFeeder(sink: client)
        let buffer = try XCTUnwrap(CameraTestBuffers.make(width: 64, height: 36))
        let started = Date()
        for _ in 0..<50 { XCTAssertFalse(feeder.push(buffer, hostTimeNs: nil)) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "50 dropped pushes return at once")
        XCTAssertEqual(feeder.droppedFrames, 50)
        XCTAssertEqual(client.droppedFrames, 50)
        XCTAssertEqual(client.enqueuedFrames, 0)
        XCTAssertEqual(client.viewerCount, 0)
    }

    func testStartWithoutTheDeviceKeepsSearchingAndStopIsClean() {
        let queue = DispatchQueue(label: "camera-tests.sink")
        let client = makeClient(queue: queue)
        var statuses: [SinkStatus] = []
        let lock = NSLock()
        client.onStatusChange = { status in lock.lock(); statuses.append(status); lock.unlock() }
        client.start()
        client.start()
        drain(queue)
        XCTAssertEqual(client.status, .notInstalled, "no installer information: the extension may simply not be activated yet")
        XCTAssertFalse(client.isConnected)
        // Let a few retries run (0.2 s interval) without the device.
        let waited = expectation(description: "retries")
        queue.asyncAfter(deadline: .now() + 0.7) { waited.fulfill() }
        wait(for: [waited], timeout: 5)
        XCTAssertFalse(client.isConnected)
        client.stop()
        drain(queue)
        XCTAssertEqual(client.status, .notInstalled)
        lock.lock()
        XCTAssertTrue(statuses.isEmpty, "the status never changed, so nothing was reported: \(statuses)")
        lock.unlock()
    }

    func testInstallerStatusesDriveTheSinkStatusWhileSearching() {
        let queue = DispatchQueue(label: "camera-tests.sink")
        let client = makeClient(queue: queue)
        client.notFoundFollowUpDelay = 3600
        var statuses: [SinkStatus] = []
        let lock = NSLock()
        client.onStatusChange = { status in lock.lock(); statuses.append(status); lock.unlock() }

        client.noteExtensionStatus(.needsApproval)
        drain(queue)
        XCTAssertEqual(client.status, .awaitingApproval)

        client.noteExtensionStatus(.needsReboot)
        drain(queue)
        XCTAssertEqual(client.status, .error(.extensionNeedsReboot, FailureText.logLine(.extensionNeedsReboot)))
        XCTAssertEqual(CMIOSinkClient.sentence(for: client.status), "Restart your Mac once to finish installing Daylight Camera.", "the detail never reaches the owner for a row without a placeholder")

        client.noteExtensionStatus(.notInApplications)
        drain(queue)
        XCTAssertEqual(client.status, .error(.notInApplications, Bundle.main.bundlePath))

        client.noteExtensionStatus(.unsignedBuild)
        drain(queue)
        XCTAssertEqual(client.status, .error(.unsignedBuild, FailureText.logLine(.unsignedBuild)))

        client.noteExtensionStatus(.failed(.codeSignatureInvalid, "not notarized"))
        drain(queue)
        XCTAssertEqual(client.status, .error(.extensionSignatureInvalid, "not notarized"))

        client.noteExtensionStatus(.failed(.requestSuperseded, "superseded"))
        drain(queue)
        XCTAssertEqual(client.status, .error(.extensionDamaged, "superseded"), "an unmapped code falls back to row 8 with the message kept")

        client.noteExtensionStatus(.activating)
        drain(queue)
        XCTAssertEqual(client.status, .notInstalled)

        client.noteExtensionStatus(.installed)
        drain(queue)
        XCTAssertEqual(client.status, .error(.sinkDeviceNotFound, CMIOSinkClientTests.deviceUUID.uuidString), "row 13: installed but not found")
        XCTAssertEqual(CMIOSinkClient.sentence(for: client.status), "Daylight Camera is installed but not found yet. Retrying...")

        lock.lock()
        XCTAssertEqual(statuses.count, 8, "one report per distinct status: \(statuses)")
        lock.unlock()
    }

    func testRow13GainsItsSecondSentenceAfterTheFollowUpDelay() {
        let queue = DispatchQueue(label: "camera-tests.sink")
        let client = makeClient(queue: queue)
        client.notFoundFollowUpDelay = 0.3
        client.noteExtensionStatus(.installed)
        client.start()
        drain(queue)
        XCTAssertEqual(client.status, .error(.sinkDeviceNotFound, CMIOSinkClientTests.deviceUUID.uuidString))
        let waited = expectation(description: "follow-up")
        queue.asyncAfter(deadline: .now() + 0.8) { waited.fulfill() }
        wait(for: [waited], timeout: 5)
        XCTAssertEqual(client.status, .error(.sinkDeviceNotFound, "Open Zoom or FaceTime once, or restart your Mac."))
        XCTAssertEqual(CMIOSinkClient.sentence(for: client.status), "Daylight Camera is installed but not found yet. Retrying... Open Zoom or FaceTime once, or restart your Mac.")
        client.stop()
        drain(queue)
    }

    func testSentencesForTheNonErrorStatuses() {
        XCTAssertNil(CMIOSinkClient.sentence(for: .notInstalled))
        XCTAssertNil(CMIOSinkClient.sentence(for: .awaitingApproval))
        XCTAssertNil(CMIOSinkClient.sentence(for: .installed))
        XCTAssertNil(CMIOSinkClient.sentence(for: .connected))
        XCTAssertEqual(CMIOSinkClient.sentence(for: .error(.sinkStreamLayout, "streams=[1] directions=[?]")), "Daylight Camera has an unexpected stream layout.")
    }
}
