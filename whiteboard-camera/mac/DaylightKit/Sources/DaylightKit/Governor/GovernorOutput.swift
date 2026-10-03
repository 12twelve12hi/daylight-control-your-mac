import Foundation

public enum SaveReason: String, Codable {
    case returned
    case cleared
    case pageChange
    case autosave
    case modeChanged
    case quit
}

public enum GovernorEffect: Equatable {
    case stateChanged(from: GovernorState, to: GovernorState)
    case savePage(reason: SaveReason)
    case clearCanvas
    case preWarningStarted
    case preWarningCancelled
    case pinChanged(Bool)
    case holdChanged(HoldMode)
}

public struct GovernorOutput: Equatable {
    public var state: GovernorState
    public var progress: Double
    public var pinned: Bool
    public var hold: HoldMode
    public var layout: LayoutStyle
    public var preWarning: Bool
    public var breath: Double
    public var msToReturn: UInt32
    public var activeContacts: Int
    public var effects: [GovernorEffect]

    public init(state: GovernorState = .passthrough, progress: Double = 0, pinned: Bool = false, hold: HoldMode = .auto, layout: LayoutStyle = .studioSplit, preWarning: Bool = false, breath: Double = 0, msToReturn: UInt32 = StateReport.noReturnScheduled, activeContacts: Int = 0, effects: [GovernorEffect] = []) {
        self.state = state
        self.progress = progress
        self.pinned = pinned
        self.hold = hold
        self.layout = layout
        self.preWarning = preWarning
        self.breath = breath
        self.msToReturn = msToReturn
        self.activeContacts = activeContacts
        self.effects = effects
    }
}
