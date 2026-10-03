import Foundation

/// Maps a request path to a relative file path under the web root; nil on traversal or anything suspicious.
public enum WebRootPath {
    public static func resolve(_ requestPath: String) -> String? {
        guard let decoded = requestPath.removingPercentEncoding else { return nil }
        if decoded.contains("\0") || decoded.contains("\\") { return nil }
        var parts: [String] = []
        for component in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { return nil }
            parts.append(String(component))
        }
        if parts.isEmpty { return "index.html" }
        return parts.joined(separator: "/")
    }
}
