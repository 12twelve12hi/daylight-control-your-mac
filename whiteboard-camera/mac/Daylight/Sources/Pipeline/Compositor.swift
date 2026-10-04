import CoreImage
import CoreVideo
import DaylightKit
import Foundation
import Metal
import QuartzCore

enum CompositorError: Error {
    case library
    case function(String)
    case pipeline(String)
    case textureCache(CVReturn)
    case commandQueue
}

/// One Metal pass per frame (ARCHITECTURE 0 invariant 3): clear to SurfaceCream, presenter quad (crop, no scaling),
/// canvas quad (ink over highlighter over paper, or the mirror picture), two border lines, the divider. Textures come
/// from `CVMetalTextureCache` (presenter and target) and from the canvas IOSurfaces; the completion handler runs on
/// Metal's thread and reports the GPU time.
final class Compositor {
    enum CanvasInput {
        case layers(CanvasSurfaces)
        case mirror(CVPixelBuffer, uv: UVRect)
        case none
    }

    /// What the Presenter Overlay cutout needs beyond `frame.overlay` (SPEC 6.7): the processed person mask (nil
    /// draws the camera rectangle through a 1x1 white mask), the halo colour and the halo radius in mask texels.
    struct OverlayInput {
        var mask: MTLTexture?
        var haloColor: RGBA
        var haloRadius: Float

        init(mask: MTLTexture? = nil, haloColor: RGBA = OverlayLayout.haloColor, haloRadius: Float = Compositor.defaultHaloRadius) {
            self.mask = mask
            self.haloColor = haloColor
            self.haloRadius = haloRadius
        }
    }

    /// Matches `OverlayUniforms` in OverlayShaders.metal (a float4 then four floats, 32 bytes).
    struct OverlayUniforms {
        var haloColor: SIMD4<Float>
        var maskStrength: Float
        var opacity: Float
        var haloRadius: Float
        var haloEnabled: Float
    }

    /// The amber outline's distance from the person, in mask texels.
    static let defaultHaloRadius: Float = 3

    /// One laser pointer dot in output pixels (LOOSE_ENDS F3), drawn over the canvas quad and clipped to it (the page,
    /// never the cream margin or the border lines around it).
    struct LaserDot: Equatable {
        var rect: PixelRect
        var alpha: Double
    }

    struct Inputs {
        var presenter: CVPixelBuffer?
        var canvas: CanvasInput
        var frame: StudioLayout.Frame
        var overlay: OverlayInput?
        var laser: [LaserDot]

        init(presenter: CVPixelBuffer?, canvas: CanvasInput, frame: StudioLayout.Frame, overlay: OverlayInput? = nil, laser: [LaserDot] = []) {
            self.presenter = presenter
            self.canvas = canvas
            self.frame = frame
            self.overlay = overlay
            self.laser = laser
        }
    }

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let texturedPipeline: MTLRenderPipelineState
    private let canvasPipeline: MTLRenderPipelineState
    private let solidPipeline: MTLRenderPipelineState
    private let dotPipeline: MTLRenderPipelineState
    private let library: MTLLibrary
    /// Created on the first overlay frame, so a library without `daylight_overlay` never breaks the other pipelines.
    private var overlayPipeline: MTLRenderPipelineState?
    private var overlayPipelineFailed = false
    private var whiteMask: MTLTexture?
    /// Called once when the overlay pipeline cannot be created (the cutout is then drawn as a plain rectangle).
    var onOverlayUnavailable: ((String) -> Void)?
    private var textureCache: CVMetalTextureCache?
    /// CVMetalTextureCache.h: `CVMetalTextureCacheFlush` "must be made periodically"; once per second of frames, on
    /// the render queue (never from the Metal completion thread, which may run while a texture is being created).
    static let textureCacheFlushInterval = 30
    private var framesSinceFlush = 0
    private var ciContext: CIContext?
    private var conversionPool: OutputPool?
    private let conversionLogged = Locked<Bool>(false)
    var onConversionFallback: ((String) -> Void)?

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw CompositorError.commandQueue }
        commandQueue = queue
        guard let library = device.makeDefaultLibrary() else { throw CompositorError.library }
        self.library = library
        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw CompositorError.function(name) }
            return f
        }
        let vertex = try function("daylight_vertex")
        texturedPipeline = try Compositor.makePipeline(device: device, vertex: vertex, fragment: try function("daylight_textured"), blending: false, label: "textured")
        canvasPipeline = try Compositor.makePipeline(device: device, vertex: vertex, fragment: try function("daylight_canvas"), blending: false, label: "canvas")
        solidPipeline = try Compositor.makePipeline(device: device, vertex: vertex, fragment: try function("daylight_solid"), blending: true, label: "solid")
        dotPipeline = try Compositor.makePipeline(device: device, vertex: vertex, fragment: try function("daylight_dot"), blending: true, label: "dot")
        var cache: CVMetalTextureCache?
        let usage = MTLTextureUsage([.renderTarget, .shaderRead])
        let textureAttributes: [CFString: Any] = [kCVMetalTextureUsage: usage.rawValue]
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, textureAttributes as CFDictionary, &cache)
        guard status == kCVReturnSuccess, let created = cache else { throw CompositorError.textureCache(status) }
        textureCache = created
    }

    private static func makePipeline(device: MTLDevice, vertex: MTLFunction, fragment: MTLFunction, blending: Bool, label: String) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = .bgra8Unorm
        if blending {
            // Colour blends sourceAlpha / oneMinusSourceAlpha; the target's alpha is kept, as the overlay pipeline does.
            // Every pass before a blended one writes alpha 1 (the clear, the textured and canvas fragments), so the
            // frame stays opaque under the divider at any fade and around every laser dot (review F3).
            attachment?.isBlendingEnabled = true
            attachment?.rgbBlendOperation = .add
            attachment?.alphaBlendOperation = .add
            attachment?.sourceRGBBlendFactor = .sourceAlpha
            attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment?.sourceAlphaBlendFactor = .zero
            attachment?.destinationAlphaBlendFactor = .one
        }
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw CompositorError.pipeline("\(label): \(error)")
        }
    }

    // MARK: Rendering

    /// Encodes one frame into `target` (a pool buffer) and calls `completion` with the GPU time in seconds on Metal's
    /// completion thread. The caller keeps `target` alive until then (it does: it pushes and releases it there).
    func render(_ inputs: Inputs, into target: CVPixelBuffer, completion: @escaping (CFTimeInterval) -> Void) {
        guard let cache = textureCache else { completion(0); return }
        framesSinceFlush += 1
        if framesSinceFlush >= Compositor.textureCacheFlushInterval {
            framesSinceFlush = 0
            CVMetalTextureCacheFlush(cache, 0)
        }
        guard let targetCV = makeTexture(cache: cache, pixelBuffer: target), let targetTexture = CVMetalTextureGetTexture(targetCV) else {
            completion(0)
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { completion(0); return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targetTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let cream = Tokens.surfaceCream
        pass.colorAttachments[0].clearColor = MTLClearColor(red: cream.r, green: cream.g, blue: cream.b, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { completion(0); return }
        var retained: [AnyObject] = [targetCV]
        let width = CVPixelBufferGetWidth(target)
        let height = CVPixelBufferGetHeight(target)
        let fullScissor = MTLScissorRect(x: 0, y: 0, width: width, height: height)
        encoder.setScissorRect(fullScissor)

        let frame = inputs.frame

        // 1. Presenter (crop, no scaling). Missing camera: the cream clear stays.
        if let quad = frame.presenter, let presenter = inputs.presenter {
            if let pair = presenterTexture(cache: cache, pixelBuffer: presenter) {
                retained.append(pair.0)
                encoder.setRenderPipelineState(texturedPipeline)
                encoder.setFragmentTexture(pair.1, index: 0)
                drawQuad(encoder, dest: quad.dest, uv: quad.uv)
            }
        }

        // 2. The studio panel, scissored to its visible part.
        if let clip = frame.canvasClip, let panelScissor = Compositor.scissor(clip, width: width, height: height) {
            encoder.setScissorRect(panelScissor)
            // Cream behind the paper (Whiteboard Only slides over the presenter).
            drawSolid(encoder, rect: clip, color: cream, alpha: 1)
            if let canvasQuad = frame.canvas {
                switch inputs.canvas {
                case let .layers(surfaces):
                    if let ink = surfaces.inkTexture, let highlight = surfaces.highlightTexture {
                        encoder.setRenderPipelineState(canvasPipeline)
                        encoder.setFragmentTexture(ink, index: 0)
                        encoder.setFragmentTexture(highlight, index: 1)
                        var paper = Compositor.float4(Tokens.paperBg, alpha: 1)
                        encoder.setFragmentBytes(&paper, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                        drawQuad(encoder, dest: canvasQuad.dest, uv: canvasQuad.uv)
                    } else {
                        drawSolid(encoder, rect: canvasQuad.dest, color: Tokens.paperBg, alpha: 1)
                    }
                case let .mirror(pixelBuffer, uv):
                    if let pair = presenterTexture(cache: cache, pixelBuffer: pixelBuffer) {
                        retained.append(pair.0)
                        encoder.setRenderPipelineState(texturedPipeline)
                        encoder.setFragmentTexture(pair.1, index: 0)
                        drawQuad(encoder, dest: canvasQuad.dest, uv: uv)
                    } else {
                        drawSolid(encoder, rect: canvasQuad.dest, color: Tokens.paperBg, alpha: 1)
                    }
                case .none:
                    drawSolid(encoder, rect: canvasQuad.dest, color: Tokens.paperBg, alpha: 1)
                }
            }
            // The laser pointer: over the page, never in it (the canvas surfaces and the store never see it). Clipped
            // to the canvas quad inside the panel and drawn before the border lines, so a dot at the page edge never
            // spills over the margin or the border, and a dot half out of a followed view is cut at the frame edge
            // (review F5).
            if let canvasQuad = frame.canvas, !inputs.laser.isEmpty,
               let dotScissor = Compositor.scissor(FollowRegion.intersect(clip, canvasQuad.dest), width: width, height: height) {
                encoder.setScissorRect(dotScissor)
                encoder.setRenderPipelineState(dotPipeline)
                for dot in inputs.laser where dot.rect.w > 0 && dot.rect.h > 0 {
                    var c = Compositor.float4(LaserTrail.color, alpha: min(max(dot.alpha, 0), 1))
                    encoder.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                    drawQuad(encoder, dest: dot.rect, uv: .full)
                }
            }
            // Restore the panel scissor for the border lines.
            encoder.setScissorRect(panelScissor)
            for border in frame.borders {
                drawSolid(encoder, rect: border, color: Tokens.borderSubtle, alpha: 1)
            }
            encoder.setScissorRect(fullScissor)
        }

        // 3. Divider (fades in with the slide; amber breath during the pre-warning).
        if let divider = frame.divider, frame.dividerAlpha > 0.001 {
            drawSolid(encoder, rect: divider, color: frame.dividerColor, alpha: frame.dividerAlpha)
        }

        // 4. Presenter Overlay cutout (SPEC 6.7): the camera picture through the person mask, over the board.
        if let cutout = frame.overlay, let presenter = inputs.presenter, let pair = presenterTexture(cache: cache, pixelBuffer: presenter) {
            retained.append(pair.0)
            let overlay = inputs.overlay ?? OverlayInput()
            if let pipeline = overlayPipelineState(), let mask = overlay.mask ?? whiteMaskTexture() {
                retained.append(mask as AnyObject)
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(pair.1, index: 0)
                encoder.setFragmentTexture(mask, index: 1)
                var uniforms = OverlayUniforms(
                    haloColor: Compositor.float4(overlay.haloColor, alpha: 1),
                    maskStrength: Float(min(max(cutout.maskStrength, 0), 1)),
                    opacity: Float(min(max(cutout.opacity, 0), 1)),
                    haloRadius: overlay.haloRadius,
                    haloEnabled: cutout.halo ? 1 : 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
            } else {
                encoder.setRenderPipelineState(texturedPipeline)
                encoder.setFragmentTexture(pair.1, index: 0)
            }
            drawQuad(encoder, dest: cutout.dest, uv: cutout.uv)
        }

        encoder.endEncoding()
        // The frame's CVMetalTextures go back to `cache` when they are released, on Metal's completion queue. The
        // cache must still exist then: when the Compositor was released with a frame in flight (a pipeline torn down
        // between ticks), CoreVideo wrote into the freed cache (EXC_BAD_ACCESS in
        // CVMetalTextureCache::bufferBackingNotInUse, Review 4 CI-1, mac-26 run 37189486118). So the handler releases
        // the textures itself, while it still holds the cache, and the cache goes last.
        let resources = FrameResources(objects: retained, cache: cache)
        commandBuffer.addCompletedHandler { buffer in
            let gpu = buffer.gpuEndTime - buffer.gpuStartTime
            completion(gpu > 0 ? gpu : 0)
            resources.releaseTextures()
        }
        commandBuffer.commit()
    }

    /// `render` plus a wait; tests and the self-test use it.
    func renderSync(_ inputs: Inputs, into target: CVPixelBuffer) -> CFTimeInterval {
        let done = DispatchSemaphore(value: 0)
        var gpu: CFTimeInterval = 0
        render(inputs, into: target) { time in
            gpu = time
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        return gpu
    }

    // MARK: Overlay

    /// The blended `daylight_overlay` pipeline, created on first use; nil (reported once) when it cannot be made.
    private func overlayPipelineState() -> MTLRenderPipelineState? {
        if let pipeline = overlayPipeline { return pipeline }
        if overlayPipelineFailed { return nil }
        do {
            guard let vertex = library.makeFunction(name: "daylight_vertex") else { throw CompositorError.function("daylight_vertex") }
            guard let fragment = library.makeFunction(name: "daylight_overlay") else { throw CompositorError.function("daylight_overlay") }
            // Colour blends sourceAlpha / oneMinusSourceAlpha like the solid pipeline; the target's alpha is kept (the
            // frame stays opaque where the cutout is clear).
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "overlay"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            if let attachment = descriptor.colorAttachments[0] {
                attachment.pixelFormat = .bgra8Unorm
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .zero
                attachment.destinationAlphaBlendFactor = .one
            }
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            overlayPipeline = pipeline
            return pipeline
        } catch {
            overlayPipelineFailed = true
            onOverlayUnavailable?("overlay pipeline unavailable: \(error)")
            return nil
        }
    }

    /// A 1x1 r8 texture holding 1: the mask of the camera rectangle.
    private func whiteMaskTexture() -> MTLTexture? {
        if let mask = whiteMask { return mask }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var white: UInt8 = 255
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 1)
        whiteMask = texture
        return texture
    }

    // MARK: Geometry helpers

    private func drawQuad(_ encoder: MTLRenderCommandEncoder, dest: PixelRect, uv: UVRect) {
        var vertices = Compositor.quadVertices(dest: dest, uv: uv)
        encoder.setVertexBytes(&vertices, length: MemoryLayout<Float>.size * vertices.count, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawSolid(_ encoder: MTLRenderCommandEncoder, rect: PixelRect, color: RGBA, alpha: Double) {
        guard rect.w > 0, rect.h > 0 else { return }
        encoder.setRenderPipelineState(solidPipeline)
        var c = Compositor.float4(color, alpha: alpha)
        encoder.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        drawQuad(encoder, dest: rect, uv: .full)
    }

    static func float4(_ c: RGBA, alpha: Double) -> SIMD4<Float> {
        return SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), Float(alpha))
    }

    /// Six vertices (two triangles), each `x, y, u, v` in clip space with v = 0 at the top.
    static func quadVertices(dest: PixelRect, uv: UVRect) -> [Float] {
        let c = StudioLayout.clip(dest)
        let l = Float(c.l), t = Float(c.t), r = Float(c.r), b = Float(c.b)
        let u0 = Float(uv.u0), v0 = Float(uv.v0), u1 = Float(uv.u1), v1 = Float(uv.v1)
        return [
            l, t, u0, v0,
            l, b, u0, v1,
            r, t, u1, v0,
            r, t, u1, v0,
            l, b, u0, v1,
            r, b, u1, v1,
        ]
    }

    /// Clamps a pixel rectangle to the target; nil when nothing is visible.
    static func scissor(_ r: PixelRect, width: Int, height: Int) -> MTLScissorRect? {
        let x0 = max(0, Int(floor(r.x)))
        let y0 = max(0, Int(floor(r.y)))
        let x1 = min(width, Int(ceil(r.x + r.w)))
        let y1 = min(height, Int(ceil(r.y + r.h)))
        guard x1 > x0, y1 > y0 else { return nil }
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // MARK: Textures

    private func makeTexture(cache: CVMetalTextureCache, pixelBuffer: CVPixelBuffer) -> CVMetalTexture? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        guard status == kCVReturnSuccess else { return nil }
        return cvTexture
    }

    /// BGRA buffers are sampled directly; anything else is converted once through CoreImage into a scratch BGRA
    /// buffer (the logged fallback of SPEC section 4, failure row 5).
    private func presenterTexture(cache: CVMetalTextureCache, pixelBuffer: CVPixelBuffer) -> (CVMetalTexture, MTLTexture)? {
        var source = pixelBuffer
        if CVPixelBufferGetPixelFormatType(pixelBuffer) != kCVPixelFormatType_32BGRA {
            guard let converted = convertToBGRA(pixelBuffer) else { return nil }
            source = converted
        }
        guard let cvTexture = makeTexture(cache: cache, pixelBuffer: source), let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (cvTexture, texture)
    }

    private func convertToBGRA(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if conversionPool == nil || conversionPool?.width != width || conversionPool?.height != height {
            conversionPool = try? OutputPool(width: width, height: height)
        }
        if ciContext == nil {
            ciContext = CIContext(mtlDevice: device, options: [CIContextOption.workingColorSpace: NSNull(), CIContextOption.outputColorSpace: NSNull()])
        }
        guard let pool = conversionPool, let context = ciContext, let out = pool.acquire() else { return nil }
        context.render(CIImage(cvPixelBuffer: pixelBuffer), to: out)
        pool.release(out)
        let first = conversionLogged.withLock { logged -> Bool in
            if logged { return false }
            logged = true
            return true
        }
        if first {
            onConversionFallback?("presenter \(width)x\(height) \(Compositor.fourcc(CVPixelBufferGetPixelFormatType(pixelBuffer))) converted through CoreImage")
        }
        return out
    }

    static func fourcc(_ type: OSType) -> String {
        let bytes: [UInt8] = [UInt8((type >> 24) & 0xFF), UInt8((type >> 16) & 0xFF), UInt8((type >> 8) & 0xFF), UInt8(type & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? String(type)
    }
}

/// One frame's textures and the cache they came from (Review 4 CI-1): `releaseTextures()` runs in the completion
/// handler, so every CVMetalTexture is released while this object still holds the cache; the cache goes when the
/// handler (and this object) is destroyed. Touched only by the one completion handler after the commit.
private final class FrameResources: @unchecked Sendable {
    private var objects: [AnyObject]
    private let cache: CVMetalTextureCache

    init(objects: [AnyObject], cache: CVMetalTextureCache) {
        self.objects = objects
        self.cache = cache
    }

    func releaseTextures() {
        objects.removeAll()
        withExtendedLifetime(cache) {}
    }
}
