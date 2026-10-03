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
}

public struct Stroke {
    public let id: UUID
    public var style: StrokeStyle
    public private(set) var points: ContiguousArray<SolStream.Point>
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
}

public enum CanvasOp: Equatable {
    case drawSegments(strokeID: UUID, fromIndex: Int)
    case redraw(DirtyRect)
    case clearAll
}
