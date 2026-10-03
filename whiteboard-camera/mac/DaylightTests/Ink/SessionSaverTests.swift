import DaylightKit
import XCTest
@testable import Daylight

/// SPEC B7: `page-NN.png` and `page-NN.json` in the session folder with the section 12 schema; autosave rewrites the
/// same files; a forgotten page binding picks `-2`.
final class SessionSaverTests: XCTestCase {
    private var root: URL!
    private let queue = DispatchQueue(label: "saver-test.io")

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("saver-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func storeWithStroke() -> StrokeStore {
        var store = StrokeStore()
        let id = UUID()
        _ = store.start(StrokeStart(id: id, tool: .pen, colorARGB: 0xFF11_1111, baseWidth: 3.2, pointer: .stylus, phase: .contact, pressure: 0.73))
        _ = store.append(id: id, points: [
            SolStream.Point(x: 10.5, y: -3.25, pressure: 0.73, deltaMs: 0),
            SolStream.Point(x: 100.0, y: 200.25, pressure: 0.2, deltaMs: 8),
            SolStream.Point(x: 1199.96875, y: 1599.0, pressure: 1.0, deltaMs: 65535),
        ], now: 1)
        _ = store.commit(id: id, pointCount: 3)
        let hl = UUID()
        _ = store.start(StrokeStart(id: hl, tool: .highlighter, colorARGB: 0x80D9_7706, baseWidth: 12, pointer: .stylus, phase: .contact, pressure: 0.5))
        _ = store.append(id: hl, points: [SolStream.Point(x: 100, y: 100, pressure: 0.5, deltaMs: 0), SolStream.Point(x: 500, y: 100, pressure: 0.5, deltaMs: 20)], now: 2)
        _ = store.commit(id: hl, pointCount: 2)
        return store
    }

    private func save(_ saver: SessionSaver, _ store: StrokeStore, start: Date, reason: SaveReason = .returned) -> [URL] {
        let doc = store.document(sessionStart: start, savedAt: Date(), reason: reason, inkSource: .web, clientLabel: "Chrome on Daylight", app: "Daylight 0.1.0 (7)")
        let done = expectation(description: "saved")
        var written: [URL] = []
        saver.save(doc, strokes: store, sessionStart: start, pageKey: store.pageID) { result in
            if case let .success(urls) = result { written = urls } else { XCTFail("save failed: \(result)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return written
    }

    func testWritesPNGAndJSONWithTheSchema() throws {
        let saver = SessionSaver(root: root, queue: queue)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let store = storeWithStroke()
        let urls = save(saver, store, start: start)
        XCTAssertEqual(urls.count, 2)
        let directory = SessionFiles.sessionDirectory(root: root, sessionStart: start)
        XCTAssertEqual(urls[0], directory.appendingPathComponent("page-01.png"))
        XCTAssertEqual(urls[1], directory.appendingPathComponent("page-01.json"))
        XCTAssertTrue(directory.path.contains("/Daylight Camera/"))
        let png = try Data(contentsOf: urls[0])
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG signature")
        let json = try Data(contentsOf: urls[1])
        let decoded = try JSONDecoder().decode(PageDocument.self, from: json)
        XCTAssertEqual(decoded.schema, "daylight-whiteboard-strokes/1")
        XCTAssertEqual(decoded.app, "Daylight 0.1.0 (7)")
        XCTAssertEqual(decoded.canvas.width, 1200)
        XCTAssertEqual(decoded.canvas.height, 1600)
        XCTAssertEqual(decoded.canvas.dpi, 200)
        XCTAssertEqual(decoded.session.reason, .returned)
        XCTAssertEqual(decoded.session.inkSource, "web")
        XCTAssertEqual(decoded.page.index, 1)
        XCTAssertEqual(decoded.strokes.count, 2)
        XCTAssertEqual(decoded.strokes[0].points.count, 3)
        XCTAssertEqual(decoded.strokes[0].points[2].tMs, 65535)
        XCTAssertEqual(decoded.strokes[0].baseWidth, 3.2, accuracy: 1e-9)
        XCTAssertEqual(decoded.strokes[1].tool, "highlighter")
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains("\"schema\" : \"daylight-whiteboard-strokes/1\"") || text.contains("\"schema\":\"daylight-whiteboard-strokes/1\""), "no escaped slash")
        XCTAssertFalse(text.contains("\\/"))
    }

    func testAutosaveRewritesTheSameFilesAndForgetPicksASuffix() throws {
        let saver = SessionSaver(root: root, queue: queue)
        let start = Date(timeIntervalSince1970: 1_790_000_100)
        var store = storeWithStroke()
        let first = save(saver, store, start: start, reason: .autosave)
        let again = save(saver, store, start: start, reason: .autosave)
        XCTAssertEqual(first, again, "autosave overwrites the same two files")
        let directory = SessionFiles.sessionDirectory(root: root, sessionStart: start)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["page-01.json", "page-01.png"])
        saver.forgetPage(store.pageID)
        store.markSaved(at: 5)
        let third = save(saver, store, start: start, reason: .cleared)
        XCTAssertEqual(third.map { $0.lastPathComponent }, ["page-01-2.png", "page-01-2.json"], "collision suffix after Clear")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 4)
    }

    func testPNGRendersPaperAndInkFromTheModel() throws {
        let store = storeWithStroke()
        let image = PNGExporter.render(store)!
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 1600)
        let saver = SessionSaver(root: root, queue: queue, writeJSON: false)
        let urls = save(saver, store, start: Date(), reason: .quit)
        XCTAssertEqual(urls.count, 1, "JSON off writes only the PNG")
    }

    func testMirrorSaveName() throws {
        let saver = SessionSaver(root: root, queue: queue)
        let start = Date(timeIntervalSince1970: 1_790_000_200)
        let buffer = SelfTest.gradientBuffer(width: 1200, height: 1600)!
        let done = expectation(description: "mirror saved")
        var written: [URL] = []
        saver.saveMirror(buffer, uv: UVRect(u0: 0, v0: 0.06, u1: 1, v1: 1), sessionStart: start) { result in
            if case let .success(urls) = result { written = urls } else { XCTFail("\(result)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(written.count, 1)
        XCTAssertTrue(written[0].lastPathComponent.hasPrefix("mirror-"))
        XCTAssertEqual(written[0].pathExtension, "png")
        XCTAssertEqual(written[0].lastPathComponent, SessionFiles.mirrorName(sessionStart: start) + ".png")
        XCTAssertTrue(saver.waitUntilIdle(timeout: 2))
    }
}
