import CoreVideo
import DaylightKit
import Foundation
import Metal
import os

enum MaskProcessorError: Error {
    case library
    case function(String)
    case pipeline(String)
    case commandQueue
    case textureCache(CVReturn)
    case texture(String)
    case commandBuffer(String)
}

/// Turns the person mask into a smoothed, feathered Metal texture (SPEC 6.7): the Vision mask becomes an r8 texture
/// without a CPU copy through `CVMetalTextureCacheCreateTextureFromImage`, then `daylight_mask_iir` blends it with
/// the previous smoothed mask (r16Float, ping-pong) and `daylight_mask_blur` runs twice (horizontal, vertical) into one
/// of three rotating r16Float outputs. `process` waits for its command buffer; it runs on the segmenter's queue only.
/// The newest output is published under a lock for the render queue.
final class MaskProcessor {
    struct Output {
        let texture: MTLTexture
        /// `CACurrentMediaTime()` seconds of the camera frame the mask came from.
        let at: Double
        let coverage: Double
    }

    struct Tuning: Equatable {
        var smoothing: Double
        var feather: Int
    }

    static let outputCount = 3

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let iirPipeline: MTLComputePipelineState
    private let blurPipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private let tuning: Locked<Tuning>
    private let published = Locked<Output?>(nil)
    private let log = Logger(subsystem: Telemetry.subsystem, category: "overlay")

    // Segmenter queue only.
    private var width = 0
    private var height = 0
    private var smoothedTextures: [MTLTexture] = []
    private var smoothedIndex = 0
    private var hasHistory = false
    private var scratch: MTLTexture?
    private var outputs: [MTLTexture] = []
    private var outputIndex = 0
    private var copyTexture: MTLTexture?
    private var copyFallbackLogged = false
    /// Called once when a mask buffer cannot be wrapped as a texture and is copied instead.
    var onLog: ((String) -> Void)?

    init(device: MTLDevice, smoothing: Double, feather: Int) throws {
        self.device = device
        tuning = Locked(Tuning(smoothing: smoothing, feather: feather))
        guard let queue = device.makeCommandQueue() else { throw MaskProcessorError.commandQueue }
        commandQueue = queue
        guard let library = device.makeDefaultLibrary() else { throw MaskProcessorError.library }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw MaskProcessorError.function(name) }
            do {
                return try device.makeComputePipelineState(function: function)
            } catch {
                throw MaskProcessorError.pipeline("\(name): \(error)")
            }
        }
        iirPipeline = try pipeline("daylight_mask_iir")
        blurPipeline = try pipeline("daylight_mask_blur")
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let created = cache else { throw MaskProcessorError.textureCache(status) }
        textureCache = created
    }

    func setTuning(smoothing: Double, feather: Int) {
        tuning.withLock { $0 = Tuning(smoothing: smoothing, feather: feather) }
    }

    /// Forget the temporal history (the next mask is taken as is).
    func resetHistory() {
        hasHistory = false
    }

    /// The newest processed mask (any thread).
    var latest: Output? {
        return published.withLock { $0 }
    }

    // MARK: Processing (segmenter queue)

    /// Processes a OneComponent8 mask buffer and publishes the result.
    @discardableResult
    func process(mask: CVPixelBuffer, at: Double, coverage: Double) throws -> Output {
        let w = CVPixelBufferGetWidth(mask)
        let h = CVPixelBufferGetHeight(mask)
        var cvTexture: CVMetalTexture?
        var source: MTLTexture?
        if let cache = textureCache {
            let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, mask, nil, .r8Unorm, w, h, 0, &cvTexture)
            if status == kCVReturnSuccess, let created = cvTexture {
                source = CVMetalTextureGetTexture(created)
            }
        }
        if source == nil {
            // UNVERIFIED that Vision's mask buffers are IOSurface-backed: copy once into an own r8 texture instead.
            source = try copyIntoTexture(mask, width: w, height: h)
            if !copyFallbackLogged {
                copyFallbackLogged = true
                let text = "overlay: mask \(w)x\(h) is not Metal-compatible; copied once per frame"
                log.notice("\(text, privacy: .public)")
                onLog?(text)
            }
        }
        guard let texture = source else { throw MaskProcessorError.texture("mask \(w)x\(h)") }
        // The CVMetalTexture keeps the Metal texture valid until the command buffer finished.
        return try withExtendedLifetime(cvTexture) {
            try process(source: texture, at: at, coverage: coverage)
        }
    }

    /// Processes an r8 (or any single-channel float-readable) source texture and publishes the result. Tests and the
    /// self-test call this with synthetic masks.
    @discardableResult
    func process(source: MTLTexture, at: Double, coverage: Double) throws -> Output {
        let w = source.width
        let h = source.height
        if w != width || h != height || outputs.isEmpty {
            try rebuild(width: w, height: h)
        }
        let t = tuning.withLock { $0 }
        guard let scratch = scratch, smoothedTextures.count == 2, outputs.count == MaskProcessor.outputCount else {
            throw MaskProcessorError.texture("intermediate textures")
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MaskProcessorError.commandBuffer("could not create a command buffer")
        }
        let previous = hasHistory ? smoothedTextures[smoothedIndex] : source
        let nextIndex = 1 - smoothedIndex
        let smoothed = smoothedTextures[nextIndex]
        var k = Float(hasHistory ? min(max(t.smoothing, 0), 1) : 0)
        encoder.setComputePipelineState(iirPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(previous, index: 1)
        encoder.setTexture(smoothed, index: 2)
        encoder.setBytes(&k, length: MemoryLayout<Float>.size, index: 0)
        dispatch(encoder, pipeline: iirPipeline, width: w, height: h)

        let radius = max(0, t.feather)
        let weights = OverlayLayout.featherWeights(radius: radius)
        let taps = weights.count
        let out = outputs[outputIndex]
        encoder.setComputePipelineState(blurPipeline)
        for (direction, pass) in [(Int32(0), (smoothed, scratch)), (Int32(1), (scratch, out))] {
            var params = SIMD2<Int32>(Int32(taps / 2), direction)
            encoder.setTexture(pass.0, index: 0)
            encoder.setTexture(pass.1, index: 1)
            weights.withUnsafeBytes { raw in
                if let base = raw.baseAddress { encoder.setBytes(base, length: raw.count, index: 0) }
            }
            encoder.setBytes(&params, length: MemoryLayout<SIMD2<Int32>>.size, index: 1)
            dispatch(encoder, pipeline: blurPipeline, width: w, height: h)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.status != .completed {
            throw MaskProcessorError.commandBuffer("status \(commandBuffer.status.rawValue) \(commandBuffer.error.map { "\($0)" } ?? "")")
        }
        smoothedIndex = nextIndex
        hasHistory = true
        outputIndex = (outputIndex + 1) % MaskProcessor.outputCount
        let output = Output(texture: out, at: at, coverage: coverage)
        published.withLock { $0 = output }
        return output
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let tw = max(1, pipeline.threadExecutionWidth)
        let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        let perGroup = MTLSize(width: tw, height: th, depth: 1)
        let groups = MTLSize(width: (width + tw - 1) / tw, height: (height + th - 1) / th, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: perGroup)
    }

    /// Mask size changed (first mask, or a quality switch): new intermediate textures, history forgotten.
    private func rebuild(width w: Int, height h: Int) throws {
        func make() throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: w, height: h, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw MaskProcessorError.texture("r16Float \(w)x\(h)") }
            return texture
        }
        smoothedTextures = [try make(), try make()]
        scratch = try make()
        outputs = try (0..<MaskProcessor.outputCount).map { _ in try make() }
        smoothedIndex = 0
        outputIndex = 0
        hasHistory = false
        width = w
        height = h
    }

    /// The fallback for a mask buffer the texture cache refuses: one CPU copy into an r8 texture of the same size.
    private func copyIntoTexture(_ buffer: CVPixelBuffer, width w: Int, height h: Int) throws -> MTLTexture {
        if copyTexture == nil || copyTexture?.width != w || copyTexture?.height != h {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
            descriptor.usage = [.shaderRead]
            copyTexture = device.makeTexture(descriptor: descriptor)
        }
        guard let texture = copyTexture else { throw MaskProcessorError.texture("r8 copy \(w)x\(h)") }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw MaskProcessorError.texture("mask base address") }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        return texture
    }

    // MARK: Read-back (tests and the self-test)

    /// The texture's values as floats, row-major, `width * height` entries: r8Unorm and r16Float are supported. Blits
    /// into a shared buffer, so private textures can be read too. Nil for other formats or a failed blit.
    static func readBack(_ texture: MTLTexture, device: MTLDevice) -> [Float]? {
        let bytesPerPixel: Int
        switch texture.pixelFormat {
        case .r8Unorm: bytesPerPixel = 1
        case .r16Float: bytesPerPixel = 2
        default: return nil
        }
        let w = texture.width
        let h = texture.height
        let bytesPerRow = ((w * bytesPerPixel + 255) / 256) * 256
        guard let buffer = device.makeBuffer(length: bytesPerRow * h, options: .storageModeShared),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * h)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        let raw = buffer.contents()
        var values: [Float] = []
        values.reserveCapacity(w * h)
        for y in 0..<h {
            let row = raw + y * bytesPerRow
            for x in 0..<w {
                if bytesPerPixel == 1 {
                    values.append(Float(row.load(fromByteOffset: x, as: UInt8.self)) / 255)
                } else {
                    values.append(MaskProcessor.halfToFloat(row.load(fromByteOffset: x * 2, as: UInt16.self)))
                }
            }
        }
        return values
    }

    /// IEEE 754 half to float without `Float16` (unavailable on Intel Macs).
    static func halfToFloat(_ bits: UInt16) -> Float {
        let sign: Float = (bits & 0x8000) != 0 ? -1 : 1
        let exponent = Int((bits >> 10) & 0x1F)
        let fraction = Float(bits & 0x3FF)
        if exponent == 0 { return sign * fraction * powf(2, -24) }
        if exponent == 31 { return fraction == 0 ? sign * Float.infinity : Float.nan }
        return sign * (1 + fraction / 1024) * powf(2, Float(exponent - 15))
    }

    /// An r8Unorm texture filled from `values` (0...1, row-major); tests and the self-test build synthetic masks.
    static func makeMaskTexture(device: MTLDevice, width: Int, height: Int, values: [Float]) -> MTLTexture? {
        guard values.count == width * height else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let bytes = values.map { UInt8(min(max($0, 0), 1) * 255 + 0.5) }
        bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: base, bytesPerRow: width)
            }
        }
        return texture
    }
}
