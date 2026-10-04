import Foundation

/// The page model: strokes in Mac canvas units (1200x1600), the undo and redo stacks, the dirty stamp (SPEC 12).
/// A pure value; the app keeps one instance on ink.queue. Every mutation returns the `CanvasOp` the rasterizer applies.
///
/// Undo and redo are stroke based (PROTOCOL 6.7): `undoDepth` is the number of committed strokes on the page,
/// `redoDepth` the number undone and still redoable; a newly committed stroke discards the redo stack. Erasing removes
/// strokes for good (not undoable in v1).
public struct StrokeStore {
    public private(set) var strokes: [Stroke] = []
    public private(set) var activeStrokeIDs: Set<UUID> = []
    public private(set) var pageID = UUID()
    /// 0-based page index (PROTOCOL 6.11); the file name and the JSON `page.index` are 1-based.
    public private(set) var pageIndex = 0
    /// Client canvas size declared by the last PAGE_CHANGE (1200x1600 unless a 4:3 page was requested).
    public private(set) var pageWidth: Double
    public private(set) var pageHeight: Double
    public private(set) var lastInkAt: Double?
    public private(set) var savedAt: Double?
    public let canvasWidth: Int
    public let canvasHeight: Int

    private var redoStack: [Stroke] = []
    /// Committed stroke ids in commit order (the undo order).
    private var commitOrder: [UUID] = []
    /// Per open stroke: the scale from the client's canvas units to ours (1200 / canvas_width, 1600 / canvas_height).
    private var scales: [UUID: (Double, Double)] = [:]
    /// Open eraser-tool strokes: tracked for lift bookkeeping, never drawn or stored.
    private var eraserIDs: Set<UUID> = []

    public init(canvasWidth: Int = SolStream.canvasWidth, canvasHeight: Int = SolStream.canvasHeight) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        pageWidth = Double(canvasWidth)
        pageHeight = Double(canvasHeight)
    }

    // MARK: Derived state

    public var undoDepth: Int { return commitOrder.count }
    public var redoDepth: Int { return redoStack.count }
    /// Committed strokes on the page (STATE `stroke_count`).
    public var committedCount: Int { return commitOrder.count }
    /// True when at least one stroke (open or committed) has a point.
    public var hasInk: Bool { return strokes.contains { !$0.points.isEmpty } }
    /// Dirty when the page has ink newer than the last save (SPEC 12).
    public var isDirty: Bool {
        guard hasInk, let ink = lastInkAt else { return false }
        guard let saved = savedAt else { return true }
        return ink > saved
    }
    public var pageAspect: Double { return pageHeight > 0 ? pageWidth / pageHeight : 0.75 }

    public func stroke(id: UUID) -> Stroke? {
        guard let i = strokes.firstIndex(where: { $0.id == id }) else { return nil }
        return strokes[i]
    }

    // MARK: Stroke lifecycle

    /// Opens a stroke. `scale` converts the client's canvas units to ours (1 when the client declared 1200x1600).
    /// Returns nil: nothing is drawn until the first chunk. A STROKE_START that does not engage (finger, palm, hover,
    /// pressure 0) is dropped together with its chunks; an eraser-tool start is tracked but never drawn.
    @discardableResult
    public mutating func start(_ s: StrokeStart, scale: (Double, Double) = (1, 1)) -> CanvasOp? {
        guard s.engages else { return nil }
        if s.tool == .eraser {
            eraserIDs.insert(s.id)
            activeStrokeIDs.insert(s.id)
            return nil
        }
        if strokes.contains(where: { $0.id == s.id }) { return nil }
        let stroke = Stroke(id: s.id, style: StrokeStyle(tool: s.tool, colorARGB: s.colorARGB, baseWidth: s.baseWidth))
        strokes.append(stroke)
        activeStrokeIDs.insert(s.id)
        scales[s.id] = scale
        return nil
    }

    /// Appends points (client units, scaled) to an open stroke and returns the segments to draw.
    public mutating func append(id: UUID, points: [SolStream.Point], now: Double) -> CanvasOp? {
        guard activeStrokeIDs.contains(id), !eraserIDs.contains(id), !points.isEmpty else { return nil }
        guard let index = strokes.firstIndex(where: { $0.id == id }) else { return nil }
        let scale = scales[id] ?? (1, 1)
        let scaled: [SolStream.Point]
        if scale.0 == 1 && scale.1 == 1 {
            scaled = points
        } else {
            scaled = points.map { p in
                SolStream.Point(x32: StrokeStore.scaleX32(p.x32, scale.0), y32: StrokeStore.scaleX32(p.y32, scale.1), pressure: p.pressure, deltaMs: p.deltaMs)
            }
        }
        let from = strokes[index].points.count
        strokes[index].append(scaled)
        lastInkAt = now
        return .drawSegments(strokeID: id, fromIndex: from)
    }

    static func scaleX32(_ v: Int32, _ s: Double) -> Int32 {
        let scaled = (Double(v) * s).rounded()
        if scaled >= Double(Int32.max) { return Int32.max }
        if scaled <= Double(Int32.min) { return Int32.min }
        return Int32(scaled)
    }

    /// Closes a stroke. `pointCount` is informational (a mismatch is the caller's log line). A committed stroke with
    /// one point is a dot and asks for a draw; an empty stroke is dropped.
    @discardableResult
    public mutating func commit(id: UUID, pointCount: UInt32) -> CanvasOp? {
        if eraserIDs.remove(id) != nil {
            activeStrokeIDs.remove(id)
            return nil
        }
        guard let index = strokes.firstIndex(where: { $0.id == id }) else { return nil }
        activeStrokeIDs.remove(id)
        scales[id] = nil
        if strokes[index].isCommitted { return nil }
        if strokes[index].points.isEmpty {
            strokes.remove(at: index)
            return nil
        }
        strokes[index].isCommitted = true
        commitOrder.append(id)
        redoStack.removeAll()
        return strokes[index].isDot ? .drawSegments(strokeID: id, fromIndex: 0) : nil
    }

    /// Commits every open stroke in `ids` as it stands (client disconnect, ARCHITECTURE 4).
    public mutating func commitAll(ids: Set<UUID>) -> [CanvasOp] {
        var ops: [CanvasOp] = []
        for id in ids where activeStrokeIDs.contains(id) {
            let count = UInt32(truncatingIfNeeded: stroke(id: id)?.points.count ?? 0)
            if let op = commit(id: id, pointCount: count) { ops.append(op) }
        }
        return ops
    }

    /// Removes an open (or committed) stroke; the returned dirty rectangle is redrawn.
    public mutating func cancel(id: UUID) -> CanvasOp? {
        if eraserIDs.remove(id) != nil {
            activeStrokeIDs.remove(id)
            return nil
        }
        guard let index = strokes.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = strokes.remove(at: index)
        activeStrokeIDs.remove(id)
        scales[id] = nil
        if let i = commitOrder.firstIndex(of: id) { commitOrder.remove(at: i) }
        if removed.points.isEmpty { return nil }
        return .redraw(DirtyRect(rect: removed.dirtyBounds))
    }

    /// Eraser hit test (PROTOCOL 6.8): removes every committed stroke within `radius + width / 2` of the segment.
    /// The id list is a hint only; the Mac's own test decides. Returns the rectangle to redraw, nil when nothing was hit.
    public mutating func erase(x1: Float, y1: Float, x2: Float, y2: Float, radius: Float, hint: [UUID], now: Double? = nil) -> CanvasOp? {
        let a = (Double(x1), Double(y1))
        let b = (Double(x2), Double(y2))
        var dirty = DirtyRect()
        var removed = 0
        var i = 0
        while i < strokes.count {
            let s = strokes[i]
            if s.isCommitted && Geometry.strokeHit(s, segment: a, b: b, radius: Double(radius)) {
                dirty.union(s.dirtyBounds)
                if let k = commitOrder.firstIndex(of: s.id) { commitOrder.remove(at: k) }
                strokes.remove(at: i)
                removed += 1
            } else {
                i += 1
            }
        }
        if removed == 0 { return nil }
        if let now = now { lastInkAt = now }
        return .redraw(dirty)
    }

    /// Undoes the last committed stroke (open strokes are untouched).
    public mutating func undo(now: Double? = nil) -> CanvasOp? {
        guard let id = commitOrder.popLast(), let index = strokes.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = strokes.remove(at: index)
        redoStack.append(removed)
        if let now = now { lastInkAt = now }
        return .redraw(DirtyRect(rect: removed.dirtyBounds))
    }

    /// Re-applies the last undone stroke; the whole stroke is drawn again (`redrawSegments`: a redraw, not writing).
    public mutating func redo(now: Double? = nil) -> CanvasOp? {
        guard let stroke = redoStack.popLast() else { return nil }
        strokes.append(stroke)
        commitOrder.append(stroke.id)
        if let now = now { lastInkAt = now }
        return .redrawSegments(strokeID: stroke.id)
    }

    /// Clears both layers and the undo stack; the page keeps its id and index (SPEC section 7, Clear).
    public mutating func clear() -> CanvasOp {
        strokes.removeAll()
        redoStack.removeAll()
        commitOrder.removeAll()
        activeStrokeIDs.removeAll()
        eraserIDs.removeAll()
        scales.removeAll()
        return .clearAll
    }

    /// Starts a new page (PAGE_CHANGE): the caller saves the old page first. The dirty stamp resets.
    public mutating func newPage(id: UUID, index: Int, width: Double, height: Double) -> CanvasOp {
        _ = clear()
        pageID = id
        pageIndex = max(index, 0)
        if width > 0 && height > 0 {
            pageWidth = width
            pageHeight = height
        }
        lastInkAt = nil
        savedAt = nil
        return .clearAll
    }

    public mutating func markSaved(at now: Double) {
        savedAt = now
    }

    /// Stroke width per segment (SPEC 6.6): `base * (0.55 + 0.9 * pressure)`.
    public static func width(base: Double, pressure: Double) -> Double {
        return base * (0.55 + 0.9 * min(max(pressure, 0), 1))
    }

    // MARK: Document

    /// The SPEC 12 JSON model of this page: every stroke with at least one point, in list order, as it stands.
    public func document(sessionStart: Date, savedAt: Date, reason: SaveReason, inkSource: InkSource, clientLabel: String, app: String = "Daylight") -> PageDocument {
        let records: [PageDocument.StrokeRecord] = strokes.filter { !$0.points.isEmpty }.map { s in
            PageDocument.StrokeRecord(
                id: s.id.uuidString.lowercased(),
                tool: PageDocument.toolName(s.style.tool),
                color: PageDocument.colorString(s.style.colorARGB),
                baseWidth: (Double(s.style.baseWidth) * 1000).rounded() / 1000,
                points: s.points.map { PageDocument.Point(x: $0.x, y: $0.y, pressure: $0.pressureUnit, tMs: Int($0.deltaMs)) })
        }
        return PageDocument(
            app: app,
            canvas: PageDocument.Canvas(width: canvasWidth, height: canvasHeight, dpi: 200, units: "canvas"),
            session: PageDocument.Session(
                started: PageDocument.isoString(sessionStart),
                saved: PageDocument.isoString(savedAt),
                reason: reason,
                inkSource: inkSource.jsonName,
                clientLabel: clientLabel),
            page: PageDocument.Page(id: pageID.uuidString.lowercased(), index: pageIndex + 1),
            strokes: records)
    }
}
