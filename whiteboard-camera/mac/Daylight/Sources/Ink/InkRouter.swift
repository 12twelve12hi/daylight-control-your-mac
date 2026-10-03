import DaylightKit
import Foundation
import QuartzCore

/// The ink path (ARCHITECTURE section 4, PROTOCOL sections 8, 9 and 13): decodes every message on ink.queue, applies
/// the allow gate and the active-source rule, feeds the `StrokeStore` and the rasterizer, posts governor events
/// through `PipelineControl`, broadcasts STATE and triggers saves. Every method runs on `queue` (ink.queue).
final class InkRouter {
    let pipeline: PipelineControl
    let rasterizer: InkRasterizer?
    let registry: ClientRegistry
    let saver: SessionSaver?
    let queue: DispatchQueue
    private(set) var store = StrokeStore()
    private(set) var settings: Settings
    private(set) var connections: [UUID: InkConnection] = [:]
    private(set) var activeSource: InkSource
    private var lastGlobalFlags: StateReport.Flags = []
    private(set) var sessionStart: Date?
    private var lastInkMonotonic: Double?
    private var autosaveTimer: DispatchSourceTimer?
    private var saving = false

    /// "Daylight <version> (<build>)" for the JSON `app` field.
    var appLabel = "Daylight"
    /// A value copy of a connection's state for the main thread (the router mutates connections on ink.queue only).
    struct ClientSnapshot: Equatable {
        let connectionID: UUID
        let label: String
        let role: String
        let address: String
        let allowed: Bool
        let active: Bool
        let pending: Bool
        let isLoopback: Bool
    }

    /// Hop to main: show the Allow panel for this connection (SPEC 9.5).
    var pendingAllow: ((ClientSnapshot) -> Void)?
    var onClientsChanged: (([ClientSnapshot]) -> Void)?
    var onLog: ((String) -> Void)?
    var onSaveResult: ((Result<[URL], Error>) -> Void)?
    var onSaving: ((Bool) -> Void)?
    /// Stamp for the latency probe: an engaging STROKE_START arrived (host time ns).
    var onEngagingStart: ((UInt64) -> Void)?

    init(pipeline: PipelineControl, rasterizer: InkRasterizer?, registry: ClientRegistry, saver: SessionSaver?, settings: Settings, queue: DispatchQueue) {
        self.pipeline = pipeline
        self.rasterizer = rasterizer
        self.registry = registry
        self.saver = saver
        self.settings = settings.validated()
        self.queue = queue
        activeSource = self.settings.inkSource
    }

    // MARK: Wiring helpers

    /// Pipeline STATE callback; the router fills the page fields and the per-client bits.
    func receiveState(_ report: StateReport) {
        var flags = StateReport.Flags(rawValue: report.flags)
        flags.remove([.clientAllowed, .clientIsActiveSource])
        lastGlobalFlags = flags
        broadcast(report)
    }

    var clientList: [InkConnection] {
        return connections.values.sorted { $0.openedAtNs < $1.openedAtNs }
    }

    static func snapshot(_ c: InkConnection) -> ClientSnapshot {
        return ClientSnapshot(connectionID: c.id, label: c.label, role: c.role?.rawValue ?? "", address: c.remote, allowed: c.allowed, active: c.isActiveSource, pending: c.pending && !c.isClosed, isLoopback: c.isLoopback)
    }

    /// Handshaken clients as values, oldest first.
    var clientSnapshots: [ClientSnapshot] {
        return clientList.filter { $0.identity != nil && !$0.isClosed }.map { InkRouter.snapshot($0) }
    }

    var inkClientCount: Int {
        return connections.values.filter { $0.identity != nil && $0.allowed && ($0.role == .web || $0.role == .ink) }.count
    }

    // MARK: Connections

    func clientOpened(_ c: InkConnection) {
        connections[c.id] = c
        onClientsChanged?(clientSnapshots)
    }

    func clientClosed(_ c: InkConnection) {
        c.markClosed()
        connections[c.id] = nil
        if !c.openStrokeIDs.isEmpty {
            for op in store.commitAll(ids: c.openStrokeIDs) { rasterizer?.apply(op, store: store) }
            pipeline.post(.clientGone(strokeIDs: c.openStrokeIDs))
            c.openStrokeIDs.removeAll()
        }
        if inkClientCount == 0 {
            pipeline.post(.allClientsGone)
        }
        if c.isActiveSource { recomputeActive() }
        onClientsChanged?(clientSnapshots)
        broadcastState()
    }

    // MARK: Messages

    func handle(_ bytes: [UInt8], from c: InkConnection, hostTimeNs: UInt64) {
        c.lastRxHostTimeNs = hostTimeNs
        let decoded: (Header, Message?)
        do {
            decoded = try bytes.withUnsafeBytes { try Codec.decodeLenient($0) }
        } catch CodecError.badMagic, CodecError.badVersion {
            c.close(code: 1002, reason: "not a SolStream peer")
            return
        } catch let CodecError.limitExceeded(opcode, value, max) {
            if opcode == SolStream.Opcode.handshake.rawValue || opcode == SolStream.Opcode.strokeChunk.rawValue || opcode == SolStream.Opcode.eraseStrokes.rawValue {
                onLog?("client \(c.label): opcode 0x\(String(opcode, radix: 16)) limit \(value) > \(max); dropped")
                return
            }
            c.close(code: 1009, reason: "payload too large")
            return
        } catch CodecError.lengthMismatch {
            if !c.lengthMismatchLogged {
                c.lengthMismatchLogged = true
                onLog?("client \(c.label): payload_len mismatch; message dropped")
            }
            return
        } catch {
            onLog?("client \(c.label): malformed message dropped (\(error))")
            return
        }
        let header = decoded.0
        guard let message = decoded.1 else {
            if !c.loggedUnknownOpcodes.contains(header.opcode) {
                c.loggedUnknownOpcodes.insert(header.opcode)
                onLog?("client \(c.label): unknown opcode 0x\(String(header.opcode, radix: 16)) ignored")
            }
            return
        }
        guard c.identity != nil else {
            if case let .handshake(width, height, _, name) = message {
                handleHandshake(c, width: width, height: height, name: name)
            } else {
                c.close(code: 1002, reason: "handshake expected")
            }
            return
        }
        let now = CACurrentMediaTime()
        switch message {
        case .handshake:
            onLog?("client \(c.label): second handshake ignored")
        case let .ping(sequence, clientTimeUs):
            c.send(.pong(sequence: sequence, clientTimeUs: clientTimeUs))
        case .togglePin, .clearCanvas, .autoEngageReturn:
            guard c.allowed else { return }
            if c.denied { c.close(code: 1008, reason: "not allowed"); return }
            handleControl(message, from: c)
        default:
            if c.denied { c.close(code: 1008, reason: "not allowed"); return }
            guard c.allowed else { return }   // pending: decoded and dropped, STATE keeps flowing
            guard c.isActiveSource || c.role == .test else { return }   // non-active source: dropped silently
            handleInk(message, from: c, hostTimeNs: hostTimeNs, now: now)
        }
    }

    private func handleControl(_ message: Message, from c: InkConnection) {
        switch message {
        case let .togglePin(value, _):
            pipeline.post(.pin(value))
        case .clearCanvas:
            clearRequested()
        case .autoEngageReturn:
            pipeline.post(.returnNow)
        default:
            break
        }
    }

    private func handleInk(_ message: Message, from c: InkConnection, hostTimeNs: UInt64, now: Double) {
        switch message {
        case let .strokeStart(start):
            guard start.engages else {
                onLog?("client \(c.label): STROKE_START pointer=\(start.pointer) phase=\(start.phase) pressure=\(start.pressure) dropped")
                return
            }
            noteInk(now: now)
            if let op = store.start(start, scale: c.scale) { rasterizer?.apply(op, store: store) }
            c.openStrokeIDs.insert(start.id)
            onEngagingStart?(hostTimeNs)
            pipeline.post(.contact(strokeID: start.id, pointer: start.pointer, phase: start.phase, pressure: start.pressure, tool: start.tool))
        case let .strokeChunk(id, points):
            guard c.openStrokeIDs.contains(id) else { return }
            noteInk(now: now)
            if let op = store.append(id: id, points: points, now: now) {
                rasterizer?.apply(op, store: store)
                pipeline.post(.motion(strokeID: id))
            }
        case let .strokeCommit(id, pointCount):
            guard c.openStrokeIDs.contains(id) else { return }
            if let stroke = store.stroke(id: id), stroke.points.count != Int(pointCount) {
                onLog?("client \(c.label): stroke \(id) commit count \(pointCount) vs \(stroke.points.count) received")
            }
            if let op = store.commit(id: id, pointCount: pointCount) { rasterizer?.apply(op, store: store) }
            c.openStrokeIDs.remove(id)
            pipeline.post(.lift(strokeID: id))
            broadcastState()
        case let .strokeCancel(id):
            guard c.openStrokeIDs.contains(id) else { return }
            if let op = store.cancel(id: id) { rasterizer?.apply(op, store: store) }
            c.openStrokeIDs.remove(id)
            pipeline.post(.cancel(strokeID: id))
            broadcastState()
        case .undo:
            if let op = store.undo(now: now) {
                rasterizer?.apply(op, store: store)
                noteInk(now: now)
            }
            pipeline.post(.activity)
            broadcastState()
        case .redo:
            if let op = store.redo(now: now) {
                rasterizer?.apply(op, store: store)
                noteInk(now: now)
            }
            pipeline.post(.activity)
            broadcastState()
        case let .eraseStrokes(x1, y1, x2, y2, radius, ids):
            if let op = store.erase(x1: x1, y1: y1, x2: x2, y2: y2, radius: radius, hint: ids, now: now) {
                rasterizer?.apply(op, store: store)
                noteInk(now: now)
                broadcastState()
            }
            pipeline.post(.activity)
        case .laserPoint:
            pipeline.post(.activity)
        case let .pageChange(pageID, width, height, _):
            newPage(id: pageID, width: Double(width), height: Double(height))
            pipeline.post(.activity)
        default:
            break
        }
    }

    // MARK: Handshake and the allow gate (PROTOCOL section 8)

    private func handleHandshake(_ c: InkConnection, width: Float, height: Float, name: String) {
        guard let identity = Identity(name: name), width > 0, height > 0 else {
            c.send(.handshakeAck(width: SolStream.targetWidth, height: SolStream.targetHeight, fps: SolStream.targetFPS, status: .unsupported))
            c.close(code: 1002, reason: "unsupported handshake")
            onLog?("client \(c.remote): handshake rejected (name '\(name)', canvas \(width)x\(height))")
            return
        }
        c.identity = identity
        c.scale = (Double(SolStream.canvasWidth) / Double(width), Double(SolStream.canvasHeight) / Double(height))
        if Int(width) != SolStream.canvasWidth || Int(height) != SolStream.canvasHeight {
            onLog?("client \(identity.label): canvas \(width)x\(height) scaled by \(c.scale)")
        }
        let record = registry.lookup(id: identity.clientID)
        if record?.allowed == true {
            registry.noteSeen(id: identity.clientID, label: identity.label, role: identity.role.rawValue, address: c.remote)
            grant(c)
        } else if c.isLoopback && registry.trustLoopback {
            registry.recordLoopback(id: identity.clientID, label: identity.label, role: identity.role.rawValue)
            grant(c)
        } else if registry.isDeniedThisSession(id: identity.clientID) {
            c.denied = true
            c.send(.handshakeAck(width: SolStream.targetWidth, height: SolStream.targetHeight, fps: SolStream.targetFPS, status: .denied))
            c.close(code: 1008, reason: "not allowed")
        } else {
            c.pending = true
            c.send(.handshakeAck(width: SolStream.targetWidth, height: SolStream.targetHeight, fps: SolStream.targetFPS, status: .pendingApproval))
            c.sendState(stateReport(for: c))
            onLog?(FailureText.logLine(.allowDismissed, [identity.clientID]))
            pendingAllow?(InkRouter.snapshot(c))
        }
        onClientsChanged?(clientSnapshots)
    }

    private func grant(_ c: InkConnection) {
        c.allowed = true
        c.pending = false
        c.denied = false
        makeActiveIfMatching(c)
        c.send(.handshakeAck(width: SolStream.targetWidth, height: SolStream.targetHeight, fps: SolStream.targetFPS, status: .ok))
        c.sendState(stateReport(for: c))
        onLog?("client \(c.label) (\(c.role?.rawValue ?? "?")) allowed from \(c.remote)\(c.isLoopback ? " over USB" : "")")
    }

    /// The owner clicked Allow (main thread hop lands here on ink.queue).
    func allow(connectionID: UUID) {
        guard let c = connections[connectionID], let identity = c.identity else { return }
        registry.allow(id: identity.clientID, label: identity.label, role: identity.role.rawValue, address: c.remote)
        for other in connections.values where other.pending && other.clientID == identity.clientID {
            grant(other)
        }
        if c.pending { grant(c) }
        onClientsChanged?(clientSnapshots)
        broadcastState()
    }

    /// The owner clicked Not now.
    func deny(connectionID: UUID) {
        guard let c = connections[connectionID], let identity = c.identity else { return }
        registry.deny(id: identity.clientID)
        c.denied = true
        c.pending = false
        c.send(.handshakeAck(width: SolStream.targetWidth, height: SolStream.targetHeight, fps: SolStream.targetFPS, status: .denied))
        c.close(code: 1008, reason: "not allowed")
        onClientsChanged?(clientSnapshots)
    }

    var pendingConnections: [InkConnection] {
        return clientList.filter { $0.pending && !$0.isClosed }
    }

    // MARK: Active source (PROTOCOL section 8)

    func setActiveSource(_ source: InkSource) {
        guard source != activeSource else { return }
        activeSource = source
        recomputeActive()
        broadcastState()
    }

    private static func role(for source: InkSource) -> SolStream.Role? {
        switch source {
        case .web: return .web
        case .native: return .ink
        case .mirror: return nil
        }
    }

    private func makeActiveIfMatching(_ c: InkConnection) {
        guard let role = c.role else { return }
        if role == .test || role == .overlay {
            c.isActiveSource = true
            return
        }
        guard role == InkRouter.role(for: activeSource) else {
            c.isActiveSource = false
            return
        }
        for other in connections.values where other.id != c.id && other.isActiveSource && other.role == role {
            other.isActiveSource = false
            if other.identity != nil && !other.isClosed { other.sendState(stateReport(for: other)) }
        }
        c.isActiveSource = true
    }

    /// The most recently handshaken allowed client of the role matching the ink source becomes active.
    private func recomputeActive() {
        let wanted = InkRouter.role(for: activeSource)
        var newest: InkConnection?
        for c in connections.values where c.identity != nil && !c.isClosed {
            if c.role == .test || c.role == .overlay {
                c.isActiveSource = true
                continue
            }
            c.isActiveSource = false
            if c.allowed, let wanted = wanted, c.role == wanted {
                if newest == nil || c.openedAtNs > newest!.openedAtNs { newest = c }
            }
        }
        newest?.isActiveSource = true
    }

    // MARK: STATE (PROTOCOL 6.14)

    func stateReport(for c: InkConnection) -> StateReport {
        var flags = lastGlobalFlags
        if c.allowed { flags.insert(.clientAllowed) }
        if c.isActiveSource { flags.insert(.clientIsActiveSource) }
        return pipeline.governorSnapshot.stateReport(
            clientFlags: flags, inkSource: activeSource,
            pageIndex: store.pageIndex, strokeCount: store.committedCount, undoDepth: store.undoDepth, redoDepth: store.redoDepth)
    }

    /// Sends the current STATE to every handshaken client (router-side changes: page, depths, active source).
    func broadcastState() {
        for c in connections.values where c.identity != nil && !c.isClosed {
            c.sendState(stateReport(for: c))
        }
    }

    /// Sends a pipeline-originated STATE (governor fields and global flags), with the page and client bits filled in.
    func broadcast(_ report: StateReport) {
        for c in connections.values where c.identity != nil && !c.isClosed {
            var flags = StateReport.Flags(rawValue: report.flags)
            flags.remove([.clientAllowed, .clientIsActiveSource])
            if c.allowed { flags.insert(.clientAllowed) }
            if c.isActiveSource { flags.insert(.clientIsActiveSource) }
            var copy = report
            copy.flags = flags.rawValue
            copy.inkSource = activeSource.rawValue
            copy.pageIndex = InkRouter.saturate16(store.pageIndex)
            copy.strokeCount = InkRouter.saturate16(store.committedCount)
            copy.undoDepth = InkRouter.saturate16(store.undoDepth)
            copy.redoDepth = InkRouter.saturate16(store.redoDepth)
            c.sendState(copy)
        }
    }

    static func saturate16(_ v: Int) -> UInt16 {
        if v <= 0 { return 0 }
        if v >= Int(UInt16.max) { return UInt16.max }
        return UInt16(v)
    }

    // MARK: Pages and saving (SPEC 12)

    private func noteInk(now: Double) {
        if SessionFiles.startsNewSession(lastInkAt: lastInkMonotonic, now: now) {
            sessionStart = Date()
            saver?.forgetAllPages()
            onLog?("new session \(sessionStart!)")
        }
        lastInkMonotonic = now
    }

    /// Clear from any input (SPEC 7): save if ink, clear both layers and the undo stack, then let the governor
    /// decide the return. The governor's own `savePage`/`clearCanvas` effects find nothing left to do.
    func clearRequested() {
        savePage(reason: .cleared)
        clearCanvas()
        pipeline.post(.clear)
    }

    /// Governor effect `clearCanvas` (also used directly by `clearRequested`).
    func clearCanvas() {
        let hadInk = store.hasInk
        let op = store.clear()
        rasterizer?.apply(op, store: store)
        saver?.forgetPage(store.pageID)
        if hadInk { broadcastState() }
    }

    /// New page (PAGE_CHANGE): save the current page if it has ink, start blank, board stays up.
    func newPage(id: UUID, width: Double, height: Double) {
        savePage(reason: .pageChange)
        let op = store.newPage(id: id, index: store.pageIndex + 1, width: width, height: height)
        rasterizer?.apply(op, store: store)
        saver?.forgetPage(id)
        broadcastState()
    }

    /// Governor effect `savePage(reason:)` and every other save trigger; a page is written only when dirty.
    func savePage(reason: SaveReason) {
        guard let saver = saver, store.isDirty else { return }
        let start = sessionStart ?? Date()
        if sessionStart == nil { sessionStart = start }
        let label = connections.values.first(where: { $0.isActiveSource && $0.identity != nil })?.label ?? activeSource.displayName
        let document = store.document(sessionStart: start, savedAt: Date(), reason: reason, inkSource: activeSource, clientLabel: label, app: appLabel)
        let snapshot = store
        let stamp = CACurrentMediaTime()
        setSaving(true)
        saver.save(document, strokes: snapshot, sessionStart: start, pageKey: store.pageID) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                self.setSaving(false)
                if case .success = result {
                    self.store.markSaved(at: stamp)
                }
                self.onSaveResult?(result)
            }
        }
    }

    private func setSaving(_ v: Bool) {
        guard saving != v else { return }
        saving = v
        onSaving?(v)
    }

    /// Autosave every `autosaveSeconds` while dirty (SPEC 12), on ink.queue.
    func startAutosave() {
        autosaveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = Double(settings.autosaveSeconds)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.store.isDirty { self.savePage(reason: .autosave) }
        }
        autosaveTimer = timer
        timer.activate()
    }

    func stopAutosave() {
        autosaveTimer?.cancel()
        autosaveTimer = nil
    }

    /// Quit: save the page if dirty and wait up to `timeout` for the writer (SPEC 12).
    func saveOnQuit(timeout: Double) {
        queue.sync { self.savePage(reason: .quit) }
        saver?.waitUntilIdle(timeout: timeout)
    }

    func updateSettings(_ s: Settings) {
        settings = s.validated()
        registry.trustLoopback = settings.trustLoopback
        if autosaveTimer != nil { startAutosave() }
    }
}
