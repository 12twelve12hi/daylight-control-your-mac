import AppKit

/// A press-and-hold button. Reports progress in seconds while the mouse is
/// down, fires `onComplete` once the hold lasted `holdSeconds`, and
/// `onCancel` when the mouse is released or dragged out early.
final class HoldButton: NSView {

    // MARK: - Public

    var onProgress: ((Double) -> Void)?
    var onComplete: (() -> Void)?
    var onCancel: (() -> Void)?

    init(title: String, holdSeconds: Int) {
        self.title = title
        self.holdSeconds = Double(holdSeconds)
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 44))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Stops any hold in progress and invalidates the timer.
    func stop() {
        cancelHold()
    }

    // MARK: - Private state

    private let title: String
    private let holdSeconds: Double
    private var pressStart: Date?
    private var timer: Timer?
    private var isPressed = false

    // MARK: - NSView

    override var intrinsicContentSize: NSSize {
        return NSSize(width: 360, height: 44)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        let fill = isPressed
            ? NSColor(calibratedRed: 0.62, green: 0.22, blue: 0.2, alpha: 1)
            : NSColor(calibratedWhite: 0.2, alpha: 1)
        fill.setFill()
        path.fill()
        NSColor(calibratedWhite: 0.38, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = text.size()
        let textRect = NSRect(
            x: 0,
            y: (bounds.height - size.height) / 2,
            width: bounds.width,
            height: size.height
        )
        text.draw(in: textRect)
    }

    // MARK: - Mouse tracking

    override func mouseDown(with event: NSEvent) {
        beginHold()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !bounds.contains(point) {
            cancelHold()
        }
    }

    override func mouseUp(with event: NSEvent) {
        cancelHold()
    }

    // MARK: - Hold logic

    private func beginHold() {
        cancelTimer()
        isPressed = true
        pressStart = Date()
        needsDisplay = true
        onProgress?(0)
        let newTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func tick() {
        guard let start = pressStart else { return }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= holdSeconds {
            cancelTimer()
            onProgress?(holdSeconds)
            onComplete?()
        } else {
            onProgress?(elapsed)
        }
    }

    /// Ends a hold early. Does nothing special after a completed hold, so the
    /// mouse-up that follows completion does not undo it.
    private func cancelHold() {
        let wasHolding = timer != nil
        cancelTimer()
        isPressed = false
        needsDisplay = true
        if wasHolding {
            onCancel?()
        }
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
        pressStart = nil
    }
}
