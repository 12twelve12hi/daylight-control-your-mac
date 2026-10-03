import CoreMedia
import DaylightKit
import Foundation

/// The sink of an unsigned build and of tests (SPEC D19, IMPLEMENTATION-PLAN section 10): status `.installed` so the
/// idle rule keeps the webcam running for the preview window, `push` accepts and discards every frame, no viewers.
final class PreviewOnlySink: VirtualCameraSink {
    private(set) var status: SinkStatus = .installed
    var onStatusChange: ((SinkStatus) -> Void)?
    var onQueueAltered: (() -> Void)?
    let viewerCount: Int = 0
    var onViewerCount: ((Int) -> Void)?
    private let pushes = Locked<UInt64>(0)
    private let running = Locked<Bool>(false)

    init() {}

    var pushCount: UInt64 { return pushes.withLock { $0 } }
    var isRunning: Bool { return running.withLock { $0 } }

    func start() {
        running.withLock { $0 = true }
        onStatusChange?(status)
    }

    func stop() {
        running.withLock { $0 = false }
    }

    @discardableResult
    func push(_ sampleBuffer: CMSampleBuffer) -> Bool {
        pushes.withLock { $0 += 1 }
        return true
    }
}
