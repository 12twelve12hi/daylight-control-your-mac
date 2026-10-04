import SwiftUI

/// Settings > Share (docs/product/TOO-SMALL.md section 8). Every row here works today; the second camera device and
/// follow the pen are scoped in docs/handoff/vp-too-small.md and get their rows when they ship.
struct ShareSettingsView: View {
    @ObservedObject var store: ShareSettingsStore
    var showWindow: () -> Void = {}

    var body: some View {
        Form {
            Text("A shared window fills everyone's main stage; a camera tile never does. Share the \"Daylight Whiteboard\" window in Zoom, Meet, Teams, Slack or Webex.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Open the share window when the whiteboard slides in", isOn: $store.settings.openWithBoard)
            Toggle("Keep the share window above other windows", isOn: $store.settings.floats)
            Toggle("Hide the share window's title bar", isOn: $store.settings.hideTitleBar)
            Button("Show share window") { showWindow() }
                .accessibilityIdentifier(SettingsTab.share.lastElementID)
        }
        .padding()
    }

}
