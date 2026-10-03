import CoreMedia
import CoreVideo
import DaylightKit
import Foundation
import XCTest
@testable import Daylight

/// Pixel buffers for the camera tests: IOSurface-backed BGRA of any size, filled with one byte value.
enum CameraTestBuffers {
    static func make(width: Int, height: Int, fill: UInt8 = 0x80) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(fill), CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}

/// A `VirtualCameraSink` over a real `CMSimpleQueue` of capacity 1 (IMPLEMENTATION-PLAN section 10): the same enqueue
/// rule as `CMIOSinkClient.push` (count < capacity, retained element), so the drop behaviour of SPEC C4 is real.
final class QueueSink: VirtualCameraSink {
    private(set) var status: SinkStatus = .connected
    var onStatusChange: ((SinkStatus) -> Void)?
    var onQueueAltered: (() -> Void)?
    let viewerCount: Int = 0
    var onViewerCount: ((Int) -> Void)?
    let queue: CMSimpleQueue
    private(set) var enqueued = 0
    private(set) var dropped = 0

    init(capacity: Int32 = 1) throws {
        var created: CMSimpleQueue?
        let status = CMSimpleQueueCreate(allocator: kCFAllocatorDefault, capacity: capacity, queueOut: &created)
        guard status == noErr, let queue = created else {
            throw NSError(domain: "QueueSink", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "CMSimpleQueueCreate failed"])
        }
        self.queue = queue
    }

    func start() {}
    func stop() {}

    @discardableResult
    func push(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            dropped += 1
            return false
        }
        let element = UnsafeMutableRawPointer(Unmanaged.passRetained(sampleBuffer).toOpaque())
        guard CMSimpleQueueEnqueue(queue, element: element) == noErr else {
            Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
            dropped += 1
            return false
        }
        enqueued += 1
        onQueueAltered?()
        return true
    }

    /// What the extension does: take the retained element off the queue.
    func dequeue() -> CMSampleBuffer? {
        guard let element = CMSimpleQueueDequeue(queue) else { return nil }
        return Unmanaged<CMSampleBuffer>.fromOpaque(element).takeRetainedValue()
    }

    var count: Int { return Int(CMSimpleQueueGetCount(queue)) }
    var capacity: Int { return Int(CMSimpleQueueGetCapacity(queue)) }
}
