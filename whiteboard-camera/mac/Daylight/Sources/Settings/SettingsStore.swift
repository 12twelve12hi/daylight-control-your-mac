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

    /// Where "Follow the pen on camera" lived before `Settings.followPen` existed (handoff vp-ink-legibility R2).
    /// Read once by `init` and then removed; nothing writes it any more.
    static let legacyFollowPenKey = "com.twelve.daylight.followPen.v1"

    init(defaults: UserDefaults = .standard, unsignedBuild: Bool = false) {
        self.defaults = defaults
        let data = defaults.data(forKey: Settings.userDefaultsKey)
        let stored = SettingsStore.decode(data)
        var loaded = stored ?? Settings.defaults
        if unsignedBuild && stored == nil {
            loaded.previewOnLaunch = true   // SPEC D19: previewOnLaunch defaults to true on unsigned builds
        }
        let tookLegacyFollowPen = SettingsStore.takeLegacyFollowPen(&loaded, storedData: data, defaults: defaults)
        settings = loaded.validated()
        // The blob carries the migrated value before the old key goes, so an interrupted launch migrates again.
        if tookLegacyFollowPen { persist() }
        defaults.removeObject(forKey: SettingsStore.legacyFollowPenKey)
    }

    static func load(from defaults: UserDefaults) -> Settings? {
        return decode(defaults.data(forKey: Settings.userDefaultsKey))
    }

    static func decode(_ data: Data?) -> Settings? {
        guard let data = data else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    /// R2 migration: a stored blob without a `followPen` key (or no blob at all) takes the old key's true. A blob that
    /// already has the key wins. Returns true when `settings.followPen` was set from the old key. Idempotent: once
    /// `init` has removed the old key this changes nothing.
    static func takeLegacyFollowPen(_ settings: inout Settings, storedData: Data?, defaults: UserDefaults) -> Bool {
        guard defaults.bool(forKey: legacyFollowPenKey), !storedJSONHasKey("followPen", storedData) else { return false }
        settings.followPen = true
        return true
    }

    /// True when `data` is a JSON object with `key` at the top level.
    static func storedJSONHasKey(_ key: String, _ data: Data?) -> Bool {
        guard let data = data,
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any] else { return false }
        return dictionary[key] != nil
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
