import CoreMedia
import CoreVideo
import DaylightKit
import Foundation
@testable import Daylight

/// Records every push (IMPLEMENTATION-PLAN section 10). Prompt: `push` returns at once, so a pipeline fed by it
/// never drops for back-pressure.
final class FakeSink: VirtualCameraSink {
    private let lock = NSLock()
    private var currentStatus: SinkStatus = .notInstalled
    private var count = 0
    private var last: CVPixelBuffer?
    private var first: CVPixelBuffer?
    var acceptPushes = true
    var onStatusChange: ((SinkStatus) -> Void)?
    var onQueueAltered: (() -> Void)?
    var onViewerCount: ((Int) -> Void)?
    private(set) var viewerCount: Int = 0
    private(set) var started = false

    var status: SinkStatus {
        lock.lock()
        defer { lock.unlock() }
        return currentStatus
    }

    func setStatus(_ status: SinkStatus) {
        lock.lock()
        currentStatus = status
        lock.unlock()
        onStatusChange?(status)
    }

    func setViewers(_ n: Int) {
        viewerCount = n
        onViewerCount?(n)
    }

    func start() { started = true }
    func stop() { started = false }

    @discardableResult
    func push(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard acceptPushes else { return false }
        let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        lock.lock()
        count += 1
        if first == nil { first = buffer }
        last = buffer
        lock.unlock()
        return true
    }

    var pushCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var lastPixelBuffer: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    var firstPixelBuffer: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return first
    }

    func resetRecording() {
        lock.lock()
        count = 0
        first = nil
        last = nil
        lock.unlock()
    }
}
