import XCTest
import DaylightKit

/// SPEC 13.3 and plan 3.4: 51 cases in row order, exact owner-facing sentences, log lines, placeholder substitution.
final class FailureTextTests: XCTestCase {
    func testFiftyOneCasesInRowOrder() {
        let names = FailureText.Case.allCases.map { $0.rawValue }
        XCTAssertEqual(names.count, 51)
        XCTAssertEqual(names, [
            "notInApplications", "unsignedBuild", "cameraAccessDenied", "noWebcam", "webcamFormatComposed",
            "extensionMissingEntitlement", "extensionUnsupportedLocation", "extensionDamaged", "extensionSignatureInvalid",
            "extensionValidationFailed", "extensionForbiddenByPolicy", "extensionNeedsApproval", "extensionNeedsReboot",
            "sinkDeviceNotFound", "sinkStreamLayout", "viewerShowsBlack", "portInUse", "bonjourRenamed", "nobodyConnected",
            "allowDismissed", "webNonSecure", "adbNoDevice", "adbUnauthorized", "adbOffline", "adbVersionClash",
            "scrcpyServerFailed", "scrcpyCodecError", "decoderError", "noPenDevice", "noSideButtonEvents", "pillsInvisible",
            "mdnsNotFound", "saveFailed", "wifiMirrorFailed", "captureIdle",
            "wifiStreamConsentDenied", "wifiStreamEncoderUnavailable", "wifiStreamStalled", "wifiStreamFrameDiffEngage",
            "wifiStreamNoTablet",
            "adbTermsDeclined", "adbDownloadFailed", "adbChecksumMismatch", "adbInstalledMissing", "adbInstalledTooOld",
            "diagnosticsExportRunning", "diagnosticsExportSaved", "diagnosticsExportPartial", "diagnosticsExportFailed",
            "overlayFallback", "overlayLowCoverage",
        ])
        XCTAssertEqual(FailureText.Case.allCases.map { $0.row }, [
            "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "12b", "13", "14", "15", "16", "17", "18", "19", "20",
            "21", "22", "23", "24", "25", "26", "27", "28", "28b", "29", "30", "31", "32", "33",
            "34", "35", "36", "37", "38", "39", "40", "41", "42", "43",
            "44", "45", "46", "47",
            "48", "49",
        ])
    }

    /// LOOSE_ENDS H1: the adb source rows, every sentence exact (SPEC 13.3 rows 39 to 43).
    func testAdbSourceRowsExact() {
        XCTAssertEqual(FailureText.sentence(.adbTermsDeclined), "Downloading adb needs Google's Android SDK License accepted. Choose Download again in Settings > Mirror to review it, or pick another adb source.")
        XCTAssertEqual(FailureText.sentence(.adbDownloadFailed, ["the request timed out"]), "Could not download adb: the request timed out. Check the internet connection and try again, or choose Use bundled.")
        XCTAssertEqual(FailureText.sentence(.adbChecksumMismatch), "The downloaded adb did not match its checksum and was deleted. Try again, or choose Use bundled.")
        XCTAssertEqual(FailureText.sentence(.adbInstalledMissing), "No installed adb found. Daylight looked in your PATH, in Homebrew (/opt/homebrew/bin, /usr/local/bin) and in the Android Studio SDK (ANDROID_HOME, ~/Library/Android/sdk).")
        XCTAssertEqual(FailureText.sentence(.adbInstalledTooOld, ["/usr/local/bin/adb", "1.0.39 (29.0.6)"]), "The adb at /usr/local/bin/adb is version 1.0.39 (29.0.6). Daylight needs platform-tools 35 or newer: update it, or choose another adb source.")
        XCTAssertEqual(FailureText.logLine(.adbTermsDeclined, ["37.0.0"]), "failure.adbTermsDeclined (row 39): adb download: terms not accepted for platform-tools 37.0.0")
        XCTAssertEqual(FailureText.logLine(.adbChecksumMismatch, ["aa", "bb"]), "failure.adbChecksumMismatch (row 41): adb download: sha256 aa want bb")
    }

    /// The diagnostics export rows, every sentence exact (SPEC 13.3 rows 44 to 47).
    func testDiagnosticsExportRowsExact() {
        XCTAssertEqual(FailureText.sentence(.diagnosticsExportRunning, ["reading the log"]), "Saving diagnostics: reading the log...")
        XCTAssertEqual(FailureText.sentence(.diagnosticsExportSaved, ["diagnostics-2026-10-03-14-05.zip"]), "Diagnostics saved as diagnostics-2026-10-03-14-05.zip in Documents > Daylight Camera. Send this file back after the test.")
        XCTAssertEqual(FailureText.sentence(.diagnosticsExportPartial, ["the unified log", "log show timed out"]), "The diagnostics file was saved without the unified log: log show timed out.")
        XCTAssertEqual(FailureText.sentence(.diagnosticsExportFailed, ["the disk is full"]), "Could not save the diagnostics file: the disk is full. Use Diagnostics > Copy diagnostics instead.")
        XCTAssertEqual(FailureText.logLine(.diagnosticsExportSaved, ["diagnostics-2026-10-03-14-05.zip", "1024", "12"]), "failure.diagnosticsExportSaved (row 45): diagnostics export: wrote diagnostics-2026-10-03-14-05.zip (1024 bytes, 12 files)")
        XCTAssertEqual(FailureText.logLine(.diagnosticsExportFailed, ["ENOSPC"]), "failure.diagnosticsExportFailed (row 47): diagnostics export failed: ENOSPC")
    }

    /// Presenter Overlay rows, every sentence and log line exact (SPEC 13.3 rows 48 and 49).
    func testOverlayRowsExact() {
        XCTAssertEqual(FailureText.Case.overlayFallback.row, "48")
        XCTAssertEqual(FailureText.Case.overlayLowCoverage.row, "49")
        XCTAssertEqual(FailureText.sentence(.overlayFallback), "Overlay mode could not find you in the camera picture, so Daylight is showing Studio Split. Turn Overlay off and on in Settings > Overlay to try again.")
        XCTAssertEqual(FailureText.sentence(.overlayFallback, ["request failed"]), FailureText.sentence(.overlayFallback), "the sentence takes no argument")
        XCTAssertEqual(FailureText.sentence(.overlayLowCoverage), "Overlay is showing your whole camera picture because it cannot separate you from the background (too dark, or nobody in view).")
        XCTAssertEqual(FailureText.logLine(.overlayFallback, ["15", "request failed"]), "failure.overlayFallback (row 48): overlay: segmentation failed 15 frames in a row: request failed")
        XCTAssertEqual(FailureText.logLine(.overlayLowCoverage, ["0.009"]), "failure.overlayLowCoverage (row 49): overlay: mask coverage 0.009 below 0.01; showing the camera rectangle")
    }

    func testEveryCaseHasASentenceAndALogLine() {
        for c in FailureText.Case.allCases {
            let log = FailureText.logLine(c)
            XCTAssertTrue(log.hasPrefix("failure.\(c.rawValue) (row \(c.row)): "), log)
            XCTAssertGreaterThan(log.count, "failure.\(c.rawValue) (row \(c.row)): ".count, "\(c) log line has content")
            if c == .bonjourRenamed {
                XCTAssertEqual(FailureText.sentence(c), "", "row 17: nothing visible")
            } else {
                XCTAssertFalse(FailureText.sentence(c).isEmpty, "\(c) has a sentence")
            }
            XCTAssertFalse(FailureText.sentence(c).contains("\u{2014}"), "no em-dashes")
            XCTAssertFalse(log.contains("\u{2014}"))
        }
    }

    func testExactOwnerFacingText() {
        XCTAssertEqual(FailureText.sentence(.notInApplications), "Move Daylight to your Applications folder, then open it from there.")
        XCTAssertEqual(FailureText.sentence(.unsignedBuild), "This is an unsigned test build. The virtual camera cannot be installed on this Mac. Use Daylight > Preview window to see the output.")
        XCTAssertEqual(FailureText.sentence(.cameraAccessDenied), "Camera access is off for Daylight.")
        XCTAssertEqual(FailureText.sentence(.noWebcam), "No camera found")
        XCTAssertEqual(FailureText.sentence(.webcamFormatComposed, ["1280", "720", "NV12"]), "Camera delivers 1280x720 NV12; composing every frame", "the SPEC example")
        XCTAssertEqual(FailureText.sentence(.webcamFormatComposed, ["1920", "1080", "420v", "true"]), "Camera delivers 1920x1080 420v; composing every frame", "the pipeline's four arguments; the iosurface flag is for the log line")
        XCTAssertEqual(FailureText.sentence(.webcamFormatComposed), "Camera delivers <w>x<h> <fourcc>; composing every frame", "placeholders stay without arguments")
        XCTAssertEqual(FailureText.sentence(.extensionMissingEntitlement), "The camera extension is missing an entitlement (build signing problem).")
        XCTAssertEqual(FailureText.sentence(.extensionUnsupportedLocation), FailureText.sentence(.notInApplications), "row 7 reads as row 1")
        XCTAssertEqual(FailureText.sentence(.extensionDamaged), "The camera extension inside this build is damaged. Download the build again.")
        XCTAssertEqual(FailureText.sentence(.extensionSignatureInvalid), "macOS refused the extension's signature. This build is not notarized.")
        XCTAssertEqual(FailureText.sentence(.extensionValidationFailed), "The extension's service name does not match its app group (build configuration).")
        XCTAssertEqual(FailureText.sentence(.extensionForbiddenByPolicy), "Your Mac's security policy blocks system extensions (MDM or SIP setting).")
        XCTAssertEqual(FailureText.sentence(.extensionNeedsApproval), "Approve 'Daylight Camera' in System Settings > General > Login Items & Extensions > Camera Extensions, then click Check again.")
        XCTAssertEqual(FailureText.sentence(.extensionNeedsApproval, [FailureText.approvalPathLegacy]), "Approve 'Daylight Camera' in System Settings > Privacy & Security > Security, then click Check again.", "13 and 14 wording variant")
        XCTAssertEqual(FailureText.sentence(.extensionNeedsReboot), "Restart your Mac once to finish installing Daylight Camera.")
        XCTAssertEqual(FailureText.sentence(.sinkDeviceNotFound), "Daylight Camera is installed but not found yet. Retrying...")
        XCTAssertEqual(FailureText.followUp(.sinkDeviceNotFound), "Open Zoom or FaceTime once, or restart your Mac.")
        XCTAssertNil(FailureText.followUp(.noWebcam))
        // Row 13 after 30 s: the menu status line and the onboarding row show both sentences (camera review CAMA-01).
        XCTAssertEqual(FailureText.sentence(.sinkDeviceNotFound, detail: "Open Zoom or FaceTime once, or restart your Mac."), "Daylight Camera is installed but not found yet. Retrying... Open Zoom or FaceTime once, or restart your Mac.")
        XCTAssertEqual(FailureText.sentence(.sinkDeviceNotFound, detail: "AB51C6BA-17FD-4A67-BE3A-06A8540BA6AA"), "Daylight Camera is installed but not found yet. Retrying...", "before 30 s the detail is the UUID, which no placeholder takes")
        XCTAssertEqual(FailureText.sentence(.scrcpyServerFailed, detail: "boom"), "The screen mirror could not start: boom", "any other detail fills the placeholder")
        XCTAssertEqual(FailureText.sentence(.sinkStreamLayout, detail: ""), "Daylight Camera has an unexpected stream layout.")
        XCTAssertEqual(FailureText.sentence(.sinkStreamLayout), "Daylight Camera has an unexpected stream layout.")
        XCTAssertEqual(FailureText.sentence(.viewerShowsBlack), "If Zoom shows a black picture, quit and reopen Zoom.")
        XCTAssertEqual(FailureText.sentence(.portInUse, ["7788", "7789"]), "Port 7788 is in use. Daylight is using 7789.")
        XCTAssertEqual(FailureText.sentence(.portInUse, ["7788"]), "Port 7788 is in use. Quit the other app or change the port in Settings.")
        XCTAssertEqual(FailureText.sentence(.nobodyConnected), "Nobody has connected yet. Same Wi-Fi? Office networks often block this: use USB or Tailscale.")
        XCTAssertEqual(FailureText.sentence(.allowDismissed, ["Mike's DC-1"]), "Allow Mike's DC-1")
        XCTAssertEqual(FailureText.sentence(.adbNoDevice), "No Daylight found over USB. Is USB debugging on?")
        XCTAssertEqual(FailureText.sentence(.adbUnauthorized), "Tap Allow on your Daylight (tick Always allow).")
        XCTAssertEqual(FailureText.sentence(.adbOffline), "The Daylight is connected but not responding. Unplug and plug again.")
        XCTAssertEqual(FailureText.sentence(.adbVersionClash), "Another adb is running (Android Studio?). Daylight is using its own copy; a tablet already claimed by the other adb will not be visible.")
        XCTAssertEqual(FailureText.sentence(.scrcpyServerFailed, ["[server] ERROR: boom"]), "The screen mirror could not start: [server] ERROR: boom")
        XCTAssertEqual(FailureText.sentence(.scrcpyCodecError), "Your Daylight refused screen capture (codec error).")
        XCTAssertEqual(FailureText.sentence(.decoderError), "Recovering video...")
        XCTAssertEqual(FailureText.sentence(.noPenDevice), "Pen events not found on this Daylight. Mirror works, but auto-engage and the pen button do not. Use the pills or the Whiteboard hotkey.")
        XCTAssertEqual(FailureText.sentence(.noSideButtonEvents), "Pen button events not seen; use the pills.")
        XCTAssertEqual(FailureText.sentence(.pillsInvisible), "Allow display over other apps")
        XCTAssertEqual(FailureText.sentence(.mdnsNotFound), "Looking for your Mac... Enter its address if this takes long")
        XCTAssertEqual(FailureText.sentence(.saveFailed, ["No space left on device"]), "Could not save the whiteboard: No space left on device")
        XCTAssertEqual(FailureText.sentence(.wifiMirrorFailed), "Plug in once to re-enable Wi-Fi mirroring.")
        XCTAssertEqual(FailureText.sentence(.captureIdle), "Webcam capture is paused because no app is viewing Daylight Camera (LED off). It restarts within a second when a call starts.")
    }

    func testLogLines() {
        XCTAssertEqual(FailureText.logLine(.notInApplications, ["/Users/mike/Downloads/Daylight.app"]), "failure.notInApplications (row 1): bundle path not under /Applications: /Users/mike/Downloads/Daylight.app")
        XCTAssertEqual(FailureText.logLine(.unsignedBuild), "failure.unsignedBuild (row 2): DaylightBuildSigned=false")
        XCTAssertEqual(FailureText.logLine(.cameraAccessDenied), "failure.cameraAccessDenied (row 3): AVAuthorizationStatus = denied")
        XCTAssertEqual(FailureText.logLine(.noWebcam), "failure.noWebcam (row 4): cameras() returned 0")
        XCTAssertEqual(FailureText.logLine(.webcamFormatComposed, ["1280", "720", "420v", "true"]), "failure.webcamFormatComposed (row 5): first frame 1280x720 420v iosurface=true")
        XCTAssertEqual(FailureText.logLine(.extensionMissingEntitlement), "failure.extensionMissingEntitlement (row 6): OSSystemExtensionError 2 missingEntitlement")
        XCTAssertEqual(FailureText.logLine(.extensionSignatureInvalid), "failure.extensionSignatureInvalid (row 9): OSSystemExtensionError 8 codeSignatureInvalid")
        XCTAssertEqual(FailureText.logLine(.extensionValidationFailed), "failure.extensionValidationFailed (row 10): OSSystemExtensionError 9 validationFailed")
        XCTAssertEqual(FailureText.logLine(.extensionForbiddenByPolicy), "failure.extensionForbiddenByPolicy (row 11): OSSystemExtensionError 10 forbiddenBySystemPolicy")
        XCTAssertEqual(FailureText.logLine(.extensionNeedsApproval), "failure.extensionNeedsApproval (row 12): requestNeedsUserApproval")
        XCTAssertEqual(FailureText.logLine(.extensionNeedsReboot), "failure.extensionNeedsReboot (row 12b): willCompleteAfterReboot")
        XCTAssertEqual(FailureText.logLine(.sinkDeviceNotFound, ["ABC", "[x, y]"]), "failure.sinkDeviceNotFound (row 13): sink: no CMIO device with UID ABC; devices=[x, y]")
        XCTAssertEqual(FailureText.logLine(.portInUse, ["Address already in use"]), "failure.portInUse (row 16): NWListener failed: Address already in use")
        XCTAssertEqual(FailureText.logLine(.allowDismissed, ["6f1a"]), "failure.allowDismissed (row 19): client 6f1a pending")
        XCTAssertEqual(FailureText.logLine(.adbUnauthorized), "failure.adbUnauthorized (row 22): state=unauthorized")
        XCTAssertEqual(FailureText.logLine(.adbOffline), "failure.adbOffline (row 23): state=offline")
        XCTAssertEqual(FailureText.logLine(.adbVersionClash, ["41", "39"]), "failure.adbVersionClash (row 24): host:version mismatch 41 vs 39")
        XCTAssertEqual(FailureText.logLine(.scrcpyCodecError, ["0x00000001"]), "failure.scrcpyCodecError (row 26): codec id = 0x00000001")
        XCTAssertEqual(FailureText.logLine(.decoderError, ["-12909"]), "failure.decoderError (row 27): VTDecompressionSessionDecodeFrame status -12909")
        XCTAssertEqual(FailureText.logLine(.noSideButtonEvents), "failure.noSideButtonEvents (row 28b): no BTN_STYLUS after 30 s of inking")
        XCTAssertEqual(FailureText.logLine(.wifiMirrorFailed, ["192.168.1.40", "failed to connect"]), "failure.wifiMirrorFailed (row 32): adb connect 192.168.1.40:5555 -> failed to connect")
        XCTAssertEqual(FailureText.logLine(.captureIdle), "failure.captureIdle (row 33): capture stopped: viewers=0 preview=hidden")
    }

    /// SPEC 13.3 rows 34 to 38: Mirror over Wi-Fi (Daylight Ink screen stream, PROTOCOL 14).
    func testWifiStreamRows34To38() {
        XCTAssertEqual(FailureText.sentence(.wifiStreamConsentDenied), "Daylight Ink was not allowed to share the tablet screen. Tap the Daylight Ink notification on the tablet and choose Start now.")
        XCTAssertEqual(FailureText.sentence(.wifiStreamEncoderUnavailable), "Your Daylight could not start its screen encoder. Restart Daylight Ink, or use Mirror over USB.")
        XCTAssertEqual(FailureText.sentence(.wifiStreamStalled), "The tablet's screen stream paused. Reconnecting...")
        XCTAssertEqual(FailureText.sentence(.wifiStreamFrameDiffEngage), "Mirror over Wi-Fi starts the whiteboard when the tablet screen changes. Plug in with USB debugging for pen-exact engage.")
        XCTAssertEqual(FailureText.sentence(.wifiStreamNoTablet), "Open Daylight Ink on your Daylight to mirror over Wi-Fi.")
        XCTAssertEqual(FailureText.logLine(.wifiStreamConsentDenied, ["Mike's DC-1"]), "failure.wifiStreamConsentDenied (row 34): mirror stream: consent denied by Mike's DC-1")
        XCTAssertEqual(FailureText.logLine(.wifiStreamEncoderUnavailable, ["DC-1", "6"]), "failure.wifiStreamEncoderUnavailable (row 35): mirror stream: encoder unavailable on DC-1 (state 6)")
        XCTAssertEqual(FailureText.logLine(.wifiStreamStalled, ["2.0", "DC-1"]), "failure.wifiStreamStalled (row 36): mirror stream: no packet for 2.0 s from DC-1; key frame requested")
        XCTAssertEqual(FailureText.logLine(.wifiStreamFrameDiffEngage), "failure.wifiStreamFrameDiffEngage (row 37): mirror stream: engage source frame-diff (no USB pen watcher)")
        XCTAssertEqual(FailureText.logLine(.wifiStreamNoTablet), "failure.wifiStreamNoTablet (row 38): mirror stream: no capable Daylight Ink connection")
        XCTAssertEqual(FailureText.logLine(.wifiStreamStalled), "failure.wifiStreamStalled (row 36): mirror stream: no packet for <s> s from <label>; key frame requested", "placeholders stay without arguments")
    }

    func testPlaceholdersWithoutArgumentsStayVerbatim() {
        XCTAssertEqual(FailureText.sentence(.saveFailed), "Could not save the whiteboard: <error>")
        XCTAssertEqual(FailureText.logLine(.wifiMirrorFailed, ["10.0.0.2"]), "failure.wifiMirrorFailed (row 32): adb connect 10.0.0.2:5555 -> <stdout>")
        XCTAssertEqual(FailureText.sentence(.allowDismissed, ["a", "extra"]), "Allow a", "extra arguments are ignored")
    }
}
