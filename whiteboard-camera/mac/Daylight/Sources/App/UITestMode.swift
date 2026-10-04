import AppKit
import Foundation

/// `--ui-test-appearance light|dark`.
enum UITestAppearance: String, Equatable {
    case light
    case dark
}

/// `--ui-test-open <surface>`: the surface opened right after launch.
enum UITestSurface: String, Equatable {
    case welcome
    case settings
    case preview
    case diagnostics
    case allow
    case menu
}

/// Everything after `--ui-test` (docs/handoff/vp-mac-ui.md, "Design contract").
struct UITestOptions: Equatable {
    var appearance: UITestAppearance?
    var open: UITestSurface?
    var settingsTab: SettingsTab?
    var overlayEnabled = false
}

/// The `--ui-test` launch: a throwaway defaults suite cleared at every launch, a forced appearance, and the fixture
/// values of the Allow panel. These strings are test fixtures, not owner-facing text.
enum UITestMode {
    static let defaultsSuite = "com.twelve.daylight.uitest"
    static let allowLabel = "UI test tablet"
    static let allowAddress = "192.168.1.40"

    /// Accessibility identifiers the XCUITest suite reads.
    static let welcomeWindowID = "daylight.window.welcome"
    static let settingsWindowID = "daylight.window.settings"
    static let previewWindowID = "daylight.window.preview"
    static let diagnosticsWindowID = "daylight.window.diagnostics"
    static let allowPanelID = "daylight.panel.allow"
    static let statusItemID = "daylight.statusitem"
    /// `PreviewWindow` keeps its NSWindow private (Pipeline/ is another owner's folder); the App side finds it by title.
    static let previewWindowTitle = "Daylight Camera preview"

    /// The suite, emptied, so every UI test launch is a first launch and the runner's real defaults are never read
    /// or written. `UserDefaults(suiteName:)` returns nil only for the global domain or the app's own bundle id,
    /// neither of which this name is, so the `.standard` fallback is not expected to run.
    static func freshDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else { return UserDefaults.standard }
        defaults.removePersistentDomain(forName: defaultsSuite)
        return defaults
    }

    /// `NSApp.appearance` before any window opens; nil leaves the system appearance.
    static func apply(_ appearance: UITestAppearance?) {
        guard let appearance = appearance else { return }
        switch appearance {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Tags the preview window, found by its title among the app's windows.
    static func tagPreviewWindow() {
        for window in NSApp.windows where window.title == previewWindowTitle {
            window.setAccessibilityIdentifier(previewWindowID)
        }
    }
}
