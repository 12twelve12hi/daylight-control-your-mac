import Foundation
import XCTest
import DaylightKit

/// LOOSE_ENDS H1: Settings `adbSource` (default bundled, unknown values map to bundled) and the accepted terms version.
final class AdbSourceSettingsTests: XCTestCase {
    func testDefaultIsBundledWithNoTermsAccepted() {
        XCTAssertEqual(Settings.defaults.adbSource, .bundled)
        XCTAssertNil(Settings.defaults.adbTermsAcceptedVersion)
        XCTAssertEqual(AdbSource.allCases.map { $0.rawValue }, ["bundled", "download", "installed"])
        XCTAssertEqual(AdbSource.allCases.map { $0.label }, ["Bundled (default)", "Download on first use", "Use installed adb"])
    }

    func testRoundTripKeepsSourceAndTermsVersion() throws {
        for source in AdbSource.allCases {
            var s = Settings.defaults
            s.adbSource = source
            s.adbTermsAcceptedVersion = source == .download ? "37.0.0" : nil
            let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
            XCTAssertEqual(back.adbSource, source)
            XCTAssertEqual(back.adbTermsAcceptedVersion, s.adbTermsAcceptedVersion)
            XCTAssertEqual(back.validated().adbSource, source)
        }
    }

    func testEncodedKeysAreTheSpecNames() throws {
        var s = Settings.defaults
        s.adbSource = .installed
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertTrue(json.contains("\"adbSource\":\"installed\""), json)
        XCTAssertFalse(json.contains("adbTermsAcceptedVersion"), "nil is not written")
    }

    func testOlderBlobWithoutTheKeyLoadsBundled() throws {
        let old = Data(#"{"port":7790,"adbServerMode":"shared"}"#.utf8)
        let s = try JSONDecoder().decode(Settings.self, from: old)
        XCTAssertEqual(s.adbSource, .bundled)
        XCTAssertEqual(s.port, 7790)
        XCTAssertEqual(s.adbServerMode, .shared)
    }

    func testUnknownValueMapsToBundledWithoutLosingTheRest() throws {
        for raw in [#""brew""#, #"42"#, #"null"#] {
            let blob = Data(#"{"port":7790,"adbSource":\#(raw),"adbTermsAcceptedVersion":"37.0.0"}"#.utf8)
            let s = try JSONDecoder().decode(Settings.self, from: blob)
            XCTAssertEqual(s.adbSource, .bundled, raw)
            XCTAssertEqual(s.port, 7790, raw)
            XCTAssertEqual(s.adbTermsAcceptedVersion, "37.0.0", raw)
        }
    }

    func testBuildWithoutBundledAdbMakesDownloadTheDefault() {
        XCTAssertEqual(AdbSource.bundled.effective(bundledAvailable: true), .bundled)
        XCTAssertEqual(AdbSource.bundled.effective(bundledAvailable: false), .download)
        XCTAssertEqual(AdbSource.installed.effective(bundledAvailable: false), .installed)
        XCTAssertEqual(AdbSource.download.effective(bundledAvailable: true), .download)
    }
}
