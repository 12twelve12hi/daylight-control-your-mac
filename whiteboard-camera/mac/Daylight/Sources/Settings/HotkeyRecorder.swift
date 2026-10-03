import AppKit
import Carbon
import DaylightKit
import SwiftUI

/// Click, then press a chord: records the key code and the Carbon modifier mask of SPEC 14.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var binding: HotkeyBinding
    /// "Already used by another app" or "Already used by <action>"; nil when the chord registered.
    var conflict: String?

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = { keyCode, modifiers in binding = HotkeyBinding(keyCode: keyCode, modifiers: modifiers) }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.text = (conflict.map { $0 + ": " } ?? "") + describe(binding)
        view.needsDisplay = true
    }

    private func describe(_ b: HotkeyBinding) -> String {
        var parts: [String] = []
        if b.modifiers & HotkeyBinding.controlKey != 0 { parts.append("Ctrl") }
        if b.modifiers & HotkeyBinding.optionKey != 0 { parts.append("Opt") }
        if b.modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if b.modifiers & HotkeyBinding.cmdKey != 0 { parts.append("Cmd") }
        parts.append(RecorderView.keyName(b.keyCode))
        return parts.joined(separator: "+")
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
        override var intrinsicContentSize: NSSize { return NSSize(width: 220, height: 24) }

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
            NSAttributedString(string: shown, attributes: attributes).draw(at: NSPoint(x: 8, y: 5))
        }

        static func keyName(_ keyCode: UInt32) -> String {
            switch keyCode {
            case HotkeyBinding.keyW: return "W"
            case HotkeyBinding.keyD: return "D"
            case HotkeyBinding.keyK: return "K"
            case HotkeyBinding.keyC: return "C"
            case HotkeyBinding.keyEscape: return "Esc"
            default: return "Key \(keyCode)"
            }
        }
    }
}
