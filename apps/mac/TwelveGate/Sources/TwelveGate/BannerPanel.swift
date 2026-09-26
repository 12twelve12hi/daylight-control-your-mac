import AppKit

/// Check-in warning: a non-activating floating panel at the top-center of the
/// main screen with the banner text, a live m:ss countdown to `endsAt`, and
/// an optional "Snooze 15 min" button.
final class BannerPanel: NSPanel {

    // MARK: - Public

    /// Fired when the user clicks "Snooze 15 min".
    var onSnooze: (() -> Void)?

    static let panelSize = NSSize(width: 420, height: 80)

    convenience init() {
        self.init(
            contentRect: NSRect(origin: .zero, size: BannerPanel.panelSize),
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
        isMovableByWindowBackground = true
        animationBehavior = .none
        buildContent()
        reposition()
    }

    /// Updates text, countdown target and snooze visibility.
    func apply(_ info: BannerInfo) {
        textLabel.stringValue = info.text
        endsAt = info.endsAt
        snoozeButton.isHidden = !info.canSnooze
        tick()
        if timer == nil {
            let newTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(newTimer, forMode: .common)
            timer = newTimer
        }
    }

    /// Moves the panel to the top-center of the main screen.
    func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.maxY - frame.height - 12
        )
        setFrameOrigin(origin)
    }

    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }

    // MARK: - Private

    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "0:00")
    private let snoozeButton = NSButton(title: "Snooze 15 min", target: nil, action: nil)
    private var endsAt: Double = 0
    private var timer: Timer?

    private func buildContent() {
        let container = NSView(frame: NSRect(origin: .zero, size: BannerPanel.panelSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.12, alpha: 0.96).cgColor
        container.layer?.cornerRadius = 14
        contentView = container

        textLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        textLabel.textColor = .white
        textLabel.preferredMaxLayoutWidth = 250
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.maximumNumberOfLines = 2
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        countdownLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        countdownLabel.textColor = .white
        countdownLabel.alignment = .right
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false

        snoozeButton.target = self
        snoozeButton.action = #selector(snoozeTapped(_:))
        snoozeButton.controlSize = .small
        snoozeButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        snoozeButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(textLabel)
        container.addSubview(countdownLabel)
        container.addSubview(snoozeButton)

        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            textLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 250),

            countdownLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            countdownLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),

            snoozeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            snoozeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
    }

    private func tick() {
        let remaining = max(0, endsAt / 1000 - Date().timeIntervalSince1970)
        let total = Int(remaining.rounded())
        countdownLabel.stringValue = String(format: "%ld:%02ld", total / 60, total % 60)
    }

    @objc private func snoozeTapped(_ sender: Any?) {
        onSnooze?()
    }
}
