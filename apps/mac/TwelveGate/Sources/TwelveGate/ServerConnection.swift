import Foundation

/// WebSocket link to the Twelve server.
///
/// Sends `hello` when the socket opens, a protocol-level `ping` every 20 s,
/// and decodes `state` messages. Reconnects with exponential backoff
/// (1 s → 30 s) after any error or close. All callbacks run on the main thread.
final class ServerConnection: NSObject, URLSessionWebSocketDelegate {

    // MARK: - Public

    /// Called on the main thread with every decoded `state` message.
    var onState: ((StateSnapshot) -> Void)?

    /// Called on the main thread when the socket opens or drops.
    var onConnectionChange: ((Bool) -> Void)?

    private(set) var isConnected = false

    /// - Parameters:
    ///   - urlProvider: builds the socket URL (server URL + token). It is
    ///     called again before every connection attempt so a token written
    ///     after launch is picked up. Return nil when there is nothing to
    ///     connect to yet.
    init(urlProvider: @escaping () -> URL?, deviceId: String, version: String) {
        self.urlProvider = urlProvider
        self.deviceId = deviceId
        self.version = version
        super.init()
    }

    /// Opens the socket if it is not open already. Safe to call repeatedly.
    func connect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        if task != nil { return }
        guard let url = urlProvider() else {
            debugLog("TwelveGate: no server URL or pairing token yet, will retry")
            scheduleReconnect()
            return
        }
        let newTask = session.webSocketTask(with: url)
        task = newTask
        newTask.resume()
        receiveLoop(newTask)
    }

    /// Drops the current socket (if any) and connects again right away.
    func reconnect() {
        backoff = 1
        tearDown()
        connect()
    }

    /// Encodes and sends one message. Silently dropped while disconnected.
    func send(_ message: ClientMessage) {
        guard let task = task, isConnected else { return }
        let data: Data
        do {
            data = try message.encoded()
        } catch {
            debugLog("TwelveGate: could not encode message: \(error)")
            return
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error = error else { return }
            DispatchQueue.main.async {
                self?.handleFailure(task, "send failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private state

    private let urlProvider: () -> URL?
    private let deviceId: String
    private let version: String
    private lazy var session: URLSession = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: .main
    )
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var backoff: TimeInterval = 1
    private let maxBackoff: TimeInterval = 30
    private let pingInterval: TimeInterval = 20

    // MARK: - Lifecycle helpers

    /// Cancels the current task and timers. Notifies if we were connected.
    private func tearDown() {
        pingTimer?.invalidate()
        pingTimer = nil
        if let current = task {
            task = nil
            current.cancel(with: .goingAway, reason: nil)
        }
        if isConnected {
            isConnected = false
            onConnectionChange?(false)
        }
    }

    /// Handles any failure for `failed`. Ignored when it is not the live task,
    /// so the several callbacks one failure produces collapse into one.
    private func handleFailure(_ failed: URLSessionWebSocketTask, _ reason: String) {
        guard failed === task else { return }
        debugLog("TwelveGate: connection lost (\(reason))")
        tearDown()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        let delay = backoff
        backoff = min(backoff * 2, maxBackoff)
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.reconnectTimer = nil
            self?.connect()
        }
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            self?.send(.ping)
        }
    }

    // MARK: - Receiving

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, task === self.task else { return }
                switch result {
                case .failure(let error):
                    self.handleFailure(task, "receive failed: \(error.localizedDescription)")
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handle(text: text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handle(text: text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveLoop(task)
                }
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(ServerEnvelope.self, from: data) else {
            debugLog("TwelveGate: message without a type, ignored")
            return
        }
        switch envelope.type {
        case "state":
            do {
                let message = try decoder.decode(StateMessage.self, from: data)
                onState?(message.state)
            } catch {
                debugLog("TwelveGate: bad state message: \(error)")
            }
        case "pong":
            break
        case "error":
            if let message = try? decoder.decode(ErrorMessage.self, from: data) {
                debugLog("TwelveGate: server error \(message.code): \(message.message)")
            }
        default:
            // ai.message, ai.busy and anything newer are for the Daylight.
            break
        }
    }

    // MARK: - URLSessionWebSocketDelegate (delegateQueue is main)

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol proto: String?
    ) {
        guard webSocketTask === task else { return }
        isConnected = true
        backoff = 1
        debugLog("TwelveGate: connected")
        onConnectionChange?(true)
        send(.hello(deviceId: deviceId, version: version))
        startPing()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        handleFailure(webSocketTask, "closed with code \(closeCode.rawValue)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let webSocketTask = task as? URLSessionWebSocketTask else { return }
        handleFailure(webSocketTask, error?.localizedDescription ?? "completed")
    }

    // MARK: - Logging

    private func debugLog(_ message: String) {
        NSLog("%@", message)
    }
}
