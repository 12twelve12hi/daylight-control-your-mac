import DaylightKit
import Foundation
import os

/// What the rasterizer saw on ink.queue since the last frame: the boxes of new segments and whether the page was
/// cleared (Clear or a new page). The render queue drains it once per frame.
final class InkActivity {
    struct Pending {
        var boxes: [PixelRect] = []
        var cleared = false
    }

    /// More boxes than this between two frames are merged into one (a frame is 33 ms; this never happens with a pen).
    static let maxPendingBoxes = 64

    private let pending = Locked(Pending())

    func noteInk(_ box: PixelRect) {
        pending.withLock { p in
            if p.boxes.count >= InkActivity.maxPendingBoxes, let last = p.boxes.popLast() {
                p.boxes.append(FollowRegion.union(last, box))
            } else {
                p.boxes.append(box)
            }
        }
    }

    func noteCleared() {
        pending.withLock { p in
            p.boxes.removeAll()
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

/// Owns the `FollowCamera` for the ink canvas on the render queue: drains `InkActivity` each frame (stamping boxes
/// with the frame time), snaps to the full page on Clear and a new page, refits without animation when the layout
/// changes, and swaps the canvas quad of Studio Split and Whiteboard Only frames. Off, it keeps the history (so
/// turning it on mid-call follows at once) but returns frames unchanged. Render queue only.
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
        guard var cam = camera else { return frame }
        guard enabled, followable, frame.canvas != nil else {
            cam.update(now: now)   // keeps the history pruned to FP3 while nothing is drawn with it
            camera = cam
            return frame
        }
        let quad = cam.quad(now: now)
        camera = cam
        // At rest on the full page the layout's own frame is drawn, bit for bit what it was before follow existed.
        if cam.isFullPage && cam.isSettled { return frame }
        return FollowFrame.apply(quad, to: frame, layout: layout, progress: progress)
    }

    private func absorb(_ pending: InkActivity.Pending, now: Double) {
        guard var cam = camera else { return }
        if pending.cleared {
            cam.reset(at: now)
            log.debug("follow: page cleared, full page")
        }
        for box in pending.boxes { cam.noteInk(box, at: now) }
        camera = cam
    }
}
