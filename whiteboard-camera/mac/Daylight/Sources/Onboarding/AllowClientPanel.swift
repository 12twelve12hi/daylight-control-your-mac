import AppKit
import DaylightKit
import Foundation

/// "Allow 'Mike's DC-1' to draw on Daylight Camera? It connected from 192.168.1.40." (SPEC 9.5, D44): a
/// non-activating floating panel at the top right, Allow / Not now, 60 s auto-dismiss. Dismissing never denies; the
/// menu item mirrors the prompt while the connection stays pending. Main thread only.
final class AllowClientPanel: NSPanel {
    static let autoDismissSeconds: Double = 60
    static let width: CGFloat = 420
    static let height: CGFloat = 120

    var onAllow: (() -> Void)?
    var onNotNow: (() -> Void)?
    var onDismissed: (() -> Void)?
    private var dismissWork: DispatchWorkItem?
    private let messageLabel = NSTextField(wrappingLabelWithString: "")

    static func prompt(label: String, address: String) -> String {
        return "Allow '\(label)' to draw on Daylight Camera? It connected from \(address)."
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: AllowClientPanel.width, height: AllowClientPanel.height),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false)
        title = "Daylight"
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        buildContent()
    }

    private func buildContent() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: AllowClientPanel.width, height: AllowClientPanel.height))
        messageLabel.font = NSFont.systemFont(ofSize: 13)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(messageLabel)
        let allow = NSButton(title: "Allow", target: self, action: #selector(allowClicked(_:)))
        allow.keyEquivalent = "\r"
        allow.translatesAutoresizingMaskIntoConstraints = false
        let notNow = NSButton(title: "Not now", target: self, action: #selector(notNowClicked(_:)))
        notNow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(allow)
        content.addSubview(notNow)
        NSLayoutConstraint.activate([
            messageLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            messageLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            allow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            allow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            notNow.trailingAnchor.constraint(equalTo: allow.leadingAnchor, constant: -8),
            notNow.bottomAnchor.constraint(equalTo: allow.bottomAnchor),
        ])
        contentView = content
    }

    /// Shows the prompt at the top right of the main screen without stealing focus from the call.
    func show(label: String, address: String) {
        messageLabel.stringValue = AllowClientPanel.prompt(label: label, address: address)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.maxX - AllowClientPanel.width - 16, y: frame.maxY - AllowClientPanel.height - 16)
            setFrameOrigin(origin)
        }
        orderFrontRegardless()
        armDismiss()
    }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        orderOut(nil)
    }

    private func armDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isVisible else { return }
            self.orderOut(nil)
            self.onDismissed?()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AllowClientPanel.autoDismissSeconds, execute: work)
    }

    @objc private func allowClicked(_ sender: Any?) {
        dismiss()
        onAllow?()
    }

    @objc private func notNowClicked(_ sender: Any?) {
        dismiss()
        onNotNow?()
    }
}
