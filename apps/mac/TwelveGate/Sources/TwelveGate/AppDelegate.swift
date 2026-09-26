import AppKit

// MARK: - Settings

/// Reads `~/.twelve/mac.json` (server URL) and `~/.twelve/config.json`
/// (pairing token, written by the server on the same machine).
enum Settings {

    static let defaultServerURL = "ws://127.0.0.1:7712/ws"

    private struct MacSettings: Decodable {
        let serverUrl: String?
    }

    private struct PairingConfig: Decodable {
        struct Pairing: Decodable {
            let token: String?
        }
        let pairing: Pairing?
    }

    static var twelveDirectory: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".twelve", isDirectory: true)
    }

    static func serverURLString() -> String {
        let file = twelveDirectory.appendingPathComponent("mac.json")
        if let data = try? Data(contentsOf: file),
           let settings = try? JSONDecoder().decode(MacSettings.self, from: data),
           let url = settings.serverUrl,
           !url.isEmpty {
            return url
        }
        return defaultServerURL
    }

    static func pairingToken() -> String {
        let file = twelveDirectory.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: file),
           let config = try? JSONDecoder().decode(PairingConfig.self, from: data),
           let token = config.pairing?.token {
            return token
        }
        return ""
    }

    /// `serverUrl + "?token=" + token`, or nil until the server has paired.
    static func webSocketURL() -> URL? {
        let token = pairingToken()
        guard !token.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
        let base = serverURLString()
        let separator = base.contains("?") ? "&" : "?"
        return URL(string: base + separator + "token=" + encoded)
    }

    /// The HTTP counterpart of the server URL, e.g. http://127.0.0.1:7712/pair
    static func httpURL(path: String) -> URL? {
        guard var components = URLComponents(string: serverURLString()) else { return nil }
        components.scheme = (components.scheme == "wss") ? "https" : "http"
        components.path = path
        components.query = nil
        return components.url
    }

    /// A stable per-install identifier for the `hello` message.
    static func deviceId() -> String {
        let key = "twelve.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    static func appVersion() -> String {
        return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: State

    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let nextCheckinItem = NSMenuItem(title: "Next check-in: —", action: nil, keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit TwelveGate", action: nil, keyEquivalent: "q")
    private var connection: ServerConnection?
    private var lockController: LockController?
    private var latestState: StateSnapshot?
    private var connected = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        let lock = LockController(holdSeconds: 30)
        let conn = ServerConnection(
            urlProvider: { Settings.webSocketURL() },
            deviceId: Settings.deviceId(),
            version: Settings.appVersion()
        )
        lock.send = { [weak conn] message in
            conn?.send(message)
        }
        conn.onState = { [weak self] state in
            self?.handleState(state)
        }
        conn.onConnectionChange = { [weak self] isConnected in
            self?.handleConnection(isConnected)
        }
        lockController = lock
        connection = conn
        lock.start()
        conn.connect()
        refreshMenu()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isLocked {
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: State handling

    /// True while the Quit rule must refuse: shield or allowlist mode and no
    /// emergency unlock in progress.
    private var isLocked: Bool {
        guard let state = latestState else { return false }
        return state.isLocked
    }

    private func handleState(_ state: StateSnapshot) {
        latestState = state
        lockController?.apply(state)
        refreshMenu()
    }

    private func handleConnection(_ isConnected: Bool) {
        connected = isConnected
        lockController?.setConnected(isConnected)
        refreshMenu()
    }

    // MARK: Menu

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "12"

        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        nextCheckinItem.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(nextCheckinItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Open Daylight pairing page", #selector(openPairing(_:))))
        menu.addItem(makeItem("Open dashboard", #selector(openDashboard(_:))))
        menu.addItem(makeItem("Reconnect", #selector(reconnectTapped(_:))))
        menu.addItem(NSMenuItem.separator())
        quitItem.target = self
        quitItem.action = #selector(quitTapped(_:))
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func refreshMenu() {
        let connectionText = connected ? "Connected" : "Reconnecting…"
        if let state = latestState {
            statusLine.title = "\(connectionText) · \(state.phase) · \(modeDescription(state))"
            if let next = state.nextCheckinAt {
                nextCheckinItem.title = "Next check-in: \(formatTime(next))"
            } else if let locks = state.checkinLocksAt {
                nextCheckinItem.title = "Check-in locks at \(formatTime(locks))"
            } else {
                nextCheckinItem.title = "Next check-in: —"
            }
        } else {
            statusLine.title = connectionText
            nextCheckinItem.title = "Next check-in: —"
        }
        quitItem.isEnabled = !isLocked
    }

    private func modeDescription(_ state: StateSnapshot) -> String {
        if state.isEmergencyActive { return "emergency unlock" }
        switch state.lockMode {
        case "shield": return "locked"
        case "allowlist": return "meeting mode"
        default: return "free"
        }
    }

    private func formatTime(_ unixMilliseconds: Double) -> String {
        return AppDelegate.timeFormatter.string(from: Date(timeIntervalSince1970: unixMilliseconds / 1000))
    }

    // MARK: Actions

    @objc private func openPairing(_ sender: Any?) {
        open(path: "/pair")
    }

    @objc private func openDashboard(_ sender: Any?) {
        open(path: "/")
    }

    @objc private func reconnectTapped(_ sender: Any?) {
        connection?.reconnect()
    }

    @objc private func quitTapped(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func open(path: String) {
        guard let url = Settings.httpURL(path: path) else { return }
        _ = NSWorkspace.shared.open(url)
    }
}
