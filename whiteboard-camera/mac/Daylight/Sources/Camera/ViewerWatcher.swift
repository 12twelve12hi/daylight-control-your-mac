import CoreMediaIO
import DaylightKit
import Foundation
import os

/// Reads the extension's custom viewers property on the source stream (`4cc_dlvw_glob_0000`, ARCHITECTURE 2.4
/// item 2) with `CMIOObjectGetPropertyData` once a second, and also registers a `CMIOObjectAddPropertyListenerBlock`
/// whose firing for a custom property is UNVERIFIED (LOOSE_ENDS E3); the poll is always on. Reports changes only.
///
/// The listener is registered at most once per distinct source stream id, and only after one read of the property
/// succeeded, so an unreadable property (the unverified transport failing) costs one locate per second and registers
/// nothing, instead of a new listener block per second for the life of the app. A failed read keeps the stream unless
/// the device is gone or carries a new source stream id (the extension was replaced).
final class ViewerWatcher {
    static let log = Logger(subsystem: "com.twelve.daylight", category: "camera")
    static let pollInterval: Double = 1
    static let propertySelector: UInt32 = CMIOProperties.fourCC("dlvw")

    let locator: CMIODeviceLocator
    let queue: DispatchQueue
    var onViewerCount: ((Int) -> Void)?

    private let state = Locked<Int>(0)
    private var timer: DispatchSourceTimer?
    private var stream: CMIOStreamID?
    /// The stream a listener block was registered on (never removed: one per distinct id over the app's life).
    private var listenerStream: CMIOStreamID?
    /// How many listener blocks were registered so far (tests assert it stays bounded).
    private(set) var listenerRegistrations = 0
    private var loggedMissingProperty = false
    private var loggedUnsupported = false

    init(locator: CMIODeviceLocator, queue: DispatchQueue) {
        self.locator = locator
        self.queue = queue
    }

    var viewerCount: Int { return state.withLock { $0 } }

    /// The source stream to read from, when the sink client already located the device (saves a walk per second).
    func setSourceStream(_ stream: CMIOStreamID?) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stream = stream
            if stream == nil { self.report(0) }
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: ViewerWatcher.pollInterval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.report(0)
        }
    }

    /// One read; on the watcher queue.
    func poll() {
        if stream == nil {
            stream = locateSourceStream()
            if stream == nil {
                report(0)
                return
            }
        }
        guard let stream = stream else { return }
        guard let value = CMIOProperties.customValue(stream, fourCC: ViewerWatcher.propertySelector) else {
            if !loggedMissingProperty {
                loggedMissingProperty = true
                ViewerWatcher.log.notice("viewers property dlvw not readable on stream \(stream); the idle rule falls back to the sink state")
            }
            // The stream may have gone away (extension replaced): keep it unless the device is gone or has a new id.
            let next = ViewerWatcher.streamAfterFailedRead(current: stream, located: locateSourceStream())
            if next != stream {
                ViewerWatcher.log.info("viewers source stream \(stream) replaced by \(String(describing: next), privacy: .public)")
                self.stream = next
                if next == nil { report(0) }
            }
            return
        }
        installListenerIfNeeded(on: stream)
        guard let count = ViewerWatcher.parseCount(value) else {
            if !loggedUnsupported {
                loggedUnsupported = true
                ViewerWatcher.log.error("viewers property has an unexpected value \(String(describing: value), privacy: .public)")
            }
            return
        }
        report(count)
    }

    /// The extension publishes "sc=<n>" (verified transport, ldenoue); a bare number or a 4-byte UInt32 also decodes.
    static func parseCount(_ value: CMIOProperties.CustomValue) -> Int? {
        switch value {
        case let .number(n):
            return n >= 0 ? n : nil
        case let .string(s):
            let digits = s.reversed().prefix { $0 >= "0" && $0 <= "9" }
            guard !digits.isEmpty else { return nil }
            return Int(String(digits.reversed()))
        case .unsupported:
            return nil
        }
    }

    /// After a failed read: the same stream while the device still carries it, the new id when the device was replaced
    /// (a new extension process gets new object ids), nil when no device is found.
    static func streamAfterFailedRead(current: CMIOStreamID, located: CMIOStreamID?) -> CMIOStreamID? {
        guard let found = located else { return nil }
        return found == current ? current : found
    }

    /// One device walk; the source stream id or nil.
    private func locateSourceStream() -> CMIOStreamID? {
        guard let found = locator.locate(), let index = CMIODeviceLocator.sourceStreamIndex(streamCount: found.streams.count) else { return nil }
        return found.streams[index]
    }

    /// Registers once per distinct stream id, and only once a read succeeded (the caller guarantees that).
    private func installListenerIfNeeded(on stream: CMIOStreamID) {
        guard listenerStream != stream else { return }
        listenerStream = stream
        listenerRegistrations += 1
        var address = CMIOProperties.address(selector: ViewerWatcher.propertySelector)
        let status = CMIOObjectAddPropertyListenerBlock(stream, &address, queue) { [weak self] _, _ in
            self?.poll()
        }
        ViewerWatcher.log.info("CMIOObjectAddPropertyListenerBlock(dlvw) on stream \(stream) -> \(status) (0 means registered; whether it fires for a custom property is recorded in the handoff)")
    }

    private func report(_ count: Int) {
        let changed = state.withLock { current -> Bool in
            if current == count { return false }
            current = count
            return true
        }
        if changed {
            ViewerWatcher.log.info("viewers=\(count)")
            onViewerCount?(count)
        }
    }
}
