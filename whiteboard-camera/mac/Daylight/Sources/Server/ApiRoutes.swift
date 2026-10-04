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

/// `POST /api/facts` (PROTOCOL 15): the tablet's "Send facts to Mac" button. Pure, so every status is unit-tested
/// without a socket; the listener reads the body (`factsHead` says how much) and calls `facts`.
extension ApiRoutes {
    static let factsPath = "/api/facts"
    static let factsSchema = "daylight-tablet-facts/1"
    static let factsMaxBody = 16384
    static let factsMaxKeys = 64
    static let factsMaxValueLength = 1024
    static let factsMaxIdLength = 64

    enum FactsHead: Equatable {
        /// Answer at once (403, 411, 413, 415, 400 for a malformed length) without reading a body.
        case reject(Int, String)
        /// Read exactly this many body bytes, then call `facts`.
        case read(Int)
    }

    /// The header checks of PROTOCOL 15.2, in this order: Origin, Content-Length present, its size, Content-Type.
    static func factsHead(_ request: HTTPRequest) -> FactsHead {
        if request.headers["origin"] != nil && !WebServer.originMatchesHost(origin: request.headers["origin"], host: request.headers["host"]) {
            return .reject(403, "Origin not allowed")
        }
        if request.headers["transfer-encoding"] != nil { return .reject(411, "Length required") }
        guard let lengthText = request.headers["content-length"] else { return .reject(411, "Length required") }
        let trimmedLength = lengthText.trimmingCharacters(in: .whitespaces)
        guard let length = Int(trimmedLength), length >= 0 else {
            // Only digits but past Int.max: still a length above 16384 (15.2 row 413), not a malformed one.
            let digits = Set("0123456789")
            if !trimmedLength.isEmpty && trimmedLength.allSatisfy({ digits.contains($0) }) {
                return .reject(413, "Facts too large")
            }
            return .reject(400, "Bad facts: bad Content-Length")
        }
        if length > factsMaxBody { return .reject(413, "Facts too large") }
        guard isJSONContentType(request.headers["content-type"]) else {
            return .reject(415, "Content-Type must be application/json")
        }
        return .read(length)
    }

    /// `application/json`, optionally with `; charset=utf-8` (any case).
    static func isJSONContentType(_ value: String?) -> Bool {
        guard let value = value else { return false }
        let parts = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.first == "application/json" else { return false }
        for parameter in parts.dropFirst() where parameter != "charset=utf-8" { return false }
        return true
    }

    /// A validated body (PROTOCOL 15.1).
    struct FactsBody: Equatable {
        let source: String
        let clientId: String?
        let sentAt: String
        let facts: [String: FactValue]
    }

    /// The 15.1 rules; the error is the `<reason>` of `Bad facts: <reason>`.
    static func validateFacts(_ body: [UInt8]) -> Result<FactsBody, FactsError> {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(body), options: []) else { return .failure(FactsError("not JSON")) }
        guard let object = parsed as? [String: Any] else { return .failure(FactsError("not a JSON object")) }
        guard object["schema"] as? String == factsSchema else { return .failure(FactsError("wrong schema")) }
        guard let source = object["source"] as? String, source == "web" || source == "ink" else { return .failure(FactsError("wrong source")) }
        var clientId: String?
        if let raw = object["clientId"], !(raw is NSNull) {
            let hex = Set("0123456789abcdefABCDEF-")
            guard let id = raw as? String, id.count <= factsMaxIdLength, id.allSatisfy({ hex.contains($0) }) else {
                return .failure(FactsError("bad clientId"))
            }
            clientId = id.isEmpty ? nil : id
        }
        guard let sentAt = object["sentAt"] as? String, !sentAt.isEmpty, sentAt.count <= 64 else { return .failure(FactsError("bad sentAt")) }
        guard let factsObject = object["facts"] as? [String: Any] else { return .failure(FactsError("facts is not an object")) }
        guard factsObject.count <= factsMaxKeys else { return .failure(FactsError("too many keys (\(factsObject.count), at most \(factsMaxKeys))")) }
        var facts: [String: FactValue] = [:]
        for key in factsObject.keys.sorted() {
            guard let value = factsValue(factsObject[key]) else { return .failure(FactsError("nested value \(printable(key))")) }
            if case let .string(s) = value, s.count > factsMaxValueLength { return .failure(FactsError("value too long \(printable(key))")) }
            facts[key] = value
        }
        return .success(FactsBody(source: source, clientId: clientId, sentAt: sentAt, facts: facts))
    }

    /// A posted key as it may appear in a reason (and so in the log): control characters become `?`, at most 64
    /// characters (finder AF-3: a key with a newline forged log lines).
    static func printable(_ key: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in key.unicodeScalars.prefix(64) {
            let isControl = scalar.properties.generalCategory == .control
            out.append(isControl ? "?" : scalar)
        }
        return String(out)
    }

    struct FactsError: Error, Equatable {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// nil for an array or an object (a nested value).
    static func factsValue(_ value: Any?) -> FactValue? {
        guard let value = value else { return .null }
        if value is NSNull { return .null }
        if let s = value as? String { return .string(s) }
        if let n = value as? NSNumber {
            // JSONSerialization returns booleans as NSNumber (CFBoolean) on Darwin.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        return nil
    }

    /// The whole route after the body arrived: the head checks again, validation, then the store (PROTOCOL 15.3).
    static func facts(_ request: HTTPRequest, body: [UInt8], remoteAddress: String, now: Date, isAllowed: (String) -> Bool, store: TabletFactsStore) -> HTTPResponse {
        if case let .reject(status, text) = factsHead(request) { return HTTPResponse.text(status, text) }
        let parsed: FactsBody
        switch validateFacts(body) {
        case let .success(value): parsed = value
        case let .failure(error): return HTTPResponse.text(400, "Bad facts: \(error.reason)")
        }
        let key = TabletFactsStore.key(source: parsed.source, clientId: parsed.clientId, remoteAddress: remoteAddress)
        let allowed = parsed.clientId.map(isAllowed) ?? false
        let entry = TabletFactsStore.Entry(
            key: key, source: parsed.source, clientId: parsed.clientId, sentAt: parsed.sentAt, facts: parsed.facts,
            receivedAt: now, remoteAddress: remoteAddress, allowed: allowed)
        let stored = store.put(entry)
        let answer: [String: Any] = ["ok": true, "key": key, "stored": stored]
        guard let data = try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return HTTPResponse.text(500, "facts unavailable")
        }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-cache")], body: [UInt8](data))
    }
}
