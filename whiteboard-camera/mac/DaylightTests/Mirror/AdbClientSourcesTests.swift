import DaylightKit
import Foundation
import XCTest
@testable import Daylight

/// LOOSE_ENDS H1: the three adb sources through `AdbClient.locateExecutable`, without a device or the network. Fake adb
/// executables are shell scripts printing real `adb version` output; the download runs against a local file URL.
final class AdbClientSourcesTests: XCTestCase {
    static let modernOutput = "Android Debug Bridge version 1.0.41\nVersion 37.0.0-14910828\nInstalled as /opt/homebrew/bin/adb\nRunning on Darwin 25.0.0 (arm64)\n"
    static let oldOutput = "Android Debug Bridge version 1.0.41\nVersion 34.0.5-10900879\nInstalled as /usr/local/bin/adb\n"
    static let ancientOutput = "Android Debug Bridge version 1.0.39\nRevision 3db08f2c6889-android\n"

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("adb-sources-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    /// A fake adb: `adb version` prints `output`.
    @discardableResult
    private func fakeAdb(in dir: String, output: String, executable: Bool = true) throws -> URL {
        let folder = root.appendingPathComponent(dir, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("adb")
        let script = "#!/bin/sh\ncat <<'EOF'\n\(output)EOF\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    private func path(_ dir: String) -> String { return root.appendingPathComponent(dir).path }

    // MARK: adb version

    func testVersionParsingAndTheMinimum() {
        let modern = AdbVersionInfo.parse(Self.modernOutput)
        XCTAssertEqual(modern, AdbVersionInfo(bridge: [1, 0, 41], platformTools: "37.0.0-14910828"))
        XCTAssertEqual(modern?.text, "1.0.41 (37.0.0-14910828)")
        XCTAssertEqual(modern?.platformToolsMajor, 37)
        XCTAssertEqual(modern?.isSupported, true)
        XCTAssertEqual(AdbVersionInfo.parse("Android Debug Bridge version 1.0.41\nVersion 35.0.0-11411520\n")?.isSupported, true)
        XCTAssertEqual(AdbVersionInfo.parse(Self.oldOutput)?.isSupported, false, "platform-tools 34 is below 35")
        XCTAssertEqual(AdbVersionInfo.parse(Self.ancientOutput)?.isSupported, false, "no Version line counts as too old")
        XCTAssertEqual(AdbVersionInfo.parse("Android Debug Bridge version 1.0.40\nVersion 36.0.0-1\n")?.isSupported, false, "bridge below 1.0.41")
        XCTAssertNil(AdbVersionInfo.parse("zsh: command not found: adb"))
        XCTAssertNil(AdbVersionInfo.parse(""))
    }

    // MARK: Use installed adb

    func testProbingOrderIsPathThenHomebrewThenAndroidStudio() {
        let env = ["PATH": "/p1:/p2::/usr/local/bin", "ANDROID_HOME": "/sdk-home", "ANDROID_SDK_ROOT": "/sdk-root"]
        let list = AdbInstalledProbe.candidates(environment: env, home: URL(fileURLWithPath: "/Users/owner")).map { $0.path }
        XCTAssertEqual(list, [
            "/p1/adb", "/p2/adb", "/usr/local/bin/adb", "/opt/homebrew/bin/adb",
            "/sdk-home/platform-tools/adb", "/sdk-root/platform-tools/adb", "/Users/owner/Library/Android/sdk/platform-tools/adb",
        ], "PATH first, Homebrew next (duplicates dropped), then ANDROID_HOME, ANDROID_SDK_ROOT and the Android Studio default")
        XCTAssertEqual(AdbInstalledProbe.homebrewPaths, ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"])
    }

    func testFirstExecutableWinsAndAModernOneIsAccepted() throws {
        try fakeAdb(in: "path-a", output: Self.modernOutput, executable: false)
        let winner = try fakeAdb(in: "brew", output: Self.modernOutput)
        try fakeAdb(in: "home/Library/Android/sdk/platform-tools", output: Self.oldOutput)
        let result = AdbInstalledProbe.locate(environment: ["PATH": path("path-a")], home: root.appendingPathComponent("home"),
                                              homebrew: [path("brew") + "/adb"])
        XCTAssertEqual(try result.get(), AdbLocation(url: winner.standardizedFileURL, source: .installed, version: "1.0.41 (37.0.0-14910828)"))
    }

    func testAnOlderAdbIsRefusedWithRow43() throws {
        let old = try fakeAdb(in: "path-a", output: Self.oldOutput)
        try fakeAdb(in: "brew", output: Self.modernOutput)
        let result = AdbInstalledProbe.locate(environment: ["PATH": path("path-a")], home: root, homebrew: [path("brew") + "/adb"])
        guard case let .failure(error) = result else { return XCTFail("expected a refusal, got \(result)") }
        XCTAssertEqual(error, .installedTooOld(path: old.standardizedFileURL.path, version: "1.0.41 (34.0.5-10900879)"))
        XCTAssertEqual(error.failure?.0, .adbInstalledTooOld)
        XCTAssertEqual(error.sentence, "The adb at \(old.standardizedFileURL.path) is version 1.0.41 (34.0.5-10900879). Daylight needs platform-tools 35 or newer: update it, or choose another adb source.")
    }

    func testNoInstalledAdbIsRow42NamingThePlacesSearched() {
        let result = AdbInstalledProbe.locate(environment: ["PATH": path("empty")], home: root, homebrew: [path("brew") + "/adb"])
        guard case let .failure(error) = result else { return XCTFail("expected none, got \(result)") }
        guard case let .installedMissing(searched) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(searched.first, path("empty") + "/adb")
        XCTAssertTrue(searched.contains(root.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path))
        XCTAssertEqual(error.sentence, FailureText.sentence(.adbInstalledMissing))
        XCTAssertTrue(error.logLine.hasPrefix("failure.adbInstalledMissing (row 42): adb installed: none executable in \(path("empty"))/adb, "), error.logLine)
        XCTAssertEqual(error.adbError, .launchFailed(FailureText.sentence(.adbInstalledMissing)))
    }

    func testUnreadableVersionIsRefused() throws {
        let junk = try fakeAdb(in: "path-a", output: "segmentation fault\n")
        let result = AdbInstalledProbe.locate(environment: ["PATH": path("path-a")], home: root, homebrew: [])
        XCTAssertEqual(result.failureValue, .installedUnreadable(path: junk.standardizedFileURL.path))
    }

    // MARK: Download on first use

    /// A platform-tools zip like Google's: `platform-tools/adb` and `platform-tools/NOTICE.txt`.
    private func makeZip(adbOutput: String = modernOutput) throws -> URL {
        let staging = root.appendingPathComponent("zip-staging/platform-tools", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try "#!/bin/sh\ncat <<'EOF'\n\(adbOutput)EOF\n".write(to: staging.appendingPathComponent("adb"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.appendingPathComponent("adb").path)
        try "Android SDK notices\n".write(to: staging.appendingPathComponent("NOTICE.txt"), atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent("platform-tools_r37.0.0-darwin.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", staging.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
        return zip
    }

    private func ensure(_ downloader: AdbDownloader) -> Result<AdbLocation, AdbSourceError> {
        let done = expectation(description: "download")
        var outcome: Result<AdbLocation, AdbSourceError>?
        downloader.ensure { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return outcome ?? .failure(.downloadFailed(reason: "no completion", url: ""))
    }

    private var installDirectory: URL { return root.appendingPathComponent("Application Support/Daylight/platform-tools", isDirectory: true) }

    func testDownloadVerifiesInstallsAndThenWorksOffline() throws {
        let zip = try makeZip()
        let sha = try XCTUnwrap(AdbSHA256.hex(of: zip))
        let downloader = AdbDownloader(directory: installDirectory, pins: AdbPins(version: "37.0.0", sha256: sha, url: zip))
        XCTAssertEqual(downloader.locateInstalled().failureValue, .notDownloaded(version: "37.0.0"))

        let location = try ensure(downloader).get()
        XCTAssertEqual(location, AdbLocation(url: installDirectory.appendingPathComponent("adb"), source: .download, version: "platform-tools 37.0.0"))
        let attributes = try fm.attributesOfItem(atPath: location.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertTrue(fm.fileExists(atPath: installDirectory.appendingPathComponent("NOTICE.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: installDirectory.appendingPathComponent("adb.partial").path), "no partial file left")
        XCTAssertEqual(AdbVersionInfo.parse(AdbVersionProbe.run(location.url) ?? "")?.isSupported, true, "the installed adb runs")

        // Offline afterwards: the zip is gone, the pinned copy is found and its checksum re-verified.
        try fm.removeItem(at: zip)
        XCTAssertEqual(try ensure(downloader).get(), location)
        XCTAssertEqual(try downloader.locateInstalled().get(), location)
    }

    func testWrongChecksumIsRow41AndInstallsNothing() throws {
        let zip = try makeZip()
        let want = String(repeating: "0", count: 64)
        let downloader = AdbDownloader(directory: installDirectory, pins: AdbPins(version: "37.0.0", sha256: want, url: zip))
        let result = ensure(downloader)
        guard case let .failure(error) = result, case let .checksumMismatch(got, wanted) = error else { return XCTFail("\(result)") }
        XCTAssertEqual(got, AdbSHA256.hex(of: zip))
        XCTAssertEqual(wanted, want)
        XCTAssertEqual(error.sentence, FailureText.sentence(.adbChecksumMismatch))
        XCTAssertFalse(fm.fileExists(atPath: installDirectory.appendingPathComponent("adb").path))
        XCTAssertFalse(fm.fileExists(atPath: installDirectory.appendingPathComponent("adb.partial").path))
    }

    func testMissingFileIsRow40() {
        let missing = root.appendingPathComponent("nothing-here.zip")
        let downloader = AdbDownloader(directory: installDirectory, pins: AdbPins(version: "37.0.0", sha256: String(repeating: "0", count: 64), url: missing))
        let result = ensure(downloader)
        guard case let .failure(error) = result, case .downloadFailed = error else { return XCTFail("\(result)") }
        XCTAssertEqual(error.failure?.0, .adbDownloadFailed)
        XCTAssertFalse(fm.fileExists(atPath: installDirectory.appendingPathComponent("adb").path))
    }

    func testTamperedCopyFailsTheChecksumBeforeUse() throws {
        let zip = try makeZip()
        let sha = try XCTUnwrap(AdbSHA256.hex(of: zip))
        let downloader = AdbDownloader(directory: installDirectory, pins: AdbPins(version: "37.0.0", sha256: sha, url: zip))
        let adb = try ensure(downloader).get().url
        let handle = try FileHandle(forWritingTo: adb)
        handle.seekToEndOfFile()
        handle.write(Data("# changed\n".utf8))
        try handle.close()
        guard case let .failure(error) = downloader.locateInstalled(), case .checksumMismatch = error else { return XCTFail("tampered adb accepted") }
        XCTAssertEqual(downloader.locateInstalled().failureValue, .notDownloaded(version: "37.0.0"), "the manifest is dropped, so the next ensure downloads again")
    }

    func testANewPinDownloadsAgain() throws {
        let zip = try makeZip()
        let sha = try XCTUnwrap(AdbSHA256.hex(of: zip))
        _ = try ensure(AdbDownloader(directory: installDirectory, pins: AdbPins(version: "37.0.0", sha256: sha, url: zip))).get()
        let newer = AdbDownloader(directory: installDirectory, pins: AdbPins(version: "38.0.0", sha256: sha, url: zip))
        XCTAssertEqual(newer.locateInstalled().failureValue, .notDownloaded(version: "38.0.0"))
    }

    func testTheShippedPinsMatchFetchTools() {
        XCTAssertEqual(AdbPins.current.version, "37.0.0")
        XCTAssertEqual(AdbPins.current.sha256, "094a1395683c509fd4d48667da0d8b5ef4d42b2abfcd29f2e8149e2f989357c7")
        XCTAssertEqual(AdbPins.current.url.absoluteString, "https://dl.google.com/android/repository/platform-tools_r37.0.0-darwin.zip")
        XCTAssertTrue(AdbDownloader.defaultDirectory().path.hasSuffix("Library/Application Support/Daylight/platform-tools"))
    }

    // MARK: The seam

    private func request(_ source: AdbSource, bundled: Bool = true, terms: String? = nil, downloader: AdbDownloader? = nil) -> AdbSourceRequest {
        return AdbSourceRequest(source: source, bundledAvailable: bundled, termsAcceptedVersion: terms, vendorDirectory: root.appendingPathComponent("Vendor"),
                                downloader: downloader ?? AdbDownloader(directory: installDirectory), environment: ["PATH": path("path-a")],
                                home: root, versionOutput: { AdbVersionProbe.run($0) })
    }

    func testBundledIsTheVendorCopy() throws {
        let vendorAdb = try fakeAdb(in: "Vendor", output: Self.modernOutput)
        let location = try AdbClient.locateExecutable(request(.bundled), recordStatus: false).get()
        XCTAssertEqual(location.url, vendorAdb)
        XCTAssertEqual(location.source, .bundled)
        XCTAssertEqual(try AdbClient.locateBundled(vendorDirectory: root.appendingPathComponent("Vendor")).get(), vendorAdb)
    }

    func testBundledMissingKeepsTheExistingError() {
        let result = AdbClient.locateExecutable(request(.bundled), recordStatus: false)
        let expectedPath = root.appendingPathComponent("Vendor/adb").path
        XCTAssertEqual(result.failureValue, .bundledMissing(path: expectedPath))
        XCTAssertEqual(result.failureValue?.adbError, .executableMissing(expectedPath), "MirrorController's row 25 wording is unchanged")
    }

    func testDownloadNeverRunsBeforeTheTermsAreAccepted() {
        XCTAssertEqual(AdbClient.locateExecutable(request(.download), recordStatus: false).failureValue, .termsNotAccepted(version: "37.0.0"))
        XCTAssertEqual(AdbClient.locateExecutable(request(.download, terms: "36.0.0"), recordStatus: false).failureValue, .termsNotAccepted(version: "37.0.0"),
                       "terms accepted for an older pin are asked again")
        XCTAssertEqual(AdbClient.locateExecutable(request(.download, terms: "37.0.0"), recordStatus: false).failureValue, .notDownloaded(version: "37.0.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installDirectory.path), "locate never downloads")
        XCTAssertEqual(AdbSourceError.termsNotAccepted(version: "37.0.0").sentence, FailureText.sentence(.adbTermsDeclined))
    }

    func testABuildWithoutBundledAdbResolvesBundledAsDownload() throws {
        try fakeAdb(in: "Vendor", output: Self.modernOutput)
        XCTAssertEqual(AdbClient.locateExecutable(request(.bundled, bundled: false), recordStatus: false).failureValue, .termsNotAccepted(version: "37.0.0"))
    }

    func testInstalledThroughTheSeam() throws {
        let adb = try fakeAdb(in: "path-a", output: Self.modernOutput)
        XCTAssertEqual(try AdbClient.locateExecutable(request(.installed), recordStatus: false).get().url, adb.standardizedFileURL)
    }

    func testBuildSwitchInfoValues() {
        XCTAssertTrue(AdbSourceRequest.infoValueMeansBundled(nil), "builds before H1 bundled adb")
        XCTAssertTrue(AdbSourceRequest.infoValueMeansBundled("1"))
        XCTAssertTrue(AdbSourceRequest.infoValueMeansBundled(true))
        XCTAssertFalse(AdbSourceRequest.infoValueMeansBundled("0"))
        XCTAssertFalse(AdbSourceRequest.infoValueMeansBundled(" false "))
        XCTAssertFalse(AdbSourceRequest.infoValueMeansBundled(NSNumber(value: false)))
        XCTAssertEqual(AdbSourceRequest.bundlesAdbInfoKey, "DaylightBundlesAdb")
    }

    // MARK: Diagnostics

    func testDiagnosticsShowSourcePathAndVersion() throws {
        let adb = try fakeAdb(in: "path-a", output: Self.modernOutput)
        _ = AdbClient.locateExecutable(request(.installed))
        let d = AdbSourceStatus.diagnostics()
        XCTAssertEqual(d["adb.source"], "installed")
        XCTAssertEqual(d["adb.path"], adb.standardizedFileURL.path)
        XCTAssertEqual(d["adb.version"], "1.0.41 (37.0.0-14910828)")

        var facts = DiagnosticsReport.Facts()
        facts.mirror = ["adb.mode": "shared 5037"]
        facts.adbSource = d
        let text = DiagnosticsReport.text(facts)
        XCTAssertTrue(text.contains("mirror.adb.mode: shared 5037"))
        XCTAssertTrue(text.contains("mirror.adb.source: installed"))
        XCTAssertTrue(text.contains("mirror.adb.path: \(adb.standardizedFileURL.path)"))
        XCTAssertTrue(text.contains("mirror.adb.version: 1.0.41 (37.0.0-14910828)"))

        _ = AdbClient.locateExecutable(request(.download))
        XCTAssertEqual(AdbSourceStatus.diagnostics()["adb.path"], "none")
        XCTAssertEqual(AdbSourceStatus.diagnostics()["adb.error"], FailureText.logLine(.adbTermsDeclined, ["37.0.0"]))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
