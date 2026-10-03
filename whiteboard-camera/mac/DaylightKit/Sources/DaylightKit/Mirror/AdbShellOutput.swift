import Foundation

/// Parsers for the one-line answers of `adb shell` commands the mirror controller consults before acting
/// (ARCHITECTURE 6 items 2 and 9). Every parser is forgiving: an unexpected answer reads as "unknown" so the caller
/// falls back to the action it would have taken anyway (install, tcpip).
public enum AdbShellOutput {
    /// `pm path <package>` prints `package:/data/app/.../base.apk` (one line per split) when the package is installed and
    /// nothing (exit 1) when it is not. True only when a `package:` line is present.
    public static func packageInstalled(pmPathOutput: String) -> Bool {
        for line in lines(pmPathOutput) where line.hasPrefix("package:") {
            return line.count > "package:".count
        }
        return false
    }

    /// The first `versionCode=N` in `dumpsys package <package>` (the line reads `versionCode=3 minSdk=29 targetSdk=34`),
    /// or nil when the package is unknown (`Unable to find package:`) or the answer has no such field.
    public static func versionCode(dumpsysPackageOutput: String) -> Int? {
        let marker = "versionCode="
        for line in lines(dumpsysPackageOutput) {
            guard let range = line.range(of: marker) else { continue }
            let digits = line[range.upperBound...].prefix(while: { $0 >= "0" && $0 <= "9" })
            if !digits.isEmpty, let value = Int(digits) { return value }
        }
        return nil
    }

    /// `getprop service.adb.tcp.port` prints the port adbd listens on over TCP, or an empty line (or `-1`) when adbd is
    /// in USB mode. Nil when no port is set.
    public static func tcpPort(getpropOutput: String) -> UInt16? {
        guard let first = lines(getpropOutput).first else { return nil }
        guard let value = Int(first), value > 0, value <= Int(UInt16.max) else { return nil }
        return UInt16(value)
    }

    /// Non-empty trimmed lines, CRLF tolerant (adb shell without `-T` may emit `\r\n`).
    static func lines(_ output: String) -> [String] {
        var out: [String] = []
        for raw in output.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { out.append(line) }
        }
        return out
    }
}
