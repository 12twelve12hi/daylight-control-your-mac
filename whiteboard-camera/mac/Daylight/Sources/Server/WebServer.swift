import DaylightKit
import Foundation
import Network

/// One TCP listener (ARCHITECTURE section 5): static files, `/healthz`, `/api/info`, `/daylight-ink.apk`, and the
/// `/ink` WebSocket upgrade with a hand-written RFC 6455 frame loop. Ports 7788...7799 are tried in order when the
/// preferred one is busy (failure row 16); the Bonjour service is set before `start`. Everything runs on `queue`.
final class WebServer {
    static let defaultPort: UInt16 = SolStream.defaultPort
    static let portRange: ClosedRange<UInt16> = 7788...7799
    static let serviceType = SolStream.serviceType
    /// PROTOCOL 6.1: the HANDSHAKE must arrive within 5 s of the upgrade.
    static let handshakeTimeout: Double = 5
    /// PROTOCOL 1: 30 s without any frame closes the socket (1001).
    static let idleTimeout: Double = 30
    /// PROTOCOL 1: 2 MiB receive buffer per connection; exceeding it closes with 1009.
    static let maxFrame = WebSocketFrame.defaultMaxPayload
    static let receiveChunk = 65536

    struct Config {
        var webRoot: URL?
        var apkURL: URL?
        /// 0 means an ephemeral port (tests and the self-test).
        var preferredPort: UInt16 = WebServer.defaultPort
        /// nil means no Bonjour advertisement (tests and the self-test never touch the local network).
        var bonjourName: String?
        /// Bind 127.0.0.1 only (`--self-test` and tests).
        var loopbackOnly = false
        /// Try the next port up to 7799 when the preferred one is busy.
        var scanPorts = true

        init(webRoot: URL? = nil, apkURL: URL? = nil, preferredPort: UInt16 = WebServer.defaultPort, bonjourName: String? = nil, loopbackOnly: Bool = false, scanPorts: Bool = true) {
            self.webRoot = webRoot
            self.apkURL = apkURL
            self.preferredPort = preferredPort
            self.bonjourName = bonjourName
            self.loopbackOnly = loopbackOnly
            self.scanPorts = scanPorts
        }
    }

    enum State: Equatable {
        case idle
        case starting(UInt16)
        case ready(UInt16)
        case failed(String)
    }

    let config: Config
    let queue: DispatchQueue
    private let info: () -> [String: Any]
    private var listener: NWListener?
    private var attemptPort: UInt16
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private(set) var state: State = .idle
    private(set) var port: UInt16 = 0
    private(set) var bonjourRegisteredName: String?
    private let staticFiles: StaticFiles

    var onReady: ((UInt16) -> Void)?
    var onFailed: ((FailureText.Case, [String]) -> Void)?
    var onLog: ((String) -> Void)?
    /// A complete binary WebSocket message from an ink client: (connection, payload, host time ns). Called on `queue`.
    var onInkMessage: ((InkConnection, [UInt8], UInt64) -> Void)?
    var onInkClientOpened: ((InkConnection) -> Void)?
    var onInkClientClosed: ((InkConnection) -> Void)?

    init(config: Config, info: @escaping () -> [String: Any], queue: DispatchQueue) {
        self.config = config
        self.info = info
        self.queue = queue
        attemptPort = config.preferredPort
        staticFiles = StaticFiles(root: config.webRoot)
    }

    // MARK: Lifecycle

    func start() {
        queue.async { [weak self] in self?.startListener() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.shutdown(code: 1001, reason: "server shutting down") }
            self.connections.removeAll()
            self.state = .idle
        }
    }

    var connectionCount: Int { return connections.count }

    private func startListener() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.serviceClass = .interactiveVideo
        let newListener: NWListener
        do {
            if config.loopbackOnly {
                let portValue: NWEndpoint.Port = attemptPort == 0 ? .any : (NWEndpoint.Port(rawValue: attemptPort) ?? .any)
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: portValue)
                newListener = try NWListener(using: parameters)
            } else if attemptPort == 0 {
                newListener = try NWListener(using: parameters)
            } else {
                guard let portValue = NWEndpoint.Port(rawValue: attemptPort) else { throw WebServerError.badPort }
                newListener = try NWListener(using: parameters, on: portValue)
            }
        } catch {
            fail("NWListener init: \(error)")
            return
        }
        if let name = config.bonjourName, attemptPort != 0 {
            newListener.service = NWListener.Service(name: name, type: WebServer.serviceType, domain: nil, txtRecord: NWTXTRecord(["v": "1", "ws": "/ink", "port": "\(attemptPort)"]))
            newListener.serviceRegistrationUpdateHandler = { [weak self] change in
                guard let self = self else { return }
                if case let .add(endpoint) = change {
                    if case let .service(registered, _, _, _) = endpoint {
                        self.bonjourRegisteredName = registered
                        if registered != name {
                            self.onLog?(FailureText.logLine(.bonjourRenamed, ["\(endpoint)"]))
                        }
                    }
                    self.onLog?("bonjour registered \(endpoint)")
                }
            }
        }
        state = .starting(attemptPort)
        newListener.stateUpdateHandler = { [weak self, weak newListener] listenerState in
            guard let self = self, let current = newListener, current === self.listener else { return }
            switch listenerState {
            case .ready:
                let bound = current.port?.rawValue ?? self.attemptPort
                self.port = bound
                self.state = .ready(bound)
                self.onLog?("listening on \(bound)\(self.config.loopbackOnly ? " (loopback only)" : "")")
                self.onReady?(bound)
            case let .failed(error):
                self.portFailed("\(error)")
            case let .waiting(error):
                self.portFailed("\(error)")
            case .cancelled:
                break
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener = newListener
        newListener.start(queue: queue)
    }

    private func portFailed(_ reason: String) {
        onLog?(FailureText.logLine(.portInUse, [reason]))
        listener?.cancel()
        listener = nil
        if config.scanPorts && attemptPort != 0 && attemptPort < WebServer.portRange.upperBound {
            attemptPort += 1
            startListener()
        } else {
            fail(reason)
        }
    }

    private func fail(_ reason: String) {
        state = .failed(reason)
        onFailed?(.portInUse, ["\(config.preferredPort)"])
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let http = HTTPConnection(connection: connection, server: self)
        connections[ObjectIdentifier(http)] = http
        http.onClosed = { [weak self, weak http] in
            guard let self = self, let http = http else { return }
            self.connections[ObjectIdentifier(http)] = nil
        }
        http.start()
    }

    fileprivate func route(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            return HTTPResponse.text(405, "Method not allowed")
        }
        switch request.path {
        case "/healthz":
            return ApiRoutes.healthz()
        case "/api/info":
            var dictionary = info()
            if let host = request.headers["host"], let origin = WebServer.originFromHost(host) { dictionary["origin"] = origin }
            return ApiRoutes.info(dictionary)
        case ApiRoutes.apkPath:
            return ApiRoutes.apk(url: config.apkURL)
        default:
            return staticFiles.respond(path: request.path)
        }
    }

    /// The `/api/info` origin for this listener when the request carries no usable Host: the first address, or loopback.
    static func origin(port: UInt16) -> String {
        return LocalAddresses.primaryURL(port: port) ?? "http://127.0.0.1:\(port)"
    }

    /// The origin the tablet actually reached us at, from its Host header: SPEC 9.2 step 4 promises the exact string
    /// the page runs on, and a Wi-Fi tablet must not be told the Tailscale address. Only `host[:port]` characters pass
    /// (an IPv6 literal in brackets included); anything else falls back to `origin(port:)`.
    static func originFromHost(_ host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 255 else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]_")
        guard trimmed.allSatisfy({ allowed.contains($0) }) else { return nil }
        return "http://" + trimmed
    }
}

enum WebServerError: Error {
    case badPort
}

/// One accepted TCP connection: reads the HTTP head, answers or upgrades, then runs the WebSocket frame loop.
private final class HTTPConnection: InkTransport {
    private let connection: NWConnection
    private weak var server: WebServer?
    private var buffer: [UInt8] = []
    private var upgraded = false
    private var assembler = WebSocketMessageAssembler(maxMessage: WebServer.maxFrame)
    private var ink: InkConnection?
    private var handshakeDeadline: DispatchWorkItem?
    private var idleDeadline: DispatchWorkItem?
    private var sawHandshake = false
    private var closed = false
    var onClosed: (() -> Void)?

    let remoteAddress: String
    let isLoopback: Bool

    init(connection: NWConnection, server: WebServer) {
        self.connection = connection
        self.server = server
        let described = HTTPConnection.describe(connection.endpoint)
        remoteAddress = described
        isLoopback = HTTPConnection.isLoopbackAddress(described)
    }

    /// "192.168.1.40" from a `.hostPort` endpoint (interface suffixes such as `%en0` removed).
    static func describe(_ endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint {
            var text = "\(host)"
            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
            return text
        }
        return "\(endpoint)"
    }

    static func isLoopbackAddress(_ address: String) -> Bool {
        if address.hasPrefix("127.") { return true }
        if address == "::1" || address == "0:0:0:0:0:0:0:1" { return true }
        if address.lowercased().hasPrefix("::ffff:127.") { return true }
        return false
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        guard let queue = server?.queue else { return }
        connection.start(queue: queue)
        receiveHead()
    }

    // MARK: HTTP

    private func receiveHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: WebServer.receiveChunk) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data { self.buffer.append(contentsOf: data) }
            do {
                if let parsed = try HTTPRequest.parse(self.buffer) {
                    self.buffer.removeFirst(parsed.consumed)
                    self.handle(parsed.request)
                    return
                }
            } catch {
                self.respond(HTTPResponse.text(400, "Bad request"))
                return
            }
            if error != nil || isComplete {
                self.finish()
                return
            }
            self.receiveHead()
        }
    }

    private func handle(_ request: HTTPRequest) {
        guard let server = server else { finish(); return }
        if request.path == "/ink" && request.isWebSocketUpgrade {
            guard let key = request.webSocketKey, request.webSocketVersion == 13 else {
                respond(HTTPResponse(status: 426, headers: [("Sec-WebSocket-Version", "13"), ("Content-Type", "text/plain")], body: Array("Upgrade required".utf8)))
                return
            }
            let subprotocol = request.webSocketProtocols.contains(SolStream.subprotocol) ? SolStream.subprotocol : nil
            let response = HTTPRequest.upgradeResponse(accept: HTTPRequest.webSocketAccept(forKey: key), subprotocol: subprotocol)
            upgraded = true
            let ink = InkConnection(transport: self)
            self.ink = ink
            connection.send(content: Data(response), completion: .contentProcessed { [weak self] error in
                guard let self = self else { return }
                if error != nil { self.finish(); return }
                self.server?.onInkClientOpened?(ink)
                self.armHandshakeDeadline()
                self.armIdleDeadline()
                self.receiveFrames()
            })
            return
        }
        respond(server.route(request))
    }

    private func respond(_ response: HTTPResponse) {
        connection.send(content: Data(response.bytes()), completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    // MARK: WebSocket

    private func receiveFrames() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: WebServer.receiveChunk) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.closed else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
                self.armIdleDeadline()
            }
            if self.buffer.count > WebServer.maxFrame {
                self.closeSocket(code: 1009, reason: "frame too large")
                return
            }
            if !self.drainFrames() { return }
            if error != nil || isComplete {
                self.finish()
                return
            }
            self.receiveFrames()
        }
    }

    /// Returns false when the connection was closed while draining.
    private func drainFrames() -> Bool {
        while true {
            let parsed: (frame: WebSocketFrame, consumed: Int)?
            do {
                parsed = try WebSocketFrame.parse(&buffer, maxPayload: WebServer.maxFrame)
            } catch WebSocketError.oversize {
                closeSocket(code: 1009, reason: "frame too large")
                return false
            } catch {
                closeSocket(code: 1002, reason: "bad frame")
                return false
            }
            guard let next = parsed else { return true }
            let frame = next.frame
            buffer.removeFirst(next.consumed)
            let message: WebSocketFrame?
            do {
                message = try assembler.accept(frame)
            } catch WebSocketError.oversize {
                closeSocket(code: 1009, reason: "message too large")
                return false
            } catch {
                closeSocket(code: 1002, reason: "bad continuation")
                return false
            }
            guard let complete = message else { continue }
            switch complete.opcode {
            case WebSocketFrame.opcodeBinary:
                if !deliver(complete.payload) { return false }
            case WebSocketFrame.opcodeText:
                if let ink = ink, !ink.textFrameLogged {
                    ink.textFrameLogged = true
                    server?.onLog?("client \(remoteAddress) sent a text frame; ignored")
                }
            case WebSocketFrame.opcodePing:
                sendRaw(WebSocketFrame.encode(opcode: WebSocketFrame.opcodePong, payload: complete.payload))
            case WebSocketFrame.opcodeClose:
                sendRaw(WebSocketFrame.encode(opcode: WebSocketFrame.opcodeClose, payload: Array(complete.payload.prefix(2))))
                finish()
                return false
            default:
                break
            }
        }
    }

    /// One SolStream message. The header is checked here (net.queue); the full decode is the router's job.
    private func deliver(_ payload: [UInt8]) -> Bool {
        guard let ink = ink else { return true }
        let header: Header
        do {
            header = try payload.withUnsafeBytes { try Codec.decodeHeader($0) }
        } catch CodecError.limitExceeded {
            closeSocket(code: 1009, reason: "payload too large")
            return false
        } catch CodecError.badMagic, CodecError.badVersion {
            closeSocket(code: 1002, reason: "not a SolStream peer")
            return false
        } catch {
            if !ink.lengthMismatchLogged {
                ink.lengthMismatchLogged = true
                server?.onLog?("client \(remoteAddress): malformed header dropped (\(error))")
            }
            return true
        }
        if !sawHandshake {
            guard header.knownOpcode == .handshake else {
                closeSocket(code: 1002, reason: "handshake expected")
                return false
            }
            sawHandshake = true
            handshakeDeadline?.cancel()
            handshakeDeadline = nil
        }
        server?.onInkMessage?(ink, payload, DispatchTime.now().uptimeNanoseconds)
        return true
    }

    private func armHandshakeDeadline() {
        guard let queue = server?.queue else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.sawHandshake else { return }
            self.closeSocket(code: 1002, reason: "no handshake")
        }
        handshakeDeadline = work
        queue.asyncAfter(deadline: .now() + WebServer.handshakeTimeout, execute: work)
    }

    private func armIdleDeadline() {
        guard let queue = server?.queue else { return }
        idleDeadline?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.closeSocket(code: 1001, reason: "idle")
        }
        idleDeadline = work
        queue.asyncAfter(deadline: .now() + WebServer.idleTimeout, execute: work)
    }

    private func closeSocket(code: UInt16, reason: String) {
        guard !closed else { return }
        if let ink = ink {
            ink.close(code: code, reason: reason)
        } else {
            sendRaw(WebSocketFrame.encodeClose(code: code, reason: reason))
            closeTransport()
        }
    }

    fileprivate func shutdown(code: UInt16, reason: String) {
        if upgraded { closeSocket(code: code, reason: reason) } else { finish() }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        handshakeDeadline?.cancel()
        idleDeadline?.cancel()
        connection.cancel()
        if let ink = ink {
            ink.markClosed()
            server?.onInkClientClosed?(ink)
        }
        onClosed?()
    }

    // MARK: InkTransport

    func sendRaw(_ bytes: [UInt8]) {
        guard !closed else { return }
        connection.send(content: Data(bytes), completion: .idempotent)
    }

    func closeTransport() {
        // Let the close frame leave first, then tear down.
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }
}
