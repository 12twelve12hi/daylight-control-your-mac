import DaylightKit
import IOSurface
import XCTest
@testable import Daylight

/// ARCHITECTURE 11.2: the dot lands in the right rows of IOSurface memory (y-flip verified), segments leave pixels
/// along their path, an erase redraw leaves neighbours intact, the highlighter writes only its own layer.
final class InkRasterizerTests: XCTestCase {
    private func makeStore() -> StrokeStore { return StrokeStore() }

    private func start(_ store: inout StrokeStore, id: UUID, tool: SolStream.Tool = .pen, color: UInt32 = 0xFF11_1111, width: Float = 8) {
        _ = store.start(StrokeStart(id: id, tool: tool, colorARGB: color, baseWidth: width, pointer: .stylus, phase: .contact, pressure: 0.8))
    }

    func testDotLandsAtItsCanvasCoordinatesInTheFirstRows() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let rasterizer = InkRasterizer(surfaces: surfaces)
        var store = makeStore()
        let id = UUID()
        start(&store, id: id, width: 10)
        _ = store.append(id: id, points: [SolStream.Point(x: 10.5, y: 10.5, pressure: 1.0, deltaMs: 0)], now: 1)
        let op = store.commit(id: id, pointCount: 1)
        XCTAssertEqual(op, .drawSegments(strokeID: id, fromIndex: 0), "a one-point stroke is a dot")
        rasterizer.apply(op!, store: store)
        let centre = CanvasSurfaces.pixel(surfaces.ink, x: 10, y: 10)
        XCTAssertEqual(centre.a, 0xFF)
        XCTAssertEqual(centre.b, 0x11)
        XCTAssertEqual(centre.g, 0x11)
        XCTAssertEqual(centre.r, 0x11)
        // y-flip: nothing lands near the bottom of the surface.
        XCTAssertEqual(CanvasSurfaces.pixel(surfaces.ink, x: 10, y: 1590).a, 0)
        XCTAssertEqual(CanvasSurfaces.pixel(surfaces.ink, x: 10, y: 40).a, 0)
        XCTAssertEqual(rasterizer.stats.locks, 1)
        XCTAssertEqual(CanvasSurfaces.pixel(surfaces.highlight, x: 10, y: 10).a, 0, "the dot never touches the highlight layer")
    }

    func testSegmentsAreNonZeroAlongThePathAndNowhereElse() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let rasterizer = InkRasterizer(surfaces: surfaces)
        var store = makeStore()
        let id = UUID()
        start(&store, id: id, width: 6)
        let points = [
            SolStream.Point(x: 100, y: 100, pressure: 0.5, deltaMs: 0),
            SolStream.Point(x: 300, y: 100, pressure: 0.5, deltaMs: 10),
            SolStream.Point(x: 300, y: 400, pressure: 0.9, deltaMs: 20),
        ]
        let op = store.append(id: id, points: points, now: 1)!
        rasterizer.apply(op, store: store)
        XCTAssertGreaterThan(CanvasSurfaces.pixel(surfaces.ink, x: 200, y: 100).a, 0)
        XCTAssertGreaterThan(CanvasSurfaces.pixel(surfaces.ink, x: 300, y: 250).a, 0)
        XCTAssertEqual(CanvasSurfaces.pixel(surfaces.ink, x: 200, y: 300).a, 0)
        XCTAssertEqual(CanvasSurfaces.pixel(surfaces.ink, x: 50, y: 50).a, 0)
        XCTAssertEqual(rasterizer.stats.segments, 2)
        let seedBefore = surfaces.seed
        _ = store.append(id: id, points: [SolStream.Point(x: 600, y: 400, pressure: 0.5, deltaMs: 30)], now: 2)
        rasterizer.apply(.drawSegments(strokeID: id, fromIndex: 3), store: store)
        XCTAssertGreaterThan(CanvasSurfaces.pixel(surfaces.ink, x: 450, y: 400).a, 0, "incremental append draws only the new segment")
        XCTAssertNotEqual(surfaces.seed, seedBefore, "seed changes on write")
    }

    func testWidthFollowsPressure() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let rasterizer = InkRasterizer(surfaces: surfaces)
        var store = makeStore()
        let thin = UUID(), thick = UUID()
        start(&store, id: thin, width: 10)
        start(&store, id: thick, width: 10)
        rasterizer.apply(store.append(id: thin, points: [SolStream.Point(x: 100, y: 200, pressure: 0.0, deltaMs: 0), SolStream.Point(x: 300, y: 200, pressure: 0.0, deltaMs: 5)], now: 1)!, store: store)
        rasterizer.apply(store.append(id: thick, points: [SolStream.Point(x: 100, y: 600, pressure: 1.0, deltaMs: 0), SolStream.Point(x: 300, y: 600, pressure: 1.0, deltaMs: 5)], now: 1)!, store: store)
        // width(10, 0) = 5.5 px, width(10, 1) = 14.5 px: 6 px above the centre is ink only for the thick stroke.
        XCTAssertEqual(CanvasSurfaces.pixel(surfaces.ink, x: 200, y: 194).a, 0)
        XCTAssertGreaterThan(CanvasSurfaces.pixel(surfaces.ink, x: 200, y: 594).a, 0)
        XCTAssertEqual(StrokeStore.width(base: 10, pressure: 0), 5.5, accuracy: 1e-9)
        XCTAssertEqual(StrokeStore.width(base: 10, pressure: 1), 14.5, accuracy: 1e-9)
    }

    func testEraseRedrawLeavesNeighboursIntact() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let rasterizer = InkRasterizer(surfaces: surfaces)
        var store = makeStore()
        let left = UUID(), right = UUID()
        start(&store, id: left, width: 6)
        start(&store, id: right, width: 6)
        rasterizer.apply(store.append(id: left, points: [SolStream.Point(x: 100, y: 300, pressure: 0.5, deltaMs: 0), SolStream.Point(x: 300, y: 300, pressure: 0.5, deltaMs: 5)], now: 1)!, store: store)
        _ = store.commit(id: left, pointCount: 2)
        rasterizer.apply(store.append(id: right, points: [SolStream.Point(x: 700, y: 300, pressure: 0.5, deltaMs: 0), SolStream.Point(x: 900, y: 300, pressure: 0.5, deltaMs: 5)], now: 1)!, store: store)
        _ = store.commit(id: right, pointCount: 2)
        XCTAssertGreaterThan(CanvasSurfaces.pixel(surfaces.ink, x: 200, y: 300).a, 0)
        XCTAssertGreaterThan(CanvasSurfaces.pixel(surfaces.ink, x: 800, y: 300).a, 0)
        let op = store.erase(x1: 200, y1: 290, x2: 200, y2: 310, radius: 12, hint: [], now: 2)
        XCTAssertNotNil(op)
        rasterizer.apply(op!, store: store)
        XCTAssertEqual(CanvasSurfaces.pixel(surfaces.ink, x: 200, y: 300).a, 0, "erased stroke is gone")
        XCTAssertGreaterThan(CanvasSurfaces.pixel(surfaces.ink, x: 800, y: 300).a, 0, "the neighbour survives")
        XCTAssertEqual(store.committedCount, 1)
        XCTAssertGreaterThan(rasterizer.stats.redrawPixels, 0)
    }

    func testUndoClearsAndRedoRestores() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let rasterizer = InkRasterizer(surfaces: surfaces)
        var store = makeStore()
        let id = UUID()
        start(&store, id: id, width: 6)
        rasterizer.apply(store.append(id: id, points: [SolStream.Point(x: 100, y: 900, pressure: 0.5, deltaMs: 0), SolStream.Point(x: 500, y: 900, pressure: 0.5, deltaMs: 5)], now: 1)!, store: store)
        _ = store.commit(id: id, pointCount: 2)
        rasterizer.apply(store.undo(now: 2)!, store: store)
        XCTAssertEqual(CanvasSurfaces.pixel(surfaces.ink, x: 300, y: 900).a, 0)
        XCTAssertEqual(store.undoDepth, 0)
        XCTAssertEqual(store.redoDepth, 1)
        rasterizer.apply(store.redo(now: 3)!, store: store)
        XCTAssertGreaterThan(CanvasSurfaces.pixel(surfaces.ink, x: 300, y: 900).a, 0)
    }

    func testHighlighterWritesOnlyTheHighlightLayerAndClearAllEmptiesBoth() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let rasterizer = InkRasterizer(surfaces: surfaces)
        var store = makeStore()
        let hl = UUID()
        start(&store, id: hl, tool: .highlighter, color: 0x80D9_7706, width: 12)
        rasterizer.apply(store.append(id: hl, points: [SolStream.Point(x: 100, y: 1200, pressure: 0.5, deltaMs: 0), SolStream.Point(x: 400, y: 1200, pressure: 0.5, deltaMs: 5)], now: 1)!, store: store)
        let highlight = CanvasSurfaces.pixel(surfaces.highlight, x: 250, y: 1200)
        XCTAssertGreaterThan(highlight.a, 0)
        XCTAssertLessThan(highlight.a, 0xFF, "50 percent amber stays translucent")
        XCTAssertEqual(CanvasSurfaces.pixel(surfaces.ink, x: 250, y: 1200).a, 0)
        rasterizer.apply(store.clear(), store: store)
        XCTAssertEqual(CanvasSurfaces.pixel(surfaces.highlight, x: 250, y: 1200).a, 0)
    }

    func testEraserToolStrokesAreNeverDrawn() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let rasterizer = InkRasterizer(surfaces: surfaces)
        var store = makeStore()
        let id = UUID()
        start(&store, id: id, tool: .eraser, width: 12)
        XCTAssertNil(store.append(id: id, points: [SolStream.Point(x: 100, y: 100, pressure: 0.5, deltaMs: 0)], now: 1))
        rasterizer.apply(.drawSegments(strokeID: id, fromIndex: 0), store: store)
        XCTAssertEqual(CanvasSurfaces.pixel(surfaces.ink, x: 100, y: 100).a, 0)
    }

    // MARK: Camera line weight (D14)

    /// Integrated alpha across a horizontal line in column `x`: the line's covered width in canvas pixels.
    private func coverage(_ surface: IOSurfaceRef, x: Int, rows: ClosedRange<Int>) -> Double {
        return rows.reduce(0.0) { $0 + Double(CanvasSurfaces.pixel(surface, x: x, y: $1).a) / 255 }
    }

    private func drawLine(_ rasterizer: InkRasterizer, _ store: inout StrokeStore, tool: SolStream.Tool = .pen, color: UInt32 = 0xFF11_1111, base: Float, y: Double) -> UUID {
        let id = UUID()
        start(&store, id: id, tool: tool, color: color, width: base)
        // Pressure 0.5 makes the tablet width exactly the base: base * (0.55 + 0.9 * 0.5).
        let op = store.append(id: id, points: [SolStream.Point(x: 200, y: y, pressure: 0.5, deltaMs: 0), SolStream.Point(x: 1000, y: y, pressure: 0.5, deltaMs: 5)], now: 1)!
        rasterizer.apply(op, store: store)
        _ = store.commit(id: id, pointCount: 2)
        return id
    }

    func testOnePixelStrokeCoversTheCameraMinimumAt1080pAnd720p() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let rasterizer = InkRasterizer(surfaces: surfaces)
        var store = makeStore()
        let id = drawLine(rasterizer, &store, base: 1, y: 400.5)
        XCTAssertEqual(store.stroke(id: id)!.width(at: 1), 1, accuracy: 0.01, "the tablet width stays 1 px (pressure 0.5 quantizes to 128/255)")
        let canvas = coverage(surfaces.ink, x: 600, rows: 380...420)
        let minimum = CameraLineWeight.minimumCanvasWidth(for: .pen)
        print("hosted-test: camera line weight: 1 px stroke covers \(canvas) canvas px (minimum \(minimum))")
        XCTAssertGreaterThanOrEqual(canvas, minimum - 0.05)
        XCTAssertLessThan(canvas, minimum + 0.5)
        XCTAssertGreaterThanOrEqual(CameraLineWeight.outputWidth(canvasWidth: canvas, outputHeight: 1080), 2.5 - 0.04, "2.5 output px at 1080p")
        XCTAssertGreaterThanOrEqual(CameraLineWeight.outputWidth(canvasWidth: canvas, outputHeight: 720), 2.5 * 720 / 1080 - 0.03, "1.7 output px at 720p")
    }

    func testSixPixelStrokeIsUnchanged() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let rasterizer = InkRasterizer(surfaces: surfaces)
        var store = makeStore()
        let id = drawLine(rasterizer, &store, base: 6, y: 700.5)
        let stroke = store.stroke(id: id)!
        XCTAssertEqual(InkRasterizer.cameraWidth(stroke, at: 1), stroke.width(at: 1), "no clamp above the minimum")
        let canvas = coverage(surfaces.ink, x: 600, rows: 680...720)
        XCTAssertEqual(canvas, 6, accuracy: 0.1)
    }

    func testHighlighterHasItsOwnLargerMinimum() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let rasterizer = InkRasterizer(surfaces: surfaces)
        var store = makeStore()
        _ = drawLine(rasterizer, &store, tool: .highlighter, color: 0xFFD9_7706, base: 1, y: 1000.5)
        let canvas = coverage(surfaces.highlight, x: 600, rows: 970...1030)
        let minimum = CameraLineWeight.minimumCanvasWidth(for: .highlighter)
        XCTAssertGreaterThan(minimum, CameraLineWeight.minimumCanvasWidth(for: .pen))
        XCTAssertEqual(canvas, minimum, accuracy: 0.1)
        XCTAssertEqual(coverage(surfaces.ink, x: 600, rows: 970...1030), 0, "the highlighter stays on its own layer")
    }

    func testEraseOfAClampedThinStrokeLeavesNoEdgeBehind() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let rasterizer = InkRasterizer(surfaces: surfaces)
        var store = makeStore()
        _ = drawLine(rasterizer, &store, base: 1, y: 300.5)
        XCTAssertGreaterThan(coverage(surfaces.ink, x: 600, rows: 290...310), 3)
        let op = store.erase(x1: 600, y1: 290, x2: 600, y2: 310, radius: 12, hint: [], now: 2)
        XCTAssertNotNil(op)
        rasterizer.apply(op!, store: store)
        XCTAssertEqual(store.committedCount, 0)
        for x in [200, 600, 1000] {
            XCTAssertEqual(coverage(surfaces.ink, x: x, rows: 290...310), 0, "the bolder camera edge is erased too at x=\(x)")
        }
    }

    func testOnePixelDotIsDrawnAtTheMinimum() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let rasterizer = InkRasterizer(surfaces: surfaces)
        var store = makeStore()
        let id = UUID()
        start(&store, id: id, width: 1)
        _ = store.append(id: id, points: [SolStream.Point(x: 500.5, y: 500.5, pressure: 0.5, deltaMs: 0)], now: 1)
        rasterizer.apply(store.commit(id: id, pointCount: 1)!, store: store)
        let column = coverage(surfaces.ink, x: 500, rows: 490...510)
        XCTAssertGreaterThan(column, CameraLineWeight.minimumCanvasWidth(for: .pen) - 0.6, "the dot's diameter is raised to the minimum")
    }
}

