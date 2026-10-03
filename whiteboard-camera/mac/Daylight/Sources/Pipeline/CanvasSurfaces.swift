import CoreVideo
import DaylightKit
import Foundation
import IOSurface
import Metal

enum CanvasSurfacesError: Error {
    case surfaceCreation
    case textureCreation
}

/// The two 1200x1600 premultiplied BGRA canvas layers (ink and highlighter, SPEC D35) as IOSurfaces that CoreGraphics
/// writes and Metal samples. The Metal textures are created when a device exists; without one (the self-test on a
/// runner with no GPU) the surfaces still exist and the rasterizer still works.
final class CanvasSurfaces {
    let width: Int
    let height: Int
    let ink: IOSurfaceRef
    let highlight: IOSurfaceRef
    let inkTexture: MTLTexture?
    let highlightTexture: MTLTexture?
    private let writes = Locked<UInt32>(0)

    init(device: MTLDevice?, width: Int = SolStream.canvasWidth, height: Int = SolStream.canvasHeight) throws {
        self.width = width
        self.height = height
        ink = try CanvasSurfaces.makeSurface(width: width, height: height)
        highlight = try CanvasSurfaces.makeSurface(width: width, height: height)
        if let device = device {
            inkTexture = try CanvasSurfaces.makeTexture(device: device, surface: ink, width: width, height: height)
            highlightTexture = try CanvasSurfaces.makeTexture(device: device, surface: highlight, width: width, height: height)
        } else {
            inkTexture = nil
            highlightTexture = nil
        }
        CanvasSurfaces.zero(ink)
        CanvasSurfaces.zero(highlight)
    }

    /// Changes on every write the rasterizer reports (the compositor's "canvas seed" for frame reuse).
    var seed: UInt32 {
        return writes.withLock { $0 }
    }

    func noteWrite() {
        writes.withLock { $0 &+= 1 }
    }

    var bytesPerRow: Int { return IOSurfaceGetBytesPerRow(ink) }

    private static func makeSurface(width: Int, height: Int) throws -> IOSurfaceRef {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else { throw CanvasSurfacesError.surfaceCreation }
        return surface
    }

    private static func makeTexture(device: MTLDevice, surface: IOSurfaceRef, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        // Storage mode is left at the macOS default on purpose (research-mac-pipeline 3.1 item 2).
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            throw CanvasSurfacesError.textureCreation
        }
        return texture
    }

    private static func zero(_ surface: IOSurfaceRef) {
        IOSurfaceLock(surface, [], nil)
        let base = IOSurfaceGetBaseAddress(surface)
        let size = IOSurfaceGetAllocSize(surface)
        memset(base, 0, size)
        IOSurfaceUnlock(surface, [], nil)
    }

    /// Reads one BGRA pixel (B, G, R, A) from a layer; tests and the self-test probes use it.
    static func pixel(_ surface: IOSurfaceRef, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        var seed: UInt32 = 0
        IOSurfaceLock(surface, [.readOnly], &seed)
        defer { IOSurfaceUnlock(surface, [.readOnly], &seed) }
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let stride = IOSurfaceGetBytesPerRow(surface)
        let offset = y * stride + x * 4
        return (base[offset], base[offset + 1], base[offset + 2], base[offset + 3])
    }
}
