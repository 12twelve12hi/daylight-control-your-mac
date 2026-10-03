import AVFoundation
import CoreMedia
import CoreVideo
import DaylightKit
import Foundation

enum CaptureEvent {
    case frame(CVPixelBuffer, hostTimeNs: UInt64)
    case formatChanged(width: Int, height: Int, pixelFormat: OSType)
    case lost
    case restored
}

/// What the pipeline needs from a camera; `WebcamCapture` is the real one, `FakeCapture` (DaylightTests) the stand-in.
protocol CaptureSource: AnyObject {
    var onEvent: ((CaptureEvent) -> Void)? { get set }
    var isRunning: Bool { get }
    /// True when a camera device is attached (the STATE `camera_attached` bit).
    var hasDevice: Bool { get }
    func start() throws
    func stop()
}

enum CaptureError: Error {
    case noCamera
    case cannotAddInput
    case cannotAddOutput
}

/// AVCaptureSession at 1920x1080 BGRA 30 fps (research-mac-pipeline section 1). Frames are delivered on the capture
/// queue; the delegate holds no buffer (the retention warning of AVCaptureVideoDataOutput.h).
///
/// Device choice (SPEC 11 `cameraUniqueID`): the owner's explicit camera while it is present, else the system's
/// `userPreferredCamera`, else the first connected camera; evaluated live on every start and reconnect so an unplugged
/// webcam falls back to the built-in or Continuity camera. The app's own virtual "Daylight Camera" is never a
/// candidate (its uniqueID is the fixed device UUID of the Info.plist, SPEC 13.1 step 2): capturing it would feed
/// Daylight's output back into itself.
final class WebcamCapture: NSObject, CaptureSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// The facts the choice is made from; pure and unit-tested without a real device.
    struct DeviceFacts: Equatable {
        let uniqueID: String
        let name: String
        let isConnected: Bool
    }

    static let ownCameraName = "Daylight Camera"
    private static let ownCameraUniqueIDs = Locked<Set<String>>([])

    let session = AVCaptureSession()
    let queue: DispatchQueue
    var onEvent: ((CaptureEvent) -> Void)?
    var onLog: ((String) -> Void)?
    /// Settings `cameraUniqueID`; nil means the preferred-camera rule.
    var preferredUniqueID: String?
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private(set) var firstFrameFacts: (iosurface: Bool, width: Int, height: Int, fourcc: OSType)?
    private var lastFormat: (Int, Int, OSType)?

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: nil) { [weak self] note in
            guard let self = self, let gone = note.object as? AVCaptureDevice, gone.uniqueID == self.input?.device.uniqueID else { return }
            self.queue.async { self.handleLost() }
        })
        observers.append(center.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.queue.async { self.handleRestored() }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var isRunning: Bool { return running }
    var hasDevice: Bool { return input != nil }

    // MARK: Device choice

    /// Registers the app's own virtual camera (the Info.plist `DaylightCameraDeviceUUID`), compared case-insensitively.
    static func excludeOwnCamera(uniqueID: String) {
        ownCameraUniqueIDs.withLock { $0.insert(uniqueID.uppercased()) }
    }

    static func isOwnCamera(uniqueID: String, name: String) -> Bool {
        if name == ownCameraName { return true }
        return ownCameraUniqueIDs.withLock { $0.contains(uniqueID.uppercased()) }
    }

    static func isOwnCamera(_ device: AVCaptureDevice) -> Bool {
        return isOwnCamera(uniqueID: device.uniqueID, name: device.localizedName)
    }

    /// Every camera macOS knows about (DiscoverySession with the macOS 14 device types), without our own.
    static func cameras() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices.filter { !isOwnCamera($0) }
    }

    /// The pure rule: the chosen id while present and connected, else the system's preferred camera, else the first
    /// connected camera; the app's own camera and disconnected devices never.
    static func choose(preferredUniqueID: String?, systemPreferredID: String?, from devices: [DeviceFacts]) -> DeviceFacts? {
        let usable = devices.filter { $0.isConnected && !isOwnCamera(uniqueID: $0.uniqueID, name: $0.name) }
        if let id = preferredUniqueID, let match = usable.first(where: { $0.uniqueID == id }) { return match }
        if let id = systemPreferredID, let match = usable.first(where: { $0.uniqueID == id }) { return match }
        return usable.first
    }

    /// The device the rule picks right now (the onboarding row's camera name; the pipeline asks its own instance).
    static func camera(uniqueID: String?) -> AVCaptureDevice? {
        let devices = cameras()
        let facts = devices.map { DeviceFacts(uniqueID: $0.uniqueID, name: $0.localizedName, isConnected: $0.isConnected) }
        guard let chosen = choose(preferredUniqueID: uniqueID, systemPreferredID: AVCaptureDevice.userPreferredCamera?.uniqueID, from: facts) else { return nil }
        return devices.first { $0.uniqueID == chosen.uniqueID }
    }

    private func chooseDevice() -> AVCaptureDevice? {
        guard let device = WebcamCapture.camera(uniqueID: preferredUniqueID) else { return nil }
        if let wanted = preferredUniqueID, wanted != device.uniqueID {
            onLog?("camera \(wanted) is not present; using \(device.localizedName)")
        }
        return device
    }

    // MARK: Lifecycle

    func start() throws {
        guard let camera = chooseDevice() else { throw CaptureError.noCamera }
        try configure(device: camera)
        if !session.isRunning { session.startRunning() }
        running = true
    }

    func stop() {
        running = false
        if session.isRunning { session.stopRunning() }
    }

    private func configure(device camera: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let existing = input {
            session.removeInput(existing)
            input = nil
        }
        let newInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(newInput) else { throw CaptureError.cannotAddInput }
        session.addInput(newInput)
        input = newInput
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }
        pinFrameRate(camera)
        if session.outputs.isEmpty {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
            session.addOutput(output)
        }
        onLog?("capturing \(camera.localizedName) (\(camera.uniqueID))")
    }

    /// 30 fps when the active format allows it (checked first: an unsupported duration raises on iOS).
    private func pinFrameRate(_ camera: AVCaptureDevice) {
        let target = CMTime(value: 1, timescale: 30)
        let ranges = camera.activeFormat.videoSupportedFrameRateRanges
        guard ranges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) else { return }
        do {
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = target
            camera.activeVideoMaxFrameDuration = target
            camera.unlockForConfiguration()
        } catch {
            // Leave the device at its default rate; the compositor paces itself.
        }
    }

    private func handleLost() {
        if let existing = input {
            session.beginConfiguration()
            session.removeInput(existing)
            session.commitConfiguration()
            input = nil
        }
        onEvent?(.lost)
    }

    /// `wasConnectedNotification` while the session has no input: the rule runs again, so the returning webcam or any
    /// other present camera is re-added (row 4 "retried on wasConnectedNotification").
    private func handleRestored() {
        guard running, input == nil else { return }
        guard let camera = chooseDevice() else { return }
        do {
            try configure(device: camera)
        } catch {
            onLog?("camera \(camera.localizedName) could not be added: \(error)")
            return
        }
        if !session.isRunning { session.startRunning() }
        onEvent?(.restored)
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate (on `queue`)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let fourcc = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if firstFrameFacts == nil {
            firstFrameFacts = (CVPixelBufferGetIOSurface(pixelBuffer) != nil, width, height, fourcc)
        }
        if lastFormat == nil || lastFormat! != (width, height, fourcc) {
            lastFormat = (width, height, fourcc)
            onEvent?(.formatChanged(width: width, height: height, pixelFormat: fourcc))
        }
        onEvent?(.frame(pixelBuffer, hostTimeNs: DispatchTime.now().uptimeNanoseconds))
    }
}
