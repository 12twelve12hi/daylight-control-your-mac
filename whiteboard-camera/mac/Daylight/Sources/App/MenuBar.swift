import AppKit
import DaylightKit
import Foundation

/// The status item and its menu (IMPLEMENTATION-PLAN 5 step 5): rebuilt from `AppModel` every time it opens.
final class MenuBar: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let model: AppModel
    /// Menu bar > Export diagnostics... (AppDelegate hands it to `DiagnosticsExport`).
    var onExportDiagnostics: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        item.menu = menu
        updateIcon()
    }

    func updateIcon() {
        guard let button = item.button else { return }
        let symbol = model.cameraPresent ? "camera" : "video.slash"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Daylight")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Daylight Camera"
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refresh()
        updateIcon()
        menu.removeAllItems()
        addDisabled("Daylight Camera \(model.version) (\(model.build))")
        addDisabled(statusLine())
        if let problem = model.portProblem { addDisabled("● " + problem) }
        if let banner = model.visibleBanner { addDisabled("● " + banner) }
        if let error = model.lastSaveError { addDisabled("● " + error) }
        if let fallback = model.overlayFallbackLine { addDisabled("● " + fallback) }
        if model.nobodyConnectedYet && model.clients.isEmpty { addDisabled(FailureText.sentence(.nobodyConnected)) }
        menu.addItem(NSMenuItem.separator())
        for (index, line) in model.addressLines.enumerated() {
            let address = NSMenuItem(title: line, action: #selector(copyAddress(_:)), keyEquivalent: "")
            address.target = self
            address.representedObject = line
            if index == model.addressLines.count - 1 { address.isEnabled = false }
            menu.addItem(address)
        }
        for pending in model.pending {
            let allow = NSMenuItem(title: FailureText.sentence(.allowDismissed, [pending.label]), action: #selector(allowPending(_:)), keyEquivalent: "")
            allow.target = self
            allow.representedObject = pending.connectionID.uuidString
            menu.addItem(allow)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(inkSourceMenu())
        menu.addItem(holdMenu())
        menu.addItem(NSMenuItem.separator())
        let keep = add("Keep whiteboard", #selector(pin(_:)), hotkey: .keep)
        keep.state = model.governor.pinned ? .on : .off
        add("Clear", #selector(clear(_:)), hotkey: .clear)
        add("Camera", #selector(camera(_:)), hotkey: .camera)
        add("Whiteboard now (Studio Split)", #selector(studioSplit(_:)), hotkey: .studioSplit)
        add("Whiteboard now (Whiteboard Only)", #selector(whiteboardOnly(_:)), hotkey: .whiteboardOnly)
        if model.settings.overlayEnabled {
            add("Whiteboard now (Overlay)", #selector(overlay(_:)), hotkey: .overlay)
        }
        menu.addItem(NSMenuItem.separator())
        let preview = add("Preview window", #selector(togglePreview(_:)), hotkey: nil)
        preview.state = (model.preview?.isVisible ?? false) ? .on : .off
        add("Settings...", #selector(openSettings(_:)), hotkey: nil)
        add("Diagnostics...", #selector(openDiagnostics(_:)), hotkey: nil)
        add("Export diagnostics...", #selector(exportDiagnostics(_:)), hotkey: nil)
        add("Setup again", #selector(setupAgain(_:)), hotkey: nil)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Daylight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func statusLine() -> String {
        let g = model.governor
        var state: String
        switch g.state {
        case .passthrough: state = "Camera"
        case .engaging: state = "Engaging"
        case .live:
            switch g.layout {
            case .whiteboardOnly: state = "Whiteboard Only"
            case .studioSplit: state = "Studio Split"
            case .overlay: state = model.overlayFellBack ? "Studio Split" : "Overlay"
            }
        case .returning: state = "Returning"
        }
        if g.pinned { state += ", pinned" }
        if g.hold != .auto { state += ", hold" }
        let clients = model.clients.filter { $0.allowed }.count
        return "\(state) · \(model.sinkStatusText) · \(clients) tablet\(clients == 1 ? "" : "s") · ink: \(model.settings.inkSource.displayName)"
    }

    private func inkSourceMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Ink source", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, source) in [("Web whiteboard", InkSource.web), ("Daylight Ink app", InkSource.native), ("Mirror the tablet", InkSource.mirror)] {
            let entry = NSMenuItem(title: title, action: #selector(selectSource(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = NSNumber(value: source.rawValue)
            entry.state = model.settings.inkSource == source ? .on : .off
            sub.addItem(entry)
        }
        parent.submenu = sub
        return parent
    }

    private func holdMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Hold", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, mode) in [("Auto", HoldMode.auto), ("Camera", HoldMode.camera), ("Studio Split", HoldMode.split), ("Whiteboard Only", HoldMode.whiteboard)] {
            let entry = NSMenuItem(title: title, action: #selector(selectHold(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = NSNumber(value: mode.rawValue)
            entry.state = model.governor.hold == mode ? .on : .off
            sub.addItem(entry)
        }
        parent.submenu = sub
        return parent
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, hotkey: HotkeyAction?) -> NSMenuItem {
        var label = title
        if let hotkey = hotkey, let binding = model.settings.hotkeys[hotkey] {
            label += "  (\(Hotkeys.describe(binding)))"
        }
        let entry = NSMenuItem(title: label, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    private func addDisabled(_ title: String) {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        menu.addItem(entry)
    }

    // MARK: Actions

    @objc private func pin(_ sender: Any?) { model.pin() }
    @objc private func clear(_ sender: Any?) { model.clear() }
    @objc private func camera(_ sender: Any?) { model.returnToCamera() }
    @objc private func studioSplit(_ sender: Any?) { model.menuWhiteboardNow(.studioSplit) }
    @objc private func whiteboardOnly(_ sender: Any?) { model.menuWhiteboardNow(.whiteboardOnly) }
    @objc private func overlay(_ sender: Any?) { model.menuWhiteboardNow(.overlay) }
    @objc private func openSettings(_ sender: Any?) { model.onOpenSettings?() }
    @objc private func openDiagnostics(_ sender: Any?) { model.onOpenDiagnostics?() }
    @objc private func exportDiagnostics(_ sender: Any?) { onExportDiagnostics?() }
    @objc private func setupAgain(_ sender: Any?) { model.onSetupAgain?() }

    @objc private func togglePreview(_ sender: Any?) {
        guard let preview = model.preview else { return }
        if preview.isVisible { preview.hide() } else { preview.show() }
    }

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard let raw = (sender.representedObject as? NSNumber)?.uint8Value, let source = InkSource(rawValue: raw) else { return }
        model.setInkSource(source)
    }

    @objc private func selectHold(_ sender: NSMenuItem) {
        guard let raw = (sender.representedObject as? NSNumber)?.uint8Value, let mode = HoldMode(rawValue: raw) else { return }
        model.hold(mode)
    }

    @objc private func copyAddress(_ sender: NSMenuItem) {
        guard let line = sender.representedObject as? String, let range = line.range(of: "http://") else { return }
        let url = line[range.lowerBound...].split(separator: " ").first.map(String.init) ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func allowPending(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let id = UUID(uuidString: text),
              let item = model.pending.first(where: { $0.connectionID == id }) else { return }
        model.onAllowRequested?(item)
    }
}
