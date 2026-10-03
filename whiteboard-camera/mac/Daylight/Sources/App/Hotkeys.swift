import Carbon
import DaylightKit
import Foundation

enum HotkeyError: Error, Equatable {
    /// `eventHotKeyExistsErr` from an exclusive registration: another app holds the chord exclusively.
    case alreadyUsed(HotkeyAction)
    /// The chord is bound to another Daylight action; one application cannot register a chord twice.
    case duplicate(HotkeyAction, HotkeyAction)
    case registration(HotkeyAction, OSStatus)
}

/// Global hotkeys through Carbon `RegisterEventHotKey` (SPEC 14): no Accessibility permission, works in an
/// LSUIElement app. Defaults Ctrl+Opt+Cmd + W / D / K / C / Esc. Main thread only.
final class Hotkeys {
    static let signature: OSType = Hotkeys.fourCharCode("dylt")
    /// `eventHotKeyExistsErr`: the combination is taken (by another Daylight action, or by another app registering it
    /// exclusively).
    static let alreadyUsedStatus: OSStatus = -9878
    /// `kEventHotKeyExclusive` (CarbonEvents.h, `1 << 0`): without it `RegisterEventHotKey` never reports a chord
    /// another application holds (both apps simply receive it), so "Already used by another app" could never be true.
    static let exclusiveOption: OptionBits = 1

    var onAction: ((HotkeyAction) -> Void)?
    private(set) var bindings: [HotkeyAction: HotkeyBinding]
    private var references: [HotkeyAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    /// Actions whose chord could not be registered, with the reason the Settings window shows.
    private(set) var conflicts: [HotkeyAction: HotkeyError] = [:]

    /// The Settings text for each conflict.
    var conflictTexts: [HotkeyAction: String] {
        return conflicts.mapValues { Hotkeys.conflictText($0) }
    }

    static func conflictText(_ error: HotkeyError) -> String {
        switch error {
        case let .duplicate(_, other): return "Already used by \(title(other))"
        case .alreadyUsed: return "Already used by another app"
        case let .registration(_, status): return "Could not register (\(status))"
        }
    }

    /// Another action already bound to the same chord, if any (pure; unit-tested).
    static func duplicate(of action: HotkeyAction, binding: HotkeyBinding, in bindings: [HotkeyAction: HotkeyBinding]) -> HotkeyAction? {
        return HotkeyAction.allCases.first { $0 != action && bindings[$0] == binding }
    }

    init(settings: Settings) {
        bindings = settings.validated().hotkeys
    }

    deinit {
        unregisterAll()
        if let handler = handler { RemoveEventHandler(handler) }
    }

    /// The action behind a hotkey id (ids are the action's index in `HotkeyAction.allCases` plus 1).
    static func action(forID id: UInt32) -> HotkeyAction? {
        let cases = HotkeyAction.allCases
        guard id >= 1, Int(id) <= cases.count else { return nil }
        return cases[Int(id) - 1]
    }

    static func id(for action: HotkeyAction) -> UInt32 {
        return UInt32((HotkeyAction.allCases.firstIndex(of: action) ?? 0) + 1)
    }

    static func fourCharCode(_ text: String) -> OSType {
        var code: OSType = 0
        for byte in text.utf8.prefix(4) {
            code = code << 8 | OSType(byte)
        }
        return code
    }

    /// Human-readable chord, e.g. "Ctrl+Opt+Cmd+W".
    static func describe(_ binding: HotkeyBinding) -> String {
        var parts: [String] = []
        if binding.modifiers & HotkeyBinding.controlKey != 0 { parts.append("Ctrl") }
        if binding.modifiers & HotkeyBinding.optionKey != 0 { parts.append("Opt") }
        if binding.modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if binding.modifiers & HotkeyBinding.cmdKey != 0 { parts.append("Cmd") }
        parts.append(keyName(binding.keyCode))
        return parts.joined(separator: "+")
    }

    static func keyName(_ keyCode: UInt32) -> String {
        switch keyCode {
        case HotkeyBinding.keyW: return "W"
        case HotkeyBinding.keyD: return "D"
        case HotkeyBinding.keyK: return "K"
        case HotkeyBinding.keyC: return "C"
        case HotkeyBinding.keyEscape: return "Esc"
        case 0x00: return "A"
        case 0x0B: return "B"
        case 0x0E: return "E"
        case 0x03: return "F"
        case 0x05: return "G"
        case 0x04: return "H"
        case 0x22: return "I"
        case 0x26: return "J"
        case 0x25: return "L"
        case 0x2E: return "M"
        case 0x2D: return "N"
        case 0x1F: return "O"
        case 0x23: return "P"
        case 0x0C: return "Q"
        case 0x0F: return "R"
        case 0x01: return "S"
        case 0x11: return "T"
        case 0x20: return "U"
        case 0x09: return "V"
        case 0x07: return "X"
        case 0x10: return "Y"
        case 0x06: return "Z"
        case 0x31: return "Space"
        case 0x24: return "Return"
        default: return "Key \(keyCode)"
        }
    }

    static func title(_ action: HotkeyAction) -> String {
        switch action {
        case .whiteboardOnly: return "Whiteboard Only"
        case .studioSplit: return "Studio Split"
        case .keep: return "Keep whiteboard"
        case .clear: return "Clear"
        case .camera: return "Camera"
        }
    }

    // MARK: Registration

    /// Registers every binding; conflicts are collected in `conflicts` and the rest still work.
    func registerAll() {
        installHandlerIfNeeded()
        for action in HotkeyAction.allCases {
            guard let binding = bindings[action] else { continue }
            do {
                try register(action, binding: binding)
            } catch {
                conflicts[action] = (error as? HotkeyError) ?? .registration(action, -1)
            }
        }
    }

    func unregisterAll() {
        for reference in references.values {
            UnregisterEventHotKey(reference)
        }
        references.removeAll()
    }

    func rebind(_ action: HotkeyAction, keyCode: UInt32, modifiers: UInt32) throws {
        let binding = HotkeyBinding(keyCode: keyCode, modifiers: modifiers)
        if let existing = references[action] {
            UnregisterEventHotKey(existing)
            references[action] = nil
        }
        bindings[action] = binding
        installHandlerIfNeeded()
        do {
            try register(action, binding: binding)
        } catch {
            conflicts[action] = (error as? HotkeyError) ?? .registration(action, -1)
            throw error
        }
        // A chord freed by this rebind may unblock an action that was reported as its duplicate.
        for other in HotkeyAction.allCases where other != action && conflicts[other] != nil && references[other] == nil {
            if let otherBinding = bindings[other] { try? register(other, binding: otherBinding) }
        }
    }

    private func register(_ action: HotkeyAction, binding: HotkeyBinding) throws {
        if let other = Hotkeys.duplicate(of: action, binding: binding, in: bindings), references[other] != nil {
            throw HotkeyError.duplicate(action, other)
        }
        let hotKeyID = EventHotKeyID(signature: Hotkeys.signature, id: Hotkeys.id(for: action))
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, hotKeyID, GetEventDispatcherTarget(), Hotkeys.exclusiveOption, &reference)
        if status == Hotkeys.alreadyUsedStatus { throw HotkeyError.alreadyUsed(action) }
        guard status == noErr, let created = reference else { throw HotkeyError.registration(action, status) }
        references[action] = created
        conflicts[action] = nil
    }

    private func installHandlerIfNeeded() {
        if handler != nil { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var installed: EventHandlerRef?
        let status = InstallEventHandler(GetEventDispatcherTarget(), hotkeyCallback, 1, &spec, userData, &installed)
        if status == noErr { handler = installed }
    }

    fileprivate func dispatch(id: UInt32) {
        guard let action = Hotkeys.action(forID: id) else { return }
        onAction?(action)
    }
}

/// C callback for Carbon; `userData` is the unretained `Hotkeys` instance.
private func hotkeyCallback(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == Hotkeys.signature else { return OSStatus(eventNotHandledErr) }
    let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
    hotkeys.dispatch(id: hotKeyID.id)
    return noErr
}
