import AppKit
import CoreGraphics
import DaylightKit
import ImageIO
import QuartzCore
import XCTest
@testable import Daylight

/// The board as the follow-up: D39 `session.pdf`, D40 "Copy last page", D41 "Send today's board...".
final class SessionPDFTests: XCTestCase {
    private var root: URL!
    private let ioQueue = DispatchQueue(label: "session-pdf-test.io")
    private let inkQueue = DispatchQueue(label: "session-pdf-test.ink")

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("session-pdf-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        ioQueue.sync {}
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func storeWithStroke(x: Double) -> StrokeStore {
        var store = StrokeStore()
        let id = UUID()
        _ = store.start(StrokeStart(id: id, tool: .pen, colorARGB: 0xFF11_1111, baseWidth: 3.2, pointer: .stylus, phase: .contact, pressure: 0.7))
        _ = store.append(id: id, points: [
            SolStream.Point(x: x, y: 100, pressure: 0.7, deltaMs: 0),
            SolStream.Point(x: x + 300, y: 900, pressure: 0.7, deltaMs: 16),
        ], now: 1)
        _ = store.commit(id: id, pointCount: 2)
        return store
    }

    private func save(_ saver: SessionSaver, _ store: StrokeStore, start: Date) {
        let doc = store.document(sessionStart: start, savedAt: Date(), reason: .pageChange, inkSource: .web, clientLabel: "Chrome on Daylight", app: "Daylight 0.1.0 (7)")
        let done = expectation(description: "saved")
        saver.save(doc, strokes: store, sessionStart: start, pageKey: UUID()) { result in
            if case .failure = result { XCTFail("save failed: \(result)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    private func writePDF(_ saver: SessionSaver, start: Date) -> URL? {
        let done = expectation(description: "pdf")
        var written: URL?
        saver.writeSessionPDF(sessionStart: start) { result in
            switch result {
            case let .success(url): written = url
            case let .failure(error): XCTFail("pdf failed: \(error)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        return written
    }

    /// D39: three saved pages make a three-page session.pdf next to them, each page 1200x1600 points.
    func testThreePagesMakeAThreePagePDF() throws {
        let saver = SessionSaver(root: root, queue: ioQueue)
        let start = Date(timeIntervalSince1970: 1_791_100_000)
        save(saver, storeWithStroke(x: 100), start: start)
        save(saver, storeWithStroke(x: 400), start: start)
        save(saver, storeWithStroke(x: 700), start: start)
        guard let url = writePDF(saver, start: start) else { return XCTFail("no PDF written") }
        let directory = saver.sessionDirectory(sessionStart: start)
        XCTAssertEqual(url.lastPathComponent, "session.pdf")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
        guard let document = CGPDFDocument(url as CFURL) else { return XCTFail("the PDF does not open") }
        XCTAssertEqual(document.numberOfPages, 3)
        for index in 1...3 {
            guard let page = document.page(at: index) else { return XCTFail("page \(index) missing") }
            let box = page.getBoxRect(.mediaBox)
            XCTAssertEqual(box.width, 1200, accuracy: 0.5, "page \(index)")
            XCTAssertEqual(box.height, 1600, accuracy: 0.5, "page \(index)")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThan(size, 30_000_000, "three pages stay well below 30 MB")
        // More pages later rewrite the same session's own PDF.
        save(saver, storeWithStroke(x: 200), start: start)
        XCTAssertEqual(writePDF(saver, start: start), url)
        XCTAssertEqual(CGPDFDocument(url as CFURL)?.numberOfPages, 4)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".pdf") }
        XCTAssertEqual(names, ["session.pdf"])
    }

    /// A session.pdf this saver did not write for the session (a folder collision) is never overwritten.
    func testAForeignSessionPDFIsKept() throws {
        let saver = SessionSaver(root: root, queue: ioQueue)
        let start = Date(timeIntervalSince1970: 1_791_100_100)
        save(saver, storeWithStroke(x: 100), start: start)
        let directory = saver.sessionDirectory(sessionStart: start)
        let foreign = directory.appendingPathComponent("session.pdf")
        try Data("not ours".utf8).write(to: foreign)
        let url = writePDF(saver, start: start)
        XCTAssertEqual(url?.lastPathComponent, "session-2.pdf")
        XCTAssertEqual(try Data(contentsOf: foreign), Data("not ours".utf8))
    }

    func testAFolderWithoutPagesWritesNoPDF() {
        let saver = SessionSaver(root: root, queue: ioQueue)
        XCTAssertNil(writePDF(saver, start: Date(timeIntervalSince1970: 1_791_100_200)))
    }

    /// D39 through the router: a saved session gets its PDF once the autosave tick finds it idle past the gap.
    func testRouterWritesThePDFWhenTheSessionGoesIdle() throws {
        let pipeline = FakePipeline()
        let registryURL = FileManager.default.temporaryDirectory.appendingPathComponent("clients-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: registryURL) }
        let registry = ClientRegistry(fileURL: registryURL, ioQueue: ioQueue, trustLoopback: true)
        let saver = SessionSaver(root: root, queue: ioQueue)
        let surfaces = try CanvasSurfaces(device: nil)
        let router = InkRouter(pipeline: pipeline, rasterizer: InkRasterizer(surfaces: surfaces), registry: registry, saver: saver, settings: Settings.defaults, queue: inkQueue)
        let transport = FakeTransport(address: "127.0.0.1")
        let connection = InkConnection(transport: transport)
        router.clientOpened(connection)
        router.handle(Codec.encode(.handshake(canvasWidth: 1200, canvasHeight: 1600, dpi: 200, name: "web;6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b;Mike's DC-1"), timestampUs: 1), from: connection, hostTimeNs: 1)
        router.handle(Hex.decode(SelfTest.Golden.strokeStart)!, from: connection, hostTimeNs: 2)
        router.handle(Hex.decode(SelfTest.Golden.strokeChunk3)!, from: connection, hostTimeNs: 3)
        router.handle(Hex.decode(SelfTest.Golden.strokeCommit)!, from: connection, hostTimeNs: 4)
        XCTAssertNotNil(router.currentPageSnapshot(), "the page has ink")
        XCTAssertTrue(router.pageHasInk)
        router.savePage(reason: .returned)
        ioQueue.sync {}   // the save and its completion, which queues the result hop on ink.queue
        inkQueue.sync {}
        guard let start = router.sessionStart else { return XCTFail("no session") }
        XCTAssertEqual(router.handout.pendingStart, start)
        let pdf = saver.sessionDirectory(sessionStart: start).appendingPathComponent("session.pdf")
        router.writeHandoutIfIdle(nowWall: Date(), nowMonotonic: CACurrentMediaTime())
        XCTAssertTrue(saver.waitUntilIdle(timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.path), "still inside the 10-minute gap")
        router.writeHandoutIfIdle(nowWall: Date().addingTimeInterval(SessionFiles.sessionGapSeconds + 1), nowMonotonic: CACurrentMediaTime())
        XCTAssertTrue(saver.waitUntilIdle(timeout: 20))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path), "idle by the wall clock (the Mac slept)")
        XCTAssertEqual(CGPDFDocument(pdf as CFURL)?.numberOfPages, 1)
        XCTAssertNil(router.handout.pendingStart, "written once")
        inkQueue.sync {}
    }

    /// D40: the rendered current page and the saved fallback both reach the pasteboard as a 1200x1600 PNG.
    func testCopyLastPagePutsA1200x1600PNGOnThePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("daylight-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        guard let rendered = LastPage.pngData(snapshot: storeWithStroke(x: 100), fallback: nil) else { return XCTFail("no PNG from the stroke model") }
        XCTAssertTrue(LastPage.put(rendered, on: pasteboard))
        try assertPNG(pasteboard.data(forType: .png), width: 1200, height: 1600)
        XCTAssertNil(LastPage.pngData(snapshot: StrokeStore(), fallback: nil), "a blank page and nothing saved: nothing to copy")

        // Through the model: no router, the last saved page is the fallback.
        let saver = SessionSaver(root: root, queue: ioQueue)
        let start = Date(timeIntervalSince1970: 1_791_100_300)
        save(saver, storeWithStroke(x: 500), start: start)
        let png = saver.sessionDirectory(sessionStart: start).appendingPathComponent("page-01.png")
        let model = AppModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "copy-\(UUID().uuidString)")!, unsignedBuild: false), signed: true, version: "0", build: "0")
        XCTAssertFalse(model.canCopyLastPage, "nothing at all: the menu item is disabled")
        model.noteSaved([png, png.deletingPathExtension().appendingPathExtension("json")])
        XCTAssertEqual(model.lastSavedPNG, png)
        XCTAssertTrue(model.canCopyLastPage)
        let copied = expectation(description: "copied")
        var ok = false
        model.copyLastPage(to: pasteboard) { result in
            ok = result
            copied.fulfill()
        }
        wait(for: [copied], timeout: 10)
        XCTAssertTrue(ok)
        try assertPNG(pasteboard.data(forType: .png), width: 1200, height: 1600)
    }

    private func assertPNG(_ data: Data?, width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let data = data else { return XCTFail("no PNG on the pasteboard", file: file, line: line) }
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], file: file, line: line)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("the PNG does not decode", file: file, line: line)
        }
        XCTAssertEqual(image.width, width, file: file, line: line)
        XCTAssertEqual(image.height, height, file: file, line: line)
    }

    /// D41: with no saved session "Send today's board..." yields the sentence, never a share sheet.
    func testSendWithNoSessionSaysNoSavedBoard() {
        XCTAssertEqual(AppModel.boardToSend(root: root, today: Date()), .nothing("No saved board to send yet."))
        let model = AppModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "send-\(UUID().uuidString)")!, unsignedBuild: false), signed: true, version: "0", build: "0")
        model.settingsStore.settings.saveDirectory = root
        let decided = expectation(description: "decided")
        var choice: SessionHandout.SendChoice?
        model.prepareBoardToSend { result in
            choice = result
            decided.fulfill()
        }
        wait(for: [decided], timeout: 10)
        XCTAssertEqual(choice, .nothing(SessionHandout.nothingToSend))
    }

    /// D41: today's written session PDF is the one offered.
    func testSendOffersTodaysSessionPDF() throws {
        let saver = SessionSaver(root: root, queue: ioQueue)
        let start = Date()
        save(saver, storeWithStroke(x: 100), start: start)
        guard let url = writePDF(saver, start: start) else { return XCTFail("no PDF") }
        let choice = AppModel.boardToSend(root: root, today: Date(), calendar: saver.calendar)
        guard case let .send(sent) = choice else { return XCTFail("expected a PDF, got \(choice)") }
        XCTAssertEqual(sent.standardizedFileURL.path, url.standardizedFileURL.path)
    }
}
