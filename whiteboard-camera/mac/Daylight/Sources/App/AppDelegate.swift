import AppKit
import AVFoundation
import DaylightKit
import Foundation

/// Wires the app (IMPLEMENTATION-PLAN 5): sink, pipeline, server, router, saver, hotkeys, menu, preview, onboarding,
/// Allow panel, Settings and Diagnostics. The only place that knows `NSStatusItem`, the camera components and the
/// mirror facade. Under `xcodebuild test` (hosted bundle) nothing that touches the camera or the network is started.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let quitSaveTimeout: Double = 2

    let arguments: LaunchArguments
    let signed: Bool
    let telemetry: Telemetry
    let settingsStore: SettingsStore
    let model: AppModel
    let ioQueue = DispatchQueue(label: "com.twelve.daylight.io", qos: .utility)
    let netQueue = DispatchQueue(label: "com.twelve.daylight.net", qos: .userInitiated)
    let inkQueue = DispatchQueue(label: "com.twelve.daylight.ink", qos: .userInitiated)
    private let preview = PreviewWindow()
    private let settingsContext = SettingsContext()
    private let onboardingModel: OnboardingModel
    private var sink: VirtualCameraSink?
    private var pipeline: FramePipeline?
    private var server: WebServer?
    private var router: InkRouter?
    private var registry: ClientRegistry?
    private var saver: SessionSaver?
    private var rasterizer: InkRasterizer?
    private var hotkeys: Hotkeys?
    private var menuBar: MenuBar?
    private var allowPanel: AllowClientPanel?
    private var onboarding: OnboardingWindowController?
    private var settingsWindow: SettingsWindowController?
    private var diagnostics: DiagnosticsWindowController?
    /// Component F's `MirrorController` (ARCHITECTURE 18, "B's `AppDelegate` wiring"); `mirrorController` is the same
    /// object with its concrete members (`serverPort`, `updateSettings`) for the few places that need them.
    private var mirror: MirrorControl?
    private var mirrorController: MirrorController?
    /// Component C: the camera extension installer and the queue the sink client runs on.
    private var installer: ExtensionInstaller?
    private var installerStatus: ExtensionInstaller.Status = .unknown
    private let cameraQueue = DispatchQueue(label: "com.twelve.daylight.camera", qos: .userInitiated)
    private var mirrorSessionStart: Date?
    private var lastApplied: Settings
    private var onboardingTimer: Timer?

    init(arguments: LaunchArguments) {
        self.arguments = arguments
        let bundle = Bundle.main
        signed = (bundle.object(forInfoDictionaryKey: "DaylightBuildSigned") as? Bool) ?? false
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        settingsStore = SettingsStore(unsignedBuild: !signed)
        telemetry = Telemetry(perfLog: arguments.perfLog || settingsStore.settings.perfLog)
        model = AppModel(settingsStore: settingsStore, signed: signed, version: version, build: build)
        onboardingModel = OnboardingModel(inputs: OnboardingSteps.Inputs(bundlePath: bundle.bundlePath, signed: signed))
        lastApplied = settingsStore.settings
        super.init()
    }

    /// True inside the hosted DaylightTests bundle: the tests build their own pipelines and servers.
    static var isUnderTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        telemetry.note("app", "Daylight \(model.version) (\(model.build)) signed=\(signed) path=\(Bundle.main.bundlePath)")
        if OnboardingSteps.locationProblem(bundlePath: Bundle.main.bundlePath) {
            telemetry.note("app", FailureText.logLine(.notInApplications, [Bundle.main.bundlePath]))
        }
        if !signed { telemetry.note("app", FailureText.logLine(.unsignedBuild)) }
        model.telemetry = telemetry
        model.preview = preview
        menuBar = MenuBar(model: model)
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        model.onOpenDiagnostics = { [weak self] in self?.showDiagnostics() }
        model.onSetupAgain = { [weak self] in self?.showOnboarding(force: true) }
        model.onAllowRequested = { [weak self] item in self?.showAllowPanel(for: item) }
        if AppDelegate.isUnderTest {
            telemetry.note("app", "hosted test run: pipeline, server and camera are not started")
            model.start()
            return
        }
        wirePipeline()
        wireInstaller()
        wireMirror()
        wireInkPath()
        wireServer()
        wireHotkeys()
        wireSettings()
        model.start()
        preview.floats = settingsStore.settings.previewFloats
        if settingsStore.settings.previewOnLaunch || !signed { preview.show() }
        startCaptureIfAuthorized()
        if !settingsStore.settings.onboardingDone { showOnboarding(force: false) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        router?.stopAutosave()
        router?.saveOnQuit(timeout: AppDelegate.quitSaveTimeout)
        saveMirrorSessionIfNeeded()
        saver?.waitUntilIdle(timeout: AppDelegate.quitSaveTimeout)
        hotkeys?.unregisterAll()
        server?.stop()
        pipeline?.shutdown()
        // After the pipeline (no more pushes): stop the sink stream so the extension shows its card (SPEC 4).
        (sink as? CMIOSinkClient)?.stopAndWait(timeout: 0.5)
        mirror?.stop()
        model.stop()
        return .terminateNow
    }

    // MARK: Sink and installer (component C)

    /// `signed ? CMIOSinkClient : PreviewOnlySink` (IMPLEMENTATION-PLAN 3.2, C handoff request 2). The UUIDs come from
    /// the Info.plist keys `project.yml` writes into both bundles; a signed build without them falls back to the preview.
    private func makeSink() -> VirtualCameraSink {
        guard signed else { return PreviewOnlySink() }
        let bundle = Bundle.main
        guard let deviceString = bundle.object(forInfoDictionaryKey: "DaylightCameraDeviceUUID") as? String,
              let sinkString = bundle.object(forInfoDictionaryKey: "DaylightCameraSinkUUID") as? String,
              let deviceUUID = UUID(uuidString: deviceString),
              let sinkUUID = UUID(uuidString: sinkString) else {
            telemetry.note("camera", "Info.plist lacks DaylightCameraDeviceUUID or DaylightCameraSinkUUID; preview-only sink")
            return PreviewOnlySink()
        }
        return CMIOSinkClient(deviceUUID: deviceUUID, sinkUUID: sinkUUID, queue: cameraQueue)
    }

    /// Submits the activation request as early as possible (SPEC 13.3 rows 6 to 12b). Delegate callbacks arrive on
    /// the main queue; the status is forwarded to the sink client (row 13 wording) and to the onboarding step.
    private func wireInstaller() {
        let installer = ExtensionInstaller()
        self.installer = installer
        installer.onChange = { [weak self] status in
            DispatchQueue.main.async { self?.installerChanged(status) }
        }
        installer.activate()
    }

    private func installerChanged(_ status: ExtensionInstaller.Status) {
        installerStatus = status
        (sink as? CMIOSinkClient)?.noteExtensionStatus(status)
        if let failure = ExtensionInstaller.failure(for: status) {
            model.noteFailure(failure.0, failure.1)
        }
        if let sink = sink { sinkStatusChanged(sink.status) }
    }

    /// The onboarding step from the installer's view and the sink's view: connected wins, then what the installer
    /// said (C handoff request 2 mapping), then the sink status alone.
    static func extensionState(signed: Bool, installer: ExtensionInstaller.Status, sink: SinkStatus, bundlePath: String) -> ExtensionState {
        if !signed { return .unsignedBuild }
        if case .connected = sink { return .connected }
        switch installer {
        case .needsApproval: return .awaitingApproval
        case .activating: return .activating
        case .installed: return .installed
        case .needsReboot: return .needsReboot
        case let .failed(code, message): return .failed(ExtensionInstaller.failureCase(for: code) ?? .extensionDamaged, message)
        case .notInApplications: return .failed(.notInApplications, bundlePath)
        case .unsignedBuild: return .unsignedBuild
        case .unknown, .notInstalled:
            switch sink {
            case .notInstalled: return .notInstalled
            case .awaitingApproval: return .awaitingApproval
            case .installed: return .installed
            case .connected: return .connected
            case let .error(failure, detail): return .failed(failure, detail)
            }
        }
    }

    // MARK: Mirror (component F)

    /// Constructs the facade (F handoff request 1): the pipeline samples `mirror.source`, pen events reach the
    /// governor through `post`, status and failures hop to main. Started only while the ink source is Mirror.
    private func wireMirror() {
        guard let pipeline = pipeline else { return }
        let vendor = Bundle.main.resourceURL?.appendingPathComponent("Vendor")
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Vendor")
        let controlQueue = DispatchQueue(label: "com.twelve.daylight.mirror.control", qos: .userInitiated)
        let mirror = MirrorController(settings: settingsStore.settings, vendorDirectory: vendor, pipeline: pipeline, queue: controlQueue)
        mirror.onLog = { [weak self] line in self?.telemetry.note("mirror", line) }
        mirror.onFailure = { [weak self] failure, args in
            DispatchQueue.main.async { self?.model.noteFailure(failure, args) }
        }
        mirror.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.model.mirrorStatusText = MirrorController.describe(status)
                var mirroring = false
                if case .mirroring = status { mirroring = true }
                self?.settingsContext.mirrorAvailable = mirroring
            }
        }
        mirror.source.onGovernorEvent = { [weak pipeline] event in pipeline?.post(event) }
        pipeline.setMirrorSource(mirror.source)
        mirrorController = mirror
        self.mirror = mirror
        model.mirror = mirror
        model.mirrorStatusText = MirrorController.describe(mirror.status)
        if settingsStore.settings.inkSource == .mirror { mirror.start() }
    }

    // MARK: Pipeline

    private func wirePipeline() {
        // The capture must never pick the app's own virtual camera (a feedback loop); its uniqueID is the fixed UUID.
        if let ownUUID = Bundle.main.object(forInfoDictionaryKey: "DaylightCameraDeviceUUID") as? String {
            WebcamCapture.excludeOwnCamera(uniqueID: ownUUID)
        }
        let sink = makeSink()
        self.sink = sink
        let pipeline: FramePipeline
        do {
            pipeline = try FramePipeline(sink: sink, settings: settingsStore.settings, telemetry: telemetry, capture: nil)
        } catch {
            telemetry.note("pipeline", "could not start: \(error)")
            model.noteFailure(.noWebcam, [])
            return
        }
        self.pipeline = pipeline
        model.pipeline = pipeline
        pipeline.latencyProbe = arguments.latencyProbe
        // Row 3 before anything else: the idle rule may want capture at once (sink not connected), and a denied
        // AVCaptureDeviceInput must not read as "No camera found". `startCaptureIfAuthorized` opens the gate.
        pipeline.setCaptureAuthorized(AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
        let capture = WebcamCapture(queue: pipeline.captureQueue)
        capture.preferredUniqueID = settingsStore.settings.cameraUniqueID
        capture.onLog = { [weak self] line in self?.telemetry.note("capture", line) }
        pipeline.setCaptureSource(capture)
        pipeline.onPreviewFrame = { [weak self] buffer in self?.preview.display(buffer) }
        pipeline.onFailure = { [weak self] failure, args in
            DispatchQueue.main.async { self?.model.noteFailure(failure, args) }
        }
        pipeline.onCameraPresence = { [weak self] present in
            DispatchQueue.main.async {
                self?.model.setCameraPresent(present)
                self?.menuBar?.updateIcon()
                self?.preview.setOverlayText(present ? "" : FailureText.sentence(.noWebcam))
            }
        }
        pipeline.onStateChanged = { [weak self] from, to in
            DispatchQueue.main.async { self?.governorChanged(from: from, to: to) }
        }
        preview.onVisibility = { [weak pipeline] visible in pipeline?.setPreviewVisible(visible) }
        sink.onStatusChange = { [weak self] status in
            DispatchQueue.main.async { self?.sinkStatusChanged(status) }
        }
        sink.onViewerCount = { [weak pipeline] count in pipeline?.setViewerCount(count) }
        sinkStatusChanged(sink.status)
        sink.start()
    }

    private func startCaptureIfAuthorized() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            onboardingModel.inputs.camera = .granted
            pipeline?.setCaptureAuthorized(true)
            pipeline?.start()
        case .denied, .restricted:
            onboardingModel.inputs.camera = .denied
            model.noteFailure(.cameraAccessDenied, [])
        case .notDetermined:
            onboardingModel.inputs.camera = .notDetermined
            if settingsStore.settings.onboardingDone { requestCameraAccess() }
        @unknown default:
            pipeline?.setCaptureAuthorized(true)
            pipeline?.start()
        }
    }

    /// The TCC status as the onboarding row sees it.
    static func cameraPermission(_ status: AVAuthorizationStatus) -> CameraPermission {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .granted
        }
    }

    private func requestCameraAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.onboardingModel.inputs.camera = granted ? .granted : .denied
                if granted {
                    self.pipeline?.setCaptureAuthorized(true)
                    self.pipeline?.start()
                } else {
                    self.model.noteFailure(.cameraAccessDenied, [])
                }
            }
        }
    }

    private func sinkStatusChanged(_ status: SinkStatus) {
        model.setSinkStatus(status)
        var connected = false
        if case .connected = status { connected = true }
        pipeline?.setSinkConnected(connected)
        let state = AppDelegate.extensionState(signed: signed, installer: installerStatus, sink: status, bundlePath: Bundle.main.bundlePath)
        model.setExtensionState(state)
        onboardingModel.inputs.extensionState = state
        onboardingModel.inputs.sinkFollowUpDue = CMIOSinkClient.followUpDue(status)
    }

    private func governorChanged(from: GovernorState, to: GovernorState) {
        if from == .passthrough && to == .engaging && settingsStore.settings.inkSource == .mirror {
            mirrorSessionStart = Date()
        }
        if to == .passthrough { saveMirrorSessionIfNeeded() }
    }

    /// Mirror mode writes `mirror-<HH-mm-ss>.png` at session end (SPEC 12, ARCHITECTURE 6 item 10).
    private func saveMirrorSessionIfNeeded() {
        guard let start = mirrorSessionStart, let mirror = mirror, let saver = saver else { return }
        mirrorSessionStart = nil
        guard let frame = mirror.latestFrameForSave() else { return }
        saver.saveMirror(frame.buffer, uv: frame.uv, sessionStart: start, completion: nil)
    }

    // MARK: Ink path

    private func wireInkPath() {
        guard let pipeline = pipeline else { return }
        let registry = ClientRegistry(ioQueue: ioQueue, trustLoopback: settingsStore.settings.trustLoopback)
        self.registry = registry
        model.registry = registry
        let root = settingsStore.settings.saveDirectory ?? SessionSaver.defaultRoot()
        let saver = SessionSaver(root: root, queue: ioQueue, writeJSON: settingsStore.settings.saveStrokesJSON)
        self.saver = saver
        let rasterizer = InkRasterizer(surfaces: pipeline.surfaces)
        self.rasterizer = rasterizer
        let router = InkRouter(pipeline: pipeline, rasterizer: rasterizer, registry: registry, saver: saver, settings: settingsStore.settings, queue: inkQueue)
        self.router = router
        model.router = router
        router.appLabel = "Daylight \(model.version) (\(model.build))"
        router.onLog = { [weak self] line in self?.telemetry.note("ink", line) }
        router.pendingAllow = { [weak self] connection in
            DispatchQueue.main.async { self?.model.setPendingAllow(connection) }
        }
        router.onClientsChanged = { [weak self] snapshots in
            DispatchQueue.main.async {
                self?.model.setClients(snapshots)
                self?.onboardingModel.inputs.clientsAllowed = snapshots.filter { $0.allowed }.count
                self?.onboardingModel.inputs.clientsPending = snapshots.filter { $0.pending }.count
            }
        }
        router.onSaveResult = { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case let .success(urls): self?.model.noteSaved(urls)
                case let .failure(error): self?.model.noteFailure(.saveFailed, ["\(error.localizedDescription)"])
                }
            }
        }
        router.onSaving = { [weak pipeline] saving in pipeline?.setSaving(saving) }
        router.onEngagingStart = { [weak pipeline] ns in pipeline?.noteInkArrival(hostTimeNs: ns) }
        pipeline.onStateForClients = { [weak self] report in self?.inkQueue.async { self?.router?.receiveState(report) } }
        pipeline.onSavePage = { [weak self] reason in self?.inkQueue.async { self?.router?.savePage(reason: reason) } }
        pipeline.onClearCanvas = { [weak self] in self?.inkQueue.async { self?.router?.clearCanvas() } }
        registry.onChange = { [weak self] records in
            DispatchQueue.main.async { self?.settingsContext.allowedClients = records }
        }
        settingsContext.allowedClients = registry.all
        inkQueue.async { router.startAutosave() }
    }

    // MARK: Server

    private func wireServer() {
        let resources = Bundle.main.resourceURL
        let webRoot = resources?.appendingPathComponent("web")
        let apk = resources?.appendingPathComponent("DaylightInk.apk")
        let apkURL = (apk.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) ? apk : nil
        let name = settingsStore.settings.bonjourName ?? "Daylight Camera on \(LocalAddresses.hostname())"
        let port = arguments.port ?? settingsStore.settings.port
        let config = WebServer.Config(webRoot: webRoot, apkURL: apkURL, preferredPort: port, bonjourName: name, loopbackOnly: false, scanPorts: true)
        let version = model.version
        let build = Int(model.build) ?? 0
        let store = settingsStore
        let server = WebServer(config: config, info: { [weak self] in
            let bound = self?.server?.port ?? port
            return ApiRoutes.infoDictionary(version: version, build: build, port: bound, inkSource: store.settings.inkSource, pillStripHeight: store.settings.pillStripHeight, origin: WebServer.origin(port: bound))
        }, queue: netQueue)
        self.server = server
        model.server = server
        server.onLog = { [weak self] line in self?.telemetry.note("server", line) }
        server.onFailed = { [weak self] failure, args in DispatchQueue.main.async { self?.model.noteFailure(failure, args) } }
        server.onReady = { [weak self] bound in
            DispatchQueue.main.async {
                self?.model.refresh()
                self?.onboardingModel.inputs.webURL = LocalAddresses.primaryURL(port: bound)
                self?.mirrorController?.serverPort = bound
                if bound != port { self?.model.noteFailure(.portInUse, ["\(port)", "\(bound)"]) }
            }
        }
        server.onInkClientOpened = { [weak self] c in self?.inkQueue.async { self?.router?.clientOpened(c) } }
        server.onInkClientClosed = { [weak self] c in self?.inkQueue.async { self?.router?.clientClosed(c) } }
        server.onInkMessage = { [weak self] c, bytes, ns in self?.inkQueue.async { self?.router?.handle(bytes, from: c, hostTimeNs: ns) } }
        server.start()
    }

    // MARK: Hotkeys and settings

    private func wireHotkeys() {
        let hotkeys = Hotkeys(settings: settingsStore.settings)
        hotkeys.onAction = { [weak self] action in self?.model.hotkey(action) }
        hotkeys.registerAll()
        settingsContext.hotkeyConflicts = hotkeys.conflictTexts
        for (action, text) in hotkeys.conflictTexts {
            telemetry.note("hotkeys", "\(Hotkeys.title(action)): \(text)")
        }
        self.hotkeys = hotkeys
    }

    private func wireSettings() {
        settingsContext.cameras = { WebcamCapture.cameras().map { CameraOption(id: $0.uniqueID, name: $0.localizedName) } }
        settingsContext.forget = { [weak self] id in self?.registry?.forget(id: id) }
        settingsContext.latestMirrorFrame = { [weak self] in self?.mirror?.latestFrameForSave()?.buffer }
        settingsContext.tryWiFiMirror = { [weak self] in
            self?.mirror?.tryWiFiMirror { ok in
                if !ok { DispatchQueue.main.async { self?.model.noteFailure(.wifiMirrorFailed, []) } }
            }
        }
        settingsContext.refreshDiagnostics = { [weak self] in
            guard let self = self else { return }
            self.settingsContext.diagnosticsText = self.diagnosticsText()
        }
        settingsContext.chooseSaveDirectory = { [weak self] in self?.chooseSaveDirectory() }
        settingsStore.onChange = { [weak self] settings in self?.applySettings(settings) }
    }

    private func applySettings(_ settings: Settings) {
        let previous = lastApplied
        lastApplied = settings
        pipeline?.updateSettings(settings)
        mirrorController?.updateSettings(settings)
        inkQueue.async { [weak self] in self?.router?.updateSettings(settings) }
        telemetry.perfLog = settings.perfLog || arguments.perfLog
        preview.floats = settings.previewFloats
        if settings.cameraUniqueID != previous.cameraUniqueID {
            pipeline?.setCamera(uniqueID: settings.cameraUniqueID)
        }
        if settings.hotkeys != previous.hotkeys, let hotkeys = hotkeys {
            for (action, binding) in settings.hotkeys where previous.hotkeys[action] != binding {
                do {
                    try hotkeys.rebind(action, keyCode: binding.keyCode, modifiers: binding.modifiers)
                } catch {
                    telemetry.note("hotkeys", "\(Hotkeys.title(action)): \(error)")
                }
            }
            settingsContext.hotkeyConflicts = hotkeys.conflictTexts
        }
        if settings.inkSource != previous.inkSource {
            model.applyInkSource(settings.inkSource)
        }
        if settings.saveDirectory != previous.saveDirectory || settings.saveStrokesJSON != previous.saveStrokesJSON {
            saver?.writeJSON = settings.saveStrokesJSON
            telemetry.note("app", "save folder changes apply after a restart")
        }
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.settings.saveDirectory = url
        }
    }

    // MARK: Windows

    private func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(store: settingsStore, context: settingsContext) }
        settingsContext.diagnosticsText = diagnosticsText()
        settingsWindow?.show()
    }

    private func showDiagnostics() {
        if diagnostics == nil { diagnostics = DiagnosticsWindowController(provider: { [weak self] in self?.diagnosticsText() ?? "" }) }
        diagnostics?.show()
    }

    private func showAllowPanel(for item: AppModel.PendingClient) {
        if allowPanel == nil { allowPanel = AllowClientPanel() }
        guard let panel = allowPanel else { return }
        panel.onAllow = { [weak self] in self?.model.allow(item) }
        panel.onNotNow = { [weak self] in self?.model.deny(item) }
        panel.onDismissed = { [weak self] in self?.telemetry.note("app", "allow panel dismissed; the menu item stays") }
        panel.show(label: item.label, address: item.address)
    }

    private func showOnboarding(force: Bool) {
        if force { settingsStore.settings.onboardingDone = false }
        if onboarding == nil {
            wireOnboardingActions()
            onboarding = OnboardingWindowController(model: onboardingModel)
            onboarding?.onClose = { [weak self] in
                self?.onboardingTimer?.invalidate()
                self?.onboardingTimer = nil
            }
        }
        refreshOnboardingInputs()
        onboarding?.show()
        onboardingTimer?.invalidate()
        onboardingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshOnboardingInputs() }
    }

    private func refreshOnboardingInputs() {
        let s = settingsStore.settings
        // The "Your Daylight" row must see a tablet on USB with every ink source (SPEC 13.1 step 3); the tracker runs
        // only in mirror mode, so ask for one rate-limited `adb devices -l` while this window is open.
        mirror?.refreshDevices()
        // The owner may have answered the system prompt without this window's button: follow the TCC status, and
        // open the capture gate the moment access is granted.
        let permission = AppDelegate.cameraPermission(AVCaptureDevice.authorizationStatus(for: .video))
        if permission == .granted && onboardingModel.inputs.camera != .granted {
            pipeline?.setCaptureAuthorized(true)
            pipeline?.start()
        }
        onboardingModel.inputs.camera = permission
        onboardingModel.inputs.cameraName = WebcamCapture.camera(uniqueID: s.cameraUniqueID)?.localizedName
        onboardingModel.inputs.webURL = LocalAddresses.primaryURL(port: server?.port ?? s.port)
        onboardingModel.inputs.usbDevice = mirror?.devices.first(where: { $0.isUSB })?.serial
        onboardingModel.inputs.mirrorFrames = (mirror?.latestFrameForSave()) != nil
        onboardingModel.inputs.loginItemEnabled = settingsStore.launchAtLogin
        onboardingModel.inputs.hotkeyLines = HotkeyAction.allCases.compactMap { action in
            guard let binding = s.hotkeys[action] else { return nil }
            return "\(Hotkeys.describe(binding)) \(Hotkeys.title(action))"
        }
        onboardingModel.inkSource = s.inkSource
        onboardingModel.launchAtLogin = settingsStore.launchAtLogin
        onboardingModel.inputs.modernApprovalPath = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
    }

    private func wireOnboardingActions() {
        var actions = OnboardingModel.Actions()
        actions.requestCamera = { [weak self] in self?.requestCameraAccess() }
        actions.installExtension = { [weak self] in self?.installer?.activate() }
        actions.openApprovalPane = { [weak self] in self?.openSystemSettings() }
        actions.checkAgain = { [weak self] in
            guard let self = self else { return }
            // A second activation request of an approved extension completes at once (C handoff request 2).
            self.installer?.activate()
            if let sink = self.sink { self.sinkStatusChanged(sink.status) }
            self.refreshOnboardingInputs()
        }
        actions.revealInFinder = { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
        actions.openPreview = { [weak self] in self?.preview.show() }
        actions.setUpOverUSB = { [weak self] source in
            guard let self = self else { return }
            guard let mirror = self.mirror else {
                self.telemetry.note("app", "Set up over USB needs the mirror component (adb); open the web address on the tablet instead")
                return
            }
            let host = LocalAddresses.list().first?.ip
            mirror.setUpOverUSB(source: source, host: host, pills: self.settingsStore.settings.mirrorPinClearMode.includesPills) { result in
                DispatchQueue.main.async {
                    guard case let .failure(error) = result else { return }
                    if let row = AppDelegate.usbSetupFailure(error) {
                        self.model.noteFailure(row.0, row.1)
                    } else {
                        self.model.noteUSBSetupFailed(AppDelegate.describeUSBSetupError(error))
                    }
                }
            }
        }
        actions.selectSource = { [weak self] source in self?.model.setInkSource(source) }
        actions.copyURL = { [weak self] in
            guard let url = self?.onboardingModel.inputs.webURL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        }
        actions.setLaunchAtLogin = { [weak self] enabled in
            guard let self = self else { return }
            do {
                try self.settingsStore.setLaunchAtLogin(enabled)
            } catch {
                self.telemetry.note("app", "launch at login: \(error)")
            }
            self.onboardingModel.launchAtLogin = self.settingsStore.launchAtLogin
        }
        actions.finish = { [weak self] in
            guard let self = self else { return }
            self.settingsStore.settings.onboardingDone = true
            self.settingsStore.settings.onboardingVersion = 1
            self.onboarding?.close()
        }
        onboardingModel.actions = actions
    }

    /// "Set up over USB" failures onto the adb rows (SPEC 13.3 rows 21 to 23): no USB tablet is row 21, a tablet that
    /// still shows the RSA prompt is row 22, an offline one is row 23. Anything else (an install or grant that failed,
    /// a build without the APK, a missing adb) has no row and returns nil; the caller shows the error text itself
    /// instead of blaming USB debugging.
    static func usbSetupFailure(_ error: Error) -> (FailureText.Case, [String])? {
        guard let adbError = error as? AdbError else { return nil }
        switch adbError {
        case .noDevice:
            return (.adbNoDevice, ["(no USB device)"])
        case let .deviceNotReady(serial, state):
            if state == AdbDevicesParser.stateUnauthorized { return (.adbUnauthorized, [serial]) }
            if state == AdbDevicesParser.stateOffline { return (.adbOffline, [serial]) }
            return (.adbNoDevice, ["\(serial) \(state)"])
        case .executableMissing, .launchFailed, .timeout, .failed:
            return nil
        }
    }

    /// One readable line for the menu banner when `usbSetupFailure` has no row.
    static func describeUSBSetupError(_ error: Error) -> String {
        guard let adbError = error as? AdbError else { return "\(error)" }
        switch adbError {
        case let .executableMissing(path): return "the bundled adb is missing at \(path)"
        case let .launchFailed(detail): return "adb could not be launched (\(detail))"
        case let .timeout(command): return "adb \(command) timed out"
        case let .failed(status, detail, command):
            let text = detail.isEmpty ? "exit \(status)" : detail
            return "adb \(command) failed: \(text)"
        case .noDevice: return FailureText.sentence(.adbNoDevice)
        case let .deviceNotReady(serial, state): return "\(serial) is \(state)"
        }
    }

    /// The camera privacy pane for row 3; otherwise the installer's Camera Extensions pane (macOS 15 and later first,
    /// Privacy & Security below; UNVERIFIED URLs, LOOSE_ENDS E13). The onboarding row already spells the text path.
    private func openSystemSettings() {
        if onboardingModel.inputs.camera == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        if let installer = installer {
            if !installer.openApprovalPane() {
                telemetry.note("app", "System Settings did not open; approve the extension under \(installer.approvalPathText)")
            }
            return
        }
        let candidates = [ExtensionInstaller.modernApprovalPaneURL, ExtensionInstaller.legacyApprovalPaneURL]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: Diagnostics

    func diagnosticsText() -> String {
        var facts = DiagnosticsReport.Facts()
        facts.version = model.version
        facts.build = model.build
        facts.signed = signed
        facts.bundlePath = Bundle.main.bundlePath
        facts.extensionState = "\(model.extensionState)"
        facts.sinkStatus = model.sinkStatusText
        if let pipeline = pipeline {
            facts.pipeline = pipeline.stats
            facts.governor = pipeline.governorSnapshot
        }
        facts.inkSource = settingsStore.settings.inkSource
        facts.serverState = "\(server?.state ?? .idle)"
        facts.port = server?.port ?? 0
        facts.bonjourName = server?.bonjourRegisteredName ?? server?.config.bonjourName
        facts.addresses = LocalAddresses.list()
        facts.clients = model.clients.map { "\($0.label) (\($0.role)) \($0.address)\($0.allowed ? " allowed" : "")\($0.active ? " active" : "")\($0.pending ? " pending" : "")" }
        facts.allowedClients = registry?.all ?? []
        facts.mirror = mirror?.diagnostics ?? ["status": model.mirrorStatusText]
        facts.failures = model.recentFailures
        facts.logLines = telemetry.recentLines
        return DiagnosticsReport.text(facts)
    }
}
