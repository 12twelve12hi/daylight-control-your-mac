import AppKit
import DaylightKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Daylight")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Daylight Camera"
        }
        item.menu = makeMenu()
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let header = NSMenuItem(title: "Daylight Camera \(version) (SolStream v\(SolStream.version))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let status = NSMenuItem(title: "Camera extension: not installed yet (skeleton build)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(NSMenuItem.separator())
        let preview = NSMenuItem(title: "Open Preview", action: #selector(openPreview(_:)), keyEquivalent: "p")
        preview.target = self
        menu.addItem(preview)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit Daylight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc private func openPreview(_ sender: Any?) {
        if previewWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "Daylight Camera preview"
            window.isReleasedWhenClosed = false
            window.contentView = PreviewPlaceholderView(frame: window.contentLayoutRect)
            window.center()
            previewWindow = window
        }
        previewWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
