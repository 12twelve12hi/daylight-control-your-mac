import Foundation
import XCTest
import DaylightKit

/// Acceptance A6: start/append/commit, canvas units, cancel, undo/redo depths, erase precision, dirty rects, dot rule,
/// JSON round trip of SPEC section 12.
final class StrokeStoreTests: XCTestCase {
    private func start(_ id: UUID = UUID(), tool: SolStream.Tool = .pen, pressure: Float = 0.5, pointer: SolStream.PointerType = .stylus, phase: SolStream.Phase = .contact) -> StrokeStart {
        let style: StrokeStyle = tool == .highlighter ? .highlighter : .pen
        return StrokeStart(id: id, tool: tool, colorARGB: style.colorARGB, baseWidth: style.baseWidth, pointer: pointer, phase: phase, pressure: pressure)
    }

    private func points(_ xs: [(Double, Double, Double, Int)]) -> [SolStream.Point] {
        return xs.map { SolStream.Point(x: $0.0, y: $0.1, pressure: $0.2, deltaMs: $0.3) }
    }

    /// A committed two-point stroke from (x0, y0) to (x1, y1), base width 3.2.
    @discardableResult
    private func line(_ store: inout StrokeStore, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, pressure: Double = 1, now: Double = 1) -> UUID {
        let id = UUID()
        store.start(start(id), scale: (1, 1))
        _ = store.append(id: id, points: points([(x0, y0, pressure, 0), (x1, y1, pressure, 10)]), now: now)
        store.commit(id: id, pointCount: 2)
        return id
    }

    func testStartAppendCommitProducesOneStrokeInCanvasUnits() {
        var store = StrokeStore()
        let id = UUID()
        XCTAssertNil(store.start(start(id), scale: (1, 1)), "nothing to draw before the first chunk")
        XCTAssertEqual(store.activeStrokeIDs, [id])
        XCTAssertEqual(store.undoDepth, 0, "an open stroke is not undoable yet")
        let op = store.append(id: id, points: [SolStream.Point(x32: 336, y32: -104, pressure: 186, deltaMs: 0), SolStream.Point(x32: 3200, y32: 6408, pressure: 51, deltaMs: 8)], now: 5)
        XCTAssertEqual(op, .drawSegments(strokeID: id, fromIndex: 0))
        let op2 = store.append(id: id, points: [SolStream.Point(x32: 38399, y32: 51168, pressure: 255, deltaMs: 65535)], now: 6)
        XCTAssertEqual(op2, .drawSegments(strokeID: id, fromIndex: 2))
        XCTAssertNil(store.commit(id: id, pointCount: 3))
        XCTAssertEqual(store.strokes.count, 1)
        let s = store.strokes[0]
        XCTAssertEqual(s.points.count, 3)
        XCTAssertEqual(s.points[0].x, 10.5, "x32 / 32")
        XCTAssertEqual(s.points[0].y, -3.25)
        XCTAssertEqual(s.points[1].x, 100.0)
        XCTAssertEqual(s.points[1].y, 200.25)
        XCTAssertEqual(s.points[2].x, 1199.96875)
        XCTAssertTrue(s.isCommitted)
        XCTAssertTrue(store.activeStrokeIDs.isEmpty)
        XCTAssertEqual(store.undoDepth, 1)
        XCTAssertEqual(store.redoDepth, 0)
        XCTAssertEqual(store.committedCount, 1)
        XCTAssertEqual(store.lastInkAt, 6)
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(s.bounds.x, 10.5)
        XCTAssertEqual(s.bounds.y, -3.25)
        XCTAssertEqual(s.bounds.w, 1199.96875 - 10.5, accuracy: 1e-9)
        XCTAssertEqual(s.bounds.h, 1599.0 + 3.25, accuracy: 1e-9)
    }

    func testStartScalesAForeignCanvas() {
        var store = StrokeStore()
        let id = UUID()
        store.start(start(id), scale: (1200.0 / 600.0, 1600.0 / 800.0))
        _ = store.append(id: id, points: points([(300, 400, 0.5, 0)]), now: 1)
        XCTAssertEqual(store.strokes[0].points[0].x, 600)
        XCTAssertEqual(store.strokes[0].points[0].y, 800)
    }

    func testNonEngagingStartIsDroppedWithItsChunks() {
        var store = StrokeStore()
        let finger = UUID()
        XCTAssertNil(store.start(start(finger, pointer: .finger)))
        XCTAssertNil(store.append(id: finger, points: points([(1, 1, 1, 0)]), now: 1))
        XCTAssertNil(store.commit(id: finger, pointCount: 1))
        let hover = UUID()
        XCTAssertNil(store.start(start(hover, phase: .hover)))
        let zero = UUID()
        XCTAssertNil(store.start(start(zero, pressure: 0)))
        XCTAssertTrue(store.strokes.isEmpty)
        XCTAssertTrue(store.activeStrokeIDs.isEmpty)
        XCTAssertFalse(store.isDirty)
        XCTAssertNil(store.append(id: UUID(), points: points([(1, 1, 1, 0)]), now: 1), "unknown stroke id")
    }

    func testEraserToolStartIsTrackedButNeverDrawn() {
        var store = StrokeStore()
        let id = UUID()
        XCTAssertNil(store.start(start(id, tool: .eraser)))
        XCTAssertEqual(store.activeStrokeIDs, [id])
        XCTAssertNil(store.append(id: id, points: points([(1, 1, 1, 0)]), now: 1))
        XCTAssertNil(store.commit(id: id, pointCount: 1))
        XCTAssertTrue(store.strokes.isEmpty)
        XCTAssertTrue(store.activeStrokeIDs.isEmpty)
    }

    func testCancelRemovesTheStrokeAndReturnsItsDirtyRect() {
        var store = StrokeStore()
        let id = UUID()
        store.start(start(id))
        _ = store.append(id: id, points: points([(100, 100, 1, 0), (200, 150, 1, 10)]), now: 1)
        let op = store.cancel(id: id)
        guard case let .redraw(dirty)? = op, let r = dirty.rect else { return XCTFail("expected a redraw, got \(String(describing: op))") }
        let inflate = 3.2 * 1.45 / 2 + 1   // baseWidth travels as a Float, so compare at 1e-6
        XCTAssertEqual(r.x, 100 - inflate, accuracy: 1e-6)
        XCTAssertEqual(r.y, 100 - inflate, accuracy: 1e-6)
        XCTAssertEqual(r.w, 100 + 2 * inflate, accuracy: 1e-6)
        XCTAssertEqual(r.h, 50 + 2 * inflate, accuracy: 1e-6)
        XCTAssertTrue(store.strokes.isEmpty)
        XCTAssertTrue(store.activeStrokeIDs.isEmpty)
        XCTAssertNil(store.cancel(id: id), "already gone")
        let empty = UUID()
        store.start(start(empty))
        XCTAssertNil(store.cancel(id: empty), "nothing drawn, nothing to redraw")
    }

    func testUndoRedoDepths() {
        var store = StrokeStore()
        let a = line(&store, 0, 0, 10, 10)
        let b = line(&store, 20, 20, 30, 30)
        XCTAssertEqual(store.undoDepth, 2)
        XCTAssertEqual(store.redoDepth, 0)
        guard case .redraw? = store.undo(now: 2) else { return XCTFail("undo redraws") }
        XCTAssertEqual(store.undoDepth, 1)
        XCTAssertEqual(store.redoDepth, 1)
        XCTAssertEqual(store.strokes.map { $0.id }, [a], "the last committed stroke goes first")
        XCTAssertEqual(store.redo(now: 3), .drawSegments(strokeID: b, fromIndex: 0))
        XCTAssertEqual(store.undoDepth, 2)
        XCTAssertEqual(store.redoDepth, 0)
        XCTAssertNil(store.redo(), "nothing left to redo")
        _ = store.undo()
        _ = store.undo()
        XCTAssertEqual(store.undoDepth, 0)
        XCTAssertEqual(store.redoDepth, 2)
        XCTAssertNil(store.undo(), "nothing left to undo")
        XCTAssertFalse(store.isDirty, "an empty page is never dirty")
        line(&store, 50, 50, 60, 60)
        XCTAssertEqual(store.redoDepth, 0, "a new stroke discards the redo stack")
        XCTAssertEqual(store.undoDepth, 1)
    }

    func testUndoWhileAStrokeIsOpenAppliesToTheLastCommittedStroke() {
        var store = StrokeStore()
        let a = line(&store, 0, 0, 10, 10)
        let open = UUID()
        store.start(start(open))
        _ = store.append(id: open, points: points([(5, 5, 1, 0)]), now: 2)
        _ = store.undo()
        XCTAssertEqual(store.strokes.map { $0.id }, [open])
        XCTAssertNotEqual(store.strokes[0].id, a)
        XCTAssertEqual(store.activeStrokeIDs, [open])
    }

    func testEraseHitTestPrecisionAtTheRadiusEdge() {
        // Stroke from (100, 100) to (200, 100), base 3.2 at pressure 1: width 4.64, half width 2.32.
        // Eraser segment 30 px below it: hit iff radius + 2.32 >= 30, i.e. radius >= 27.68.
        var store = StrokeStore()
        line(&store, 100, 100, 200, 100)
        XCTAssertNil(store.erase(x1: 100, y1: 130, x2: 200, y2: 130, radius: 27.67, hint: []), "just outside")
        XCTAssertEqual(store.undoDepth, 1)
        let op = store.erase(x1: 100, y1: 130, x2: 200, y2: 130, radius: 27.69, hint: [], now: 9)
        guard case .redraw? = op else { return XCTFail("just inside erases") }
        XCTAssertEqual(store.undoDepth, 0)
        XCTAssertTrue(store.strokes.isEmpty)
        XCTAssertEqual(store.lastInkAt, 9)
    }

    func testEraseHintIsNotAuthoritative() {
        var store = StrokeStore()
        let a = line(&store, 0, 0, 10, 0)
        let b = line(&store, 500, 500, 600, 500)
        // The hint names b, the geometry hits a: a is erased, b stays.
        _ = store.erase(x1: 0, y1: 5, x2: 10, y2: 5, radius: 5, hint: [b])
        XCTAssertEqual(store.strokes.map { $0.id }, [b])
        XCTAssertNotEqual(store.strokes[0].id, a)
        // Crossing segments hit at any radius.
        _ = store.erase(x1: 550, y1: 400, x2: 550, y2: 600, radius: 0.001, hint: [])
        XCTAssertTrue(store.strokes.isEmpty)
    }

    func testEraseSkipsOpenStrokesAndReturnsUnionOfDirtyRects() {
        var store = StrokeStore()
        line(&store, 0, 0, 10, 0)
        line(&store, 100, 0, 110, 0)
        let open = UUID()
        store.start(start(open))
        _ = store.append(id: open, points: points([(50, 0, 1, 0), (60, 0, 1, 5)]), now: 1)
        let op = store.erase(x1: -10, y1: 0, x2: 200, y2: 0, radius: 1, hint: [])
        guard case let .redraw(dirty)? = op, let r = dirty.rect else { return XCTFail("redraw expected") }
        XCTAssertEqual(store.strokes.map { $0.id }, [open], "the open stroke survives")
        let inflate = 3.2 * 1.45 / 2 + 1
        XCTAssertEqual(r.x, -inflate, accuracy: 1e-6)
        XCTAssertEqual(r.x + r.w, 110 + inflate, accuracy: 1e-6)
    }

    func testDirtyRectsUnionAndClip() {
        var d = DirtyRect()
        XCTAssertNil(d.rect)
        XCTAssertNil(d.clipped(toWidth: 1200, height: 1600))
        d.union(PixelRect(x: -5, y: 10.25, w: 20, h: 20))
        d.union(PixelRect(x: 100, y: 100, w: 10.5, h: 10))
        XCTAssertEqual(d.rect, PixelRect(x: -5, y: 10.25, w: 115.5, h: 99.75))
        let c = d.clipped(toWidth: 1200, height: 1600)!
        XCTAssertEqual(c.x, 0)
        XCTAssertEqual(c.y, 10)
        XCTAssertEqual(c.x + c.w, 111)
        XCTAssertEqual(c.y + c.h, 110)
        XCTAssertNil(DirtyRect(rect: PixelRect(x: 1300, y: 0, w: 10, h: 10)).clipped(toWidth: 1200, height: 1600), "entirely outside")
    }

    func testDotRuleForOnePointStrokes() {
        var store = StrokeStore()
        let id = UUID()
        store.start(start(id))
        XCTAssertEqual(store.append(id: id, points: points([(400, 400, 0.5, 0)]), now: 1), .drawSegments(strokeID: id, fromIndex: 0))
        XCTAssertEqual(store.commit(id: id, pointCount: 1), .drawSegments(strokeID: id, fromIndex: 0), "a committed dot asks for a draw")
        let s = store.strokes[0]
        XCTAssertTrue(s.isDot)
        XCTAssertEqual(s.dotDiameter, StrokeStore.width(base: 3.2, pressure: Double(128) / 255), accuracy: 1e-6)
        XCTAssertEqual(s.dirtyBounds.w, 2 * (3.2 * 1.45 / 2 + 1), accuracy: 1e-6)
        // Width rule: base * (0.55 + 0.9 * pressure).
        XCTAssertEqual(StrokeStore.width(base: 3.2, pressure: 0), 1.76, accuracy: 1e-9)
        XCTAssertEqual(StrokeStore.width(base: 3.2, pressure: 1), 4.64, accuracy: 1e-9)
        XCTAssertEqual(StrokeStore.width(base: 12, pressure: 0.5), 12, accuracy: 1e-9)
        XCTAssertEqual(StrokeStore.width(base: 3.2, pressure: 7), 4.64, accuracy: 1e-9, "pressure is clamped")
        // An empty committed stroke is dropped.
        let empty = UUID()
        store.start(start(empty))
        XCTAssertNil(store.commit(id: empty, pointCount: 0))
        XCTAssertEqual(store.strokes.count, 1)
    }

    func testCommitAllCommitsOpenStrokesAsTheyStand() {
        var store = StrokeStore()
        let a = UUID()
        let b = UUID()
        store.start(start(a))
        store.start(start(b))
        _ = store.append(id: a, points: points([(1, 1, 1, 0), (2, 2, 1, 1)]), now: 1)
        _ = store.append(id: b, points: points([(3, 3, 1, 0)]), now: 1)
        let ops = store.commitAll(ids: [a, b, UUID()])
        XCTAssertEqual(ops, [.drawSegments(strokeID: b, fromIndex: 0)], "only the dot asks for a draw")
        XCTAssertTrue(store.activeStrokeIDs.isEmpty)
        XCTAssertEqual(store.undoDepth, 2)
    }

    func testClearAndNewPage() {
        var store = StrokeStore()
        line(&store, 0, 0, 10, 10, now: 1)
        let page = store.pageID
        XCTAssertEqual(store.clear(), .clearAll)
        XCTAssertTrue(store.strokes.isEmpty)
        XCTAssertEqual(store.undoDepth, 0)
        XCTAssertEqual(store.redoDepth, 0)
        XCTAssertEqual(store.pageID, page, "clear keeps the page")
        XCTAssertFalse(store.isDirty)
        line(&store, 0, 0, 10, 10, now: 2)
        let next = UUID()
        XCTAssertEqual(store.newPage(id: next, index: 1, width: 1200, height: 1600), .clearAll)
        XCTAssertEqual(store.pageID, next)
        XCTAssertEqual(store.pageIndex, 1)
        XCTAssertNil(store.lastInkAt)
        XCTAssertNil(store.savedAt)
        XCTAssertFalse(store.isDirty)
        _ = store.newPage(id: UUID(), index: 2, width: 1600, height: 1200)
        XCTAssertEqual(store.pageAspect, 4.0 / 3.0, accuracy: 1e-12)
    }

    func testDirtyAndSavedAtStamps() {
        var store = StrokeStore()
        XCTAssertFalse(store.isDirty)
        line(&store, 0, 0, 10, 10, now: 10)
        XCTAssertTrue(store.isDirty)
        store.markSaved(at: 11)
        XCTAssertFalse(store.isDirty, "saved after the last ink")
        XCTAssertEqual(store.savedAt, 11)
        line(&store, 0, 0, 10, 10, now: 12)
        XCTAssertTrue(store.isDirty)
        _ = store.undo(now: 13)
        XCTAssertTrue(store.isDirty, "undo is ink too")
        store.markSaved(at: 14)
        _ = store.undo(now: 15)
        XCTAssertFalse(store.isDirty, "no strokes left: nothing to save")
    }

    func testDocumentMatchesTheSpec12Schema() throws {
        var store = StrokeStore()
        let id = UUID(uuidString: "00010203-0405-0607-0809-0a0b0c0d0e0f")!
        store.start(start(id))
        _ = store.append(id: id, points: points([(10.5, -3.25, 0.73, 0), (100.5, 200.25, 0.2, 8)]), now: 1)
        store.commit(id: id, pointCount: 2)
        let hl = UUID()
        store.start(start(hl, tool: .highlighter))
        _ = store.append(id: hl, points: points([(1, 2, 1, 0), (3, 4, 1, 40)]), now: 2)
        store.commit(id: hl, pointCount: 2)
        let started = Date(timeIntervalSince1970: 1_791_036_309)   // 2026-10-03T14:05:09Z
        let saved = Date(timeIntervalSince1970: 1_791_037_300)     // 2026-10-03T14:21:40Z
        let doc = store.document(sessionStart: started, savedAt: saved, reason: .returned, inkSource: .web, clientLabel: "Chrome on Daylight", app: "Daylight 0.1.0 (42)")
        XCTAssertEqual(doc.schema, "daylight-whiteboard-strokes/1")
        XCTAssertEqual(doc.app, "Daylight 0.1.0 (42)")
        XCTAssertEqual(doc.canvas, PageDocument.Canvas(width: 1200, height: 1600, dpi: 200, units: "canvas"))
        XCTAssertEqual(doc.session.started, "2026-10-03T14:05:09Z")
        XCTAssertEqual(doc.session.saved, "2026-10-03T14:21:40Z")
        XCTAssertEqual(doc.session.reason, .returned)
        XCTAssertEqual(doc.session.inkSource, "web")
        XCTAssertEqual(doc.session.clientLabel, "Chrome on Daylight")
        XCTAssertEqual(doc.page.id, store.pageID.uuidString.lowercased())
        XCTAssertEqual(doc.page.index, 1, "1-based like page-01")
        XCTAssertEqual(doc.strokes.count, 2)
        XCTAssertEqual(doc.strokes[0].id, "00010203-0405-0607-0809-0a0b0c0d0e0f")
        XCTAssertEqual(doc.strokes[0].tool, "pen")
        XCTAssertEqual(doc.strokes[0].color, "#FF111111")
        XCTAssertEqual(doc.strokes[0].baseWidth, 3.2, accuracy: 1e-6)
        XCTAssertEqual(doc.strokes[0].points[0].x, 10.5)
        XCTAssertEqual(doc.strokes[0].points[0].y, -3.25)
        XCTAssertEqual(doc.strokes[0].points[0].pressure, 186.0 / 255.0, accuracy: 1e-12, "quantised pressure")
        XCTAssertEqual(doc.strokes[0].points[1].tMs, 8)
        XCTAssertEqual(doc.strokes[1].tool, "highlighter")
        XCTAssertEqual(doc.strokes[1].color, "#80D97706")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(doc)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"app\":\"Daylight 0.1.0 (42)\",\"canvas\":{\"dpi\":200,\"height\":1600,\"units\":\"canvas\",\"width\":1200},\"page\":{"), text)
        XCTAssertTrue(text.contains("\"schema\":\"daylight-whiteboard-strokes/1\""))
        XCTAssertTrue(text.contains("\"points\":[[10.5,-3.25,0.7294"), "points are [x, y, pressure, tMs] arrays: \(text)")
        XCTAssertTrue(text.contains(",0],[100.5,200.25,0.2,8]]"), "the second point and the integer tMs: \(text)")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strokeObjects = try XCTUnwrap(object["strokes"] as? [[String: Any]])
        let firstPoints = try XCTUnwrap(strokeObjects[0]["points"] as? [[Double]])
        XCTAssertEqual(firstPoints.count, 2)
        XCTAssertEqual(firstPoints[0].count, 4, "[x, y, pressure, tMs]")
        XCTAssertEqual(firstPoints[0][0], 10.5)
        XCTAssertEqual(firstPoints[0][1], -3.25)
        XCTAssertEqual(firstPoints[0][2], 186.0 / 255.0, accuracy: 1e-9)
        XCTAssertEqual(firstPoints[0][3], 0)
        XCTAssertEqual(firstPoints[1][3], 8)
        XCTAssertEqual((strokeObjects[0]["baseWidth"] as? Double) ?? 0, 3.2, accuracy: 1e-9, "baseWidth is written at three decimals, not as the Float's binary value")
        XCTAssertTrue(text.contains("\"session\":{\"clientLabel\":\"Chrome on Daylight\",\"inkSource\":\"web\",\"reason\":\"returned\",\"saved\":\"2026-10-03T14:21:40Z\",\"started\":\"2026-10-03T14:05:09Z\"}"))

        let decoded = try JSONDecoder().decode(PageDocument.self, from: data)
        XCTAssertEqual(decoded, doc, "JSON round trip")
        let strokes = decoded.strokeValues()
        XCTAssertEqual(strokes.count, 2)
        XCTAssertEqual(strokes[0].points.map { $0.x32 }, [336, 3216])
        XCTAssertEqual(strokes[0].points.map { $0.pressure }, [186, 51])
        XCTAssertEqual(strokes[1].style, .highlighter)
    }

    func testDocumentHelpers() {
        XCTAssertEqual(PageDocument.colorString(0xFF11_1111), "#FF111111")
        XCTAssertEqual(PageDocument.colorString(0x0000_00FF), "#000000FF")
        XCTAssertEqual(PageDocument.colorValue("#FF111111"), 0xFF11_1111)
        XCTAssertEqual(PageDocument.colorValue("#111111"), 0xFF11_1111)
        XCTAssertNil(PageDocument.colorValue("#12"))
        XCTAssertEqual(PageDocument.toolName(.eraser), "eraser")
        XCTAssertEqual(PageDocument.tool(named: "lasso"), .lasso)
        XCTAssertNil(PageDocument.tool(named: "crayon"))
        XCTAssertEqual(PageDocument.isoString(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00Z")
    }

    func testAnEmptyDocumentDecodesFromTheSpecExample() throws {
        let json = """
        { "schema": "daylight-whiteboard-strokes/1", "app": "Daylight 0.1.0 (1)",
          "canvas": { "width": 1200, "height": 1600, "dpi": 200, "units": "canvas" },
          "session": { "started": "2026-10-03T14:05:09Z", "saved": "2026-10-03T14:21:40Z", "reason": "returned", "inkSource": "web", "clientLabel": "Chrome on Daylight" },
          "page": { "id": "10111213-1415-1617-1819-1a1b1c1d1e1f", "index": 1 },
          "strokes": [ { "id": "00010203-0405-0607-0809-0a0b0c0d0e0f", "tool": "pen", "color": "#FF111111", "baseWidth": 3.2, "points": [ [10.5, -3.25, 0.73, 0], [100, 200.25, 0.2, 8] ] } ] }
        """
        let doc = try JSONDecoder().decode(PageDocument.self, from: Data(json.utf8))
        XCTAssertEqual(doc.strokes[0].points[1], PageDocument.Point(x: 100, y: 200.25, pressure: 0.2, tMs: 8))
        XCTAssertEqual(doc.page.index, 1)
    }
}
