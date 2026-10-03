import AVFoundation
import CoreMedia
import CoreMediaIO
import DaylightKit
import Foundation
import os

/// The host side of the sink stream (ARCHITECTURE 2.3, research-cmio-signing 2.3): locate the Daylight Camera device
/// by UUID, `CMIOStreamCopyBufferQueue` on its sink stream, `CMIODeviceStartStream`, then `CMSimpleQueueEnqueue` each
/// frame when the queue has room (drop otherwise, never block). Retries every 2 s until connected, and at once on
/// `AVCaptureDevice.wasConnectedNotification`. Status maps onto `SinkStatus`; the extension installer's status can be
/// fed in so row 13 (installed but not found) fires only when the extension really is installed.
///
/// While connected the same 2 s timer, both AVCaptureDevice connect and disconnect notifications and every installer
/// status change re-validate the connection: when the located device or sink stream id differs from the one the queue
/// was copied from (the extension was replaced by an app update, crashed and relaunched, or was removed) the stale
/// queue is dropped and the sink reconnects, instead of enqueuing into a queue nobody drains while reporting connected.
///
/// `push` serialises its producers: `CMSimpleQueue.h` allows one enqueueing thread, and the pipeline pushes from the
/// capture queue (passthrough), the Metal completion thread (composed frames) and the render queue (cached frame or
/// cream card at capture start), which overlap at every engage or return transition and every capture start.
final class CMIOSinkClient: VirtualCameraSink {
    static let log = Logger(subsystem: "com.twelve.daylight", category: "camera")
    static let retryInterval: Double = 2
    /// SPEC row 13: after this long without the device the second sentence is appended.
    static let notFoundFollowUpDelay: Double = 30
    /// Consecutive dropped pushes while connected (about 2 s at 30 fps) before the stale-queue notice is logged.
    static let staleDropThreshold: UInt64 = 60

    let deviceUUID: UUID
    let sinkUUID: UUID
    let queue: DispatchQueue
    let locator: CMIODeviceLocator
    let viewers: ViewerWatcher

    var onStatusChange: ((SinkStatus) -> Void)?
    var onQueueAltered: (() -> Void)?
    var onViewerCount: ((Int) -> Void)?

    private struct Connection {
        let device: CMIODeviceID
        let sinkStream: CMIOStreamID
        let sourceStream: CMIOStreamID?
        let queue: CMSimpleQueue
    }

    private let statusBox = Locked<SinkStatus>(.notInstalled)
    private let connection = Locked<Connection?>(nil)
    /// Held from the capacity check through `CMSimpleQueueEnqueue` (and while `disconnect` swaps the connection), so
    /// the single-enqueuer contract of `CMSimpleQueue.h` holds whatever thread calls `push`. Never waits on the
    /// extension: the critical section is a count read and one enqueue.
    private let pushLock = NSLock()
    private let counters = Locked<(enqueued: UInt64, dropped: UInt64, altered: UInt64, consecutiveDrops: UInt64)>((0, 0, 0, 0))
    private var retryTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var loggedStaleDrops = false
    private var running = false
    private var extensionStatus: ExtensionInstaller.Status = .unknown
    private var installedSince: Double?
    private var loggedNotFound = false
    private var loggedLayout = false
    /// Tests shorten these.
    var retryInterval: Double = CMIOSinkClient.retryInterval
    var notFoundFollowUpDelay: Double = CMIOSinkClient.notFoundFollowUpDelay

    init(deviceUUID: UUID, sinkUUID: UUID, queue: DispatchQueue) {
        self.deviceUUID = deviceUUID
        self.sinkUUID = sinkUUID
        self.queue = queue
        locator = CMIODeviceLocator(deviceUUID: deviceUUID)
        viewers = ViewerWatcher(locator: locator, queue: queue)
        viewers.onViewerCount = { [weak self] count in self?.onViewerCount?(count) }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var status: SinkStatus { return statusBox.withLock { $0 } }
    var isConnected: Bool { return connection.withLock { $0 != nil } }
    var viewerCount: Int { return viewers.viewerCount }
    var enqueuedFrames: UInt64 { return counters.withLock { $0.enqueued } }
    var droppedFrames: UInt64 { return counters.withLock { $0.dropped } }
    var queueAlteredCount: UInt64 { return counters.withLock { $0.altered } }
    /// Drops since the last successful enqueue (reset by every enqueue and every connect).
    var consecutiveDroppedFrames: UInt64 { return counters.withLock { $0.consecutiveDrops } }

    /// Diagnostics (SPEC 13.2): sink queue count and capacity, or nil while not connected.
    var queueCountAndCapacity: (count: Int, capacity: Int)? {
        guard let q = connection.withLock({ $0?.queue }) else { return nil }
        return (Int(CMSimpleQueueGetCount(q)), Int(CMSimpleQueueGetCapacity(q)))
    }

    // MARK: VirtualCameraSink

    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.running else { return }
            self.running = true
            let center = NotificationCenter.default
            // Both notifications funnel into `revalidate()`: connect so a fresh extension is picked up at once,
            // disconnect so a replaced or relaunched extension drops the stale queue (camera review finding 02).
            let names: [(Notification.Name, String)] = [(.AVCaptureDeviceWasConnected, "wasConnected"), (.AVCaptureDeviceWasDisconnected, "wasDisconnected")]
            for (name, label) in names {
                self.observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                    guard let self = self else { return }
                    let device = (note.object as? AVCaptureDevice)?.localizedName ?? "?"
                    CMIOSinkClient.log.info("AVCaptureDevice.\(label, privacy: .public)Notification \(device, privacy: .public); re-validating the sink")
                    self.queue.async { self.revalidate() }
                })
            }
            self.viewers.start()
            self.attempt()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.running = false
            self.retryTimer?.cancel()
            self.retryTimer = nil
            for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
            self.observers.removeAll()
            self.viewers.stop()
            self.disconnect()
        }
    }

    @discardableResult
    func push(_ sampleBuffer: CMSampleBuffer) -> Bool {
        pushLock.lock()
        defer { pushLock.unlock() }
        guard let q = connection.withLock({ $0?.queue }) else {
            counters.withLock { $0.dropped += 1 }
            return false
        }
        let ok = CMIOSinkClient.enqueue(sampleBuffer, into: q)
        counters.withLock {
            if ok {
                $0.enqueued += 1
                $0.consecutiveDrops = 0
            } else {
                $0.dropped += 1
                $0.consecutiveDrops += 1
            }
        }
        return ok
    }

    /// The enqueue rule alone (SPEC C4): only when `count < capacity`, the element retained for the consumer, released
    /// again when `CMSimpleQueueEnqueue` refuses it. The caller serialises enqueuers.
    static func enqueue(_ sampleBuffer: CMSampleBuffer, into q: CMSimpleQueue) -> Bool {
        guard CMSimpleQueueGetCount(q) < CMSimpleQueueGetCapacity(q) else { return false }
        let element = UnsafeMutableRawPointer(Unmanaged.passRetained(sampleBuffer).toOpaque())
        let status = CMSimpleQueueEnqueue(q, element: element)
        if status != noErr {
            Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
            return false
        }
        return true
    }

    /// The installer's view of the extension, so the status is right before the device appears (row 12, 12b, 13).
    /// While connected it re-validates instead: an `.installed` after a replacement, or a `.notInstalled` after a
    /// deactivation, is the moment the old extension's queue died.
    func noteExtensionStatus(_ status: ExtensionInstaller.Status) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.extensionStatus = status
            switch status {
            case .installed:
                if self.installedSince == nil { self.installedSince = ProcessInfo.processInfo.systemUptime }
            case .notInstalled, .unknown:
                // The extension was removed (deactivation completed): a later activation starts its own 30 s.
                self.installedSince = nil
                self.loggedNotFound = false
            default:
                break
            }
            if self.isConnected {
                self.revalidate()
                return
            }
            self.publishSearchingStatus()
            if self.running { self.attempt() }
        }
    }

    /// Pure rule behind `revalidate()`: the connection is stale when the device is gone or the located device or sink
    /// stream id differs from the one the queue was copied from (a replaced or relaunched extension gets new ids).
    static func connectionIsStale(device: CMIODeviceID, sinkStream: CMIOStreamID, located: (device: CMIODeviceID, streams: [CMIOStreamID])?) -> Bool {
        guard let found = located else { return true }
        guard found.device == device else { return true }
        guard let sinkIndex = CMIODeviceLocator.sinkStreamIndex(streamCount: found.streams.count, directions: []) else { return true }
        return found.streams[sinkIndex] != sinkStream
    }

    /// Pure rule for the first-run log: drops piling up while connected and somebody is watching means nobody drains
    /// the queue (the extension consumes at 90 Hz when it is alive).
    static func dropsLookStale(consecutiveDrops: UInt64, viewers: Int) -> Bool {
        return viewers > 0 && consecutiveDrops >= CMIOSinkClient.staleDropThreshold
    }

    // MARK: Connection (all on `queue`)

    /// Not connected: one attempt. Connected: one locate; a stale connection is dropped and reconnected at once.
    private func revalidate() {
        guard running else { return }
        guard let active = connection.withLock({ $0 }) else {
            attempt()
            return
        }
        let located = locator.locate().map { (device: $0.device, streams: $0.streams) }
        if CMIOSinkClient.connectionIsStale(device: active.device, sinkStream: active.sinkStream, located: located) {
            let now = located.map { "device=\($0.device) streams=\(String(describing: $0.streams))" } ?? "no device"
            CMIOSinkClient.log.notice("sink connection to device=\(active.device) sink=\(active.sinkStream) is stale (\(now, privacy: .public)); reconnecting")
            disconnect()
            attempt()
            return
        }
        let drops = consecutiveDroppedFrames
        if !loggedStaleDrops, CMIOSinkClient.dropsLookStale(consecutiveDrops: drops, viewers: viewerCount) {
            loggedStaleDrops = true
            CMIOSinkClient.log.notice("sink connected but \(drops) pushes in a row were dropped with viewers=\(self.viewerCount); the extension is not draining its queue (quit and reopen Daylight if the viewer shows the card)")
        }
    }

    private func attempt() {
        guard running, !isConnected else { return }
        defer { scheduleRetry() }
        guard let found = locator.locate() else {
            publishSearchingStatus()
            return
        }
        let layout = CMIODeviceLocator.layoutDescription(streams: found.streams, directions: found.directions)
        guard let sinkIndex = CMIODeviceLocator.sinkStreamIndex(streamCount: found.streams.count, directions: found.directions) else {
            if !loggedLayout {
                loggedLayout = true
                CMIOSinkClient.log.error("\(FailureText.logLine(.sinkStreamLayout, [layout.ids, layout.directions]), privacy: .public)")
            }
            setStatus(.error(.sinkStreamLayout, "streams=\(layout.ids) directions=\(layout.directions)"))
            return
        }
        if CMIODeviceLocator.directionsLookUnexpected(found.directions) {
            CMIOSinkClient.log.notice("stream directions \(layout.directions, privacy: .public) differ from the expected [1, 0]; index 1 is used as the sink (LOOSE_ENDS E2)")
        }
        let sinkStream = found.streams[sinkIndex]
        let sourceStream = CMIODeviceLocator.sourceStreamIndex(streamCount: found.streams.count).map { found.streams[$0] }

        var queuePointer: Unmanaged<CMSimpleQueue>? = nil
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let copyStatus = CMIOStreamCopyBufferQueue(sinkStream, { _, _, refcon in
            guard let refcon = refcon else { return }
            Unmanaged<CMIOSinkClient>.fromOpaque(refcon).takeUnretainedValue().queueAltered()
        }, refcon, &queuePointer)
        guard copyStatus == noErr, let unmanagedQueue = queuePointer else {
            CMIOSinkClient.log.error("CMIOStreamCopyBufferQueue failed: \(copyStatus)")
            setStatus(.installed)
            return
        }
        // ldenoue takes the queue unretained and ships; a possible one-time over-retain beats an over-release
        // (STATUS.md section 3, LOOSE_ENDS E28: the convention is settled on the owner's first signed run).
        let simpleQueue = unmanagedQueue.takeUnretainedValue()
        let startStatus = CMIODeviceStartStream(found.device, sinkStream)
        guard startStatus == noErr else {
            CMIOSinkClient.log.error("CMIODeviceStartStream failed: \(startStatus)")
            // Leave nothing registered behind a failed start: the proc was registered with an unretained refcon and
            // the next retry copies the queue again (the same NULL-proc call `disconnect()` makes).
            var unused: Unmanaged<CMSimpleQueue>? = nil
            _ = CMIOStreamCopyBufferQueue(sinkStream, nil, nil, &unused)
            setStatus(.installed)
            return
        }
        connection.withLock { $0 = Connection(device: found.device, sinkStream: sinkStream, sourceStream: sourceStream, queue: simpleQueue) }
        counters.withLock { $0.consecutiveDrops = 0 }
        loggedStaleDrops = false
        viewers.setSourceStream(sourceStream)
        CMIOSinkClient.log.info("sink connected: device=\(found.device) sink=\(sinkStream) capacity=\(CMSimpleQueueGetCapacity(simpleQueue)) directions=\(layout.directions, privacy: .public)")
        setStatus(.connected)
    }

    private func disconnect() {
        // Under `pushLock` so a push in flight finishes its enqueue before the queue goes away.
        pushLock.lock()
        let old = connection.withLock { current -> Connection? in
            let value = current
            current = nil
            return value
        }
        pushLock.unlock()
        guard let active = old else { return }
        if active.device != CMIODeviceID(kCMIOObjectUnknown) {
            let status = CMIODeviceStopStream(active.device, active.sinkStream)
            // Unregister the queue-altered callback (the header: pass NULL as the proc).
            var unused: Unmanaged<CMSimpleQueue>? = nil
            _ = CMIOStreamCopyBufferQueue(active.sinkStream, nil, nil, &unused)
            CMIOSinkClient.log.info("sink stopped: \(status)")
        }
        viewers.setSourceStream(nil)
        setStatus(running ? .installed : .notInstalled)
    }

    /// The 2 s timer runs for the life of `start()`: attempts while searching, re-validates while connected (one
    /// locate per tick, which also catches an extension crash when no AVFoundation notification fires).
    private func scheduleRetry() {
        guard running else {
            retryTimer?.cancel()
            retryTimer = nil
            return
        }
        if retryTimer != nil { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + retryInterval, repeating: retryInterval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if !self.running {
                self.retryTimer?.cancel()
                self.retryTimer = nil
                return
            }
            self.revalidate()
        }
        retryTimer = timer
        timer.resume()
    }

    #if DEBUG
    /// Tests only: adopt a `CMSimpleQueue` as if the sink stream had been copied, so `push` runs against a real queue
    /// without a Daylight Camera on the machine. `disconnect()` skips the CMIO calls for this unknown device id.
    func adoptQueueForTesting(_ q: CMSimpleQueue) {
        connection.withLock { $0 = Connection(device: CMIODeviceID(kCMIOObjectUnknown), sinkStream: 0, sourceStream: nil, queue: q) }
        setStatus(.connected)
    }
    #endif

    /// Status while the device is not located, derived from what the installer said.
    private func publishSearchingStatus() {
        switch extensionStatus {
        case .unsignedBuild:
            setStatus(.error(.unsignedBuild, FailureText.logLine(.unsignedBuild)))
        case .notInApplications:
            setStatus(.error(.notInApplications, Bundle.main.bundlePath))
        case .needsApproval:
            setStatus(.awaitingApproval)
        case .needsReboot:
            setStatus(.error(.extensionNeedsReboot, FailureText.logLine(.extensionNeedsReboot)))
        case let .failed(code, message):
            setStatus(.error(ExtensionInstaller.failureCase(for: code) ?? .extensionDamaged, message))
        case .installed:
            let uuid = deviceUUID.uuidString
            if !loggedNotFound {
                loggedNotFound = true
                CMIOSinkClient.log.error("\(FailureText.logLine(.sinkDeviceNotFound, [uuid, self.locator.deviceUIDs().description]), privacy: .public)")
            }
            var detail = uuid
            if let since = installedSince, ProcessInfo.processInfo.systemUptime - since >= notFoundFollowUpDelay, let followUp = FailureText.followUp(.sinkDeviceNotFound) {
                detail = followUp
            }
            setStatus(.error(.sinkDeviceNotFound, detail))
        case .activating:
            setStatus(.notInstalled)
        case .unknown, .notInstalled:
            setStatus(.notInstalled)
        }
    }

    /// Owner-facing sentence for the current status (row 13 gains its second sentence after 30 s).
    static func sentence(for status: SinkStatus) -> String? {
        switch status {
        case let .error(failure, detail):
            if failure == .sinkDeviceNotFound, let followUp = FailureText.followUp(.sinkDeviceNotFound), detail == followUp {
                return FailureText.sentence(failure) + " " + followUp
            }
            return FailureText.sentence(failure)
        case .notInstalled, .awaitingApproval, .installed, .connected:
            return nil
        }
    }

    private func setStatus(_ new: SinkStatus) {
        let changed = statusBox.withLock { current -> Bool in
            if current == new { return false }
            current = new
            return true
        }
        if changed {
            CMIOSinkClient.log.info("sink status \(String(describing: new), privacy: .public)")
            onStatusChange?(new)
        }
    }

    private func queueAltered() {
        counters.withLock { $0.altered += 1 }
        onQueueAltered?()
    }
}
