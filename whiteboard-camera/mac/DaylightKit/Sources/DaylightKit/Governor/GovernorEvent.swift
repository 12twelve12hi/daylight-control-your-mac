import Foundation

public enum GovernorState: UInt8 {
    case passthrough = 0
    case engaging = 1
    case live = 2
    case returning = 3
}

public enum HoldMode: UInt8 {
    case auto = 0
    case split = 1
    case whiteboard = 2
    case camera = 3
}

public enum LayoutStyle: UInt8 {
    case studioSplit = 0
    case whiteboardOnly = 1
}

public enum InkSource: UInt8 {
    case web = 0
    case native = 1
    case mirror = 2
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
}
