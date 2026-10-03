import AppKit
import DaylightKit

/// Stand-in for the AVSampleBufferDisplayLayer preview: a SolOS cream card with one line of text.
final class PreviewPlaceholderView: NSView {
    override var isFlipped: Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        let cream = Tokens.surfaceCream
        NSColor(srgbRed: CGFloat(cream.r), green: CGFloat(cream.g), blue: CGFloat(cream.b), alpha: 1).setFill()
        bounds.fill()
        let ink = Tokens.inkBlack
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor(srgbRed: CGFloat(ink.r), green: CGFloat(ink.g), blue: CGFloat(ink.b), alpha: 1),
        ]
        let text = NSAttributedString(string: "Daylight Camera preview placeholder (\(SolStream.targetWidth) x \(SolStream.targetHeight) @ \(SolStream.targetFPS) fps)", attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
