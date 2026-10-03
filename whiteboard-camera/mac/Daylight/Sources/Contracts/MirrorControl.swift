// MirrorControl.swift
import CoreVideo
import DaylightKit

enum MirrorStatus: Equatable {
    case idle                                  // mirror source not selected or stopped
    case noDevice                              // tracking, no DC-1 visible
    case connecting(serial: String)
    case mirroring(serial: String, width: Int, height: Int)
    case error(FailureText.Case, String)
}

/// Implemented by MirrorController (F); the only F type that B constructs or calls.
protocol MirrorControl: AnyObject {
    var source: MirrorFrameSource { get }
    var status: MirrorStatus { get }
    var onStatusChange: ((MirrorStatus) -> Void)? { get set }
    var devices: [AdbDevice] { get }
    var onDevicesChange: (([AdbDevice]) -> Void)? { get set }
    var diagnostics: [String: String] { get }  // adb server mode and version, pen node, session size, codec
    func start()                               // start device tracking; mirror the chosen DC-1 when present
    func stop()
    /// One `adb devices -l` while the tracker is not running, so the Welcome window's "Your Daylight" row sees a tablet
    /// on USB with the Web or Daylight Ink source selected too (SPEC 13.1 step 3); rate-limited, a no-op while mirroring.
    func refreshDevices()
    /// USB onboarding for the other two sources (SPEC 9.2 step 1 and 9.3 step 1).
    func setUpOverUSB(source: InkSource, host: String?, pills: Bool, completion: @escaping (Result<Void, Error>) -> Void)
    /// Last decoded frame and its crop, for SessionSaver.saveMirror (SPEC 12).
    func latestFrameForSave() -> (buffer: CVPixelBuffer, uv: UVRect)?
    func tryWiFiMirror(completion: @escaping (Bool) -> Void)   // SPEC D42
}
