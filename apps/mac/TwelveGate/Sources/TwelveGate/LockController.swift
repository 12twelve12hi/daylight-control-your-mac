import AppKit

/// Turns each StateSnapshot into windows and system presentation options.
///
/// - `shield`: one ShieldWindow per display at the shielding window level,
///   kiosk presentation options, re-activation whenever another app comes
///   forward, plus a 2 s backstop.
/// - `allowlist`: a floating HUD; apps not on the allowlist get hidden.
/// - `free`: nothing.
/// - `banner`: a floating countdown panel, independent of the lock mode.
///
/// Everything here runs on the main thread.
final class LockController {

    // MARK: - Public

    /// Sends a message to the server. Wired by the AppDelegate.
    var send: ((ClientMessage) -> Void)?

    /// The lock mode currently enforced: "shield", "allowlist" or "free".
    private(set) var effectiveMode = "free"

    init(holdSeconds: Int = 30) {
        self.holdSeconds = holdSeconds
    }

    deinit {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        backstopTimer?.invalidate()
    }

    /// Installs the screen and app-activation observers. Call once.
    func start() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screensChanged()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.appActivated(app)
        }
    }

    /// Applies a snapshot. The server already sends `lockMode: free` during an
    /// emergency unlock; the check here only guards against a stale snapshot.
    func apply(_ state: StateSnapshot) {
        latest = state
        let mode = state.isEmergencyActive ? "free" : state.lockMode
        switch mode {
        case "shield":
            effectiveMode = "shield"
            enterShield(state)
        case "allowlist":
            effectiveMode = "allowlist"
            enterAllowlist(state)
        default:
            effectiveMode = "free"
            enterFree()
        }
        updateBanner(state.banner)
        updateBackstop()
    }

    /// Mirrors the socket status on the shields.
    func setConnected(_ connected: Bool) {
        self.connected = connected
        for shield in shields {
            shield.setConnected(connected)
        }
    }

    // MARK: - Private state

    private let holdSeconds: Int
    private var latest: StateSnapshot?
    private var connected = false
    private var shields: [ShieldWindow] = []
    private var hud: HUDPanel?
    private var banner: BannerPanel?
    private var backstopTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    /// Apple's documented kiosk combination. Other mixes raise an exception.
    private let kioskOptions: NSApplication.PresentationOptions = [
        .hideDock,
        .hideMenuBar,
        .disableAppleMenu,
        .disableProcessSwitching,
        .disableForceQuit,
        .disableSessionTermination,
        .disableHideApplication
    ]

    private var ownPid: Int32 {
        return ProcessInfo.processInfo.processIdentifier
    }

    // MARK: - Shield mode

    private func enterShield(_ state: StateSnapshot) {
        removeHUD()
        _ = NSApp.setActivationPolicy(.regular)
        if shields.isEmpty {
            buildShields()
        }
        for shield in shields {
            shield.apply(state: state, connected: connected)
        }
        applyKioskOptions()
        bringShieldsFront()
    }

    private func buildShields() {
        for screen in NSScreen.screens {
            let shield = ShieldWindow(screen: screen, holdSeconds: holdSeconds)
            shield.onEmergencyUnlock = { [weak self] reason in
                self?.send?(.emergencyUnlock(reason: reason))
            }
            shields.append(shield)
        }
    }

    private func removeShields() {
        let old = shields
        shields = []
        for shield in old {
            shield.close()
        }
    }

    private func applyKioskOptions() {
        if NSApp.presentationOptions != kioskOptions {
            NSApp.presentationOptions = kioskOptions
        }
    }

    private func clearKioskOptions() {
        if NSApp.presentationOptions != [] {
            NSApp.presentationOptions = []
        }
    }

    /// Activates the app and orders every shield to the front. Only makes the
    /// primary shield key when no shield is key, so typing a reason on a
    /// secondary display is not interrupted.
    private func bringShieldsFront() {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        for shield in shields {
            shield.orderFrontRegardless()
        }
        let hasKey = shields.contains { $0.isKeyWindow }
        if !hasKey {
            shields.first?.makeKeyAndOrderFront(nil)
        }
    }

    private func screensChanged() {
        banner?.reposition()
        hud?.reposition()
        guard effectiveMode == "shield", let state = latest else { return }
        removeShields()
        buildShields()
        for shield in shields {
            shield.apply(state: state, connected: connected)
        }
        bringShieldsFront()
    }

    // MARK: - Allowlist mode

    private func enterAllowlist(_ state: StateSnapshot) {
        removeShields()
        clearKioskOptions()
        _ = NSApp.setActivationPolicy(.accessory)
        if hud == nil {
            hud = HUDPanel()
        }
        hud?.apply(meetingTitle: state.meeting?.title)
        hud?.orderFrontRegardless()
        if let front = NSWorkspace.shared.frontmostApplication {
            enforceAllowlist(front)
        }
    }

    private func removeHUD() {
        hud?.close()
        hud = nil
    }

    /// Hides `app` when it is a regular app that is neither us nor allowlisted.
    private func enforceAllowlist(_ app: NSRunningApplication) {
        guard effectiveMode == "allowlist" else { return }
        if app.processIdentifier == ownPid { return }
        guard app.activationPolicy == .regular else { return }
        let bundleId = app.bundleIdentifier ?? ""
        let allowed = latest?.allowlist ?? []
        if allowed.contains(bundleId) { return }
        let name = app.localizedName ?? bundleId
        _ = app.hide()
        hud?.flash("\(name) is not on the meeting allowlist")
    }

    private func reportForeground(_ app: NSRunningApplication) {
        guard let bundleId = app.bundleIdentifier else { return }
        send?(.macForeground(bundleId: bundleId, name: app.localizedName ?? bundleId))
    }

    // MARK: - Free mode

    private func enterFree() {
        removeShields()
        removeHUD()
        clearKioskOptions()
        _ = NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - App activation

    private func appActivated(_ app: NSRunningApplication) {
        if app.processIdentifier == ownPid { return }
        switch effectiveMode {
        case "shield":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self, self.effectiveMode == "shield" else { return }
                self.applyKioskOptions()
                self.bringShieldsFront()
            }
        case "allowlist":
            reportForeground(app)
            enforceAllowlist(app)
        default:
            break
        }
    }

    // MARK: - Backstop timer

    private func updateBackstop() {
        if effectiveMode == "free" {
            backstopTimer?.invalidate()
            backstopTimer = nil
            return
        }
        if backstopTimer != nil { return }
        backstopTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.backstopTick()
        }
    }

    private func backstopTick() {
        switch effectiveMode {
        case "shield":
            applyKioskOptions()
            bringShieldsFront()
        case "allowlist":
            if let front = NSWorkspace.shared.frontmostApplication {
                enforceAllowlist(front)
            }
        default:
            break
        }
    }

    // MARK: - Banner

    private func updateBanner(_ info: BannerInfo?) {
        guard let info = info else {
            banner?.close()
            banner = nil
            return
        }
        if banner == nil {
            let panel = BannerPanel()
            panel.onSnooze = { [weak self] in
                self?.send?(.checkinSnooze)
            }
            banner = panel
        }
        banner?.apply(info)
        banner?.orderFrontRegardless()
    }
}
