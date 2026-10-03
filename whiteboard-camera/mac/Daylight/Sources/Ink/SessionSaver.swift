import CoreImage
import CoreVideo
import DaylightKit
import Foundation

enum SessionSaverError: Error {
    case render
    case mirrorCrop
}

/// Writes `page-NN.png` and `page-NN.json` into `<root>/Daylight Camera/<yyyy-MM-dd>/<HH-mm-ss>/` (SPEC 12) on
/// io.queue. The first write of a page picks a unique name (`-2`, `-3` on collision); later writes of the same page
/// (autosave) overwrite the same two files until `forgetPage` (Clear, New page) breaks the binding.
final class SessionSaver {
    let root: URL
    let queue: DispatchQueue
    var writeJSON: Bool
    var calendar = Calendar(identifier: .gregorian)
    var onSaved: (([URL]) -> Void)?
    var onError: ((Error) -> Void)?
    private let lock = NSLock()
    private var pageURLs: [UUID: (png: URL, json: URL)] = [:]
    private var pendingWrites = 0
    private let idle = DispatchGroup()
    private var mirrorContext: CIContext?

    static func defaultRoot() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    }

    init(root: URL = SessionSaver.defaultRoot(), queue: DispatchQueue, writeJSON: Bool = true) {
        self.root = root
        self.queue = queue
        self.writeJSON = writeJSON
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
            let urls = urlsFor(pageKey: pageKey, index: strokes.pageIndex, directory: directory)
            guard let image = PNGExporter.render(strokes) else { throw SessionSaverError.render }
            try PNGExporter.write(image, to: urls.png)
            var written = [urls.png]
            if writeJSON {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
                let data = try encoder.encode(document)
                try data.write(to: urls.json, options: [.atomic])
                written.append(urls.json)
            }
            return .success(written)
        } catch {
            return .failure(error)
        }
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

    /// Breaks the file binding of a page (after Clear or New page the next save picks a fresh name).
    func forgetPage(_ key: UUID) {
        lock.lock()
        pageURLs[key] = nil
        lock.unlock()
    }

    func forgetAllPages() {
        lock.lock()
        pageURLs.removeAll()
        lock.unlock()
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
