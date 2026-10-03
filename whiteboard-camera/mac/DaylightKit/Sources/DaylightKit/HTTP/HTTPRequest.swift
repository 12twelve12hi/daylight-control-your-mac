import Foundation

/// HTTP/1.1 request head parser and response builder for the Mac's listener (ARCHITECTURE section 5).
public struct HTTPRequest: Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names lower-cased; a repeated header keeps the last value.
    public var headers: [String: String]

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:]) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
    }

    public static let webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    /// A head longer than this without its terminator is rejected (`HTTPError.headTooLarge`).
    public static let maxHeadLength = 16 * 1024

    /// Returns nil until the head is complete ("\r\n\r\n" seen); `consumed` counts the head including the terminator.
    public static func parse(_ buffer: UnsafeRawBufferPointer) throws -> (request: HTTPRequest, consumed: Int)? {
        let bytes = [UInt8](buffer)
        guard let end = indexOfHeadEnd(bytes) else {
            if bytes.count > maxHeadLength { throw HTTPError.headTooLarge }
            return nil
        }
        if end > maxHeadLength { throw HTTPError.headTooLarge }
        let head = String(decoding: bytes[0..<end], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw HTTPError.badRequestLine }
        if requestLine.count >= 3 && !requestLine[2].hasPrefix("HTTP/") { throw HTTPError.badRequestLine }
        let target = String(requestLine[1])
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (HTTPRequest(method: String(requestLine[0]), path: path, query: query, headers: headers), end + 4)
    }

    public static func parse(_ bytes: [UInt8]) throws -> (request: HTTPRequest, consumed: Int)? {
        return try bytes.withUnsafeBytes { try parse($0) }
    }

    private static func indexOfHeadEnd(_ bytes: [UInt8]) -> Int? {
        if bytes.count < 4 { return nil }
        for i in 0...(bytes.count - 4) {
            if bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 { return i }
        }
        return nil
    }

    public var isWebSocketUpgrade: Bool {
        guard headers["upgrade"]?.lowercased() == "websocket", headers["sec-websocket-key"] != nil else { return false }
        let connection = headers["connection"]?.lowercased() ?? ""
        return connection.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }
    }

    public var webSocketKey: String? { return headers["sec-websocket-key"] }

    public var webSocketVersion: Int? {
        guard let raw = headers["sec-websocket-version"] else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    public var webSocketProtocols: [String] {
        guard let raw = headers["sec-websocket-protocol"] else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func statusText(_ code: Int) -> String {
        switch code {
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 413: return "Payload Too Large"
        case 426: return "Upgrade Required"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }

    /// A complete response; always `Connection: close` (the static server never keeps a connection open).
    public static func response(status: Int, headers: [(String, String)], body: [UInt8]) -> [UInt8] {
        var head = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Array(head.utf8) + body
    }

    /// base64(SHA1(key + GUID)), RFC 6455 section 1.3.
    public static func webSocketAccept(forKey key: String) -> String {
        let digest = SHA1.hash(Array((key + webSocketGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    public static func upgradeResponse(accept: String, subprotocol: String?) -> [UInt8] {
        var head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n"
        if let sub = subprotocol {
            head += "Sec-WebSocket-Protocol: \(sub)\r\n"
        }
        head += "\r\n"
        return Array(head.utf8)
    }
}

public enum HTTPError: Error, Equatable {
    case badRequestLine
    case headTooLarge
}
