import Foundation

/// Owner-facing failure sentences (SPEC section 13.3): one case per row, shared by the UI and the log.
public enum FailureText {
    public enum Case: String, CaseIterable {
        case extensionNotInApplications
        case extensionNeedsApproval
        case extensionNotNotarized
        case extensionMachServiceInvalid
        case noWebcam
        case sinkNotFound
        case portInUse
        case adbMissing
        case noPenDevice
    }

    public static func sentence(_ c: Case, _ args: [String] = []) -> String {
        switch c {
        case .extensionNotInApplications: return "Move Daylight to your Applications folder, then open it again."
        case .extensionNeedsApproval: return "Allow the Daylight camera extension in System Settings, then come back."
        case .extensionNotNotarized: return "This build is not notarized, so macOS will not load the camera extension. Use the preview window instead."
        case .extensionMachServiceInvalid: return "The camera extension could not register its service. Reinstall Daylight."
        case .noWebcam: return "No webcam found. Plug one in or pick one in the Daylight menu."
        case .sinkNotFound: return "Daylight Camera is installed but not reachable yet. Waiting for macOS to publish it."
        case .portInUse: return "Ports 7788 to 7799 are all in use. Quit the app using them and relaunch Daylight."
        case .adbMissing: return "The bundled adb is missing from this build. Mirror mode is unavailable."
        case .noPenDevice: return "No pen input device was found on the tablet: " + args.joined(separator: ", ")
        }
    }

    public static func logLine(_ c: Case, _ args: [String] = []) -> String {
        return "failure.\(c.rawValue): " + sentence(c, args)
    }
}
