import CoreVideo
import CryptoKit
import DaylightKit
import Foundation
import Metal

/// `Daylight --self-test [--perf-log]` (SPEC 16 B1): render probes (skipped with a warning without a Metal device),
/// the WebSocket round trip against the real listener on 127.0.0.1, the ink alpha probe and undo, the vendor facts.
/// Prints one line per probe and exits 0 only when every probe passed. Never touches the camera or the local network.
enum SelfTest {
    /// Golden vectors of PROTOCOL 12.1 (full frames, header included).
    enum Golden {
        static let handshake = "da0101004400000040e2cfeeb5400600000096440000c8440000484336007765623b36663161326233632d346435652d346636302d386139622d3063316432653366346135623b4d696b65e28099732044432d31"
        static let handshakeAckOk = "da0102001000000040e2cfeeb540060080070000380400001e00000000000000"
        static let strokeStart = "da0110001f00000040e2cfeeb5400600000102030405060708090a0b0c0d0e0f00111111ffcdcc4c40000148e13a3f"
        static let strokeChunk3 = "da0111003300000040e2cfeeb5400600000102030405060708090a0b0c0d0e0f03005001000098ffffffba0000800c000008190000330800ff950000e0c70000ffffff"
        static let strokeCommit = "da0112001400000040e2cfeeb5400600000102030405060708090a0b0c0d0e0f03000000"
        static let undoCurrentPage = "da0114001800000040e2cfeeb54006000000000000000000000000000000000040e2cfeeb5400600"
    }

    final class Report {
        private(set) var failures = 0
        private(set) var lines: [String] = []

        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            let line = "self-test: \(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")"
            lines.append(line)
            print(line)
            if !ok { failures += 1 }
        }

        func note(_ text: String) {
            let line = "self-test: \(text)"
            lines.append(line)
            print(line)
        }
    }

    static func run(_ arguments: LaunchArguments) -> Int32 {
        let report = Report()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        report.note("Daylight \(version) build \(build) pid \(ProcessInfo.processInfo.processIdentifier)")
        let device = MTLCreateSystemDefaultDevice()
        report.note("metal device: \(device?.name ?? "none")")
        if let device = device {
            renderProbes(device: device, report: report)
        } else {
            report.note("WARNING no Metal device on this machine; render probes skipped")
        }
        socketRoundTrip(device: device, report: report, perfLog: arguments.perfLog)
        vendorFacts(report: report)
        extensionFacts(report: report)
        report.note(Telemetry.perfLine(PipelineStats()))
        report.note(report.failures == 0 ? "PASS" : "\(report.failures) probe(s) failed")
        fflush(stdout)
        return report.failures == 0 ? 0 : 1
    }

    // MARK: Render probes (SPEC 6 numbers)

    static func renderProbes(device: MTLDevice, report: Report) {
        do {
            let compositor = try Compositor(device: device)
            let surfaces = try CanvasSurfaces(device: device)
            let pool = try OutputPool()
            guard let presenter = gradientBuffer(width: 1920, height: 1080) else {
                report.check("render: gradient presenter buffer", false)
                return
            }
            for s in [0.0, 0.5, 1.0] {
                guard let target = pool.acquire() else { report.check("render: pool buffer at s=\(s)", false); continue }
                let frame = StudioLayout.frame(progress: s, layout: .studioSplit, orientation: .portrait, canvasAspect: StudioLayout.portraitAspect, breath: 0)
                let gpu = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: frame), into: target)
                report.note(String(format: "render s=%.1f gpu %.3f ms", s, gpu * 1000))
                probe(target, presenter: presenter, progress: s, report: report)
                pool.release(target)
            }
            // Whiteboard Only (SPEC 6.3): canvas (555, 0, 810, 1080), cream both sides, no presenter, no divider.
            if let target = pool.acquire() {
                let frame = StudioLayout.frame(progress: 1, layout: .whiteboardOnly, orientation: .portrait, canvasAspect: StudioLayout.portraitAspect, breath: 0)
                _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: frame), into: target)
                report.check("render whiteboard-only paper at (960, 540)", matches(pixel(target, 960, 540), Tokens.paperBg), describe(pixel(target, 960, 540)))
                report.check("render whiteboard-only cream at (100, 540)", matches(pixel(target, 100, 540), Tokens.surfaceCream), describe(pixel(target, 100, 540)))
                report.check("render whiteboard-only cream at (1800, 540) (no presenter)", matches(pixel(target, 1800, 540), Tokens.surfaceCream), describe(pixel(target, 1800, 540)))
                report.check("render whiteboard-only border at (555, 540)", matches(pixel(target, 555, 540), Tokens.borderSubtle, tolerance: 60), describe(pixel(target, 555, 540)))
                pool.release(target)
            }
            // Landscape canvas (SPEC 6.4): canvas (0, 0, 1440, 1080), presenter dest (1440, 0, 480, 1080) from source x in [720, 1200).
            if let target = pool.acquire() {
                let frame = StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .landscape, canvasAspect: StudioLayout.landscapeAspect, breath: 0)
                _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: frame), into: target)
                report.check("render landscape paper at (720, 540)", matches(pixel(target, 720, 540), Tokens.paperBg), describe(pixel(target, 720, 540)))
                report.check("render landscape divider at (1439, 540)", matches(pixel(target, 1439, 540), Tokens.inkBlack), describe(pixel(target, 1439, 540)))
                report.check("render landscape presenter (1680, 540) = source (960, 540)", close(pixel(target, 1680, 540), pixel(presenter, 960, 540)))
                pool.release(target)
            }
            // Mirror canvas (SPEC 6.5): the 1200x1504 crop fits 810x1015 into the slot with about 32 px cream bars.
            if let target = pool.acquire(), let tablet = gradientBuffer(width: 1200, height: 1600) {
                let insets = Settings.defaults.mirrorCropInsetsPortrait
                let uv = insets.uv(sessionWidth: 1200, sessionHeight: 1600, nativeWidth: 1200, nativeHeight: 1600)
                let aspect = insets.croppedAspect(nativeWidth: 1200, nativeHeight: 1600)
                let frame = StudioLayout.frame(progress: 1, layout: .studioSplit, orientation: .portrait, canvasAspect: aspect, breath: 0)
                _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .mirror(tablet, uv: uv), frame: frame), into: target)
                let centre = pixel(target, 640, 540)
                report.check("render mirror picture at (640, 540) is neither cream nor paper", !matches(centre, Tokens.surfaceCream) && !matches(centre, Tokens.paperBg), describe(centre))
                report.check("render mirror cream bar at (640, 8)", matches(pixel(target, 640, 8), Tokens.surfaceCream), describe(pixel(target, 640, 8)))
                report.check("render mirror cream bar at (640, 1072)", matches(pixel(target, 640, 1072), Tokens.surfaceCream), describe(pixel(target, 640, 1072)))
                pool.release(target)
            }
            report.check("render: pool never exceeded 3 in flight", pool.inFlight == 0, "inFlight=\(pool.inFlight)")
        } catch {
            report.check("render: compositor setup", false, "\(error)")
        }
    }

    private static func probe(_ target: CVPixelBuffer, presenter: CVPixelBuffer, progress s: Double, report: Report) {
        let cream = Tokens.surfaceCream, paper = Tokens.paperBg, ink = Tokens.inkBlack
        if s >= 1 {
            report.check("render s=1 cream margin at (100, 540)", matches(pixel(target, 100, 540), cream), describe(pixel(target, 100, 540)))
            report.check("render s=1 paper at (640, 540)", matches(pixel(target, 640, 540), paper), describe(pixel(target, 640, 540)))
            report.check("render s=1 divider at (1279, 540)", matches(pixel(target, 1279, 540), ink), describe(pixel(target, 1279, 540)))
            report.check("render s=1 divider at (1280, 540)", matches(pixel(target, 1280, 540), ink), describe(pixel(target, 1280, 540)))
            report.check("render s=1 presenter (1600, 540) = source (960, 540)", close(pixel(target, 1600, 540), pixel(presenter, 960, 540)))
            report.check("render s=1 presenter (1281, 10) = source (641, 10)", close(pixel(target, 1281, 10), pixel(presenter, 641, 10)))
        } else if s == 0 {
            for (x, y) in [(100, 100), (960, 540), (1800, 1000)] {
                report.check("render s=0 presenter (\(x), \(y)) equals input", close(pixel(target, x, y), pixel(presenter, x, y)))
            }
        } else {
            // d = 640: paper spans x in [0, 405), cream [405, 640), divider at 639..640, presenter from 640 with source x = dest + 320 - 640... see SPEC 6.2
            report.check("render s=0.5 paper at (200, 540)", matches(pixel(target, 200, 540), paper), describe(pixel(target, 200, 540)))
            report.check("render s=0.5 cream at (520, 540)", matches(pixel(target, 520, 540), cream), describe(pixel(target, 520, 540)))
            let divider = pixel(target, 639, 540)
            let mixed = (Double(divider.r) / 255 < 0.6)
            report.check("render s=0.5 divider darkens at (639, 540)", mixed, describe(divider))
            report.check("render s=0.5 presenter (1000, 540) = source (680, 540)", close(pixel(target, 1000, 540), pixel(presenter, 680, 540)))
        }
    }

    static func gradientBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created) == kCVReturnSuccess, let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let g = UInt8(y * 255 / max(1, height - 1))
                var offset = y * stride
                for x in 0..<width {
                    bytes[offset] = UInt8(x * 255 / max(1, width - 1))
                    bytes[offset + 1] = g
                    bytes[offset + 2] = 128
                    bytes[offset + 3] = 255
                    offset += 4
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    struct Pixel { var b: UInt8; var g: UInt8; var r: UInt8; var a: UInt8 }

    static func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> Pixel {
        CVPixelBufferLockBaseAddress(buffer, [.readOnly])
        defer { CVPixelBufferUnlockBaseAddress(buffer, [.readOnly]) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Pixel(b: 0, g: 0, r: 0, a: 0) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let p = base.assumingMemoryBound(to: UInt8.self) + y * stride + x * 4
        return Pixel(b: p[0], g: p[1], r: p[2], a: p[3])
    }

    static func matches(_ p: Pixel, _ c: RGBA, tolerance: Int = 2) -> Bool {
        let r = Int(c.r * 255 + 0.5), g = Int(c.g * 255 + 0.5), b = Int(c.b * 255 + 0.5)
        return abs(Int(p.r) - r) <= tolerance && abs(Int(p.g) - g) <= tolerance && abs(Int(p.b) - b) <= tolerance
    }

    static func close(_ a: Pixel, _ b: Pixel, tolerance: Int = 2) -> Bool {
        return abs(Int(a.r) - Int(b.r)) <= tolerance && abs(Int(a.g) - Int(b.g)) <= tolerance && abs(Int(a.b) - Int(b.b)) <= tolerance
    }

    static func describe(_ p: Pixel) -> String {
        return String(format: "rgb %02X%02X%02X a %02X", p.r, p.g, p.b, p.a)
    }

    // MARK: Socket round trip (PROTOCOL 12 test contract)

    static func socketRoundTrip(device: MTLDevice?, report: Report, perfLog: Bool) {
        let telemetry = Telemetry(perfLog: perfLog)
        let sink = PreviewOnlySink()
        let pipeline: FramePipeline
        do {
            pipeline = try FramePipeline(sink: sink, settings: Settings.defaults, telemetry: telemetry, device: device, capture: nil)
        } catch {
            report.check("socket: pipeline setup", false, "\(error)")
            return
        }
        let ioQueue = DispatchQueue(label: "com.twelve.daylight.selftest.io")
        let inkQueue = DispatchQueue(label: "com.twelve.daylight.selftest.ink")
        let netQueue = DispatchQueue(label: "com.twelve.daylight.selftest.net")
        let registryURL = FileManager.default.temporaryDirectory.appendingPathComponent("daylight-selftest-\(UUID().uuidString).json")
        let registry = ClientRegistry(fileURL: registryURL, ioQueue: ioQueue)
        let rasterizer = InkRasterizer(surfaces: pipeline.surfaces)
        let router = InkRouter(pipeline: pipeline, rasterizer: rasterizer, registry: registry, saver: nil, settings: Settings.defaults, queue: inkQueue)
        router.onLog = { report.note("router: \($0)") }
        pipeline.onStateForClients = { state in inkQueue.async { router.receiveState(state) } }
        let server = WebServer(config: WebServer.Config(preferredPort: 0, bonjourName: nil, loopbackOnly: true, scanPorts: false), info: { ["version": "self-test"] }, queue: netQueue)
        server.onLog = { report.note("server: \($0)") }
        server.onInkClientOpened = { c in inkQueue.async { router.clientOpened(c) } }
        server.onInkClientClosed = { c in inkQueue.async { router.clientClosed(c) } }
        server.onInkMessage = { c, bytes, ns in inkQueue.async { router.handle(bytes, from: c, hostTimeNs: ns) } }
        let ready = DispatchSemaphore(value: 0)
        var boundPort: UInt16 = 0
        server.onReady = { port in
            boundPort = port
            ready.signal()
        }
        server.start()
        guard ready.wait(timeout: .now() + 5) == .success, boundPort != 0 else {
            report.check("socket: listener ready on 127.0.0.1", false, "\(server.state)")
            return
        }
        report.check("socket: listener ready on 127.0.0.1", true, "port \(boundPort)")

        // /healthz and /api/info over plain HTTP.
        if let health = httpGet("http://127.0.0.1:\(boundPort)/healthz") {
            report.check("http: /healthz is ok", health == "ok", health)
        } else {
            report.check("http: /healthz is ok", false, "no answer")
        }
        if let info = httpGet("http://127.0.0.1:\(boundPort)/api/info") {
            report.check("http: /api/info says app daylight", info.contains("\"app\":\"daylight\""), info)
        } else {
            report.check("http: /api/info says app daylight", false, "no answer")
        }

        // WebSocket client.
        let client = Client(url: URL(string: "ws://127.0.0.1:\(boundPort)/ink")!)
        client.connect()
        client.send(Golden.handshake)
        guard let ack = client.wait(where: { $0.header.knownOpcode == .handshakeAck }, timeout: 5) else {
            report.check("socket: HANDSHAKE_ACK received", false, "timeout; \(client.errorText ?? "")")
            return
        }
        let expected = Array(Hex.decode(Golden.handshakeAckOk)![16...])
        report.check("socket: ACK 0 (loopback) bytes 16...31 equal golden", Array(ack.bytes[16...]) == expected, Hex.encode(Array(ack.bytes[16...])))
        if let first = client.wait(where: { $0.header.knownOpcode == .state }, timeout: 3), case let .state(s)? = first.message {
            report.check("socket: STATE after ACK has bit2 set", s.flagSet.contains(.clientAllowed), "flags 0x\(String(s.flags, radix: 16))")
        } else {
            report.check("socket: STATE after ACK", false, "timeout")
        }
        client.send(Golden.strokeStart)
        client.send(Golden.strokeChunk3)
        client.send(Golden.strokeCommit)
        let engaged = client.wait(where: { m in
            if case let .state(s)? = m.message { return s.governor == GovernorState.engaging.rawValue || s.governor == GovernorState.live.rawValue }
            return false
        }, timeout: 3)
        report.check("socket: STATE with governor 1 (ENGAGING) after the stroke", engaged != nil)
        inkQueue.sync {}
        // Midpoint of the second segment (100, 200.25) -> (1199.97, 1599): about (650, 900).
        let mid = CanvasSurfaces.pixel(pipeline.surfaces.ink, x: 650, y: 900)
        report.check("ink: alpha along the stroke at (650, 900)", mid.a > 0, "a=\(mid.a)")
        let first = CanvasSurfaces.pixel(pipeline.surfaces.ink, x: 55, y: 98)
        report.check("ink: alpha along the first segment at (55, 98)", first.a > 0, "a=\(first.a)")
        let away = CanvasSurfaces.pixel(pipeline.surfaces.ink, x: 1100, y: 200)
        report.check("ink: no alpha away from the stroke at (1100, 200)", away.a == 0, "a=\(away.a)")
        inkQueue.sync { report.check("store: one committed stroke", router.store.committedCount == 1 && router.store.undoDepth == 1) }
        client.send(Golden.undoCurrentPage)
        let undone = client.wait(where: { m in
            if case let .state(s)? = m.message { return s.undoDepth == 0 && s.redoDepth == 1 }
            return false
        }, timeout: 3)
        report.check("socket: STATE undo_depth 0 redo_depth 1 after UNDO", undone != nil)
        inkQueue.sync {}
        let afterUndo = CanvasSurfaces.pixel(pipeline.surfaces.ink, x: 650, y: 900)
        report.check("ink: alpha back to zero after undo", afterUndo.a == 0, "a=\(afterUndo.a)")
        // The first composed frame reaches the sink when its command buffer completes (about 70 ms cold on the
        // runner's paravirtual GPU), so this waits instead of sampling the counter at once.
        var pushed = sink.pushCount
        if device != nil {
            let deadline = Date().addingTimeInterval(2)
            while pushed == 0 && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
                pushed = sink.pushCount
            }
        }
        report.check("sink: frames pushed while engaged", device == nil || pushed > 0, "pushes=\(pushed)")
        report.note("pipeline: passthroughZeroCopy=\(pipeline.stats.passthroughZeroCopy) mode=\(pipeline.stats.mode)")

        // Ink-source switch (SPEC 8): the web client sees ink_source 1 with bit3 clear and its ink is dropped silently.
        switchSource(.native, pipeline: pipeline, router: router, inkQueue: inkQueue)
        let nativeState = client.wait(where: { m in
            if case let .state(s)? = m.message { return s.inkSource == InkSource.native.rawValue && !s.flagSet.contains(.clientIsActiveSource) && s.flagSet.contains(.clientAllowed) }
            return false
        }, timeout: 3)
        report.check("source: STATE ink_source 1 with bit3 clear after switching to Daylight Ink", nativeState != nil)
        client.send(Golden.strokeStart)
        client.send(Golden.strokeChunk3)
        client.send(Golden.strokeCommit)
        Thread.sleep(forTimeInterval: 0.2)
        inkQueue.sync { report.check("source: ink from the non-active source is dropped", router.store.committedCount == 0 && router.store.redoDepth == 1, "committed=\(router.store.committedCount) redo=\(router.store.redoDepth)") }
        switchSource(.web, pipeline: pipeline, router: router, inkQueue: inkQueue)
        let webState = client.wait(where: { m in
            if case let .state(s)? = m.message { return s.inkSource == InkSource.web.rawValue && s.flagSet.contains(.clientIsActiveSource) }
            return false
        }, timeout: 3)
        report.check("source: STATE ink_source 0 with bit3 set after switching back to web", webState != nil)
        let zeroPage = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        client.sendMessage(.redo(pageID: zeroPage, clientTimeUs: InkConnection.nowUs()))
        let redone = client.wait(where: { m in
            if case let .state(s)? = m.message { return s.undoDepth == 1 && s.redoDepth == 0 }
            return false
        }, timeout: 3)
        report.check("socket: STATE undo_depth 1 redo_depth 0 after REDO", redone != nil)
        inkQueue.sync {}
        let afterRedo = CanvasSurfaces.pixel(pipeline.surfaces.ink, x: 650, y: 900)
        report.check("ink: alpha back along the stroke after redo", afterRedo.a > 0, "a=\(afterRedo.a)")

        // Mirror mode: the pipeline composes the mirror picture into the slot while the board is up (SPEC 4, 6.5).
        if device != nil {
            let tablet = MirrorStandIn()
            let lastFrame = Locked<CVPixelBuffer?>(nil)
            pipeline.setMirrorSource(tablet)
            pipeline.onPreviewFrame = { buffer in lastFrame.withLock { $0 = buffer } }
            switchSource(.mirror, pipeline: pipeline, router: router, inkQueue: inkQueue)
            let mirrorState = client.wait(where: { m in
                if case let .state(s)? = m.message { return s.inkSource == InkSource.mirror.rawValue && !s.flagSet.contains(.clientIsActiveSource) }
                return false
            }, timeout: 3)
            report.check("source: STATE ink_source 2 with bit3 clear after switching to mirror", mirrorState != nil)
            var hit = false
            var seen = "no frame"
            for _ in 0..<60 {
                if let frame = lastFrame.withLock({ $0 }), CVPixelBufferGetWidth(frame) == 1920 {
                    let centre = pixel(frame, 640, 540)
                    seen = describe(centre)
                    if !matches(centre, Tokens.surfaceCream) && !matches(centre, Tokens.paperBg) { hit = true; break }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            report.check("mirror: composed frame shows the tablet picture at (640, 540)", hit, seen)
            report.note("pipeline: mode=\(pipeline.stats.mode) pushed=\(pipeline.stats.pushed) dropped=\(pipeline.stats.dropped)")
            switchSource(.web, pipeline: pipeline, router: router, inkQueue: inkQueue)
        } else {
            report.note("WARNING no Metal device; the mirror compose probe is skipped")
        }
        client.close()
        server.stop()
        netQueue.sync {}
        pipeline.shutdown()
        try? FileManager.default.removeItem(at: registryURL)
    }

    /// What `AppModel.applyInkSource` does in the app: the pipeline posts `sourceChanged`, the router re-picks the
    /// active client; both STATE paths carry the new byte.
    static func switchSource(_ source: InkSource, pipeline: FramePipeline, router: InkRouter, inkQueue: DispatchQueue) {
        pipeline.setInkSource(source)
        inkQueue.sync { router.setActiveSource(source) }
    }

    /// A static tablet picture with the default portrait crop (what `MirrorSource` publishes once a frame decoded).
    final class MirrorStandIn: MirrorFrameSource {
        let buffer: CVPixelBuffer?
        let uv: UVRect
        let aspect: Double
        let frameSeed: UInt64 = 1
        var onGovernorEvent: ((GovernorEvent) -> Void)?

        init() {
            buffer = SelfTest.gradientBuffer(width: 1200, height: 1600)
            let insets = Settings.defaults.mirrorCropInsetsPortrait
            uv = insets.uv(sessionWidth: 1200, sessionHeight: 1600, nativeWidth: 1200, nativeHeight: 1600)
            aspect = insets.croppedAspect(nativeWidth: 1200, nativeHeight: 1600)
        }

        func latest() -> (buffer: CVPixelBuffer, uv: UVRect, aspect: Double, orientation: StudioLayout.CanvasOrientation)? {
            guard let buffer = buffer else { return nil }
            return (buffer, uv, aspect, .portrait)
        }

        func start() {}
        func stop() {}
    }

    static func httpGet(_ urlText: String) -> String? {
        guard let url = URL(string: urlText) else { return nil }
        let done = DispatchSemaphore(value: 0)
        var body: String?
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }
        task.resume()
        _ = done.wait(timeout: .now() + 5)
        return body
    }

    /// A minimal `URLSessionWebSocketTask` client that records decoded server messages.
    final class Client: NSObject, URLSessionWebSocketDelegate {
        struct Received {
            let bytes: [UInt8]
            let header: Header
            let message: Message?
        }

        private let url: URL
        private var session: URLSession!
        private var task: URLSessionWebSocketTask?
        private let lock = NSLock()
        private var received: [Received] = []
        private let arrived = DispatchSemaphore(value: 0)
        private(set) var errorText: String?
        private(set) var openedProtocol: String?
        /// Server close code, from the delegate.
        var onClose: ((UInt16) -> Void)?

        init(url: URL) {
            self.url = url
            super.init()
            session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        }

        func connect() {
            let task = session.webSocketTask(with: url, protocols: [SolStream.subprotocol])
            self.task = task
            task.resume()
            receiveLoop()
        }

        func send(_ hex: String) {
            guard let bytes = Hex.decode(hex) else { return }
            task?.send(.data(Data(bytes))) { [weak self] error in
                if let error = error { self?.errorText = "\(error)" }
            }
        }

        /// An encoded SolStream message (for the messages without a golden vector).
        func sendMessage(_ message: Message) {
            let payload = Codec.encode(message, timestampUs: InkConnection.nowUs())
            task?.send(.data(Data(payload))) { [weak self] error in
                if let error = error { self?.errorText = "\(error)" }
            }
        }

        /// Raw bytes, for the oversize-frame probe.
        func sendRaw(_ data: Data, completion: @escaping (Error?) -> Void) {
            task?.send(.data(data), completionHandler: completion)
        }

        func close() {
            task?.cancel(with: .normalClosure, reason: nil)
        }

        private func receiveLoop() {
            task?.receive { [weak self] result in
                guard let self = self else { return }
                switch result {
                case let .success(message):
                    if case let .data(data) = message {
                        let bytes = [UInt8](data)
                        if let header = try? bytes.withUnsafeBytes({ try Codec.decodeHeader($0) }) {
                            let decoded = try? bytes.withUnsafeBytes { try Codec.decodeLenient($0) }
                            self.lock.lock()
                            self.received.append(Received(bytes: bytes, header: header, message: decoded?.1))
                            self.lock.unlock()
                            self.arrived.signal()
                        }
                    }
                    self.receiveLoop()
                case let .failure(error):
                    self.errorText = "\(error)"
                    self.arrived.signal()
                }
            }
        }

        /// Waits until a received message satisfies `predicate` (messages are consumed in order).
        func wait(where predicate: (Received) -> Bool, timeout: Double) -> Received? {
            let deadline = DispatchTime.now() + timeout
            while true {
                lock.lock()
                if let index = received.firstIndex(where: predicate) {
                    let hit = received[index]
                    received.removeSubrange(0...index)
                    lock.unlock()
                    return hit
                }
                lock.unlock()
                if arrived.wait(timeout: deadline) == .timedOut { return nil }
            }
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
            openedProtocol = proto
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            onClose?(UInt16(closeCode.rawValue))
        }
    }

    // MARK: Vendor and extension facts (LOOSE_ENDS B2)

    static func vendorFacts(report: Report) {
        guard let resources = Bundle.main.resourceURL else { report.note("vendor: no resource URL"); return }
        let vendor = resources.appendingPathComponent("Vendor")
        let adb = vendor.appendingPathComponent("adb")
        if FileManager.default.fileExists(atPath: adb.path) {
            let archs = runTool("/usr/bin/lipo", ["-archs", adb.path]) ?? "lipo failed"
            let size = (try? FileManager.default.attributesOfItem(atPath: adb.path)[.size] as? Int) ?? 0
            report.note("vendor: adb \(size) bytes, lipo -archs: \(archs.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            report.note("vendor: adb missing (make fetch-tools)")
        }
        let server = vendor.appendingPathComponent("scrcpy-server-v4.1")
        if let data = try? Data(contentsOf: server) {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            report.note("vendor: scrcpy-server-v4.1 \(data.count) bytes sha256 \(digest)")
        } else {
            report.note("vendor: scrcpy-server-v4.1 missing (make fetch-tools)")
        }
        let apk = resources.appendingPathComponent("DaylightInk.apk")
        if let size = try? FileManager.default.attributesOfItem(atPath: apk.path)[.size] as? Int {
            report.note("vendor: DaylightInk.apk \(size) bytes")
        } else {
            report.note("vendor: DaylightInk.apk absent (served as 404)")
        }
    }

    static func extensionFacts(report: Report) {
        let signed = Bundle.main.object(forInfoDictionaryKey: "DaylightBuildSigned") as? Bool ?? false
        report.note("bundle: DaylightBuildSigned=\(signed) path=\(Bundle.main.bundlePath)")
        let extensions = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: extensions.path) else {
            report.note("extension: none embedded")
            return
        }
        for name in names where name.hasSuffix(".systemextension") {
            let plist = extensions.appendingPathComponent(name).appendingPathComponent("Contents/Info.plist")
            if let data = try? Data(contentsOf: plist), let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
                let keys = ["CFBundleIdentifier", "DaylightCameraDeviceUUID", "DaylightCameraSourceUUID", "DaylightCameraSinkUUID"]
                let facts = keys.map { "\($0)=\(dict[$0] ?? "?")" }.joined(separator: " ")
                let service = (dict["CMIOExtension"] as? [String: Any])?["CMIOExtensionMachServiceName"] ?? "?"
                report.note("extension: \(name) \(facts) CMIOExtensionMachServiceName=\(service)")
            } else {
                report.note("extension: \(name) (Info.plist unreadable)")
            }
        }
    }

    static func runTool(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
