import DaylightKit
import Foundation
import os
import QuartzCore

/// What the rasterizer saw on ink.queue since the last frame: the boxes of new segments, each stamped with the time it
/// was reported, and whether the page was cleared (Clear or a new page). The render queue drains it once per frame.
/// The stamp is taken on ink.queue with the render clock (`CACurrentMediaTime()`), so ink drawn while no board frame
/// renders (the camera held, auto-engage off) keeps its own age and is already stale when the frames resume.
final class InkActivity {
    /// One reported box and when it was reported.
    struct Ink {
        var box: PixelRect
        var at: Double
    }

    struct Pending {
        var ink: [Ink] = []
        var cleared = false

        /// The boxes alone, oldest first.
        var boxes: [PixelRect] { return ink.map { $0.box } }
    }

    /// More boxes than this between two frames are merged into one (a frame is 33 ms; this never happens with a pen,
    /// only when no frame drains the inbox). The merged box carries the newest stamp.
    static let maxPendingBoxes = 64

    private let pending = Locked(Pending())

    func noteInk(_ box: PixelRect, at now: Double = CACurrentMediaTime()) {
        pending.withLock { p in
            if p.ink.count >= InkActivity.maxPendingBoxes, let last = p.ink.popLast() {
                p.ink.append(Ink(box: FollowRegion.union(last.box, box), at: max(last.at, now)))
            } else {
                p.ink.append(Ink(box: box, at: now))
            }
        }
    }

    func noteCleared() {
        pending.withLock { p in
            p.ink.removeAll()
            p.cleared = true
        }
    }

    func drain() -> Pending {
        return pending.withLock { (p: inout Pending) -> Pending in
            let out = p
            p = Pending()
            return out
        }
    }
}

/// Owns the `FollowCamera` for the ink canvas on the render queue: drains `InkActivity` each frame (each box keeps the
/// time it was reported, never later than the frame), snaps to the full page on Clear and a new page, refits without
/// animation when the layout changes, and swaps the canvas quad of Studio Split and Whiteboard Only frames. Off, it
/// keeps the history (so turning it on mid-call follows at once) but returns frames unchanged. The camera is mutated
/// in place (never copied out and written back), so its history buffer stays uniquely referenced and an append or a
/// prune never copies it. Render queue only.
final class FollowDriver {
    private let activity: InkActivity
    private let canvasWidth: Double
    private let canvasHeight: Double
    private var camera: FollowCamera?
    private var lastLayout: LayoutStyle?
    private let log = Logger(subsystem: "com.twelve.daylight", category: "follow")

    init(activity: InkActivity, canvasWidth: Int = SolStream.canvasWidth, canvasHeight: Int = SolStream.canvasHeight) {
        self.activity = activity
        self.canvasWidth = Double(canvasWidth)
        self.canvasHeight = Double(canvasHeight)
    }

    /// The view the camera is heading for (nil before the first frame); tests and the perf log read it.
    var target: FollowRegion.View? { return camera?.target }
    var isFullPage: Bool { return camera?.isFullPage ?? true }

    /// `frame` as the compositor should draw it at `now`. `followable` is false for mirror pictures and the Overlay
    /// layout; the ink history is still drained so the inbox never grows.
    func frame(_ frame: StudioLayout.Frame, layout: LayoutStyle, progress: Double, now: Double, enabled: Bool, followable: Bool) -> StudioLayout.Frame {
        let pending = activity.drain()
        guard let zone = FollowFrame.restZone(layout: layout) else {
            absorb(pending, now: now)
            return frame
        }
        if camera == nil {
            camera = FollowCamera(canvasWidth: canvasWidth, canvasHeight: canvasHeight, zone: zone, now: now)
            lastLayout = layout
        }
        if lastLayout != layout {
            camera?.setGeometry(canvasWidth: canvasWidth, canvasHeight: canvasHeight, zone: zone, at: now)
            lastLayout = layout
        }
        absorb(pending, now: now)
        guard camera != nil else { return frame }
        guard enabled, followable, frame.canvas != nil else {
            camera?.update(now: now)   // keeps the history pruned to FP3 while nothing is drawn with it
            return frame
        }
        guard let quad = camera?.quad(now: now) else { return frame }
        // At rest on the full page the layout's own frame is drawn, bit for bit what it was before follow existed.
        if isFullPage && camera?.isSettled == true { return frame }
        return FollowFrame.apply(quad, to: frame, layout: layout, progress: progress)
    }

    private func absorb(_ pending: InkActivity.Pending, now: Double) {
        guard camera != nil else { return }
        if pending.cleared {
            camera?.reset(at: now)
            log.debug("follow: page cleared, full page")
        }
        for ink in pending.ink {
            // Never later than this frame, never earlier than the newest box already absorbed (the history is ordered).
            let floor = camera?.history.last?.0 ?? -Double.infinity
            camera?.noteInk(ink.box, at: max(min(ink.at, now), floor))
        }
    }
}
