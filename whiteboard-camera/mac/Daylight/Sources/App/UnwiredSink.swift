import CoreMedia
import DaylightKit
import Foundation

/// The sink used while component C's `PreviewOnlySink` and `CMIOSinkClient` are not in the tree: status
/// `.notInstalled` keeps webcam capture running (SPEC D32: capture runs while the sink is not connected) and the
/// preview window is the only output. `AppDelegate.makeSink` swaps in C's types the day they land.
final class UnwiredSink: VirtualCameraSink {
    private(set) var status: SinkStatus = .notInstalled
    var onStatusChange: ((SinkStatus) -> Void)?
    var onQueueAltered: (() -> Void)?
    var viewerCount: Int = 0
    var onViewerCount: ((Int) -> Void)?
    private let pushes = Locked<UInt64>(0)

    func start() {}
    func stop() {}

    @discardableResult
    func push(_ sampleBuffer: CMSampleBuffer) -> Bool {
        pushes.withLock { $0 += 1 }
        return true
    }

    var pushCount: UInt64 { return pushes.withLock { $0 } }
}
