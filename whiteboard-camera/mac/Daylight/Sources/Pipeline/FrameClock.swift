import Foundation
import QuartzCore

/// The 30 Hz render clock (SPEC D34): a strict `DispatchSourceTimer` with 1 ms leeway on the render queue, running
/// only while the governor is not in PASSTHROUGH or a hold mode is active. The tick passes `CACurrentMediaTime()`
/// so a late tick never slows the spring.
final class FrameClock {
    let queue: DispatchQueue
    let fps: Int
    var onTick: ((Double) -> Void)?
    private var timer: DispatchSourceTimer?

    init(queue: DispatchQueue, fps: Int = 30) {
        self.queue = queue
        self.fps = max(1, fps)
    }

    var isRunning: Bool { return timer != nil }

    /// Idempotent. Call on `queue`.
    func start() {
        if timer != nil { return }
        let source = DispatchSource.makeTimerSource(flags: [.strict], queue: queue)
        let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000 / Double(fps)))
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.onTick?(CACurrentMediaTime())
        }
        timer = source
        source.activate()
    }

    /// Idempotent. Call on `queue`.
    func stop() {
        guard let source = timer else { return }
        timer = nil
        source.cancel()
    }
}
