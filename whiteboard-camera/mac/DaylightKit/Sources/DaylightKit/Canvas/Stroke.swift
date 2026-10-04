import Foundation

public struct StrokeStyle: Equatable {
    public var tool: SolStream.Tool
    public var colorARGB: UInt32
    public var baseWidth: Float

    public init(tool: SolStream.Tool, colorARGB: UInt32, baseWidth: Float) {
        self.tool = tool
        self.colorARGB = colorARGB
        self.baseWidth = baseWidth
    }

    /// Pen default InkBlack 3.2; highlighter default Amber at 50 percent, 12.0 (PROTOCOL 6.3).
    public static let pen = StrokeStyle(tool: .pen, colorARGB: 0xFF11_1111, baseWidth: 3.2)
    public static let highlighter = StrokeStyle(tool: .highlighter, colorARGB: 0x80D9_7706, baseWidth: 12.0)

    /// The widest this stroke can get (pressure 1): `base * 1.45`.
    public var maxWidth: Double { return StrokeStore.width(base: Double(baseWidth), pressure: 1) }
}

/// One stroke in Mac canvas units (1200x1600, stored as x32 fixed point like the wire).
public struct Stroke {
    public let id: UUID
    public var style: StrokeStyle
    public private(set) var points: ContiguousArray<SolStream.Point>
    /// Tight bounding box of the point centres (no width).
    public private(set) var bounds: PixelRect
    public var isCommitted: Bool

    public init(id: UUID, style: StrokeStyle) {
        self.id = id
        self.style = style
        points = []
        bounds = PixelRect(x: 0, y: 0, w: 0, h: 0)
        isCommitted = false
    }

    public mutating func append(_ pts: [SolStream.Point]) {
        for p in pts {
            if points.isEmpty {
                bounds = PixelRect(x: p.x, y: p.y, w: 0, h: 0)
            } else {
                let minX = min(bounds.x, p.x)
                let minY = min(bounds.y, p.y)
                let maxX = max(bounds.x + bounds.w, p.x)
                let maxY = max(bounds.y + bounds.h, p.y)
                bounds = PixelRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
            }
            points.append(p)
        }
    }

    /// The pixels this stroke can touch: `bounds` inflated by half the maximum width plus one pixel of anti-aliasing.
    public var dirtyBounds: PixelRect {
        let inflate = style.maxWidth / 2 + 1
        return PixelRect(x: bounds.x - inflate, y: bounds.y - inflate, w: bounds.w + 2 * inflate, h: bounds.h + 2 * inflate)
    }

    /// Dot rule: a stroke with exactly one point is drawn as a filled disc of diameter `width(base, pressure)` at that
    /// point (a zero-length segment would otherwise draw nothing).
    public var isDot: Bool { return points.count == 1 }

    public var dotDiameter: Double {
        guard let p = points.first else { return 0 }
        return StrokeStore.width(base: Double(style.baseWidth), pressure: p.pressureUnit)
    }

    /// Stroke width at point `index` (SPEC 6.6): `baseWidth * (0.55 + 0.9 * pressure)`.
    public func width(at index: Int) -> Double {
        guard index >= 0, index < points.count else { return Double(style.baseWidth) }
        return StrokeStore.width(base: Double(style.baseWidth), pressure: points[index].pressureUnit)
    }
}

public struct DirtyRect: Equatable {
    public var rect: PixelRect?

    public init(rect: PixelRect? = nil) {
        self.rect = rect
    }

    public mutating func union(_ r: PixelRect) {
        guard let current = rect else {
            rect = r
            return
        }
        let minX = min(current.x, r.x)
        let minY = min(current.y, r.y)
        let maxX = max(current.x + current.w, r.x + r.w)
        let maxY = max(current.y + current.h, r.y + r.h)
        rect = PixelRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    /// The rectangle clipped to the canvas, with integer edges (floor/ceil); nil when empty.
    public func clipped(toWidth w: Int, height h: Int) -> PixelRect? {
        guard let r = rect else { return nil }
        let x0 = max(0, floor(r.x))
        let y0 = max(0, floor(r.y))
        let x1 = min(Double(w), ceil(r.x + r.w))
        let y1 = min(Double(h), ceil(r.y + r.h))
        if x1 <= x0 || y1 <= y0 { return nil }
        return PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }
}

public enum CanvasOp: Equatable {
    /// Draw the segments of stroke `strokeID` from point index `fromIndex` (the segment into it from `fromIndex - 1` included;
    /// a committed one-point stroke is a dot).
    case drawSegments(strokeID: UUID, fromIndex: Int)
    /// Draw the whole of stroke `strokeID` again (redo): the same pixels as `drawSegments` from index 0, but not new
    /// writing, so follow the pen does not count it as ink.
    case redrawSegments(strokeID: UUID)
    /// Clear the rectangle and re-stroke every stroke intersecting it.
    case redraw(DirtyRect)
    case clearAll
}
