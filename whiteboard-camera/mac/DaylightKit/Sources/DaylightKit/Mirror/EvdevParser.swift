import Foundation

/// One line of `getevent -lt` output. `type`, `code` and `value` are the printed tokens (`EV_KEY`, `BTN_TOUCH`, `DOWN`,
/// or `ABS_PRESSURE` with a hex value such as `00000fff`). `tsUs` is the `[sec.usec]` stamp in microseconds, 0 without `-t`.
public struct EvdevEvent: Equatable {
    public var tsUs: UInt64
    public var type: String
    public var code: String
    public var value: String

    public init(tsUs: UInt64, type: String, code: String, value: String) {
        self.tsUs = tsUs
        self.type = type
        self.code = code
        self.value = value
    }

    /// `DOWN` = 1, `UP` = 0, `REPEAT` = 2, hex (getevent prints `%08x`) or decimal otherwise; nil when unreadable.
    public var numericValue: Int64? {
        switch value {
        case "DOWN": return 1
        case "UP": return 0
        case "REPEAT": return 2
        default:
            if value.count == 8, let v = UInt32(value, radix: 16) { return Int64(Int32(bitPattern: v)) }
            if let v = Int64(value) { return v }
            if let v = UInt32(value, radix: 16) { return Int64(Int32(bitPattern: v)) }
            return nil
        }
    }

    public var isSynReport: Bool { return type == "EV_SYN" && code == "SYN_REPORT" }
}

/// Incremental parser for `adb shell getevent -lt [/dev/input/eventN]` output (research-scrcpy-adb section 4.2).
/// Tolerates the `/dev/input/eventX: ` prefix (printed when no device path is given), partial lines across reads,
/// `\r\n` line ends, missing timestamps, and the `add device` / `name:` lines of the device scan (ignored).
public struct EvdevParser {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: UnsafeRawBufferPointer, emit: (EvdevEvent) -> Void) {
        pending.append(contentsOf: bytes)
        drain(emit: emit)
    }

    public mutating func feed(_ bytes: [UInt8], emit: (EvdevEvent) -> Void) {
        pending.append(contentsOf: bytes)
        drain(emit: emit)
    }

    public mutating func feed(_ text: String, emit: (EvdevEvent) -> Void) {
        pending.append(contentsOf: Array(text.utf8))
        drain(emit: emit)
    }

    private mutating func drain(emit: (EvdevEvent) -> Void) {
        var start = 0
        var i = 0
        while i < pending.count {
            if pending[i] == 0x0A {
                let line = String(decoding: pending[start..<i], as: UTF8.self)
                if let event = EvdevParser.parseLine(line) { emit(event) }
                start = i + 1
            }
            i += 1
        }
        if start > 0 { pending.removeFirst(start) }
    }

    /// Parses one complete line; nil for anything that is not an event (device scan lines, blanks, prompts).
    public static func parseLine(_ rawLine: String) -> EvdevEvent? {
        var line = Substring(rawLine)
        while let last = line.last, last == "\r" || last == " " || last == "\t" { line.removeLast() }
        while let first = line.first, first == " " || first == "\t" { line.removeFirst() }
        if line.isEmpty { return nil }
        if line.hasPrefix("/dev/input/") {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            line = line[line.index(after: colon)...]
            while let first = line.first, first == " " { line.removeFirst() }
        }
        var tsUs: UInt64 = 0
        if line.hasPrefix("[") {
            guard let close = line.firstIndex(of: "]") else { return nil }
            let stamp = line[line.index(after: line.startIndex)..<close]
            tsUs = parseTimestamp(stamp) ?? 0
            line = line[line.index(after: close)...]
        }
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 3 else { return nil }
        let type = String(tokens[0])
        guard type.hasPrefix("EV_") || (type.count == 4 && UInt16(type, radix: 16) != nil) else { return nil }
        return EvdevEvent(tsUs: tsUs, type: type, code: String(tokens[1]), value: String(tokens[2]))
    }

    /// `   12345.678901` -> 12345678901 microseconds.
    static func parseTimestamp(_ stamp: Substring) -> UInt64? {
        let trimmed = stamp.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard let secs = UInt64(parts[0]) else { return nil }
        var micros: UInt64 = 0
        if parts.count > 1 {
            var fraction = String(parts[1])
            if fraction.count > 6 { fraction = String(fraction.prefix(6)) }
            while fraction.count < 6 { fraction.append("0") }
            micros = UInt64(fraction) ?? 0
        }
        return secs * 1_000_000 + micros
    }
}
