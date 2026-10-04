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
    /// The "Daylight Whiteboard" share window and its menu (docs/handoff/vp-too-small.md).
    private let shareWindow = ShareWindowController()
    private lazy var shareMenu = ShareMenu(controller: shareWindow)
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
    private var allowPanelItem: AppModel.PendingClient?
    private var onboarding: OnboardingWindowController?
    private var settingsWindow: SettingsWindowController?
    private var diagnostics: DiagnosticsWindowController?
    private lazy var diagnosticsExport = DiagnosticsExport(app: self)
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

    init(arguments: LaunchArguments) {
        self.arguments = arguments
        let bundle = Bundle.main
        signed = (bundle.object(forInfoDictionaryKey: "DaylightBuildSigned") as? Bool) ?? false
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        if arguments.uiTest {
            // `--ui-test`: a throwaway suite, emptied, so the launch is a first launch (docs/handoff/vp-mac-ui.md).
            let store = SettingsStore(defaults: UITestMode.freshDefaults(), unsignedBuild: !signed)
            if arguments.uiTestOptions.overlayEnabled { store.settings.overlayEnabled = true }
            settingsStore = store
        } else {
            settingsStore = SettingsStore(unsignedBuild: !signed)
        }
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
        if arguments.uiTest {
            launchForUITest()
            return
        }
        // `--self-test` exits in main.swift before this object exists; the hosted test bundle never looks at, quits or
        // defers to another copy.
        if AppDelegate.isUnderTest || arguments.selfTest {
            launch()
            return
        }
        settleOtherInstances { [weak self] in self?.launch() }
    }

    // MARK: Single instance

    /// What a launch does when another process with our bundle id is running (the Downloads or translocated copy
    /// still up when the owner opens the /Applications one, SPEC 13.1 step 0). Two copies would feed one sink and
    /// fight over the port and the hotkeys.
    enum InstanceDecision: Equatable {
        case proceed
        /// Bring that copy forward and quit this one.
        case activateOtherAndQuit(pid_t)
        /// This copy is in /Applications and every other one is misplaced: quit them, then carry on.
        case terminateOthers([pid_t])
    }

    struct RunningCopy: Equatable {
        let pid: pid_t
        let bundlePath: String?
    }

    static let otherInstanceQuitTimeout: Double = 6

    /// Pure: `running` is every app with our bundle id (this process included), `selfPID` and `selfPath` are ours.
    static func instanceDecision(selfPID: pid_t, selfPath: String, running: [RunningCopy]) -> InstanceDecision {
        let others = running.filter { $0.pid != selfPID }
        guard !others.isEmpty else { return .proceed }
        let misplaced: (RunningCopy) -> Bool = { copy in
            guard let path = copy.bundlePath, path != selfPath else { return false }
            return OnboardingSteps.locationProblem(bundlePath: path)
        }
        if !OnboardingSteps.locationProblem(bundlePath: selfPath) && others.allSatisfy(misplaced) {
            return .terminateOthers(others.map { $0.pid })
        }
        let target = others.first(where: { !misplaced($0) }) ?? others[0]
        return .activateOtherAndQuit(target.pid)
    }

    private func settleOtherInstances(then proceed: @escaping () -> Void) {
        guard let bundleID = Bundle.main.bundleIdentifier else { proceed(); return }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let running = apps.map { RunningCopy(pid: $0.processIdentifier, bundlePath: $0.bundleURL?.path) }
        let decision = AppDelegate.instanceDecision(selfPID: ProcessInfo.processInfo.processIdentifier, selfPath: Bundle.main.bundlePath, running: running)
        switch decision {
        case .proceed:
            proceed()
        case let .activateOtherAndQuit(pid):
            telemetry.note("app", "Daylight is already running (pid \(pid)); activating it and quitting this copy")
            _ = apps.first(where: { $0.processIdentifier == pid })?.activate(options: [])
            NSApp.terminate(nil)
        case let .terminateOthers(pids):
            let others = apps.filter { pids.contains($0.processIdentifier) }
            telemetry.note("app", "quitting the misplaced copy (pids \(pids)) before starting from \(Bundle.main.bundlePath)")
            for other in others { _ = other.terminate() }
            waitForExit(others, deadline: Date().addingTimeInterval(AppDelegate.otherInstanceQuitTimeout), then: proceed)
        }
    }

    /// Polls on main until the quitting copies are gone (they save and free the port and the hotkeys first), or the
    /// deadline passes; then the launch goes on either way.
    private func waitForExit(_ apps: [NSRunningApplication], deadline: Date, then proceed: @escaping () -> Void) {
        if apps.allSatisfy({ $0.isTerminated }) || Date() >= deadline {
            proceed()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForExit(apps, deadline: deadline, then: proceed)
        }
    }

    private func launch() {
        telemetry.note("app", "Daylight \(model.version) (\(model.build)) signed=\(signed) path=\(Bundle.main.bundlePath)")
        if OnboardingSteps.locationProblem(bundlePath: Bundle.main.bundlePath) {
            telemetry.note("app", FailureText.logLine(.notInApplications, [Bundle.main.bundlePath]))
        }
        if !signed { telemetry.note("app", FailureText.logLine(.unsignedBuild)) }
        model.telemetry = telemetry
        model.preview = preview
        menuBar = MenuBar(model: model)
        menuBar?.onExportDiagnostics = { [weak self] in self?.diagnosticsExport.start() }
        wireShare()
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

    // MARK: UI test mode

    /// `--ui-test` (docs/handoff/vp-mac-ui.md, "Design contract"): every window and the status item, nothing that
    /// touches the camera, TCC, the extension installer, the mirror, global hotkeys, the network or another running
    /// copy. The preview opens only when asked for (`--ui-test-open preview`) so it never covers another surface.
    private func launchForUITest() {
        UITestMode.apply(arguments.uiTestOptions.appearance)
        telemetry.note("app", "ui test run: camera, installer, mirror, hotkeys and server are not started")
        model.telemetry = telemetry
        model.preview = preview
        menuBar = MenuBar(model: model)
        menuBar?.onExportDiagnostics = { [weak self] in self?.diagnosticsExport.start() }
        wireShare()
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        model.onOpenDiagnostics = { [weak self] in self?.showDiagnostics() }
        model.onSetupAgain = { [weak self] in self?.showOnboarding(force: true) }
        model.onAllowRequested = { [weak self] item in self?.showAllowPanel(for: item) }
        wireSettings()
        if let tab = arguments.uiTestOptions.settingsTab { settingsContext.selectedTab = tab }
        model.start()
        preview.floats = settingsStore.settings.previewFloats
        if !settingsStore.settings.onboardingDone { showOnboarding(force: false) }
        // After the run loop is up: the status item button can take a click and the windows are ordered in.
        DispatchQueue.main.async { [weak self] in self?.openUITestSurface() }
    }

    private func openUITestSurface() {
        guard let surface = arguments.uiTestOptions.open else { return }
        switch surface {
        case .welcome:
            showOnboarding(force: false)
        case .settings:
            showSettings()
        case .preview:
            preview.show()
            UITestMode.tagPreviewWindow()
        case .diagnostics:
            showDiagnostics()
        case .allow:
            if allowPanel == nil { allowPanel = AllowClientPanel() }
            guard let panel = allowPanel else { return }
            panel.onAllow = {}
            panel.onNotNow = {}
            panel.onDismissed = {}
            allowPanelItem = nil
            panel.show(label: UITestMode.allowLabel, address: UITestMode.allowAddress)
        case .menu:
            menuBar?.openForUITest()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        router?.stopAutosave()
        router?.saveOnQuit(timeout: AppDelegate.quitSaveTimeout)
        saveMirrorSessionIfNeeded()
        saver?.waitUntilIdle(timeout: AppDelegate.quitSaveTimeout)
        hotkeys?.unregisterAll()
        mirrorController?.releaseWifiStream()
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
        let mirror = MirrorController(settings: settingsStore.settings, vendorDirectory: vendor, pipeline: pipeline, queue: controlQueue, wifiQueue: inkQueue)
        mirror.onLog = { [weak self] line in self?.telemetry.note("mirror", line) }
        mirror.onFailure = { [weak self] failure, args in
            DispatchQueue.main.async { self?.model.noteFailure(failure, args) }
        }
        // Row 37 is withdrawn once the USB pen watcher starts (hardening round 3, DIFF-B4).
        mirror.onResolve = { [weak self] cases in
            DispatchQueue.main.async { self?.model.resolve(cases) }
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
        pipeline.setMirrorSource(mirror.activeSource)
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
        // Every callback is set before the first render-queue block (setCaptureAuthorized below) can read it. The ink
        // router does not exist yet; these three go through `self?.router`, which wireInkPath fills in.
        pipeline.onStateForClients = { [weak self] report in self?.inkQueue.async { self?.router?.receiveState(report) } }
        pipeline.onSavePage = { [weak self] reason in self?.inkQueue.async { self?.router?.applyGovernorEffect(.savePage(reason: reason)) } }
        pipeline.onClearCanvas = { [weak self] in self?.inkQueue.async { self?.router?.applyGovernorEffect(.clearCanvas) } }
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
        // Row 3 before the capture source: the idle rule may want capture at once (sink not connected), and a denied
        // AVCaptureDeviceInput must not read as "No camera found". `startCaptureIfAuthorized` opens the gate.
        pipeline.setCaptureAuthorized(AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
        let capture = WebcamCapture(queue: pipeline.captureQueue)
        capture.preferredUniqueID = settingsStore.settings.cameraUniqueID
        capture.onLog = { [weak self] line in self?.telemetry.note("capture", line) }
        pipeline.setCaptureSource(capture)
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
            model.noteCameraGranted()
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
        // No TCC prompt on the UI test runner.
        if arguments.uiTest { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.onboardingModel.inputs.camera = granted ? .granted : .denied
                if granted {
                    self.model.noteCameraGranted()
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
        if from == .passthrough && to == .engaging && settingsContext.shareStore.settings.openWithBoard && !shareWindow.isVisible {
            shareWindow.show(activate: false)
        }
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
                self?.syncAllowPanel()
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
        server.factsStore = TabletFactsStore.shared
        server.factsAllowed = { [registry = self.registry] id in registry?.isAllowed(id: id) ?? false }
        server.onReady = { [weak self] bound in
            DispatchQueue.main.async {
                self?.model.refresh()
                self?.onboardingModel.inputs.webURL = LocalAddresses.primaryURL(port: bound)
                self?.mirrorController?.serverPort = bound
                if bound != port { self?.model.noteFailure(.portInUse, ["\(port)", "\(bound)"]) }
            }
        }
        server.onInkClientOpened = { [weak self] c in self?.inkQueue.async { self?.router?.clientOpened(c) } }
        // The Wi-Fi mirror family (PROTOCOL 14) is peeled off on ink.queue before the router sees a frame.
        server.onInkClientClosed = { [weak self] c in
            self?.inkQueue.async {
                self?.mirrorController?.wifiSource.forget(c)
                self?.router?.clientClosed(c)
            }
        }
        server.onInkMessage = { [weak self] c, bytes, ns in
            self?.inkQueue.async {
                if self?.mirrorController?.wifiSource.ingest(bytes, from: c, hostTimeNs: ns) == true { return }
                self?.router?.handle(bytes, from: c, hostTimeNs: ns)
            }
        }
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
        // A transport switch empties the other transport's frame slot inside `updateSettings`, so the board of the
        // session that is ending is saved first (hardening round 3, USB-A2/B3).
        if settings.mirrorTransport != previous.mirrorTransport { saveMirrorSessionIfNeeded() }
        mirrorController?.updateSettings(settings)
        if settings.mirrorTransport != previous.mirrorTransport, let mirror = mirrorController {
            pipeline?.setMirrorSource(mirror.activeSource)
        }
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
        } else if settings.overlayEnabled != previous.overlayEnabled, let hotkeys = hotkeys {
            // `Hotkeys` already (un)registered the Overlay chord through AppModel's notification, which the store
            // publishes before `onChange`; refresh the conflict text so Settings shows a clash at once (VP Overlay
            // request 1).
            settingsContext.hotkeyConflicts = hotkeys.conflictTexts
        }
        if settings.inkSource != previous.inkSource {
            model.applyInkSource(settings.inkSource)
        }
        if settings.saveDirectory != previous.saveDirectory || settings.saveStrokesJSON != previous.saveStrokesJSON {
            saver?.writeJSON = settings.saveStrokesJSON
            if settings.saveDirectory != previous.saveDirectory {
                saver?.setRoot(settings.saveDirectory ?? SessionSaver.defaultRoot())
            }
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

    /// Share window (docs/handoff/vp-too-small.md): reads the canvas the pipeline draws into, or the mirror picture
    /// while the ink source is Mirror; its own settings live in `settingsContext.shareStore`.
    private func wireShare() {
        if arguments.uiTest, let defaults = UserDefaults(suiteName: ShareSettingsStore.uiTestSuite) {
            defaults.removePersistentDomain(forName: ShareSettingsStore.uiTestSuite)
            settingsContext.shareStore = ShareSettingsStore(defaults: defaults)
        }
        let store = settingsContext.shareStore
        shareWindow.apply(store.settings)
        store.onChange = { [weak self] s in self?.shareWindow.apply(s) }
        shareWindow.source = { [weak self] in
            guard let self = self, let pipeline = self.pipeline else { return .none }
            if self.settingsStore.settings.inkSource == .mirror {
                guard let mirror = self.mirrorController?.activeSource else { return .none }
                return .mirror(mirror)
            }
            return .layers(pipeline.surfaces)
        }
        shareWindow.onLog = { [weak self] line in self?.telemetry.note("share", line) }
        shareMenu.onOpenSettings = { [weak self] in
            self?.settingsContext.selectedTab = .share
            self?.showSettings()
        }
        settingsContext.showShareWindow = { [weak self] in self?.shareWindow.show(activate: true) }
        menuBar?.shareMenu = { [weak self] in self?.shareMenu.makeItem() ?? NSMenuItem() }
    }

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
        allowPanelItem = item
        panel.show(label: item.label, address: item.address)
    }

    /// The panel's connection left the pending list (socket closed, or allowed elsewhere): show the redial of the same
    /// tablet if one is pending, otherwise take the stale prompt down.
    private func syncAllowPanel() {
        guard let shown = allowPanelItem, let panel = allowPanel, panel.isVisible else { return }
        if model.pending.contains(where: { $0.connectionID == shown.connectionID }) { return }
        if let redial = model.pending.first(where: { $0.clientID == shown.clientID }) {
            showAllowPanel(for: redial)
        } else {
            panel.dismiss()
            allowPanelItem = nil
        }
    }

    private func showOnboarding(force: Bool) {
        if force { settingsStore.settings.onboardingDone = false }
        if onboarding == nil {
            wireOnboardingActions()
            onboarding = OnboardingWindowController(model: onboardingModel)
        }
        refreshOnboardingInputs()
        onboarding?.show()
        onboarding?.startPolling(every: 1) { [weak self] in self?.refreshOnboardingInputs() }
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
            model.noteCameraGranted()
            pipeline?.setCaptureAuthorized(true)
            pipeline?.start()
        }
        onboardingModel.inputs.camera = permission
        onboardingModel.inputs.cameraName = WebcamCapture.camera(uniqueID: s.cameraUniqueID)?.localizedName
        onboardingModel.inputs.webURL = LocalAddresses.primaryURL(port: server?.port ?? s.port)
        onboardingModel.inputs.usbDevice = mirror?.devices.first(where: { $0.isUSB })?.serial
        onboardingModel.inputs.mirrorFrames = (mirror?.latestFrameForSave()) != nil
        onboardingModel.inputs.loginItemEnabled = settingsStore.launchAtLogin
        onboardingModel.inputs.hotkeyLines = HotkeyAction.allCases.filter { $0 != .overlay || s.overlayEnabled }.compactMap { action in
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
            // The UI test runner's login items are never changed.
            if self.arguments.uiTest { return }
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
