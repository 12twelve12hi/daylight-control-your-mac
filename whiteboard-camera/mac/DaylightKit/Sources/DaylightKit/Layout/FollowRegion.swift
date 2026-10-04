import Foundation

/// "Follow the pen" (docs/product/TOO-SMALL.md section 7, numbers FP1 to FP9): a virtual camera over the ink canvas
/// that magnifies the region being written in, so a drawing stays legible in a small call tile. Pure geometry plus a
/// small state machine with hysteresis; the compositor only needs the `QuadSpec` that `quad(_:canvasWidth:canvasHeight:zone:)`
/// returns (dest in output pixels, uv in canvas 0...1), the same shape `StudioLayout` already hands it.
///
/// Coordinates: canvas boxes are canvas pixels (1200x1600 for the ink canvas, y down); `zone` is the output rectangle
/// the canvas may fill (the studio zone in Studio Split, the whole frame in Whiteboard Only). A `View` is a camera:
/// the canvas point at the zone centre and the zoom in output pixels per canvas pixel.
public enum FollowRegion {
    /// FP1: never magnify more than 2.5 times the full page fitted in the zone.
    public static let maxMagnification: Double = 2.5
    /// FP2: margin added around the active ink on every side, as a fraction of the canvas width.
    public static let padding: Double = 0.06
    /// FP3: ink older than 20 s no longer counts towards the active region.
    public static let activitySeconds: Double = 20
    /// FP4: the camera moves at once when active ink comes closer than 5 % of the visible width to an edge.
    public static let edgeMargin: Double = 0.05
    /// FP5: it zooms in only when the active region would fit at 1.25 times the current zoom or more...
    public static let zoomInFactor: Double = 1.25
    /// FP6: ...continuously for 2.5 s (the camera never jumps on the first stroke).
    public static let zoomInDelaySeconds: Double = 2.5
    /// FP7: 30 s without ink returns to the full page.
    public static let idleReturnSeconds: Double = 30
    /// FP8: spring stiffness of the camera move (omega about 7.7 per second, settled in well under a second).
    public static let springK: Double = 60
    /// FP9: an ink box narrower than 10 % of the canvas width is widened to that, so a dot is not a target.
    public static let minimumExtent: Double = 0.10

    public struct Config: Equatable {
        public var maxMagnification: Double
        public var padding: Double
        public var activitySeconds: Double
        public var edgeMargin: Double
        public var zoomInFactor: Double
        public var zoomInDelaySeconds: Double
        public var idleReturnSeconds: Double
        public var springK: Double
        public var minimumExtent: Double

        public init(maxMagnification: Double = FollowRegion.maxMagnification, padding: Double = FollowRegion.padding, activitySeconds: Double = FollowRegion.activitySeconds, edgeMargin: Double = FollowRegion.edgeMargin, zoomInFactor: Double = FollowRegion.zoomInFactor, zoomInDelaySeconds: Double = FollowRegion.zoomInDelaySeconds, idleReturnSeconds: Double = FollowRegion.idleReturnSeconds, springK: Double = FollowRegion.springK, minimumExtent: Double = FollowRegion.minimumExtent) {
            self.maxMagnification = maxMagnification
            self.padding = padding
            self.activitySeconds = activitySeconds
            self.edgeMargin = edgeMargin
            self.zoomInFactor = zoomInFactor
            self.zoomInDelaySeconds = zoomInDelaySeconds
            self.idleReturnSeconds = idleReturnSeconds
            self.springK = springK
            self.minimumExtent = minimumExtent
        }

        public static let `default` = Config()
    }

    /// A camera over the canvas: `cx`, `cy` in canvas pixels, `zoom` in output pixels per canvas pixel.
    public struct View: Equatable {
        public var cx: Double
        public var cy: Double
        public var zoom: Double

        public init(cx: Double, cy: Double, zoom: Double) {
            self.cx = cx
            self.cy = cy
            self.zoom = zoom
        }
    }

    /// The zoom at which the whole canvas fits the zone (what `StudioLayout.fit` draws today).
    public static func fullPageZoom(canvasWidth w: Double, canvasHeight h: Double, zone: PixelRect) -> Double {
        return min(zone.w / w, zone.h / h)
    }

    /// The whole page, centred: the picture of the layouts without follow.
    public static func fullPage(canvasWidth w: Double, canvasHeight h: Double, zone: PixelRect) -> View {
        return View(cx: w / 2, cy: h / 2, zoom: fullPageZoom(canvasWidth: w, canvasHeight: h, zone: zone))
    }

    /// The canvas rectangle a view covers (it may extend past the canvas when the zone is wider than the page).
    public static func visible(_ v: View, zone: PixelRect) -> PixelRect {
        let vw = zone.w / v.zoom
        let vh = zone.h / v.zoom
        return PixelRect(x: v.cx - vw / 2, y: v.cy - vh / 2, w: vw, h: vh)
    }

    /// Keeps the zoom within [full page, full page x maxMagnification] and the visible rectangle on the canvas along
    /// every axis where it is smaller than the canvas (centred on the canvas along the others).
    public static func clamp(_ v: View, canvasWidth w: Double, canvasHeight h: Double, zone: PixelRect, maxMagnification: Double = FollowRegion.maxMagnification) -> View {
        let z0 = fullPageZoom(canvasWidth: w, canvasHeight: h, zone: zone)
        let zoom = min(max(v.zoom, z0), z0 * max(maxMagnification, 1))
        let vw = zone.w / zoom
        let vh = zone.h / zoom
        let cx = vw >= w ? w / 2 : min(max(v.cx, vw / 2), w - vw / 2)
        let cy = vh >= h ? h / 2 : min(max(v.cy, vh / 2), h - vh / 2)
        return View(cx: cx, cy: cy, zoom: zoom)
    }

    /// The smallest view that shows `box` with the padding, clamped (FP1, FP2, FP9).
    public static func fit(_ box: PixelRect, canvasWidth w: Double, canvasHeight h: Double, zone: PixelRect, config: Config = .default) -> View {
        let minSide = config.minimumExtent * w
        let bw = max(box.w, minSide)
        let bh = max(box.h, minSide)
        let pad = config.padding * w
        let pw = bw + 2 * pad
        let ph = bh + 2 * pad
        let zoom = min(zone.w / pw, zone.h / ph)
        let view = View(cx: box.x + box.w / 2, cy: box.y + box.h / 2, zoom: zoom)
        return clamp(view, canvasWidth: w, canvasHeight: h, zone: zone, maxMagnification: config.maxMagnification)
    }

    /// The compositor's quad for a view: `dest` is the part of the zone the canvas covers, `uv` the matching canvas
    /// sub-rectangle. At the full page it equals `StudioLayout.fit(aspect: w / h, into: zone)` with uv `.full`.
    public static func quad(_ v: View, canvasWidth w: Double, canvasHeight h: Double, zone: PixelRect) -> QuadSpec {
        let r = visible(v, zone: zone)
        let x0 = max(r.x, 0)
        let y0 = max(r.y, 0)
        let x1 = min(r.x + r.w, w)
        let y1 = min(r.y + r.h, h)
        let iw = max(x1 - x0, 0)
        let ih = max(y1 - y0, 0)
        let dest = PixelRect(x: zone.x + (x0 - r.x) * v.zoom, y: zone.y + (y0 - r.y) * v.zoom, w: iw * v.zoom, h: ih * v.zoom)
        let uv = UVRect(u0: x0 / w, v0: y0 / h, u1: (x0 + iw) / w, v1: (y0 + ih) / h)
        return QuadSpec(dest: dest, uv: uv)
    }

    /// True when `inner` lies inside `outer` shrunk by `margin` on every side.
    public static func contains(_ outer: PixelRect, _ inner: PixelRect, margin: Double) -> Bool {
        return inner.x >= outer.x + margin && inner.y >= outer.y + margin
            && inner.x + inner.w <= outer.x + outer.w - margin && inner.y + inner.h <= outer.y + outer.h - margin
    }

    /// The smallest rectangle containing both.
    public static func union(_ a: PixelRect, _ b: PixelRect) -> PixelRect {
        let x0 = min(a.x, b.x)
        let y0 = min(a.y, b.y)
        let x1 = max(a.x + a.w, b.x + b.w)
        let y1 = max(a.y + a.h, b.y + b.h)
        return PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// The bounding box of stroke points in canvas pixels; nil for no points.
    public static func boundingBox(xs: [Double], ys: [Double]) -> PixelRect? {
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return PixelRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }
}

/// The stateful follower: feed it ink boxes, ask it for the view each frame. One instance per canvas; not thread-safe
/// (the pipeline keeps it on the render queue, like the governor's spring).
public struct FollowCamera {
    public let config: FollowRegion.Config
    public private(set) var canvasWidth: Double
    public private(set) var canvasHeight: Double
    public private(set) var zone: PixelRect
    /// Where the camera is heading (changes only at the hysteresis decisions).
    public private(set) var target: FollowRegion.View
    /// The boxes of the last `activitySeconds` (time, box), oldest first.
    public private(set) var history: [(Double, PixelRect)] = []
    public private(set) var lastInk: Double?
    private var zoomInSince: Double?
    private var springX: CriticalSpring
    private var springY: CriticalSpring
    /// The zoom animates in log space so zooming in and out feel the same speed.
    private var springZ: CriticalSpring

    public init(canvasWidth: Double, canvasHeight: Double, zone: PixelRect, config: FollowRegion.Config = .default, now: Double = 0) {
        self.config = config
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.zone = zone
        let full = FollowRegion.fullPage(canvasWidth: canvasWidth, canvasHeight: canvasHeight, zone: zone)
        target = full
        springX = CriticalSpring(k: config.springK, position: full.cx)
        springY = CriticalSpring(k: config.springK, position: full.cy)
        springZ = CriticalSpring(k: config.springK, position: log(full.zoom))
        springX.snap(to: full.cx, at: now)
        springY.snap(to: full.cy, at: now)
        springZ.snap(to: log(full.zoom), at: now)
    }

    /// The union of the ink boxes still inside the activity window; nil when there is none.
    public var activeBox: PixelRect? {
        guard var box = history.first?.1 else { return nil }
        for (_, b) in history.dropFirst() { box = FollowRegion.union(box, b) }
        return box
    }

    public var isFullPage: Bool {
        return target == FollowRegion.fullPage(canvasWidth: canvasWidth, canvasHeight: canvasHeight, zone: zone)
    }

    /// A stroke (or a chunk of one) touched `box` at `now`.
    public mutating func noteInk(_ box: PixelRect, at now: Double) {
        history.append((now, box))
        lastInk = now
    }

    /// Clear or a new page: back to the full page at once (no animation into an empty page) and forget the history.
    public mutating func reset(at now: Double) {
        history.removeAll()
        lastInk = nil
        zoomInSince = nil
        retarget(FollowRegion.fullPage(canvasWidth: canvasWidth, canvasHeight: canvasHeight, zone: zone), at: now, animated: false)
    }

    /// The layout changed the zone (Studio Split and Whiteboard Only have different zones) or the canvas changed size.
    public mutating func setGeometry(canvasWidth w: Double, canvasHeight h: Double, zone: PixelRect, at now: Double) {
        guard w != canvasWidth || h != canvasHeight || zone != self.zone else { return }
        canvasWidth = w
        canvasHeight = h
        self.zone = zone
        zoomInSince = nil
        let next: FollowRegion.View
        if let box = activeBox {
            next = FollowRegion.fit(box, canvasWidth: w, canvasHeight: h, zone: zone, config: config)
        } else {
            next = FollowRegion.fullPage(canvasWidth: w, canvasHeight: h, zone: zone)
        }
        retarget(next, at: now, animated: false)
    }

    /// Applies the hysteresis rules (FP3 to FP7) and returns the animated, clamped view for `now`.
    @discardableResult
    public mutating func update(now: Double) -> FollowRegion.View {
        decide(now: now)
        let raw = FollowRegion.View(cx: springX.evaluate(at: now), cy: springY.evaluate(at: now), zoom: exp(springZ.evaluate(at: now)))
        return FollowRegion.clamp(raw, canvasWidth: canvasWidth, canvasHeight: canvasHeight, zone: zone, maxMagnification: config.maxMagnification)
    }

    /// The compositor quad for `now` (calls `update`).
    public mutating func quad(now: Double) -> QuadSpec {
        let v = update(now: now)
        return FollowRegion.quad(v, canvasWidth: canvasWidth, canvasHeight: canvasHeight, zone: zone)
    }

    public var isSettled: Bool {
        return springX.isSettled && springY.isSettled && abs(springZ.position - springZ.target) < 1e-3 && abs(springZ.velocity) < 1e-3
    }

    private mutating func decide(now: Double) {
        let horizon = now - config.activitySeconds
        if let firstKept = history.firstIndex(where: { $0.0 > horizon }) {
            if firstKept > 0 { history.removeFirst(firstKept) }
        } else {
            history.removeAll()
        }
        let full = FollowRegion.fullPage(canvasWidth: canvasWidth, canvasHeight: canvasHeight, zone: zone)
        guard let box = activeBox else {
            zoomInSince = nil
            let idle = lastInk.map { now - $0 >= config.idleReturnSeconds } ?? true
            if idle && target != full { retarget(full, at: now, animated: true) }
            return
        }
        let desired = FollowRegion.fit(box, canvasWidth: canvasWidth, canvasHeight: canvasHeight, zone: zone, config: config)
        let seen = FollowRegion.visible(target, zone: zone)
        let canvasRect = PixelRect(x: 0, y: 0, w: canvasWidth, h: canvasHeight)
        // Clip the visible rectangle to the canvas: ink at the page edge is "inside" a view that shows the whole page.
        let seenOnCanvas = FollowRegion.intersect(seen, canvasRect)
        let margin = config.edgeMargin * seen.w
        let inside = FollowRegion.contains(FollowRegion.expandToCanvasEdges(seenOnCanvas, canvas: canvasRect, margin: margin), box, margin: margin)
        if !inside {
            zoomInSince = nil
            retarget(desired, at: now, animated: true)
            return
        }
        if desired.zoom >= target.zoom * config.zoomInFactor {
            if let since = zoomInSince {
                if now - since >= config.zoomInDelaySeconds {
                    zoomInSince = nil
                    retarget(desired, at: now, animated: true)
                }
            } else {
                zoomInSince = now
            }
        } else {
            zoomInSince = nil
        }
    }

    private mutating func retarget(_ view: FollowRegion.View, at now: Double, animated: Bool) {
        target = view
        if animated {
            springX.retarget(view.cx, at: now)
            springY.retarget(view.cy, at: now)
            springZ.retarget(log(view.zoom), at: now)
        } else {
            springX.snap(to: view.cx, at: now)
            springY.snap(to: view.cy, at: now)
            springZ.snap(to: log(view.zoom), at: now)
        }
    }
}

extension FollowRegion {
    /// The overlap of two rectangles (zero size when they do not meet).
    public static func intersect(_ a: PixelRect, _ b: PixelRect) -> PixelRect {
        let x0 = max(a.x, b.x)
        let y0 = max(a.y, b.y)
        let x1 = min(a.x + a.w, b.x + b.w)
        let y1 = min(a.y + a.h, b.y + b.h)
        return PixelRect(x: x0, y: y0, w: max(x1 - x0, 0), h: max(y1 - y0, 0))
    }

    /// Pushes every edge of `r` that lies on a canvas edge outwards by `margin`, so the edge margin of FP4 applies only
    /// to edges the camera can still move past (ink touching the page edge of a full-width view is not "leaving").
    public static func expandToCanvasEdges(_ r: PixelRect, canvas: PixelRect, margin: Double) -> PixelRect {
        let eps = 1e-6
        var x0 = r.x
        var y0 = r.y
        var x1 = r.x + r.w
        var y1 = r.y + r.h
        if x0 <= canvas.x + eps { x0 -= margin }
        if y0 <= canvas.y + eps { y0 -= margin }
        if x1 >= canvas.x + canvas.w - eps { x1 += margin }
        if y1 >= canvas.y + canvas.h - eps { y1 += margin }
        return PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }
}
