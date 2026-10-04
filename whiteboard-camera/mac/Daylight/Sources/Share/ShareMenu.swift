import AppKit
import Foundation

/// menu bar > "Share the whiteboard" (docs/product/TOO-SMALL.md section 8): show the share window, how to share it in a
/// call, the Share settings. Built fresh every time the status menu opens (MenuBar.shareMenu).
final class ShareMenu: NSObject {
    static let parentTitle = "Share the whiteboard"
    static let showTitle = "Show share window"
    static let howToTitle = "How to share it in a call..."
    static let settingsTitle = "Share settings..."

    let controller: ShareWindowController
    var onOpenSettings: (() -> Void)?

    init(controller: ShareWindowController) {
        self.controller = controller
        super.init()
    }

    func makeItem() -> NSMenuItem {
        let parent = NSMenuItem(title: ShareMenu.parentTitle, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let show = NSMenuItem(title: ShareMenu.showTitle, action: #selector(toggleWindow(_:)), keyEquivalent: "")
        show.target = self
        show.state = controller.isVisible ? .on : .off
        sub.addItem(show)
        let howTo = NSMenuItem(title: ShareMenu.howToTitle, action: #selector(showHowTo(_:)), keyEquivalent: "")
        howTo.target = self
        sub.addItem(howTo)
        let settings = NSMenuItem(title: ShareMenu.settingsTitle, action: #selector(openSettings(_:)), keyEquivalent: "")
        settings.target = self
        sub.addItem(settings)
        parent.submenu = sub
        return parent
    }

    @objc private func toggleWindow(_ sender: Any?) { controller.toggle() }
    @objc private func openSettings(_ sender: Any?) { onOpenSettings?() }

    @objc private func showHowTo(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = ShareGuide.heading
        alert.informativeText = ShareGuide.text
        alert.addButton(withTitle: "Show share window")
        alert.addButton(withTitle: "Close")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { controller.show(activate: true) }
    }
}

/// The how-to the menu shows, per call app. Kept here (not in FailureText: it is guidance, not a failure) and quoted by
/// docs/OWNER-NEXT-STEPS.md step 9. Every path is the call app's own wording as of 2026-10 (TOO-SMALL.md section 3).
enum ShareGuide {
    static let heading = "Make the whiteboard big in a group call"
    static let zoom = "Zoom: Share Screen (Command-Shift-S), pick the window \"Daylight Whiteboard\", then Share."
    static let meet = "Google Meet: Present now (also labelled Share screen), A window, pick \"Daylight Whiteboard\", then Share."
    static let teams = "Teams: Share (Command-Shift-E), Window, pick \"Daylight Whiteboard\"."
    static let other = "Slack huddles and Webex: share a window the same way. Your camera tile stays as it is."
    static let tip = "Leave the window open behind the call (covered is fine, minimised pauses it). Stop sharing when you are done."
    static var text: String {
        return [zoom, meet, teams, other, tip].joined(separator: "\n\n")
    }
}
