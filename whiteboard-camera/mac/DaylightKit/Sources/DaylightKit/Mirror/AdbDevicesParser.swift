import Foundation

/// One line of `adb devices -l` or one entry of `host:track-devices` (research-scrcpy-adb section 3.2).
public struct AdbDevice: Equatable {
    public var serial: String
    public var state: String
    public var model: String?
    public var product: String?
    public var transportID: Int?

    public init(serial: String, state: String, model: String? = nil, product: String? = nil, transportID: Int? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
        self.product = product
        self.transportID = transportID
    }

    /// TCP transports (`adb connect`) have `host:port` serials; everything else is USB.
    public var isUSB: Bool { return !serial.contains(":") }
    public var isReady: Bool { return state == AdbDevicesParser.stateDevice }

    /// SPEC 9.4 and ARCHITECTURE 6 item 2: a DC-1 looks like `model:` containing Daylight or DC, or a serial starting JP or DC1.
    public var looksLikeDaylight: Bool {
        let m = (model ?? "").lowercased()
        if m.contains("daylight") || m.contains("dc") { return true }
        return serial.hasPrefix("JP") || serial.hasPrefix("DC1")
    }
}

public enum AdbDevicesParser {
    public static let stateDevice = "device"
    public static let stateOffline = "offline"
    public static let stateUnauthorized = "unauthorized"
    /// Every state adb prints (scrcpy `adb_parser.c:36-52`).
    public static let knownStates: Set<String> = [
        "device", "offline", "unauthorized", "bootloader", "host", "recovery", "rescue", "sideload", "authorizing", "connecting", "detached", "no permissions",
    ]

    /// Parses `adb devices -l` output (or the short `serial\tstate` form of `host:track-devices`). Noise lines (`*
    /// daemon ...`, `adb server ...`, `List of devices attached`) are skipped. Serials may contain spaces: the state
    /// token is located first (scanning from the end past the `key:value` fields) and everything before it is the serial.
    public static func parse(_ output: String) -> [AdbDevice] {
        var devices: [AdbDevice] = []
        for rawLine in output.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("*") || line.hasPrefix("adb server") || line.hasPrefix("List of devices") || line.hasPrefix("error:") { continue }
            if let device = parseLine(line) { devices.append(device) }
        }
        return devices
    }

    public static func parseLine(_ line: String) -> AdbDevice? {
        // Tokens with their positions so the serial keeps its original spacing.
        var tokens: [(text: Substring, range: Range<String.Index>)] = []
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
            guard index < line.endIndex else { break }
            let start = index
            while index < line.endIndex, line[index] != " " && line[index] != "\t" { index = line.index(after: index) }
            tokens.append((line[start..<index], start..<index))
        }
        guard tokens.count >= 2 else { return nil }
        // Walk back from the end over key:value fields; the first token that is not one must be the state.
        var stateIndex = tokens.count - 1
        while stateIndex > 0 && isField(tokens[stateIndex].text) { stateIndex -= 1 }
        var state = String(tokens[stateIndex].text)
        // "no permissions" prints as two words (older adb); glue them.
        if state == "permissions", stateIndex > 0, tokens[stateIndex - 1].text == "no" {
            stateIndex -= 1
            state = "no permissions"
        }
        guard stateIndex > 0 else { return nil }
        guard knownStates.contains(state) else { return nil }
        let serial = String(line[tokens[0].range.lowerBound..<tokens[stateIndex - 1].range.upperBound])
        var device = AdbDevice(serial: serial, state: state)
        for token in tokens[(stateIndex + 1)...] where isField(token.text) {
            let parts = token.text.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "model": device.model = String(parts[1])
            case "product": device.product = String(parts[1])
            case "transport_id": device.transportID = Int(parts[1])
            default: break
            }
        }
        return device
    }

    private static func isField(_ token: Substring) -> Bool {
        guard let colon = token.firstIndex(of: ":") else { return false }
        let key = token[..<colon]
        return ["usb", "product", "model", "device", "transport_id"].contains(String(key))
    }

    /// The adb protocol version: from `adb version` text (`Android Debug Bridge version 1.0.41` -> 41), from a raw
    /// `host:version` reply (`OKAY00040029` -> 41) or from the bare 4-hex payload (`0029` -> 41).
    public static func parseHostVersion(_ output: String) -> Int? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "version 1.0.") {
            let rest = text[range.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            return Int(digits)
        }
        if let okay = text.range(of: "OKAY") {
            let after = text[okay.upperBound...]
            guard after.count >= 8, let length = Int(after.prefix(4), radix: 16) else { return nil }
            let payload = after.dropFirst(4).prefix(length)
            return Int(payload, radix: 16)
        }
        if text.count == 4 || text.count == 8, let v = Int(text.suffix(4), radix: 16) { return v }
        return nil
    }
}
