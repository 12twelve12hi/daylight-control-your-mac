// Daylight: the menu-bar host app. Skeleton: a status item with a menu (Open Preview, Quit).
// The frame pipeline, server and camera sink land here in later milestones (docs/ARCHITECTURE.md section 2.3).
import AppKit
import DaylightKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // LSUIElement is also set in Info.plist
app.run()
