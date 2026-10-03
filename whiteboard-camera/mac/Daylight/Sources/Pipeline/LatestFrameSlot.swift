import CoreVideo
import Foundation
import os

/// The one-deep hand-off between the capture queue and the render queue (ARCHITECTURE 3.4: capacity 1, replace).
/// `take()` returns the newest entry and leaves it in place so a 30 Hz render loop can re-use a 30 fps camera frame
/// when the two clocks interleave; `clear()` empties the slot (camera lost, idle stop).
final class LatestFrameSlot {
    struct Entry {
        let buffer: CVPixelBuffer
        let hostTimeNs: UInt64
        let sequence: UInt64
    }

    private struct State {
        var entry: Entry?
        var sequence: UInt64 = 0
    }

    private let lock = OSAllocatedUnfairLock<State>(uncheckedState: State())

    func publish(_ buffer: CVPixelBuffer, hostTimeNs: UInt64) {
        lock.withLockUnchecked { state in
            state.sequence += 1
            state.entry = Entry(buffer: buffer, hostTimeNs: hostTimeNs, sequence: state.sequence)
        }
    }

    func take() -> Entry? {
        return lock.withLockUnchecked { $0.entry }
    }

    func clear() {
        lock.withLockUnchecked { $0.entry = nil }
    }

    /// Number of frames published so far (the compositor's "camera sequence" for frame reuse).
    var sequence: UInt64 {
        return lock.withLockUnchecked { $0.sequence }
    }
}
