import Foundation

/// Hotkey actions (SPEC section 14). Raw values are the JSON keys of `Settings.hotkeys`.
public enum HotkeyAction: String, Codable, CaseIterable, CodingKeyRepresentable {
    case whiteboardOnly
    case studioSplit
    case keep
    case clear
    case camera
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

    public init() {}

    public static let defaults = Settings()

    public static let defaultHotkeys: [HotkeyAction: HotkeyBinding] = [
        .whiteboardOnly: HotkeyBinding(keyCode: HotkeyBinding.keyW, modifiers: HotkeyBinding.defaultModifiers),
        .studioSplit: HotkeyBinding(keyCode: HotkeyBinding.keyD, modifiers: HotkeyBinding.defaultModifiers),
        .keep: HotkeyBinding(keyCode: HotkeyBinding.keyK, modifiers: HotkeyBinding.defaultModifiers),
        .clear: HotkeyBinding(keyCode: HotkeyBinding.keyC, modifiers: HotkeyBinding.defaultModifiers),
        .camera: HotkeyBinding(keyCode: HotkeyBinding.keyEscape, modifiers: HotkeyBinding.defaultModifiers),
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
        for action in HotkeyAction.allCases where s.hotkeys[action] == nil {
            s.hotkeys[action] = Settings.defaultHotkeys[action]
        }
        return s
    }

    static func clamp(_ v: Int, _ r: ClosedRange<Int>) -> Int {
        return min(max(v, r.lowerBound), r.upperBound)
    }

    // MARK: Codable (holdMode omitted; missing keys keep their defaults)

    private enum CodingKeys: String, CodingKey {
        case onboardingDone, onboardingVersion, cameraUniqueID, inkSource, preferredLayout, autoEngage
        case idleTimeoutSeconds, preWarningSeconds, springK, engageOnEraser, hotkeys, port, bonjourName, trustLoopback
        case mirrorPinClearMode, sideButtonDoublePressMs, sideButtonLongPressMs, sideButtonSwap
        case mirrorCropInsetsPortrait, mirrorCropInsetsLandscape, pillStripHeight, mirrorPillsPosition
        case mirrorMaxSize, mirrorBitRate, mirrorMaxFps, mirrorDeviceSerial, adbServerMode, adbPrivatePort, mirrorOverWiFi
        case viewerIdleStopSeconds, saveDirectory, saveStrokesJSON, autosaveSeconds, previewOnLaunch, previewFloats
        case frameReuse, deadlineIdle, perfLog
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.defaults
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? d.onboardingDone
        onboardingVersion = try c.decodeIfPresent(Int.self, forKey: .onboardingVersion) ?? d.onboardingVersion
        cameraUniqueID = try c.decodeIfPresent(String.self, forKey: .cameraUniqueID) ?? d.cameraUniqueID
        inkSource = try c.decodeIfPresent(InkSource.self, forKey: .inkSource) ?? d.inkSource
        preferredLayout = try c.decodeIfPresent(LayoutStyle.self, forKey: .preferredLayout) ?? d.preferredLayout
        holdMode = .auto
        autoEngage = try c.decodeIfPresent(Bool.self, forKey: .autoEngage) ?? d.autoEngage
        idleTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .idleTimeoutSeconds) ?? d.idleTimeoutSeconds
        preWarningSeconds = try c.decodeIfPresent(Int.self, forKey: .preWarningSeconds) ?? d.preWarningSeconds
        springK = try c.decodeIfPresent(Double.self, forKey: .springK) ?? d.springK
        engageOnEraser = try c.decodeIfPresent(Bool.self, forKey: .engageOnEraser) ?? d.engageOnEraser
        hotkeys = try c.decodeIfPresent([HotkeyAction: HotkeyBinding].self, forKey: .hotkeys) ?? d.hotkeys
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        bonjourName = try c.decodeIfPresent(String.self, forKey: .bonjourName) ?? d.bonjourName
        trustLoopback = try c.decodeIfPresent(Bool.self, forKey: .trustLoopback) ?? d.trustLoopback
        mirrorPinClearMode = try c.decodeIfPresent(MirrorPinClearMode.self, forKey: .mirrorPinClearMode) ?? d.mirrorPinClearMode
        sideButtonDoublePressMs = try c.decodeIfPresent(Int.self, forKey: .sideButtonDoublePressMs) ?? d.sideButtonDoublePressMs
        sideButtonLongPressMs = try c.decodeIfPresent(Int.self, forKey: .sideButtonLongPressMs) ?? d.sideButtonLongPressMs
        sideButtonSwap = try c.decodeIfPresent(Bool.self, forKey: .sideButtonSwap) ?? d.sideButtonSwap
        mirrorCropInsetsPortrait = try c.decodeIfPresent(CropInsets.self, forKey: .mirrorCropInsetsPortrait) ?? d.mirrorCropInsetsPortrait
        mirrorCropInsetsLandscape = try c.decodeIfPresent(CropInsets.self, forKey: .mirrorCropInsetsLandscape) ?? d.mirrorCropInsetsLandscape
        pillStripHeight = try c.decodeIfPresent(Int.self, forKey: .pillStripHeight) ?? d.pillStripHeight
        mirrorPillsPosition = try c.decodeIfPresent(PillsPosition.self, forKey: .mirrorPillsPosition) ?? d.mirrorPillsPosition
        mirrorMaxSize = try c.decodeIfPresent(Int.self, forKey: .mirrorMaxSize) ?? d.mirrorMaxSize
        mirrorBitRate = try c.decodeIfPresent(Int.self, forKey: .mirrorBitRate) ?? d.mirrorBitRate
        mirrorMaxFps = try c.decodeIfPresent(Int.self, forKey: .mirrorMaxFps) ?? d.mirrorMaxFps
        mirrorDeviceSerial = try c.decodeIfPresent(String.self, forKey: .mirrorDeviceSerial) ?? d.mirrorDeviceSerial
        adbServerMode = try c.decodeIfPresent(AdbServerMode.self, forKey: .adbServerMode) ?? d.adbServerMode
        adbPrivatePort = try c.decodeIfPresent(UInt16.self, forKey: .adbPrivatePort) ?? d.adbPrivatePort
        mirrorOverWiFi = try c.decodeIfPresent(Bool.self, forKey: .mirrorOverWiFi) ?? d.mirrorOverWiFi
        viewerIdleStopSeconds = try c.decodeIfPresent(Int.self, forKey: .viewerIdleStopSeconds) ?? d.viewerIdleStopSeconds
        saveDirectory = try c.decodeIfPresent(URL.self, forKey: .saveDirectory) ?? d.saveDirectory
        saveStrokesJSON = try c.decodeIfPresent(Bool.self, forKey: .saveStrokesJSON) ?? d.saveStrokesJSON
        autosaveSeconds = try c.decodeIfPresent(Int.self, forKey: .autosaveSeconds) ?? d.autosaveSeconds
        previewOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .previewOnLaunch) ?? d.previewOnLaunch
        previewFloats = try c.decodeIfPresent(Bool.self, forKey: .previewFloats) ?? d.previewFloats
        frameReuse = try c.decodeIfPresent(Bool.self, forKey: .frameReuse) ?? d.frameReuse
        deadlineIdle = try c.decodeIfPresent(Bool.self, forKey: .deadlineIdle) ?? d.deadlineIdle
        perfLog = try c.decodeIfPresent(Bool.self, forKey: .perfLog) ?? d.perfLog
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
        try c.encode(viewerIdleStopSeconds, forKey: .viewerIdleStopSeconds)
        try c.encodeIfPresent(saveDirectory, forKey: .saveDirectory)
        try c.encode(saveStrokesJSON, forKey: .saveStrokesJSON)
        try c.encode(autosaveSeconds, forKey: .autosaveSeconds)
        try c.encode(previewOnLaunch, forKey: .previewOnLaunch)
        try c.encode(previewFloats, forKey: .previewFloats)
        try c.encode(frameReuse, forKey: .frameReuse)
        try c.encode(deadlineIdle, forKey: .deadlineIdle)
        try c.encode(perfLog, forKey: .perfLog)
    }
}
