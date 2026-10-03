import CoreGraphics
import DaylightKit
import Foundation
import IOSurface

/// Draws `CanvasOp`s from the stroke model into the two canvas IOSurfaces with CoreGraphics (ARCHITECTURE 4):
/// one `IOSurfaceLock` per op, a cached `CGContext` per layer (`byteOrder32Little | premultipliedFirst`, y-flipped CTM
/// so canvas coordinates are y-down), per-segment widths `base * (0.55 + 0.9 * pressure)` with round caps and joins.
/// Runs on ink.queue only.
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
        }
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
                if stroke.isCommitted { fillDot(ctx, stroke) }
                return
            }
            let start = max(fromIndex, 1)
            if start >= points.count { return }
            for i in start..<points.count {
                strokeSegment(ctx, from: points[i - 1], to: points[i], width: stroke.width(at: i))
                stats.segments += 1
            }
        }
    }

    private func redraw(rect: PixelRect, store: StrokeStore) {
        let cgRect = CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
        stats.redrawPixels += UInt64(max(0, rect.w * rect.h))
        for tool in [SolStream.Tool.pen, SolStream.Tool.highlighter] {
            withLayer(tool) { ctx in
                ctx.saveGState()
                ctx.clip(to: cgRect)
                ctx.clear(cgRect)
                for stroke in store.strokes where InkRasterizer.layer(for: stroke.style.tool) == tool && !stroke.points.isEmpty {
                    let bounds = stroke.dirtyBounds
                    let strokeRect = CGRect(x: bounds.x, y: bounds.y, width: bounds.w, height: bounds.h)
                    guard strokeRect.intersects(cgRect) else { continue }
                    setColor(ctx, stroke.style.colorARGB)
                    if stroke.points.count == 1 {
                        if stroke.isCommitted { fillDot(ctx, stroke) }
                        continue
                    }
                    for i in 1..<stroke.points.count {
                        strokeSegment(ctx, from: stroke.points[i - 1], to: stroke.points[i], width: stroke.width(at: i))
                        stats.segments += 1
                    }
                }
                ctx.restoreGState()
            }
        }
    }

    private func strokeSegment(_ ctx: CGContext, from a: SolStream.Point, to b: SolStream.Point, width: Double) {
        ctx.setLineWidth(CGFloat(width))
        ctx.move(to: CGPoint(x: a.x, y: a.y))
        ctx.addLine(to: CGPoint(x: b.x, y: b.y))
        ctx.strokePath()
    }

    private func fillDot(_ ctx: CGContext, _ stroke: Stroke) {
        guard let p = stroke.points.first else { return }
        let d = stroke.dotDiameter
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
