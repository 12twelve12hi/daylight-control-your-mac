import Foundation

/// Owner-facing failure text (SPEC section 13.3): one case per row, in row order. `sentence` is the "Owner sees (exact)"
/// column and `logLine` the "Log line" column; every `<...>` placeholder is replaced by the next argument in order.
/// A placeholder without an argument stays in the text, except row 12 whose single argument (the System Settings path)
/// defaults to the macOS 26 and 15 wording.
public enum FailureText {
    public enum Case: String, CaseIterable {
        case notInApplications              // 1
        case unsignedBuild                  // 2
        case cameraAccessDenied             // 3
        case noWebcam                       // 4
        case webcamFormatComposed           // 5
        case extensionMissingEntitlement    // 6
        case extensionUnsupportedLocation   // 7
        case extensionDamaged               // 8
        case extensionSignatureInvalid      // 9
        case extensionValidationFailed      // 10
        case extensionForbiddenByPolicy     // 11
        case extensionNeedsApproval         // 12
        case extensionNeedsReboot           // 12b
        case sinkDeviceNotFound             // 13
        case sinkStreamLayout               // 14
        case viewerShowsBlack               // 15
        case portInUse                      // 16
        case bonjourRenamed                 // 17
        case nobodyConnected                // 18
        case allowDismissed                 // 19
        case webNonSecure                   // 20
        case adbNoDevice                    // 21
        case adbUnauthorized                // 22
        case adbOffline                     // 23
        case adbVersionClash                // 24
        case scrcpyServerFailed             // 25
        case scrcpyCodecError               // 26
        case decoderError                   // 27
        case noPenDevice                    // 28
        case noSideButtonEvents             // 28b
        case pillsInvisible                 // 29
        case mdnsNotFound                   // 30
        case saveFailed                     // 31
        case wifiMirrorFailed               // 32
        case captureIdle                    // 33
        case wifiStreamConsentDenied        // 34
        case wifiStreamEncoderUnavailable   // 35
        case wifiStreamStalled              // 36
        case wifiStreamFrameDiffEngage      // 37
        case wifiStreamNoTablet             // 38
        case adbTermsDeclined               // 39
        case adbDownloadFailed              // 40
        case adbChecksumMismatch            // 41
        case adbInstalledMissing            // 42
        case adbInstalledTooOld             // 43

        /// The SPEC 13.3 row label.
        public var row: String {
            switch self {
            case .notInApplications: return "1"
            case .unsignedBuild: return "2"
            case .cameraAccessDenied: return "3"
            case .noWebcam: return "4"
            case .webcamFormatComposed: return "5"
            case .extensionMissingEntitlement: return "6"
            case .extensionUnsupportedLocation: return "7"
            case .extensionDamaged: return "8"
            case .extensionSignatureInvalid: return "9"
            case .extensionValidationFailed: return "10"
            case .extensionForbiddenByPolicy: return "11"
            case .extensionNeedsApproval: return "12"
            case .extensionNeedsReboot: return "12b"
            case .sinkDeviceNotFound: return "13"
            case .sinkStreamLayout: return "14"
            case .viewerShowsBlack: return "15"
            case .portInUse: return "16"
            case .bonjourRenamed: return "17"
            case .nobodyConnected: return "18"
            case .allowDismissed: return "19"
            case .webNonSecure: return "20"
            case .adbNoDevice: return "21"
            case .adbUnauthorized: return "22"
            case .adbOffline: return "23"
            case .adbVersionClash: return "24"
            case .scrcpyServerFailed: return "25"
            case .scrcpyCodecError: return "26"
            case .decoderError: return "27"
            case .noPenDevice: return "28"
            case .noSideButtonEvents: return "28b"
            case .pillsInvisible: return "29"
            case .mdnsNotFound: return "30"
            case .saveFailed: return "31"
            case .wifiMirrorFailed: return "32"
            case .captureIdle: return "33"
            case .wifiStreamConsentDenied: return "34"
            case .wifiStreamEncoderUnavailable: return "35"
            case .wifiStreamStalled: return "36"
            case .wifiStreamFrameDiffEngage: return "37"
            case .wifiStreamNoTablet: return "38"
            case .adbTermsDeclined: return "39"
            case .adbDownloadFailed: return "40"
            case .adbChecksumMismatch: return "41"
            case .adbInstalledMissing: return "42"
            case .adbInstalledTooOld: return "43"
            }
        }
    }

    /// The System Settings path for macOS 26 and 15 (row 12); 13 and 14 use `approvalPathLegacy`.
    public static let approvalPathModern = "System Settings > General > Login Items & Extensions > Camera Extensions"
    public static let approvalPathLegacy = "System Settings > Privacy & Security > Security"

    /// The "Owner sees (exact)" column. Rows whose owner-facing text lives on the tablet (19, 20, 29, 30) carry that text;
    /// row 17 is "nothing visible" and returns an empty string.
    public static func sentence(_ c: Case, _ args: [String] = []) -> String {
        let template: String
        switch c {
        case .notInApplications: template = "Move Daylight to your Applications folder, then open it from there."
        case .unsignedBuild: template = "This is an unsigned test build. The virtual camera cannot be installed on this Mac. Use Daylight > Preview window to see the output."
        case .cameraAccessDenied: template = "Camera access is off for Daylight."
        case .noWebcam: template = "No camera found"
        case .webcamFormatComposed: template = "Camera delivers <w>x<h> <fourcc>; composing every frame"   // SPEC 13.3 row 5 quotes an example
        case .extensionMissingEntitlement: template = "The camera extension is missing an entitlement (build signing problem)."
        case .extensionUnsupportedLocation: template = "Move Daylight to your Applications folder, then open it from there."
        case .extensionDamaged: template = "The camera extension inside this build is damaged. Download the build again."
        case .extensionSignatureInvalid: template = "macOS refused the extension's signature. This build is not notarized."
        case .extensionValidationFailed: template = "The extension's service name does not match its app group (build configuration)."
        case .extensionForbiddenByPolicy: template = "Your Mac's security policy blocks system extensions (MDM or SIP setting)."
        case .extensionNeedsApproval: template = "Approve 'Daylight Camera' in <path>, then click Check again."
        case .extensionNeedsReboot: template = "Restart your Mac once to finish installing Daylight Camera."
        case .sinkDeviceNotFound: template = "Daylight Camera is installed but not found yet. Retrying..."
        case .sinkStreamLayout: template = "Daylight Camera has an unexpected stream layout."
        case .viewerShowsBlack: template = "If Zoom shows a black picture, quit and reopen Zoom."
        case .portInUse:
            template = args.count >= 2
                ? "Port <port> is in use. Daylight is using <bound>."
                : "Port <port> is in use. Quit the other app or change the port in Settings."
        case .bonjourRenamed: template = ""
        case .nobodyConnected: template = "Nobody has connected yet. Same Wi-Fi? Office networks often block this: use USB or Tailscale."
        case .allowDismissed: template = "Allow <label>"
        case .webNonSecure: template = "Optional: paste <origin> into chrome://flags/#unsafely-treat-insecure-origin-as-secure on the tablet for better ink and a screen that stays awake over Wi-Fi."
        case .adbNoDevice: template = "No Daylight found over USB. Is USB debugging on?"
        case .adbUnauthorized: template = "Tap Allow on your Daylight (tick Always allow)."
        case .adbOffline: template = "The Daylight is connected but not responding. Unplug and plug again."
        case .adbVersionClash: template = "Another adb is running (Android Studio?). Daylight is using its own copy; a tablet already claimed by the other adb will not be visible."
        case .scrcpyServerFailed: template = "The screen mirror could not start: <error>"
        case .scrcpyCodecError: template = "Your Daylight refused screen capture (codec error)."
        case .decoderError: template = "Recovering video..."
        case .noPenDevice: template = "Pen events not found on this Daylight. Mirror works, but auto-engage and the pen button do not. Use the pills or the Whiteboard hotkey."
        case .noSideButtonEvents: template = "Pen button events not seen; use the pills."
        case .pillsInvisible: template = "Allow display over other apps"
        case .mdnsNotFound: template = "Looking for your Mac... Enter its address if this takes long"
        case .saveFailed: template = "Could not save the whiteboard: <error>"
        case .wifiMirrorFailed: template = "Plug in once to re-enable Wi-Fi mirroring."
        case .captureIdle: template = "Webcam capture is paused because no app is viewing Daylight Camera (LED off). It restarts within a second when a call starts."
        case .wifiStreamConsentDenied: template = "Daylight Ink was not allowed to share the tablet screen. Tap the Daylight Ink notification on the tablet and choose Start now."
        case .wifiStreamEncoderUnavailable: template = "Your Daylight could not start its screen encoder. Restart Daylight Ink, or use Mirror over USB."
        case .wifiStreamStalled: template = "The tablet's screen stream paused. Reconnecting..."
        case .wifiStreamFrameDiffEngage: template = "Mirror over Wi-Fi starts the whiteboard when the tablet screen changes. Plug in with USB debugging for pen-exact engage."
        case .wifiStreamNoTablet: template = "Open Daylight Ink on your Daylight to mirror over Wi-Fi."
        case .adbTermsDeclined: template = "Downloading adb needs Google's Android SDK License accepted. Choose Download again in Settings > Mirror to review it, or pick another adb source."
        case .adbDownloadFailed: template = "Could not download adb: <reason>. Check the internet connection and try again, or choose Use bundled."
        case .adbChecksumMismatch: template = "The downloaded adb did not match its checksum and was deleted. Try again, or choose Use bundled."
        case .adbInstalledMissing: template = "No installed adb found. Daylight looked in your PATH, in Homebrew (/opt/homebrew/bin, /usr/local/bin) and in the Android Studio SDK (ANDROID_HOME, ~/Library/Android/sdk)."
        case .adbInstalledTooOld: template = "The adb at <path> is version <version>. Daylight needs platform-tools 35 or newer: update it, or choose another adb source."
        }
        var filled = args
        if c == .extensionNeedsApproval && filled.isEmpty { filled = [approvalPathModern] }
        return substitute(template, filled)
    }

    /// The second sentence of row 13, shown after 30 s of retrying.
    public static func followUp(_ c: Case) -> String? {
        switch c {
        case .sinkDeviceNotFound: return "Open Zoom or FaceTime once, or restart your Mac."
        default: return nil
        }
    }

    /// Owner-facing text for a status that carries a row and a detail (the sink status): the sentence with the detail as
    /// its argument, or, when the detail is the row's follow-up (row 13 after 30 s), the sentence and then the follow-up.
    public static func sentence(_ c: Case, detail: String) -> String {
        if let followUp = followUp(c), detail == followUp {
            return sentence(c) + " " + followUp
        }
        return sentence(c, detail.isEmpty ? [] : [detail])
    }

    /// The "Log line" column with the same placeholder rule.
    public static func logLine(_ c: Case, _ args: [String] = []) -> String {
        let template: String
        switch c {
        case .notInApplications: template = "bundle path not under /Applications: <path>"
        case .unsignedBuild: template = "DaylightBuildSigned=false"
        case .cameraAccessDenied: template = "AVAuthorizationStatus = denied"
        case .noWebcam: template = "cameras() returned 0"
        case .webcamFormatComposed: template = "first frame <w>x<h> <fourcc> iosurface=<bool>"
        case .extensionMissingEntitlement: template = "OSSystemExtensionError 2 missingEntitlement"
        case .extensionUnsupportedLocation: template = "OSSystemExtensionError 3 unsupportedParentBundleLocation"
        case .extensionDamaged: template = "OSSystemExtensionError <code>; ls -R Contents/Library/SystemExtensions: <listing>"
        case .extensionSignatureInvalid: template = "OSSystemExtensionError 8 codeSignatureInvalid"
        case .extensionValidationFailed: template = "OSSystemExtensionError 9 validationFailed"
        case .extensionForbiddenByPolicy: template = "OSSystemExtensionError 10 forbiddenBySystemPolicy"
        case .extensionNeedsApproval: template = "requestNeedsUserApproval"
        case .extensionNeedsReboot: template = "willCompleteAfterReboot"
        case .sinkDeviceNotFound: template = "sink: no CMIO device with UID <uuid>; devices=<devices>"
        case .sinkStreamLayout: template = "streams=<ids> directions=<directions>"
        case .viewerShowsBlack: template = "extension placeholder shown while a viewer streams"
        case .portInUse: template = "NWListener failed: <error>"
        case .bonjourRenamed: template = "serviceRegistrationUpdateHandler .add <endpoint>"
        case .nobodyConnected: template = "no client connected after 60 s"
        case .allowDismissed: template = "client <id> pending"
        case .webNonSecure: template = "web client on a non-secure origin <origin>"
        case .adbNoDevice: template = "adb devices -l: <output>"
        case .adbUnauthorized: template = "state=unauthorized"
        case .adbOffline: template = "state=offline"
        case .adbVersionClash: template = "host:version mismatch <a> vs <b>"
        case .scrcpyServerFailed: template = "scrcpy server: <error>"
        case .scrcpyCodecError: template = "codec id = <id>"
        case .decoderError: template = "VTDecompressionSessionDecodeFrame status <n>"
        case .noPenDevice: template = "getevent -pl devices: <names>"
        case .noSideButtonEvents: template = "no BTN_STYLUS after 30 s of inking"
        case .pillsInvisible: template = "overlay permission not granted"
        case .mdnsNotFound: template = "discoverServices found nothing"
        case .saveFailed: template = "SessionSaver error: <error>"
        case .wifiMirrorFailed: template = "adb connect <ip>:5555 -> <stdout>"
        case .captureIdle: template = "capture stopped: viewers=0 preview=hidden"
        case .wifiStreamConsentDenied: template = "mirror stream: consent denied by <label>"
        case .wifiStreamEncoderUnavailable: template = "mirror stream: encoder unavailable on <label> (state <n>)"
        case .wifiStreamStalled: template = "mirror stream: no packet for <s> s from <label>; key frame requested"
        case .wifiStreamFrameDiffEngage: template = "mirror stream: engage source frame-diff (no USB pen watcher)"
        case .wifiStreamNoTablet: template = "mirror stream: no capable Daylight Ink connection"
        case .adbTermsDeclined: template = "adb download: terms not accepted for platform-tools <version>"
        case .adbDownloadFailed: template = "adb download <url> failed: <error>"
        case .adbChecksumMismatch: template = "adb download: sha256 <got> want <want>"
        case .adbInstalledMissing: template = "adb installed: none executable in <paths>"
        case .adbInstalledTooOld: template = "adb installed: <path> version <version> below platform-tools 35"
        }
        return "failure.\(c.rawValue) (row \(c.row)): " + substitute(template, args)
    }

    /// Replaces each `<...>` placeholder, left to right, with the next argument; leftover placeholders stay verbatim.
    static func substitute(_ template: String, _ args: [String]) -> String {
        var out = ""
        var next = 0
        var i = template.startIndex
        while i < template.endIndex {
            let ch = template[i]
            if ch == "<", let close = template[i...].firstIndex(of: ">") {
                if next < args.count {
                    out += args[next]
                    next += 1
                } else {
                    out.append(contentsOf: template[i...close])
                }
                i = template.index(after: close)
            } else {
                out.append(ch)
                i = template.index(after: i)
            }
        }
        return out
    }
}
