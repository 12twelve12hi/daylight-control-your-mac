import CoreGraphics
import CoreImage
import CoreVideo
import DaylightKit
import Foundation
import IOSurface

/// What the share window shows: the two ink layers of the stroke sources, or the mirror picture.
enum ShareCanvasSource {
    case layers(CanvasSurfaces)
    case mirror(MirrorFrameSource)
    case none
}

/// Turns the canvas into one `CGImage` for the share window (docs/product/TOO-SMALL.md section 8). The stroke layers
/// are composed exactly like the compositor's `daylight_canvas` shader: paper, the highlighter multiplied under the
/// ink, the ink on top. Pure CoreGraphics on the caller's queue; no Metal, so it also runs without a GPU.
enum ShareCanvasRenderer {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    static let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

    /// Paper, then `highlight` with the multiply blend (premultiplied: `paper * ((1 - a) + rgb)`), then `ink` source
    /// over. Both surfaces are premultiplied BGRA of the same size, row 0 at the top of the page.
    static func compose(ink: IOSurfaceRef, highlight: IOSurfaceRef, paper: RGBA = Tokens.paperBg) -> CGImage? {
        let width = IOSurfaceGetWidth(ink)
        let height = IOSurfaceGetHeight(ink)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo),
              let inkImage = snapshot(ink), let highlightImage = snapshot(highlight) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [CGFloat(paper.r), CGFloat(paper.g), CGFloat(paper.b), 1]) ?? CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.multiply)
        ctx.draw(highlightImage, in: rect)
        ctx.setBlendMode(.normal)
        ctx.draw(inkImage, in: rect)
        return ctx.makeImage()
    }

    /// A copy of a premultiplied BGRA surface as a `CGImage` (the rasterizer keeps writing the surface, so the share
    /// window never holds a view of live memory).
    static func snapshot(_ surface: IOSurfaceRef) -> CGImage? {
        var seed: UInt32 = 0
        IOSurfaceLock(surface, [.readOnly], &seed)
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let stride = IOSurfaceGetBytesPerRow(surface)
        let data = Data(bytes: IOSurfaceGetBaseAddress(surface), count: stride * height)
        IOSurfaceUnlock(surface, [.readOnly], &seed)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// The mirror picture cropped to `uv` (Metal convention: v = 0 is the top row).
    static func mirrorImage(_ buffer: CVPixelBuffer, uv: UVRect) -> CGImage? {
        let width = Double(CVPixelBufferGetWidth(buffer))
        let height = Double(CVPixelBufferGetHeight(buffer))
        guard width > 0, height > 0 else { return nil }
        let crop = cropRect(uv: uv, width: width, height: height)
        let image = CIImage(cvPixelBuffer: buffer).cropped(to: crop)
        return ciContext.createCGImage(image, from: crop)
    }

    /// `uv` (top-left origin) as a CoreImage rectangle (bottom-left origin) in pixels.
    static func cropRect(uv: UVRect, width: Double, height: Double) -> CGRect {
        let u0 = min(max(uv.u0, 0), 1)
        let u1 = min(max(uv.u1, 0), 1)
        let v0 = min(max(uv.v0, 0), 1)
        let v1 = min(max(uv.v1, 0), 1)
        return CGRect(x: u0 * width, y: (1 - v1) * height, width: max(u1 - u0, 0) * width, height: max(v1 - v0, 0) * height)
    }

    /// One BGRA pixel of a `CGImage` drawn into a known layout (tests and the self-test).
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8)? {
        let width = image.width
        let height = image.height
        guard x >= 0, y >= 0, x < width, y < height,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let offset = y * width * 4 + x * 4
        return (base[offset], base[offset + 1], base[offset + 2], base[offset + 3])
    }
}
