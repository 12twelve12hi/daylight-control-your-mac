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
    /// Amber breath weight 0...1 while the pre-warning is on: `0.5 * (1 - cos(2 * pi * t / 2))`, 0.5 Hz.
    public var breath: Double
    /// Milliseconds until the automatic return; `StateReport.noReturnScheduled` when none is scheduled.
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

    /// The breath formula of SPEC 5.2 and PROTOCOL 6.14 for `t` seconds since the pre-warning started.
    public static func breathWeight(secondsSincePreWarning t: Double) -> Double {
        if t < 0 { return 0 }
        return 0.5 * (1 - cos(2 * Double.pi * t / 2))
    }

    /// The 20-byte STATE for one client (PROTOCOL 6.14). `clientFlags` carries the bits the governor does not know:
    /// clientAllowed, clientIsActiveSource, cameraAttached, sinkConnected, saving, captureIdle. Counts saturate at 65535.
    public func stateReport(clientFlags: StateReport.Flags, inkSource: InkSource, pageIndex: Int, strokeCount: Int, undoDepth: Int, redoDepth: Int) -> StateReport {
        var flags = clientFlags
        flags.remove([.pinned, .preWarning])
        if pinned { flags.insert(.pinned) }
        if preWarning { flags.insert(.preWarning) }
        return StateReport(
            governor: state.rawValue,
            flags: flags.rawValue,
            mode: hold.rawValue,
            inkSource: inkSource.rawValue,
            progress: Float(progress),
            msToReturn: msToReturn,
            pageIndex: GovernorOutput.saturate16(pageIndex),
            strokeCount: GovernorOutput.saturate16(strokeCount),
            undoDepth: GovernorOutput.saturate16(undoDepth),
            redoDepth: GovernorOutput.saturate16(redoDepth))
    }

    static func saturate16(_ v: Int) -> UInt16 {
        if v <= 0 { return 0 }
        if v >= Int(UInt16.max) { return UInt16.max }
        return UInt16(v)
    }
}
