import DaylightKit
import XCTest
@testable import Daylight

/// A `PipelineControl` that records events and runs a real governor so STATE fields are meaningful.
final class FakePipeline: PipelineControl {
    private(set) var events: [GovernorEvent] = []
    private var governor = EngageGovernor(config: GovernorConfig(), now: 0)
    var now: Double = 0
    var onStateForClients: ((StateReport) -> Void)?

    func post(_ event: GovernorEvent) {
        events.append(event)
        _ = governor.handle(event, now: now)
    }

    var governorSnapshot: GovernorOutput { return governor.snapshot }
    func setViewerCount(_ n: Int) {}
    func setPreviewVisible(_ visible: Bool) {}
    func setSinkConnected(_ connected: Bool) {}
}

final class InkRouterTests: XCTestCase {
    private var pipeline: FakePipeline!
    private var registry: ClientRegistry!
    private var registryURL: URL!
    private var saver: SessionSaver!
    private var saveRoot: URL!
    private var router: InkRouter!
    private var surfaces: CanvasSurfaces!
    private let ioQueue = DispatchQueue(label: "router-test.io")
    private let inkQueue = DispatchQueue(label: "router-test.ink")

    override func setUpWithError() throws {
        pipeline = FakePipeline()
        registryURL = FileManager.default.temporaryDirectory.appendingPathComponent("clients-\(UUID().uuidString).json")
        registry = ClientRegistry(fileURL: registryURL, ioQueue: ioQueue, trustLoopback: true)
        saveRoot = FileManager.default.temporaryDirectory.appendingPathComponent("save-\(UUID().uuidString)", isDirectory: true)
        saver = SessionSaver(root: saveRoot, queue: ioQueue)
        surfaces = try CanvasSurfaces(device: nil)
        router = InkRouter(pipeline: pipeline, rasterizer: InkRasterizer(surfaces: surfaces), registry: registry, saver: saver, settings: Settings.defaults, queue: inkQueue)
    }

    override func tearDown() {
        ioQueue.sync {}
        try? FileManager.default.removeItem(at: registryURL)
        try? FileManager.default.removeItem(at: saveRoot)
        super.tearDown()
    }

    private func bytes(_ hex: String) -> [UInt8] { return Hex.decode(hex)! }

    private func connect(address: String, name: String = "web;6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b;Mike's DC-1") -> (InkConnection, FakeTransport) {
        let transport = FakeTransport(address: address)
        let connection = InkConnection(transport: transport)
        router.clientOpened(connection)
        let handshake = Codec.encode(.handshake(canvasWidth: 1200, canvasHeight: 1600, dpi: 200, name: name), timestampUs: 1)
        router.handle(handshake, from: connection, hostTimeNs: 1)
        return (connection, transport)
    }

    private func drawGoldenStroke(_ connection: InkConnection) {
        router.handle(bytes(SelfTest.Golden.strokeStart), from: connection, hostTimeNs: 2)
        router.handle(bytes(SelfTest.Golden.strokeChunk3), from: connection, hostTimeNs: 3)
        router.handle(bytes(SelfTest.Golden.strokeCommit), from: connection, hostTimeNs: 4)
    }

    func testLoopbackClientIsAllowedAtOnceAndRecordedAsSeenOverUSB() {
        let (connection, transport) = connect(address: "127.0.0.1")
        XCTAssertEqual(transport.acks, [.ok])
        XCTAssertTrue(connection.allowed)
        XCTAssertTrue(connection.isActiveSource)
        XCTAssertEqual(transport.states.count, 1)
        XCTAssertTrue(transport.states[0].flagSet.contains(.clientAllowed))
        XCTAssertTrue(transport.states[0].flagSet.contains(.clientIsActiveSource))
        let record = registry.lookup(id: "6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b")
        XCTAssertEqual(record?.allowed, true)
        XCTAssertEqual(record?.seenOverUSB, true)
        XCTAssertEqual(record?.label, "Mike's DC-1")
        XCTAssertEqual(record?.roles, ["web"])
    }

    func testUnknownWirelessClientIsPendingUntilAllowed() {
        var prompted: [UUID] = []
        router.pendingAllow = { prompted.append($0.connectionID) }
        let (connection, transport) = connect(address: "192.168.1.40")
        XCTAssertEqual(transport.acks, [.pendingApproval])
        XCTAssertTrue(connection.pending)
        XCTAssertFalse(connection.allowed)
        XCTAssertEqual(prompted, [connection.id])
        XCTAssertEqual(transport.states.count, 1)
        XCTAssertFalse(transport.states[0].flagSet.contains(.clientAllowed), "STATE bit2 clear while pending")
        drawGoldenStroke(connection)
        XCTAssertEqual(router.store.committedCount, 0, "ink from a pending client is decoded and dropped")
        XCTAssertTrue(pipeline.events.isEmpty)
        XCTAssertNil(transport.closeCode, "the socket stays pending, no auto-deny")
        router.allow(connectionID: connection.id)
        XCTAssertEqual(transport.acks, [.pendingApproval, .ok])
        XCTAssertTrue(transport.states.last!.flagSet.contains(.clientAllowed))
        XCTAssertEqual(registry.lookup(id: "6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b")?.lastAddress, "192.168.1.40")
        XCTAssertEqual(registry.lookup(id: "6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b")?.seenOverUSB, false)
        drawGoldenStroke(connection)
        XCTAssertEqual(router.store.committedCount, 1)
    }

    func testNotNowSendsDeniedAndCloses1008() {
        let (connection, transport) = connect(address: "192.168.1.40")
        router.deny(connectionID: connection.id)
        XCTAssertEqual(transport.acks, [.pendingApproval, .denied])
        XCTAssertEqual(transport.closeCode, 1008)
        XCTAssertTrue(connection.isClosed)
        // The same tablet dialling again in this session is denied without a prompt.
        let (again, transportAgain) = connect(address: "192.168.1.40")
        XCTAssertEqual(transportAgain.acks, [.denied])
        XCTAssertTrue(again.denied)
    }

    func testRememberedClientNeedsNoPromptOverWiFi() {
        registry.recordLoopback(id: "6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b", label: "Mike's DC-1", role: "web")
        let (connection, transport) = connect(address: "192.168.1.40")
        XCTAssertEqual(transport.acks, [.ok])
        XCTAssertTrue(connection.allowed)
    }

    func testOverlayRoleReusesTheInkClientsAllowance() {
        let (_, inkTransport) = connect(address: "192.168.1.40", name: "ink;ABC;Tablet")
        XCTAssertEqual(inkTransport.acks, [.pendingApproval])
        let (_, overlayTransport) = connect(address: "192.168.1.40", name: "overlay;ABC;Tablet")
        XCTAssertEqual(overlayTransport.acks, [.pendingApproval], "the overlay waits with the canvas")
        let pending = router.pendingConnections
        XCTAssertEqual(pending.count, 2)
        router.allow(connectionID: pending[0].id)
        XCTAssertEqual(inkTransport.acks.last, .ok)
        XCTAssertEqual(overlayTransport.acks.last, .ok, "one Allow covers both roles of the same clientId")
        let (_, later) = connect(address: "192.168.1.41", name: "overlay;ABC;Tablet")
        XCTAssertEqual(later.acks, [.ok], "the overlay never prompts once the ink client was allowed")
    }

    func testBadHandshakeNameGetsAck3AndClose1002() {
        let (connection, transport) = connect(address: "127.0.0.1", name: "no-semicolons")
        XCTAssertEqual(transport.acks, [.unsupported])
        XCTAssertEqual(transport.closeCode, 1002)
        XCTAssertNil(connection.identity)
    }

    func testFirstMessageMustBeAHandshake() {
        let transport = FakeTransport(address: "127.0.0.1")
        let connection = InkConnection(transport: transport)
        router.clientOpened(connection)
        router.handle(bytes(SelfTest.Golden.strokeStart), from: connection, hostTimeNs: 1)
        XCTAssertEqual(transport.closeCode, 1002)
    }

    func testGoldenStrokeDrivesStoreRasterizerAndGovernor() {
        let (connection, transport) = connect(address: "127.0.0.1")
        drawGoldenStroke(connection)
        XCTAssertEqual(router.store.committedCount, 1)
        XCTAssertEqual(router.store.undoDepth, 1)
        XCTAssertEqual(pipeline.events.count, 3)
        if case let .contact(id, pointer, phase, pressure, tool) = pipeline.events[0] {
            XCTAssertEqual(id, UUID(uuidString: "00010203-0405-0607-0809-0a0b0c0d0e0f"))
            XCTAssertEqual(pointer, .stylus)
            XCTAssertEqual(phase, .contact)
            XCTAssertEqual(pressure, 0.73, accuracy: 1e-6)
            XCTAssertEqual(tool, .pen)
        } else {
            XCTFail("first event is contact: \(pipeline.events)")
        }
        XCTAssertEqual(pipeline.events[1], .motion(strokeID: UUID(uuidString: "00010203-0405-0607-0809-0a0b0c0d0e0f")!))
        XCTAssertEqual(pipeline.events[2], .lift(strokeID: UUID(uuidString: "00010203-0405-0607-0809-0a0b0c0d0e0f")!))
        XCTAssertEqual(pipeline.governorSnapshot.state, .engaging)
        XCTAssertGreaterThan(CanvasSurfaces.pixel(surfaces.ink, x: 650, y: 900).a, 0)
        let last = transport.states.last!
        XCTAssertEqual(last.undoDepth, 1)
        XCTAssertEqual(last.strokeCount, 1)
        XCTAssertEqual(last.governor, GovernorState.engaging.rawValue)
        XCTAssertTrue(connection.openStrokeIDs.isEmpty)
    }

    func testFingerStrokeStartIsDroppedWithItsChunks() {
        let (connection, _) = connect(address: "127.0.0.1")
        let finger = StrokeStart(id: UUID(uuidString: "00010203-0405-0607-0809-0a0b0c0d0e0f")!, tool: .pen, colorARGB: 0xFF11_1111, baseWidth: 3.2, pointer: .finger, phase: .contact, pressure: 0.7)
        router.handle(Codec.encode(.strokeStart(finger), timestampUs: 1), from: connection, hostTimeNs: 1)
        router.handle(bytes(SelfTest.Golden.strokeChunk3), from: connection, hostTimeNs: 2)
        router.handle(bytes(SelfTest.Golden.strokeCommit), from: connection, hostTimeNs: 3)
        XCTAssertTrue(pipeline.events.isEmpty)
        XCTAssertEqual(router.store.committedCount, 0)
        XCTAssertEqual(CanvasSurfaces.pixel(surfaces.ink, x: 650, y: 900).a, 0)
        let hover = StrokeStart(id: UUID(), tool: .pen, colorARGB: 0xFF11_1111, baseWidth: 3.2, pointer: .stylus, phase: .contact, pressure: 0)
        router.handle(Codec.encode(.strokeStart(hover), timestampUs: 1), from: connection, hostTimeNs: 1)
        XCTAssertTrue(pipeline.events.isEmpty, "pressure 0 never engages")
    }

    func testNewestClientOfTheSourceRoleIsActiveAndOthersAreDropped() {
        let (older, olderTransport) = connect(address: "127.0.0.1", name: "web;OLD;Tablet A")
        let (newer, newerTransport) = connect(address: "127.0.0.1", name: "web;NEW;Tablet B")
        XCTAssertFalse(older.isActiveSource)
        XCTAssertTrue(newer.isActiveSource)
        XCTAssertFalse(olderTransport.states.last!.flagSet.contains(.clientIsActiveSource), "the older client learns it lost bit3")
        XCTAssertTrue(newerTransport.states.last!.flagSet.contains(.clientIsActiveSource))
        drawGoldenStroke(older)
        XCTAssertEqual(router.store.committedCount, 0, "ink from a non-active source is dropped silently")
        // Control messages still work from any allowed client.
        router.handle(bytes("da0161000900000040e2cfeeb5400600ff40e2cfeeb5400600"), from: older, hostTimeNs: 5)
        XCTAssertEqual(pipeline.events.last, .pin(-1))
        // Switching the source to native leaves no web client active.
        router.setActiveSource(.native)
        XCTAssertFalse(newer.isActiveSource)
        XCTAssertEqual(newerTransport.states.last!.inkSource, InkSource.native.rawValue)
        XCTAssertEqual(pipeline.events.filter { if case .sourceChanged = $0 { return true } else { return false } }.count, 0, "the pipeline posts sourceChanged itself")
        let (native, nativeTransport) = connect(address: "127.0.0.1", name: "ink;APK;Daylight Ink")
        XCTAssertTrue(native.isActiveSource)
        XCTAssertTrue(nativeTransport.states.last!.flagSet.contains(.clientIsActiveSource))
        // The test role may send everything in every source.
        let (test, _) = connect(address: "127.0.0.1", name: "test;T;Self-test")
        XCTAssertTrue(test.isActiveSource)
        drawGoldenStroke(test)
        XCTAssertEqual(router.store.committedCount, 1)
    }

    func testClientDisconnectCommitsOpenStrokesAndNeverChangesState() {
        let (connection, _) = connect(address: "127.0.0.1")
        router.handle(bytes(SelfTest.Golden.strokeStart), from: connection, hostTimeNs: 2)
        router.handle(bytes(SelfTest.Golden.strokeChunk3), from: connection, hostTimeNs: 3)
        XCTAssertEqual(router.store.activeStrokeIDs.count, 1)
        let stateBefore = pipeline.governorSnapshot.state
        router.clientClosed(connection)
        XCTAssertEqual(router.store.committedCount, 1, "the open stroke is committed as it stands")
        XCTAssertTrue(router.store.activeStrokeIDs.isEmpty)
        XCTAssertEqual(pipeline.events.last, .allClientsGone)
        XCTAssertTrue(pipeline.events.contains(.clientGone(strokeIDs: [UUID(uuidString: "00010203-0405-0607-0809-0a0b0c0d0e0f")!])))
        XCTAssertEqual(pipeline.governorSnapshot.state, stateBefore, "D37: a disconnect never changes the governor state")
        XCTAssertTrue(router.clientList.isEmpty)
    }

    func testClearSavesOnceThenClearsAndPostsClear() {
        let (connection, _) = connect(address: "127.0.0.1")
        drawGoldenStroke(connection)
        let saved = expectation(description: "saved")
        var urls: [URL] = []
        router.onSaveResult = { result in
            if case let .success(written) = result { urls = written }
            saved.fulfill()
        }
        router.handle(bytes("da0140001800000040e2cfeeb5400600101112131415161718191a1b1c1d1e1f40e2cfeeb5400600"), from: connection, hostTimeNs: 9)
        wait(for: [saved], timeout: 5)
        inkQueue.sync {}
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls.map { $0.lastPathComponent }.sorted(), ["page-01.json", "page-01.png"])
        XCTAssertEqual(router.store.committedCount, 0)
        XCTAssertEqual(CanvasSurfaces.pixel(surfaces.ink, x: 650, y: 900).a, 0, "both layers cleared")
        XCTAssertEqual(pipeline.events.last, .clear)
        // Clear again on the empty board: nothing new is written (SPEC 12: a pinned board cleared twice saves once).
        router.onSaveResult = { _ in XCTFail("no second save") }
        router.handle(bytes("da0140001800000040e2cfeeb5400600101112131415161718191a1b1c1d1e1f40e2cfeeb5400600"), from: connection, hostTimeNs: 10)
        ioQueue.sync {}
        let files = try? FileManager.default.subpathsOfDirectory(atPath: saveRoot.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(files?.count, 1)
    }

    func testPageChangeSavesAndStartsAFreshPage() {
        let (connection, transport) = connect(address: "127.0.0.1")
        drawGoldenStroke(connection)
        let saved = expectation(description: "saved")
        router.onSaveResult = { _ in saved.fulfill() }
        router.handle(bytes("da0150001c00000040e2cfeeb5400600101112131415161718191a1b1c1d1e1f000096440000c84402000000"), from: connection, hostTimeNs: 9)
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(router.store.pageIndex, 1)
        XCTAssertEqual(router.store.pageID, UUID(uuidString: "10111213-1415-1617-1819-1a1b1c1d1e1f"))
        XCTAssertEqual(router.store.committedCount, 0)
        XCTAssertEqual(transport.states.last?.pageIndex, 1)
        XCTAssertEqual(pipeline.events.last, .activity)
    }

    func testControlMessagesMapToGovernorEvents() {
        let (connection, _) = connect(address: "127.0.0.1")
        router.handle(bytes("da0160000800000040e2cfeeb540060040e2cfeeb5400600"), from: connection, hostTimeNs: 1)
        XCTAssertEqual(pipeline.events.last, .returnNow)
        router.handle(bytes("da0161000900000040e2cfeeb54006000140e2cfeeb5400600"), from: connection, hostTimeNs: 1)
        XCTAssertEqual(pipeline.events.last, .pin(1))
        router.handle(bytes("da0130001000000040e2cfeeb540060000001644000048440000803f0000003f"), from: connection, hostTimeNs: 1)
        XCTAssertEqual(pipeline.events.last, .activity, "LASER_POINT counts as activity")
        router.handle(bytes("da0120002600000040e2cfeeb54006000000c8420000c84200000c4300002043000040410100000102030405060708090a0b0c0d0e0f"), from: connection, hostTimeNs: 1)
        XCTAssertEqual(pipeline.events.last, .activity, "ERASE_STROKES counts as activity")
    }

    func testMalformedInputIsHandledPerTheValidationTable() {
        let (connection, transport) = connect(address: "127.0.0.1")
        var logs: [String] = []
        router.onLog = { logs.append($0) }
        // Unknown opcode: ignored, logged once.
        router.handle(bytes("da01aa000000000040e2cfeeb5400600"), from: connection, hostTimeNs: 1)
        router.handle(bytes("da01aa000000000040e2cfeeb5400600"), from: connection, hostTimeNs: 1)
        XCTAssertEqual(logs.filter { $0.contains("unknown opcode") }.count, 1)
        XCTAssertNil(transport.closeCode)
        // payload_len mismatch: dropped, logged once.
        router.handle(bytes("da0112001500000040e2cfeeb5400600000102030405060708090a0b0c0d0e0f03000000"), from: connection, hostTimeNs: 1)
        router.handle(bytes("da0112001500000040e2cfeeb5400600000102030405060708090a0b0c0d0e0f03000000"), from: connection, hostTimeNs: 1)
        XCTAssertEqual(logs.filter { $0.contains("payload_len mismatch") }.count, 1)
        XCTAssertNil(transport.closeCode)
        // Bad magic closes 1002.
        router.handle(bytes("db0112001400000040e2cfeeb5400600000102030405060708090a0b0c0d0e0f03000000"), from: connection, hostTimeNs: 1)
        XCTAssertEqual(transport.closeCode, 1002)
    }

    func testPingIsAnsweredWithTheSamePayload() {
        let (connection, transport) = connect(address: "127.0.0.1")
        router.handle(bytes("da01fe001000000040e2cfeeb5400600070000000000000040e2cfeeb5400600"), from: connection, hostTimeNs: 1)
        XCTAssertEqual(transport.messages.last, .pong(sequence: 7, clientTimeUs: 1_760_000_000_123_456))
    }

    func testReceiveStateFillsPageFieldsAndClientBits() {
        let (_, transport) = connect(address: "127.0.0.1")
        let (pendingConnection, pendingTransport) = connect(address: "192.168.1.9", name: "web;P;Pending")
        XCTAssertTrue(pendingConnection.pending)
        let report = StateReport(governor: 2, flags: StateReport.Flags([.cameraAttached, .sinkConnected]).rawValue, mode: 0, inkSource: 0, progress: 1, msToReturn: 4200, pageIndex: 0, strokeCount: 0, undoDepth: 0, redoDepth: 0)
        router.receiveState(report)
        let allowedState = transport.states.last!
        XCTAssertEqual(allowedState.governor, 2)
        XCTAssertEqual(allowedState.msToReturn, 4200)
        XCTAssertTrue(allowedState.flagSet.contains(.cameraAttached))
        XCTAssertTrue(allowedState.flagSet.contains(.clientAllowed))
        let pendingState = pendingTransport.states.last!
        XCTAssertFalse(pendingState.flagSet.contains(.clientAllowed), "STATE keeps flowing to a pending client without bit2")
        XCTAssertTrue(pendingState.flagSet.contains(.sinkConnected))
    }
}
