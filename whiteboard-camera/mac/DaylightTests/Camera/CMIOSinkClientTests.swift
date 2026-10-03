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
        client.onStatusChange = { status in lock.lock(); statuses.append(status); lock.unlock() }
        client.start()
        drain(queue)
        let holder = try QueueSink(capacity: 1)
        let adopted = expectation(description: "adopted")
        queue.async { client.adoptQueueForTesting(holder.queue); adopted.fulfill() }
        wait(for: [adopted], timeout: 5)
        XCTAssertTrue(client.isConnected)
        let feeder = SinkFeeder(sink: client)
        let buffer = try XCTUnwrap(CameraTestBuffers.make(width: 64, height: 36))
        XCTAssertTrue(feeder.push(buffer, hostTimeNs: nil), "the adopted queue accepts one frame")
        XCTAssertFalse(feeder.push(buffer, hostTimeNs: nil), "nobody drains it: the second push drops")
        XCTAssertEqual(client.consecutiveDroppedFrames, 1)
        let waited = expectation(description: "a revalidation tick (0.2 s interval)")
        queue.asyncAfter(deadline: .now() + 0.7) { waited.fulfill() }
        wait(for: [waited], timeout: 5)
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
