import CoreGraphics
import DaylightKit
import Foundation
import IOSurface
import QuartzCore

/// Draws `CanvasOp`s from the stroke model into the two canvas IOSurfaces with CoreGraphics (ARCHITECTURE 4):
/// one `IOSurfaceLock` per op, a cached `CGContext` per layer (`byteOrder32Little | premultipliedFirst`, y-flipped CTM
/// so canvas coordinates are y-down), per-segment widths `base * (0.55 + 0.9 * pressure)` with round caps and joins,
/// never thinner than the camera line weight (`CameraLineWeight`, D14): these surfaces feed only the live outputs, the
/// PNG export renders the store at the true widths. Runs on ink.queue only.
final class InkRasterizer {
    struct Stats {
        var locks: UInt64 = 0
        var segments: UInt64 = 0
        var redrawPixels: UInt64 = 0
    }

    let surfaces: CanvasSurfaces
    private(set) var stats = Stats()
    private var inkContext: CGContext?
    private var highlightContext: CGContext?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    init(surfaces: CanvasSurfaces) {
        self.surfaces = surfaces
    }

    // MARK: Ops

    func apply(_ op: CanvasOp, store: StrokeStore) {
        switch op {
        case let .drawSegments(strokeID, fromIndex):
            guard let stroke = store.stroke(id: strokeID), stroke.style.tool != .eraser else { return }
            drawSegments(of: stroke, fromIndex: fromIndex)
        case let .redraw(dirty):
            guard let rect = dirty.clipped(toWidth: surfaces.width, height: surfaces.height) else { return }
            redraw(rect: rect, store: store)
        case .clearAll:
            clearAll()
            surfaces.activity.noteCleared()
        }
    }

    /// LASER_POINT (PROTOCOL 6.9): a trail sample for the camera board only. It never touches the canvas surfaces or
    /// the store, so it is never saved, undone or erased.
    func laser(x: Double, y: Double, intensity: Double, decay: Double, now: Double = CACurrentMediaTime()) {
        let w = Double(surfaces.width), h = Double(surfaces.height)
        surfaces.laser.withLock { $0.add(x: x, y: y, intensity: intensity, decay: decay, now: now, canvasWidth: w, canvasHeight: h) }
    }

    func clearAll() {
        let full = CGRect(x: 0, y: 0, width: surfaces.width, height: surfaces.height)
        withLayer(.pen) { ctx in ctx.clear(full) }
        withLayer(.highlighter) { ctx in ctx.clear(full) }
    }

    // MARK: Drawing

    private func drawSegments(of stroke: Stroke, fromIndex: Int) {
        let points = stroke.points
        guard !points.isEmpty else { return }
        withLayer(stroke.style.tool) { ctx in
            setColor(ctx, stroke.style.colorARGB)
            if points.count == 1 {
                if stroke.isCommitted {
                    fillDot(ctx, stroke)
                    noteActivity(points[0...0])
                }
                return
            }
            let start = max(fromIndex, 1)
            if start >= points.count { return }
            noteActivity(points[(start - 1)...])
            for i in start..<points.count {
                strokeSegment(ctx, from: points[i - 1], to: points[i], width: InkRasterizer.cameraWidth(stroke, at: i, canvasHeight: surfaces.height))
                stats.segments += 1
            }
        }
    }

    private func redraw(rect dirty: PixelRect, store: StrokeStore) {
        // A clamped line can reach past the true-width dirty bounds: grow the cleared area and the hit test alike.
        let margin = CameraLineWeight.redrawMargin(canvasHeight: Double(surfaces.height))
        let grown = PixelRect(x: dirty.x - margin, y: dirty.y - margin, w: dirty.w + 2 * margin, h: dirty.h + 2 * margin)
        let rect = DirtyRect(rect: grown).clipped(toWidth: surfaces.width, height: surfaces.height) ?? dirty
        let cgRect = CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
        stats.redrawPixels += UInt64(max(0, rect.w * rect.h))
        for tool in [SolStream.Tool.pen, SolStream.Tool.highlighter] {
            withLayer(tool) { ctx in
                ctx.saveGState()
                ctx.clip(to: cgRect)
                ctx.clear(cgRect)
                for stroke in store.strokes where InkRasterizer.layer(for: stroke.style.tool) == tool && !stroke.points.isEmpty {
                    let bounds = stroke.dirtyBounds
                    let strokeRect = CGRect(x: bounds.x - margin, y: bounds.y - margin, width: bounds.w + 2 * margin, height: bounds.h + 2 * margin)
                    guard strokeRect.intersects(cgRect) else { continue }
                    setColor(ctx, stroke.style.colorARGB)
                    if stroke.points.count == 1 {
                        if stroke.isCommitted { fillDot(ctx, stroke) }
                        continue
                    }
                    for i in 1..<stroke.points.count {
                        strokeSegment(ctx, from: stroke.points[i - 1], to: stroke.points[i], width: InkRasterizer.cameraWidth(stroke, at: i, canvasHeight: surfaces.height))
                        stats.segments += 1
                    }
                }
                ctx.restoreGState()
            }
        }
    }

    /// Follow the pen: the box of the points just drawn (not erase, undo or redo redraws, which are not writing).
    private func noteActivity(_ points: ArraySlice<SolStream.Point>) {
        let xs = points.map { Double($0.x) }
        let ys = points.map { Double($0.y) }
        if let box = FollowRegion.boundingBox(xs: xs, ys: ys) { surfaces.activity.noteInk(box) }
    }

    private func strokeSegment(_ ctx: CGContext, from a: SolStream.Point, to b: SolStream.Point, width: Double) {
        ctx.setLineWidth(CGFloat(width))
        ctx.move(to: CGPoint(x: a.x, y: a.y))
        ctx.addLine(to: CGPoint(x: b.x, y: b.y))
        ctx.strokePath()
    }

    private func fillDot(_ ctx: CGContext, _ stroke: Stroke) {
        guard let p = stroke.points.first else { return }
        let d = CameraLineWeight.cameraWidth(stroke.dotDiameter, tool: stroke.style.tool, canvasHeight: Double(surfaces.height))
        ctx.fillEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
    }

    private func setColor(_ ctx: CGContext, _ argb: UInt32) {
        let a = CGFloat((argb >> 24) & 0xFF) / 255
        let r = CGFloat((argb >> 16) & 0xFF) / 255
        let g = CGFloat((argb >> 8) & 0xFF) / 255
        let b = CGFloat(argb & 0xFF) / 255
        ctx.setStrokeColor(red: r, green: g, blue: b, alpha: a)
        ctx.setFillColor(red: r, green: g, blue: b, alpha: a)
    }

    /// The camera width of segment `index` (D14): the stroke's own width, raised to the tool's camera minimum.
    static func cameraWidth(_ stroke: Stroke, at index: Int, canvasHeight: Int = SolStream.canvasHeight) -> Double {
        return CameraLineWeight.cameraWidth(stroke.width(at: index), tool: stroke.style.tool, canvasHeight: Double(canvasHeight))
    }

    // MARK: Layers

    /// Pen (and anything that is not a highlighter) goes to the ink layer; the highlighter to its own layer.
    static func layer(for tool: SolStream.Tool) -> SolStream.Tool {
        return tool == .highlighter ? .highlighter : .pen
    }

    private func withLayer(_ tool: SolStream.Tool, _ body: (CGContext) -> Void) {
        let surface = InkRasterizer.layer(for: tool) == .highlighter ? surfaces.highlight : surfaces.ink
        IOSurfaceLock(surface, [], nil)
        stats.locks += 1
        if let ctx = context(for: tool, surface: surface) {
            body(ctx)
            ctx.flush()
        }
        IOSurfaceUnlock(surface, [], nil)
        surfaces.noteWrite()
    }

    private func context(for tool: SolStream.Tool, surface: IOSurfaceRef) -> CGContext? {
        let isHighlight = InkRasterizer.layer(for: tool) == .highlighter
        if isHighlight, let ctx = highlightContext { return ctx }
        if !isHighlight, let ctx = inkContext { return ctx }
        guard let ctx = CGContext(
            data: IOSurfaceGetBaseAddress(surface),
            width: surfaces.width,
            height: surfaces.height,
            bitsPerComponent: 8,
            bytesPerRow: IOSurfaceGetBytesPerRow(surface),
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        // Canvas coordinates are y-down (tablet space); CG user space is y-up: flip once.
        ctx.translateBy(x: 0, y: CGFloat(surfaces.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        if isHighlight { highlightContext = ctx } else { inkContext = ctx }
        return ctx
    }
}
