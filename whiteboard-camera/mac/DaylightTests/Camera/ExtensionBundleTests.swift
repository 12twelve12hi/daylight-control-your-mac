import DaylightKit
import XCTest
@testable import Daylight

/// SPEC C1 and C2 as far as a hosted test can see them: the `.systemextension` is embedded in Daylight.app, both
/// Info.plists carry the same three UUIDs, the Mach service name is the app group, the bundle id is right, and the
/// extension's entitlements in `project.yml` are exactly app-sandbox plus the app group.
final class ExtensionBundleTests: XCTestCase {
    static let uuidKeys = ["DaylightCameraDeviceUUID", "DaylightCameraSourceUUID", "DaylightCameraSinkUUID"]
    static let extensionIdentifier = "com.twelve.daylight.camera"
    static let appGroup = "com.twelve.daylight"

    /// The one embedded extension bundle, or nil with the listing printed.
    static func embeddedExtension() -> Bundle? {
        let directory = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        print("camera-tests: SystemExtensions=\(urls.map { $0.lastPathComponent })")
        guard let url = urls.first(where: { $0.pathExtension == "systemextension" }) else { return nil }
        return Bundle(url: url)
    }

    /// The repository checkout this test file was compiled from (the hosted bundle runs on the same machine).
    static var repositoryMacDirectory: URL {
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testExactlyOneSystemExtensionIsEmbedded() throws {
        let directory = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let extensions = urls.filter { $0.pathExtension == "systemextension" }
        XCTAssertEqual(extensions.count, 1, "Daylight.app embeds exactly one .systemextension (SPEC C1)")
        XCTAssertEqual(extensions.first?.lastPathComponent, "\(ExtensionBundleTests.extensionIdentifier).systemextension")
        let executable = try XCTUnwrap(extensions.first).appendingPathComponent("Contents/MacOS/\(ExtensionBundleTests.extensionIdentifier)")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), "the extension executable is named after its bundle id")
    }

    func testBothInfoPlistsCarryTheSameThreeUUIDs() throws {
        let ext = try XCTUnwrap(ExtensionBundleTests.embeddedExtension(), "no embedded extension")
        for key in ExtensionBundleTests.uuidKeys {
            let app = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: key) as? String, "app Info.plist lacks \(key)")
            let inExtension = try XCTUnwrap(ext.object(forInfoDictionaryKey: key) as? String, "extension Info.plist lacks \(key)")
            XCTAssertEqual(app, inExtension, "\(key) differs between the app and the extension")
            XCTAssertNotNil(UUID(uuidString: app), "\(key) is not a UUID: \(app)")
        }
        let values = ExtensionBundleTests.uuidKeys.compactMap { Bundle.main.object(forInfoDictionaryKey: $0) as? String }
        XCTAssertEqual(Set(values).count, 3, "the three UUIDs are distinct")
    }

    /// The extension's built-in fallback UUIDs (used when its Info.plist is broken, instead of crashing) are the values
    /// the build writes into the extension's Info.plist, and they are distinct.
    func testBuiltInFallbackUUIDsMatchTheExtensionInfoPlist() throws {
        let ext = try XCTUnwrap(ExtensionBundleTests.embeddedExtension(), "no embedded extension")
        let defaults = [
            "DaylightCameraDeviceUUID": DaylightExtensionRules.defaultDeviceUUID,
            "DaylightCameraSourceUUID": DaylightExtensionRules.defaultSourceUUID,
            "DaylightCameraSinkUUID": DaylightExtensionRules.defaultSinkUUID,
        ]
        for key in ExtensionBundleTests.uuidKeys {
            let value = ext.object(forInfoDictionaryKey: key)
            let inExtension = try XCTUnwrap(DaylightExtensionRules.uuid(fromPlistValue: value), "extension Info.plist \(key) is not a UUID: \(String(describing: value))")
            XCTAssertEqual(defaults[key], inExtension, "the built-in \(key) differs from the built bundle")
        }
        XCTAssertEqual(Set(defaults.values).count, 3, "the three built-in UUIDs are distinct")
    }

    func testExtensionIdentityAndMachServiceName() throws {
        let ext = try XCTUnwrap(ExtensionBundleTests.embeddedExtension(), "no embedded extension")
        XCTAssertEqual(ext.bundleIdentifier, ExtensionBundleTests.extensionIdentifier)
        XCTAssertEqual(ext.object(forInfoDictionaryKey: "CFBundlePackageType") as? String, "SYSX")
        let cmio = try XCTUnwrap(ext.object(forInfoDictionaryKey: "CMIOExtension") as? [String: Any], "CMIOExtension dictionary missing")
        let service = try XCTUnwrap(cmio["CMIOExtensionMachServiceName"] as? String)
        print("camera-tests: CMIOExtensionMachServiceName=\(service)")
        // Unexpanded in the spec, `TEAMID.` prefixed when signed, bare when the unsigned build expanded an empty prefix.
        XCTAssertTrue(service.hasSuffix(ExtensionBundleTests.appGroup), "service name \(service) is not under the app group")
        XCTAssertTrue(
            service == "$(TeamIdentifierPrefix)\(ExtensionBundleTests.appGroup)" || service == ExtensionBundleTests.appGroup
                || service.range(of: "^[A-Z0-9]{10}\\.com\\.twelve\\.daylight$", options: .regularExpression) != nil,
            "unexpected service name form: \(service)")
        XCTAssertNotNil(ext.object(forInfoDictionaryKey: "NSSystemExtensionUsageDescription") as? String)
        XCTAssertEqual(ext.object(forInfoDictionaryKey: "CFBundleVersion") as? String, Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "both targets share CURRENT_PROJECT_VERSION so replacement works")
    }

    func testExtensionEntitlementsAreExactlySandboxAndAppGroup() throws {
        let projectYML = ExtensionBundleTests.repositoryMacDirectory.appendingPathComponent("project.yml")
        guard let text = try? String(contentsOf: projectYML, encoding: .utf8) else {
            throw XCTSkip("project.yml not reachable from the test host at \(projectYML.path)")
        }
        // The extension target's entitlements block: from its `entitlements:` key to the next target.
        let extensionRange = try XCTUnwrap(text.range(of: "  DaylightCameraExtension:\n"))
        let afterExtension = String(text[extensionRange.upperBound...])
        let entitlementsRange = try XCTUnwrap(afterExtension.range(of: "    entitlements:\n"))
        let afterEntitlements = String(afterExtension[entitlementsRange.upperBound...])
        let end = afterEntitlements.range(of: "\n  DaylightTests:")?.lowerBound ?? afterEntitlements.endIndex
        let block = String(afterEntitlements[..<end])
        let keys = block.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("com.apple.") else { return nil }
            return String(trimmed.split(separator: ":").first ?? "")
        }
        XCTAssertEqual(Set(keys), Set(["com.apple.security.app-sandbox", "com.apple.security.application-groups"]), "SPEC C2: exactly app-sandbox plus the app group; block was:\n\(block)")
        XCTAssertTrue(block.contains("com.apple.security.app-sandbox: true"))
        XCTAssertTrue(block.contains("$(TeamIdentifierPrefix)com.twelve.daylight"))
        XCTAssertFalse(block.contains("com.apple.security.cs."), "no hardened-runtime exceptions on the extension (SPEC D30)")
    }

    func testExtensionSourcesStayFreeOfDaylightKitAndPinTheRules() throws {
        let sources = ExtensionBundleTests.repositoryMacDirectory.appendingPathComponent("DaylightCameraExtension/Sources")
        guard let files = try? FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) else {
            throw XCTSkip("extension sources not reachable at \(sources.path)")
        }
        var allText = ""
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("import DaylightKit"), "\(file.lastPathComponent) imports DaylightKit")
            allText += text
        }
        // SPEC C3 numbers and spellings, pinned until the integrator compiles ExtensionRules.swift into this bundle.
        XCTAssertTrue(allText.contains("static let consumeStrategy: ConsumeStrategy = .timer90Hz"), "the default consume strategy is the 90 Hz timer (SPEC D33)")
        XCTAssertTrue(allText.contains("static let consumeRateMultiplier: Int = 3"))
        XCTAssertTrue(allText.contains("static let frameRate: Int = 30"))
        XCTAssertTrue(allText.contains("static let hostSigningID = \"com.twelve.daylight\""))
        XCTAssertTrue(allText.contains("static let viewersPropertyName = \"4cc_dlvw_glob_0000\""))
        XCTAssertTrue(allText.contains("Daylight is not running. Open Daylight from the menu bar."))
        XCTAssertTrue(allText.contains("sinkBufferQueueSize = 1"))
        XCTAssertTrue(allText.contains("sinkBuffersRequiredForStartup = 1"))
        XCTAssertTrue(allText.contains("notifyScheduledOutputChanged(output)"))
        XCTAssertTrue(allText.contains("return !sinkStarted && streamingCounter > 0"), "the placeholder rule of SPEC C3")
    }
}
