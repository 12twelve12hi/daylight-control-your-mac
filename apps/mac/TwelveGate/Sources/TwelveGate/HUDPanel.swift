import AppKit

/// Small non-activating floating panel in the top-right corner shown during
/// allowlist (meeting) mode. Can briefly flash a warning line.
final class HUDPanel: NSPanel {

    // MARK: - Public

    static let panelSize = NSSize(width: 340, height: 92)

    convenience init() {
        self.init(
            contentRect: NSRect(origin: .zero, size: HUDPanel.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        animationBehavior = .none
        buildContent()
        reposition()
    }

    /// Shows the meeting title (hidden when empty).
    func apply(meetingTitle: String?) {
        let title = (meetingTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        meetingLabel.stringValue = title
        meetingLabel.isHidden = title.isEmpty
    }

    /// Shows `text` for three seconds.
    func flash(_ text: String) {
        flashLabel.stringValue = text
        flashLabel.isHidden = false
        flashTimer?.invalidate()
        let newTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.flashLabel.isHidden = true
            self?.flashLabel.stringValue = ""
            self?.flashTimer = nil
        }
        RunLoop.main.add(newTimer, forMode: .common)
        flashTimer = newTimer
    }

    /// Moves the panel to the top-right corner of the main screen.
    func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - frame.width - 12,
            y: visible.maxY - frame.height - 12
        )
        setFrameOrigin(origin)
    }

    override func close() {
        flashTimer?.invalidate()
        flashTimer = nil
        super.close()
    }

    // MARK: - Private

    private let titleLabel = NSTextField(labelWithString: "Meeting mode — only allowlisted apps")
    private let meetingLabel = NSTextField(labelWithString: "")
    private let flashLabel = NSTextField(wrappingLabelWithString: "")
    private var flashTimer: Timer?

    private func buildContent() {
        let container = NSView(frame: NSRect(origin: .zero, size: HUDPanel.panelSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.12, alpha: 0.94).cgColor
        container.layer?.cornerRadius = 12
        contentView = container

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail

        meetingLabel.font = NSFont.systemFont(ofSize: 12)
        meetingLabel.textColor = NSColor(calibratedWhite: 0.8, alpha: 1)
        meetingLabel.lineBreakMode = .byTruncatingTail
        meetingLabel.isHidden = true

        flashLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        flashLabel.textColor = NSColor(calibratedRed: 1, green: 0.75, blue: 0.4, alpha: 1)
        flashLabel.preferredMaxLayoutWidth = HUDPanel.panelSize.width - 28
        flashLabel.lineBreakMode = .byWordWrapping
        flashLabel.maximumNumberOfLines = 2
        flashLabel.isHidden = true

        let stack = NSStackView(views: [titleLabel, meetingLabel, flashLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: HUDPanel.panelSize.width - 28),
            meetingLabel.widthAnchor.constraint(lessThanOrEqualToConstant: HUDPanel.panelSize.width - 28)
        ])
    }
}
