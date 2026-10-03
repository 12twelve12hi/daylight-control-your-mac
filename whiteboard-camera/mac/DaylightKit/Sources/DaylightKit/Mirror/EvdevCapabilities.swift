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

    /// `ABS_PRESSURE` maximum, or 4095 when the axis has no usable range (Wacom digitizers commonly report 4095).
    public var pressureMax: Int {
        if let range = abs["ABS_PRESSURE"], range.max > range.min { return range.max }
        return EvdevCapabilitiesParser.defaultPressureMax
    }

    public var hasSideButton: Bool { return keys.contains("BTN_STYLUS") || keys.contains("BTN_STYLUS2") }
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
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
            var line = Substring(rawLine)
            if line.last == "\r" { line.removeLast() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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

    /// The Wacom pen node: `BTN_TOOL_PEN` plus `ABS_PRESSURE` and no `ABS_MT_SLOT` (the finger touchscreen is a separate
    /// multitouch node). When several match, the one whose name mentions Wacom or a pen wins, then the first.
    public static func penNode(_ caps: [EvdevCapabilities]) -> EvdevCapabilities? {
        let candidates = caps.filter { $0.keys.contains("BTN_TOOL_PEN") && $0.abs["ABS_PRESSURE"] != nil && $0.abs["ABS_MT_SLOT"] == nil }
        if candidates.isEmpty { return nil }
        if let named = candidates.first(where: { let n = $0.name.lowercased(); return n.contains("wacom") || n.contains("pen") || n.contains("stylus") || n.contains("digitizer") }) {
            return named
        }
        return candidates.first
    }
}
