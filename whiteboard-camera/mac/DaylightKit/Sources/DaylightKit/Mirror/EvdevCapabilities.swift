import Foundation

/// One input device from `getevent -pl`: its node, name, key codes, absolute axes with ranges, and input props.
public struct EvdevCapabilities: Equatable {
    public struct AxisRange: Equatable {
        public var min: Int
        public var max: Int
        public init(min: Int, max: Int) {
            self.min = min
            self.max = max
        }
    }

    public var path: String
    public var name: String
    public var keys: Set<String>
    public var abs: [String: AxisRange]
    public var props: Set<String>

    public init(path: String, name: String, keys: Set<String> = [], abs: [String: AxisRange] = [:], props: Set<String> = []) {
        self.path = path
        self.name = name
        self.keys = keys
        self.abs = abs
        self.props = props
    }

    /// The axis that carries the pen pressure: `ABS_PRESSURE` when the node has it, else `ABS_MT_PRESSURE` (a pen
    /// multiplexed through the finger touchscreen's multitouch node), else nil.
    public var pressureAxis: String? {
        if abs["ABS_PRESSURE"] != nil { return "ABS_PRESSURE" }
        if abs["ABS_MT_PRESSURE"] != nil { return "ABS_MT_PRESSURE" }
        return nil
    }

    /// Maximum of `pressureAxis`, or 4095 when the axis has no usable range (Wacom digitizers commonly report 4095).
    public var pressureMax: Int {
        if let axis = pressureAxis, let range = abs[axis], range.max > range.min { return range.max }
        return EvdevCapabilitiesParser.defaultPressureMax
    }

    public var hasSideButton: Bool { return keys.contains("BTN_STYLUS") || keys.contains("BTN_STYLUS2") }

    /// A multitouch node (`ABS_MT_SLOT`): the finger touchscreen, which on some tablets also carries the pen.
    public var isMultitouch: Bool { return abs["ABS_MT_SLOT"] != nil }

    /// `BTN_TOOL_PEN` plus a pressure axis: the node can report pen contact.
    public var canReportPen: Bool { return keys.contains("BTN_TOOL_PEN") && pressureAxis != nil }

    /// The name says pen: Wacom, pen, stylus or digitizer.
    public var isNamedLikeAPen: Bool {
        let n = name.lowercased()
        return n.contains("wacom") || n.contains("pen") || n.contains("stylus") || n.contains("digitizer")
    }
}

/// Parses the `getevent -pl` listing (research-scrcpy-adb section 4.2 and getevent.c `print_possible_events`):
///
///     add device 1: /dev/input/event3
///       name:     "Wacom I2C Digitizer"
///       events:
///         KEY (0001): BTN_TOOL_PEN          BTN_TOOL_RUBBER       BTN_TOUCH             BTN_STYLUS
///                     BTN_STYLUS2
///         ABS (0003): ABS_X                 : value 0, min 0, max 21600, fuzz 0, flat 0, resolution 100
///                     ABS_PRESSURE          : value 0, min 0, max 4095, fuzz 0, flat 0, resolution 0
///       input props:
///         INPUT_PROP_DIRECT
///
/// A `*` after a key label marks a key that is currently down; it is stripped.
public enum EvdevCapabilitiesParser {
    public static let defaultPressureMax = 4095

    public static func parse(_ text: String) -> [EvdevCapabilities] {
        var devices: [EvdevCapabilities] = []
        var current: EvdevCapabilities?
        var section = ""   // "KEY", "ABS", "PROPS" or ""
        // `isNewline` also splits a CRLF, which Swift treats as one `Character`.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("add device ") {
                if let device = current { devices.append(device) }
                let path = trimmed.split(separator: ":", maxSplits: 1).count > 1 ? trimmed.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) : ""
                current = EvdevCapabilities(path: path, name: "")
                section = ""
                continue
            }
            if trimmed.hasPrefix("could not") || trimmed.hasPrefix("remove device") { continue }
            guard var device = current else { continue }
            if trimmed.hasPrefix("name:") {
                var name = trimmed.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\"") { name.removeFirst() }
                if name.hasSuffix("\"") { name.removeLast() }
                device.name = name
                current = device
                continue
            }
            if trimmed.hasPrefix("input props:") { section = "PROPS"; current = device; continue }
            if trimmed.hasPrefix("events:") { section = ""; current = device; continue }
            var body = trimmed
            if let paren = trimmed.range(of: " ("), trimmed.hasPrefix("KEY") || trimmed.hasPrefix("ABS") || trimmed.hasPrefix("REL") || trimmed.hasPrefix("SW ") || trimmed.hasPrefix("MSC") || trimmed.hasPrefix("LED") || trimmed.hasPrefix("SND") || trimmed.hasPrefix("REP") || trimmed.hasPrefix("FF") {
                section = String(trimmed[..<paren.lowerBound]).trimmingCharacters(in: .whitespaces)
                if let colon = trimmed.range(of: "):") {
                    body = String(trimmed[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    body = ""
                }
            }
            switch section {
            case "KEY":
                for token in body.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    var label = String(token)
                    if label.hasSuffix("*") { label.removeLast() }
                    if !label.isEmpty { device.keys.insert(label) }
                }
            case "ABS":
                if let parsed = parseAxis(body) { device.abs[parsed.0] = parsed.1 }
            case "PROPS":
                if body.hasPrefix("<") { break }
                device.props.insert(body)
            default:
                break
            }
            current = device
        }
        if let device = current { devices.append(device) }
        return devices
    }

    /// `ABS_PRESSURE          : value 0, min 0, max 4095, fuzz 0, flat 0, resolution 0` -> ("ABS_PRESSURE", 0...4095).
    static func parseAxis(_ body: String) -> (String, EvdevCapabilities.AxisRange)? {
        let parts = body.split(separator: ":", maxSplits: 1)
        guard let first = parts.first else { return nil }
        var axis = first.trimmingCharacters(in: .whitespaces)
        if axis.hasSuffix("*") { axis.removeLast() }
        guard !axis.isEmpty else { return nil }
        var range = EvdevCapabilities.AxisRange(min: 0, max: 0)
        if parts.count > 1 {
            for field in parts[1].split(separator: ",") {
                let kv = field.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard kv.count == 2, let value = Int(kv[1]) else { continue }
                if kv[0] == "min" { range.min = value }
                if kv[0] == "max" { range.max = value }
            }
        }
        return (axis, range)
    }

    /// Why `penNodeChoice` picked a node; the text goes into the log line next to the node.
    public struct PenNodeChoice: Equatable {
        public var node: EvdevCapabilities
        public var reason: String
        public init(node: EvdevCapabilities, reason: String) {
            self.node = node
            self.reason = reason
        }
    }

    /// The pen node, ranked rather than filtered (LOOSE_ENDS D1: the DC-1's node layout is unverified). Candidates
    /// have `BTN_TOOL_PEN` plus `ABS_PRESSURE` or `ABS_MT_PRESSURE`. A node without `ABS_MT_SLOT` (the mainline
    /// `wacom_i2c` layout: a dedicated single-touch digitizer next to a separate finger touchscreen) wins over a
    /// multitouch node that multiplexes the pen with the fingers; within a tier a name that mentions Wacom, pen,
    /// stylus or digitizer wins; then listing order.
    public static func penNodeChoice(_ caps: [EvdevCapabilities]) -> PenNodeChoice? {
        var best: (node: EvdevCapabilities, rank: Int)?
        for node in caps where node.canReportPen {
            let rank = (node.isMultitouch ? 2 : 0) + (node.isNamedLikeAPen ? 0 : 1)
            if let current = best, current.rank <= rank { continue }
            best = (node, rank)
        }
        guard let chosen = best else { return nil }
        let reason: String
        switch chosen.rank {
        case 0: reason = "dedicated pen node named like a pen"
        case 1: reason = "dedicated pen node"
        case 2: reason = "multitouch node named like a pen; the pen shares the finger touchscreen node"
        default: reason = "multitouch node; the pen shares the finger touchscreen node"
        }
        return PenNodeChoice(node: chosen.node, reason: reason)
    }

    /// `penNodeChoice(_:)` without the reason.
    public static func penNode(_ caps: [EvdevCapabilities]) -> EvdevCapabilities? {
        return penNodeChoice(caps)?.node
    }
}
