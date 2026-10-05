import CoreGraphics
import CoreImage
import CoreVideo
import DaylightKit
import Foundation
import ImageIO

enum SessionSaverError: Error {
    case render
    case mirrorCrop
    case pdfContext
}

/// Writes `page-NN.png` and `page-NN.json` into `<root>/Daylight Camera/<yyyy-MM-dd>/<HH-mm-ss>/` (SPEC 12) on
/// io.queue. The PNG carries the same JSON bytes in an `iTXt` chunk with the keyword `daylight-strokes`
/// (`PNGTextChunk`), also when `writeJSON` is off (then only the sidecar file is skipped). The first write of a page picks a unique name (`-2`, `-3` on collision); later writes of the same page
/// (autosave) overwrite the same two files until `forgetPage` (Clear, New page) breaks the binding.
///
/// The binding is created inside the queued write, so `forgetPage` and `forgetAllPages` are queued on the same serial
/// queue: a Clear that saves and then forgets (in that program order on ink.queue) runs the write first and the forget
/// second, and the next board drawn on the same page id gets a fresh pair (`page-01-2`) instead of overwriting.
final class SessionSaver {
    let queue: DispatchQueue
    var writeJSON: Bool
    var calendar = Calendar(identifier: .gregorian)
    var onSaved: (([URL]) -> Void)?
    var onError: ((Error) -> Void)?
    private let lock = NSLock()
    private var pageURLs: [UUID: (png: URL, json: URL)] = [:]
    /// Session folder path -> the session PDF this saver wrote there (D39): rewritten in place, never another's.
    private var pdfURLs: [String: URL] = [:]
    /// Session start -> every folder a page of that session was written to, oldest first (review F7: a save folder
    /// changed in Settings mid-session leaves earlier pages under the old root; the session PDF follows the pages).
    private var sessionFolders: [Date: [URL]] = [:]
    private var pendingWrites = 0
    private let idle = DispatchGroup()
    private var mirrorContext: CIContext?
    private var currentRoot: URL

    static func defaultRoot() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    }

    init(root: URL = SessionSaver.defaultRoot(), queue: DispatchQueue, writeJSON: Bool = true) {
        self.currentRoot = root
        self.queue = queue
        self.writeJSON = writeJSON
    }

    /// The folder sessions are written under (SPEC 11 `saveDirectory`); Settings can move it while the app runs.
    var root: URL {
        lock.lock()
        defer { lock.unlock() }
        return currentRoot
    }

    /// A new save folder from Settings. Queued on `queue` like the writes: every save enqueued before this call lands
    /// in the old folder, every save after it in the new one. The page bindings point into the old folder, so they
    /// are dropped and the next save of an open page starts a fresh pair in the new one.
    func setRoot(_ url: URL) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.currentRoot = url
            self.pageURLs.removeAll()
            self.lock.unlock()
        }
    }

    var isSaving: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingWrites > 0
    }

    /// The directory a page of this session lands in.
    func sessionDirectory(sessionStart: Date) -> URL {
        return SessionFiles.sessionDirectory(root: root, sessionStart: sessionStart, calendar: calendar)
    }

    /// Renders and writes one page. `strokes` is a value copy taken on ink.queue.
    func save(_ document: PageDocument, strokes: StrokeStore, sessionStart: Date, pageKey: UUID, completion: ((Result<[URL], Error>) -> Void)?) {
        begin()
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = self.write(document, strokes: strokes, sessionStart: sessionStart, pageKey: pageKey)
            self.end()
            switch result {
            case let .success(urls): self.onSaved?(urls)
            case let .failure(error): self.onError?(error)
            }
            completion?(result)
        }
    }

    private func write(_ document: PageDocument, strokes: StrokeStore, sessionStart: Date, pageKey: UUID) -> Result<[URL], Error> {
        do {
            let directory = sessionDirectory(sessionStart: sessionStart)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            noteFolder(directory, sessionStart: sessionStart)
            let urls = urlsFor(pageKey: pageKey, index: strokes.pageIndex, directory: directory)
            guard let image = PNGExporter.render(strokes) else { throw SessionSaverError.render }
            // The strokes JSON goes inside the PNG as an `iTXt` chunk `daylight-strokes` (the same bytes as the
            // sidecar), whether or not the sidecar is written: the PNG alone is enough to rebuild the board.
            let json = try SessionSaver.strokesJSON(document)
            let png = try PNGTextChunk.inserting(keyword: PNGTextChunk.strokesKeyword, text: json, into: PNGExporter.pngData(image))
            try png.write(to: urls.png, options: [.atomic])
            var written = [urls.png]
            if writeJSON {
                try json.write(to: urls.json, options: [.atomic])
                written.append(urls.json)
            }
            return .success(written)
        } catch {
            return .failure(error)
        }
    }

    /// The page's strokes JSON (SPEC 12 schema v1), exactly as the sidecar and the PNG chunk hold it.
    static func strokesJSON(_ document: PageDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return try encoder.encode(document)
    }

    private func urlsFor(pageKey: UUID, index: Int, directory: URL) -> (png: URL, json: URL) {
        lock.lock()
        defer { lock.unlock() }
        if let bound = pageURLs[pageKey] { return bound }
        let base = SessionFiles.pageBaseName(index: index)
        let exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        let png = SessionFiles.uniqueURL(directory.appendingPathComponent(base).appendingPathExtension("png"), exists: exists)
        // The JSON follows the PNG's chosen suffix so the pair always matches.
        let json = png.deletingPathExtension().appendingPathExtension("json")
        let pair = (png: png, json: json)
        pageURLs[pageKey] = pair
        return pair
    }

    /// Breaks the file binding of a page (after Clear or New page the next save picks a fresh name). Ordered with the
    /// writes: the forget runs on `queue` after every save enqueued before it.
    func forgetPage(_ key: UUID) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.pageURLs[key] = nil
            self.lock.unlock()
        }
    }

    /// Breaks every binding (a new session starts); ordered with the writes like `forgetPage`.
    func forgetAllPages() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.pageURLs.removeAll()
            self.lock.unlock()
        }
    }

    /// Mirror mode: the last decoded frame, cropped by `uv`, as `mirror-<HH-mm-ss>.png` (SPEC 12, D39).
    func saveMirror(_ pixelBuffer: CVPixelBuffer, uv: UVRect, sessionStart: Date, completion: ((Result<[URL], Error>) -> Void)? = nil) {
        begin()
        queue.async { [weak self] in
            guard let self = self else { return }
            let result: Result<[URL], Error>
            do {
                let directory = self.sessionDirectory(sessionStart: sessionStart)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                self.noteFolder(directory, sessionStart: sessionStart)
                let name = SessionFiles.mirrorName(sessionStart: sessionStart, calendar: self.calendar)
                let url = SessionFiles.uniqueURL(directory.appendingPathComponent(name).appendingPathExtension("png"), exists: { FileManager.default.fileExists(atPath: $0.path) })
                let image = try self.cropped(pixelBuffer, uv: uv)
                try PNGExporter.write(image, to: url)
                result = .success([url])
            } catch {
                result = .failure(error)
            }
            self.end()
            switch result {
            case let .success(urls): self.onSaved?(urls)
            case let .failure(error): self.onError?(error)
            }
            completion?(result)
        }
    }

    private func cropped(_ pixelBuffer: CVPixelBuffer, uv: UVRect) throws -> CGImage {
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        // CIImage coordinates are y-up; uv.v0 is the top edge.
        let rect = CGRect(x: uv.u0 * width, y: (1 - uv.v1) * height, width: (uv.u1 - uv.u0) * width, height: (uv.v1 - uv.v0) * height)
        let image = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: rect)
        if mirrorContext == nil { mirrorContext = CIContext(options: nil) }
        guard let context = mirrorContext, let cg = context.createCGImage(image, from: rect) else { throw SessionSaverError.mirrorCrop }
        return cg
    }

    /// Records, on `queue`, a folder a page of this session was written to.
    private func noteFolder(_ directory: URL, sessionStart: Date) {
        lock.lock()
        defer { lock.unlock() }
        var folders = sessionFolders[sessionStart] ?? []
        if !folders.contains(directory) { folders.append(directory) }
        sessionFolders[sessionStart] = folders
    }

    /// The folders this session's pages were written to (oldest first), or the folder under the current root when
    /// this saver wrote none (a session from before a relaunch).
    func sessionFoldersForPDF(sessionStart: Date) -> [URL] {
        lock.lock()
        let folders = sessionFolders[sessionStart] ?? []
        lock.unlock()
        return folders.isEmpty ? [sessionDirectory(sessionStart: sessionStart)] : folders
    }

    /// D39: every page image of the session's folder (`SessionHandout.pageFiles` order) as one PDF, one page per
    /// image with the image's pixel size as its media box in points (1200x1600 for a page). Queued on `queue` after
    /// every save enqueued before it, so the PDF holds the latest page. Written with `Data.write(.atomic)` (a temporary
    /// file in the folder, then a rename). The folders are the ones the session's pages were actually written to
    /// (review F7), not the current root: after a save-folder change mid-session each folder gets the PDF of its own
    /// pages. The result is the newest folder's PDF, nil when no folder holds a page image.
    func writeSessionPDF(sessionStart: Date, completion: ((Result<URL?, Error>) -> Void)? = nil) {
        begin()
        queue.async { [weak self] in
            guard let self = self else { return }
            let result: Result<URL?, Error>
            do {
                var newest: URL?
                for directory in self.sessionFoldersForPDF(sessionStart: sessionStart) {
                    if let url = try self.writePDF(directory: directory) { newest = url }
                }
                result = .success(newest)
            } catch {
                result = .failure(error)
            }
            self.end()
            completion?(result)
        }
    }

    private func writePDF(directory: URL) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        let pages = SessionHandout.pageFiles(try fileManager.contentsOfDirectory(atPath: directory.path))
        guard !pages.isEmpty else { return nil }
        let data = NSMutableData()
        var defaultBox = CGRect(x: 0, y: 0, width: CGFloat(SolStream.canvasWidth), height: CGFloat(SolStream.canvasHeight))
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else { throw SessionSaverError.pdfContext }
        var drawn = 0
        for name in pages {
            let url = directory.appendingPathComponent(name)
            // A page that does not decode (a write in progress elsewhere, a damaged file) is left out, not fatal.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
            drawn += 1
        }
        context.closePDF()
        guard drawn > 0 else { return nil }
        lock.lock()
        let bound = pdfURLs[directory.path]
        lock.unlock()
        let target = SessionHandout.pdfURL(directory: directory, bound: bound, exists: { fileManager.fileExists(atPath: $0.path) })
        try (data as Data).write(to: target, options: [.atomic])
        lock.lock()
        pdfURLs[directory.path] = target
        lock.unlock()
        return target
    }

    /// Waits for queued writes (quit: SPEC 12 "the app waits up to 2 s for the writer").
    @discardableResult
    func waitUntilIdle(timeout: Double) -> Bool {
        return idle.wait(timeout: .now() + timeout) == .success
    }

    private func begin() {
        lock.lock()
        pendingWrites += 1
        lock.unlock()
        idle.enter()
    }

    private func end() {
        lock.lock()
        pendingWrites -= 1
        lock.unlock()
        idle.leave()
    }
}
