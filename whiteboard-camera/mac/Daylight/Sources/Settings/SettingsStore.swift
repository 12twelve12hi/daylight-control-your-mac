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

    /// "Follow the pen on camera" (off by default): its own key beside the settings blob until the Kit's `Settings`
    /// carries it; every change reaches the render queue through `FollowPenSwitch` (handoff vp-ink-legibility).
    @Published var followPen: Bool {
        didSet {
            defaults.set(followPen, forKey: FollowPenSwitch.userDefaultsKey)
            followPenSwitch.isOn = followPen
        }
    }

    let defaults: UserDefaults
    let followPenSwitch: FollowPenSwitch
    var onChange: ((Settings) -> Void)?

    init(defaults: UserDefaults = .standard, unsignedBuild: Bool = false, followPenSwitch: FollowPenSwitch = .shared) {
        self.defaults = defaults
        self.followPenSwitch = followPenSwitch
        let follow = defaults.bool(forKey: FollowPenSwitch.userDefaultsKey)
        followPen = follow
        followPenSwitch.isOn = follow
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
