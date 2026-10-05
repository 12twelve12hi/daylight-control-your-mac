import AppKit
import AVFoundation
import Combine
import DaylightKit
import Foundation

/// Main-thread mirror of the app's state for the menu, the panels and the windows (ARCHITECTURE 2.3): stats at 2 Hz,
/// governor, clients, pending Allow prompts, addresses. Actions fan out to the pipeline, the router and the server.
final class AppModel: ObservableObject {
    struct PendingClient: Equatable {
        let connectionID: UUID
        /// The tablet the prompt asks about; Allow is remembered by this id even after the socket closed.
        let clientID: String
        let role: String
        let label: String
        let address: String

        init(_ s: InkRouter.ClientSnapshot) {
            connectionID = s.connectionID
            clientID = s.clientID
            role = s.role
            label = s.label
            address = s.address
        }
    }

    struct ClientLine: Equatable {
        let label: String
        let role: String
        let address: String
        let allowed: Bool
        let active: Bool
        let pending: Bool
    }

    @Published private(set) var stats = PipelineStats()
    @Published private(set) var governor = GovernorOutput()
    @Published private(set) var clients: [ClientLine] = []
    @Published private(set) var pending: [PendingClient] = []
    @Published private(set) var addresses: [LocalAddresses.Entry] = []
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var serverState: WebServer.State = .idle
    @Published private(set) var extensionState: ExtensionState = .notInstalled
    @Published private(set) var sinkStatusText = "not connected"
    @Published private(set) var banner: String?
    @Published private(set) var lastSaveError: String?
    @Published private(set) var nobodyConnectedYet = false
    @Published private(set) var cameraPresent = true
    @Published var mirrorStatusText = "mirror mode not available in this build"
    /// Row 48: Overlay fell back to Studio Split; the menu shows its sentence until Overlay is toggled in Settings.
    @Published private(set) var overlayFellBack = false
    /// D40: the newest page PNG saved in this run ("Copy last page" falls back to it when the page is blank).
    @Published private(set) var lastSavedPNG: URL?

    let settingsStore: SettingsStore
    let signed: Bool
    let version: String
    let build: String
    private var timer: Timer?
    private var nobodyTimer: Timer?
    private var failures: [String] = []
    /// The failure whose sentence `banner` shows (nil for the USB setup text), so its resolution clears it.
    private var bannerCase: FailureText.Case?
    private var launchedAt = Date()
    private var settingsObserver: AnyCancellable?
    private var lastOverlayEnabled: Bool
    private var lastOverlayQuality: OverlayQuality
    /// Whether the pipeline holds an Overlay controller (OV-5); nil reads `pipeline?.overlayController`. A test seam.
    var overlayControllerProbe: (() -> Bool)?

    // Wired by AppDelegate.
    var pipeline: FramePipeline?
    var router: InkRouter?
    var server: WebServer?
    var registry: ClientRegistry?
    var mirror: MirrorControl?
    var preview: PreviewWindow?
    var telemetry: Telemetry?
    var onOpenSettings: (() -> Void)?
    var onOpenDiagnostics: (() -> Void)?
    var onSetupAgain: (() -> Void)?
    var onAllowRequested: ((PendingClient) -> Void)?

    static let nobodyConnectedSeconds: Double = 60

    init(settingsStore: SettingsStore, signed: Bool, version: String, build: String) {
        self.settingsStore = settingsStore
        self.signed = signed
        self.version = version
        self.build = build
        lastOverlayEnabled = settingsStore.settings.overlayEnabled
        lastOverlayQuality = settingsStore.settings.overlayQuality
        settingsObserver = settingsStore.$settings.sink { [weak self] settings in self?.overlaySettingMayHaveChanged(settings) }
    }

    /// Main thread (the store publishes on every Settings change). Toggling Overlay clears the row 48 menu line and
    /// tells `Hotkeys` to register or unregister the Overlay chord. A "Segmentation quality" change while Overlay is on
    /// resets an existing controller's fallback (`OverlayController.update`), so it clears the line too (Review 4
    /// OV-5); after a creation failure there is no controller and nothing is retried, so the line stays.
    private func overlaySettingMayHaveChanged(_ settings: Settings) {
        let qualityChanged = settings.overlayQuality != lastOverlayQuality
        lastOverlayQuality = settings.overlayQuality
        guard settings.overlayEnabled != lastOverlayEnabled else {
            if qualityChanged && settings.overlayEnabled && overlayControllerExists { overlayFellBack = false }
            return
        }
        lastOverlayEnabled = settings.overlayEnabled
        overlayFellBack = false
        NotificationCenter.default.post(name: Hotkeys.overlayEnabledChanged, object: nil, userInfo: ["enabled": settings.overlayEnabled])
    }

    private var overlayControllerExists: Bool {
        return overlayControllerProbe?() ?? (pipeline?.overlayController != nil)
    }

    /// The disabled menu line while Overlay has fallen back (row 48), nil otherwise.
    var overlayFallbackLine: String? {
        return overlayFellBack ? FailureText.sentence(.overlayFallback) : nil
    }

    var settings: Settings { return settingsStore.settings }

    // MARK: Lifecycle

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        nobodyTimer = Timer.scheduledTimer(withTimeInterval: AppModel.nobodyConnectedSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.clients.isEmpty && (self.registry?.all.isEmpty ?? true) {
                self.nobodyConnectedYet = true
                self.telemetry?.note("app", FailureText.logLine(.nobodyConnected))
            }
        }
    }

    func stop() {
        timer?.invalidate()
        nobodyTimer?.invalidate()
    }

    func refresh() {
        if let pipeline = pipeline {
            stats = pipeline.stats
            governor = pipeline.governorSnapshot
        }
        if let server = server {
            serverState = server.state
            port = server.port
        }
        addresses = LocalAddresses.list()
    }

    // MARK: Inputs from the router (main thread)

    func setClients(_ snapshots: [InkRouter.ClientSnapshot]) {
        clients = snapshots.map { ClientLine(label: $0.label, role: $0.role, address: $0.address, allowed: $0.allowed, active: $0.active, pending: $0.pending) }
        pending = snapshots.filter { $0.pending }.map { PendingClient($0) }
        if !clients.isEmpty { nobodyConnectedYet = false }
    }

    func setPendingAllow(_ c: InkRouter.ClientSnapshot) {
        let item = PendingClient(c)
        if !pending.contains(item) { pending.append(item) }
        onAllowRequested?(item)
    }

    func setExtensionState(_ state: ExtensionState) {
        extensionState = state
        resolveExtensionFailures(state)
    }

    func setSinkStatus(_ status: SinkStatus) {
        switch status {
        case .notInstalled: sinkStatusText = signed ? "extension not installed" : "unsigned build (preview only)"
        case .awaitingApproval: sinkStatusText = "waiting for approval"
        case .installed: sinkStatusText = "installed, sink not open"
        case .connected: sinkStatusText = "connected"
        case let .error(failure, detail): sinkStatusText = FailureText.sentence(failure, detail: detail)
        }
    }

    func noteFailure(_ failure: FailureText.Case, _ args: [String]) {
        let text = FailureText.sentence(failure, args)
        let logLine = FailureText.logLine(failure, args)
        telemetry?.note("failure", logLine)
        if !text.isEmpty {
            failures.append(text)
            if failures.count > 20 { failures.removeFirst() }
            // Row 16 is already the menu's port line (`portProblem`); a banner would say it twice.
            if failure == .saveFailed {
                lastSaveError = text
            } else if failure == .overlayFallback {
                // Row 48 has its own menu line (`overlayFallbackLine`); row 49 is for Diagnostics only.
                overlayFellBack = true
            } else if failure != .portInUse && failure != .overlayLowCoverage {
                banner = text
                bannerCase = failure
            }
        }
        if failure == .noWebcam { cameraPresent = false }
    }

    func clearBanner() {
        banner = nil
        bannerCase = nil
    }

    /// Clears the banner when the failure that set it is one of `cases` (the owner fixed it); a newer, unrelated
    /// banner stays.
    func resolve(_ cases: Set<FailureText.Case>) {
        guard let current = bannerCase, cases.contains(current) else { return }
        clearBanner()
    }

    /// Rows 6 to 12b end once the extension is installed; rows 13 and 14 once the sink is connected.
    static let extensionFailures: Set<FailureText.Case> = [
        .extensionMissingEntitlement, .extensionUnsupportedLocation, .extensionDamaged, .extensionSignatureInvalid,
        .extensionValidationFailed, .extensionForbiddenByPolicy, .extensionNeedsApproval, .extensionNeedsReboot,
    ]
    static let sinkFailures: Set<FailureText.Case> = [.sinkDeviceNotFound, .sinkStreamLayout]

    private func resolveExtensionFailures(_ state: ExtensionState) {
        switch state {
        case .installed: resolve(AppModel.extensionFailures)
        case .connected: resolve(AppModel.extensionFailures.union(AppModel.sinkFailures))
        default: break
        }
    }

    /// Row 3 is over: camera access was granted (the prompt, System Settings, or found granted at launch).
    func noteCameraGranted() {
        resolve([.cameraAccessDenied])
    }

    /// The banner as the menu shows it: nil when the same sentence is already on the status or port line.
    var visibleBanner: String? {
        guard let text = banner else { return nil }
        if sinkStatusText.contains(text) || (portProblem?.contains(text) ?? false) { return nil }
        return text
    }

    /// "Set up over USB" stopped on something that is not one of the adb rows (an install or grant that failed, a build
    /// without the APK): the menu shows the real reason instead of row 21's "Is USB debugging on?".
    func noteUSBSetupFailed(_ detail: String) {
        let text = AppModel.usbSetupFailedText(detail)
        telemetry?.note("failure", "usb setup: \(detail)")
        failures.append(text)
        if failures.count > 20 { failures.removeFirst() }
        banner = text
        bannerCase = nil
    }

    static func usbSetupFailedText(_ detail: String) -> String {
        return "Set up over USB failed: \(detail)"
    }

    func setCameraPresent(_ present: Bool) {
        cameraPresent = present
        if present { resolve([.noWebcam]) }
    }

    func noteSaved(_ urls: [URL]) {
        lastSaveError = nil
        if let png = urls.last(where: { $0.pathExtension == "png" }) { lastSavedPNG = png }
        telemetry?.note("save", "saved " + urls.map { $0.lastPathComponent }.joined(separator: ", "))
    }

    var recentFailures: [String] { return failures }

    // MARK: Actions (SPEC section 7)

    func pin() { pipeline?.post(.pin(-1)) }
    func clear() { router?.queue.async { [weak self] in self?.router?.clearRequested() } }
    func returnToCamera() { pipeline?.post(.returnNow) }
    /// Hotkeys W and D (SPEC 7, toggle semantics: the active layout's hotkey returns to the camera).
    func whiteboardNow(_ layout: LayoutStyle) { pipeline?.post(.layoutHotkey(layout)) }
    func engage() { pipeline?.post(.engage) }

    /// Menu "Whiteboard now (<layout>)" (SPEC 7: engage without drawing, never a toggle).
    func menuWhiteboardNow(_ layout: LayoutStyle) {
        guard let pipeline = pipeline else { return }
        pipeline.post(AppModel.whiteboardNowEvent(layout, snapshot: pipeline.governorSnapshot))
    }

    /// From the camera, or with the other layout showing, the layout event brings that layout up; with the chosen
    /// layout already up (LIVE, ENGAGING or RETURNING) `engage` only resets the idle timer or re-engages (SPEC D38),
    /// where `layoutHotkey` would start a return.
    static func whiteboardNowEvent(_ layout: LayoutStyle, snapshot: GovernorOutput) -> GovernorEvent {
        if snapshot.state == .passthrough || snapshot.layout != layout { return .layoutHotkey(layout) }
        return .engage
    }

    func hold(_ mode: HoldMode) {
        settingsStore.settings.holdMode = mode
        if mode == .camera { router?.queue.async { [weak self] in self?.router?.savePage(reason: .modeChanged) } }
        pipeline?.post(.hold(mode))
    }

    /// Writes the setting; `AppDelegate.applySettings` fans the change out to the pipeline, the router and the mirror.
    func setInkSource(_ source: InkSource) {
        guard source != settings.inkSource else { return }
        settingsStore.settings.inkSource = source
    }

    /// Called by the app once the setting changed (SPEC section 8: takes effect immediately, STATE tells the tablets).
    func applyInkSource(_ source: InkSource) {
        pipeline?.setInkSource(source)
        router?.queue.async { [weak self] in self?.router?.setActiveSource(source) }
        if source == .mirror { mirror?.start() } else { mirror?.stop() }
    }

    func allow(_ item: PendingClient) {
        pending.removeAll { $0 == item }
        router?.queue.async { [weak self] in self?.router?.allow(connectionID: item.connectionID, clientID: item.clientID, label: item.label, role: item.role, address: item.address) }
    }

    func deny(_ item: PendingClient) {
        pending.removeAll { $0 == item }
        router?.queue.async { [weak self] in self?.router?.deny(connectionID: item.connectionID) }
    }

    func forget(id: String) {
        registry?.forget(id: id)
    }

    func hotkey(_ action: HotkeyAction) {
        switch action {
        case .whiteboardOnly: whiteboardNow(.whiteboardOnly)
        case .studioSplit: whiteboardNow(.studioSplit)
        case .keep: pin()
        case .clear: clear()
        case .camera: returnToCamera()
        case .overlay:
            if settings.overlayEnabled { whiteboardNow(.overlay) }
        }
    }

    // MARK: The board as the follow-up (D40, D41)

    /// Menu "Copy last page" is enabled: the current page has ink, or a page was saved in this run. Asks ink.queue
    /// synchronously (main never waits on anything that waits on main there, like `saveOnQuit`).
    var canCopyLastPage: Bool {
        if lastSavedPNG != nil { return true }
        guard let router = router else { return false }
        return router.queue.sync { router.pageHasInk }
    }

    /// Menu "Copy last page" and Ctrl+Opt+Cmd+P: the current page (rendered from the stroke model) or else the last
    /// saved page as PNG on `pasteboard`. `completion` runs on main with whether anything was copied.
    func copyLastPage(to pasteboard: NSPasteboard = .general, completion: ((Bool) -> Void)? = nil) {
        let fallback = lastSavedPNG
        let telemetry = self.telemetry
        let finish: (StrokeStore?) -> Void = { snapshot in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = LastPage.pngData(snapshot: snapshot, fallback: fallback)
                DispatchQueue.main.async {
                    var copied = false
                    if let data = data { copied = LastPage.put(data, on: pasteboard) }
                    telemetry?.note("app", copied ? "copy last page: \(data?.count ?? 0) bytes" : "copy last page: nothing to copy")
                    completion?(copied)
                }
            }
        }
        if let router = router {
            router.queue.async { finish(router.currentPageSnapshot()) }
        } else {
            finish(nil)
        }
    }

    /// Menu "Send today's board...": writes the current session's PDF if one is due, then decides what to send
    /// (`AppModel.boardToSend`); `completion` runs on main.
    func prepareBoardToSend(completion: @escaping (SessionHandout.SendChoice) -> Void) {
        let root = router?.saver?.root ?? (settings.saveDirectory ?? SessionSaver.defaultRoot())
        let calendar = router?.saver?.calendar ?? Calendar(identifier: .gregorian)
        let decide: () -> Void = {
            DispatchQueue.main.async { completion(AppModel.boardToSend(root: root, today: Date(), calendar: calendar)) }
        }
        if let router = router {
            router.queue.async { router.writeCurrentSessionPDF { _ in decide() } }
        } else {
            decide()
        }
    }

    /// The PDF to share, or the sentence to show (`SessionHandout.boardToSend` over the real folders).
    static func boardToSend(root: URL, today: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> SessionHandout.SendChoice {
        return SessionHandout.boardToSend(root: root, today: today, calendar: calendar, list: { url in
            try? FileManager.default.contentsOfDirectory(atPath: url.path)
        })
    }

    /// "Open http://100.x.y.z:7788 on your Daylight" lines (SPEC 9.2 step 1).
    var addressLines: [String] {
        let p = port == 0 ? settings.port : port
        var lines = addresses.map { "Open http://\($0.ip):\(p) on your Daylight" + ($0.kind == .tailscale ? " (Tailscale)" : "") }
        lines.append("http://\(LocalAddresses.hostname()).local:\(p) may also work on Wi-Fi")
        return lines
    }

    var portProblem: String? {
        switch serverState {
        case let .failed(reason):
            return FailureText.sentence(.portInUse, ["\(settings.port)"]) + " (\(reason))"
        case let .ready(bound) where bound != settings.port && settings.port != 0:
            return FailureText.sentence(.portInUse, ["\(settings.port)", "\(bound)"])
        default:
            return nil
        }
    }

    var cameras: [AVCaptureDevice] { return WebcamCapture.cameras() }
}
