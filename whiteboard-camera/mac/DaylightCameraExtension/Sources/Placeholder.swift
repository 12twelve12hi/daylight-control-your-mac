import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// The cream card viewers see while Daylight.app is not feeding the sink (SPEC 4): SurfaceCream background, a PaperBg
/// card with a BorderSubtle edge and the one sentence of `DaylightExtensionRules.placeholderText` in InkBlack.
/// Rendered once into a BGRA byte array (`byteOrder32Little | noneSkipFirst`, the OBS bitmap layout) and copied into
/// every placeholder pixel buffer, so the 30 Hz placeholder timer does no CoreGraphics work per frame.
final class Placeholder {
    static let shared = Placeholder(width: Int(DaylightExtensionRules.frameWidth), height: Int(DaylightExtensionRules.frameHeight))

    let width: Int
    let height: Int
    private let bytesPerRow: Int
    private let pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytesPerRow = width * 4
        pixels = Placeholder.render(width: width, height: height, bytesPerRow: bytesPerRow, text: DaylightExtensionRules.placeholderText)
    }

    /// Copies the card into `pixelBuffer`; a buffer of another size gets a plain SurfaceCream fill.
    func fill(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let targetWidth = CVPixelBufferGetWidth(pixelBuffer)
        let targetHeight = CVPixelBufferGetHeight(pixelBuffer)
        let targetRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        if targetWidth == width && targetHeight == height {
            pixels.withUnsafeBytes { source in
                guard let sourceBase = source.baseAddress else { return }
                if targetRowBytes == bytesPerRow {
                    memcpy(base, sourceBase, bytesPerRow * height)
                } else {
                    for row in 0..<height {
                        memcpy(base + row * targetRowBytes, sourceBase + row * bytesPerRow, bytesPerRow)
                    }
                }
            }
            return
        }
        Placeholder.fillCream(base: base, width: targetWidth, height: targetHeight, bytesPerRow: targetRowBytes)
    }

    /// Plain SurfaceCream (the scaffold behaviour), used for buffers of an unexpected size.
    static func fillCream(base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.setFillColor(color(DaylightExtensionRules.surfaceCream))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: alpha)
    }

    private static func render(width: Int, height: Int, bytesPerRow: Int, text: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            fillCream(base: base, width: width, height: height, bytesPerRow: bytesPerRow)
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            // The card: 1200 x 360 centred, PaperBg with a 1.5 px BorderSubtle edge (tokens only, no shadow).
            let cardWidth = CGFloat(min(1200, width - 80))
            let cardHeight = CGFloat(min(360, height - 80))
            let card = CGRect(x: (CGFloat(width) - cardWidth) / 2, y: (CGFloat(height) - cardHeight) / 2, width: cardWidth, height: cardHeight)
            let path = CGPath(roundedRect: card, cornerWidth: 24, cornerHeight: 24, transform: nil)
            context.addPath(path)
            context.setFillColor(color(DaylightExtensionRules.paperBg))
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(color(DaylightExtensionRules.borderSubtle))
            context.setLineWidth(1.5)
            context.strokePath()
            // The sentence, split at the period so both halves fit the card.
            let lines = splitSentence(text)
            let fontSize: CGFloat = lines.count > 1 ? 44 : 40
            let lineGap: CGFloat = fontSize * 1.5
            let totalHeight = lineGap * CGFloat(lines.count)
            var baseline = card.midY + totalHeight / 2 - fontSize
            for (index, line) in lines.enumerated() {
                let colour = index == 0 ? DaylightExtensionRules.inkBlack : DaylightExtensionRules.textMuted
                drawCentered(line, in: context, fontSize: fontSize, colour: color(colour), centerX: card.midX, baseline: baseline)
                baseline -= lineGap
            }
        }
        return bytes
    }

    /// "A. B." becomes ["A.", "B."]; a sentence without an inner period stays one line.
    static func splitSentence(_ text: String) -> [String] {
        let parts = text.split(separator: ".", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count <= 1 { return [text] }
        return parts.map { $0 + "." }
    }

    private static func drawCentered(_ text: String, in context: CGContext, fontSize: CGFloat, colour: CGColor, centerX: CGFloat, baseline: CGFloat) {
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: colour,
        ]
        guard let attributed = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.saveGState()
        context.textPosition = CGPoint(x: centerX - bounds.width / 2, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
