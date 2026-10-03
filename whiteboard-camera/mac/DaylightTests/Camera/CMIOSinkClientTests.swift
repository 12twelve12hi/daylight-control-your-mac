import CoreMedia
import DaylightKit
import XCTest
@testable import Daylight

/// The host sink client without a Daylight Camera on the machine: every status path short of `.connected`, pushes
/// never block and report drops, the installer feed drives rows 12, 12b and 13, pushes from several threads are
/// serialised on a real `CMSimpleQueue`, and a connection whose device vanished is dropped by the re-validation timer.
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

    /// An expectation fulfilled by the status change itself (CAMB-03: the follow-up lands on a 0.2 s tick with 0.2 s
    /// leeway after a CMIO device walk, which a shared runner can delay past any fixed window).
    private func expectStatus(_ client: CMIOSinkClient, _ wanted: SinkStatus, _ description: String) -> XCTestExpectation {
        let reached = expectation(description: description)
        reached.assertForOverFulfill = false
        client.onStatusChange = { status in
            if status == wanted { reached.fulfill() }
        }
        return reached
    }

    func testRow13GainsItsSecondSentenceAfterTheFollowUpDelay() {
        let queue = DispatchQueue(label: "camera-tests.sink")
        let client = makeClient(queue: queue)
        client.notFoundFollowUpDelay = 0.3
        let followUp = expectStatus(client, .error(.sinkDeviceNotFound, "Open Zoom or FaceTime once, or restart your Mac."), "row 13 follow-up")
        client.noteExtensionStatus(.installed)
        client.start()
        drain(queue)
        XCTAssertEqual(client.status, .error(.sinkDeviceNotFound, CMIOSinkClientTests.deviceUUID.uuidString))
        wait(for: [followUp], timeout: 10)
        XCTAssertEqual(client.status, .error(.sinkDeviceNotFound, "Open Zoom or FaceTime once, or restart your Mac."))
        XCTAssertEqual(CMIOSinkClient.sentence(for: client.status), "Daylight Camera is installed but not found yet. Retrying... Open Zoom or FaceTime once, or restart your Mac.")
        XCTAssertTrue(CMIOSinkClient.followUpDue(client.status))
        client.stop()
        drain(queue)
    }

    /// CAMA-01: the 30 s of row 13 count time without the device, not time since the installer said installed. After
    /// a connect, losing the device starts with the first sentence again (the UUID detail), not the follow-up.
    func testRow13ClockRestartsWhenTheDeviceIsLostAfterAConnect() throws {
        let queue = DispatchQueue(label: "camera-tests.sink")
        let client = makeClient(queue: queue)
        client.notFoundFollowUpDelay = 0.3
        let followUp = expectStatus(client, .error(.sinkDeviceNotFound, "Open Zoom or FaceTime once, or restart your Mac."), "row 13 follow-up")
        client.noteExtensionStatus(.installed)
        client.start()
        wait(for: [followUp], timeout: 10)

        // Connect, then lose the device: the extension status re-validates, the unknown device is not located, the
        // connection is dropped as stale and the sink searches again.
        var afterConnect: [SinkStatus] = []
        let lock = NSLock()
        let searching = expectation(description: "searching again after the connect")
        searching.assertForOverFulfill = false
        let holder = try QueueSink(capacity: 1)
        queue.sync {
            client.onStatusChange = { status in
                lock.lock()
                afterConnect.append(status)
                lock.unlock()
                if case .error(.sinkDeviceNotFound, _) = status { searching.fulfill() }
            }
            client.adoptQueueForTesting(holder.queue)
        }
        client.noteExtensionStatus(.installed)
        wait(for: [searching], timeout: 10)
        lock.lock()
        let firstNotFound = afterConnect.first { if case .error = $0 { return true } else { return false } }
        lock.unlock()
        XCTAssertEqual(firstNotFound, .error(.sinkDeviceNotFound, CMIOSinkClientTests.deviceUUID.uuidString), "a fresh outage starts with the first sentence: \(afterConnect)")
        client.stop()
        drain(queue)
    }

    /// CAMA-01: the menu status line (and Diagnostics, which copies it) shows both sentences of row 13 after 30 s.
    func testMenuStatusLineShowsRow13FollowUp() throws {
        let suite = "camera-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settingsStore: SettingsStore(defaults: defaults), signed: true, version: "0", build: "0")
        model.setSinkStatus(.error(.sinkDeviceNotFound, CMIOSinkClientTests.deviceUUID.uuidString))
        XCTAssertEqual(model.sinkStatusText, "Daylight Camera is installed but not found yet. Retrying...")
        model.setSinkStatus(.error(.sinkDeviceNotFound, try XCTUnwrap(FailureText.followUp(.sinkDeviceNotFound))))
        XCTAssertEqual(model.sinkStatusText, "Daylight Camera is installed but not found yet. Retrying... Open Zoom or FaceTime once, or restart your Mac.")
    }

    /// CAMA-01: the onboarding camera row gains the second sentence too.
    func testOnboardingRowShowsRow13FollowUp() {
        var inputs = OnboardingSteps.Inputs(bundlePath: "/Applications/Daylight.app", signed: true)
        inputs.extensionState = .installed
        XCTAssertEqual(OnboardingSteps.extensionRow(inputs, misplaced: false).detail, "Daylight Camera is installed but not found yet. Retrying...")
        inputs.sinkFollowUpDue = CMIOSinkClient.followUpDue(.error(.sinkDeviceNotFound, "Open Zoom or FaceTime once, or restart your Mac."))
        XCTAssertTrue(inputs.sinkFollowUpDue)
        XCTAssertEqual(OnboardingSteps.extensionRow(inputs, misplaced: false).detail, "Daylight Camera is installed but not found yet. Retrying... Open Zoom or FaceTime once, or restart your Mac.")
        XCTAssertFalse(CMIOSinkClient.followUpDue(.error(.sinkDeviceNotFound, CMIOSinkClientTests.deviceUUID.uuidString)))
        XCTAssertFalse(CMIOSinkClient.followUpDue(.connected))
    }

    /// CAMB-02: Quit stops the sink stream before the process exits; `stop()` alone is asynchronous.
    func testStopAndWaitStopsSynchronously() throws {
        let queue = DispatchQueue(label: "camera-tests.sink")
        let client = makeClient(queue: queue)
        client.start()
        drain(queue)
        let holder = try QueueSink(capacity: 1)
        queue.sync { client.adoptQueueForTesting(holder.queue) }
        XCTAssertTrue(client.isConnected)
        XCTAssertTrue(client.stopAndWait(timeout: 10))
        XCTAssertFalse(client.isConnected, "stopped before stopAndWait returned, with no drain")
        XCTAssertEqual(client.status, .notInstalled)
    }

    /// CAMB-02: a camera queue that does not answer cannot hang Quit; the wait gives up after its timeout.
    func testStopAndWaitIsBoundedByItsTimeout() {
        let queue = DispatchQueue(label: "camera-tests.sink")
        let client = makeClient(queue: queue)
        let release = DispatchSemaphore(value: 0)
        queue.async { _ = release.wait(timeout: .now() + 30) }
        let started = Date()
        XCTAssertFalse(client.stopAndWait(timeout: 0.2), "the queue is blocked, so the stop cannot finish")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "returned at about the timeout")
        release.signal()
        drain(queue)
    }

    func testStalenessRuleComparesDeviceAndSinkStreamIds() {
        XCTAssertFalse(CMIOSinkClient.connectionIsStale(device: 7, sinkStream: 42, located: (device: 7, streams: [41, 42])), "same device, same sink stream")
        XCTAssertTrue(CMIOSinkClient.connectionIsStale(device: 7, sinkStream: 42, located: nil), "device gone")
        XCTAssertTrue(CMIOSinkClient.connectionIsStale(device: 7, sinkStream: 42, located: (device: 9, streams: [41, 42])), "a replaced extension has a new device id")
        XCTAssertTrue(CMIOSinkClient.connectionIsStale(device: 7, sinkStream: 42, located: (device: 7, streams: [51, 52])), "same device id, new streams")
        XCTAssertTrue(CMIOSinkClient.connectionIsStale(device: 7, sinkStream: 42, located: (device: 7, streams: [41])), "the sink stream disappeared (row 14 layout)")
        XCTAssertEqual(CMIOSinkClient.staleDropThreshold, 60, "about 2 s at 30 fps before the stale-queue notice")
        XCTAssertFalse(CMIOSinkClient.dropsLookStale(consecutiveDrops: 1000, viewers: 0), "nobody watching: drops are expected")
        XCTAssertFalse(CMIOSinkClient.dropsLookStale(consecutiveDrops: 59, viewers: 1))
        XCTAssertTrue(CMIOSinkClient.dropsLookStale(consecutiveDrops: 60, viewers: 1))
    }

    /// Finding 03: `CMSimpleQueue.h` allows one enqueueing thread; the pipeline pushes from the capture queue, the Metal
    /// completion thread and the render queue at once. Four producers against a capacity-1 queue with one consumer:
    /// every push is either enqueued or counted as dropped, and the consumer sees exactly the enqueued ones.
    func testConcurrentPushesAreSerialisedOnTheSinkQueue() throws {
        let client = makeClient(queue: DispatchQueue(label: "camera-tests.sink"))
        let holder = try QueueSink(capacity: 1)
        client.adoptQueueForTesting(holder.queue)
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(client.status, .connected)
        XCTAssertEqual(client.queueCountAndCapacity?.capacity, 1)
        let feeder = SinkFeeder(sink: client)
        let buffer = try XCTUnwrap(CameraTestBuffers.make(width: 64, height: 36))
        let producers = 4
        let perProducer = 2000
        let group = DispatchGroup()
        let dequeued = Locked<Int>(0)
        let stopConsumer = Locked<Bool>(false)
        let consumer = Thread {
            while !stopConsumer.withLock({ $0 }) {
                if holder.dequeue() != nil { dequeued.withLock { $0 += 1 } }
            }
            while holder.dequeue() != nil { dequeued.withLock { $0 += 1 } }
        }
        consumer.start()
        for index in 0..<producers {
            group.enter()
            DispatchQueue.global(qos: index % 2 == 0 ? .userInteractive : .userInitiated).async {
                for _ in 0..<perProducer { feeder.push(buffer, hostTimeNs: nil) }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        stopConsumer.withLock { $0 = true }
        while !consumer.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        let total = UInt64(producers * perProducer)
        XCTAssertEqual(client.enqueuedFrames + client.droppedFrames, total, "every push is counted once")
        XCTAssertEqual(feeder.pushedFrames + feeder.droppedFrames, total)
        XCTAssertEqual(feeder.pushedFrames, client.enqueuedFrames)
        XCTAssertGreaterThan(client.enqueuedFrames, 0)
        XCTAssertEqual(UInt64(dequeued.withLock { $0 }), client.enqueuedFrames, "the consumer took exactly the enqueued elements: nothing lost, nothing duplicated")
        XCTAssertEqual(holder.count, 0)
        client.stop()
        drain(client.queue)
        XCTAssertFalse(client.isConnected)
        XCTAssertEqual(client.status, .notInstalled)
        XCTAssertFalse(client.push(try XCTUnwrap(feeder.makeSampleBuffer(buffer, hostTimeNs: nil))), "after stop every push drops")
    }

    /// Finding 02: a connection whose device is no longer located is dropped by the running re-validation timer and
    /// the sink goes back to searching (`.connected` to `.installed` to `.notInstalled` here, because no Daylight Camera
    /// exists on the runner), instead of staying `.connected` with a queue nobody drains.
    func testStaleConnectionIsDroppedByTheRunningTimer() throws {
        let queue = DispatchQueue(label: "camera-tests.sink")
        let client = makeClient(queue: queue)
        var statuses: [SinkStatus] = []
        let lock = NSLock()
        // Fulfilled by the status change itself (delivered on `queue`), not by a fixed window: the re-validation tick
        // has a 0.2 s interval with 0.2 s leeway and walks the CMIO devices, which the shared runner can slow down.
        let searchingAgain = expectation(description: "the running timer drops the stale connection and searches again")
        searchingAgain.assertForOverFulfill = false
        var sawConnected = false
        client.onStatusChange = { status in
            lock.lock()
            statuses.append(status)
            if status == .connected { sawConnected = true }
            let done = sawConnected && status == .notInstalled
            lock.unlock()
            if done { searchingAgain.fulfill() }
        }
        client.start()
        drain(queue)
        let holder = try QueueSink(capacity: 1)
        let feeder = SinkFeeder(sink: client)
        let buffer = try XCTUnwrap(CameraTestBuffers.make(width: 64, height: 36))
        // Adopt and push inside one block on `queue`: the re-validation timer runs on that queue too, so it cannot drop
        // the adopted connection between these steps (run 37131914413 saw it fire inside the 0.2 s window).
        queue.sync {
            client.adoptQueueForTesting(holder.queue)
            XCTAssertTrue(client.isConnected)
            XCTAssertTrue(feeder.push(buffer, hostTimeNs: nil), "the adopted queue accepts one frame")
            XCTAssertFalse(feeder.push(buffer, hostTimeNs: nil), "nobody drains it: the second push drops")
            XCTAssertEqual(client.consecutiveDroppedFrames, 1)
        }
        wait(for: [searchingAgain], timeout: 10)
        drain(queue)
        XCTAssertFalse(client.isConnected, "the device is not located on this Mac, so the adopted connection is stale")
        XCTAssertEqual(client.status, .notInstalled)
        lock.lock()
        XCTAssertEqual(statuses, [.connected, .installed, .notInstalled], "connected, dropped as stale, searching again: \(statuses)")
        lock.unlock()
        XCTAssertNotNil(holder.dequeue(), "the frame pushed before the drop is still in the old queue (the extension would have consumed it)")
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
