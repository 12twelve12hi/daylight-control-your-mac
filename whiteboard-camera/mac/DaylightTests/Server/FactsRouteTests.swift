import DaylightKit
import Foundation
import Network
import XCTest
@testable import Daylight

/// PROTOCOL 15: `POST /api/facts` as a pure route (every status of 15.2 and the 15.3 storage rules).
final class FactsRouteTests: XCTestCase {
    static let clientId = "6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b"

    static func body(source: String = "web", clientId: String? = FactsRouteTests.clientId, schema: String = "daylight-tablet-facts/1", facts: String = "{\"chromeVersion\":\"141.0.7390.54\",\"devicePixelRatio\":2,\"secureContext\":true,\"firstPenPointerdown\":null}") -> String {
        let id = clientId.map { ",\"clientId\":\"\($0)\"" } ?? ""
        return "{\"schema\":\"\(schema)\",\"source\":\"\(source)\"\(id),\"sentAt\":\"2026-10-03T14:05:09.123Z\",\"facts\":\(facts)}"
    }

    private func post(_ body: String, headers extra: [String: String] = [:], contentLength: Bool = true, remote: String = "192.168.1.40",
                      at seconds: Double = 1_791_036_309, store: TabletFactsStore, allowed: Set<String> = []) -> HTTPResponse {
        var headers = ["host": "192.168.1.10:7788", "content-type": "application/json"]
        if contentLength { headers["content-length"] = "\(body.utf8.count)" }
        for (k, v) in extra { headers[k] = v }
        let request = HTTPRequest(method: "POST", path: ApiRoutes.factsPath, headers: headers)
        return ApiRoutes.facts(request, body: Array(body.utf8), remoteAddress: remote, now: Date(timeIntervalSince1970: seconds), isAllowed: { allowed.contains($0) }, store: store)
    }

    private func text(_ r: HTTPResponse) -> String {
        return String(decoding: r.body, as: UTF8.self)
    }

    func testStoresAndAnswersWithTheKey() throws {
        let store = TabletFactsStore()
        let r = post(FactsRouteTests.body(), store: store, allowed: [FactsRouteTests.clientId])
        XCTAssertEqual(r.status, 200, text(r))
        let json = try JSONSerialization.jsonObject(with: Data(r.body)) as? [String: Any]
        XCTAssertEqual(json?["ok"] as? Bool, true)
        XCTAssertEqual(json?["key"] as? String, "web:\(FactsRouteTests.clientId)")
        XCTAssertEqual((json?["stored"] as? NSNumber)?.intValue, 1)
        XCTAssertTrue(r.headers.contains { $0.0 == "Content-Type" && $0.1 == "application/json" })
        let entry = try XCTUnwrap(store.all.first)
        XCTAssertTrue(entry.allowed, "clientId is an allowed tablet")
        XCTAssertEqual(entry.remoteAddress, "192.168.1.40")
        XCTAssertEqual(entry.receivedAt, Date(timeIntervalSince1970: 1_791_036_309))
        XCTAssertEqual(entry.sentAt, "2026-10-03T14:05:09.123Z")
        XCTAssertEqual(entry.facts["chromeVersion"], .string("141.0.7390.54"))
        XCTAssertEqual(entry.facts["devicePixelRatio"], .number(2))
        XCTAssertEqual(entry.facts["secureContext"], .bool(true), "a JSON boolean is not the number 1")
        XCTAssertEqual(entry.facts["firstPenPointerdown"], .null)
        XCTAssertEqual(store.diagnosticsLines(), ["tablet facts: web:\(FactsRouteTests.clientId) received 2026-10-03T14:05:09Z (4 facts)"])

        // Without a clientId the key is the remote address; an unknown sender is not allowed.
        let ink = post(FactsRouteTests.body(source: "ink", clientId: nil), remote: "192.168.1.41", at: 1_791_036_310, store: store)
        XCTAssertEqual(ink.status, 200)
        XCTAssertTrue(text(ink).contains("\"key\":\"ink:192.168.1.41\""), text(ink))
        XCTAssertTrue(text(ink).contains("\"stored\":2"))
        XCTAssertEqual(store.all.last?.allowed, false)
        // A charset parameter is fine.
        XCTAssertEqual(post(FactsRouteTests.body(), headers: ["content-type": "application/json; charset=UTF-8"], store: store).status, 200)
        // An Origin naming this server is fine.
        XCTAssertEqual(post(FactsRouteTests.body(), headers: ["origin": "http://192.168.1.10:7788"], store: store).status, 200)
    }

    func testBadBodiesAre400() {
        let store = TabletFactsStore()
        var tooMany = "{"
        for i in 0..<65 { tooMany += (i == 0 ? "" : ",") + "\"k\(i)\":\(i)" }
        tooMany += "}"
        let cases: [(String, String)] = [
            ("{\"schema\":", "not JSON"),
            ("[1,2]", "not a JSON object"),
            (FactsRouteTests.body(schema: "daylight-tablet-facts/2"), "wrong schema"),
            (FactsRouteTests.body(source: "ios"), "wrong source"),
            (FactsRouteTests.body(clientId: "not hex; drop table"), "bad clientId"),
            (FactsRouteTests.body(facts: "{\"viewport\":{\"w\":800}}"), "nested value viewport"),
            (FactsRouteTests.body(facts: "{\"list\":[1,2]}"), "nested value list"),
            (FactsRouteTests.body(facts: tooMany), "too many keys (65, at most 64)"),
            (FactsRouteTests.body(facts: "{\"userAgent\":\"\(String(repeating: "a", count: 1025))\"}"), "value too long userAgent"),
            (FactsRouteTests.body(facts: "\"flat\""), "facts is not an object"),
        ]
        for (body, reason) in cases {
            let r = post(body, store: store)
            XCTAssertEqual(r.status, 400, reason)
            XCTAssertEqual(text(r), "Bad facts: \(reason)")
        }
        XCTAssertEqual(post(FactsRouteTests.body(facts: "{\"userAgent\":\"\(String(repeating: "a", count: 1024))\"}"), store: store).status, 200, "1024 characters is the limit")
        XCTAssertEqual(store.count, 1, "nothing else was stored")
    }

    func testHeaderChecks() {
        let store = TabletFactsStore()
        let foreign = post(FactsRouteTests.body(), headers: ["origin": "http://evil.example"], store: store)
        XCTAssertEqual(foreign.status, 403)
        XCTAssertEqual(text(foreign), "Origin not allowed")
        let noLength = post(FactsRouteTests.body(), contentLength: false, store: store)
        XCTAssertEqual(noLength.status, 411)
        XCTAssertEqual(text(noLength), "Length required")
        XCTAssertEqual(post(FactsRouteTests.body(), headers: ["transfer-encoding": "chunked"], contentLength: false, store: store).status, 411)
        let large = post(FactsRouteTests.body(), headers: ["content-length": "16385"], store: store)
        XCTAssertEqual(large.status, 413)
        XCTAssertEqual(text(large), "Facts too large")
        let form = post(FactsRouteTests.body(), headers: ["content-type": "application/x-www-form-urlencoded"], store: store)
        XCTAssertEqual(form.status, 415)
        XCTAssertEqual(text(form), "Content-Type must be application/json")
        XCTAssertEqual(post(FactsRouteTests.body(), headers: ["content-type": "text/plain"], store: store).status, 415)
        XCTAssertEqual(post(FactsRouteTests.body(), headers: ["content-type": "application/json; charset=latin1"], store: store).status, 415)
        XCTAssertEqual(store.count, 0)
        var head = HTTPRequest(method: "POST", path: ApiRoutes.factsPath, headers: ["content-type": "application/json", "content-length": "16384"])
        XCTAssertEqual(ApiRoutes.factsHead(head), .read(16384))
        head.headers["content-length"] = "-1"
        XCTAssertEqual(ApiRoutes.factsHead(head), .reject(400, "Bad facts: bad Content-Length"))
    }

    /// Finder AF-3: the posted key goes into the 400 reason, which the listener logs; a newline in it forged log lines.
    func testReasonCarriesNoControlCharactersFromTheKey() {
        let nested = ApiRoutes.validateFacts(Array(FactsRouteTests.body(facts: "{\"a\\nfacts from 10.0.0.1: 200\":[1]}").utf8))
        XCTAssertEqual(nested, .failure(ApiRoutes.FactsError("nested value a?facts from 10.0.0.1: 200")))
        let long = String(repeating: "k", count: 100) + "\\r"
        let tooLong = ApiRoutes.validateFacts(Array(FactsRouteTests.body(facts: "{\"\(long)\":\"\(String(repeating: "a", count: 1025))\"}").utf8))
        XCTAssertEqual(tooLong, .failure(ApiRoutes.FactsError("value too long " + String(repeating: "k", count: 64))))
        let tab = ApiRoutes.validateFacts(Array(FactsRouteTests.body(facts: "{\"x\\ty\":{}}").utf8))
        XCTAssertEqual(tab, .failure(ApiRoutes.FactsError("nested value x?y")))
    }

    /// Finder AF-2: a Content-Length of digits too large for Int is above 16384, so 413 (PROTOCOL 15.2), not 400.
    func testHugeContentLengthIs413() {
        var head = HTTPRequest(method: "POST", path: ApiRoutes.factsPath, headers: ["content-type": "application/json"])
        head.headers["content-length"] = "99999999999999999999999"
        XCTAssertEqual(ApiRoutes.factsHead(head), .reject(413, "Facts too large"))
        head.headers["content-length"] = "9223372036854775808"
        XCTAssertEqual(ApiRoutes.factsHead(head), .reject(413, "Facts too large"))
        head.headers["content-length"] = "12abc"
        XCTAssertEqual(ApiRoutes.factsHead(head), .reject(400, "Bad facts: bad Content-Length"))
    }

    /// A body nested as deep as 16384 bytes allow answers 400 on a GCD worker thread (the listener's queue runs on
    /// one, with a smaller stack than the main thread) instead of taking the app down.
    func testDeeplyNestedBodyIs400() {
        let store = TabletFactsStore()
        let depth = 8000
        let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let body = FactsRouteTests.body(facts: "{\"deep\":\(nested)}")
        XCTAssertLessThanOrEqual(body.utf8.count, ApiRoutes.factsMaxBody)
        let done = expectation(description: "validated off the main thread")
        var status = 0
        DispatchQueue(label: "test.facts.deep").async {
            status = self.post(body, store: store).status
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(status, 400)
        XCTAssertEqual(store.count, 0)
    }

    func testSameKeyReplacesAndTheSeventeenthEvictsTheOldest() {
        let store = TabletFactsStore()
        XCTAssertEqual(post(FactsRouteTests.body(facts: "{\"a\":1}"), at: 100, store: store).status, 200)
        XCTAssertEqual(post(FactsRouteTests.body(facts: "{\"a\":2,\"b\":3}"), at: 101, store: store).status, 200)
        XCTAssertEqual(store.count, 1, "same key replaces")
        XCTAssertEqual(store.all.first?.facts["a"], .number(2))
        for i in 1...15 {
            let id = String(format: "%08x", i)
            XCTAssertEqual(post(FactsRouteTests.body(clientId: id), at: 200 + Double(i), store: store).status, 200)
        }
        XCTAssertEqual(store.count, 16)
        let seventeenth = post(FactsRouteTests.body(clientId: "ffffffff"), at: 400, store: store)
        XCTAssertTrue(text(seventeenth).contains("\"stored\":16"), text(seventeenth))
        XCTAssertEqual(store.count, 16)
        XCTAssertFalse(store.all.contains { $0.key == "web:\(FactsRouteTests.clientId)" }, "the oldest sender was evicted")
        XCTAssertTrue(store.all.contains { $0.key == "web:ffffffff" })
    }
}

/// The real listener on 127.0.0.1: the body read by Content-Length (also when it arrives after the head), 405 for
/// other methods, the header checks before any body.
final class FactsLoopbackTests: XCTestCase {
    private var server: WebServer!
    private let netQueue = DispatchQueue(label: "test.facts.net")
    private var port: UInt16 = 0
    private let store = TabletFactsStore()

    override func setUpWithError() throws {
        let config = WebServer.Config(webRoot: nil, apkURL: nil, preferredPort: 0, bonjourName: nil, loopbackOnly: true, scanPorts: false)
        server = WebServer(config: config, info: { ["version": "test"] }, queue: netQueue)
        server.factsStore = store
        server.factsAllowed = { $0 == FactsRouteTests.clientId }
        let ready = expectation(description: "listener ready")
        server.onReady = { [weak self] bound in
            self?.port = bound
            ready.fulfill()
        }
        server.start()
        wait(for: [ready], timeout: 5)
        XCTAssertNotEqual(port, 0)
    }

    override func tearDown() {
        server?.stop()
        netQueue.sync {}
        super.tearDown()
    }

    private func request(_ method: String, contentType: String? = "application/json", body: String? = nil) -> (status: Int, body: String)? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(ApiRoutes.factsPath)")!)
        request.httpMethod = method
        if let type = contentType { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        if let body = body { request.httpBody = Data(body.utf8) }
        let done = expectation(description: "\(method) /api/facts")
        var result: (Int, String)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                result = (http.statusCode, data.map { String(decoding: $0, as: UTF8.self) } ?? "")
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return result
    }

    func testPostOverLoopbackStores() throws {
        let posted = try XCTUnwrap(request("POST", body: FactsRouteTests.body()))
        XCTAssertEqual(posted.status, 200, posted.body)
        XCTAssertTrue(posted.body.contains("\"key\":\"web:\(FactsRouteTests.clientId)\""), posted.body)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.all.first?.allowed, true)
        XCTAssertEqual(store.all.first?.remoteAddress, "127.0.0.1")
        XCTAssertEqual(try XCTUnwrap(request("GET", contentType: nil)).status, 405)
        XCTAssertEqual(try XCTUnwrap(request("POST", contentType: "text/plain", body: FactsRouteTests.body())).status, 415)
        let bad = try XCTUnwrap(request("POST", body: "{nope"))
        XCTAssertEqual(bad.status, 400)
        XCTAssertEqual(bad.body, "Bad facts: not JSON")
        XCTAssertEqual(store.count, 1)
    }

    /// The head, then the body 300 ms later in two pieces: the listener waits without blocking its queue.
    func testBodyArrivingAfterTheHead() throws {
        let body = FactsRouteTests.body(source: "ink", clientId: nil)
        let head = "POST /api/facts HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        let bytes = Array(body.utf8)
        let half = bytes.count / 2
        let connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let rawQueue = DispatchQueue(label: "test.facts.raw")
        let received = Locked<[UInt8]>([])
        let closed = expectation(description: "response and close")
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data = data { received.withLock { $0.append(contentsOf: data) } }
                if error != nil || isComplete { closed.fulfill() } else { receive() }
            }
        }
        connection.start(queue: rawQueue)
        receive()
        defer { connection.cancel() }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        rawQueue.asyncAfter(deadline: .now() + 0.3) {
            connection.send(content: Data(bytes[0..<half]), completion: .contentProcessed { _ in })
        }
        // While the body is pending the listener still answers other requests.
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(try XCTUnwrap(request("GET", contentType: nil)).status, 405)
        rawQueue.asyncAfter(deadline: .now() + 0.5) {
            connection.send(content: Data(bytes[half...]), completion: .contentProcessed { _ in })
        }
        wait(for: [closed], timeout: 10)
        let response = String(decoding: received.withLock { $0 }, as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
        XCTAssertTrue(response.contains("\"key\":\"ink:127.0.0.1\""), response)
        XCTAssertEqual(store.count, 1)
    }

    /// Finder AF-1: a peer that never completes its request head (here half a facts head, then silence) is closed
    /// at the head deadline instead of holding the connection forever.
    func testIncompleteHeadIsClosedAtTheHeadDeadline() throws {
        var config = WebServer.Config(webRoot: nil, apkURL: nil, preferredPort: 0, bonjourName: nil, loopbackOnly: true, scanPorts: false)
        XCTAssertEqual(config.headTimeout, WebServer.headTimeout)
        XCTAssertEqual(WebServer.headTimeout, 10)
        config.headTimeout = 1
        let queue = DispatchQueue(label: "test.facts.head")
        let slow = WebServer(config: config, info: { ["version": "test"] }, queue: queue)
        slow.factsStore = TabletFactsStore()
        var slowPort: UInt16 = 0
        let ready = expectation(description: "listener ready")
        slow.onReady = { bound in
            slowPort = bound
            ready.fulfill()
        }
        slow.start()
        wait(for: [ready], timeout: 5)
        defer {
            slow.stop()
            queue.sync {}
        }
        let connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: slowPort)!, using: .tcp)
        let rawQueue = DispatchQueue(label: "test.facts.head.raw")
        let closed = expectation(description: "closed by the listener")
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, isComplete, error in
                if error != nil || isComplete { closed.fulfill() } else { receive() }
            }
        }
        connection.start(queue: rawQueue)
        receive()
        defer { connection.cancel() }
        connection.send(content: Data("POST /api/facts HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8), completion: .contentProcessed { _ in })
        let started = Date()
        wait(for: [closed], timeout: 6)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(queue.sync { slow.connectionCount }, 0, "the listener forgot the connection")
    }
}
