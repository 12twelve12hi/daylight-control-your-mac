import Foundation

/// The diagnostics export's redaction (docs/FEEDBACK.md, PROTOCOL 15.3): pure, applied to every text file of the zip.
///
/// - File paths: the home folder becomes `~`; a path inside one of `keptRoots` (the app's own folders) stays, any
///   other absolute path is reduced to `.../<last component>`. Only paths that start at a filesystem root (`/Users`,
///   `/Applications`, `/private`, ...) or at `~/` count, so URL paths such as `/api/info` stay readable.
/// - Known client ids are cut to the 8-character prefix Diagnostics already shows (`3f0c1a2b...`).
/// - Wi-Fi network names (`SSID: ...`, `ssid=...`, `"ssid":"..."`) become `<ssid>`.
/// - Secrets: `Bearer <x>`, `token=`, `key=`, `password=`, `secret=` values and any hex or base64 run of 32 or more
///   characters become `<redacted>` (a `sha256` digest of a bundled file is a public fact and stays).
/// - IPv4 addresses keep their last octet (`x.x.x.40`), IPv6 addresses their last group (`x::3d4e`).
struct Redactor {
    static let ssidPlaceholder = "<ssid>"
    static let secretPlaceholder = "<redacted>"
    /// First path components that mark an absolute file path.
    static let fileSystemRoots: Set<String> = [
        "Users", "Volumes", "private", "var", "tmp", "Applications", "Library", "System", "usr", "opt", "etc", "bin",
        "sbin", "dev", "cores", "Network", "home", "nix",
    ]

    /// The user's home folder without a trailing slash, e.g. `/Users/mike`.
    let home: String
    /// Absolute folders whose paths stay (with the home folder written as `~`).
    let keptRoots: [String]
    /// Client ids (SolStream HANDSHAKE ids) to shorten to their first 8 characters.
    let clientIds: [String]

    init(home: String, keptRoots: [String], clientIds: [String] = []) {
        self.home = Redactor.trimSlash(home)
        // Longest first, so `~/Library/Application Support/Daylight` wins over `~/Library`.
        self.keptRoots = keptRoots.map(Redactor.trimSlash).filter { $0.count > 1 }.sorted { $0.count > $1.count }
        self.clientIds = clientIds.filter { $0.count > 8 }.sorted { $0.count > $1.count }
    }

    func redact(_ text: String) -> String {
        var out = redactPaths(text)
        for id in clientIds {
            out = out.replacingOccurrences(of: id, with: String(id.prefix(8)) + "...")
        }
        out = Redactor.replace(out, Redactor.ssidPattern, "$1$2" + Redactor.ssidPlaceholder)
        out = Redactor.replace(out, Redactor.ssidJSONPattern, "$1" + Redactor.ssidPlaceholder + "\"")
        out = Redactor.replace(out, Redactor.bearerPattern, "$1" + Redactor.secretPlaceholder)
        out = Redactor.replace(out, Redactor.assignmentPattern, "$1$2" + Redactor.secretPlaceholder)
        out = Redactor.replace(out, Redactor.secretJSONPattern, "$1" + Redactor.secretPlaceholder + "\"")
        out = Redactor.replace(out, Redactor.longHexPattern, Redactor.secretPlaceholder)
        out = Redactor.replaceBase64(out)
        out = Redactor.replace(out, Redactor.ipv4Pattern, "x.x.x.$1")
        out = Redactor.replaceIPv6(out)
        return out
    }

    /// One address on its own (a stored `remoteAddress`): IPv4 to `x.x.x.<last>`, IPv6 to `x::<last group>`.
    static func redactAddress(_ address: String) -> String {
        let r = Redactor(home: "/nonexistent-home", keptRoots: [])
        return r.redact(address)
    }

    // MARK: Paths

    private static let pathTerminators: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\"", "'", "<", ">", "(", ")", ",", ";", "`", "[", "]", "{", "}", "|"]
    private static let pathStartBoundary: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\"", "'", "=", "(", "[", "{", ",", ":", ";", "<", ">", "`", "|"]

    /// Works on Unicode scalars (cheap for a 4 MiB log); every boundary and separator is ASCII.
    func redactPaths(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        let filePrefix = Array("file://".unicodeScalars)
        while i < chars.count {
            let atBoundary = i == 0 || Redactor.pathStartBoundary.contains(chars[i - 1]) || Redactor.endsWith(chars, at: i, filePrefix)
            if atBoundary, let found = path(at: i, in: chars) {
                out.append(contentsOf: found.text.unicodeScalars)
                i += found.consumed
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return String(out)
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static func endsWith(_ chars: [Unicode.Scalar], at i: Int, _ suffix: [Unicode.Scalar]) -> Bool {
        guard i >= suffix.count else { return false }
        for k in 0..<suffix.count where chars[i - suffix.count + k] != suffix[k] { return false }
        return true
    }

    private static func hasPrefix(_ chars: [Unicode.Scalar], at i: Int, _ prefix: [Unicode.Scalar]) -> Bool {
        guard i + prefix.count <= chars.count else { return false }
        for k in 0..<prefix.count where chars[i + k] != prefix[k] { return false }
        return true
    }

    /// The path starting at `i` (absolute or `~/`), how many scalars it spans and what replaces it; nil when the
    /// text there is not a file path.
    private func path(at i: Int, in chars: [Unicode.Scalar]) -> (consumed: Int, text: String)? {
        let isTilde = chars[i] == "~" && i + 1 < chars.count && chars[i + 1] == "/"
        guard chars[i] == "/" || isTilde else { return nil }
        // A kept root first: it may contain spaces ("Application Support", "Daylight Camera").
        for root in keptRoots {
            for form in forms(of: root) {
                let f = Array(form.unicodeScalars)
                guard Redactor.hasPrefix(chars, at: i, f) else { continue }
                let after = i + f.count
                if after < chars.count && chars[after] != "/" && !Redactor.pathTerminators.contains(chars[after]) { continue }
                var end = after
                while end < chars.count && !Redactor.pathTerminators.contains(chars[end]) { end += 1 }
                return (consumed: end - i, text: tilde(Redactor.string(chars[i..<end])))
            }
        }
        var end = i
        while end < chars.count && !Redactor.pathTerminators.contains(chars[end]) { end += 1 }
        let token = Redactor.string(chars[i..<end])
        // `//host/...` is a URL authority (`http://`), not a file path.
        if token.hasPrefix("//") { return nil }
        let absolute = isTilde ? home + String(token.dropFirst()) : token
        let components = absolute.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = components.first, Redactor.fileSystemRoots.contains(String(first)) else { return nil }
        if absolute == home || absolute == home + "/" { return (consumed: end - i, text: "~") }
        guard let last = components.last else { return nil }
        return (consumed: end - i, text: ".../" + String(last))
    }

    private func forms(of root: String) -> [String] {
        if root == home { return [root] }
        if root.hasPrefix(home + "/") { return [root, "~" + String(root.dropFirst(home.count))] }
        return [root]
    }

    private func tilde(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    private static func trimSlash(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: Patterns

    private static let ssidPattern = regex("(?i)\\b(b?ssid)(\\s*[:=]\\s*)(?!\")[^\\n\\r,;\"]+")
    private static let ssidJSONPattern = regex("(?i)(\"b?ssid\"\\s*:\\s*\")[^\"]*\"")
    private static let bearerPattern = regex("(?i)\\b(bearer\\s+)[A-Za-z0-9._~+/=-]+")
    private static let assignmentPattern = regex("(?i)\\b(token|key|password|passwd|secret|api_key|apikey)(\\s*=\\s*)[^\\s&;,\"'<>]+")
    private static let secretJSONPattern = regex("(?i)(\"(?:token|password|passwd|secret|apiKey|api_key)\"\\s*:\\s*\")[^\"]*\"")
    private static let longHexPattern = regex("(?i)(?<!sha256 )(?<!sha256=)(?<!sha256: )(?<![0-9a-f])[0-9a-f]{32,}(?![0-9a-f])")
    private static let base64Candidate = regex("(?<![A-Za-z0-9+/_-])[A-Za-z0-9+/_-]{32,}={0,2}")
    private static let ipv4Pattern = regex("(?<![0-9.])(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(?![0-9]|\\.[0-9])")
    /// Starts after a non-address character, or after a word and one colon (`web:fe80::1`, the tablet facts key of a
    /// sender without a client id, finder DX-1).
    private static let ipv6Candidate = regex("(?:(?<![0-9A-Za-z:.])|(?<=[A-Za-z]{2}:))(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{1,4}(?![0-9A-Fa-f:])")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a typo fails the first test that redacts anything.
        return try! NSRegularExpression(pattern: pattern)
    }

    private static func replace(_ text: String, _ regex: NSRegularExpression, _ template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// A base64 or base64url run of 32+ characters that mixes upper case, lower case and digits and has no `/` (a path
    /// such as `Contents/Library/SystemExtensions` is not a secret).
    private static func replaceBase64(_ text: String) -> String {
        return replaceMatches(text, base64Candidate) { match in
            let core = match.trimmingCharacters(in: CharacterSet(charactersIn: "="))
            let hasUpper = core.contains { $0.isUppercase }
            let hasLower = core.contains { $0.isLowercase }
            let hasDigit = core.contains { $0.isNumber }
            if hasUpper && hasLower && hasDigit && !core.contains("/") { return secretPlaceholder }
            return nil
        }
    }

    /// Compressed (`::`) or full (seven colons) IPv6 literals; times such as `14:05:09` and MAC addresses do not
    /// qualify.
    private static func replaceIPv6(_ text: String) -> String {
        return replaceMatches(text, ipv6Candidate) { match in
            let colons = match.filter { $0 == ":" }.count
            guard match.contains("::") || colons == 7 else { return nil }
            let last = match.split(separator: ":").last.map(String.init) ?? ""
            return "x::" + last
        }
    }

    /// Replaces each match for which `transform` returns a string; nil keeps the match.
    private static func replaceMatches(_ text: String, _ regex: NSRegularExpression, _ transform: (String) -> String?) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            let r = match.range
            out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            let original = ns.substring(with: r)
            out += transform(original) ?? original
            cursor = r.location + r.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
