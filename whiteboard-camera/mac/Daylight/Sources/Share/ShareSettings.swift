import Combine
import Foundation

/// The share window's own settings (docs/product/TOO-SMALL.md section 8), one JSON blob under its own UserDefaults key
/// so the Kit `Settings` schema (SPEC 3) is untouched. Missing keys decode to the defaults.
struct ShareSettings: Codable, Equatable {
    /// Keep the share window above other windows (off: an ordinary window the owner can put behind the call).
    var floats = false
    /// Hide the title bar so viewers see only the page (UNVERIFIED that every call app lists a borderless window).
    var hideTitleBar = false
    /// Open the share window by itself when the whiteboard slides in (it never takes focus).
    var openWithBoard = false

    static let userDefaultsKey = "com.twelve.daylight.share.v1"
    static let defaults = ShareSettings()

    init(floats: Bool = false, hideTitleBar: Bool = false, openWithBoard: Bool = false) {
        self.floats = floats
        self.hideTitleBar = hideTitleBar
        self.openWithBoard = openWithBoard
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        floats = (try? c.decode(Bool.self, forKey: .floats)) ?? false
        hideTitleBar = (try? c.decode(Bool.self, forKey: .hideTitleBar)) ?? false
        openWithBoard = (try? c.decode(Bool.self, forKey: .openWithBoard)) ?? false
    }
}

/// Observable on main; `onChange` lets the share window follow a change at once.
final class ShareSettingsStore: ObservableObject {
    @Published var settings: ShareSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
            onChange?(settings)
        }
    }

    /// `--ui-test` keeps the share settings in their own throwaway suite (the main one is UITestMode's).
    static let uiTestSuite = "com.twelve.daylight.uitest.share"

    let defaults: UserDefaults
    var onChange: ((ShareSettings) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = ShareSettingsStore.load(from: defaults) ?? .defaults
    }

    static func load(from defaults: UserDefaults) -> ShareSettings? {
        guard let data = defaults.data(forKey: ShareSettings.userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(ShareSettings.self, from: data)
    }

    func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(settings) { defaults.set(data, forKey: ShareSettings.userDefaultsKey) }
    }
}
