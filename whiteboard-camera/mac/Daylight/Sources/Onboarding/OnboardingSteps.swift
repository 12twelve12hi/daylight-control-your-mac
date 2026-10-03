import DaylightKit
import Foundation

/// What the host knows about the camera extension, in B's own words (component C's installer and sink statuses
/// are mapped onto this by the app; onboarding never imports C's types).
enum ExtensionState: Equatable {
    case unsignedBuild
    case notInstalled
    case activating
    case awaitingApproval
    case installed
    case connected
    case needsReboot
    case failed(FailureText.Case, String)
}

enum CameraPermission: Equatable {
    case notDetermined
    case granted
    case denied
}

/// The onboarding state machine of SPEC 13.1 as a pure value: inputs in, step rows out. The window renders the rows.
struct OnboardingSteps: Equatable {
    enum Status: Equatable {
        case pending
        case active
        case done
        case blocked
    }

    struct Row: Equatable {
        let index: Int
        let title: String
        let detail: String
        let status: Status
        /// The failure row driving the text, when one does.
        let failure: FailureText.Case?
    }

    struct Inputs: Equatable {
        var bundlePath: String
        var signed: Bool
        var camera: CameraPermission = .notDetermined
        var cameraName: String? = nil
        var extensionState: ExtensionState = .notInstalled
        var modernApprovalPath = true
        var clientsAllowed = 0
        var clientsPending = 0
        var mirrorFrames = false
        var usbDevice: String? = nil
        var webURL: String? = nil
        var loginItemEnabled = false
        var hotkeyLines: [String] = []
    }

    static let applicationsPrefix = "/Applications/"
    static let translocationMarker = "/AppTranslocation/"

    /// SPEC 13.1 step 0: not under /Applications or translocated.
    static func locationProblem(bundlePath: String) -> Bool {
        return !bundlePath.hasPrefix(applicationsPrefix) || bundlePath.contains(translocationMarker)
    }

    static func rows(_ i: Inputs) -> [Row] {
        var rows: [Row] = []
        let misplaced = locationProblem(bundlePath: i.bundlePath)
        // 0. Location
        if !i.signed {
            rows.append(Row(index: 0, title: "Location", detail: FailureText.sentence(.unsignedBuild), status: .blocked, failure: .unsignedBuild))
        } else if misplaced {
            rows.append(Row(index: 0, title: "Location", detail: FailureText.sentence(.notInApplications), status: .blocked, failure: .notInApplications))
        } else {
            rows.append(Row(index: 0, title: "Location", detail: "Daylight is in your Applications folder.", status: .done, failure: nil))
        }
        // 1. Camera
        switch i.camera {
        case .granted:
            rows.append(Row(index: 1, title: "Camera", detail: i.cameraName.map { "Using \($0)." } ?? FailureText.sentence(.noWebcam), status: i.cameraName == nil ? .active : .done, failure: i.cameraName == nil ? .noWebcam : nil))
        case .denied:
            rows.append(Row(index: 1, title: "Camera", detail: FailureText.sentence(.cameraAccessDenied), status: .blocked, failure: .cameraAccessDenied))
        case .notDetermined:
            rows.append(Row(index: 1, title: "Camera", detail: "Allow camera access so Daylight can show your webcam.", status: .active, failure: nil))
        }
        // 2. Install Daylight Camera
        rows.append(extensionRow(i, misplaced: misplaced))
        // 3. Your Daylight
        let connected = i.clientsAllowed > 0 || i.mirrorFrames
        let detail: String
        if connected {
            detail = "Your Daylight is connected."
        } else if let serial = i.usbDevice {
            detail = "A Daylight is on USB (\(serial)). Set up over USB does everything for the chosen ink source."
        } else if let url = i.webURL {
            detail = "Open \(url) on your Daylight."
        } else {
            detail = "Connect your Daylight to the same Wi-Fi, or plug it in over USB."
        }
        rows.append(Row(index: 3, title: "Your Daylight", detail: detail, status: connected ? .done : .active, failure: nil))
        // 4. Allow (wireless clients only)
        if i.clientsPending > 0 {
            rows.append(Row(index: 4, title: "Allow this Daylight?", detail: "A tablet is waiting for your click.", status: .active, failure: .allowDismissed))
        } else {
            rows.append(Row(index: 4, title: "Allow this Daylight?", detail: connected ? "Allowed and remembered." : "Shown when a tablet connects over Wi-Fi.", status: connected ? .done : .pending, failure: nil))
        }
        // 5. Finish
        var finish = "Open Zoom and pick Daylight Camera."
        if !i.hotkeyLines.isEmpty { finish += " Hotkeys: " + i.hotkeyLines.joined(separator: ", ") + "." }
        finish += i.loginItemEnabled ? " Daylight starts at login." : " Turn on Launch at login so Daylight is always ready."
        rows.append(Row(index: 5, title: "Finish", detail: finish, status: .pending, failure: nil))
        return rows
    }

    static func extensionRow(_ i: Inputs, misplaced: Bool) -> Row {
        let title = "Install Daylight Camera"
        if !i.signed {
            return Row(index: 2, title: title, detail: "Not available on an unsigned test build. The preview window shows the output.", status: .blocked, failure: .unsignedBuild)
        }
        if misplaced {
            return Row(index: 2, title: title, detail: FailureText.sentence(.notInApplications), status: .blocked, failure: .notInApplications)
        }
        switch i.extensionState {
        case .unsignedBuild:
            return Row(index: 2, title: title, detail: FailureText.sentence(.unsignedBuild), status: .blocked, failure: .unsignedBuild)
        case .notInstalled:
            return Row(index: 2, title: title, detail: "Click Install to add the Daylight Camera extension.", status: .active, failure: nil)
        case .activating:
            return Row(index: 2, title: title, detail: "Installing...", status: .active, failure: nil)
        case .awaitingApproval:
            let path = i.modernApprovalPath ? FailureText.approvalPathModern : FailureText.approvalPathLegacy
            return Row(index: 2, title: title, detail: FailureText.sentence(.extensionNeedsApproval, [path]), status: .active, failure: .extensionNeedsApproval)
        case .installed:
            return Row(index: 2, title: title, detail: FailureText.sentence(.sinkDeviceNotFound), status: .active, failure: .sinkDeviceNotFound)
        case .connected:
            return Row(index: 2, title: title, detail: "Daylight Camera is installed and connected.", status: .done, failure: nil)
        case .needsReboot:
            return Row(index: 2, title: title, detail: FailureText.sentence(.extensionNeedsReboot), status: .blocked, failure: .extensionNeedsReboot)
        case let .failed(failure, detail):
            let text = FailureText.sentence(failure, detail.isEmpty ? [] : [detail])
            return Row(index: 2, title: title, detail: text, status: .blocked, failure: failure)
        }
    }

    /// True when every step that can be done is done (sets `onboardingDone`). A blocked location or camera row stops
    /// the finish, except the unsigned-build row: an unsigned test build has no camera extension to install and
    /// finishes onboarding with the preview window (SPEC 13.3 row 2).
    static func canFinish(_ rows: [Row]) -> Bool {
        return !rows.contains { $0.index <= 1 && $0.status == .blocked && $0.failure != .unsignedBuild }
    }
}
