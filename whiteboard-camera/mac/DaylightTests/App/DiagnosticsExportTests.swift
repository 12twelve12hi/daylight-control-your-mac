import DaylightKit
import Foundation
import XCTest
@testable import Daylight

/// A `CommandRunning` that answers from a table keyed by the executable's last path component.
final class FakeCommandRunner: CommandRunning {
    var results: [String: CommandResult] = [:]
    private let lock = NSLock()
    private var recorded: [(String, [String], Double)] = []

    var calls: [(String, [String], Double)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ executable: String, _ arguments: [String], timeout: Double, maxBytes: Int) -> CommandResult {
        lock.lock()
        recorded.append((executable, arguments, timeout))
        lock.unlock()
        let name = (executable as NSString).lastPathComponent
        return results[name] ?? CommandResult(output: Data("fake \(name) output\n".utf8))
    }
}

/// The ZIP writer and reader on their own, and a real tool (`/usr/bin/unzip`) accepting what the writer produces.
final class ZipArchiveTests: XCTestCase {
    func testCRC32CheckValue() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testRoundTripIsDeterministic() throws {
        var binary = Data()
        for i in 0..<70000 { binary.append(UInt8(truncatingIfNeeded: i &* 31)) }
        let date = Date(timeIntervalSince1970: 1_791_036_309)   // 2026-10-03 14:05:09 UTC
        let utc = TimeZone(identifier: "UTC")!
        var a = ZipWriter(date: date, timeZone: utc)
        a.add("MANIFEST.txt", Data("files:\n".utf8))
        a.add("empty.txt", Data())
        a.add("binary.bin", binary)
        var b = ZipWriter(date: date, timeZone: utc)
        b.add("MANIFEST.txt", Data("files:\n".utf8))
        b.add("empty.txt", Data())
        b.add("binary.bin", binary)
        let archive = a.finish()
        XCTAssertEqual(archive, b.finish(), "same entries and date, same bytes")
        let entries = try ZipReader.entries(archive)
        XCTAssertEqual(entries.map { $0.name }, ["MANIFEST.txt", "empty.txt", "binary.bin"])
        XCTAssertEqual(entries[1].data, Data())
        XCTAssertEqual(entries[2].data, binary)
        XCTAssertEqual(entries[2].crc, CRC32.checksum(binary))
    }

    func testCorruptedEntryFailsTheCRC() throws {
        var w = ZipWriter(date: Date(), timeZone: TimeZone(identifier: "UTC")!)
        w.add("a.txt", Data("hello".utf8))
        var archive = w.finish()
        // The local header is 30 bytes plus the 5-byte name; the first data byte follows.
        archive[35] = UInt8(ascii: "j")
        XCTAssertThrowsError(try ZipReader.entries(archive)) { error in
            XCTAssertEqual(error as? ZipReadError, .crcMismatch("a.txt"))
        }
        XCTAssertThrowsError(try ZipReader.entries(Data("not a zip".utf8)))
    }

    func testUnzipAcceptsTheArchive() throws {
        var w = ZipWriter(date: Date(), timeZone: .current)
        w.add("MANIFEST.txt", Data("- a.txt (5 bytes): note\n".utf8))
        w.add("a.txt", Data("hello".utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try w.finish().write(to: url)
        let test = DiagnosticsExportTests.runTool("/usr/bin/unzip", ["-t", url.path])
        XCTAssertEqual(test.status, 0, test.output)
        XCTAssertTrue(test.output.contains("No errors detected"), test.output)
        let list = DiagnosticsExportTests.runTool("/usr/bin/unzip", ["-l", url.path])
        XCTAssertEqual(list.status, 0, list.output)
        XCTAssertTrue(list.output.contains("MANIFEST.txt") && list.output.contains("a.txt"), list.output)
    }
}

final class RedactorTests: XCTestCase {
    private let redactor = Redactor(
        home: "/Users/mike",
        keptRoots: ["/Users/mike/Documents/Daylight Camera", "/Users/mike/Library/Application Support/Daylight", "/Users/mike/Library/Logs", "/Applications/Daylight.app"],
        clientIds: ["6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b"])

    func testAddresses() {
        XCTAssertEqual(redactor.redact("from 192.168.1.40 and http://100.101.102.103:7788/ink"), "from x.x.x.40 and http://x.x.x.103:7788/ink")
        XCTAssertEqual(redactor.redact("fe80::1c2b:3d4e:5f60:7a8b%en0 and ::1"), "x::7a8b%en0 and x::1")
        XCTAssertEqual(redactor.redact("2001:0db8:85a3:0000:0000:8a2e:0370:7334"), "x::7334")
        XCTAssertEqual(redactor.redact("at 14:05:09.123 chrome 141.0.7390.54 adb 1.0.41 mac a4:83:e7:12:34:56"), "at 14:05:09.123 chrome 141.0.7390.54 adb 1.0.41 mac a4:83:e7:12:34:56", "times, versions and MAC addresses stay")
        XCTAssertEqual(redactor.redact(redactor.redact("192.168.1.40 fe80::1")), "x.x.x.40 x::1", "redaction is idempotent")
        XCTAssertEqual(Redactor.redactAddress("10.0.0.7"), "x.x.x.7")
        XCTAssertEqual(Redactor.redactAddress("fe80::abcd"), "x::abcd")
    }

    /// Finder DX-1: the facts key of a sender without a client id is `<source>:<address>`; an IPv6 address right after
    /// `web:` or `ink:` was left whole in diagnostics.txt and tablet-facts.json.
    func testIPv6InAFactsKeyIsCut() {
        let address = "fe80::1c2b:3d4e:5f60:7a8b"
        let entry = TabletFactsStore.Entry(
            key: TabletFactsStore.key(source: "web", clientId: nil, remoteAddress: address), source: "web", clientId: nil,
            sentAt: "2026-10-03T14:05:09Z", facts: [:], receivedAt: Date(timeIntervalSince1970: 1_791_036_309), remoteAddress: address, allowed: false)
        XCTAssertEqual(redactor.redact(TabletFactsStore.diagnosticsLine(entry)), "tablet facts: web:x::7a8b received 2026-10-03T14:05:09Z (0 facts)")
        XCTAssertEqual(redactor.redact("\"key\" : \"ink:2001:db8::42\","), "\"key\" : \"ink:x::42\",")
        XCTAssertEqual(redactor.redact("web:x::7a8b"), "web:x::7a8b", "idempotent")
        XCTAssertEqual(redactor.redact("mac aa:bb:cc:dd:ee:ff at 14:05:09"), "mac aa:bb:cc:dd:ee:ff at 14:05:09", "MAC addresses and times still stay")
    }

    /// Finder DX-3: an IPv6 address followed by a colon (the listener's `facts from <address>: <status>` and
    /// `client <address>: ...` lines) was left whole.
    func testIPv6FollowedByAColonIsCut() {
        XCTAssertEqual(redactor.redact("facts from fe80::1c2b:3d4e:5f60:7a8b: 200"), "facts from x::7a8b: 200")
        XCTAssertEqual(redactor.redact("client 2001:db8::42: malformed header dropped"), "client x::42: malformed header dropped")
        XCTAssertEqual(redactor.redact("x::7a8b: 200"), "x::7a8b: 200", "idempotent")
        XCTAssertEqual(redactor.redact("at 14:05:09.123 mac a4:83:e7:12:34:56: up"), "at 14:05:09.123 mac a4:83:e7:12:34:56: up", "times and MAC addresses stay")
    }

    func testSSIDsAndSecrets() {
        XCTAssertEqual(redactor.redact("SSID: Mike Home WiFi\nnext"), "SSID: <ssid>\nnext")
        XCTAssertEqual(redactor.redact("wifi ssid=Office-5G, rssi=-50"), "wifi ssid=<ssid>, rssi=-50")
        XCTAssertEqual(redactor.redact("{\"ssid\":\"Cafe\"}"), "{\"ssid\":\"<ssid>\"}")
        XCTAssertEqual(redactor.redact("Authorization: Bearer abc.DEF-123"), "Authorization: Bearer <redacted>")
        XCTAssertEqual(redactor.redact("url?token=s3cr3t&key=k1 password=hunter2"), "url?token=<redacted>&key=<redacted> password=<redacted>")
        XCTAssertEqual(redactor.redact("hotkey=W"), "hotkey=W", "a word that ends in key is not a key")
        XCTAssertEqual(redactor.redact("secret 0123456789abcdef0123456789abcdef01 end"), "secret <redacted> end")
        XCTAssertEqual(redactor.redact("b64 QWxhZGRpbjpPcGVuU2VzYW1lMTIzNDU2Nzg5MA== end"), "b64 <redacted> end")
        let digest = "sha256 9fdf8612aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa8dc7"
        XCTAssertEqual(redactor.redact(digest), digest, "a bundled file's digest is not a secret")
        XCTAssertEqual(redactor.redact("client 6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b pending"), "client 6f1a2b3c... pending", "the 8-character prefix Diagnostics shows")
        XCTAssertEqual(redactor.redact("DaylightCameraDeviceUUID=AB51C6BA-17FD-4A67-BE3A-06A8540BA6AA"), "DaylightCameraDeviceUUID=AB51C6BA-17FD-4A67-BE3A-06A8540BA6AA")
    }

    func testPaths() {
        XCTAssertEqual(redactor.redact("adb.path: /Users/mike/Downloads/platform-tools/adb"), "adb.path: .../adb")
        XCTAssertEqual(redactor.redact("saved /Users/mike/Documents/Daylight Camera/2026-10-03/14-05-09/page-01.png"), "saved ~/Documents/Daylight Camera/2026-10-03/14-05-09/page-01.png")
        XCTAssertEqual(redactor.redact("file ~/Library/Application Support/Daylight/clients.json"), "file ~/Library/Application Support/Daylight/clients.json")
        XCTAssertEqual(redactor.redact("bundle: /Applications/Daylight.app/Contents/MacOS/Daylight"), "bundle: /Applications/Daylight.app/Contents/MacOS/Daylight")
        XCTAssertEqual(redactor.redact("bundle: /Users/mike/Downloads/Daylight.app"), "bundle: .../Daylight.app")
        XCTAssertEqual(redactor.redact("\"path\":\"/private/var/folders/x/T/AppTranslocation/Daylight.app\""), "\"path\":\".../Daylight.app\"")
        XCTAssertEqual(redactor.redact("home /Users/mike and ~/Desktop/notes.txt"), "home ~ and .../notes.txt")
        XCTAssertEqual(redactor.redact("url file:///Users/mike/Desktop/Boards/"), "url file://.../Boards")
        XCTAssertEqual(redactor.redact("GET /api/info and /ink"), "GET /api/info and /ink", "URL paths are not file paths")
        XCTAssertEqual(redactor.redact("/Users/mike/Library/LogsSecret/x.log"), ".../x.log", "a kept root matches whole components only")
    }
}

final class TabletFactsStoreTests: XCTestCase {
    private func entry(_ key: String, at seconds: Double, facts: Int = 1) -> TabletFactsStore.Entry {
        var values: [String: FactValue] = [:]
        for i in 0..<facts { values["k\(i)"] = .number(Double(i)) }
        return TabletFactsStore.Entry(key: key, source: "web", clientId: nil, sentAt: "2026-10-03T14:05:09Z", facts: values,
                                      receivedAt: Date(timeIntervalSince1970: seconds), remoteAddress: "192.168.1.40", allowed: false)
    }

    func testReplaceEvictAndDiagnosticsLine() {
        let store = TabletFactsStore()
        XCTAssertEqual(store.put(entry("web:a", at: 100)), 1)
        XCTAssertEqual(store.put(entry("web:a", at: 101, facts: 3)), 1, "same key replaces")
        XCTAssertEqual(store.all.first?.facts.count, 3)
        for i in 1..<16 { store.put(entry("web:\(i)", at: 200 + Double(i))) }
        XCTAssertEqual(store.count, 16)
        XCTAssertEqual(store.put(entry("web:new", at: 500)), 16, "the 17th key evicts the oldest")
        XCTAssertFalse(store.all.contains { $0.key == "web:a" })
        XCTAssertEqual(store.all.last?.key, "web:new")
        XCTAssertEqual(TabletFactsStore.diagnosticsLine(entry("web:a", at: 1_791_036_309, facts: 2)), "tablet facts: web:a received 2026-10-03T14:05:09Z (2 facts)")
        let object = TabletFactsStore.exportObject(entry("ink:192.168.1.40", at: 0))
        XCTAssertEqual(object["remoteAddress"] as? String, "x.x.x.40")
        XCTAssertTrue(object["clientId"] is NSNull)
    }

    func testDiagnosticsReportPrintsOneLinePerKey() {
        var facts = DiagnosticsReport.Facts()
        facts.tabletFacts = []
        XCTAssertTrue(DiagnosticsReport.text(facts).contains("tablet facts: none"))
        facts.tabletFacts = [TabletFactsStore.diagnosticsLine(entry("web:6f1a2b3c", at: 1_791_036_309, facts: 18))]
        XCTAssertTrue(DiagnosticsReport.text(facts).contains("tablet facts: web:6f1a2b3c received 2026-10-03T14:05:09Z (18 facts)"))
    }
}

final class DiagnosticsExportTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private let date = Date(timeIntervalSince1970: 1_791_036_309)   // 2026-10-03 14:05:09 UTC
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    private let clientId = "6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let clients = "{\n  \"clients\" : [\n    {\n      \"id\" : \"\(clientId)\",\n      \"label\" : \"Mike's DC-1\",\n      \"lastAddress\" : \"192.168.1.40\"\n    }\n  ],\n  \"version\" : 1\n}\n"
        try clients.write(to: root.appendingPathComponent("clients.json"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if let root = root { try? fm.removeItem(at: root) }
        super.tearDown()
    }

    static func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let result = ProcessCommandRunner().run(path, arguments, timeout: 30, maxBytes: 1 << 20)
        return (result.exitStatus ?? -1, result.text)
    }

    private func exporter(folder: URL? = nil, runner: CommandRunning) -> DiagnosticsExporter {
        var config = DiagnosticsExporter.Config(
            folder: folder ?? root.appendingPathComponent("Daylight Camera", isDirectory: true),
            clientsFile: root.appendingPathComponent("clients.json"),
            vendorDirectory: nil,
            selfTestExecutable: URL(fileURLWithPath: "/Applications/Daylight.app/Contents/MacOS/Daylight"),
            home: "/Users/mike",
            keptRoots: ["/Users/mike/Documents/Daylight Camera", "/Users/mike/Library/Application Support/Daylight", "/Users/mike/Library/Logs", "/Applications/Daylight.app"])
        config.timeZone = berlin
        config.osVersion = "Version 15.5 (Build 24F74)"
        config.macModel = "Mac15,3"
        return DiagnosticsExporter(config: config, runner: runner)
    }

    private func snapshot() -> DiagnosticsExporter.Snapshot {
        var settings = Settings.defaults
        settings.saveDirectory = URL(fileURLWithPath: "/Users/mike/Desktop/Boards", isDirectory: true)
        let diagnostics = [
            "Daylight 0.1.0 (57) signed=false",
            "addresses: 192.168.1.23 (en0, LAN), fe80::1c2b:3d4e:5f60:7a8b (en0, LAN)",
            "SSID: Mike Home WiFi",
            "Authorization: Bearer abcdef0123456789abcdef0123456789",
            "mirror.adb.path: /Users/mike/Downloads/platform-tools/adb",
            "saved /Users/mike/Documents/Daylight Camera/2026-10-03/14-05-09/page-01.png",
            "client \(clientId) pending",
        ].joined(separator: "\n")
        let entry = TabletFactsStore.Entry(key: "web:\(clientId)", source: "web", clientId: clientId, sentAt: "2026-10-03T14:05:09Z",
                                           facts: ["viewport": .string("800x1280"), "devicePixelRatio": .number(2), "secureContext": .bool(false), "rttMs": .null],
                                           receivedAt: date, remoteAddress: "192.168.1.40", allowed: true)
        return DiagnosticsExporter.Snapshot(
            date: date, diagnosticsText: diagnostics, settings: settings, perfLines: ["perf mode=passthrough fps=30.0 dropped=0"],
            tabletFacts: [entry], adbSource: ["adb.source": "bundled"], version: "0.1.0", build: "57", signed: false,
            bundlePath: "/Applications/Daylight.app", bundleIdentifier: "com.twelve.daylight")
    }

    private func entries(_ outcome: DiagnosticsExporter.Outcome) throws -> [String: String] {
        var map: [String: String] = [:]
        for e in try ZipReader.entries(Data(contentsOf: outcome.url)) { map[e.name] = String(decoding: e.data, as: UTF8.self) }
        return map
    }

    /// `- <name> (<n> bytes): <note>` lines of MANIFEST.txt.
    private func manifestSizes(_ manifest: String) -> [String: Int] {
        var sizes: [String: Int] = [:]
        for line in manifest.split(separator: "\n") where line.hasPrefix("- ") && line.contains(" bytes): ") {
            let body = line.dropFirst(2)
            guard let open = body.range(of: " ("), let close = body.range(of: " bytes): ") else { continue }
            sizes[String(body[..<open.lowerBound])] = Int(body[open.upperBound..<close.lowerBound])
        }
        return sizes
    }

    func testExportWritesAZipThatReadsBackAndUnzipAccepts() throws {
        let runner = FakeCommandRunner()
        runner.results["Daylight"] = CommandResult(output: Data("self-test: ok   render\nself-test: PASS\n".utf8))
        let export = exporter(runner: runner)
        var events: [DiagnosticsExporter.Event] = []
        export.onEvent = { events.append($0) }
        let outcome = try export.export(snapshot(), runSelfTest: true).get()
        XCTAssertEqual(outcome.url.lastPathComponent, "diagnostics-2026-10-03-16-05.zip", "local time (Berlin)")
        let expected = ["MANIFEST.txt", "diagnostics.txt", "system.txt", "settings.json", "unified-log.txt", "extension-status.txt", "self-test.txt", "perf-log.txt", "vendor.txt", "clients.json", "tablet-facts.json"]
        XCTAssertEqual(outcome.files, expected)
        let files = try entries(outcome)
        XCTAssertEqual(Set(files.keys), Set(expected))
        XCTAssertEqual(outcome.bytes, try Data(contentsOf: outcome.url).count)
        XCTAssertLessThan(outcome.bytes, DiagnosticsExporter.maxZipBytes)

        // MANIFEST lists every other file with its exact size.
        let manifest = files["MANIFEST.txt"] ?? ""
        let sizes = manifestSizes(manifest)
        for name in expected where name != "MANIFEST.txt" {
            XCTAssertEqual(sizes[name], files[name]?.utf8.count, "\(name) in MANIFEST")
        }
        XCTAssertTrue(manifest.contains("missing:\n- none"), manifest)
        XCTAssertTrue(manifest.contains("truncated:\n- none"), manifest)
        XCTAssertTrue(files["self-test.txt"]?.contains("self-test: PASS") == true)
        XCTAssertTrue(files["system.txt"]?.contains("Mac model: Mac15,3") == true)
        XCTAssertTrue(files["system.txt"]?.contains("CFBundleVersion: 57") == true)

        // The commands ran with the ticket's arguments and timeouts.
        let calls = runner.calls
        XCTAssertTrue(calls.contains { $0.0 == "/usr/bin/log" && $0.1 == ["show", "--predicate", "subsystem == \"com.twelve.daylight\"", "--last", "2h", "--style", "compact"] && $0.2 == 20 })
        XCTAssertTrue(calls.contains { $0.0 == "/usr/bin/systemextensionsctl" && $0.1 == ["list"] && $0.2 == 10 })
        XCTAssertTrue(calls.contains { $0.0.hasSuffix("/Daylight") && $0.1 == ["--self-test"] && $0.2 == 120 })

        // Rows 44 then 45, nothing missing.
        XCTAssertEqual(events.first, .running("collecting app facts"))
        XCTAssertTrue(events.contains(.running("running the self-test")))
        XCTAssertEqual(events.last, .saved(name: outcome.url.lastPathComponent, bytes: outcome.bytes, files: expected.count))
        let saved = events.last!.failure
        XCTAssertEqual(saved.0, .diagnosticsExportSaved)
        XCTAssertEqual(FailureText.sentence(saved.0, saved.1), "Diagnostics saved as diagnostics-2026-10-03-16-05.zip in Documents > Daylight Camera. Send this file back after the test.")
        XCTAssertEqual(FailureText.sentence(DiagnosticsExporter.Event.running("reading the log").failure.0, ["reading the log"]), "Saving diagnostics: reading the log...")

        // A real tool accepts the archive.
        let unzip = DiagnosticsExportTests.runTool("/usr/bin/unzip", ["-t", outcome.url.path])
        XCTAssertEqual(unzip.status, 0, unzip.output)
        let out = root.appendingPathComponent("ditto-out", isDirectory: true)
        let ditto = DiagnosticsExportTests.runTool("/usr/bin/ditto", ["-x", "-k", outcome.url.path, out.path])
        XCTAssertEqual(ditto.status, 0, ditto.output)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("MANIFEST.txt"), encoding: .utf8), manifest)
    }

    func testRedactionAppliedAndSaveFolderKept() throws {
        let outcome = try exporter(runner: FakeCommandRunner()).export(snapshot(), runSelfTest: false).get()
        let files = try entries(outcome)
        let diagnostics = files["diagnostics.txt"] ?? ""
        XCTAssertTrue(diagnostics.contains("x.x.x.23 (en0, LAN)"), diagnostics)
        XCTAssertTrue(diagnostics.contains("x::7a8b (en0, LAN)"), diagnostics)
        XCTAssertTrue(diagnostics.contains("SSID: <ssid>"))
        XCTAssertTrue(diagnostics.contains("Bearer <redacted>"))
        XCTAssertTrue(diagnostics.contains("mirror.adb.path: .../adb"))
        XCTAssertTrue(diagnostics.contains("saved ~/Documents/Daylight Camera/2026-10-03/14-05-09/page-01.png"))
        XCTAssertTrue(diagnostics.contains("client 6f1a2b3c... pending"))
        for leak in ["192.168.1.23", "Mike Home WiFi", "abcdef0123456789abcdef0123456789", "/Users/mike", "Downloads", clientId] {
            for (name, text) in files where name != "settings.json" {
                XCTAssertFalse(text.contains(leak), "\(name) leaks \(leak)")
            }
        }
        let settings = files["settings.json"] ?? ""
        XCTAssertTrue(settings.contains("\"saveDirectory\":\"file:///Users/mike/Desktop/Boards/\""), settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(settings.utf8))
        XCTAssertEqual(decoded.saveDirectory?.path, "/Users/mike/Desktop/Boards")

        let clients = files["clients.json"] ?? ""
        XCTAssertTrue(clients.contains("\"lastAddress\" : \"x.x.x.40\""), clients)
        XCTAssertTrue(clients.contains("6f1a2b3c..."))
        XCTAssertFalse(clients.contains("192.168.1.40"))

        let facts = try JSONSerialization.jsonObject(with: Data((files["tablet-facts.json"] ?? "").utf8)) as? [String: Any]
        let stored = (facts?["entries"] as? [[String: Any]])?.first
        XCTAssertEqual(stored?["remoteAddress"] as? String, "x.x.x.40")
        XCTAssertEqual(stored?["key"] as? String, "web:6f1a2b3c...")
        XCTAssertEqual(stored?["allowed"] as? Bool, true)
        XCTAssertEqual(stored?["receivedAt"] as? String, "2026-10-03T14:05:09Z")
        let values = stored?["facts"] as? [String: Any]
        XCTAssertEqual(values?["viewport"] as? String, "800x1280")
        XCTAssertEqual((values?["devicePixelRatio"] as? NSNumber)?.doubleValue, 2)
        XCTAssertTrue(values?["rttMs"] is NSNull)
        XCTAssertTrue((files["MANIFEST.txt"] ?? "").contains("- self-test.txt: not requested"))
    }

    func testTenMiBLogIsCutToTheCapAndManifestSaysSo() throws {
        let runner = FakeCommandRunner()
        var big = Data()
        let line = Data((String(repeating: "z", count: 10239) + "\n").utf8)
        for _ in 0..<1024 { big.append(line) }
        XCTAssertEqual(big.count, 10 << 20)
        runner.results["log"] = CommandResult(output: big)
        let outcome = try exporter(runner: runner).export(snapshot(), runSelfTest: false).get()
        let files = try entries(outcome)
        let log = files["unified-log.txt"] ?? ""
        let cap = DiagnosticsExporter.Part.unifiedLog.cap
        XCTAssertLessThanOrEqual(log.utf8.count, cap)
        XCTAssertGreaterThan(log.utf8.count, cap - 10240, "cut at a line boundary just under the cap")
        XCTAssertTrue(log.hasPrefix("zzz"), "whole lines only")
        XCTAssertEqual(outcome.truncated["unified-log.txt"], 10 << 20)
        let manifest = files["MANIFEST.txt"] ?? ""
        XCTAssertTrue(manifest.contains("- unified-log.txt: truncated to \(log.utf8.count) of \(10 << 20) bytes"), manifest)
        XCTAssertEqual(manifestSizes(manifest)["unified-log.txt"], log.utf8.count)
    }

    func testLogLineLimitKeepsTheNewestLines() throws {
        let runner = FakeCommandRunner()
        var text = ""
        for i in 0..<2500 { text += "line \(i)\n" }
        runner.results["log"] = CommandResult(output: Data(text.utf8))
        let files = try entries(try exporter(runner: runner).export(snapshot(), runSelfTest: false).get())
        let lines = (files["unified-log.txt"] ?? "").split(separator: "\n")
        XCTAssertEqual(lines.count, 2000)
        XCTAssertEqual(lines.first, "line 500")
        XCTAssertEqual(lines.last, "line 2499")
    }

    func testMissingPartRaisesRow46AndManifestNamesIt() throws {
        let runner = FakeCommandRunner()
        runner.results["log"] = CommandResult(output: Data(), exitStatus: nil, timedOut: true)
        runner.results["systemextensionsctl"] = CommandResult(output: Data(), exitStatus: nil, launchError: "launch path not accessible")
        let export = exporter(runner: runner)
        var events: [DiagnosticsExporter.Event] = []
        export.onEvent = { events.append($0) }
        let outcome = try export.export(snapshot(), runSelfTest: false).get()
        XCTAssertFalse(outcome.files.contains("unified-log.txt"))
        XCTAssertFalse(outcome.files.contains("extension-status.txt"))
        XCTAssertEqual(outcome.missing["unified-log.txt"], "log show timed out after 20 s")
        let partial = events.filter { $0.failure.0 == .diagnosticsExportPartial }
        XCTAssertEqual(partial.count, 2, "once per missing part")
        XCTAssertEqual(partial.first, .partMissing(part: "the unified log", reason: "log show timed out after 20 s"))
        let row = partial[0].failure
        XCTAssertEqual(FailureText.sentence(row.0, row.1), "The diagnostics file was saved without the unified log: log show timed out after 20 s.")
        XCTAssertEqual(FailureText.logLine(row.0, row.1), "failure.diagnosticsExportPartial (row 46): diagnostics export: the unified log unavailable: log show timed out after 20 s")
        let manifest = try entries(outcome)["MANIFEST.txt"] ?? ""
        XCTAssertTrue(manifest.contains("- unified-log.txt: log show timed out after 20 s"), manifest)
        XCTAssertTrue(manifest.contains("- extension-status.txt: systemextensionsctl list could not start"), manifest)
        // A missing perf log is recorded but is not a row 46.
        var noPerf = snapshot()
        noPerf.perfLines = []
        events.removeAll()
        let second = try export.export(noPerf, runSelfTest: false).get()
        XCTAssertEqual(second.url.lastPathComponent, "diagnostics-2026-10-03-16-05-2.zip", "the same minute gets -2")
        XCTAssertNotNil(second.missing["perf-log.txt"])
        XCTAssertEqual(events.filter { $0.failure.0 == .diagnosticsExportPartial }.count, 2)
    }

    func testUnwritableFolderRaisesRow47() throws {
        let blocker = root.appendingPathComponent("not-a-folder")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let export = exporter(folder: blocker.appendingPathComponent("Daylight Camera"), runner: FakeCommandRunner())
        var events: [DiagnosticsExporter.Event] = []
        export.onEvent = { events.append($0) }
        let result = export.export(snapshot(), runSelfTest: false)
        guard case let .failure(error) = result else { return XCTFail("the export must fail") }
        XCTAssertFalse(error.reason.isEmpty)
        guard let last = events.last else { return XCTFail("no events") }
        XCTAssertEqual(last, .failed(error.reason))
        XCTAssertEqual(last.failure.0, .diagnosticsExportFailed)
        XCTAssertEqual(FailureText.sentence(last.failure.0, last.failure.1), "Could not save the diagnostics file: \(error.reason). Use Diagnostics > Copy diagnostics instead.")
        XCTAssertFalse(events.contains { if case .saved = $0 { return true } else { return false } })
    }

    func testFileNameStampAndSuffix() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(DiagnosticsExporter.stamp(date, timeZone: utc), "2026-10-03-14-05")
        XCTAssertEqual(DiagnosticsExporter.stamp(date, timeZone: berlin), "2026-10-03-16-05")
        let folder = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        XCTAssertEqual(DiagnosticsExporter.uniqueURL(in: folder, date: date, timeZone: utc, exists: { _ in false }).lastPathComponent, "diagnostics-2026-10-03-14-05.zip")
        let taken: Set<String> = ["diagnostics-2026-10-03-14-05.zip", "diagnostics-2026-10-03-14-05-2.zip"]
        XCTAssertEqual(DiagnosticsExporter.uniqueURL(in: folder, date: date, timeZone: utc, exists: { taken.contains($0.lastPathComponent) }).lastPathComponent, "diagnostics-2026-10-03-14-05-3.zip")
        XCTAssertEqual(DiagnosticsExport.exportFolder().lastPathComponent, "Daylight Camera")
        XCTAssertEqual(DiagnosticsExport.exportFolder().deletingLastPathComponent().path, SessionSaver.defaultRoot().path)
    }

    func testExportRunsOnTheExportQueue() {
        let done = expectation(description: "export")
        let export = exporter(runner: FakeCommandRunner())
        let key = DispatchSpecificKey<String>()
        DiagnosticsExporter.queue.setSpecific(key: key, value: "export")
        var label = ""
        export.onEvent = { _ in label = DispatchQueue.getSpecific(key: key) ?? "elsewhere" }
        export.start(snapshot(), runSelfTest: false) { result in
            XCTAssertNotNil(try? result.get())
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(label, "export", "events come from the export queue")
        XCTAssertEqual(DiagnosticsExporter.queue.label, "com.twelve.daylight.export")
    }

    func testRealRunnerBoundsOutputAndTimesOut() {
        let runner = ProcessCommandRunner()
        let chatty = runner.run("/bin/sh", ["-c", "i=0; while [ $i -lt 3000 ]; do echo 0123456789abcdef0123456789abcdef; i=$((i+1)); done"], timeout: 20, maxBytes: 1000)
        XCTAssertEqual(chatty.exitStatus, 0)
        XCTAssertEqual(chatty.output.count, 1000)
        XCTAssertTrue(chatty.truncated)
        XCTAssertEqual(chatty.totalBytes, 3000 * 33)
        let started = Date()
        let slow = runner.run("/bin/sleep", ["30"], timeout: 1, maxBytes: 1000)
        XCTAssertTrue(slow.timedOut)
        XCTAssertNil(slow.exitStatus)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        let missing = runner.run("/nonexistent/tool", [], timeout: 1, maxBytes: 10)
        XCTAssertNotNil(missing.launchError)
    }

    /// Finder DX-2: a child that crashed was reported as "exit status 11"; it is a signal, not an exit status.
    func testRealRunnerReportsADeathBySignal() {
        let crashed = ProcessCommandRunner().run("/bin/sh", ["-c", "kill -SEGV $$"], timeout: 10, maxBytes: 1000)
        XCTAssertFalse(crashed.timedOut)
        XCTAssertNil(crashed.exitStatus)
        XCTAssertEqual(crashed.signal, SIGSEGV)
        let clean = ProcessCommandRunner().run("/bin/sh", ["-c", "exit 11"], timeout: 10, maxBytes: 1000)
        XCTAssertEqual(clean.exitStatus, 11)
        XCTAssertNil(clean.signal)
    }

    func testCrashedCommandIsNamedASignalInRow46AndTheManifest() throws {
        let runner = FakeCommandRunner()
        runner.results["log"] = CommandResult(output: Data(), exitStatus: nil, signal: 11)
        runner.results["Daylight"] = CommandResult(output: Data("self-test: ok   render\n".utf8), exitStatus: nil, signal: 6)
        let export = exporter(runner: runner)
        var events: [DiagnosticsExporter.Event] = []
        export.onEvent = { events.append($0) }
        let outcome = try export.export(snapshot(), runSelfTest: true).get()
        XCTAssertEqual(outcome.missing["unified-log.txt"], "log show was killed by signal 11")
        XCTAssertTrue(events.contains(.partMissing(part: "the unified log", reason: "log show was killed by signal 11")))
        let manifest = try entries(outcome)["MANIFEST.txt"] ?? ""
        XCTAssertTrue(manifest.contains("killed by signal 6"), manifest)
    }

    /// Finder DX-4: an unauthenticated POST could make any 9 to 64 hex digits a "client id" that the redactor then
    /// shortened everywhere in the zip; only UUID-shaped posted ids are shortened.
    func testAPostedNonUUIDClientIdRewritesNothing() throws {
        var snap = snapshot()
        snap.diagnosticsText += "\nbytes=1000000000 frames=9000000001"
        snap.tabletFacts.append(TabletFactsStore.Entry(
            key: "web:000000000", source: "web", clientId: "000000000", sentAt: "2026-10-03T14:05:09Z", facts: [:],
            receivedAt: date, remoteAddress: "192.168.1.41", allowed: false))
        let files = try entries(try exporter(runner: FakeCommandRunner()).export(snap, runSelfTest: false).get())
        let diagnostics = files["diagnostics.txt"] ?? ""
        XCTAssertTrue(diagnostics.contains("bytes=1000000000 frames=9000000001"), diagnostics)
        XCTAssertTrue(diagnostics.contains("client 6f1a2b3c... pending"), "the clients.json id is still shortened")
        XCTAssertTrue(DiagnosticsExporter.isUUID(clientId))
        XCTAssertTrue(DiagnosticsExporter.isUUID("AB51C6BA-17FD-4A67-BE3A-06A8540BA6AA"))
        XCTAssertFalse(DiagnosticsExporter.isUUID("000000000"))
        XCTAssertFalse(DiagnosticsExporter.isUUID("6f1a2b3c4d5e4f608a9b0c1d2e3f4a5b0000"))
    }

    /// Finder DX-5: a write that fails half way left a truncated diagnostics zip under the final name.
    func testAFailedWriteLeavesNoZip() throws {
        let folder = root.appendingPathComponent("Daylight Camera", isDirectory: true)
        let export = exporter(folder: folder, runner: FakeCommandRunner())
        var config = export.config
        config.write = { data, url in
            try Data(data.prefix(data.count / 2)).write(to: url)
            throw DiagnosticsExporter.ExportError(reason: "disk full")
        }
        let failing = DiagnosticsExporter(config: config, runner: FakeCommandRunner())
        guard case .failure = failing.export(snapshot(), runSelfTest: false) else { return XCTFail("the export must fail") }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path), [], "no zip and no partial file left")
    }
}
