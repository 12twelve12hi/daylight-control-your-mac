import AVFoundation
import CoreMedia
import CoreVideo
import DaylightKit
import Foundation
import Metal
import os
import QuartzCore

/// The frame pipeline (ARCHITECTURE section 3): camera frames pass through untouched while the governor is in
/// PASSTHROUGH; a 30 Hz clock drives one Metal pass per frame otherwise. Owns the governor under one lock, the idle
/// rule of SPEC D32, the STATE cadence of SPEC D47 and the perf counters. Implements `PipelineControl`.
final class FramePipeline: PipelineControl {
    /// STATE cadence (SPEC D47): 10 Hz while ENGAGING, RETURNING or pre-warning; 1 Hz while LIVE.
    static let stateIntervalAnimating: Double = 0.1
    static let stateIntervalLive: Double = 1.0
    static let outputWidth = 1920
    static let outputHeight = 1080

    let sink: VirtualCameraSink
    let telemetry: Telemetry
    let renderQueue: DispatchQueue
    let captureQueue: DispatchQueue
    let clock: FrameClock
    let surfaces: CanvasSurfaces
    let compositor: Compositor?
    let pool: OutputPool?
    let feeder: FrameFeeder
    let cameraSlot = LatestFrameSlot()
    let device: MTLDevice?
    private let governor: Locked<EngageGovernor>
    private let log = Logger(subsystem: Telemetry.subsystem, category: "pipeline")

    private struct Flags {
        var viewers = 0
        var previewVisible = false
        var sinkConnected = false
        var saving = false
        var cameraAttached = false
        var captureRunning = false
        var captureIdleReason: String?
        var inkSource: InkSource
        var mirror: MirrorFrameSource?
        var zeroCopyEligible = true
        /// The current camera's facts ("1920x1080 BGRA iosurface=true"), re-evaluated whenever the format changes.
        var firstFrame: String?
        var lastFormat: (Int, Int, OSType, Bool)?
        /// Camera authorization (SPEC 13.3 row 3): false blocks capture; the app sets it from the TCC status.
        var captureAuthorized = true
        /// Presenter Overlay (SPEC 6.7): exists only while `Settings.overlayEnabled`. Read with the flags the capture
        /// and render paths already copy, so a disabled overlay costs no extra lock.
        var overlay: OverlayController?
        /// The controller could not be created and row 48 was posted; no retry (and no second row 48) until the
        /// setting is turned off and on again (SPEC 6.7, row 48 reported once).
        var overlayCreationFailed = false
        /// Mirrors `onFailure != nil`, kept under this lock so a creation failure and the handler assignment agree
        /// on who delivers row 48.
        var failureHandlerSet = false
        /// Row 48 arguments from a creation failure that happened before `onFailure` was set (a launch with Overlay
        /// on runs `init` before the app wires the handler). Delivered once, by `onFailure`'s didSet.
        var pendingOverlayFailure: [String]?
    }
    private let flags: Locked<Flags>
    /// A governor config changed while the board was up; applied on the next return to PASSTHROUGH.
    private let pendingConfig = Locked<GovernorConfig?>(nil)
    private var settings: Settings
    private(set) var capture: CaptureSource?
    private var captureObserver: NSObjectProtocol?
    private var idleWork: DispatchWorkItem?
    /// Tests shorten the 60 s hysteresis; nil means `settings.viewerIdleStopSeconds`.
    var idleStopOverrideSeconds: Double?

    // Counters (render queue and Metal completion thread; the Locked keeps them coherent for the 2 Hz readers).
    private struct Counters {
        var pushed: UInt64 = 0
        var dropped: UInt64 = 0
        var composed: UInt64 = 0
        var cpuMsLast: Double = 0
        var gpuMsLast: Double = 0
        var fpsWindowStart: Double = 0
        var fpsWindowCount: UInt64 = 0
        var fps: Double = 0
        var inkArrivalNs: UInt64?
    }
    private let counters = Locked<Counters>(Counters())
    /// Bumped by a lost camera. A composed passthrough frame carries the value from its arrival and is pushed only if
    /// it is still current, under this lock, so a GPU completion can never land after the lost-camera card.
    private let passthroughGeneration = Locked<UInt64>(0)
    private var stateLimiter = RateLimiter(minInterval: FramePipeline.stateIntervalAnimating)
    private var lastReportKey: (UInt8, UInt8, UInt8, UInt8)?
    private var perfTimer: DispatchSourceTimer?
    private var creamCard: CVPixelBuffer?

    // MARK: Callbacks (set once at wiring time)

    var onStateForClients: ((StateReport) -> Void)?
    var onPreviewFrame: ((CVPixelBuffer) -> Void)?
    /// Governor effects the ink router acts on (ink.queue hop is the router's job).
    var onSavePage: ((SaveReason) -> Void)?
    var onClearCanvas: (() -> Void)?
    var onStateChanged: ((GovernorState, GovernorState) -> Void)?
    var onCameraPresence: ((Bool) -> Void)?
    var onFailure: ((FailureText.Case, [String]) -> Void)? {
        didSet {
            let handlerSet = onFailure != nil
            let pending = flags.withLock { (f: inout Flags) -> [String]? in
                f.failureHandlerSet = handlerSet
                guard handlerSet else { return nil }
                let args = f.pendingOverlayFailure
                f.pendingOverlayFailure = nil
                return args
            }
            if let args = pending { onFailure?(.overlayFallback, args) }
        }
    }
    var latencyProbe = false
    /// The person segmentation engine a new OverlayController gets (tests inject fakes before enabling Overlay).
    var makeOverlayEngine: () throws -> PersonMaskEngine = { VisionPersonEngine() }

    /// `overlayEngine` replaces `makeOverlayEngine` before `init` creates the first controller (tests reach the
    /// launch path with Overlay already on); nil keeps the Vision engine.
    init(sink: VirtualCameraSink, settings: Settings, telemetry: Telemetry, device: MTLDevice? = MTLCreateSystemDefaultDevice(), capture: CaptureSource? = nil, now: Double = CACurrentMediaTime(), overlayEngine: (() throws -> PersonMaskEngine)? = nil) throws {
        let validated = settings.validated()
        self.sink = sink
        self.settings = validated
        self.telemetry = telemetry
        self.device = device
        let target = DispatchQueue.global(qos: .userInteractive)
        renderQueue = DispatchQueue(label: "com.twelve.daylight.render", qos: .userInteractive, target: target)
        captureQueue = DispatchQueue(label: "com.twelve.daylight.capture", qos: .userInteractive)
        clock = FrameClock(queue: renderQueue, fps: 30)
        surfaces = try CanvasSurfaces(device: device)
        if let device = device {
            compositor = try Compositor(device: device)
            pool = try OutputPool(width: FramePipeline.outputWidth, height: FramePipeline.outputHeight)
        } else {
            compositor = nil
            pool = nil
        }
        feeder = FrameFeeder(sink: sink)
        governor = Locked(EngageGovernor(config: GovernorConfig(settings: validated), now: now))
        var initialFlags = Flags(inkSource: validated.inkSource)
        if case .connected = sink.status { initialFlags.sinkConnected = true }
        flags = Locked(initialFlags)
        self.capture = capture
        clock.onTick = { [weak self] now in self?.tick(now: now) }
        compositor?.onConversionFallback = { [weak self] text in self?.telemetry.note("pipeline", text) }
        compositor?.onOverlayUnavailable = { [weak self] text in self?.telemetry.note("overlay", text) }
        if let overlayEngine = overlayEngine { makeOverlayEngine = overlayEngine }
        if validated.overlayEnabled { applyOverlaySetting(validated) }
        if let capture = capture {
            capture.onEvent = { [weak self] event in self?.handleCapture(event) }
        }
        captureObserver = NotificationCenter.default.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.renderQueue.async { self.recomputeCapture() }
        }
    }

    deinit {
        if let observer = captureObserver { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: PipelineControl

    func post(_ event: GovernorEvent) {
        let now = CACurrentMediaTime()
        let out = governor.withLock { $0.handle(event, now: now) }
        renderQueue.async { [weak self] in self?.consume(out, now: now, fromEvent: true) }
    }

    var governorSnapshot: GovernorOutput {
        return governor.withLock { $0.snapshot }
    }

    /// The config the governor runs with (Diagnostics and tests; a pending change is not yet visible here).
    var governorConfig: GovernorConfig {
        return governor.withLock { $0.config }
    }

    func setViewerCount(_ n: Int) {
        let arrived = flags.withLock { (f: inout Flags) -> Bool in
            let count = max(0, n)
            let rose = count > f.viewers
            f.viewers = count
            return rose
        }
        renderQueue.async { [weak self] in
            self?.recomputeCapture()
            if arrived { self?.pushCardIfNoCameraPicture() }
            self?.publishFlagsChange()
        }
    }

    func setPreviewVisible(_ visible: Bool) {
        let opened = flags.withLock { (f: inout Flags) -> Bool in
            let opening = visible && !f.previewVisible
            f.previewVisible = visible
            return opening
        }
        renderQueue.async { [weak self] in
            self?.recomputeCapture()
            if opened { self?.pushCardIfNoCameraPicture() }
            self?.publishFlagsChange()
        }
    }

    func setSinkConnected(_ connected: Bool) {
        let connecting = flags.withLock { (f: inout Flags) -> Bool in
            let rising = connected && !f.sinkConnected
            f.sinkConnected = connected
            return rising
        }
        renderQueue.async { [weak self] in
            self?.recomputeCapture()
            if connecting { self?.pushCardIfNoCameraPicture() }
            self?.publishFlagsChange()
        }
    }

    /// Render queue: a viewer, the preview or a (re)connected sink arrives while no camera picture flows (access not
    /// granted, or the camera lost while capture runs). The card pushed when that state began went to nobody (the
    /// extension drops frames while no app streams), so the newcomer gets it now instead of no frame at all (SPEC B4,
    /// rows 3 and 4). A capture that is not running needs nothing here: `startCapture` pushes the cached frame or card.
    private func pushCardIfNoCameraPicture() {
        let f = flags.withLock { $0 }
        guard !f.captureAuthorized || (f.captureRunning && !f.cameraAttached) else { return }
        guard f.viewers > 0 || f.previewVisible else { return }
        guard governor.withLock({ $0.state }) == .passthrough, let card = creamCardBuffer() else { return }
        feeder.push(card, hostTimeNs: nil)
        onPreviewFrame?(card)
    }

    // MARK: Wiring

    /// Replaces the capture source (tests pass a `FakeCapture`; the app passes a `WebcamCapture` on `captureQueue`).
    func setCaptureSource(_ source: CaptureSource?) {
        renderQueue.async { [weak self] in
            guard let self = self else { return }
            if let old = self.capture, old.isRunning { old.stop() }
            self.capture = source
            source?.onEvent = { [weak self] event in self?.handleCapture(event) }
            self.flags.withLock { $0.captureRunning = false }
            self.recomputeCapture()
        }
    }

    /// Switches the webcam (Settings `cameraUniqueID`; nil means the preferred-camera rule of SPEC 11, evaluated live).
    func setCamera(uniqueID: String?) {
        renderQueue.async { [weak self] in
            guard let self = self, let webcam = self.capture as? WebcamCapture else { return }
            webcam.preferredUniqueID = uniqueID
            if webcam.isRunning {
                webcam.stop()
                self.flags.withLock { $0.captureRunning = false }
            }
            self.flags.withLock { $0.lastFormat = nil }
            self.recomputeCapture()
        }
    }

    /// Camera authorization (SPEC 13.3 row 3): while false the capture never starts, the sink and the preview show the
    /// cream card, and no AVCaptureDeviceInput failure is mistaken for "No camera found".
    func setCaptureAuthorized(_ authorized: Bool) {
        flags.withLock { $0.captureAuthorized = authorized }
        renderQueue.async { [weak self] in
            guard let self = self else { return }
            if !authorized, let card = self.creamCardBuffer() {
                self.feeder.push(card, hostTimeNs: nil)
                self.onPreviewFrame?(card)
            }
            self.recomputeCapture()
            self.publishFlagsChange()
        }
    }

    func setInkSource(_ source: InkSource) {
        flags.withLock { $0.inkSource = source }
        post(.sourceChanged(source))
    }

    func setMirrorSource(_ mirror: MirrorFrameSource?) {
        flags.withLock { $0.mirror = mirror }
    }

    /// STATE bit6 while a page write is in progress.
    func setSaving(_ saving: Bool) {
        flags.withLock { $0.saving = saving }
        renderQueue.async { [weak self] in self?.publishFlagsChange() }
    }

    /// Applies changed governor settings (idle timeout, pre-warning, spring, eraser rule). A changed config rebuilds
    /// the governor only while it is in PASSTHROUGH; while the board is up (the owner tuning "Return to camera after"
    /// during a call) the change waits and is applied on the next return, so the picture never snaps away.
    func updateSettings(_ newSettings: Settings) {
        let validated = newSettings.validated()
        settings = validated
        let config = GovernorConfig(settings: validated)
        let now = CACurrentMediaTime()
        pendingConfig.withLock { pending in
            governor.withLock { g in
                if g.config == config {
                    pending = nil
                } else if g.state == .passthrough {
                    FramePipeline.rebuild(&g, config: config, now: now)
                    pending = nil
                } else {
                    pending = config
                }
            }
        }
        flags.withLock { $0.inkSource = validated.inkSource }
        applyOverlaySetting(validated)
        renderQueue.async { [weak self] in self?.publishFlagsChange() }
    }

    /// Presenter Overlay lifetime (SPEC 6.7): a controller exists only while `overlayEnabled` and a Metal device does;
    /// turning the setting off releases it (its queue, Vision and textures go with it).
    private func applyOverlaySetting(_ validated: Settings) {
        guard validated.overlayEnabled, let device = device, compositor != nil else {
            let old = flags.withLock { (f: inout Flags) -> OverlayController? in
                let current = f.overlay
                f.overlay = nil
                f.overlayCreationFailed = false
                return current
            }
            if old != nil { telemetry.note("overlay", "overlay off") }
            return
        }
        let (existing, creationFailed) = flags.withLock { ($0.overlay, $0.overlayCreationFailed) }
        if let existing = existing {
            existing.update(settings: validated)
            return
        }
        if creationFailed { return }
        do {
            let controller = try OverlayController(device: device, settings: validated, telemetry: telemetry, engine: makeOverlayEngine())
            controller.onFailure = { [weak self] failure, args in self?.onFailure?(failure, args) }
            flags.withLock { $0.overlay = controller }
            telemetry.note("overlay", "overlay on (quality \(validated.overlayQuality.rawValue))")
        } catch {
            let args = ["0", "\(error)"]
            // No handler yet (the launch path runs this from init): keep the row for onFailure's didSet.
            let deliverNow = flags.withLock { (f: inout Flags) -> Bool in
                f.overlayCreationFailed = true
                if f.failureHandlerSet { return true }
                f.pendingOverlayFailure = args
                return false
            }
            telemetry.note("overlay", FailureText.logLine(.overlayFallback, args))
            if deliverNow { onFailure?(.overlayFallback, args) }
        }
    }

    /// A fresh governor in PASSTHROUGH with the new config; `hold(camera)` is the only hold state PASSTHROUGH can
    /// carry, so it is the only thing restored.
    private static func rebuild(_ g: inout EngageGovernor, config: GovernorConfig, now: Double) {
        let hold = g.holdState
        g = EngageGovernor(config: config, now: now)
        if hold == .camera { _ = g.handle(.hold(.camera), now: now) }
    }

    /// Render queue: a config that waited for the board to come down is applied once the governor is in PASSTHROUGH.
    private func applyPendingConfigIfPassthrough(now: Double) {
        pendingConfig.withLock { pending in
            guard let config = pending else { return }
            governor.withLock { g in
                guard g.state == .passthrough else { return }
                FramePipeline.rebuild(&g, config: config, now: now)
                pending = nil
            }
        }
    }

    /// The latency probe (ARCHITECTURE 3.5): the ink router stamps the arrival of an engaging STROKE_START.
    func noteInkArrival(hostTimeNs: UInt64) {
        guard latencyProbe else { return }
        counters.withLock { if $0.inkArrivalNs == nil { $0.inkArrivalNs = hostTimeNs } }
    }

    /// Starts the clock bookkeeping and the capture decision; call once after wiring.
    func start() {
        renderQueue.async { [weak self] in
            guard let self = self else { return }
            self.recomputeCapture()
            if self.telemetry.perfLog { self.startPerfLog() }
        }
    }

    /// Quit: stop the clock and the camera. The router saves the page (`savePage(.quit)`) before this is called.
    func shutdown() {
        renderQueue.sync {
            clock.stop()
            perfTimer?.cancel()
            perfTimer = nil
            idleWork?.cancel()
            idleWork = nil
            if let capture = capture, capture.isRunning { capture.stop() }
            flags.withLock { $0.captureRunning = false }
        }
    }

    // MARK: Stats

    var stats: PipelineStats {
        let f = flags.withLock { $0 }
        let c = counters.withLock { $0 }
        let out = governorSnapshot
        var s = PipelineStats()
        switch out.state {
        case .passthrough: s.mode = "passthrough"
        case .engaging: s.mode = "engaging"
        case .live:
            switch out.layout {
            case .whiteboardOnly: s.mode = "whiteboard"
            case .studioSplit: s.mode = "split"
            case .overlay: s.mode = (f.overlay.map { !$0.isFellBack } ?? false) ? "overlay" : "split"
            }
        case .returning: s.mode = "returning"
        }
        s.fps = c.fps
        s.cpuMsPerFrame = c.cpuMsLast
        s.gpuMsPerFrame = c.gpuMsLast
        s.dropped = c.dropped + feeder.droppedFrames
        s.pushed = feeder.pushedFrames
        s.inFlight = pool?.inFlight ?? 0
        s.passthroughZeroCopy = f.zeroCopyEligible
        s.capturing = f.captureRunning
        s.captureIdleReason = f.captureIdleReason
        s.viewers = f.viewers
        s.firstFrame = f.firstFrame
        s.cameraAttached = f.cameraAttached
        s.sinkConnected = f.sinkConnected
        return s
    }

    /// The Presenter Overlay controller, nil while Overlay is off (Diagnostics and tests).
    var overlayController: OverlayController? {
        return flags.withLock { $0.overlay }
    }

    /// The flags every STATE carries (bits 4 to 7); the router adds the per-client bits.
    var globalStateFlags: StateReport.Flags {
        let f = flags.withLock { $0 }
        var bits: StateReport.Flags = []
        if f.cameraAttached { bits.insert(.cameraAttached) }
        if f.sinkConnected { bits.insert(.sinkConnected) }
        if f.saving { bits.insert(.saving) }
        if f.captureIdleReason != nil { bits.insert(.captureIdle) }
        return bits
    }

    var inkSource: InkSource {
        return flags.withLock { $0.inkSource }
    }

    func stateReport(_ out: GovernorOutput) -> StateReport {
        return out.stateReport(clientFlags: globalStateFlags, inkSource: inkSource, pageIndex: 0, strokeCount: 0, undoDepth: 0, redoDepth: 0)
    }

    // MARK: Governor outputs (render queue)

    private func consume(_ out: GovernorOutput, now: Double, fromEvent: Bool) {
        for effect in out.effects {
            switch effect {
            case let .stateChanged(from, to):
                telemetry.note("governor", "\(from) -> \(to)")
                if to == .engaging && from == .passthrough {
                    clock.start()
                    renderFrame(now: now, out: out)
                }
                onStateChanged?(from, to)
            case let .savePage(reason):
                onSavePage?(reason)
            case .clearCanvas:
                onClearCanvas?()
            case .preWarningStarted, .preWarningCancelled, .pinChanged, .holdChanged:
                break
            }
        }
        if out.state == .passthrough { applyPendingConfigIfPassthrough(now: now) }
        let needsTicks = governor.withLock { $0.needsTicks }
        if needsTicks && !clock.isRunning { clock.start() }
        if !needsTicks && clock.isRunning { clock.stop() }
        publishState(out, now: now, force: !out.effects.isEmpty)
    }

    private func tick(now: Double) {
        let out = governor.withLock { $0.tick(now: now) }
        consume(out, now: now, fromEvent: false)
        if out.state != .passthrough {
            renderFrame(now: now, out: out)
        }
    }

    private func publishFlagsChange() {
        let out = governorSnapshot
        publishState(out, now: CACurrentMediaTime(), force: false)
    }

    private func publishState(_ out: GovernorOutput, now: Double, force: Bool) {
        let report = stateReport(out)
        let key = (report.governor, report.flags, report.mode, report.inkSource)
        let changed = lastReportKey == nil || lastReportKey! != key
        if changed || force {
            lastReportKey = key
            stateLimiter = RateLimiter(minInterval: FramePipeline.stateIntervalAnimating)
            _ = stateLimiter.allow(now: now)
            onStateForClients?(report)
            return
        }
        switch out.state {
        case .engaging, .returning:
            stateLimiter.minInterval = FramePipeline.stateIntervalAnimating
        case .live:
            stateLimiter.minInterval = out.preWarning ? FramePipeline.stateIntervalAnimating : FramePipeline.stateIntervalLive
        case .passthrough:
            return
        }
        if stateLimiter.allow(now: now) {
            onStateForClients?(report)
        }
    }

    // MARK: Rendering (render queue)

    private func renderFrame(now: Double, out: GovernorOutput) {
        guard let compositor = compositor, let pool = pool else { return }
        let signpost = telemetry.begin("composite")
        let cpuStart = CACurrentMediaTime()
        let f = flags.withLock { $0 }
        var canvas: Compositor.CanvasInput = .layers(surfaces)
        var orientation = StudioLayout.CanvasOrientation.portrait
        var aspect = StudioLayout.portraitAspect
        if f.inkSource == .mirror {
            if let mirror = f.mirror, let latest = mirror.latest() {
                canvas = .mirror(latest.buffer, uv: latest.uv)
                orientation = latest.orientation
                aspect = latest.aspect
            } else {
                canvas = .none
            }
        }
        // Overlay draws only with a controller that has not fallen back; otherwise Studio Split (SPEC 6.7).
        var overlayInput: Compositor.OverlayInput?
        var overlayFrame: StudioLayout.Frame?
        if out.layout == .overlay, let controller = f.overlay {
            let result = controller.renderInput(now: now)
            if !result.fellBack {
                overlayFrame = OverlayLayout.frame(progress: out.progress, orientation: orientation, canvasAspect: aspect, breath: out.breath, config: controller.layoutConfig)
                overlayInput = result.input
            }
        }
        let layout: LayoutStyle = out.layout == .overlay ? .studioSplit : out.layout
        let frame = overlayFrame ?? StudioLayout.frame(progress: out.progress, layout: layout, orientation: orientation, canvasAspect: aspect, breath: out.breath)
        guard let target = pool.acquire() else {
            counters.withLock { $0.dropped += 1 }
            telemetry.end(signpost, "composite")
            return
        }
        let presenter = cameraSlot.take()?.buffer
        let inputs = Compositor.Inputs(presenter: presenter, canvas: canvas, frame: frame, overlay: overlayInput)
        let progress = out.progress
        compositor.render(inputs, into: target) { [weak self] gpuSeconds in
            guard let self = self else { return }
            let pushSignpost = self.telemetry.begin("sink.push")
            self.feeder.push(target, hostTimeNs: nil)
            self.telemetry.end(pushSignpost, "sink.push")
            self.onPreviewFrame?(target)
            pool.release(target)
            self.recordComposedFrame(gpuMs: gpuSeconds * 1000, progress: progress)
        }
        let cpuMs = (CACurrentMediaTime() - cpuStart) * 1000
        counters.withLock { $0.cpuMsLast = cpuMs }
        telemetry.end(signpost, "composite")
    }

    /// Passthrough for a camera that is not IOSurface-backed 1920x1080 BGRA: one GPU pass with the passthrough frame.
    /// `generation` is `passthroughGeneration` when the frame arrived; a camera lost since then drops it.
    private func renderPassthroughComposed(_ pixelBuffer: CVPixelBuffer, generation: UInt64) {
        guard let compositor = compositor, let pool = pool else {
            passthroughGeneration.withLock { current in
                if current == generation { feeder.push(pixelBuffer, hostTimeNs: nil) }
            }
            return
        }
        if passthroughGeneration.withLock({ $0 }) != generation { return }
        guard let target = pool.acquire() else {
            counters.withLock { $0.dropped += 1 }
            return
        }
        let inputs = Compositor.Inputs(presenter: pixelBuffer, canvas: .none, frame: StudioLayout.passthrough())
        compositor.render(inputs, into: target) { [weak self] gpuSeconds in
            guard let self = self else { return }
            // Checked and pushed under the lock the lost-camera card is pushed under: either this frame goes out
            // before the card, or the bumped generation drops it (it would otherwise freeze the face after the card).
            let pushed = self.passthroughGeneration.withLock { (current: inout UInt64) -> Bool in
                guard current == generation else { return false }
                self.feeder.push(target, hostTimeNs: nil)
                self.onPreviewFrame?(target)
                return true
            }
            pool.release(target)
            if pushed { self.recordComposedFrame(gpuMs: gpuSeconds * 1000, progress: 0) }
        }
    }

    /// Zero-copy eligibility (SPEC 4, row 5): IOSurface-backed 1920x1080 BGRA goes to the sink untouched.
    static func isZeroCopyEligible(_ pixelBuffer: CVPixelBuffer) -> Bool {
        return CVPixelBufferGetIOSurface(pixelBuffer) != nil
            && CVPixelBufferGetWidth(pixelBuffer) == outputWidth
            && CVPixelBufferGetHeight(pixelBuffer) == outputHeight
            && CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
    }

    private func recordComposedFrame(gpuMs: Double, progress: Double) {
        let now = CACurrentMediaTime()
        var probe: Double?
        counters.withLock { c in
            c.composed += 1
            c.gpuMsLast = gpuMs
            FramePipeline.countFrame(&c, now: now)
            if progress > 0, let arrival = c.inkArrivalNs {
                probe = Double(DispatchTime.now().uptimeNanoseconds - arrival) / 1_000_000
                c.inkArrivalNs = nil
            }
        }
        if let ms = probe {
            telemetry.note("latency", String(format: "engage probe: STROKE_START to first moved frame %.1f ms", ms))
        }
    }

    private static func countFrame(_ c: inout Counters, now: Double) {
        c.pushed += 1
        if c.fpsWindowStart == 0 { c.fpsWindowStart = now }
        c.fpsWindowCount += 1
        let elapsed = now - c.fpsWindowStart
        if elapsed >= 1 {
            c.fps = Double(c.fpsWindowCount) / elapsed
            c.fpsWindowStart = now
            c.fpsWindowCount = 0
        }
    }

    // MARK: Capture path (capture queue)

    private func handleCapture(_ event: CaptureEvent) {
        switch event {
        case let .frame(pixelBuffer, hostTimeNs):
            let signpost = telemetry.begin("capture")
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let fourcc = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let backed = CVPixelBufferGetIOSurface(pixelBuffer) != nil
            // Zero-copy eligibility is decided per frame (SPEC 4, row 5): a camera switch or a reconnect can change
            // the format at any time, and a non-1080p or non-BGRA buffer must take the composed path.
            let eligible = FramePipeline.isZeroCopyEligible(pixelBuffer)
            let format = (width, height, fourcc, backed)
            var firstFacts: String?
            var overlay: OverlayController?
            flags.withLock { f in
                overlay = f.overlay
                f.zeroCopyEligible = eligible
                f.cameraAttached = true
                if f.lastFormat == nil || f.lastFormat! != format {
                    f.lastFormat = format
                    f.firstFrame = "\(width)x\(height) \(Compositor.fourcc(fourcc)) iosurface=\(backed)"
                    firstFacts = f.firstFrame
                }
            }
            if let facts = firstFacts {
                telemetry.note("capture", "first frame \(facts) zeroCopy=\(eligible)")
                if !eligible {
                    telemetry.note("capture", FailureText.logLine(.webcamFormatComposed, ["\(width)", "\(height)", Compositor.fourcc(fourcc), "\(backed)"]))
                    onFailure?(.webcamFormatComposed, ["\(width)", "\(height)", Compositor.fourcc(fourcc), "\(backed)"])
                }
            }
            cameraSlot.publish(pixelBuffer, hostTimeNs: hostTimeNs)
            let state = governor.withLock { $0.state }
            // Presenter Overlay: only with a controller, only while the board is up in the Overlay layout.
            if let overlay = overlay, state != .passthrough, governor.withLock({ $0.layout }) == .overlay {
                overlay.offer(pixelBuffer, hostTimeNs: hostTimeNs)
            }
            if state == .passthrough {
                if eligible {
                    let pushSignpost = telemetry.begin("sink.push")
                    feeder.push(pixelBuffer, hostTimeNs: hostTimeNs)
                    telemetry.end(pushSignpost, "sink.push")
                    onPreviewFrame?(pixelBuffer)
                    let now = CACurrentMediaTime()
                    counters.withLock { FramePipeline.countFrame(&$0, now: now) }
                } else {
                    let generation = passthroughGeneration.withLock { $0 }
                    renderQueue.async { [weak self] in self?.renderPassthroughComposed(pixelBuffer, generation: generation) }
                }
            }
            telemetry.end(signpost, "capture")
        case let .formatChanged(width, height, pixelFormat):
            telemetry.note("capture", "format \(width)x\(height) \(Compositor.fourcc(pixelFormat))")
            flags.withLock { $0.lastFormat = nil }   // the next frame re-logs its facts and re-decides zero copy
        case .lost:
            flags.withLock { f in
                f.cameraAttached = false
                f.lastFormat = nil
            }
            cameraSlot.clear()
            // Composed passthrough frames that arrived before the loss are dropped from here on (PIPA-05).
            passthroughGeneration.withLock { $0 &+= 1 }
            telemetry.note("capture", "camera lost")
            onCameraPresence?(false)
            let state = governor.withLock { $0.state }
            renderQueue.async { [weak self] in
                guard let self = self else { return }
                // PASSTHROUGH: viewers would keep the last camera frame frozen; the cream card says it plainly.
                // Composed states already draw the cream presenter area because the slot is empty.
                if state == .passthrough, let card = self.creamCardBuffer() {
                    self.passthroughGeneration.withLock { _ in
                        self.feeder.push(card, hostTimeNs: nil)
                        self.onPreviewFrame?(card)
                    }
                }
                self.publishFlagsChange()
            }
        case .restored:
            flags.withLock { f in
                f.cameraAttached = true
                f.lastFormat = nil
            }
            telemetry.note("capture", "camera restored")
            onCameraPresence?(true)
            renderQueue.async { [weak self] in self?.publishFlagsChange() }
        }
    }

    // MARK: Idle rule (SPEC D32), render queue

    var wantsCapture: Bool {
        let f = flags.withLock { $0 }
        return f.captureAuthorized && (f.viewers > 0 || f.previewVisible || !f.sinkConnected)
    }

    private var idleStopSeconds: Double {
        return idleStopOverrideSeconds ?? Double(settings.viewerIdleStopSeconds)
    }

    private func recomputeCapture() {
        let wants = wantsCapture
        let running = flags.withLock { $0.captureRunning }
        if wants {
            idleWork?.cancel()
            idleWork = nil
            if !running { startCapture() }
        } else if running && idleWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.idleWork = nil
                if !self.wantsCapture { self.stopCaptureForIdle() }
            }
            idleWork = work
            renderQueue.asyncAfter(deadline: .now() + idleStopSeconds, execute: work)
        }
    }

    private func startCapture() {
        guard let capture = capture else {
            flags.withLock { $0.cameraAttached = false }
            return
        }
        // The viewer never sees the extension placeholder: the last frame or a cream card goes out at once, before
        // `start()` blocks for the camera's warm-up (SPEC B4). Only in PASSTHROUGH: composed states draw the slot's
        // frame (or the cream presenter) on their next tick, and a raw buffer would flash into their stream. A cached
        // frame that is not zero-copy eligible (720p, say) is composed like every passthrough frame of that camera.
        var cardPushed = false
        if governor.withLock({ $0.state }) == .passthrough {
            if let cached = cameraSlot.take()?.buffer {
                if FramePipeline.isZeroCopyEligible(cached) {
                    feeder.push(cached, hostTimeNs: nil)
                    onPreviewFrame?(cached)
                } else {
                    renderPassthroughComposed(cached, generation: passthroughGeneration.withLock { $0 })
                }
            } else if let card = creamCardBuffer() {
                feeder.push(card, hostTimeNs: nil)
                onPreviewFrame?(card)
                cardPushed = true
            }
        }
        do {
            try capture.start()
            flags.withLock { f in
                f.captureRunning = true
                f.captureIdleReason = nil
                f.cameraAttached = capture.hasDevice
            }
            let f = flags.withLock { $0 }
            telemetry.note("capture", "capture started (viewers=\(f.viewers) preview=\(f.previewVisible) sink=\(f.sinkConnected))")
            onCameraPresence?(capture.hasDevice)
        } catch {
            // Denied camera access surfaces as AVError.applicationIsNotAuthorizedToUseDevice from AVCaptureDeviceInput:
            // that is row 3, not row 4, and says nothing about whether a camera is present.
            let denied = (error as? AVError)?.code == .applicationIsNotAuthorizedToUseDevice
            flags.withLock { f in
                f.captureRunning = false
                if !denied { f.cameraAttached = false }
            }
            let failure: FailureText.Case = denied ? .cameraAccessDenied : .noWebcam
            telemetry.note("capture", FailureText.logLine(failure) + " (\(error))")
            onFailure?(failure, [])
            if !denied { onCameraPresence?(false) }
            if !cardPushed, let card = creamCardBuffer() {
                feeder.push(card, hostTimeNs: nil)
                onPreviewFrame?(card)
            }
        }
        publishFlagsChange()
    }

    private func stopCaptureForIdle() {
        capture?.stop()
        flags.withLock { f in
            f.captureRunning = false
            f.captureIdleReason = "viewers=0 preview=hidden"
        }
        pool?.flush()
        telemetry.note("capture", FailureText.logLine(.captureIdle))
        publishFlagsChange()
    }

    /// A 1920x1080 SurfaceCream frame for the moments without a camera picture. Filled with `memset_pattern4`: the
    /// per-byte Swift loop it replaces took up to about 0.9 s on the render queue in the unoptimized build on the
    /// macos-15 runner (runs 37134646725 and 37136061242), and every frame, tick and capture decision queued behind it
    /// waited that long.
    private func creamCardBuffer() -> CVPixelBuffer? {
        if let card = creamCard { return card }
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, FramePipeline.outputWidth, FramePipeline.outputHeight, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let card = created else { return nil }
        CVPixelBufferLockBaseAddress(card, [])
        if let base = CVPixelBufferGetBaseAddress(card) {
            let cream = Tokens.surfaceCream
            // BGRA in memory; a row's padding (bytesPerRow is a multiple of 4) gets the same pattern, which no reader sees.
            let pattern: [UInt8] = [UInt8(cream.b * 255 + 0.5), UInt8(cream.g * 255 + 0.5), UInt8(cream.r * 255 + 0.5), 255]
            let length = CVPixelBufferGetBytesPerRow(card) * CVPixelBufferGetHeight(card)
            pattern.withUnsafeBytes { raw in
                memset_pattern4(base, raw.baseAddress, length)
            }
        }
        CVPixelBufferUnlockBaseAddress(card, [])
        creamCard = card
        return card
    }

    // MARK: Perf log

    private func startPerfLog() {
        if perfTimer != nil { return }
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.telemetry.emit(self.stats)
            if self.telemetry.perfLog, let overlay = self.flags.withLock({ $0.overlay }) {
                let line = overlay.perfLine(now: CACurrentMediaTime())
                if let sink = self.telemetry.sink { sink(line) } else { print(line) }
                self.telemetry.remember(line)
            }
        }
        perfTimer = timer
        timer.activate()
    }
}
