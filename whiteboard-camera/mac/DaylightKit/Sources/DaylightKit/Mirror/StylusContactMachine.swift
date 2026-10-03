import Foundation

/// The pen state after one evdev report (research-scrcpy-adb section 4.4).
public struct StylusSample: Equatable {
    public var inRange = false         // BTN_TOOL_PEN
    public var eraserInRange = false   // BTN_TOOL_RUBBER
    public var touching = false        // BTN_TOUCH
    public var side1 = false           // BTN_STYLUS
    public var side2 = false           // BTN_STYLUS2
    public var pressure: Double = 0    // ABS_PRESSURE / pressureMax, 0...1
    public var x = 0                   // ABS_X in digitizer units
    public var y = 0                   // ABS_Y in digitizer units
    public var tsUs: UInt64 = 0        // stamp of the SYN_REPORT that committed this sample

    public init() {}

    /// Pen tip on the glass: engage.
    public var penContact: Bool { return touching && inRange }
    /// Eraser end on the glass: activity, never engage (SPEC D36).
    public var eraserContact: Bool { return touching && eraserInRange && !inRange }
}

public enum StylusTransition: Equatable {
    case contactDown(StylusSample)
    case contactUp(StylusSample)
    case eraserDown(StylusSample)
    case eraserUp(StylusSample)
    case side1Down(tsUs: UInt64)
    case side1Up(tsUs: UInt64)
    case side2Down(tsUs: UInt64)
    case side2Up(tsUs: UInt64)
}

/// Folds `getevent -lt` events into pen transitions. Events between two `SYN_REPORT`s update a pending sample; the
/// report commits it and the edges against the previous committed sample are emitted, so a report that carries
/// `BTN_TOOL_PEN DOWN` and `BTN_TOUCH DOWN` together yields exactly one `contactDown`. Hover (`BTN_TOOL_PEN` without
/// `BTN_TOUCH`) and bare coordinate or pressure changes emit nothing.
///
/// Pressure comes from `ABS_PRESSURE`; `ABS_MT_PRESSURE` stands in while the stream has never carried
/// `ABS_PRESSURE` (a pen multiplexed through the finger touchscreen's multitouch node). On such a node a finger also
/// raises `BTN_TOUCH` while the pen hovers in range, so `init(node:)` additionally requires pressure above zero for
/// a contact edge (`contactRequiresPressure`); a dedicated Wacom node keeps the plain `BTN_TOUCH` rule.
public struct StylusContactMachine {
    public let pressureMax: Int
    public let contactRequiresPressure: Bool
    public private(set) var committed = StylusSample()
    private var pending = StylusSample()
    private var sawAbsPressure = false

    public init(pressureMax: Int, contactRequiresPressure: Bool = false) {
        self.pressureMax = max(1, pressureMax)
        self.contactRequiresPressure = contactRequiresPressure
    }

    /// Tuned to the chosen `getevent -pl` node: its pressure range, and the pressure gate when it is multitouch.
    public init(node: EvdevCapabilities) {
        self.init(pressureMax: node.pressureMax, contactRequiresPressure: node.isMultitouch)
    }

    private func penContact(_ s: StylusSample) -> Bool { return s.penContact && (!contactRequiresPressure || s.pressure > 0) }
    private func eraserContact(_ s: StylusSample) -> Bool { return s.eraserContact && (!contactRequiresPressure || s.pressure > 0) }

    public var current: StylusSample { return committed }

    public mutating func apply(_ e: EvdevEvent) -> [StylusTransition] {
        switch e.type {
        case "EV_KEY":
            guard let v = e.numericValue else { return [] }
            let down = v != 0
            switch e.code {
            case "BTN_TOOL_PEN": pending.inRange = down
            case "BTN_TOOL_RUBBER": pending.eraserInRange = down
            case "BTN_TOUCH": pending.touching = down
            case "BTN_STYLUS": pending.side1 = down
            case "BTN_STYLUS2": pending.side2 = down
            default: break
            }
            return []
        case "EV_ABS":
            guard let v = e.numericValue else { return [] }
            switch e.code {
            case "ABS_PRESSURE":
                sawAbsPressure = true
                pending.pressure = min(1, max(0, Double(v) / Double(pressureMax)))
            case "ABS_MT_PRESSURE" where !sawAbsPressure:
                pending.pressure = min(1, max(0, Double(v) / Double(pressureMax)))
            case "ABS_X": pending.x = Int(v)
            case "ABS_Y": pending.y = Int(v)
            default: break
            }
            return []
        case "EV_SYN":
            guard e.code == "SYN_REPORT" else { return [] }
            pending.tsUs = e.tsUs
            let previous = committed
            committed = pending
            var out: [StylusTransition] = []
            if penContact(committed) != penContact(previous) {
                out.append(penContact(committed) ? .contactDown(committed) : .contactUp(committed))
            }
            if eraserContact(committed) != eraserContact(previous) {
                out.append(eraserContact(committed) ? .eraserDown(committed) : .eraserUp(committed))
            }
            if committed.side1 != previous.side1 {
                out.append(committed.side1 ? .side1Down(tsUs: committed.tsUs) : .side1Up(tsUs: committed.tsUs))
            }
            if committed.side2 != previous.side2 {
                out.append(committed.side2 ? .side2Down(tsUs: committed.tsUs) : .side2Up(tsUs: committed.tsUs))
            }
            return out
        default:
            return []
        }
    }

    /// Forces every switch open (the stream ended): emits the matching up edges so no contact stays latched.
    public mutating func reset(tsUs: UInt64) -> [StylusTransition] {
        pending = StylusSample()
        pending.tsUs = tsUs
        return apply(EvdevEvent(tsUs: tsUs, type: "EV_SYN", code: "SYN_REPORT", value: "00000000"))
    }
}
