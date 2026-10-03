import CoreGraphics
import DaylightKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PNGExporterError: Error {
    case context
    case destination
    case finalize
}

/// Renders a page from the stroke model (not the live IOSurfaces) at canvas size (SPEC 12): PaperBg fill, highlighter
/// strokes with multiply, ink strokes normal; written with ImageIO as PNG.
enum PNGExporter {
    static func render(_ store: StrokeStore, size: CGSize = CGSize(width: SolStream.canvasWidth, height: SolStream.canvasHeight), paper: Bool = true) -> CGImage? {
        return render(strokes: store.strokes, size: size, paper: paper)
    }

    static func render(strokes: [Stroke], size: CGSize, paper: Bool) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Little.rawValue | (paper ? CGImageAlphaInfo.noneSkipFirst.rawValue : CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShouldAntialias(true)
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        if paper {
            let bg = Tokens.paperBg
            ctx.setFillColor(red: CGFloat(bg.r), green: CGFloat(bg.g), blue: CGFloat(bg.b), alpha: 1)
            ctx.fill(full)
        } else {
            ctx.clear(full)
        }
        // Highlighter first (multiplied under the ink), then everything else.
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        for stroke in strokes where stroke.style.tool == .highlighter { draw(stroke, in: ctx) }
        ctx.restoreGState()
        for stroke in strokes where stroke.style.tool != .highlighter && stroke.style.tool != .eraser { draw(stroke, in: ctx) }
        return ctx.makeImage()
    }

    private static func draw(_ stroke: Stroke, in ctx: CGContext) {
        let points = stroke.points
        guard !points.isEmpty else { return }
        let argb = stroke.style.colorARGB
        let a = CGFloat((argb >> 24) & 0xFF) / 255
        let r = CGFloat((argb >> 16) & 0xFF) / 255
        let g = CGFloat((argb >> 8) & 0xFF) / 255
        let b = CGFloat(argb & 0xFF) / 255
        ctx.setStrokeColor(red: r, green: g, blue: b, alpha: a)
        ctx.setFillColor(red: r, green: g, blue: b, alpha: a)
        if points.count == 1 {
            let d = stroke.dotDiameter
            ctx.fillEllipse(in: CGRect(x: points[0].x - d / 2, y: points[0].y - d / 2, width: d, height: d))
            return
        }
        for i in 1..<points.count {
            ctx.setLineWidth(CGFloat(stroke.width(at: i)))
            ctx.move(to: CGPoint(x: points[i - 1].x, y: points[i - 1].y))
            ctx.addLine(to: CGPoint(x: points[i].x, y: points[i].y))
            ctx.strokePath()
        }
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw PNGExporterError.destination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PNGExporterError.finalize }
    }
}
