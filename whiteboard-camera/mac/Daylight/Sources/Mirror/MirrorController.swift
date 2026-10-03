import CoreVideo
import DaylightKit
import Foundation
import os
import QuartzCore

/// The `MirrorControl` facade (IMPLEMENTATION-PLAN 3.1 and 9): the only F type B constructs. Owns the adb policy, the
/// device tracker, the scrcpy session, the decoder, the stylus watcher, the Wi-Fi interim and the `MirrorSource` the
/// pipeline samples. State changes run on `queue` (the control queue B passes); frames and pen events never hop
/// through it: the decoder publishes straight into the source slot and the stylus queue posts governor events itself.
final class MirrorController: MirrorControl {
    static let log = Logger(subsystem: "com.twelve.daylight", category: "mirror")
    /// A failed session is retried while the device stays listed: 3 s doubling to 24 s.
    static let sessionRetryInitial: Double = 3
    static let sessionRetryMax: Double = 24
    /// `adb connect` for the Wi-Fi interim is tried at most once per this interval while no USB device is listed.
    static let wifiRetryInterval: Double = 30

    let queue: DispatchQueue
    let mirrorQueue = DispatchQueue(label: "com.twelve.daylight.mirror", qos: .userInteractive)
    let stylusQueue = DispatchQueue(label: "com.twelve.daylight.stylus", qos: .userInteractive)
    let adbQueue = DispatchQueue(label: "com.twelve.daylight.adb", qos: .utility)
    let vendorDirectory: URL
    private let pipeline: PipelineControl
    private let mirrorSource: MirrorSource
    private let settingsBox: Locked<Settings>
    private var injectedAdb: AdbRunning?
    private var adb: AdbRunning?
    private var policyDecision: AdbServerPolicy.Decision?
    private var tracker: DeviceTracker?
    private var session: ScrcpySession?
    private var decoder: H264Decoder?
    private var stylus: StylusWatcher?
    private var wifi: WifiMirror?
    private var started = false
    private var currentSerial: String?
    private var sessionGeneration = 0
    private var sessionRetryDelay = MirrorController.sessionRetryInitial
    private var pillsInstalledFor: Set<String> = []
    private var lastWifiAttempt: Double = 0
    private let statusBox = Locked<MirrorStatus>(.idle)
    private let devicesBox = Locked<[AdbDevice]>([])
    private let extraBox = Locked<[String: String]>([:])
    private static let queueKey = DispatchSpecificKey<Bool>()
    private var engageProbeStart: Double?
    private var loggedFirstFrame = false

    /// Mutated on the control queue; readable from any thread (B's 2 Hz mirror reads them from main).
    private var currentStatus: MirrorStatus {
        get { return statusBox.withLock { $0 } }
        set { statusBox.withLock { $0 = newValue } }
    }

    private var currentDevices: [AdbDevice] {
        get { return devicesBox.withLock { $0 } }
        set { devicesBox.withLock { $0 = newValue } }
    }

    private var extraDiagnostics: [String: String] {
        get { return extraBox.withLock { $0 } }
        set { extraBox.withLock { $0 = newValue } }
    }
    /// Dummy-byte retry budget of the session (tests shorten it).
    var sessionTuning: (attempts: Int, interval: Double) = (ScrcpyLaunch.dummyByteAttempts, ScrcpyLaunch.dummyByteRetryInterval)
    /// Device-list cadence when the track socket is unavailable (tests shorten it).
    var trackerTuning: (pollInterval: Double, useTrackSocket: Bool) = (2, true)

    /// The bound web server port for `adb reverse` (B sets it when the listener binds 7789 instead of 7788).
    var serverPort: UInt16
    /// The embedded Daylight Ink APK (`Resources/DaylightInk.apk`), nil when the build has none.
    var apkURL: URL?
    var onLog: ((String) -> Void)?
    /// Failure rows for the menu (B shows them through `FailureText`); called on the control queue.
    var onFailure: ((FailureText.Case, [String]) -> Void)?

    // MARK: MirrorControl

    var source: MirrorFrameSource { return mirrorSource }
    var onStatusChange: ((MirrorStatus) -> Void)?
    var onDevicesChange: (([AdbDevice]) -> Void)?

    var status: MirrorStatus { return currentStatus }

    var devices: [AdbDevice] { return currentDevices }

    init(settings: Settings, vendorDirectory: URL, pipeline: PipelineControl, queue: DispatchQueue, adb: AdbRunning? = nil) {
        self.queue = queue
        self.vendorDirectory = vendorDirectory
        self.pipeline = pipeline
        settingsBox = Locked(settings.validated())
        mirrorSource = MirrorSource(settings: settings)
        injectedAdb = adb
        serverPort = settings.port
        let apk = vendorDirectory.deletingLastPathComponent().appendingPathComponent("DaylightInk.apk")
        apkURL = FileManager.default.fileExists(atPath: apk.path) ? apk : nil
        if queue.getSpecific(key: MirrorController.queueKey) == nil { queue.setSpecific(key: MirrorController.queueKey, value: true) }
        mirrorSource.onStart = { [weak self] in self?.start() }
        mirrorSource.onStop = { [weak self] in self?.stop() }
    }

    /// Runs `body` on the control queue, directly when already there (B may pass the main queue and call from main).
    private func onControlQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: MirrorController.queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }

    var settings: Settings { return settingsBox.withLock { $0 } }

    /// Settings changes while running: crop insets and the pills rule apply at once, gesture windows on the next press,
    /// encoder options on the next session.
    func updateSettings(_ newSettings: Settings) {
        let validated = newSettings.validated()
        settingsBox.withLock { $0 = validated }
        mirrorSource.updateSettings(validated)
        queue.async { [weak self] in
            self?.stylus?.updateGestures(validated.sideButtonGestures)
            self?.serverPort = validated.port
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.started else { return }
            self.started = true
            self.log("mirror start: vendor \(self.vendorDirectory.path)")
            self.ensureAdb { adb in
                guard let adb = adb, self.started else { return }
                self.setStatus(.noDevice)
                let tracker = DeviceTracker(adb: adb, queue: self.adbQueue, pollInterval: self.trackerTuning.pollInterval, useTrackSocket: self.trackerTuning.useTrackSocket)
                tracker.onLog = { [weak self] line in self?.queue.async { self?.log(line) } }
                tracker.onDevices = { [weak self] list in self?.queue.async { self?.devicesChanged(list) } }
                self.tracker = tracker
                tracker.start()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self, self.started else { return }
            self.started = false
            self.tracker?.stop()
            self.tracker = nil
            self.endSession(reason: "stopped")
            self.setStatus(.idle)
        }
    }

    func setUpOverUSB(source: InkSource, host: String?, pills: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.ensureAdb { adb in
                guard let adb = adb else {
                    completion(.failure(AdbError.executableMissing(self.vendorDirectory.appendingPathComponent(AdbClient.vendorExecutableName).path)))
                    return
                }
                self.usbDevice(adb: adb) { device in
                    guard let device = device else {
                        completion(.failure(AdbError.noDevice))
                        return
                    }
                    guard device.isReady else {
                        completion(.failure(AdbError.deviceNotReady(serial: device.serial, state: device.state)))
                        return
                    }
                    let settings = self.settings
                    let port = self.serverPort
                    self.log("set up over USB: \(source.jsonName) on \(device.serial)")
                    switch source {
                    case .web:
                        UsbOnboarding.openWeb(adb: adb, serial: device.serial, port: port, completion: completion)
                    case .native:
                        guard let apk = self.apkURL else {
                            completion(.failure(AdbError.failed(status: -1, detail: "this build has no DaylightInk.apk", command: "install")))
                            return
                        }
                        UsbOnboarding.installInk(adb: adb, serial: device.serial, apk: apk, port: port, host: host, pills: pills, pillsPosition: settings.mirrorPillsPosition) { result in
                            if case .success = result { self.queue.async { self.pillsInstalledFor.insert(device.serial) } }
                            completion(result)
                        }
                    case .mirror:
                        if pills, let apk = self.apkURL {
                            UsbOnboarding.startMirrorPills(adb: adb, serial: device.serial, apk: apk, port: port, pillsPosition: settings.mirrorPillsPosition) { result in
                                if case .success = result { self.queue.async { self.pillsInstalledFor.insert(device.serial) } }
                                completion(result)
                            }
                        } else {
                            completion(.success(()))
                        }
                    }
                }
            }
        }
    }

    func latestFrameForSave() -> (buffer: CVPixelBuffer, uv: UVRect)? {
        return mirrorSource.latestForSave()
    }

    func tryWiFiMirror(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.ensureAdb { adb in
                guard let adb = adb else {
                    completion(false)
                    return
                }
                let wifi = self.wifi ?? WifiMirror(adb: adb, queue: self.adbQueue)
                self.wifi = wifi
                wifi.onLog = { [weak self] line in self?.queue.async { self?.log(line) } }
                wifi.tryConnect { ok in
                    self.queue.async {
                        if !ok {
                            self.onFailure?(.wifiMirrorFailed, [])
                            if case .noDevice = self.currentStatus { self.setStatus(.error(.wifiMirrorFailed, "")) }
                        }
                        completion(ok)
                    }
                }
            }
        }
    }

    var diagnostics: [String: String] {
        return onControlQueue { () -> [String: String] in
            var d = extraDiagnostics
            d["status"] = MirrorController.describe(currentStatus)
            d["adb.mode"] = policyDecision?.diagnosticsText ?? "not started"
            d["adb.executable"] = (adb as? AdbClient)?.executable.path ?? (adb == nil ? "none" : "injected")
            d["devices"] = currentDevices.isEmpty ? "none" : currentDevices.map { "\($0.serial) \($0.state)\($0.model.map { " model:\($0)" } ?? "")" }.joined(separator: "; ")
            if let serial = currentSerial { d["device"] = serial }
            let size = mirrorSource.sessionSize
            d["session.size"] = "\(size.w)x\(size.h)"
            d["session.frames"] = "\(mirrorSource.frameCount)"
            if let session = session {
                d["session.port"] = "\(session.boundPort)"
                d["session.bytes"] = "\(session.bytesReceived)"
                d["session.dummyByteAttempts"] = "\(session.dummyByteAttemptsUsed)"
                if let name = session.deviceName { d["session.deviceModel"] = name }
            }
            if let decoder = decoder { d.merge(decoder.diagnostics) { _, new in new } }
            if let stylus = stylus { d.merge(stylus.diagnostics) { _, new in new } }
            if let ip = wifi?.rememberedIP { d["wifi.ip"] = ip }
            let s = settings
            d["crop.portrait"] = "top \(s.mirrorCropInsetsPortrait.top) left \(s.mirrorCropInsetsPortrait.left) right \(s.mirrorCropInsetsPortrait.right) bottom \(s.mirrorCropInsetsPortrait.bottom)"
            d["crop.landscape"] = "top \(s.mirrorCropInsetsLandscape.top) left \(s.mirrorCropInsetsLandscape.left) right \(s.mirrorCropInsetsLandscape.right) bottom \(s.mirrorCropInsetsLandscape.bottom)"
            d["pinClear"] = s.mirrorPinClearMode.rawValue + (s.sideButtonSwap ? " (swapped)" : "")
            return d
        }
    }

    static func describe(_ status: MirrorStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .noDevice: return "no device"
        case let .connecting(serial): return "connecting \(serial)"
        case let .mirroring(serial, w, h): return "mirroring \(serial) \(w)x\(h)"
        case let .error(failure, detail): return "error: \(FailureText.sentence(failure, [detail]))"
        }
    }

    // MARK: adb

    private func log(_ line: String) {
        MirrorController.log.notice("\(line, privacy: .public)")
        onLog?(line)
    }

    private func setStatus(_ new: MirrorStatus) {
        guard new != currentStatus else { return }
        currentStatus = new
        log("status: \(MirrorController.describe(new))")
        onStatusChange?(new)
    }

    /// Locates the bundled adb and decides the server policy once; completion on the control queue.
    private func ensureAdb(_ completion: @escaping (AdbRunning?) -> Void) {
        if let adb = adb {
            completion(adb)
            return
        }
        let client: AdbRunning
        if let injected = injectedAdb {
            client = injected
        } else {
            switch AdbClient.locateExecutable(vendorDirectory: vendorDirectory) {
            case let .success(url):
                client = AdbClient(executable: url, queue: adbQueue)
            case let .failure(error):
                let detail: String
                switch error {
                case let .executableMissing(path): detail = "bundled adb missing at \(path) (run make fetch-tools)"
                default: detail = "\(error)"
                }
                log(detail)
                setStatus(.error(.scrcpyServerFailed, detail))
                completion(nil)
                return
            }
        }
        let settings = self.settings
        AdbServerPolicy.decide(bundled: client, mode: settings.adbServerMode, privatePort: settings.adbPrivatePort) { [weak self] decision in
            self?.queue.async {
                guard let self = self else { return }
                client.serverSocket = decision.serverSocket
                self.policyDecision = decision
                self.adb = client
                self.log("adb server: \(decision.diagnosticsText)")
                if case let .conflict(theirs, ours, _) = decision {
                    self.onFailure?(.adbVersionClash, ["\(theirs)", "\(ours)"])
                }
                client.run(["version"], timeout: 10) { result in
                    if case let .success(output) = result {
                        let firstLines = output.stdoutText.split(separator: "\n").prefix(2).joined(separator: "; ")
                        self.queue.async { self.extraDiagnostics["adb.version"] = firstLines }
                    }
                }
                completion(client)
            }
        }
    }

    /// The USB device for onboarding: the tracker's list when running, else one `devices -l`.
    private func usbDevice(adb: AdbRunning, completion: @escaping (AdbDevice?) -> Void) {
        let preferred = settings.mirrorDeviceSerial
        if tracker != nil {
            completion(DeviceTracker.chooseDaylight(currentDevices.filter { $0.isUSB }, preferredSerial: preferred))
            return
        }
        adb.run(["devices", "-l"], timeout: 15) { [weak self] result in
            self?.queue.async {
                guard let self = self else { return }
                var list: [AdbDevice] = []
                if case let .success(output) = result { list = AdbDevicesParser.parse(output.stdoutText) }
                self.currentDevices = list
                self.onDevicesChange?(list)
                completion(DeviceTracker.chooseDaylight(list.filter { $0.isUSB }, preferredSerial: preferred))
            }
        }
    }

    // MARK: Devices

    private func devicesChanged(_ list: [AdbDevice]) {
        currentDevices = list
        onDevicesChange?(list)
        guard started else { return }
        let settings = self.settings
        let chosen = DeviceTracker.chooseDaylight(list, preferredSerial: settings.mirrorDeviceSerial)
        if let serial = currentSerial, !list.contains(where: { $0.serial == serial && $0.isReady }) {
            log("device \(serial) left the list")
            endSession(reason: "device gone")
        }
        guard let device = chosen else {
            setStatus(.noDevice)
            log(FailureText.logLine(.adbNoDevice, ["(no devices)"]))
            maybeTryWiFi(settings: settings)
            return
        }
        switch device.state {
        case AdbDevicesParser.stateDevice:
            if currentSerial == nil { startSession(for: device) }
        case AdbDevicesParser.stateUnauthorized:
            setStatus(.error(.adbUnauthorized, device.serial))
            log(FailureText.logLine(.adbUnauthorized, [device.serial]))
        case AdbDevicesParser.stateOffline:
            setStatus(.error(.adbOffline, device.serial))
            log(FailureText.logLine(.adbOffline, [device.serial]))
        default:
            setStatus(.connecting(serial: device.serial))
            log("device \(device.serial) is \(device.state); waiting")
        }
    }

    private func maybeTryWiFi(settings: Settings) {
        guard settings.mirrorOverWiFi, adb != nil else { return }
        let now = CACurrentMediaTime()
        guard now - lastWifiAttempt >= MirrorController.wifiRetryInterval else { return }
        lastWifiAttempt = now
        tryWiFiMirror { _ in }
    }

    // MARK: Session

    private func startSession(for device: AdbDevice) {
        guard let adb = adb else { return }
        let settings = self.settings
        currentSerial = device.serial
        sessionGeneration += 1
        let generation = sessionGeneration
        setStatus(.connecting(serial: device.serial))
        let decoder = H264Decoder(queue: mirrorQueue)
        decoder.onLog = { [weak self] line in self?.queue.async { self?.log(line) } }
        decoder.onFrame = { [weak self] buffer, pts in
            guard let self = self else { return }
            self.mirrorSource.publish(buffer, ptsUs: pts)
        }
        self.decoder = decoder
        let serverURL = vendorDirectory.appendingPathComponent(AdbClient.scrcpyServerName)
        let session = ScrcpySession(adb: adb, server: serverURL, config: ScrcpySession.Config(serial: device.serial, settings: settings), queue: mirrorQueue, dummyByteAttempts: sessionTuning.attempts, dummyByteRetryInterval: sessionTuning.interval)
        session.onServerLog = { [weak self] line in self?.queue.async { self?.log("[scrcpy] \(line)") } }
        session.onConnected = { [weak self] in self?.queue.async { self?.log("video socket connected") } }
        session.onPacket = { [weak self, weak decoder] packet in
            guard let self = self, let decoder = decoder else { return }
            self.handlePacket(packet, decoder: decoder, serial: device.serial, generation: generation)
        }
        session.onExit = { [weak self] error in
            self?.queue.async { self?.sessionEnded(error: error, generation: generation) }
        }
        self.session = session
        session.start()
        startStylus(adb: adb, serial: device.serial, settings: settings)
        if settings.mirrorPinClearMode.includesPills, let apk = apkURL, !pillsInstalledFor.contains(device.serial), device.isUSB {
            pillsInstalledFor.insert(device.serial)
            log("installing Daylight Ink and starting the pills on \(device.serial)")
            UsbOnboarding.startMirrorPills(adb: adb, serial: device.serial, apk: apk, port: serverPort, pillsPosition: settings.mirrorPillsPosition) { [weak self] result in
                self?.queue.async {
                    switch result {
                    case .success: self?.log("pills started on \(device.serial)")
                    case let .failure(error):
                        self?.log("pills setup failed on \(device.serial): \(error)")
                        self?.onFailure?(.pillsInvisible, [])
                    }
                }
            }
        }
    }

    /// Runs on mirror.queue: demuxed packets straight into the decoder; the frame lands in the source slot.
    private func handlePacket(_ packet: ScrcpyPacket, decoder: H264Decoder, serial: String, generation: Int) {
        switch packet {
        case let .deviceMeta(name):
            queue.async { [weak self] in
                self?.extraDiagnostics["session.deviceModel"] = name
                self?.log("device model: \(name)")
            }
        case let .codec(id):
            queue.async { [weak self] in self?.extraDiagnostics["session.codec"] = String(format: "0x%08x", id) }
        case let .session(width, height):
            mirrorSource.setSessionSize(width: Int(width), height: Int(height))
            queue.async { [weak self] in
                guard let self = self, self.sessionGeneration == generation else { return }
                self.sessionRetryDelay = MirrorController.sessionRetryInitial
                self.setStatus(.mirroring(serial: serial, width: Int(width), height: Int(height)))
                self.rememberWiFiIfWanted(serial: serial)
            }
        case let .config(annexB):
            let sets = AnnexB.parameterSets(annexB)
            do {
                try decoder.setParameterSets(sps: sets.sps, pps: sets.pps)
            } catch {
                queue.async { [weak self] in
                    self?.log(FailureText.logLine(.decoderError, ["\(error)"]))
                    self?.setStatus(.error(.decoderError, "\(error)"))
                }
            }
        case let .frame(ptsUs, keyFrame, annexB):
            do {
                try decoder.decode(annexB: annexB, ptsUs: ptsUs, keyFrame: keyFrame)
                if decoder.framesDecoded == 1 {
                    let now = CACurrentMediaTime()
                    queue.async { [weak self] in
                        guard let self = self, !self.loggedFirstFrame else { return }
                        self.loggedFirstFrame = true
                        self.log(String(format: "first decoded frame at %.3f", now))
                    }
                }
                if case .error(.decoderError, _) = currentStatus, !decoder.needsKeyFrame {
                    let size = mirrorSource.sessionSize
                    queue.async { [weak self] in self?.setStatus(.mirroring(serial: serial, width: size.w, height: size.h)) }
                }
            } catch {
                queue.async { [weak self] in
                    guard let self = self, self.sessionGeneration == generation else { return }
                    if self.decoder?.decodeErrors == 1 { self.log(FailureText.logLine(.decoderError, ["\(error)"])) }
                    self.setStatus(.error(.decoderError, "\(error)"))
                }
            }
            if decoder.shouldRestartServer() {
                decoder.resetKeyFrameWait()
                queue.async { [weak self] in
                    guard let self = self, self.sessionGeneration == generation else { return }
                    self.log("no key frame for \(Int(H264Decoder.keyFrameRestartSeconds)) s after a decode error; restarting the server (row 27)")
                    self.restartSession()
                }
            }
        }
    }

    private func rememberWiFiIfWanted(serial: String) {
        let settings = self.settings
        guard settings.mirrorOverWiFi, let adb = adb, currentDevices.first(where: { $0.serial == serial })?.isUSB == true else { return }
        let wifi = self.wifi ?? WifiMirror(adb: adb, queue: adbQueue)
        self.wifi = wifi
        wifi.onLog = { [weak self] line in self?.queue.async { self?.log(line) } }
        wifi.rememberAfterUSBSession(serial: serial)
    }

    private func sessionEnded(error: Error?, generation: Int) {
        guard sessionGeneration == generation, started else { return }
        let detail: String
        var failure: FailureText.Case = .scrcpyServerFailed
        if let sessionError = error as? ScrcpySessionError {
            switch sessionError {
            case let .stream(streamError):
                switch streamError {
                case .codecDisabled, .codecConfigError, .unknownCodec:
                    failure = .scrcpyCodecError
                    log(FailureText.logLine(.scrcpyCodecError, ["\(streamError)"]))
                default: break
                }
                detail = sessionError.detail
            default:
                detail = sessionError.detail
            }
        } else {
            detail = error.map { "\($0)" } ?? "ended"
        }
        if failure == .scrcpyServerFailed { log(FailureText.logLine(.scrcpyServerFailed, [detail])) }
        setStatus(.error(failure, detail))
        onFailure?(failure, [detail])
        let serial = currentSerial
        endSession(reason: "exit: \(detail)")
        guard let retrySerial = serial, currentDevices.contains(where: { $0.serial == retrySerial && $0.isReady }) else { return }
        let delay = sessionRetryDelay
        sessionRetryDelay = min(MirrorController.sessionRetryMax, sessionRetryDelay * 2)
        log("retrying the mirror session in \(Int(delay)) s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.started, self.currentSerial == nil else { return }
            if let device = self.currentDevices.first(where: { $0.serial == retrySerial && $0.isReady }) {
                self.startSession(for: device)
            }
        }
    }

    private func restartSession() {
        guard let serial = currentSerial, let device = currentDevices.first(where: { $0.serial == serial }) else { return }
        endSession(reason: "restart")
        startSession(for: device)
    }

    private func endSession(reason: String) {
        sessionGeneration += 1
        if session != nil || stylus != nil { log("session end (\(reason))") }
        session?.stop()
        session = nil
        stylus?.stop()
        stylus = nil
        let oldDecoder = decoder
        decoder = nil
        mirrorQueue.async { oldDecoder?.invalidate() }
        if currentSerial != nil { emit(.penContact(down: false)) }
        currentSerial = nil
        engageProbeStart = nil
        loggedFirstFrame = false
    }

    // MARK: Stylus

    private func startStylus(adb: AdbRunning, serial: String, settings: Settings) {
        let watcher = StylusWatcher(adb: adb, serial: serial, queue: stylusQueue, gestures: settings.sideButtonGestures)
        watcher.onLog = { [weak self] line in self?.queue.async { self?.log("[pen] \(line)") } }
        watcher.onStatus = { [weak self] status in
            self?.queue.async {
                guard let self = self else { return }
                switch status {
                case let .noPenDevice(names):
                    self.onFailure?(.noPenDevice, ["\(names)"])
                case .sideButtonSilent:
                    if self.settings.mirrorPinClearMode.includesPenButton { self.onFailure?(.noSideButtonEvents, []) }
                case let .watching(path, name, pressureMax):
                    self.extraDiagnostics["pen.node"] = "\(path) \"\(name)\" pressureMax=\(pressureMax)"
                default:
                    break
                }
            }
        }
        watcher.onTransition = { [weak self] transition in
            guard let self = self else { return }
            switch transition {
            case .contactDown:
                self.noteEngageProbe()
                self.emit(.penContact(down: true))
            case .contactUp:
                self.emit(.penContact(down: false))
            case .eraserDown:
                self.emit(.eraserContact(down: true))
            case .eraserUp:
                self.emit(.eraserContact(down: false))
            default:
                break
            }
        }
        watcher.onGesture = { [weak self] gesture in
            guard let self = self else { return }
            let settings = self.settings
            guard settings.mirrorPinClearMode.includesPenButton else { return }
            switch SideButtonGestures.action(for: gesture, swap: settings.sideButtonSwap) {
            case .pin: self.emit(.pin(-1))
            case .clear: self.emit(.clear)
            }
        }
        stylus = watcher
        watcher.start()
    }

    /// Governor events go through the source callback B wires to `pipeline.post`, or straight to the pipeline.
    private func emit(_ event: GovernorEvent) {
        if let callback = mirrorSource.onGovernorEvent {
            callback(event)
        } else {
            pipeline.post(event)
        }
    }

    /// SPEC 15: pen contact to the first moved frame (mirror) is logged once per session as a probe.
    private func noteEngageProbe() {
        let now = CACurrentMediaTime()
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.engageProbeStart == nil {
                self.engageProbeStart = now
                self.log(String(format: "engage probe: pen contact at %.3f (mirror)", now))
            }
        }
    }
}
