import DaylightKit
import Foundation

/// The byte pipe under an ink client: the real one wraps an `NWConnection` (WebServer), tests use a fake.
protocol InkTransport: AnyObject {
    /// Numeric remote address without port ("192.168.1.40", "127.0.0.1", "::1").
    var remoteAddress: String { get }
    var isLoopback: Bool { get }
    /// Sends raw bytes (already WebSocket-framed).
    func sendRaw(_ bytes: [UInt8])
    /// Tears the TCP connection down after the close frame went out.
    func closeTransport()
}

/// One WebSocket client of `/ink` (PROTOCOL section 8). Owned by the router on ink.queue; the server hands it bytes.
final class InkConnection {
    let id = UUID()
    let transport: InkTransport
    let openedAtNs: UInt64
    var identity: Identity?
    /// Scale from the client's declared canvas to ours (1200 / canvas_width, 1600 / canvas_height).
    var scale: (Double, Double) = (1, 1)
    var allowed = false
    var pending = false
    var denied = false
    var isActiveSource = false
    var openStrokeIDs: Set<UUID> = []
    var lastRxHostTimeNs: UInt64
    var lastStateSent: StateReport?
    var textFrameLogged = false
    var lengthMismatchLogged = false
    var loggedUnknownOpcodes: Set<UInt16> = []
    private(set) var isClosed = false
    /// Everything the connection sent, for tests (kept only when `recordOutgoing` is set).
    var recordOutgoing = false
    private(set) var outgoing: [Message] = []

    init(transport: InkTransport, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.transport = transport
        openedAtNs = nowNs
        lastRxHostTimeNs = nowNs
    }

    var remote: String { return transport.remoteAddress }
    var isLoopback: Bool { return transport.isLoopback }
    var label: String { return identity?.label ?? remote }
    var role: SolStream.Role? { return identity?.role }
    var clientID: String? { return identity?.clientID }

    /// The Mac's header clock: microseconds since the Unix epoch (PROTOCOL section 3).
    static func nowUs() -> UInt64 {
        return UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }

    func send(_ message: Message, timestampUs: UInt64 = InkConnection.nowUs()) {
        guard !isClosed else { return }
        if recordOutgoing { outgoing.append(message) }
        let payload = Codec.encode(message, timestampUs: timestampUs)
        transport.sendRaw(WebSocketFrame.encode(opcode: WebSocketFrame.opcodeBinary, payload: payload))
    }

    func sendState(_ report: StateReport) {
        lastStateSent = report
        send(.state(report))
    }

    func close(code: UInt16, reason: String) {
        guard !isClosed else { return }
        isClosed = true
        transport.sendRaw(WebSocketFrame.encodeClose(code: code, reason: reason))
        transport.closeTransport()
    }

    /// Marks the connection closed without sending anything (the peer went away).
    func markClosed() {
        isClosed = true
    }
}
