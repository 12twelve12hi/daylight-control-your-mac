import AppKit
import CoreGraphics

// MARK: - ShieldWindow

/// One full-screen, borderless shield per display. Created and destroyed by
/// the LockController; updated in place from every StateSnapshot.
final class ShieldWindow: NSWindow {

    /// Fired with the reason once the user completes the emergency unlock.
    var onEmergencyUnlock: ((String) -> Void)? {
        get { return shieldView?.onEmergencyUnlock }
        set { shieldView?.onEmergencyUnlock = newValue }
    }

    private var shieldView: ShieldContentView?

    convenience init(screen: NSScreen, holdSeconds: Int) {
        self.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = ShieldContentView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            holdSeconds: holdSeconds
        )
        shieldView = view
        contentView = view
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = true
        backgroundColor = ShieldContentView.backgroundColor
        hasShadow = false
        isMovable = false
        animationBehavior = .none
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool {
        return true
    }

    override var canBecomeMain: Bool {
        return true
    }

    override func close() {
        shieldView?.stop()
        super.close()
    }

    func apply(state: StateSnapshot, connected: Bool) {
        shieldView?.apply(state: state, connected: connected)
    }

    func setConnected(_ connected: Bool) {
        shieldView?.setConnected(connected)
    }
}

// MARK: - ShieldContentView

/// Centered title/body/clock/status/meeting lines with the emergency unlock
/// controls anchored at the bottom.
final class ShieldContentView: NSView {

    static let backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)

    var onEmergencyUnlock: ((String) -> Void)? {
        get { return emergencyView.onUnlock }
        set { emergencyView.onUnlock = newValue }
    }

    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let meetingLabel = NSTextField(wrappingLabelWithString: "")
    private let clockLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let emergencyView: EmergencyUnlockView
    private var clockTimer: Timer?
    private let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()

    init(frame: NSRect, holdSeconds: Int) {
        emergencyView = EmergencyUnlockView(holdSeconds: holdSeconds)
        super.init(frame: frame)
        buildLayout()
        startClock()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Updates

    func apply(state: StateSnapshot, connected: Bool) {
        titleLabel.stringValue = state.shield?.title ?? "Your Mac is waiting for your Daylight."
        let body = state.shield?.body ?? ""
        bodyLabel.stringValue = body
        bodyLabel.isHidden = body.isEmpty
        if let meeting = state.meeting {
            meetingLabel.stringValue = "Meeting: \(meeting.title)"
            meetingLabel.isHidden = false
        } else {
            meetingLabel.isHidden = true
        }
        setConnected(connected)
    }

    func setConnected(_ connected: Bool) {
        statusLabel.stringValue = connected ? "Connected to Twelve" : "Reconnecting…"
    }

    /// Invalidates every timer owned by this view. Called when the window closes.
    func stop() {
        clockTimer?.invalidate()
        clockTimer = nil
        emergencyView.stop()
    }

    // MARK: Layout

    private func buildLayout() {
        autoresizingMask = [.width, .height]

        styleLabel(titleLabel, font: NSFont.systemFont(ofSize: 40, weight: .semibold), white: 1.0, wraps: true)
        styleLabel(bodyLabel, font: NSFont.systemFont(ofSize: 20, weight: .light), white: 0.85, wraps: true)
        styleLabel(meetingLabel, font: NSFont.systemFont(ofSize: 16, weight: .regular), white: 0.75, wraps: true)
        styleLabel(clockLabel, font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular), white: 0.6, wraps: false)
        styleLabel(statusLabel, font: NSFont.systemFont(ofSize: 14, weight: .regular), white: 0.5, wraps: false)
        bodyLabel.isHidden = true
        meetingLabel.isHidden = true

        let stack = NSStackView(views: [titleLabel, bodyLabel, meetingLabel, clockLabel, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        emergencyView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emergencyView)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),

            emergencyView.centerXAnchor.constraint(equalTo: centerXAnchor),
            emergencyView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -48),
            emergencyView.widthAnchor.constraint(equalToConstant: 420)
        ])
    }

    private func styleLabel(_ label: NSTextField, font: NSFont, white: CGFloat, wraps: Bool) {
        label.font = font
        label.textColor = NSColor(calibratedWhite: white, alpha: 1)
        label.alignment = .center
        if wraps {
            label.preferredMaxLayoutWidth = 720
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
        }
    }

    // MARK: Clock

    private func startClock() {
        updateClock()
        let newTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateClock()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        clockTimer = newTimer
    }

    private func updateClock() {
        clockLabel.stringValue = clockFormatter.string(from: Date())
    }
}

// MARK: - EmergencyUnlockView

/// Hold button + progress bar; after a full hold, a reason field and the
/// unlock button appear. The reason must be at least `minReasonChars` long.
final class EmergencyUnlockView: NSView {

    /// Fired with the trimmed reason when the user clicks "Unlock for 30 minutes".
    var onUnlock: ((String) -> Void)?

    private let minReasonChars = 10
    private let holdButton: HoldButton
    private let progress = NSProgressIndicator()
    private let hintLabel = NSTextField(labelWithString: "Why? (at least 10 characters)")
    private let reasonField = NSTextField()
    private let unlockButton = NSButton(title: "Unlock for 30 minutes", target: nil, action: nil)
    private let stack = NSStackView()

    init(holdSeconds: Int) {
        holdButton = HoldButton(
            title: "Hold for \(holdSeconds) s to unlock in an emergency",
            holdSeconds: holdSeconds
        )
        super.init(frame: .zero)
        buildLayout(holdSeconds: holdSeconds)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reasonChanged(_:)),
            name: NSControl.textDidChangeNotification,
            object: reasonField
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Cancels a hold in progress and hides the reason form.
    func stop() {
        holdButton.stop()
        setReasonVisible(false)
    }

    // MARK: Layout

    private func buildLayout(holdSeconds: Int) {
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(holdSeconds)
        progress.doubleValue = 0
        progress.controlSize = .small

        hintLabel.font = NSFont.systemFont(ofSize: 13)
        hintLabel.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        hintLabel.alignment = .center

        reasonField.font = NSFont.systemFont(ofSize: 14)
        reasonField.placeholderString = "What is the emergency?"

        unlockButton.target = self
        unlockButton.action = #selector(unlockTapped(_:))
        unlockButton.isEnabled = false

        holdButton.onProgress = { [weak self] seconds in
            self?.progress.doubleValue = seconds
        }
        holdButton.onComplete = { [weak self] in
            self?.revealReason()
        }
        holdButton.onCancel = { [weak self] in
            self?.progress.doubleValue = 0
        }

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(holdButton)
        stack.addArrangedSubview(progress)
        stack.addArrangedSubview(hintLabel)
        stack.addArrangedSubview(reasonField)
        stack.addArrangedSubview(unlockButton)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            holdButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            holdButton.heightAnchor.constraint(equalToConstant: 44),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            reasonField.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        setReasonVisible(false)
    }

    // MARK: Reason form

    private func revealReason() {
        setReasonVisible(true)
        _ = window?.makeFirstResponder(reasonField)
    }

    private func setReasonVisible(_ visible: Bool) {
        hintLabel.isHidden = !visible
        reasonField.isHidden = !visible
        unlockButton.isHidden = !visible
        if !visible {
            reasonField.stringValue = ""
            unlockButton.isEnabled = false
            progress.doubleValue = 0
        }
    }

    private var trimmedReason: String {
        return reasonField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func reasonChanged(_ notification: Notification) {
        unlockButton.isEnabled = trimmedReason.count >= minReasonChars
    }

    @objc private func unlockTapped(_ sender: Any?) {
        let reason = trimmedReason
        guard reason.count >= minReasonChars else { return }
        onUnlock?(reason)
        setReasonVisible(false)
    }
}
