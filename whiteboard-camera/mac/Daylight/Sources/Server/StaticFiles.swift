import DaylightKit
import Foundation
import UniformTypeIdentifiers

/// Serves the embedded Vite build (`Resources/web`): `WebRootPath.resolve` sanitises the path, the MIME table then
/// `UTType` picks the type, `/assets/*` is immutable for a year and everything else `no-cache` (PROTOCOL section 1).
struct StaticFiles {
    static let immutableCache = "public, max-age=31536000, immutable"
    static let noCache = "no-cache"

    let root: URL?

    init(root: URL?) {
        self.root = root
    }

    func respond(path requestPath: String) -> HTTPResponse {
        guard let root = root else { return HTTPResponse.text(404, "The web whiteboard is not in this build") }
        guard let relative = WebRootPath.resolve(requestPath) else { return HTTPResponse.text(400, "Bad path") }
        let rootPath = root.standardizedFileURL.path
        let url = root.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(rootPath) else { return HTTPResponse.text(403, "Forbidden") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let data = try? Data(contentsOf: url) else {
            return HTTPResponse.text(404, "Not found")
        }
        let type = StaticFiles.contentType(forExtension: url.pathExtension)
        let cache = relative.hasPrefix("assets/") ? StaticFiles.immutableCache : StaticFiles.noCache
        return HTTPResponse(status: 200, headers: [("Content-Type", type), ("Cache-Control", cache)], body: [UInt8](data))
    }

    static func contentType(forExtension ext: String) -> String {
        if let known = MIME.type(forExtension: ext) { return known }
        if let mime = UTType(filenameExtension: ext)?.preferredMIMEType { return mime }
        return "application/octet-stream"
    }
}
