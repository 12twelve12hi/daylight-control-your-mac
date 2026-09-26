import AppKit

// Menu bar app: no Dock icon, no main menu. The AppDelegate owns everything.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = app.setActivationPolicy(.accessory)
app.run()
