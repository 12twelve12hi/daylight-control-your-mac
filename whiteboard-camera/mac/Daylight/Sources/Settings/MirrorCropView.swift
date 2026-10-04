import AppKit
import CoreImage
import CoreVideo
import DaylightKit
import SwiftUI

/// The live mirror with four draggable crop edges (ARCHITECTURE 6 item 6). Insets are tablet pixels of the native
/// portrait (1200x1600) or landscape (1600x1200) picture; the view converts between picture pixels and view points.
struct MirrorCropView: NSViewRepresentable {
    @Binding var insets: CropInsets
    var nativeWidth: Int
    var nativeHeight: Int
    var latestFrame: () -> CVPixelBuffer?

    func makeNSView(context: Context) -> CropCanvas {
        let view = CropCanvas()
        view.onChange = { insets = $0 }
        // The Settings frame decides the size; the 300 by 400 intrinsic size is only a fallback (below).
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // An accessibility element with an identifier, so the UI suite's overlap check sees the crop view's frame.
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityIdentifier(SettingsTab.mirrorCropViewID)
        return view
    }

    /// Takes the size SwiftUI offers (the Settings tab gives 260 pt of height): with the 400 pt intrinsic height the
    /// view grew past its frame and drew over the rows above and below it (UI test run 37182692894).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CropCanvas, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 300
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 260
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ view: CropCanvas, context: Context) {
        view.insets = insets
        view.nativeWidth = nativeWidth
        view.nativeHeight = nativeHeight
        view.latestFrame = latestFrame
        view.needsDisplay = true
    }

    final class CropCanvas: NSView {
        var insets = CropInsets()
        var nativeWidth = 1200
        var nativeHeight = 1600
        var latestFrame: () -> CVPixelBuffer? = { nil }
        var onChange: ((CropInsets) -> Void)?
        private var dragging: Edge?
        private let context = CIContext(options: nil)
        private var timer: Timer?

        enum Edge { case top, left, right, bottom }

        override var isFlipped: Bool { return true }
        override var intrinsicContentSize: NSSize { return NSSize(width: 300, height: 400) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            if window != nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.needsDisplay = true }
            }
        }

        /// The picture rectangle (aspect fit) inside the view.
        var pictureRect: CGRect {
            let aspect = CGFloat(nativeWidth) / CGFloat(max(1, nativeHeight))
            var w = bounds.width, h = w / aspect
            if h > bounds.height { h = bounds.height; w = h * aspect }
            return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        }

        var scale: CGFloat { return pictureRect.width / CGFloat(max(1, nativeWidth)) }

        var cropRect: CGRect {
            let p = pictureRect
            let s = scale
            return CGRect(
                x: p.minX + CGFloat(insets.left) * s,
                y: p.minY + CGFloat(insets.top) * s,
                width: p.width - CGFloat(insets.left + insets.right) * s,
                height: p.height - CGFloat(insets.top + insets.bottom) * s)
        }

        override func draw(_ dirtyRect: NSRect) {
            let cream = Tokens.surfaceCream
            NSColor(srgbRed: CGFloat(cream.r), green: CGFloat(cream.g), blue: CGFloat(cream.b), alpha: 1).setFill()
            bounds.fill()
            let picture = pictureRect
            if let buffer = latestFrame(), let cg = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))) {
                let image = NSImage(cgImage: cg, size: picture.size)
                image.draw(in: picture)
            } else {
                NSColor.darkGray.setFill()
                picture.fill()
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white]
                NSAttributedString(string: "No mirror picture yet", attributes: attributes).draw(at: NSPoint(x: picture.minX + 8, y: picture.minY + 8))
            }
            NSColor.black.withAlphaComponent(0.45).setFill()
            let crop = cropRect
            let shade = NSBezierPath(rect: picture)
            shade.append(NSBezierPath(rect: crop).reversed)
            shade.fill()
            let amber = Tokens.amber
            NSColor(srgbRed: CGFloat(amber.r), green: CGFloat(amber.g), blue: CGFloat(amber.b), alpha: 1).setStroke()
            let outline = NSBezierPath(rect: crop)
            outline.lineWidth = 2
            outline.stroke()
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let crop = cropRect
            let candidates: [(Edge, CGFloat)] = [
                (.top, abs(point.y - crop.minY)),
                (.bottom, abs(point.y - crop.maxY)),
                (.left, abs(point.x - crop.minX)),
                (.right, abs(point.x - crop.maxX)),
            ]
            dragging = candidates.min(by: { $0.1 < $1.1 })?.0
        }

        override func mouseDragged(with event: NSEvent) {
            guard let edge = dragging else { return }
            let point = convert(event.locationInWindow, from: nil)
            let picture = pictureRect
            let s = scale
            var next = insets
            switch edge {
            case .top: next.top = Int(((point.y - picture.minY) / s).rounded())
            case .bottom: next.bottom = Int(((picture.maxY - point.y) / s).rounded())
            case .left: next.left = Int(((point.x - picture.minX) / s).rounded())
            case .right: next.right = Int(((picture.maxX - point.x) / s).rounded())
            }
            next.top = max(0, min(next.top, nativeHeight - next.bottom - 100))
            next.bottom = max(0, min(next.bottom, nativeHeight - next.top - 100))
            next.left = max(0, min(next.left, nativeWidth - next.right - 100))
            next.right = max(0, min(next.right, nativeWidth - next.left - 100))
            insets = next
            onChange?(next)
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            dragging = nil
        }
    }
}
