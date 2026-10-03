import Foundation

/// The page model (strokes, undo and redo stacks). Skeleton: start, append, commit, cancel, clear; the rest lands in M3.
public struct StrokeStore {
    public private(set) var strokes: [Stroke] = []
    public private(set) var activeStrokeIDs: Set<UUID> = []
    public private(set) var pageID = UUID()
    public private(set) var pageIndex = 0
    public private(set) var lastInkAt: Double?
    public private(set) var savedAt: Double?
    public let canvasWidth: Int
    public let canvasHeight: Int
    private var redoStack: [Stroke] = []

    public init(canvasWidth: Int = SolStream.canvasWidth, canvasHeight: Int = SolStream.canvasHeight) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    public var undoDepth: Int { return strokes.filter { $0.isCommitted }.count }
    public var redoDepth: Int { return redoStack.count }
    public var isDirty: Bool {
        guard let ink = lastInkAt else { return false }
        guard let saved = savedAt else { return true }
        return ink > saved
    }

    public mutating func start(_ s: StrokeStart) -> CanvasOp? {
        guard s.engages else { return nil }
        var stroke = Stroke(id: s.id, style: StrokeStyle(tool: s.tool, colorARGB: s.colorARGB, baseWidth: s.baseWidth))
        stroke.isCommitted = false
        strokes.append(stroke)
        activeStrokeIDs.insert(s.id)
        redoStack.removeAll()
        return nil
    }

    public mutating func append(id: UUID, points: [SolStream.Point], now: Double) -> CanvasOp? {
        guard let index = strokes.firstIndex(where: { $0.id == id }), activeStrokeIDs.contains(id) else { return nil }
        let from = strokes[index].points.count
        strokes[index].append(points)
        lastInkAt = now
        return .drawSegments(strokeID: id, fromIndex: from)
    }

    public mutating func commit(id: UUID, pointCount: UInt32) -> CanvasOp? {
        guard let index = strokes.firstIndex(where: { $0.id == id }) else { return nil }
        strokes[index].isCommitted = true
        activeStrokeIDs.remove(id)
        return nil
    }

    public mutating func cancel(id: UUID) -> CanvasOp? {
        guard let index = strokes.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = strokes.remove(at: index)
        activeStrokeIDs.remove(id)
        return .redraw(DirtyRect(rect: removed.bounds))
    }

    public mutating func clear() -> CanvasOp {
        strokes.removeAll()
        redoStack.removeAll()
        activeStrokeIDs.removeAll()
        return .clearAll
    }

    public mutating func markSaved(at now: Double) {
        savedAt = now
    }

    public static func width(base: Double, pressure: Double) -> Double {
        return base * (0.55 + 0.9 * pressure)
    }
}
