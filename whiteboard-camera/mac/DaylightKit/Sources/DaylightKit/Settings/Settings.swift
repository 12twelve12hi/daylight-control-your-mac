import Foundation

/// Hotkey actions (SPEC section 14). Raw values are the JSON keys of `Settings.hotkeys`.
/// The Carbon hotkey id is the index in `allCases` plus 1, so new actions are appended last.
public enum HotkeyAction: String, Codable, CaseIterable, CodingKeyRepresentable {
    case whiteboardOnly
    case studioSplit
    case keep
    case clear
    case camera
    /// Overlay layout (SPEC 6.7); registered only while `Settings.overlayEnabled`.
    case overlay
}

/// A Carbon hotkey: virtual key code plus modifier mask (cmdKey 1<<8, optionKey 1<<11, controlKey 1<<12).
public struct HotkeyBinding: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let cmdKey: UInt32 = 1 << 8
    public static let optionKey: UInt32 = 1 << 11
    public static let controlKey: UInt32 = 1 << 12
    /// Ctrl+Opt+Cmd, the default chord.
    public static let defaultModifiers: UInt32 = cmdKey | optionKey | controlKey

    public static let keyW: UInt32 = 0x0D
    public static let keyD: UInt32 = 0x02
    public static let keyK: UInt32 = 0x28
    public static let keyC: UInt32 = 0x08
    public static let keyEscape: UInt32 = 0x35
    /// kVK_ANSI_O, the Overlay hotkey.
    public static let keyO: UInt32 = 0x1F
}

public enum MirrorPinClearMode: String, Codable {
    case pills
    case penButton
    case both

    public var includesPills: Bool { return self != .penButton }
    public var includesPenButton: Bool { return self != .pills }
}

public enum PillsPosition: String, Codable {
    case top
    case bottom
}

public enum AdbServerMode: String, Codable {
    case auto
    case shared
    case privatePort
}

/// Settings > Mirror > adb source (LOOSE_ENDS H1): where the adb executable comes from. Raw values are the SPEC 11 values.
public enum AdbSource: String, Codable, CaseIterable {
    case bundled
    case download
    case installed

    /// The Settings picker label.
    public var label: String {
        switch self {
        case .bundled: return "Bundled (default)"
        case .download: return "Download on first use"
        case .installed: return "Use installed adb"
        }
    }

    /// The effective source on a build that may ship without the bundled adb (`DaylightBundlesAdb` false):
    /// Bundled becomes Download there, every other choice stays.
    public func effective(bundledAvailable: Bool) -> AdbSource {
        return (self == .bundled && !bundledAvailable) ? .download : self
    }
}

/// Settings > Mirror > Transport (PROTOCOL 14, LOOSE_ENDS A9): scrcpy over adb, or Daylight Ink's own screen stream.
public enum MirrorTransport: String, Codable, CaseIterable {
    case usb
    case wifiStream

    /// The Settings picker label.
    public var label: String {
        switch self {
        case .usb: return "USB (adb)"
        case .wifiStream: return "Wi-Fi (Daylight Ink screen stream)"
        }
    }
}

/// Persisted user settings (SPEC section 11). Property names equal the SPEC keys verbatim.
/// Stored as one JSON blob under `UserDefaults` key `userDefaultsKey`; `holdMode` is never persisted.
/// Decoding tolerates missing keys (every absent key keeps its default) so older blobs load after an upgrade.
public struct Settings: Codable, Equatable {
    public static let userDefaultsKey = "com.twelve.daylight.settings.v1"
    public static let documentsFolderName = "Daylight Camera"
    public static let clientsFileName = "clients.json"
    public static let applicationSupportFolderName = "Daylight"

    public var onboardingDone: Bool = false
    public var onboardingVersion: Int = 1
    public var cameraUniqueID: String? = nil
    public var inkSource: InkSource = .web
    public var preferredLayout: LayoutStyle = .studioSplit
    /// Not persisted across launches.
    public var holdMode: HoldMode = .auto
    public var autoEngage: Bool = true
    public var idleTimeoutSeconds: Int = 90
    public var preWarningSeconds: Int = 5
    public var springK: Double = 1200
    public var engageOnEraser: Bool = false
    public var hotkeys: [HotkeyAction: HotkeyBinding] = Settings.defaultHotkeys
    public var port: UInt16 = SolStream.defaultPort
    /// nil means "Daylight Camera on <hostname>", resolved by the app.
    public var bonjourName: String? = nil
    public var trustLoopback: Bool = true
    public var mirrorPinClearMode: MirrorPinClearMode = .both
    public var sideButtonDoublePressMs: Int = 400
    public var sideButtonLongPressMs: Int = 700
    public var sideButtonSwap: Bool = false
    public var mirrorCropInsetsPortrait: CropInsets = CropInsets(top: 96, left: 0, right: 0, bottom: 0)
    public var mirrorCropInsetsLandscape: CropInsets = CropInsets(top: 72, left: 0, right: 0, bottom: 0)
    public var pillStripHeight: Int = 96
    public var mirrorPillsPosition: PillsPosition = .top
    public var mirrorMaxSize: Int = 1600
    public var mirrorBitRate: Int = 8_000_000
    public var mirrorMaxFps: Int = 30
    public var mirrorDeviceSerial: String? = nil
    public var adbServerMode: AdbServerMode = .auto
    public var adbPrivatePort: UInt16 = 27180
    /// LOOSE_ENDS H1. An unknown stored value decodes as `.bundled`.
    public var adbSource: AdbSource = .bundled
    /// The platform-tools version whose Android SDK License terms the owner accepted (Download on first use); nil until Accept.
    public var adbTermsAcceptedVersion: String? = nil
    public var mirrorOverWiFi: Bool = false
    public var viewerIdleStopSeconds: Int = 60
    /// nil means ~/Documents/Daylight Camera (resolved by the app).
    public var saveDirectory: URL? = nil
    public var saveStrokesJSON: Bool = true
    public var autosaveSeconds: Int = 60
    /// false in the defaults; the app flips it to true on an unsigned build (SPEC D19).
    public var previewOnLaunch: Bool = false
    public var previewFloats: Bool = true
    public var frameReuse: Bool = false
    public var deadlineIdle: Bool = false
    public var perfLog: Bool = false
    // Mirror over Wi-Fi (Daylight Ink screen stream, PROTOCOL 14.4 ranges).
    public var mirrorTransport: MirrorTransport = .usb
    public var mirrorStreamMaxSize: Int = 1600
    public var mirrorStreamBitRate: Int = 7_000_000
    public var mirrorStreamMaxFps: Int = 30
    public var mirrorStreamKeyIntervalMs: Int = 2000
    /// `FrameDiffEngage.Config.changedFraction`.
    public var mirrorDiffThreshold: Double = 0.002
    // Presenter Overlay (SPEC 6.7, v2, off by default).
    public var overlayEnabled: Bool = false
    /// An unknown stored value decodes as `.fast`.
    public var overlayQuality: OverlayQuality = .fast
    /// Temporal mask smoothing, `OverlayLayout.smoothed` (0 none, 0.9 heavy).
    public var overlaySmoothing: Double = 0.6
    /// Edge softness in mask texels (feather blur radius).
    public var overlayFeather: Int = 2
    /// Amber outline around the person.
    public var overlayHalo: Bool = false
    /// Cutout side as a fraction of the output height.
    public var overlayScale: Double = OverlayLayout.defaultHeightFraction
    /// An unknown stored value decodes as `.bottomRight`.
    public var overlayPosition: OverlayPosition = .bottomRight
    public var overlayOpacity: Double = 1.0
    /// Settings > Advanced "Follow the pen on camera" (TOO-SMALL section 7), off by default. Read once per frame by
    /// the render queue; before this key existed it lived under `com.twelve.daylight.followPen.v1` (the app migrates it).
    public var followPen: Bool = false

    public init() {}

    public static let defaults = Settings()

    public static let defaultHotkeys: [HotkeyAction: HotkeyBinding] = [
        .whiteboardOnly: HotkeyBinding(keyCode: HotkeyBinding.keyW, modifiers: HotkeyBinding.defaultModifiers),
        .studioSplit: HotkeyBinding(keyCode: HotkeyBinding.keyD, modifiers: HotkeyBinding.defaultModifiers),
        .keep: HotkeyBinding(keyCode: HotkeyBinding.keyK, modifiers: HotkeyBinding.defaultModifiers),
        .clear: HotkeyBinding(keyCode: HotkeyBinding.keyC, modifiers: HotkeyBinding.defaultModifiers),
        .camera: HotkeyBinding(keyCode: HotkeyBinding.keyEscape, modifiers: HotkeyBinding.defaultModifiers),
        .overlay: HotkeyBinding(keyCode: HotkeyBinding.keyO, modifiers: HotkeyBinding.defaultModifiers),
    ]

    /// The "Low bandwidth" mirror preset (SPEC section 11): 1200 / 4000000 / 24.
    public static let lowBandwidthMirror: (maxSize: Int, bitRate: Int, maxFps: Int) = (1200, 4_000_000, 24)

    // MARK: Ranges (SPEC section 11)

    public static let idleTimeoutRange = 15...600
    public static let preWarningRange = 0...30
    public static let springKRange: ClosedRange<Double> = 300...2400
    public static let viewerIdleStopRange = 10...600
    public static let autosaveRange = 15...600
    public static let portRange: ClosedRange<Int> = 1024...65535
    public static let mirrorStreamMaxSizeRange = 320...1600
    public static let mirrorStreamBitRateRange = 1_000_000...8_000_000
    public static let mirrorStreamMaxFpsRange = 1...30
    public static let mirrorStreamKeyIntervalRange = 500...10000
    public static let mirrorDiffThresholdRange: ClosedRange<Double> = 0.0005...0.05
    public static let overlaySmoothingRange: ClosedRange<Double> = 0...0.9
    public static let overlayFeatherRange = 0...8
    public static let overlayScaleRange: ClosedRange<Double> = 0.15...0.5
    public static let overlayOpacityRange: ClosedRange<Double> = 0.3...1.0

    /// Clamps every range of SPEC section 11; `preWarningSeconds <= idleTimeoutSeconds - 1`; a port below 1024 becomes 7788.
    public func validated() -> Settings {
        var s = self
        s.idleTimeoutSeconds = Settings.clamp(s.idleTimeoutSeconds, Settings.idleTimeoutRange)
        s.preWarningSeconds = Settings.clamp(s.preWarningSeconds, Settings.preWarningRange)
        if s.preWarningSeconds > s.idleTimeoutSeconds - 1 { s.preWarningSeconds = s.idleTimeoutSeconds - 1 }
        if s.springK.isNaN || s.springK < Settings.springKRange.lowerBound { s.springK = Settings.springKRange.lowerBound }
        if s.springK > Settings.springKRange.upperBound { s.springK = Settings.springKRange.upperBound }
        s.viewerIdleStopSeconds = Settings.clamp(s.viewerIdleStopSeconds, Settings.viewerIdleStopRange)
        s.autosaveSeconds = Settings.clamp(s.autosaveSeconds, Settings.autosaveRange)
        if Int(s.port) < Settings.portRange.lowerBound { s.port = SolStream.defaultPort }
        if Int(s.adbPrivatePort) < Settings.portRange.lowerBound { s.adbPrivatePort = Settings.defaults.adbPrivatePort }
        if s.sideButtonDoublePressMs < 1 { s.sideButtonDoublePressMs = Settings.defaults.sideButtonDoublePressMs }
        if s.sideButtonLongPressMs < 1 { s.sideButtonLongPressMs = Settings.defaults.sideButtonLongPressMs }
        if s.pillStripHeight < 0 { s.pillStripHeight = 0 }
        if s.mirrorMaxSize < 1 { s.mirrorMaxSize = Settings.defaults.mirrorMaxSize }
        if s.mirrorBitRate < 1 { s.mirrorBitRate = Settings.defaults.mirrorBitRate }
        if s.mirrorMaxFps < 1 { s.mirrorMaxFps = Settings.defaults.mirrorMaxFps }
        if s.onboardingVersion < 1 { s.onboardingVersion = 1 }
        s.mirrorStreamMaxSize = Settings.clamp(s.mirrorStreamMaxSize, Settings.mirrorStreamMaxSizeRange)
        s.mirrorStreamBitRate = Settings.clamp(s.mirrorStreamBitRate, Settings.mirrorStreamBitRateRange)
        s.mirrorStreamMaxFps = Settings.clamp(s.mirrorStreamMaxFps, Settings.mirrorStreamMaxFpsRange)
        s.mirrorStreamKeyIntervalMs = Settings.clamp(s.mirrorStreamKeyIntervalMs, Settings.mirrorStreamKeyIntervalRange)
        if s.mirrorDiffThreshold.isNaN { s.mirrorDiffThreshold = Settings.defaults.mirrorDiffThreshold }
        s.mirrorDiffThreshold = min(max(s.mirrorDiffThreshold, Settings.mirrorDiffThresholdRange.lowerBound), Settings.mirrorDiffThresholdRange.upperBound)
        s.overlaySmoothing = Settings.clamp(s.overlaySmoothing, Settings.overlaySmoothingRange, nanDefault: Settings.defaults.overlaySmoothing)
        s.overlayFeather = Settings.clamp(s.overlayFeather, Settings.overlayFeatherRange)
        s.overlayScale = Settings.clamp(s.overlayScale, Settings.overlayScaleRange, nanDefault: Settings.defaults.overlayScale)
        s.overlayOpacity = Settings.clamp(s.overlayOpacity, Settings.overlayOpacityRange, nanDefault: Settings.defaults.overlayOpacity)
        for action in HotkeyAction.allCases where s.hotkeys[action] == nil {
            s.hotkeys[action] = Settings.defaultHotkeys[action]
        }
        return s
    }

    static func clamp(_ v: Int, _ r: ClosedRange<Int>) -> Int {
        return min(max(v, r.lowerBound), r.upperBound)
    }

    /// NaN becomes `nanDefault`; everything else is clamped into `r`.
    static func clamp(_ v: Double, _ r: ClosedRange<Double>, nanDefault: Double) -> Double {
        if v.isNaN { return nanDefault }
        return min(max(v, r.lowerBound), r.upperBound)
    }

    // MARK: Codable (holdMode omitted; missing keys keep their defaults)

    private enum CodingKeys: String, CodingKey {
        case onboardingDone, onboardingVersion, cameraUniqueID, inkSource, preferredLayout, autoEngage
        case idleTimeoutSeconds, preWarningSeconds, springK, engageOnEraser, hotkeys, port, bonjourName, trustLoopback
        case mirrorPinClearMode, sideButtonDoublePressMs, sideButtonLongPressMs, sideButtonSwap
        case mirrorCropInsetsPortrait, mirrorCropInsetsLandscape, pillStripHeight, mirrorPillsPosition
        case mirrorMaxSize, mirrorBitRate, mirrorMaxFps, mirrorDeviceSerial, adbServerMode, adbPrivatePort, mirrorOverWiFi
        case adbSource, adbTermsAcceptedVersion
        case viewerIdleStopSeconds, saveDirectory, saveStrokesJSON, autosaveSeconds, previewOnLaunch, previewFloats
        case frameReuse, deadlineIdle, perfLog
        case mirrorTransport, mirrorStreamMaxSize, mirrorStreamBitRate, mirrorStreamMaxFps, mirrorStreamKeyIntervalMs, mirrorDiffThreshold
        case overlayEnabled, overlayQuality, overlaySmoothing, overlayFeather, overlayHalo, overlayScale, overlayPosition, overlayOpacity
        case followPen
    }

    /// LOOSE_ENDS J5: every enum key decodes its raw value leniently, so a value from a newer build (a case this build
    /// does not know), a typo or a wrong JSON type falls back to that key's default instead of failing the whole blob
    /// (which reset every setting on a downgrade). A known value decodes exactly as before.
    private static func lenient<T: RawRepresentable>(_ type: T.Type, _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, _ fallback: T) -> T where T.RawValue: Decodable {
        let raw: T.RawValue?
        do {
            raw = try c.decodeIfPresent(T.RawValue.self, forKey: key)
        } catch {
            raw = nil
        }
        return raw.flatMap { T(rawValue: $0) } ?? fallback
    }

    /// `hotkeys` is keyed by action name: an action this build does not know is dropped, the known ones are kept, and a
    /// malformed value falls back to the defaults (`validated()` fills any missing action).
    private static func lenientHotkeys(_ c: KeyedDecodingContainer<CodingKeys>, _ fallback: [HotkeyAction: HotkeyBinding]) -> [HotkeyAction: HotkeyBinding] {
        let named: [String: HotkeyBinding]?
        do {
            named = try c.decodeIfPresent([String: HotkeyBinding].self, forKey: .hotkeys)
        } catch {
            return fallback
        }
        guard let byName = named else { return fallback }
        var out: [HotkeyAction: HotkeyBinding] = [:]
        for (name, binding) in byName {
            if let action = HotkeyAction(rawValue: name) { out[action] = binding }
        }
        return out
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.defaults
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? d.onboardingDone
        onboardingVersion = try c.decodeIfPresent(Int.self, forKey: .onboardingVersion) ?? d.onboardingVersion
        cameraUniqueID = try c.decodeIfPresent(String.self, forKey: .cameraUniqueID) ?? d.cameraUniqueID
        inkSource = Settings.lenient(InkSource.self, c, .inkSource, d.inkSource)
        preferredLayout = Settings.lenient(LayoutStyle.self, c, .preferredLayout, d.preferredLayout)
        holdMode = .auto
        autoEngage = try c.decodeIfPresent(Bool.self, forKey: .autoEngage) ?? d.autoEngage
        idleTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .idleTimeoutSeconds) ?? d.idleTimeoutSeconds
        preWarningSeconds = try c.decodeIfPresent(Int.self, forKey: .preWarningSeconds) ?? d.preWarningSeconds
        springK = try c.decodeIfPresent(Double.self, forKey: .springK) ?? d.springK
        engageOnEraser = try c.decodeIfPresent(Bool.self, forKey: .engageOnEraser) ?? d.engageOnEraser
        hotkeys = Settings.lenientHotkeys(c, d.hotkeys)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        bonjourName = try c.decodeIfPresent(String.self, forKey: .bonjourName) ?? d.bonjourName
        trustLoopback = try c.decodeIfPresent(Bool.self, forKey: .trustLoopback) ?? d.trustLoopback
        mirrorPinClearMode = Settings.lenient(MirrorPinClearMode.self, c, .mirrorPinClearMode, d.mirrorPinClearMode)
        sideButtonDoublePressMs = try c.decodeIfPresent(Int.self, forKey: .sideButtonDoublePressMs) ?? d.sideButtonDoublePressMs
        sideButtonLongPressMs = try c.decodeIfPresent(Int.self, forKey: .sideButtonLongPressMs) ?? d.sideButtonLongPressMs
        sideButtonSwap = try c.decodeIfPresent(Bool.self, forKey: .sideButtonSwap) ?? d.sideButtonSwap
        mirrorCropInsetsPortrait = try c.decodeIfPresent(CropInsets.self, forKey: .mirrorCropInsetsPortrait) ?? d.mirrorCropInsetsPortrait
        mirrorCropInsetsLandscape = try c.decodeIfPresent(CropInsets.self, forKey: .mirrorCropInsetsLandscape) ?? d.mirrorCropInsetsLandscape
        pillStripHeight = try c.decodeIfPresent(Int.self, forKey: .pillStripHeight) ?? d.pillStripHeight
        mirrorPillsPosition = Settings.lenient(PillsPosition.self, c, .mirrorPillsPosition, d.mirrorPillsPosition)
        mirrorMaxSize = try c.decodeIfPresent(Int.self, forKey: .mirrorMaxSize) ?? d.mirrorMaxSize
        mirrorBitRate = try c.decodeIfPresent(Int.self, forKey: .mirrorBitRate) ?? d.mirrorBitRate
        mirrorMaxFps = try c.decodeIfPresent(Int.self, forKey: .mirrorMaxFps) ?? d.mirrorMaxFps
        mirrorDeviceSerial = try c.decodeIfPresent(String.self, forKey: .mirrorDeviceSerial) ?? d.mirrorDeviceSerial
        adbServerMode = Settings.lenient(AdbServerMode.self, c, .adbServerMode, d.adbServerMode)
        adbPrivatePort = try c.decodeIfPresent(UInt16.self, forKey: .adbPrivatePort) ?? d.adbPrivatePort
        mirrorOverWiFi = try c.decodeIfPresent(Bool.self, forKey: .mirrorOverWiFi) ?? d.mirrorOverWiFi
        adbSource = Settings.lenient(AdbSource.self, c, .adbSource, d.adbSource)
        adbTermsAcceptedVersion = try c.decodeIfPresent(String.self, forKey: .adbTermsAcceptedVersion) ?? d.adbTermsAcceptedVersion
        viewerIdleStopSeconds = try c.decodeIfPresent(Int.self, forKey: .viewerIdleStopSeconds) ?? d.viewerIdleStopSeconds
        saveDirectory = try c.decodeIfPresent(URL.self, forKey: .saveDirectory) ?? d.saveDirectory
        saveStrokesJSON = try c.decodeIfPresent(Bool.self, forKey: .saveStrokesJSON) ?? d.saveStrokesJSON
        autosaveSeconds = try c.decodeIfPresent(Int.self, forKey: .autosaveSeconds) ?? d.autosaveSeconds
        previewOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .previewOnLaunch) ?? d.previewOnLaunch
        previewFloats = try c.decodeIfPresent(Bool.self, forKey: .previewFloats) ?? d.previewFloats
        frameReuse = try c.decodeIfPresent(Bool.self, forKey: .frameReuse) ?? d.frameReuse
        deadlineIdle = try c.decodeIfPresent(Bool.self, forKey: .deadlineIdle) ?? d.deadlineIdle
        perfLog = try c.decodeIfPresent(Bool.self, forKey: .perfLog) ?? d.perfLog
        mirrorTransport = Settings.lenient(MirrorTransport.self, c, .mirrorTransport, d.mirrorTransport)
        mirrorStreamMaxSize = try c.decodeIfPresent(Int.self, forKey: .mirrorStreamMaxSize) ?? d.mirrorStreamMaxSize
        mirrorStreamBitRate = try c.decodeIfPresent(Int.self, forKey: .mirrorStreamBitRate) ?? d.mirrorStreamBitRate
        mirrorStreamMaxFps = try c.decodeIfPresent(Int.self, forKey: .mirrorStreamMaxFps) ?? d.mirrorStreamMaxFps
        mirrorStreamKeyIntervalMs = try c.decodeIfPresent(Int.self, forKey: .mirrorStreamKeyIntervalMs) ?? d.mirrorStreamKeyIntervalMs
        mirrorDiffThreshold = try c.decodeIfPresent(Double.self, forKey: .mirrorDiffThreshold) ?? d.mirrorDiffThreshold
        overlayEnabled = try c.decodeIfPresent(Bool.self, forKey: .overlayEnabled) ?? d.overlayEnabled
        overlayQuality = (try? c.decodeIfPresent(String.self, forKey: .overlayQuality)).flatMap { $0 }.flatMap(OverlayQuality.init(rawValue:)) ?? d.overlayQuality
        overlaySmoothing = try c.decodeIfPresent(Double.self, forKey: .overlaySmoothing) ?? d.overlaySmoothing
        overlayFeather = try c.decodeIfPresent(Int.self, forKey: .overlayFeather) ?? d.overlayFeather
        overlayHalo = try c.decodeIfPresent(Bool.self, forKey: .overlayHalo) ?? d.overlayHalo
        overlayScale = try c.decodeIfPresent(Double.self, forKey: .overlayScale) ?? d.overlayScale
        overlayPosition = (try? c.decodeIfPresent(String.self, forKey: .overlayPosition)).flatMap { $0 }.flatMap(OverlayPosition.init(rawValue:)) ?? d.overlayPosition
        overlayOpacity = try c.decodeIfPresent(Double.self, forKey: .overlayOpacity) ?? d.overlayOpacity
        followPen = try c.decodeIfPresent(Bool.self, forKey: .followPen) ?? d.followPen
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(onboardingDone, forKey: .onboardingDone)
        try c.encode(onboardingVersion, forKey: .onboardingVersion)
        try c.encodeIfPresent(cameraUniqueID, forKey: .cameraUniqueID)
        try c.encode(inkSource, forKey: .inkSource)
        try c.encode(preferredLayout, forKey: .preferredLayout)
        try c.encode(autoEngage, forKey: .autoEngage)
        try c.encode(idleTimeoutSeconds, forKey: .idleTimeoutSeconds)
        try c.encode(preWarningSeconds, forKey: .preWarningSeconds)
        try c.encode(springK, forKey: .springK)
        try c.encode(engageOnEraser, forKey: .engageOnEraser)
        try c.encode(hotkeys, forKey: .hotkeys)
        try c.encode(port, forKey: .port)
        try c.encodeIfPresent(bonjourName, forKey: .bonjourName)
        try c.encode(trustLoopback, forKey: .trustLoopback)
        try c.encode(mirrorPinClearMode, forKey: .mirrorPinClearMode)
        try c.encode(sideButtonDoublePressMs, forKey: .sideButtonDoublePressMs)
        try c.encode(sideButtonLongPressMs, forKey: .sideButtonLongPressMs)
        try c.encode(sideButtonSwap, forKey: .sideButtonSwap)
        try c.encode(mirrorCropInsetsPortrait, forKey: .mirrorCropInsetsPortrait)
        try c.encode(mirrorCropInsetsLandscape, forKey: .mirrorCropInsetsLandscape)
        try c.encode(pillStripHeight, forKey: .pillStripHeight)
        try c.encode(mirrorPillsPosition, forKey: .mirrorPillsPosition)
        try c.encode(mirrorMaxSize, forKey: .mirrorMaxSize)
        try c.encode(mirrorBitRate, forKey: .mirrorBitRate)
        try c.encode(mirrorMaxFps, forKey: .mirrorMaxFps)
        try c.encodeIfPresent(mirrorDeviceSerial, forKey: .mirrorDeviceSerial)
        try c.encode(adbServerMode, forKey: .adbServerMode)
        try c.encode(adbPrivatePort, forKey: .adbPrivatePort)
        try c.encode(mirrorOverWiFi, forKey: .mirrorOverWiFi)
        try c.encode(adbSource, forKey: .adbSource)
        try c.encodeIfPresent(adbTermsAcceptedVersion, forKey: .adbTermsAcceptedVersion)
        try c.encode(viewerIdleStopSeconds, forKey: .viewerIdleStopSeconds)
        try c.encodeIfPresent(saveDirectory, forKey: .saveDirectory)
        try c.encode(saveStrokesJSON, forKey: .saveStrokesJSON)
        try c.encode(autosaveSeconds, forKey: .autosaveSeconds)
        try c.encode(previewOnLaunch, forKey: .previewOnLaunch)
        try c.encode(previewFloats, forKey: .previewFloats)
        try c.encode(frameReuse, forKey: .frameReuse)
        try c.encode(deadlineIdle, forKey: .deadlineIdle)
        try c.encode(perfLog, forKey: .perfLog)
        try c.encode(mirrorTransport, forKey: .mirrorTransport)
        try c.encode(mirrorStreamMaxSize, forKey: .mirrorStreamMaxSize)
        try c.encode(mirrorStreamBitRate, forKey: .mirrorStreamBitRate)
        try c.encode(mirrorStreamMaxFps, forKey: .mirrorStreamMaxFps)
        try c.encode(mirrorStreamKeyIntervalMs, forKey: .mirrorStreamKeyIntervalMs)
        try c.encode(mirrorDiffThreshold, forKey: .mirrorDiffThreshold)
        try c.encode(overlayEnabled, forKey: .overlayEnabled)
        try c.encode(overlayQuality, forKey: .overlayQuality)
        try c.encode(overlaySmoothing, forKey: .overlaySmoothing)
        try c.encode(overlayFeather, forKey: .overlayFeather)
        try c.encode(overlayHalo, forKey: .overlayHalo)
        try c.encode(overlayScale, forKey: .overlayScale)
        try c.encode(overlayPosition, forKey: .overlayPosition)
        try c.encode(overlayOpacity, forKey: .overlayOpacity)
        try c.encode(followPen, forKey: .followPen)
    }
}
