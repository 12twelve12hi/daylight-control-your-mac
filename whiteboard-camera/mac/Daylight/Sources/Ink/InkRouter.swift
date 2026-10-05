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
    /// Wall-clock time of the newest ink (the monotonic clock stops while the Mac sleeps): the D6 fresh-page rule and
    /// the SPEC 12 session gap both measure idle time across a sleep.
    private(set) var lastInkWall: Date?
    /// Daylight Camera's viewer count as last reported (SPEC C3) and since when it has been 0, for the D6 new call.
    private(set) var viewers = FreshPage.Viewers()
    /// A new call arrived while a stroke was open (review F6): the rule is decided again when the last stroke lifts.
    private(set) var freshPagePending = false
    /// Injectable for tests.
    var wallClock: () -> Date = { Date() }
    private var autosaveTimer: DispatchSourceTimer?
    private var saving = false
    /// D39: which session still needs its `session.pdf` (see `SessionHandout`).
    private(set) var handout = HandoutTracker()

    /// "Daylight <version> (<build>)" for the JSON `app` field.
    var appLabel = "Daylight"
    /// A value copy of a connection's state for the main thread (the router mutates connections on ink.queue only).
    struct ClientSnapshot: Equatable {
        let connectionID: UUID
        /// The tablet the prompt is about: an Allow is remembered by this id even when the socket already closed.
        let clientID: String
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
        return ClientSnapshot(connectionID: c.id, clientID: c.clientID ?? "", label: c.label, role: c.role?.rawValue ?? "", address: c.remote, allowed: c.allowed, active: c.isActiveSource, pending: c.pending && !c.isClosed, isLoopback: c.isLoopback)
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
        freshPageAfterLift()
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
            if opcode == SolStream.Opcode.handshake.rawValue && max == SolStream.maxNameLength && c.identity == nil {
                rejectHandshake(c, reason: "name_len \(value) outside 1...\(max)")
                return
            }
            if opcode == SolStream.Opcode.handshake.rawValue || opcode == SolStream.Opcode.strokeChunk.rawValue || opcode == SolStream.Opcode.eraseStrokes.rawValue {
                onLog?("client \(c.label): opcode 0x\(String(opcode, radix: 16)) limit \(value) > \(max); dropped")
                return
            }
            c.close(code: 1009, reason: "payload too large")
            return
        } catch CodecError.lengthMismatch {
            if c.identity == nil && InkRouter.headerOpcode(bytes) == SolStream.Opcode.handshake.rawValue {
                rejectHandshake(c, reason: "payload_len mismatch")
                return
            }
            if !c.lengthMismatchLogged {
                c.lengthMismatchLogged = true
                onLog?("client \(c.label): payload_len mismatch; message dropped")
            }
            return
        } catch {
            if c.identity == nil && InkRouter.headerOpcode(bytes) == SolStream.Opcode.handshake.rawValue {
                rejectHandshake(c, reason: "\(error)")
                return
            }
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
            if c.role == .overlay {   // PROTOCOL 8: the pills send only TOGGLE_PIN, CLEAR_CANVAS and AUTO_ENGAGE_RETURN
                if !c.loggedUnknownOpcodes.contains(header.opcode) {
                    c.loggedUnknownOpcodes.insert(header.opcode)
                    onLog?("client \(c.label): overlay role sent opcode 0x\(String(header.opcode, radix: 16)); dropped")
                }
                return
            }
            // Non-active source: dropped silently. A stroke this connection opened while it was active may still
            // finish (CHUNK, COMMIT, CANCEL), so a client demoted mid-stroke never leaves a governor contact open.
            guard c.isActiveSource || c.role == .test || InkRouter.continuesOpenStroke(message, of: c) else { return }
            handleInk(message, from: c, hostTimeNs: hostTimeNs, now: now)
        }
    }

    private static func continuesOpenStroke(_ message: Message, of c: InkConnection) -> Bool {
        switch message {
        case let .strokeChunk(id, _), let .strokeCommit(id, _), let .strokeCancel(id):
            return c.openStrokeIDs.contains(id)
        default:
            return false
        }
    }

    /// The opcode field of a SolStream header (bytes 2...3, little-endian), or nil when the message is shorter.
    static func headerOpcode(_ bytes: [UInt8]) -> UInt16? {
        guard bytes.count >= 4 else { return nil }
        return UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
    }

    /// PROTOCOL 6.1 and 9: a first HANDSHAKE that does not decode is no handshake. ACK 3 and close 1002, the same
    /// answer as an unparsable name, so the client sees a protocol error instead of waiting for the idle close.
    private func rejectHandshake(_ c: InkConnection, reason: String) {
        c.send(.handshakeAck(width: SolStream.targetWidth, height: SolStream.targetHeight, fps: SolStream.targetFPS, status: .unsupported))
        c.close(code: 1002, reason: "unsupported handshake")
        onLog?("client \(c.remote): handshake rejected (\(reason))")
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
            freshPageAfterLift()
        case let .strokeCancel(id):
            guard c.openStrokeIDs.contains(id) else { return }
            if let op = store.cancel(id: id) { rasterizer?.apply(op, store: store) }
            c.openStrokeIDs.remove(id)
            pipeline.post(.cancel(strokeID: id))
            broadcastState()
            freshPageAfterLift()
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
        case let .laserPoint(x, y, intensity, decayS):
            // Ink Legibility R1: the Mac draws the dot. Scaled like strokes (a client may declare another canvas size);
            // the laser touches neither the store nor the canvas layers, so it is never saved, undone or erased.
            rasterizer?.laser(x: Double(x) * c.scale.0, y: Double(y) * c.scale.1, intensity: Double(intensity), decay: Double(decayS), now: now)
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
        // Role `test` is active in every ink source, so only the Mac's own loopback self-test may claim it: never a
        // network client, and never a browser page whose Origin is not this server (WebServer marks it non-loopback).
        if identity.role == .test && !c.isLoopback {
            rejectHandshake(c, reason: "role test from \(c.remote) is not a loopback client")
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
        } else {
            // A tablet that was told "Not now" prompts again on its next dial (PROTOCOL 8: the client re-dials only
            // on a user action), so a mis-click never locks it out until a relaunch.
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

    /// The owner clicked Allow (main thread hop lands here on ink.queue). The answer is about the tablet, not the
    /// socket (PROTOCOL 8: "ClientRegistry remembers the id forever"): when the pending socket closed before the
    /// click, the registry is still written from the prompt's own clientId, label, role and address, and any other
    /// pending connection of that clientId is granted.
    func allow(connectionID: UUID, clientID: String = "", label: String = "", role: String = "", address: String = "") {
        let id: String
        if let c = connections[connectionID], let identity = c.identity {
            id = identity.clientID
            registry.allow(id: id, label: identity.label, role: identity.role.rawValue, address: c.remote)
        } else if !clientID.isEmpty {
            id = clientID
            registry.allow(id: id, label: label, role: role, address: address)
        } else {
            return
        }
        for other in connections.values where other.pending && other.clientID == id {
            grant(other)
        }
        onClientsChanged?(clientSnapshots)
        broadcastState()
    }

    /// Allow for the connection a snapshot describes, remembered by its clientId even if that socket is gone.
    func allow(_ snapshot: ClientSnapshot) {
        allow(connectionID: snapshot.connectionID, clientID: snapshot.clientID, label: snapshot.label, role: snapshot.role, address: snapshot.address)
    }

    /// The owner clicked Not now: ACK 2 and close 1008; nothing is written and the next dial prompts again.
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
        if role == .test {
            c.isActiveSource = true
            return
        }
        if role == .overlay {   // the pills never draw, so STATE bit3 stays clear for them
            c.isActiveSource = false
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
            if c.role == .test {
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
        let wall = wallClock()
        let wallGap = lastInkWall.map { wall.timeIntervalSince($0) } ?? 0
        handout.noteInk(wall: wall, monotonic: now)
        if SessionFiles.startsNewSession(lastInkAt: lastInkMonotonic, now: now) || wallGap > SessionFiles.sessionGapSeconds {
            finishSessionHandout()   // D39: the session that just ended gets its PDF
            sessionStart = wall
            saver?.forgetAllPages()
            onLog?("new session \(sessionStart!)")
        }
        lastInkMonotonic = now
        lastInkWall = wall
    }

    // MARK: Fresh page for a new call (DRAWING-DEEP-DIVE D6)

    /// Daylight Camera's viewer count changed (the sink's `onViewerCount`, hopped to ink.queue; the watcher reports
    /// changes only). A new call is a 0 -> 1 or more after a 0 that lasted `FreshPage.settledZeroSeconds` (the sink's
    /// revalidate reconnect and a Zoom video toggle report a short 0 inside a call). On a new call, while the board is
    /// off the air (PASSTHROUGH, not pinned, no board hold) and the page's newest ink is older than
    /// `FreshPage.idleSeconds`, the page is saved and a blank page starts before any pen-down of the new call can
    /// engage: a STROKE_START that arrives after the count is handled after this, on the same queue. With a stroke
    /// open the decision waits for the last lift. The clients see the new page through STATE (page_index 0, no
    /// strokes, depths 0).
    func viewersChanged(_ count: Int) {
        let now = wallClock()
        let newCall = viewers.update(count, at: now)
        if viewers.count == 0 { freshPagePending = false }   // the call ended before the lift
        guard newCall else { return }
        freshPagePending = false
        applyFreshPageRule(now: now)
    }

    /// The Mac woke from sleep; `currentCount` is the watcher's count read at the wake. A 0 there starts the zero at
    /// the wake at the latest; a 1 or more does nothing (a call that holds the camera across a sleep keeps its page).
    func noteWake(currentCount: Int) {
        viewers.noteWake(currentCount: currentCount, at: wallClock())
        if viewers.count == 0 { freshPagePending = false }
    }

    /// The board as the rule sees it: the governor snapshot (the same lock-guarded read STATE uses) and the store.
    private func freshPageBoard() -> FreshPage.Board {
        let governor = pipeline.governorSnapshot
        let penOnGlass = connections.values.contains { !$0.openStrokeIDs.isEmpty } || !store.activeStrokeIDs.isEmpty
        return FreshPage.Board(state: governor.state, pinned: governor.pinned, hold: governor.hold, hasInk: store.hasInk, penOnGlass: penOnGlass, newestInkAt: lastInkWall)
    }

    private func applyFreshPageRule(now: Date) {
        switch FreshPage.decide(newCall: true, board: freshPageBoard(), now: now) {
        case .keep:
            break
        case .waitForLift:
            freshPagePending = true
        case .start:
            guard let newest = lastInkWall else { return }
            startFreshPageForNewCall(idleSeconds: now.timeIntervalSince(newest))
        }
    }

    /// Review F6: a new call that arrived during a stroke is decided when the last open stroke lifts or is cancelled
    /// (the call still running and every other condition still holding).
    private func freshPageAfterLift() {
        guard freshPagePending, viewers.count >= 1 else { return }
        freshPagePending = false
        applyFreshPageRule(now: wallClock())
    }

    private func startFreshPageForNewCall(idleSeconds: Double) {
        onLog?("fresh page: saved \(store.committedCount) strokes, idle \(Int(idleSeconds)) s, reason=new_call")
        // The new call is a new session (the idle span is past the SPEC 12 gap): its first page is page-01 again.
        newPage(id: UUID(), width: Double(SolStream.canvasWidth), height: Double(SolStream.canvasHeight), index: 0, reason: .newCall)
        finishSessionHandout()   // D39: the last call's session gets its PDF, queued after the page save above
        lastInkMonotonic = nil
        lastInkWall = nil
    }

    /// Clear from any input (SPEC 7): save if ink, clear both layers and the undo stack, then let the governor
    /// decide the return. The governor's own `savePage(.cleared)`/`clearCanvas` effects are not applied (see
    /// `applyGovernorEffect`).
    func clearRequested() {
        savePage(reason: .cleared)
        clearCanvas()
        pipeline.post(.clear)
    }

    /// The governor's page effects, as the app routes them here on ink.queue. Every app Clear (tablet, hotkey, menu)
    /// already saved and cleared synchronously in `clearRequested`, and a mirror-mode Clear must not touch the store
    /// (SPEC 7: step 2 is skipped there). The governor's `savePage(.cleared)` and `clearCanvas` reach this queue only
    /// after a render-queue hop, so applying them could save or wipe a stroke drawn after the Clear: they are ignored.
    func applyGovernorEffect(_ effect: GovernorEffect) {
        switch effect {
        case let .savePage(reason):
            if reason != .cleared { savePage(reason: reason) }
        case .clearCanvas, .stateChanged, .preWarningStarted, .preWarningCancelled, .pinChanged, .holdChanged:
            break
        }
    }

    /// Clears both layers and the undo stack (used by `clearRequested`).
    func clearCanvas() {
        let hadInk = store.hasInk
        let op = store.clear()
        rasterizer?.apply(op, store: store)
        saver?.forgetPage(store.pageID)
        if hadInk { broadcastState() }
    }

    /// New page (PAGE_CHANGE): save the current page if it has ink, start blank, board stays up. The save takes its
    /// snapshot of the store before the page changes, and the STATE that announces the new page goes out after it.
    /// `reason` is the saved JSON's `session.reason`: `.newCall` for the fresh page of a new call (D6).
    func newPage(id: UUID, width: Double, height: Double, index: Int? = nil, reason: SaveReason = .pageChange) {
        savePage(reason: reason)
        let op = store.newPage(id: id, index: index ?? store.pageIndex + 1, width: width, height: height)
        rasterizer?.apply(op, store: store)
        saver?.forgetPage(id)
        broadcastState()
    }

    /// Governor effect `savePage(reason:)` and every other save trigger; a page is written only when dirty.
    /// `written`, when given, hears on io.queue whether the queued save succeeded (not called when nothing was saved).
    func savePage(reason: SaveReason, written: ((Bool) -> Void)? = nil) {
        guard let saver = saver, store.isDirty else { return }
        let start = sessionStart ?? Date()
        if sessionStart == nil { sessionStart = start }
        let label = connections.values.first(where: { $0.isActiveSource && $0.identity != nil })?.label ?? activeSource.displayName
        let document = store.document(sessionStart: start, savedAt: Date(), reason: reason, inkSource: activeSource, clientLabel: label, app: appLabel)
        let snapshot = store
        let stamp = CACurrentMediaTime()
        setSaving(true)
        saver.save(document, strokes: snapshot, sessionStart: start, pageKey: store.pageID) { [weak self] result in
            if case .success = result { written?(true) } else { written?(false) }
            guard let self = self else { return }
            self.queue.async {
                self.setSaving(false)
                if case .success = result {
                    self.store.markSaved(at: stamp)
                }
                self.onSaveResult?(result)
            }
        }
        if let finished = handout.noteSaveQueued(sessionStart: start) { writeHandout(finished) }
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
            self.writeHandoutIfIdle(nowWall: self.wallClock())
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
        queue.sync {
            self.savePage(reason: .quit)
            self.finishSessionHandout()
        }
        saver?.waitUntilIdle(timeout: timeout)
    }

    // MARK: The board as the follow-up (D39, D40, D41)

    /// D39: writes the pending session's `session.pdf` now (a new session starts, quit, or a fresh page for a new
    /// call ends the session). Queued on io.queue after the saves already queued. ink.queue.
    func finishSessionHandout() {
        if let start = handout.takePending() { writeHandout(start) }
    }

    /// Autosave tick: the pending session's PDF once it is idle past the 10-minute gap by the wall clock or the
    /// monotonic clock (the Mac may have slept). ink.queue.
    func writeHandoutIfIdle(nowWall: Date = Date(), nowMonotonic: Double = CACurrentMediaTime()) {
        if let start = handout.takeIfIdle(nowWall: nowWall, nowMonotonic: nowMonotonic) { writeHandout(start) }
    }

    /// What "Send today's board..." learned from writing the current session: the PDF written now (nil when none was
    /// due), and whether the page save or the PDF write failed (review F8: the alert then says so).
    struct CurrentSessionWrite: Equatable {
        var pdf: URL?
        var failed: Bool
    }

    /// "Send today's board...": saves a dirty page (`.sendBoard`), writes the pending session's PDF, then calls
    /// `completion` on io.queue after every queued write. ink.queue.
    func writeCurrentSessionPDF(completion: @escaping (CurrentSessionWrite) -> Void) {
        // The save's result and the PDF's are both delivered on the serial io.queue, the save's first, so this box
        // is only touched there.
        final class Outcome { var saveFailed = false }
        let outcome = Outcome()
        savePage(reason: .sendBoard, written: { ok in if !ok { outcome.saveFailed = true } })
        if let start = handout.takePending() {
            writeHandout(start) { result in
                switch result {
                case let .success(url): completion(CurrentSessionWrite(pdf: url, failed: outcome.saveFailed))
                case .failure: completion(CurrentSessionWrite(pdf: nil, failed: true))
                }
            }
        } else if let saver = saver {
            saver.queue.async { completion(CurrentSessionWrite(pdf: nil, failed: outcome.saveFailed)) }
        } else {
            completion(CurrentSessionWrite(pdf: nil, failed: false))
        }
    }

    private func writeHandout(_ start: Date, completion: ((Result<URL?, Error>) -> Void)? = nil) {
        guard let saver = saver else {
            completion?(.success(nil))
            return
        }
        saver.writeSessionPDF(sessionStart: start) { [weak self] result in
            switch result {
            case let .success(url):
                if let url = url { self?.queue.async { self?.onLog?("session PDF written: \(url.lastPathComponent)") } }
            case let .failure(error):
                self?.queue.async { self?.onLog?("session PDF failed: \(error)") }
            }
            completion?(result)
        }
    }

    /// D40 "Copy last page": a value copy of the current page when it has ink, nil otherwise. The caller renders it
    /// off ink.queue (`LastPage.pngData`) so the ink path never waits on a 1200x1600 render. ink.queue.
    func currentPageSnapshot() -> StrokeStore? {
        return store.hasInk ? store : nil
    }

    /// Whether the current page has ink (the menu enables "Copy last page"). ink.queue.
    var pageHasInk: Bool {
        return store.hasInk
    }

    func updateSettings(_ s: Settings) {
        settings = s.validated()
        registry.trustLoopback = settings.trustLoopback
        if autosaveTimer != nil { startAutosave() }
    }
}
