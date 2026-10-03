import DaylightKit
import SystemExtensions
import XCTest
@testable import Daylight

/// Every `OSSystemExtensionError.Code` and delegate result maps onto one SPEC 13.3 row; unsigned builds never submit.
final class ExtensionInstallerTests: XCTestCase {
    func testEveryErrorCodeMapsToItsFailureRow() {
        let expected: [(OSSystemExtensionError.Code, FailureText.Case?)] = [
            (.unknown, .extensionDamaged),
            (.missingEntitlement, .extensionMissingEntitlement),
            (.unsupportedParentBundleLocation, .extensionUnsupportedLocation),
            (.extensionNotFound, .extensionDamaged),
            (.extensionMissingIdentifier, .extensionDamaged),
            (.duplicateExtensionIdentifer, .extensionDamaged),
            (.unknownExtensionCategory, .extensionDamaged),
            (.codeSignatureInvalid, .extensionSignatureInvalid),
            (.validationFailed, .extensionValidationFailed),
            (.forbiddenBySystemPolicy, .extensionForbiddenByPolicy),
            (.requestCanceled, .extensionNeedsApproval),
            (.requestSuperseded, nil),
            (.authorizationRequired, .extensionNeedsApproval),
        ]
        for (code, failure) in expected {
            XCTAssertEqual(ExtensionInstaller.failureCase(for: code), failure, "code \(code.rawValue)")
        }
        // The raw values the research note pinned (1...13 in this order).
        XCTAssertEqual(OSSystemExtensionError.Code.missingEntitlement.rawValue, 2)
        XCTAssertEqual(OSSystemExtensionError.Code.unsupportedParentBundleLocation.rawValue, 3)
        XCTAssertEqual(OSSystemExtensionError.Code.codeSignatureInvalid.rawValue, 8)
        XCTAssertEqual(OSSystemExtensionError.Code.validationFailed.rawValue, 9)
        XCTAssertEqual(OSSystemExtensionError.Code.forbiddenBySystemPolicy.rawValue, 10)
        XCTAssertEqual(OSSystemExtensionError.Code.authorizationRequired.rawValue, 13)
    }

    func testRowTextsForTheExtensionFailures() {
        XCTAssertEqual(FailureText.sentence(.extensionMissingEntitlement), "The camera extension is missing an entitlement (build signing problem).")
        XCTAssertEqual(FailureText.sentence(.extensionUnsupportedLocation), FailureText.sentence(.notInApplications), "row 7 reads as row 1")
        XCTAssertEqual(FailureText.sentence(.extensionDamaged), "The camera extension inside this build is damaged. Download the build again.")
        XCTAssertEqual(FailureText.sentence(.extensionSignatureInvalid), "macOS refused the extension's signature. This build is not notarized.")
        XCTAssertEqual(FailureText.sentence(.extensionValidationFailed), "The extension's service name does not match its app group (build configuration).")
        XCTAssertEqual(FailureText.sentence(.extensionForbiddenByPolicy), "Your Mac's security policy blocks system extensions (MDM or SIP setting).")
        XCTAssertEqual(FailureText.sentence(.extensionNeedsApproval), "Approve 'Daylight Camera' in System Settings > General > Login Items & Extensions > Camera Extensions, then click Check again.")
        XCTAssertEqual(FailureText.sentence(.extensionNeedsApproval, [FailureText.approvalPathLegacy]), "Approve 'Daylight Camera' in System Settings > Privacy & Security > Security, then click Check again.")
        XCTAssertEqual(FailureText.sentence(.extensionNeedsReboot), "Restart your Mac once to finish installing Daylight Camera.")
        // The Kit prefixes every log line with "failure.<case> (row N): " (FailureText.logLine).
        XCTAssertEqual(FailureText.logLine(.extensionSignatureInvalid), "failure.extensionSignatureInvalid (row 9): OSSystemExtensionError 8 codeSignatureInvalid")
        XCTAssertEqual(FailureText.logLine(.extensionNeedsApproval), "failure.extensionNeedsApproval (row 12): requestNeedsUserApproval")
        XCTAssertEqual(FailureText.logLine(.extensionNeedsReboot), "failure.extensionNeedsReboot (row 12b): willCompleteAfterReboot")
    }

    func testStatusForErrorCodes() {
        XCTAssertEqual(ExtensionInstaller.status(forErrorCode: .unsupportedParentBundleLocation, message: "x"), .notInApplications)
        XCTAssertEqual(ExtensionInstaller.status(forErrorCode: .requestSuperseded, message: "x"), .activating, "a superseded request is not a failure")
        XCTAssertEqual(ExtensionInstaller.status(forErrorCode: .codeSignatureInvalid, message: "sig"), .failed(.codeSignatureInvalid, "sig"))
    }

    func testFailureForEveryStatus() {
        XCTAssertNil(ExtensionInstaller.failure(for: .unknown))
        XCTAssertNil(ExtensionInstaller.failure(for: .notInstalled))
        XCTAssertNil(ExtensionInstaller.failure(for: .activating))
        XCTAssertNil(ExtensionInstaller.failure(for: .installed))
        XCTAssertEqual(ExtensionInstaller.failure(for: .needsApproval, approvalPath: "P")?.0, .extensionNeedsApproval)
        XCTAssertEqual(ExtensionInstaller.failure(for: .needsApproval, approvalPath: "P")?.1, ["P"])
        XCTAssertEqual(ExtensionInstaller.failure(for: .needsReboot)?.0, .extensionNeedsReboot)
        XCTAssertEqual(ExtensionInstaller.failure(for: .notInApplications)?.0, .notInApplications)
        XCTAssertEqual(ExtensionInstaller.failure(for: .unsignedBuild)?.0, .unsignedBuild)
        let damaged = ExtensionInstaller.failure(for: .failed(.extensionNotFound, "gone"))
        XCTAssertEqual(damaged?.0, .extensionDamaged)
        XCTAssertEqual(damaged?.1, ["4", "gone"], "row 8 logs the code and the listing")
        XCTAssertEqual(ExtensionInstaller.failure(for: .failed(.validationFailed, ""))?.0, .extensionValidationFailed)
        XCTAssertNil(ExtensionInstaller.failure(for: .failed(.requestSuperseded, "")))
        let text = FailureText.sentence(ExtensionInstaller.failure(for: .failed(.codeSignatureInvalid, ""))!.0)
        XCTAssertEqual(text, "macOS refused the extension's signature. This build is not notarized.")
    }

    /// Finding 05: a finished deactivation is "not installed", never "installed" (which made the sink client publish
    /// row 13 and tell the owner to open Zoom to find a camera they just removed).
    func testFinishedRequestMapsByRequestKind() {
        XCTAssertEqual(ExtensionInstaller.status(forResult: .completed, pending: .activation), .installed)
        XCTAssertEqual(ExtensionInstaller.status(forResult: .willCompleteAfterReboot, pending: .activation), .needsReboot)
        XCTAssertEqual(ExtensionInstaller.status(forResult: .completed, pending: .deactivation), .notInstalled)
        XCTAssertEqual(ExtensionInstaller.status(forResult: .willCompleteAfterReboot, pending: .deactivation), .notInstalled, "the extension runs until the reboot; row 12b's wording is about installing")
        XCTAssertEqual(ExtensionInstaller.status(forResult: .completed, pending: nil), .installed, "no kind recorded: the activation mapping")
        XCTAssertEqual(ExtensionInstaller.status(forResult: .willCompleteAfterReboot, pending: nil), .needsReboot)
    }

    /// CAMA-02: a superseded request's callbacks describe that old request. Its error must not wipe the kind of the
    /// newer request, or a finished deactivation reads as "installed" again (finding 05's symptom).
    func testSupersededRequestCallbacksDoNotTouchTheCurrentRequest() {
        let superseded = NSError(domain: "OSSystemExtensionErrorDomain", code: OSSystemExtensionError.Code.requestSuperseded.rawValue)
        let installer = ExtensionInstaller(signed: true, bundlePath: "/Applications/Daylight.app")
        let first = installer.beginForTesting(.activation)
        let second = installer.beginForTesting(.deactivation)
        installer.request(first, didFailWithError: superseded)
        XCTAssertEqual(installer.pendingRequest, .deactivation, "the old request's error leaves the newer request's kind alone")
        installer.request(second, didFinishWithResult: .completed)
        XCTAssertEqual(installer.status, .notInstalled, "a completed deactivation is not installed")
        XCTAssertNil(installer.pendingRequest)

        // Activation then "Check again": the old activation's late superseded error keeps the approval instructions.
        let again = ExtensionInstaller(signed: true, bundlePath: "/Applications/Daylight.app")
        let old = again.beginForTesting(.activation)
        let current = again.beginForTesting(.activation)
        again.requestNeedsUserApproval(current)
        again.request(old, didFailWithError: superseded)
        XCTAssertEqual(again.status, .needsApproval)
        again.requestNeedsUserApproval(old)
        again.request(old, didFinishWithResult: .completed)
        XCTAssertEqual(again.status, .needsApproval, "nothing from the replaced request is applied")
        again.request(current, didFinishWithResult: .completed)
        XCTAssertEqual(again.status, .installed)
    }

    func testUnsignedBuildNeverSubmitsARequest() {
        let installer = ExtensionInstaller(signed: false, bundlePath: "/Applications/Daylight.app")
        var changes: [ExtensionInstaller.Status] = []
        installer.onChange = { changes.append($0) }
        XCTAssertEqual(installer.status, .unknown)
        installer.activate()
        installer.activate()
        XCTAssertEqual(installer.status, .unsignedBuild)
        XCTAssertEqual(installer.submittedRequests, 0, "SPEC row 2: the virtual camera cannot be installed from an unsigned build")
        XCTAssertEqual(changes, [.unsignedBuild], "onChange fires once per distinct status")
        installer.deactivate()
        XCTAssertEqual(installer.submittedRequests, 0)
        XCTAssertNil(installer.pendingRequest, "nothing was submitted, nothing is pending")
        XCTAssertEqual(installer.extensionBundleIdentifier, "com.twelve.daylight.camera")
    }

    func testDefaultsComeFromTheHostBundle() {
        let installer = ExtensionInstaller()
        XCTAssertEqual(installer.bundlePath, Bundle.main.bundlePath)
        XCTAssertEqual(installer.signed, (Bundle.main.object(forInfoDictionaryKey: "DaylightBuildSigned") as? Bool) ?? false)
    }

    func testApprovalPaneURLsAndPathText() {
        XCTAssertEqual(ExtensionInstaller.approvalPaneURLs(modern: true).first, "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        XCTAssertEqual(ExtensionInstaller.approvalPaneURLs(modern: false).first, "x-apple.systempreferences:com.apple.preference.security")
        XCTAssertEqual(ExtensionInstaller.approvalPaneURLs(modern: true).count, 2)
        XCTAssertTrue(ExtensionInstaller.isModernApprovalPath(version: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)))
        XCTAssertTrue(ExtensionInstaller.isModernApprovalPath(version: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)))
        XCTAssertFalse(ExtensionInstaller.isModernApprovalPath(version: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0)))
        XCTAssertEqual(ExtensionInstaller.approvalPathText(modern: true), "System Settings > General > Login Items & Extensions > Camera Extensions")
        XCTAssertEqual(ExtensionInstaller.approvalPathText(modern: false), "System Settings > Privacy & Security > Security")
        for url in ExtensionInstaller.approvalPaneURLs() { XCTAssertNotNil(URL(string: url)) }
    }

    func testExtensionListingReadsTheEmbeddedBundle() {
        let listing = ExtensionInstaller.extensionListing(bundlePath: Bundle.main.bundlePath)
        print("camera-tests: SystemExtensions listing: \(listing)")
        XCTAssertTrue(listing.contains("com.twelve.daylight.camera.systemextension"), "the row 8 log line lists the embedded extension")
        XCTAssertEqual(ExtensionInstaller.extensionListing(bundlePath: "/nonexistent/Daylight.app"), "(missing)")
    }
}
