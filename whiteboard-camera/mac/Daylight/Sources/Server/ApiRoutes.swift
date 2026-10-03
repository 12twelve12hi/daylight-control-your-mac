import DaylightKit
import Foundation

/// A complete HTTP response (always `Connection: close`, PROTOCOL section 1).
struct HTTPResponse {
    var status: Int
    var headers: [(String, String)]
    var body: [UInt8]

    func bytes() -> [UInt8] {
        return HTTPRequest.response(status: status, headers: headers, body: body)
    }

    static func text(_ status: Int, _ text: String) -> HTTPResponse {
        return HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8"), ("Cache-Control", "no-cache")], body: Array(text.utf8))
    }
}

/// `/healthz`, `/api/info` and `/daylight-ink.apk` (PROTOCOL section 1).
enum ApiRoutes {
    static let apkPath = "/daylight-ink.apk"
    static let apkContentType = "application/vnd.android.package-archive"

    static func healthz() -> HTTPResponse {
        return HTTPResponse.text(200, "ok")
    }

    /// `{"app":"daylight","version":...,"build":...,"port":...,"inkSource":...,"pillStripHeight":...,"secureHint":...,"origin":...}`.
    static func info(_ dict: [String: Any]) -> HTTPResponse {
        var object = dict
        object["app"] = "daylight"
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return HTTPResponse.text(500, "info unavailable")
        }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-cache")], body: [UInt8](data))
    }

    /// The standard `/api/info` dictionary.
    static func infoDictionary(version: String, build: Int, port: UInt16, inkSource: InkSource, pillStripHeight: Int, origin: String) -> [String: Any] {
        return [
            "app": "daylight",
            "version": version,
            "build": build,
            "port": Int(port),
            "inkSource": inkSource.jsonName,
            "pillStripHeight": pillStripHeight,
            "secureHint": "chrome://flags/#unsafely-treat-insecure-origin-as-secure",
            "origin": origin,
        ]
    }

    static func apk(url: URL?) -> HTTPResponse {
        guard let url = url, let data = try? Data(contentsOf: url), !data.isEmpty else {
            return HTTPResponse.text(404, "This build has no Daylight Ink app")
        }
        return HTTPResponse(
            status: 200,
            headers: [
                ("Content-Type", apkContentType),
                ("Content-Disposition", "attachment; filename=\"DaylightInk.apk\""),
                ("Cache-Control", "no-cache"),
            ],
            body: [UInt8](data))
    }
}
