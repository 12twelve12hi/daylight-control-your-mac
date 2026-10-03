import Foundation

public enum MIME {
    private static let table: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json",
        "webmanifest": "application/manifest+json",
        "svg": "image/svg+xml",
        "png": "image/png",
        "ico": "image/x-icon",
        "woff2": "font/woff2",
        "txt": "text/plain; charset=utf-8",
        "apk": "application/vnd.android.package-archive",
    ]

    public static func type(forExtension ext: String) -> String? {
        return table[ext.lowercased()]
    }
}
