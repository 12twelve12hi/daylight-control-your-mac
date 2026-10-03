import CryptoKit
import DaylightKit
import Foundation
import os

/// The diagnostics export (docs/FEEDBACK.md, SPEC 13.3 rows 44 to 47): collects every part, redacts it, bounds it and
/// writes one store-only zip. `export` is synchronous and slow (it runs `log show` and friends); the app calls it on
/// `DiagnosticsExporter.queue` only. Owner-facing progress and errors leave through `onEvent` (one FailureText row each).
final class DiagnosticsExporter {
    /// The one serial queue all slow export work runs on.
    static let queue = DispatchQueue(label: "com.twelve.daylight.export", qos: .utility)
    static let maxZipBytes = 16 * 1024 * 1024
    static let logLineLimit = 2000
    static let perfLineLimit = 2000
    static let logPredicate = "subsystem == \"com.twelve.daylight\""

    /// The files of the zip, in archive order after MANIFEST.txt; names and caps are fixed.
    enum Part: String, CaseIterable {
        case diagnostics = "diagnostics.txt"
        case system = "system.txt"
        case settings = "settings.json"
        case unifiedLog = "unified-log.txt"
        case extensionStatus = "extension-status.txt"
        case selfTest = "self-test.txt"
        case perfLog = "perf-log.txt"
        case vendor = "vendor.txt"
        case clients = "clients.json"
        case tabletFacts = "tablet-facts.json"
        case manifest = "MANIFEST.txt"

        /// Byte cap per file; the sum stays well under the 16 MiB zip limit.
        var cap: Int {
            switch self {
            case .diagnostics: return 1 << 20
            case .system: return 64 << 10
            case .settings: return 256 << 10
            case .unifiedLog: return 4 << 20
            case .extensionStatus: return 256 << 10
            case .selfTest: return 1 << 20
            case .perfLog: return 512 << 10
            case .vendor: return 64 << 10
            case .clients: return 256 << 10
            case .tabletFacts: return 1 << 20
            case .manifest: return 64 << 10
            }
        }

        /// Logs keep their newest bytes when cut; every other file keeps its head.
        var keepsTail: Bool {
            return self == .unifiedLog || self == .selfTest || self == .perfLog
        }

        /// The `<part>` of row 46.
        var ownerName: String {
            switch self {
            case .diagnostics: return "the Diagnostics text"
            case .system: return "the system facts"
            case .settings: return "the settings"
            case .unifiedLog: return "the unified log"
            case .extensionStatus: return "the extension status"
            case .selfTest: return "the self-test"
            case .perfLog: return "the perf log"
            case .vendor: return "the vendor facts"
            case .clients: return "the allowed tablets"
            case .tabletFacts: return "the tablet facts"
            case .manifest: return "the manifest"
            }
        }

        /// The one-line MANIFEST note.
        var note: String {
            switch self {
            case .diagnostics: return "the Diagnostics window text (SPEC 13.2)"
            case .system: return "macOS version, Mac model, build number and signing"
            case .settings: return "the settings as SettingsStore stores them (the save folder is kept as is)"
            case .unifiedLog: return "the last \(DiagnosticsExporter.logLineLimit) lines of log show for subsystem com.twelve.daylight"
            case .extensionStatus: return "systemextensionsctl list"
            case .selfTest: return "Daylight --self-test, run as a child process"
            case .perfLog: return "the perf lines (--perf-log or Settings > Perf log) this run kept in memory"
            case .vendor: return "the adb source, the bundled Vendor folder and adb version"
            case .clients: return "allowed tablets (clients.json), addresses cut to the last octet"
            case .tabletFacts: return "facts the tablets sent with Send facts to Mac (PROTOCOL 15)"
            case .manifest: return "this list"
            }
        }
    }

    /// What the main thread hands over (AppDelegate state is read there, never on the export queue).
    struct Snapshot {
        var date: Date
        var diagnosticsText: String
        var settings: Settings
        var perfLines: [String]
        var tabletFacts: [TabletFactsStore.Entry]
        var adbSource: [String: String]
        var version: String
        var build: String
        var signed: Bool
        var bundlePath: String
        var bundleIdentifier: String
    }

    struct Config {
        /// Where the zip goes (~/Documents/Daylight Camera in the app, a temp folder in tests and the self-test).
        var folder: URL
        var clientsFile: URL
        var vendorDirectory: URL?
        /// The app's own executable for "Run self-test first"; nil leaves self-test.txt out.
        var selfTestExecutable: URL?
        var home: String
        /// The app's folders whose paths survive redaction (Redactor).
        var keptRoots: [String]
        var logShowLast = "2h"
        var logShowTimeout: Double = 20
        var extensionTimeout: Double = 10
        var selfTestTimeout: Double = 120
        var adbVersionTimeout: Double = 5
        var timeZone: TimeZone = .current
        var osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
        var macModel: String = DiagnosticsExporter.hardwareModel()

        init(folder: URL, clientsFile: URL, vendorDirectory: URL?, selfTestExecutable: URL?, home: String, keptRoots: [String]) {
            self.folder = folder
            self.clientsFile = clientsFile
            self.vendorDirectory = vendorDirectory
            self.selfTestExecutable = selfTestExecutable
            self.home = home
            self.keptRoots = keptRoots
        }
    }

    enum Event: Equatable {
        case running(String)
        case saved(name: String, bytes: Int, files: Int)
        case partMissing(part: String, reason: String)
        case failed(String)

        /// The SPEC 13.3 row for the menu (AppModel.noteFailure) and its arguments.
        var failure: (FailureText.Case, [String]) {
            switch self {
            case let .running(step): return (.diagnosticsExportRunning, [step])
            case let .saved(name, bytes, files): return (.diagnosticsExportSaved, [name, "\(bytes)", "\(files)"])
            case let .partMissing(part, reason): return (.diagnosticsExportPartial, [part, reason])
            case let .failed(reason): return (.diagnosticsExportFailed, [reason])
            }
        }
    }

    struct Outcome: Equatable {
        let url: URL
        let bytes: Int
        /// Every file name in the zip, MANIFEST.txt first.
        let files: [String]
        /// Part file name to the reason it is missing.
        let missing: [String: String]
        /// Part file name to the size before the cap.
        let truncated: [String: Int]
    }

    struct ExportError: Error, Equatable {
        let reason: String
    }

    /// One collected file before it goes into the zip.
    struct Collected {
        var part: Part
        var data: Data?
        var missingReason: String?
        var extraNote: String?
        var truncatedFrom: Int?
        /// Missing parts that the owner hears about (row 46): the bounded commands.
        var reportMissing = false
    }

    let config: Config
    let runner: CommandRunning
    var onEvent: ((Event) -> Void)?
    private let log = Logger(subsystem: Telemetry.subsystem, category: "export")

    init(config: Config, runner: CommandRunning = ProcessCommandRunner()) {
        self.config = config
        self.runner = runner
    }

    // MARK: Export

    /// Collects, writes and returns the zip; events go to `onEvent` on the calling thread.
    @discardableResult
    func export(_ snapshot: Snapshot, runSelfTest: Bool) -> Result<Outcome, ExportError> {
        emit(.running("collecting app facts"))
        let clientsText = try? String(contentsOf: config.clientsFile, encoding: .utf8)
        let ids = DiagnosticsExporter.clientIds(clientsJSON: clientsText) + snapshot.tabletFacts.compactMap { $0.clientId }
        let redactor = Redactor(home: config.home, keptRoots: config.keptRoots, clientIds: ids)
        var parts: [Collected] = []
        parts.append(text(.diagnostics, snapshot.diagnosticsText, redactor))
        parts.append(text(.system, systemText(snapshot), redactor))
        parts.append(settingsPart(snapshot.settings, redactor))
        emit(.running("reading the log"))
        parts.append(unifiedLog(redactor))
        emit(.running("listing system extensions"))
        parts.append(extensionStatus(redactor))
        if runSelfTest {
            emit(.running("running the self-test"))
            parts.append(selfTest(redactor))
        }
        parts.append(perfLog(snapshot.perfLines, redactor))
        parts.append(text(.vendor, vendorText(snapshot.adbSource), redactor))
        parts.append(clientsPart(clientsText, redactor))
        parts.append(tabletFactsPart(snapshot.tabletFacts, redactor))

        emit(.running("writing the zip"))
        let manifest = manifestText(snapshot, parts: parts, runSelfTest: runSelfTest, redactor: redactor)
        var zip = ZipWriter(date: snapshot.date, timeZone: config.timeZone)
        zip.add(Part.manifest.rawValue, DiagnosticsExporter.bound(Data(manifest.utf8), cap: Part.manifest.cap, keepTail: false).data)
        var files = [Part.manifest.rawValue]
        for part in parts {
            guard let data = part.data else { continue }
            zip.add(part.part.rawValue, data)
            files.append(part.part.rawValue)
        }
        let archive = zip.finish()
        guard archive.count <= DiagnosticsExporter.maxZipBytes else {
            return fail("the zip would be \(archive.count) bytes, above 16 MiB")
        }
        let url: URL
        do {
            try FileManager.default.createDirectory(at: config.folder, withIntermediateDirectories: true)
            url = DiagnosticsExporter.uniqueURL(in: config.folder, date: snapshot.date, timeZone: config.timeZone)
            try archive.write(to: url, options: [.withoutOverwriting])
        } catch {
            return fail(error.localizedDescription)
        }
        var missing: [String: String] = [:]
        var truncated: [String: Int] = [:]
        for part in parts {
            if let reason = part.missingReason { missing[part.part.rawValue] = reason }
            if let from = part.truncatedFrom { truncated[part.part.rawValue] = from }
        }
        log.notice("diagnostics export: wrote \(url.lastPathComponent, privacy: .public) (\(archive.count) bytes, \(files.count) files)")
        emit(.saved(name: url.lastPathComponent, bytes: archive.count, files: files.count))
        for part in parts where part.reportMissing {
            emit(.partMissing(part: part.part.ownerName, reason: part.missingReason ?? "unknown"))
        }
        return .success(Outcome(url: url, bytes: archive.count, files: files, missing: missing, truncated: truncated))
    }

    /// `export` on `DiagnosticsExporter.queue`; `completion` runs on that queue too.
    func start(_ snapshot: Snapshot, runSelfTest: Bool, completion: @escaping (Result<Outcome, ExportError>) -> Void) {
        DiagnosticsExporter.queue.async {
            completion(self.export(snapshot, runSelfTest: runSelfTest))
        }
    }

    private func emit(_ event: Event) {
        if case let .running(step) = event { log.notice("diagnostics export: \(step, privacy: .public)") }
        onEvent?(event)
    }

    private func fail(_ reason: String) -> Result<Outcome, ExportError> {
        log.error("diagnostics export failed: \(reason, privacy: .public)")
        emit(.failed(reason))
        return .failure(ExportError(reason: reason))
    }

    // MARK: Parts

    private func text(_ part: Part, _ text: String, _ redactor: Redactor) -> Collected {
        return finish(Collected(part: part), redactor.redact(text))
    }

    /// Redacted text through the part's cap; records the original size when it was cut.
    private func finish(_ collected: Collected, _ text: String) -> Collected {
        var c = collected
        let bounded = DiagnosticsExporter.bound(Data(text.utf8), cap: c.part.cap, keepTail: c.part.keepsTail)
        c.data = bounded.data
        c.truncatedFrom = bounded.truncatedFrom
        return c
    }

    private func settingsPart(_ settings: Settings, _ redactor: Redactor) -> Collected {
        // The encoder SettingsStore.persist uses, so the file reads like the stored blob.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(settings) else {
            return Collected(part: .settings, data: nil, missingReason: "the settings did not encode")
        }
        let json = String(decoding: data, as: UTF8.self)
        return finish(Collected(part: .settings), DiagnosticsExporter.redactKeepingValue(json, key: "saveDirectory", redactor))
    }

    /// Redacts a JSON text but keeps the string value of `key` byte for byte (the owner's save folder, by ticket).
    static func redactKeepingValue(_ json: String, key: String, _ redactor: Redactor) -> String {
        let marker = "\"\(key)\":\""
        guard let start = json.range(of: marker), let close = json[start.upperBound...].firstIndex(of: "\"") else {
            return redactor.redact(json)
        }
        let value = String(json[start.upperBound..<close])
        let placeholder = "DAYLIGHTKEPTVALUE"
        let protected = json.replacingCharacters(in: start.upperBound..<close, with: placeholder)
        return redactor.redact(protected).replacingOccurrences(of: placeholder, with: value)
    }

    private func unifiedLog(_ redactor: Redactor) -> Collected {
        let arguments = ["show", "--predicate", DiagnosticsExporter.logPredicate, "--last", config.logShowLast, "--style", "compact"]
        let result = runner.run("/usr/bin/log", arguments, timeout: config.logShowTimeout, maxBytes: Part.unifiedLog.cap)
        return commandPart(.unifiedLog, result, tool: "log show", timeout: config.logShowTimeout, lineLimit: DiagnosticsExporter.logLineLimit, keepOnFailure: false, redactor)
    }

    private func extensionStatus(_ redactor: Redactor) -> Collected {
        let result = runner.run("/usr/bin/systemextensionsctl", ["list"], timeout: config.extensionTimeout, maxBytes: Part.extensionStatus.cap)
        return commandPart(.extensionStatus, result, tool: "systemextensionsctl list", timeout: config.extensionTimeout, lineLimit: nil, keepOnFailure: false, redactor)
    }

    /// A child process, never in-process: SelfTest.run builds its own pipeline, listener and Metal objects and prints
    /// to stdout, which must not share the running app's state; a crash or hang there cannot take the app down, and
    /// the 120 s timeout ends it.
    private func selfTest(_ redactor: Redactor) -> Collected {
        guard let executable = config.selfTestExecutable else {
            return Collected(part: .selfTest, data: nil, missingReason: "the app's executable was not found", reportMissing: true)
        }
        let result = runner.run(executable.path, ["--self-test"], timeout: config.selfTestTimeout, maxBytes: Part.selfTest.cap)
        return commandPart(.selfTest, result, tool: "the self-test", timeout: config.selfTestTimeout, lineLimit: nil, keepOnFailure: true, redactor)
    }

    /// A bounded command's output: missing (row 46) when it could not run, timed out with nothing, or failed (unless
    /// `keepOnFailure`, where a non-zero exit is the answer itself, as for a failing self-test probe).
    private func commandPart(_ part: Part, _ result: CommandResult, tool: String, timeout: Double, lineLimit: Int?, keepOnFailure: Bool, _ redactor: Redactor) -> Collected {
        if let error = result.launchError {
            return missing(part, "\(tool) could not start: \(redactor.redact(error))")
        }
        if result.timedOut && result.output.isEmpty {
            return missing(part, "\(tool) timed out after \(Int(timeout)) s")
        }
        if let status = result.exitStatus, status != 0, !keepOnFailure {
            let first = result.text.split(separator: "\n").first.map(String.init) ?? ""
            return missing(part, "\(tool) exited with status \(status)\(first.isEmpty ? "" : ": " + redactor.redact(String(first.prefix(200))))")
        }
        // Bounded before the line cut and the redaction (a runner that ignored maxBytes must not cost a 10 MiB pass).
        let pre = DiagnosticsExporter.bound(result.output, cap: part.cap, keepTail: part.keepsTail)
        var text = String(decoding: pre.data, as: UTF8.self)
        if let limit = lineLimit {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.last == "" { lines.removeLast() }
            if lines.count > limit { text = lines.suffix(limit).joined(separator: "\n") + "\n" }
        }
        var c = Collected(part: part)
        if result.timedOut { c.extraNote = "partial: \(tool) timed out after \(Int(timeout)) s" }
        if let status = result.exitStatus, status != 0 { c.extraNote = "exit status \(status)" }
        let bounded = DiagnosticsExporter.bound(Data(redactor.redact(text).utf8), cap: part.cap, keepTail: part.keepsTail)
        c.data = bounded.data
        if result.truncated || pre.truncatedFrom != nil || bounded.truncatedFrom != nil {
            c.truncatedFrom = max(result.totalBytes, result.output.count, bounded.truncatedFrom ?? 0)
        }
        log.notice("diagnostics export: \(part.rawValue, privacy: .public) \(bounded.data.count) bytes")
        return c
    }

    private func missing(_ part: Part, _ reason: String) -> Collected {
        log.notice("diagnostics export: \(part.rawValue, privacy: .public) unavailable: \(reason, privacy: .public)")
        return Collected(part: part, data: nil, missingReason: reason, reportMissing: true)
    }

    private func perfLog(_ lines: [String], _ redactor: Redactor) -> Collected {
        guard !lines.isEmpty else {
            return Collected(part: .perfLog, data: nil, missingReason: "no perf lines in this run (the perf log is off: Settings > Perf log or --perf-log)")
        }
        let text = lines.suffix(DiagnosticsExporter.perfLineLimit).joined(separator: "\n") + "\n"
        return finish(Collected(part: .perfLog), redactor.redact(text))
    }

    private func clientsPart(_ text: String?, _ redactor: Redactor) -> Collected {
        guard let text = text else {
            return Collected(part: .clients, data: nil, missingReason: "no clients.json yet (no tablet was allowed on this Mac)")
        }
        return finish(Collected(part: .clients), redactor.redact(text))
    }

    private func tabletFactsPart(_ entries: [TabletFactsStore.Entry], _ redactor: Redactor) -> Collected {
        let object: [String: Any] = ["schema": "daylight-tablet-facts-export/1", "entries": entries.map(TabletFactsStore.exportObject)]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return Collected(part: .tabletFacts, data: nil, missingReason: "the stored facts did not encode")
        }
        return finish(Collected(part: .tabletFacts), redactor.redact(String(decoding: data, as: UTF8.self)))
    }

    private func systemText(_ s: Snapshot) -> String {
        var lines: [String] = []
        lines.append("macOS: \(config.osVersion)")
        lines.append("Mac model: \(config.macModel)")
        lines.append("DaylightBuildSigned: \(s.signed)")
        lines.append("CFBundleShortVersionString: \(s.version)")
        lines.append("CFBundleVersion: \(s.build) (the CI run number)")
        lines.append("CFBundleIdentifier: \(s.bundleIdentifier)")
        lines.append("bundle: \(s.bundlePath)")
        lines.append("in /Applications: \(s.bundlePath.hasPrefix("/Applications/"))")
        lines.append("processors: \(ProcessInfo.processInfo.activeProcessorCount), memory: \(ProcessInfo.processInfo.physicalMemory >> 20) MiB")
        lines.append("time zone: \(config.timeZone.identifier)")
        return lines.joined(separator: "\n") + "\n"
    }

    private func vendorText(_ adbSource: [String: String]) -> String {
        var lines: [String] = []
        lines.append("adb source (Settings > Mirror > adb source):")
        if adbSource.isEmpty { lines.append("  not resolved in this run (mirror mode not started)") }
        for key in adbSource.keys.sorted() { lines.append("  \(key): \(adbSource[key] ?? "")") }
        guard let vendor = config.vendorDirectory else {
            lines.append("vendor folder: none")
            return lines.joined(separator: "\n") + "\n"
        }
        lines.append("vendor folder: \(vendor.path)")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: vendor.path)) ?? []
        if names.isEmpty { lines.append("  empty or missing (make fetch-tools)") }
        for name in names.sorted() {
            let path = vendor.appendingPathComponent(name).path
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
            var line = "  \(name): \(size) bytes"
            if FileManager.default.isExecutableFile(atPath: path) { line += ", executable" }
            if name.hasPrefix("scrcpy-server"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                line += ", sha256 " + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            lines.append(line)
        }
        let adb = vendor.appendingPathComponent("adb").path
        if FileManager.default.isExecutableFile(atPath: adb) {
            let result = runner.run(adb, ["version"], timeout: config.adbVersionTimeout, maxBytes: 16 << 10)
            lines.append("bundled adb version:")
            if let error = result.launchError {
                lines.append("  could not start: \(error)")
            } else if result.timedOut {
                lines.append("  timed out after \(Int(config.adbVersionTimeout)) s")
            } else {
                lines.append(contentsOf: result.text.split(separator: "\n").map { "  " + $0 })
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func manifestText(_ s: Snapshot, parts: [Collected], runSelfTest: Bool, redactor: Redactor) -> String {
        var lines: [String] = []
        lines.append("Daylight diagnostics export")
        lines.append("created: \(TabletFactsStore.iso8601(s.date)) (local \(DiagnosticsExporter.stamp(s.date, timeZone: config.timeZone)))")
        lines.append("app: Daylight \(s.version) (\(s.build)) signed=\(s.signed)")
        lines.append("redaction: IP addresses cut to the last octet or group, Wi-Fi names, tokens and file paths outside Daylight's folders removed; settings.json keeps the save folder")
        lines.append("")
        lines.append("files:")
        lines.append("- \(Part.manifest.rawValue): \(Part.manifest.note)")
        for part in parts {
            guard let data = part.data else { continue }
            var note = part.part.note
            if let extra = part.extraNote { note += "; " + extra }
            if let from = part.truncatedFrom { note += "; truncated to \(data.count) of \(from) bytes" }
            lines.append("- \(part.part.rawValue) (\(data.count) bytes): \(note)")
        }
        lines.append("")
        lines.append("missing:")
        var missing = parts.filter { $0.data == nil }.map { "- \($0.part.rawValue): \($0.missingReason ?? "unknown")" }
        if !runSelfTest { missing.append("- \(Part.selfTest.rawValue): not requested (Run self-test first was off)") }
        lines.append(contentsOf: missing.isEmpty ? ["- none"] : missing)
        lines.append("")
        lines.append("truncated:")
        let cut = parts.compactMap { p -> String? in
            guard let from = p.truncatedFrom, let data = p.data else { return nil }
            return "- \(p.part.rawValue): truncated to \(data.count) of \(from) bytes (cap \(p.part.cap))"
        }
        lines.append(contentsOf: cut.isEmpty ? ["- none"] : cut)
        return redactor.redact(lines.joined(separator: "\n") + "\n")
    }

    // MARK: Helpers

    /// At most `cap` bytes: the tail (from the first whole line) or the head (to the last whole line).
    static func bound(_ data: Data, cap: Int, keepTail: Bool) -> (data: Data, truncatedFrom: Int?) {
        guard data.count > cap else { return (data, nil) }
        let newline = UInt8(ascii: "\n")
        if keepTail {
            var cut = Data(data.suffix(cap))
            if let first = cut.prefix(4096).firstIndex(of: newline) { cut = Data(cut[cut.index(after: first)...]) }
            return (cut, data.count)
        }
        var cut = Data(data.prefix(cap))
        if let last = cut.suffix(4096).lastIndex(of: newline) { cut = Data(cut[...last]) }
        return (cut, data.count)
    }

    /// `yyyy-MM-dd-HH-mm` in local time.
    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HH-mm"
        return formatter.string(from: date)
    }

    /// `diagnostics-<stamp>.zip`, then `-2`, `-3`, ... when the name is taken.
    static func uniqueURL(in folder: URL, date: Date, timeZone: TimeZone, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let base = "diagnostics-\(stamp(date, timeZone: timeZone))"
        var candidate = folder.appendingPathComponent(base + ".zip")
        var n = 2
        while exists(candidate) && n < 1000 {
            candidate = folder.appendingPathComponent("\(base)-\(n).zip")
            n += 1
        }
        return candidate
    }

    /// The `id` of every record in a clients.json text.
    static func clientIds(clientsJSON: String?) -> [String] {
        guard let text = clientsJSON, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let clients = object["clients"] as? [[String: Any]] else { return [] }
        return clients.compactMap { $0["id"] as? String }
    }

    /// `hw.model` (sysctlbyname), e.g. `Mac15,3`.
    static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
