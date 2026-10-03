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
        let label: String
        let address: String
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

    let settingsStore: SettingsStore
    let signed: Bool
    let version: String
    let build: String
    private var timer: Timer?
    private var nobodyTimer: Timer?
    private var failures: [String] = []
    private var launchedAt = Date()

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
        pending = snapshots.filter { $0.pending }.map { PendingClient(connectionID: $0.connectionID, label: $0.label, address: $0.address) }
        if !clients.isEmpty { nobodyConnectedYet = false }
    }

    func setPendingAllow(_ c: InkRouter.ClientSnapshot) {
        let item = PendingClient(connectionID: c.connectionID, label: c.label, address: c.address)
        if !pending.contains(item) { pending.append(item) }
        onAllowRequested?(item)
    }

    func setExtensionState(_ state: ExtensionState) {
        extensionState = state
    }

    func setSinkStatus(_ status: SinkStatus) {
        switch status {
        case .notInstalled: sinkStatusText = signed ? "extension not installed" : "unsigned build (preview only)"
        case .awaitingApproval: sinkStatusText = "waiting for approval"
        case .installed: sinkStatusText = "installed, sink not open"
        case .connected: sinkStatusText = "connected"
        case let .error(failure, detail): sinkStatusText = FailureText.sentence(failure, detail.isEmpty ? [] : [detail])
        }
    }

    func noteFailure(_ failure: FailureText.Case, _ args: [String]) {
        let text = FailureText.sentence(failure, args)
        let logLine = FailureText.logLine(failure, args)
        telemetry?.note("failure", logLine)
        if !text.isEmpty {
            failures.append(text)
            if failures.count > 20 { failures.removeFirst() }
            if failure == .saveFailed { lastSaveError = text } else { banner = text }
        }
        if failure == .noWebcam { cameraPresent = false }
    }

    func clearBanner() {
        banner = nil
    }

    func setCameraPresent(_ present: Bool) {
        cameraPresent = present
    }

    func noteSaved(_ urls: [URL]) {
        lastSaveError = nil
        telemetry?.note("save", "saved " + urls.map { $0.lastPathComponent }.joined(separator: ", "))
    }

    var recentFailures: [String] { return failures }

    // MARK: Actions (SPEC section 7)

    func pin() { pipeline?.post(.pin(-1)) }
    func clear() { router?.queue.async { [weak self] in self?.router?.clearRequested() } }
    func returnToCamera() { pipeline?.post(.returnNow) }
    func whiteboardNow(_ layout: LayoutStyle) { pipeline?.post(.layoutHotkey(layout)) }
    func engage() { pipeline?.post(.engage) }

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
        router?.queue.async { [weak self] in self?.router?.allow(connectionID: item.connectionID) }
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
        }
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
