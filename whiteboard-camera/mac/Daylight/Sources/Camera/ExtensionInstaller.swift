import AppKit
import DaylightKit
import Foundation
import SystemExtensions
import os

/// Activates the camera extension with `OSSystemExtensionRequest.activationRequest` at launch (Apple: "as early as
/// possible") and maps every delegate outcome onto a `Status`, each with its `FailureText` row (SPEC 13.3 rows 6 to
/// 12b). Delegate callbacks arrive on the main queue. `.replace` is always returned so a newer build replaces the
/// running extension (CFBundleVersion is the CI run number).
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    static let log = Logger(subsystem: "com.twelve.daylight", category: "installer")
    static let defaultExtensionIdentifier = "com.twelve.daylight.camera"
    /// Community-documented pane URLs (LOOSE_ENDS E13); the text path is authoritative.
    static let modernApprovalPaneURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    static let legacyApprovalPaneURL = "x-apple.systempreferences:com.apple.preference.security"

    enum Status: Equatable {
        case unknown
        case notInstalled
        case needsApproval
        case activating
        case installed
        case needsReboot
        case failed(OSSystemExtensionError.Code, String)
        case notInApplications
        case unsignedBuild
    }

    /// Which request is in flight, so a finished deactivation does not read as "installed" (camera review finding 05).
    enum RequestKind: Equatable {
        case activation
        case deactivation
    }

    let extensionBundleIdentifier: String
    /// `DaylightBuildSigned` from Info.plist unless a test injects it.
    let signed: Bool
    let bundlePath: String
    private(set) var pendingRequest: RequestKind?
    private(set) var status: Status = .unknown {
        didSet {
            if status != oldValue {
                ExtensionInstaller.log.info("extension status \(String(describing: self.status), privacy: .public)")
                onChange?(status)
            }
        }
    }
    var onChange: ((Status) -> Void)?
    private var request: OSSystemExtensionRequest?
    /// True when `activate()` handed a request to `OSSystemExtensionManager` (tests assert it stays false unsigned).
    private(set) var submittedRequests = 0

    init(extensionBundleIdentifier: String = ExtensionInstaller.defaultExtensionIdentifier, signed: Bool? = nil, bundlePath: String? = nil) {
        self.extensionBundleIdentifier = extensionBundleIdentifier
        self.signed = signed ?? ((Bundle.main.object(forInfoDictionaryKey: "DaylightBuildSigned") as? Bool) ?? false)
        self.bundlePath = bundlePath ?? Bundle.main.bundlePath
        super.init()
    }

    // MARK: Requests

    /// Submits the activation request. Unsigned builds never submit (SPEC row 2): the extension cannot load.
    func activate() {
        guard signed else {
            status = .unsignedBuild
            ExtensionInstaller.log.notice("\(FailureText.logLine(.unsignedBuild), privacy: .public)")
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionBundleIdentifier, queue: .main)
        request.delegate = self
        self.request = request
        pendingRequest = .activation
        status = .activating
        submittedRequests += 1
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Removes the extension (Settings "Uninstall camera"; deleting the app does the same).
    func deactivate() {
        guard signed else { return }
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionBundleIdentifier, queue: .main)
        request.delegate = self
        self.request = request
        pendingRequest = .deactivation
        submittedRequests += 1
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Opens the System Settings pane for the running macOS; false when no URL could be opened (the caller shows the
    /// text path from `approvalPathText`).
    @discardableResult
    func openApprovalPane() -> Bool {
        for candidate in ExtensionInstaller.approvalPaneURLs() {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                ExtensionInstaller.log.info("opened \(candidate, privacy: .public)")
                return true
            }
        }
        ExtensionInstaller.log.notice("no System Settings URL opened; showing the text path")
        return false
    }

    /// The pane URLs to try, modern first on macOS 15 and later.
    static func approvalPaneURLs(modern: Bool = ExtensionInstaller.isModernApprovalPath()) -> [String] {
        return modern ? [modernApprovalPaneURL, legacyApprovalPaneURL] : [legacyApprovalPaneURL, modernApprovalPaneURL]
    }

    /// macOS 15 and 26 show Camera Extensions under General > Login Items & Extensions; 13 and 14 under Privacy & Security.
    static func isModernApprovalPath(version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        return version.majorVersion >= 15
    }

    static func approvalPathText(modern: Bool = ExtensionInstaller.isModernApprovalPath()) -> String {
        return modern ? FailureText.approvalPathModern : FailureText.approvalPathLegacy
    }

    var approvalPathText: String { return ExtensionInstaller.approvalPathText() }

    // MARK: Mapping

    /// SPEC 13.3 rows 6 to 12 for the activation error codes (research-cmio-signing 1.5). Code 3 is row 7 (same text
    /// as row 1); 4, 5, 6 and 7 are row 8; 13 and 11 (the approval dialog was cancelled) are row 12; 12 (superseded by
    /// a newer request) has no owner-facing row and returns nil; 1 (unknown) is reported as row 8 with the code logged.
    static func failureCase(for code: OSSystemExtensionError.Code) -> FailureText.Case? {
        switch code {
        case .missingEntitlement: return .extensionMissingEntitlement
        case .unsupportedParentBundleLocation: return .extensionUnsupportedLocation
        case .extensionNotFound, .extensionMissingIdentifier, .duplicateExtensionIdentifer, .unknownExtensionCategory: return .extensionDamaged
        case .codeSignatureInvalid: return .extensionSignatureInvalid
        case .validationFailed: return .extensionValidationFailed
        case .forbiddenBySystemPolicy: return .extensionForbiddenByPolicy
        case .authorizationRequired, .requestCanceled: return .extensionNeedsApproval
        case .requestSuperseded: return nil
        case .unknown: return .extensionDamaged
        @unknown default: return .extensionDamaged
        }
    }

    /// The owner-facing failure of a status, if it has one (B maps this onto its onboarding rows and the menu).
    static func failure(for status: Status, approvalPath: String = ExtensionInstaller.approvalPathText()) -> (FailureText.Case, [String])? {
        switch status {
        case .unknown, .notInstalled, .activating, .installed:
            return nil
        case .needsApproval:
            return (.extensionNeedsApproval, [approvalPath])
        case .needsReboot:
            return (.extensionNeedsReboot, [])
        case .notInApplications:
            return (.notInApplications, [])
        case .unsignedBuild:
            return (.unsignedBuild, [])
        case let .failed(code, message):
            guard let failure = failureCase(for: code) else { return nil }
            if failure == .extensionDamaged { return (failure, [String(code.rawValue), message]) }
            if failure == .extensionNeedsApproval { return (failure, [approvalPath]) }
            return (failure, [])
        }
    }

    /// The status a delegate error produces (pure, so a test can drive every code).
    static func status(forErrorCode code: OSSystemExtensionError.Code, message: String) -> Status {
        switch code {
        case .unsupportedParentBundleLocation: return .notInApplications
        case .requestSuperseded: return .activating
        default: return .failed(code, message)
        }
    }

    /// The status a finished request produces (pure). An activation that completed is `.installed`, one that waits for
    /// a reboot is `.needsReboot` (row 12b). A deactivation that completed is `.notInstalled`; one that completes after
    /// a reboot is reported as `.notInstalled` too (the extension keeps running until then, and row 12b's "finish
    /// installing" wording would be wrong for a removal). With no request kind recorded the activation mapping applies.
    static func status(forResult result: OSSystemExtensionRequest.Result, pending: RequestKind?) -> Status {
        let removing = pending == .deactivation
        switch result {
        case .completed: return removing ? .notInstalled : .installed
        case .willCompleteAfterReboot: return removing ? .notInstalled : .needsReboot
        @unknown default: return removing ? .notInstalled : .installed
        }
    }

    // MARK: OSSystemExtensionRequestDelegate (main queue)

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        ExtensionInstaller.log.info("replacing extension \(existing.bundleShortVersion, privacy: .public) (\(existing.bundleVersion, privacy: .public)) with \(ext.bundleShortVersion, privacy: .public) (\(ext.bundleVersion, privacy: .public))")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        ExtensionInstaller.log.notice("\(FailureText.logLine(.extensionNeedsApproval), privacy: .public)")
        status = .needsApproval
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let removing = pendingRequest == .deactivation
        let new = ExtensionInstaller.status(forResult: result, pending: pendingRequest)
        let what = removing ? "deactivation" : "request"
        switch result {
        case .completed:
            ExtensionInstaller.log.info("extension \(what, privacy: .public) completed")
        case .willCompleteAfterReboot:
            if removing {
                ExtensionInstaller.log.notice("extension deactivation completes after a reboot")
            } else {
                ExtensionInstaller.log.notice("\(FailureText.logLine(.extensionNeedsReboot), privacy: .public)")
            }
        @unknown default:
            ExtensionInstaller.log.notice("extension request finished with result \(result.rawValue)")
        }
        status = new
        pendingRequest = nil
        self.request = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        let code = OSSystemExtensionError.Code(rawValue: nsError.code) ?? .unknown
        let message = nsError.localizedDescription
        if let failure = ExtensionInstaller.failureCase(for: code) {
            let args: [String] = failure == .extensionDamaged ? [String(nsError.code), ExtensionInstaller.extensionListing(bundlePath: bundlePath)] : []
            ExtensionInstaller.log.error("\(FailureText.logLine(failure, args), privacy: .public) (\(message, privacy: .public))")
        } else {
            ExtensionInstaller.log.notice("OSSystemExtensionError \(nsError.code) \(message, privacy: .public)")
        }
        status = ExtensionInstaller.status(forErrorCode: code, message: message)
        pendingRequest = nil
        self.request = nil
    }

    /// `ls -R Contents/Library/SystemExtensions` for the row 8 log line.
    static func extensionListing(bundlePath: String) -> String {
        let root = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Library/SystemExtensions")
        // `enumerator(at:)` returns a non-nil enumerator for a directory that does not exist (it just yields nothing).
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return "(missing)" }
        var lines: [String] = []
        for case let url as URL in enumerator {
            lines.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            if lines.count >= 40 { break }
        }
        return lines.isEmpty ? "(empty)" : lines.joined(separator: " ")
    }
}
