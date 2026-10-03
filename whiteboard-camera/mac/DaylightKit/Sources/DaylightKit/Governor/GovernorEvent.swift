import Foundation

public enum GovernorState: UInt8 {
    case passthrough = 0
    case engaging = 1
    case live = 2
    case returning = 3
}

/// Raw values equal the STATE `mode` byte (PROTOCOL 6.14).
public enum HoldMode: UInt8, Codable {
    case auto = 0
    case split = 1
    case whiteboard = 2
    case camera = 3

    /// The layout a hold mode forces (nil for auto and camera).
    public var forcedLayout: LayoutStyle? {
        switch self {
        case .split: return .studioSplit
        case .whiteboard: return .whiteboardOnly
        case .auto, .camera: return nil
        }
    }
}

public enum LayoutStyle: UInt8, Codable {
    case studioSplit = 0
    case whiteboardOnly = 1
}

/// Raw values equal the STATE `ink_source` byte.
public enum InkSource: UInt8, Codable {
    case web = 0
    case native = 1
    case mirror = 2

    /// The word the tablet chip shows: "Ink source is <web / Daylight Ink / mirror> on the Mac".
    public var displayName: String {
        switch self {
        case .web: return "web"
        case .native: return "Daylight Ink"
        case .mirror: return "mirror"
        }
    }

    /// The `/api/info` and JSON value.
    public var jsonName: String {
        switch self {
        case .web: return "web"
        case .native: return "native"
        case .mirror: return "mirror"
        }
    }
}

public enum GovernorEvent: Equatable {
    case contact(strokeID: UUID, pointer: SolStream.PointerType, phase: SolStream.Phase, pressure: Float, tool: SolStream.Tool)
    case motion(strokeID: UUID)
    case lift(strokeID: UUID)
    case cancel(strokeID: UUID)
    case activity
    case penContact(down: Bool)
    case eraserContact(down: Bool)
    case pin(Int8)
    case clear
    case returnNow
    case engage
    case layoutHotkey(LayoutStyle)
    case hold(HoldMode)
    case sourceChanged(InkSource)
    case clientGone(strokeIDs: Set<UUID>)
    case allClientsGone
}

public struct GovernorConfig: Equatable {
    public var idleTimeout: Double = 90
    public var preWarningLead: Double = 5
    public var snapBackWindow: Double = 0.080
    public var snapBackMaxProgress: Double = 0.15
    public var springK: Double = 1200
    public var engageOnEraser: Bool = false
    public var autoEngage: Bool = true
    public init() {}

    /// The governor settings of SPEC section 11 (`idleTimeoutSeconds`, `preWarningSeconds`, `springK`,
    /// `engageOnEraser`, `autoEngage`), after `validated()`.
    public init(settings: Settings) {
        let s = settings.validated()
        idleTimeout = Double(s.idleTimeoutSeconds)
        preWarningLead = Double(s.preWarningSeconds)
        springK = s.springK
        engageOnEraser = s.engageOnEraser
        autoEngage = s.autoEngage
    }
}
