import CryptoKit
import DaylightKit
import Foundation
import os

// LOOSE_ENDS H1: the three adb sources (Bundled, Download on first use, Use installed adb). Every path resolves through
// `AdbClient.locateExecutable`; `AdbServerPolicy` applies unchanged to whichever executable comes back.

/// The pinned platform-tools release. `make scripts-check` asserts these equal `PT_VERSION` and `PT_SHA256` in
/// scripts/fetch-tools.sh, so the bundled copy and the downloaded copy are the same release.
struct AdbPins: Equatable {
    var version: String
    var sha256: String
    var url: URL

    static let platformToolsVersion = "37.0.0"
    static let platformToolsSHA256 = "094a1395683c509fd4d48667da0d8b5ef4d42b2abfcd29f2e8149e2f989357c7"
    /// The Android SDK License the owner accepts before the download (LOOSE_ENDS A6).
    static let termsURL = URL(string: "https://developer.android.com/studio/terms")!
    /// Use installed adb: platform-tools 35 or newer, which all print "Android Debug Bridge version 1.0.41".
    static let minimumPlatformToolsMajor = 35
    static let minimumBridgeVersion = [1, 0, 41]

    static let current = AdbPins(
        version: platformToolsVersion,
        sha256: platformToolsSHA256,
        url: URL(string: "https://dl.google.com/android/repository/platform-tools_r\(platformToolsVersion)-darwin.zip")!
    )
}

/// What `adb version` printed, e.g. "Android Debug Bridge version 1.0.41" then "Version 37.0.0-14910828".
struct AdbVersionInfo: Equatable {
    var bridge: [Int]
    /// "37.0.0-14910828"; nil when the output has no "Version" line (platform-tools older than 28).
    var platformTools: String?

    var platformToolsMajor: Int? {
        guard let pt = platformTools, let first = pt.split(whereSeparator: { $0 == "." || $0 == "-" }).first else { return nil }
        return Int(first)
    }

    /// "1.0.41 (37.0.0-14910828)", the form Settings, Diagnostics and row 43 show.
    var text: String {
        let b = bridge.map(String.init).joined(separator: ".")
        return platformTools.map { "\(b) (\($0))" } ?? b
    }

    /// At least bridge 1.0.41 and platform-tools 35; a missing "Version" line counts as too old.
    var isSupported: Bool {
        guard let major = platformToolsMajor, major >= AdbPins.minimumPlatformToolsMajor else { return false }
        return !bridge.lexicographicallyPrecedes(AdbPins.minimumBridgeVersion)
    }

    static func parse(_ output: String) -> AdbVersionInfo? {
        var bridge: [Int]?
        var platformTools: String?
        for raw in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Android Debug Bridge version ") {
                let numbers = line.dropFirst("Android Debug Bridge version ".count).split(separator: ".").map { Int($0.trimmingCharacters(in: .whitespaces)) }
                if !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) { bridge = numbers.compactMap { $0 } }
            } else if line.hasPrefix("Version ") {
                let value = line.dropFirst("Version ".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { platformTools = value }
            }
        }
        guard let b = bridge else { return nil }
        return AdbVersionInfo(bridge: b, platformTools: platformTools)
    }
}

/// Where the located adb came from (Diagnostics `mirror.adb.source`, `.path`, `.version`).
struct AdbLocation: Equatable {
    var url: URL
    var source: AdbSource
    var version: String?
}

/// Why a source produced no adb. `failure` is the SPEC 13.3 row (nil for the bundled cases and for not downloaded yet,
/// which raise no row of their own); `adbError` keeps the existing `AdbError` contract of
/// the seam (a missing bundled adb is still `.executableMissing`, so row 25's wording is unchanged).
enum AdbSourceError: Error, Equatable {
    case bundledMissing(path: String)
    case bundledNotExecutable(detail: String)
    case termsNotAccepted(version: String)
    case notDownloaded(version: String)
    case downloadFailed(reason: String, url: String)
    case checksumMismatch(got: String, want: String)
    case installedMissing(searched: [String])
    case installedTooOld(path: String, version: String)
    case installedUnreadable(path: String)

    var failure: (FailureText.Case, [String])? {
        switch self {
        case .bundledMissing, .bundledNotExecutable: return nil
        case let .termsNotAccepted(version): return (.adbTermsDeclined, [version])
        // Not downloaded yet is the state between accepting the terms and the download landing (or after a quit during
        // it), not row 40: no banner. MirrorController's download poll applies the adb when it lands, and a download
        // that really fails raises row 40 from `AdbDownloader.ensure` with its own reason.
        case .notDownloaded: return nil
        case let .downloadFailed(reason, _): return (.adbDownloadFailed, [reason])
        case let .checksumMismatch(got, want): return (.adbChecksumMismatch, [got, want])
        case .installedMissing: return (.adbInstalledMissing, [])
        case let .installedTooOld(path, version): return (.adbInstalledTooOld, [path, version])
        case let .installedUnreadable(path): return (.adbInstalledTooOld, [path, "unknown (adb version printed nothing usable)"])
        }
    }

    /// The owner-facing sentence (the row's exact text), or the technical detail for the bundled cases.
    var sentence: String {
        switch self {
        case let .bundledMissing(path): return "bundled adb missing at \(path) (run make fetch-tools)"
        case let .bundledNotExecutable(detail): return detail
        case .notDownloaded: return "adb has not been downloaded yet (Settings > Mirror > Download adb)"
        default:
            guard let row = failure else { return "\(self)" }
            // Row 41's sentence has no placeholders; its two arguments belong to the log line only.
            return row.0 == .adbChecksumMismatch ? FailureText.sentence(row.0) : FailureText.sentence(row.0, row.1)
        }
    }

    var logLine: String {
        switch self {
        case let .downloadFailed(reason, url): return FailureText.logLine(.adbDownloadFailed, [url, reason])
        case let .installedMissing(searched): return FailureText.logLine(.adbInstalledMissing, [searched.joined(separator: ", ")])
        case let .notDownloaded(version): return "adb download: platform-tools \(version) not downloaded yet"
        default:
            guard let row = failure else { return sentence }
            return FailureText.logLine(row.0, row.1)
        }
    }

    var adbError: AdbError {
        switch self {
        case let .bundledMissing(path): return .executableMissing(path)
        case let .bundledNotExecutable(detail): return .launchFailed(detail)
        default: return .launchFailed(sentence)
        }
    }
}

/// The last resolution, for Diagnostics (`DiagnosticsReport.Facts.adbSource`).
enum AdbSourceStatus {
    private static let state = Locked<(location: AdbLocation?, error: String?, requested: AdbSource?)>((nil, nil, nil))

    static func record(_ result: Result<AdbLocation, AdbSourceError>, requested: AdbSource) {
        state.withLock { s in
            s.requested = requested
            switch result {
            case let .success(location): s.location = location; s.error = nil
            case let .failure(error): s.location = nil; s.error = error.logLine
            }
        }
    }

    /// `adb.source`, `adb.path`, `adb.version` (and `adb.error` after a failure); empty before the first resolution.
    static func diagnostics() -> [String: String] {
        let s = state.withLock { $0 }
        guard let requested = s.requested else { return [:] }
        var d: [String: String] = [:]
        if let location = s.location {
            d["adb.source"] = location.source == requested ? location.source.rawValue : "\(location.source.rawValue) (chosen: \(requested.rawValue))"
            d["adb.path"] = location.url.path
            d["adb.version"] = location.version ?? "not checked"
        } else {
            d["adb.source"] = requested.rawValue
            d["adb.path"] = "none"
            d["adb.error"] = s.error ?? "unknown"
        }
        return d
    }
}

/// Runs `<adb> version` with a timeout (the installed probe and the Settings row). Never on the main thread.
enum AdbVersionProbe {
    static func run(_ executable: URL, timeout: Double = 5) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["version"]
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let output = Locked<Data>(Data())
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            output.withLock { $0 = data }
            group.leave()
        }
        do {
            try process.run()
        } catch {
            try? out.fileHandleForWriting.close()
            _ = group.wait(timeout: .now() + 1)
            return nil
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 1)
            return nil
        }
        process.waitUntilExit()
        return String(decoding: output.withLock { $0 }, as: UTF8.self)
    }
}

/// Use installed adb: the probing order of LOOSE_ENDS H1 (5). The first executable candidate wins, then its version
/// decides; an older adb is refused (row 43) rather than skipped, so the owner learns which copy is in the way.
enum AdbInstalledProbe {
    /// Apple silicon Homebrew, then Intel Homebrew.
    static let homebrewPaths = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]

    static func candidates(environment: [String: String], home: URL, homebrew: [String] = homebrewPaths) -> [URL] {
        var paths: [String] = []
        for dir in (environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            paths.append(String(dir) + "/adb")
        }
        paths.append(contentsOf: homebrew)
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key], !root.isEmpty { paths.append(root + "/platform-tools/adb") }
        }
        paths.append(home.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path)
        var seen = Set<String>()
        var urls: [URL] = []
        for p in paths {
            let standard = URL(fileURLWithPath: p).standardizedFileURL
            if seen.insert(standard.path).inserted { urls.append(standard) }
        }
        return urls
    }

    static func locate(environment: [String: String], home: URL, homebrew: [String] = homebrewPaths, fileManager: FileManager = .default,
                       versionOutput: (URL) -> String? = { AdbVersionProbe.run($0) }) -> Result<AdbLocation, AdbSourceError> {
        let list = candidates(environment: environment, home: home, homebrew: homebrew)
        guard let found = list.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            return .failure(.installedMissing(searched: list.map { $0.path }))
        }
        guard let output = versionOutput(found), let info = AdbVersionInfo.parse(output) else {
            return .failure(.installedUnreadable(path: found.path))
        }
        guard info.isSupported else { return .failure(.installedTooOld(path: found.path, version: info.text)) }
        return .success(AdbLocation(url: found, source: .installed, version: info.text))
    }
}

/// The record written next to a downloaded adb; `locate` re-checks the adb's sha256 against it before every use.
struct AdbDownloadManifest: Codable, Equatable {
    var version: String
    var zipSHA256: String
    var adbSHA256: String

    static let fileName = "daylight-platform-tools.json"
}

enum AdbSHA256 {
    /// Streams the file in 1 MiB chunks; nil when it cannot be read.
    static func hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Download on first use: fetch the pinned zip, verify its sha256 before unzipping, keep `adb` (0755) and `NOTICE.txt`
/// under `~/Library/Application Support/Daylight/platform-tools/`, remove partial files on every exit path. After that
/// the source works offline; a new pin re-downloads. `session` and `pins` are injectable (tests use a local file URL).
final class AdbDownloader {
    static let log = Logger(subsystem: "com.twelve.daylight", category: "adb")
    static let folderName = "platform-tools"

    let directory: URL
    let pins: AdbPins
    let session: URLSession
    let queue: DispatchQueue
    private let fileManager: FileManager

    init(directory: URL = AdbDownloader.defaultDirectory(), pins: AdbPins = .current, session: URLSession = .shared,
         queue: DispatchQueue = DispatchQueue(label: "com.twelve.daylight.adb.download", qos: .utility), fileManager: FileManager = .default) {
        self.directory = directory
        self.pins = pins
        self.session = session
        self.queue = queue
        self.fileManager = fileManager
    }

    /// `~/Library/Application Support/Daylight/platform-tools`.
    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent(Settings.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    var executable: URL { return directory.appendingPathComponent(AdbClient.vendorExecutableName) }
    var manifestURL: URL { return directory.appendingPathComponent(AdbDownloadManifest.fileName) }
    var noticeURL: URL { return directory.appendingPathComponent("NOTICE.txt") }

    /// The downloaded adb when it is present, of the pinned version, and its sha256 still matches the manifest. A copy
    /// that no longer matches is deleted with its manifest and notice (row 41), so the next `ensure` downloads again.
    func locateInstalled() -> Result<AdbLocation, AdbSourceError> {
        guard fileManager.isExecutableFile(atPath: executable.path),
              let data = fileManager.contents(atPath: manifestURL.path),
              let manifest = try? JSONDecoder().decode(AdbDownloadManifest.self, from: data),
              manifest.version == pins.version, manifest.zipSHA256 == pins.sha256 else {
            return .failure(.notDownloaded(version: pins.version))
        }
        guard let got = AdbSHA256.hex(of: executable), got == manifest.adbSHA256 else {
            let got = AdbSHA256.hex(of: executable) ?? "unreadable"
            // Row 41 says the copy "was deleted": remove the binary and its notice as well as the manifest.
            try? fileManager.removeItem(at: manifestURL)
            try? fileManager.removeItem(at: executable)
            try? fileManager.removeItem(at: noticeURL)
            return .failure(.checksumMismatch(got: got, want: manifest.adbSHA256))
        }
        return .success(AdbLocation(url: executable, source: .download, version: "platform-tools \(manifest.version)"))
    }

    /// Downloads when `locateInstalled` fails; completion on `queue`. The caller has checked the terms.
    func ensure(completion: @escaping (Result<AdbLocation, AdbSourceError>) -> Void) {
        queue.async {
            if case let .success(location) = self.locateInstalled() {
                completion(.success(location))
                return
            }
            let url = self.pins.url
            AdbDownloader.log.notice("adb download: \(url.absoluteString, privacy: .public)")
            let task = self.session.dataTask(with: url) { data, response, error in
                self.queue.async {
                    if let error = error {
                        completion(.failure(.downloadFailed(reason: error.localizedDescription, url: url.absoluteString)))
                        return
                    }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        completion(.failure(.downloadFailed(reason: "the server answered HTTP \(http.statusCode)", url: url.absoluteString)))
                        return
                    }
                    guard let data = data, !data.isEmpty else {
                        completion(.failure(.downloadFailed(reason: "the download was empty", url: url.absoluteString)))
                        return
                    }
                    completion(self.install(zip: data))
                }
            }
            task.resume()
        }
    }

    /// Verifies, unzips and installs one downloaded zip (on `queue`).
    func install(zip data: Data) -> Result<AdbLocation, AdbSourceError> {
        let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard got == pins.sha256 else {
            AdbDownloader.log.error("\(FailureText.logLine(.adbChecksumMismatch, [got, self.pins.sha256]), privacy: .public)")
            return .failure(.checksumMismatch(got: got, want: pins.sha256))
        }
        let work = fileManager.temporaryDirectory.appendingPathComponent("daylight-platform-tools-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: work) }
        let partial = directory.appendingPathComponent("adb.partial")
        do {
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("platform-tools.zip")
            try data.write(to: zip)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, work.appendingPathComponent("x").path]
            unzip.standardInput = FileHandle.nullDevice
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice
            try unzip.run()
            unzip.waitUntilExit()
            let extracted = work.appendingPathComponent("x/platform-tools/adb")
            guard unzip.terminationStatus == 0, fileManager.fileExists(atPath: extracted.path) else {
                return .failure(.downloadFailed(reason: "the archive has no platform-tools/adb (ditto exit \(unzip.terminationStatus))", url: pins.url.absoluteString))
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: manifestURL)
            if fileManager.fileExists(atPath: partial.path) { try fileManager.removeItem(at: partial) }
            try fileManager.copyItem(at: extracted, to: partial)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: partial.path)
            if fileManager.fileExists(atPath: executable.path) { try fileManager.removeItem(at: executable) }
            try fileManager.moveItem(at: partial, to: executable)
            let notice = work.appendingPathComponent("x/platform-tools/NOTICE.txt")
            let noticeTarget = noticeURL
            if fileManager.fileExists(atPath: notice.path) {
                if fileManager.fileExists(atPath: noticeTarget.path) { try fileManager.removeItem(at: noticeTarget) }
                try fileManager.copyItem(at: notice, to: noticeTarget)
            }
            guard let adbSHA = AdbSHA256.hex(of: executable) else {
                return .failure(.downloadFailed(reason: "the installed adb could not be read back", url: pins.url.absoluteString))
            }
            let manifest = AdbDownloadManifest(version: pins.version, zipSHA256: got, adbSHA256: adbSHA)
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: partial)
            return .failure(.downloadFailed(reason: error.localizedDescription, url: pins.url.absoluteString))
        }
        AdbDownloader.log.notice("adb download: installed platform-tools \(self.pins.version, privacy: .public) at \(self.executable.path, privacy: .public)")
        return .success(AdbLocation(url: executable, source: .download, version: "platform-tools \(pins.version)"))
    }
}

/// Everything `AdbClient.locateExecutable(source:...)` needs, so tests drive each path with fakes.
struct AdbSourceRequest {
    var source: AdbSource
    /// `DaylightBundlesAdb` in Info.plist (`make fetch-tools DAYLIGHT_BUNDLE_ADB=0` builds leave it false).
    var bundledAvailable: Bool
    var termsAcceptedVersion: String?
    var vendorDirectory: URL
    var downloader: AdbDownloader
    var environment: [String: String]
    var home: URL
    var homebrew: [String] = AdbInstalledProbe.homebrewPaths
    var versionOutput: (URL) -> String?

    init(source: AdbSource, bundledAvailable: Bool = AdbSourceRequest.bundleShipsAdb(), termsAcceptedVersion: String?, vendorDirectory: URL,
         downloader: AdbDownloader = AdbDownloader(), environment: [String: String] = ProcessInfo.processInfo.environment,
         home: URL = FileManager.default.homeDirectoryForCurrentUser, versionOutput: @escaping (URL) -> String? = { AdbVersionProbe.run($0) }) {
        self.source = source
        self.bundledAvailable = bundledAvailable
        self.termsAcceptedVersion = termsAcceptedVersion
        self.vendorDirectory = vendorDirectory
        self.downloader = downloader
        self.environment = environment
        self.home = home
        self.versionOutput = versionOutput
    }

    init(settings: Settings, vendorDirectory: URL) {
        self.init(source: settings.adbSource, termsAcceptedVersion: settings.adbTermsAcceptedVersion, vendorDirectory: vendorDirectory)
    }

    static let bundlesAdbInfoKey = "DaylightBundlesAdb"

    /// Absent or anything but a false value means bundled (every build before H1 shipped adb).
    static func bundleShipsAdb(_ bundle: Bundle = .main) -> Bool {
        return infoValueMeansBundled(bundle.object(forInfoDictionaryKey: bundlesAdbInfoKey))
    }

    static func infoValueMeansBundled(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return !["0", "no", "false"].contains(s.trimmingCharacters(in: .whitespaces).lowercased())
        default: return true
        }
    }
}
