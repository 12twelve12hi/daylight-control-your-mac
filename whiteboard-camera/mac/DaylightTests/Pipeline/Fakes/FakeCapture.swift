import CoreVideo
import Foundation
@testable import Daylight

/// A webcam stand-in: one static IOSurface-backed BGRA buffer (gradient for pixel probes) delivered at `fps`.
final class FakeCapture: CaptureSource {
    let buffer: CVPixelBuffer
    let fps: Int
    let queue = DispatchQueue(label: "com.twelve.daylight.tests.fakecapture", qos: .userInteractive)
    var onEvent: ((CaptureEvent) -> Void)?
    var hasDevice = true
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var running = false
    private(set) var startCount = 0
    private(set) var frames = 0
    private var current: CVPixelBuffer

    init(width: Int = 1920, height: Int = 1080, fps: Int = 30) {
        buffer = SelfTest.gradientBuffer(width: width, height: height)!
        current = buffer
        self.fps = fps
    }

    /// The buffer the timer delivers right now (`buffer` until `switchFormat`).
    var currentBuffer: CVPixelBuffer {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// A camera switch or reconnect mid-run: the next frames come in another size (WebcamCapture emits
    /// `.formatChanged` before the first frame of a new format).
    func switchFormat(width: Int, height: Int) {
        let next = SelfTest.gradientBuffer(width: width, height: height)!
        lock.lock()
        current = next
        lock.unlock()
        onEvent?(.formatChanged(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA))
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func start() throws {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        startCount += 1
        lock.unlock()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.frames += 1
            let frame = self.current
            self.lock.unlock()
            self.onEvent?(.frame(frame, hostTimeNs: DispatchTime.now().uptimeNanoseconds))
        }
        timer = source
        source.activate()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        timer?.cancel()
        timer = nil
    }

    func simulateLost() {
        onEvent?(.lost)
    }
}
