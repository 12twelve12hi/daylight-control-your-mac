import CoreVideo
import DaylightKit
import Foundation
import Metal
import XCTest
@testable import Daylight

/// Person mask engines for the Overlay tests: Vision is never needed (a runner may have no person segmentation).
enum OverlayFakes {
    struct Failure: Error, CustomStringConvertible {
        var description: String { return "fake segmentation failure" }
    }

    /// A OneComponent8 buffer of `value` everywhere (IOSurface-backed unless `iosurface` is false).
    static func maskBuffer(width: Int = 64, height: Int = 36, value: UInt8, iosurface: Bool = true) -> CVPixelBuffer {
        var attributes: [CFString: Any] = [:]
        if iosurface {
            attributes[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary
            attributes[kCVPixelBufferMetalCompatibilityKey] = true
        }
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent8, attributes as CFDictionary, &created)
        precondition(status == kCVReturnSuccess && created != nil, "OneComponent8 buffer \(status)")
        let buffer = created!
        fill(buffer) { _, _ in value }
        return buffer
    }

    /// Writes `value(x, y)` into every pixel of a OneComponent8 buffer.
    static func fill(_ buffer: CVPixelBuffer, _ value: (Int, Int) -> UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                bytes[y * stride + x] = value(x, y)
            }
        }
    }

    static func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("MTLCreateSystemDefaultDevice() is nil on this machine; the overlay GPU path is first tested on the owner's Mac")
        }
        return device
    }
}

/// Always throws; counts calls.
final class ThrowingMaskEngine: PersonMaskEngine {
    private let lock = NSLock()
    private var count = 0

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func mask(for pixelBuffer: CVPixelBuffer, quality: OverlayQuality) throws -> CVPixelBuffer {
        lock.lock()
        count += 1
        lock.unlock()
        throw OverlayFakes.Failure()
    }
}

/// Returns a fixed mask; counts calls.
final class FixedMaskEngine: PersonMaskEngine {
    let result: CVPixelBuffer
    private let lock = NSLock()
    private var count = 0

    init(value: UInt8) {
        result = OverlayFakes.maskBuffer(value: value)
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func mask(for pixelBuffer: CVPixelBuffer, quality: OverlayQuality) throws -> CVPixelBuffer {
        lock.lock()
        count += 1
        lock.unlock()
        return result
    }
}

/// Blocks inside `mask(for:)` until `release()`; `entered` is signalled when a call starts.
final class BlockingMaskEngine: PersonMaskEngine {
    let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    let result = OverlayFakes.maskBuffer(value: 255)

    func release() {
        gate.signal()
    }

    func mask(for pixelBuffer: CVPixelBuffer, quality: OverlayQuality) throws -> CVPixelBuffer {
        entered.signal()
        _ = gate.wait(timeout: .now() + 10)
        return result
    }
}
