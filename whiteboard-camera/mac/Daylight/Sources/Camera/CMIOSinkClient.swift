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
final class CMIOSinkClient: VirtualCameraSink {
    static let log = Logger(subsystem: "com.twelve.daylight", category: "camera")
    static let retryInterval: Double = 2
    /// SPEC row 13: after this long without the device the second sentence is appended.
    static let notFoundFollowUpDelay: Double = 30

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
    private let counters = Locked<(enqueued: UInt64, dropped: UInt64, altered: UInt64)>((0, 0, 0))
    private var retryTimer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
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
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    var status: SinkStatus { return statusBox.withLock { $0 } }
    var isConnected: Bool { return connection.withLock { $0 != nil } }
    var viewerCount: Int { return viewers.viewerCount }
    var enqueuedFrames: UInt64 { return counters.withLock { $0.enqueued } }
    var droppedFrames: UInt64 { return counters.withLock { $0.dropped } }
    var queueAlteredCount: UInt64 { return counters.withLock { $0.altered } }

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
            self.observer = NotificationCenter.default.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: nil) { [weak self] note in
                guard let self = self else { return }
                let name = (note.object as? AVCaptureDevice)?.localizedName ?? "?"
                CMIOSinkClient.log.info("AVCaptureDevice.wasConnectedNotification \(name, privacy: .public); retrying the sink")
                self.queue.async { self.attempt() }
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
            if let observer = self.observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            self.viewers.stop()
            self.disconnect()
        }
    }

    @discardableResult
    func push(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let q = connection.withLock({ $0?.queue }) else {
            counters.withLock { $0.dropped += 1 }
            return false
        }
        guard CMSimpleQueueGetCount(q) < CMSimpleQueueGetCapacity(q) else {
            counters.withLock { $0.dropped += 1 }
            return false
        }
        let element = UnsafeMutableRawPointer(Unmanaged.passRetained(sampleBuffer).toOpaque())
        let status = CMSimpleQueueEnqueue(q, element: element)
        if status != noErr {
            Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
            counters.withLock { $0.dropped += 1 }
            return false
        }
        counters.withLock { $0.enqueued += 1 }
        return true
    }

    /// The installer's view of the extension, so the status is right before the device appears (row 12, 12b, 13).
    func noteExtensionStatus(_ status: ExtensionInstaller.Status) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.extensionStatus = status
            if case .installed = status, self.installedSince == nil {
                self.installedSince = ProcessInfo.processInfo.systemUptime
            }
            if self.isConnected { return }
            self.publishSearchingStatus()
            if self.running { self.attempt() }
        }
    }

    // MARK: Connection (all on `queue`)

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
        // ldenoue takes the queue unretained and ships; a possible one-time over-retain beats an over-release.
        let simpleQueue = unmanagedQueue.takeUnretainedValue()
        let startStatus = CMIODeviceStartStream(found.device, sinkStream)
        guard startStatus == noErr else {
            CMIOSinkClient.log.error("CMIODeviceStartStream failed: \(startStatus)")
            setStatus(.installed)
            return
        }
        connection.withLock { $0 = Connection(device: found.device, sinkStream: sinkStream, sourceStream: sourceStream, queue: simpleQueue) }
        viewers.setSourceStream(sourceStream)
        CMIOSinkClient.log.info("sink connected: device=\(found.device) sink=\(sinkStream) capacity=\(CMSimpleQueueGetCapacity(simpleQueue)) directions=\(layout.directions, privacy: .public)")
        setStatus(.connected)
    }

    private func disconnect() {
        let old = connection.withLock { current -> Connection? in
            let value = current
            current = nil
            return value
        }
        guard let active = old else { return }
        let status = CMIODeviceStopStream(active.device, active.sinkStream)
        // Unregister the queue-altered callback (the header: pass NULL as the proc).
        var unused: Unmanaged<CMSimpleQueue>? = nil
        _ = CMIOStreamCopyBufferQueue(active.sinkStream, nil, nil, &unused)
        viewers.setSourceStream(nil)
        CMIOSinkClient.log.info("sink stopped: \(status)")
        setStatus(running ? .installed : .notInstalled)
    }

    private func scheduleRetry() {
        guard running, !isConnected else {
            retryTimer?.cancel()
            retryTimer = nil
            return
        }
        if retryTimer != nil { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + retryInterval, repeating: retryInterval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.isConnected || !self.running {
                self.retryTimer?.cancel()
                self.retryTimer = nil
                return
            }
            self.attempt()
        }
        retryTimer = timer
        timer.resume()
    }

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
