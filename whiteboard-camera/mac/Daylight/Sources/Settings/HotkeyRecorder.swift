import AppKit
import Carbon
import DaylightKit
import SwiftUI

/// Click, then press a chord: records the key code and the Carbon modifier mask of SPEC 14.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var binding: HotkeyBinding
    /// "Already used by another app" or "Already used by <action>"; nil when the chord registered.
    var conflict: String?
    /// The accessibility identifier, `daylight.settings.hotkeys.recorder.<action>` (the UI suite measures each field).
    var identifier = ""

    /// The field's fixed size: SwiftUI grew the view (only an intrinsic size) to about 40 pt tall, with the chord at
    /// the bottom of a tall box and every row twice the needed height (UI test run 37183673841).
    static let size = NSSize(width: 220, height: 24)

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = { keyCode, modifiers in binding = HotkeyBinding(keyCode: keyCode, modifiers: modifiers) }
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.text = (conflict.map { $0 + ": " } ?? "") + HotkeyRecorder.describe(binding)
        view.setAccessibilityLabel(view.text)
        view.setAccessibilityIdentifier(identifier)
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecorderView, context: Context) -> CGSize? {
        return HotkeyRecorder.size
    }

    /// The chord as the menu and onboarding name it, so every key the owner records reads the same everywhere.
    static func describe(_ b: HotkeyBinding) -> String {
        return Hotkeys.describe(b)
    }

    /// Converts AppKit modifier flags into the Carbon mask `RegisterEventHotKey` expects.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= HotkeyBinding.cmdKey }
        if flags.contains(.option) { mask |= HotkeyBinding.optionKey }
        if flags.contains(.control) { mask |= HotkeyBinding.controlKey }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    final class RecorderView: NSView {
        var onRecord: ((UInt32, UInt32) -> Void)?
        var text = ""
        private var recording = false

        override var acceptsFirstResponder: Bool { return true }
        override var intrinsicContentSize: NSSize { return HotkeyRecorder.size }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            recording = true
            needsDisplay = true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            let modifiers = HotkeyRecorder.carbonModifiers(event.modifierFlags)
            guard modifiers != 0 else { return }   // a chord needs at least one modifier
            recording = false
            onRecord?(UInt32(event.keyCode), modifiers)
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            needsDisplay = true
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlBackgroundColor.setFill()
            bounds.fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
            let shown = recording ? "Press the new chord..." : text
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
            // Vertically centred in whatever height the view gets.
            let string = NSAttributedString(string: shown, attributes: attributes)
            let height = string.size().height
            string.draw(at: NSPoint(x: 8, y: ((bounds.height - height) / 2).rounded()))
        }
    }
}
