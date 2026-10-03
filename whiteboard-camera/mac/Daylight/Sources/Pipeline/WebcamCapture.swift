import AVFoundation
import CoreMedia
import CoreVideo
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
final class WebcamCapture: NSObject, CaptureSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue: DispatchQueue
    var onEvent: ((CaptureEvent) -> Void)?
    /// The camera to use; nil means `AVCaptureDevice.userPreferredCamera`, then the first camera found.
    var device: AVCaptureDevice?
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

    /// Every camera macOS knows about (DiscoverySession with the macOS 14 device types).
    static func cameras() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    static func camera(uniqueID: String?) -> AVCaptureDevice? {
        if let id = uniqueID, let match = cameras().first(where: { $0.uniqueID == id }) { return match }
        return AVCaptureDevice.userPreferredCamera ?? cameras().first
    }

    func start() throws {
        let chosen = device ?? AVCaptureDevice.userPreferredCamera ?? WebcamCapture.cameras().first
        guard let camera = chosen else { throw CaptureError.noCamera }
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

    private func handleRestored() {
        guard running, input == nil else { return }
        let chosen = device ?? AVCaptureDevice.userPreferredCamera ?? WebcamCapture.cameras().first
        guard let camera = chosen, (try? configure(device: camera)) != nil else { return }
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
