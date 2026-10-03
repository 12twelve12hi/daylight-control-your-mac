import Combine
import DaylightKit
import Foundation
import ServiceManagement

/// One JSON blob under `UserDefaults` key `com.twelve.daylight.settings.v1` (SPEC section 3). Observable on main;
/// `apply` closures let the app react to changes. `holdMode` is never persisted (the Kit's CodingKeys omit it).
final class SettingsStore: ObservableObject {
    @Published var settings: Settings {
        didSet {
            let validated = settings.validated()
            if validated != settings {
                settings = validated
                return
            }
            persist()
            onChange?(settings)
        }
    }

    let defaults: UserDefaults
    var onChange: ((Settings) -> Void)?

    init(defaults: UserDefaults = .standard, unsignedBuild: Bool = false) {
        self.defaults = defaults
        var loaded = SettingsStore.load(from: defaults) ?? Settings.defaults
        if unsignedBuild && SettingsStore.load(from: defaults) == nil {
            loaded.previewOnLaunch = true   // SPEC D19: previewOnLaunch defaults to true on unsigned builds
        }
        settings = loaded.validated()
    }

    static func load(from defaults: UserDefaults) -> Settings? {
        guard let data = defaults.data(forKey: Settings.userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(settings) {
            defaults.set(data, forKey: Settings.userDefaultsKey)
        }
    }

    /// `SMAppService.mainApp` is read live (SPEC 11, `launchAtLogin`).
    var launchAtLogin: Bool {
        return SMAppService.mainApp.status == .enabled
    }

    var launchAtLoginRequiresApproval: Bool {
        return SMAppService.mainApp.status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        objectWillChange.send()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
