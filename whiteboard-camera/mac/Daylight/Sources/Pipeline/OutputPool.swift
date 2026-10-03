import CoreMedia
import CoreVideo
import DaylightKit
import Foundation

enum OutputPoolError: Error {
    case poolCreation(CVReturn)
    case formatDescription(OSStatus)
}

/// Triple-buffered 1920x1080 BGRA output frames: IOSurface-backed and Metal-compatible so the compositor writes
/// into them and the extension reads them without a copy (research-mac-pipeline section 2 item 4).
/// `acquire()` never blocks: a `DispatchSemaphore(value: 3)` with `wait(timeout: .now())` drops the frame when all
/// three are busy. The semaphore is the only bound: CoreVideo's allocation threshold would also count buffers a
/// consumer (the sink's `CMSampleBuffer`, the preview layer) still holds after `release()` and refuse a legitimate
/// acquire (LOOSE_ENDS B19 c), so the pool itself is left unbounded and `release()` is the contract.
final class OutputPool {
    static let capacity = 3

    let width: Int
    let height: Int
    let formatDescription: CMVideoFormatDescription
    private let pool: CVPixelBufferPool
    private let semaphore = DispatchSemaphore(value: OutputPool.capacity)
    private let inFlightCount = Locked<Int>(0)

    init(width: Int = 1920, height: Int = 1080) throws {
        self.width = width
        self.height = height
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: OutputPool.capacity,
        ]
        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, bufferAttributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let pool = created else { throw OutputPoolError.poolCreation(status) }
        self.pool = pool
        var probe: CVPixelBuffer?
        let probeStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &probe)
        guard probeStatus == kCVReturnSuccess, let first = probe else { throw OutputPoolError.poolCreation(probeStatus) }
        var description: CMVideoFormatDescription?
        let descriptionStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: first, formatDescriptionOut: &description)
        guard descriptionStatus == noErr, let fd = description else { throw OutputPoolError.formatDescription(descriptionStatus) }
        formatDescription = fd
    }

    /// A free buffer, or nil when all three are in flight (the caller skips this tick and counts a drop).
    func acquire() -> CVPixelBuffer? {
        guard semaphore.wait(timeout: .now()) == .success else { return nil }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let pb = buffer else {
            semaphore.signal()
            return nil
        }
        inFlightCount.withLock { $0 += 1 }
        return pb
    }

    /// Called once per acquired buffer when the GPU and the sink hand-off are done with it.
    func release(_ pixelBuffer: CVPixelBuffer) {
        inFlightCount.withLock { $0 = max(0, $0 - 1) }
        semaphore.signal()
    }

    var inFlight: Int {
        return inFlightCount.withLock { $0 }
    }

    /// Frees buffers the pool holds but nobody uses (the idle rule calls this when capture stops).
    func flush() {
        CVPixelBufferPoolFlush(pool, CVPixelBufferPoolFlushFlags(rawValue: 0))
    }
}
