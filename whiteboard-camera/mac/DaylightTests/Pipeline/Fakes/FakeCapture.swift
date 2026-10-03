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
    /// Called at the top of `start()`, on the caller's queue (the render queue), before the timer exists: tests read
    /// what the sink already received at the moment the real camera would begin its blocking warm-up.
    var onStart: (() -> Void)?
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var running = false
    private var starts = 0
    private var delivered = 0
    private var current: CVPixelBuffer

    init(width: Int = 1920, height: Int = 1080, fps: Int = 30) {
        buffer = SelfTest.gradientBuffer(width: width, height: height)!
        current = buffer
        self.fps = fps
    }

    /// The buffer the timer delivers right now (`buffer` until `switchFormat` or `replaceBuffer`).
    var currentBuffer: CVPixelBuffer {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Frames delivered so far (each one before its `onEvent`).
    var frames: Int {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    /// A camera switch or reconnect mid-run: the next frames come in another size (WebcamCapture emits
    /// `.formatChanged` on the capture queue before the first frame of a new format; so does this fake, so no frame
    /// of the new size can slip in between the swap and the event).
    func switchFormat(width: Int, height: Int) {
        let next = SelfTest.gradientBuffer(width: width, height: height)!
        queue.sync {
            lock.lock()
            current = next
            lock.unlock()
            onEvent?(.formatChanged(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA))
        }
    }

    /// The next frames are a new buffer of the same size and format (a live camera hands out fresh buffers): tests
    /// tell the cached frame from live ones by identity. Returns the new buffer.
    @discardableResult
    func replaceBuffer() -> CVPixelBuffer {
        let old = currentBuffer
        let next = SelfTest.gradientBuffer(width: CVPixelBufferGetWidth(old), height: CVPixelBufferGetHeight(old))!
        lock.lock()
        current = next
        lock.unlock()
        return next
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func start() throws {
        lock.lock()
        if running { lock.unlock(); return }
        lock.unlock()
        onStart?()
        lock.lock()
        running = true
        starts += 1
        lock.unlock()
        startTimer()
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

    /// The camera in use is unplugged while another one is present: `.lost`, then `.restored` and frames again, on
    /// the capture queue in that order (what WebcamCapture's fallback emits).
    func simulateLostWithFallback() {
        queue.async { [weak self] in
            self?.onEvent?(.lost)
            self?.onEvent?(.restored)
        }
        lock.lock()
        running = true
        lock.unlock()
        startTimer()
    }

    /// One frame now. Call on `queue` (it is the timer handler's body).
    func deliverFrame() {
        lock.lock()
        delivered += 1
        let frame = current
        lock.unlock()
        onEvent?(.frame(frame, hostTimeNs: DispatchTime.now().uptimeNanoseconds))
    }

    private func startTimer() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.deliverFrame() }
        timer = source
        source.activate()
    }
}
