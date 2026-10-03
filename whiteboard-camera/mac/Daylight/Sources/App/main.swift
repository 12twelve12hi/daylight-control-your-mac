// Daylight: the menu-bar host app (AppKit lifecycle, ARCHITECTURE section 18). `--self-test` runs the SPEC B1 probes
// and exits before any window or status item exists.
import AppKit
import DaylightKit

let launchArguments = LaunchArguments.parse(CommandLine.arguments)
if launchArguments.selfTest {
    exit(SelfTest.run(launchArguments))
}

let app = NSApplication.shared
let delegate = AppDelegate(arguments: launchArguments)
app.delegate = delegate
app.setActivationPolicy(.accessory)   // LSUIElement is also set in Info.plist
app.run()
