# Daylight Whiteboard Camera: architecture

Status: binding for v1. This is the winning architecture (the performance-first proposal) with the judges' grafts from the reliability-first and experience-first proposals applied and every mustFix repaired (section 17 lists each repair). `SPEC.md` holds behaviour; `docs/PROTOCOL.md` holds the bytes; `docs/LOOSE_ENDS.md` holds what is still open.

Every API, plist key, entitlement and CLI flag named here was verified by one of the five research notes against a source read in that session (OBS, ldenoue/cameraextension, OffcutsCam, XcodeGen docs, actions/runner-images, Apple documentation JSON, SDK headers, scrcpy 4.1 source, AOSP, OkHttp, Chromium, w3c drafts, MDN, Vite). Items marked UNVERIFIED carry a runtime check or a fallback. Writing rules: no em-dashes.

---

## 0. Architecture in one paragraph, and the five invariants

The Mac host is a GCD pipeline with one job: hand IOSurface-backed BGRA 1920x1080 frames to a CMIO camera extension through its sink stream. In Passthrough it re-wraps the webcam's own buffer (no pixels touched, no timer). When the governor leaves PASSTHROUGH a 30 Hz clock drives one Metal pass that composes the presenter crop, the 1200x1600 ink and highlighter IOSurfaces (CoreGraphics writes them incrementally), the cream margins and the divider. Ink arrives over one TCP listener on 7788 that serves the web whiteboard and upgrades `/ink` to WebSocket; the native app and its overlay pills speak the same protocol; mirror mode replaces the ink surfaces with a VideoToolbox-decoded scrcpy stream and takes engage events from `getevent`. The invariants: (1) zero compute in Passthrough; (2) zero copies end to end (IOSurface everywhere; the one fallback copy logs loudly); (3) sub-frame compositing (one pass, under 1 ms GPU); (4) incremental ink (segments drawn once, dirty-rect redraws); (5) nothing waits on anything (serial queues, lock-free slots, drop-oldest back-pressure, no `sync` across queues except a microsecond governor lock). Reliability principle grafted on top: a pure, Linux-tested core (DaylightKit) under thin framework shells; every risky Apple hop has a dumb stand-in (preview window, null composer, fake sink) and a named owner-facing failure sentence.

---

## 1. Directory layout

```
whiteboard-camera/                      root of the future standalone repo 12twelve12hi/whiteboard-camera
  README.md  SPEC.md  LICENSE  THIRD_PARTY_NOTICES.md  VERSION  Makefile
  .github/workflows/ci.yml              standalone workflow (thin; every step is make <target>)
  docs/
    ARCHITECTURE.md  PROTOCOL.md  SETUP.md  SIGNING.md  LOOSE_ENDS.md  COMPARE.md  TESTING-CHECKLIST.md  PERFORMANCE.md
  protocol/
    gen_golden.py                       Python 3 struct oracle, no dependencies
    golden/solstream-v1.json            canonical golden vectors (copied into the three test trees by make golden)
  scripts/
    fetch-thirdparty.sh                 pinned scrcpy-server + platform-tools adb, sha256 verified, lipo/ls/unzip -l logged
    embed-web.sh                        copies web/dist -> mac/Daylight/Resources/web
    embed-apk.sh                        copies the android artifact -> mac/Daylight/Resources/DaylightInk.apk
    mac-generate.sh                     writes build/BuildNumber.xcconfig, runs xcodegen generate
    mac-build-unsigned.sh               CODE_SIGNING_ALLOWED=NO build; ad-hoc fallback for the extension; zips Daylight.app
    mac-sign-import.sh                  keychain, p12, both profiles into both profile directories
    mac-archive-export.sh               xcodebuild archive + -exportArchive with ExportOptions.plist; pre-notarization checks
    mac-notarize.sh                     notarytool submit --wait, log, stapler; make-dmg
    make-dmg.sh                         hdiutil UDZO, codesign the dmg
    check-golden.sh                     regenerate to tmp, diff the four copies
    ci-env.sh                           prints tool versions, DEVELOPER_DIR decision, HAS_SIGNING/DO_NOTARIZE evaluation
  mac/
    project.yml                         XcodeGen spec (section 12)
    ExportOptions.plist.in              developer-id, manual, provisioningProfiles for both bundle ids
    DaylightKit/                        SwiftPM package, Foundation only, XCTest on Linux and macOS
      Package.swift
      Sources/DaylightKit/
        Protocol/   SolStream.swift  Messages.swift  Codec.swift  ByteReader.swift  ByteWriter.swift  Identity.swift
        Governor/   EngageGovernor.swift  GovernorEvent.swift  GovernorOutput.swift  Clock.swift
        Spring/     CriticalSpring.swift
        Layout/     StudioLayout.swift  Rects.swift  Tokens.swift
        Canvas/     StrokeStore.swift  Stroke.swift  Geometry.swift  DirtyRect.swift  CatmullRom.swift  PageDocument.swift
        HTTP/       HTTPRequest.swift  WebSocketFrame.swift  SHA1.swift  MIME.swift  WebRootPath.swift
        Mirror/     ScrcpyDemuxer.swift  AnnexB.swift  EvdevParser.swift  EvdevCapabilities.swift  StylusContactMachine.swift
                    SideButtonGestures.swift  AdbDevicesParser.swift  CropInsets.swift
        Settings/   Settings.swift  FailureText.swift
        Session/    SessionFiles.swift
        Util/       Locked.swift  RingBuffer.swift  RateLimiter.swift  FixedPoint.swift  Hex.swift
      Tests/DaylightKitTests/
        Resources/solstream-v1.json     copy of the golden file
        Protocol/ Governor/ Spring/ Layout/ Canvas/ HTTP/ Mirror/ Settings/ Session/   (one test file per source file, plus GoldenVectorTests, ScenarioTests)
    Daylight/                           the menu-bar app (host)
      Contracts/  VirtualCameraSink.swift  InkSourceContracts.swift  PipelineContracts.swift   (frozen protocols, integrator-owned)
      App/        DaylightApp.swift  AppDelegate.swift  AppModel.swift  MenuBar.swift  Hotkeys.swift  SelfTest.swift  Diagnostics.swift
      Onboarding/ OnboardingWindow.swift  OnboardingSteps.swift  AllowClientPanel.swift
      Settings/   SettingsView.swift  SettingsStore.swift  HotkeyRecorder.swift  MirrorCropView.swift
      Pipeline/   FramePipeline.swift  WebcamCapture.swift  LatestFrameSlot.swift  OutputPool.swift  Compositor.swift  Shaders.metal
                  CanvasSurfaces.swift  InkRasterizer.swift  FrameClock.swift  Telemetry.swift  PreviewWindow.swift
      Camera/     ExtensionInstaller.swift  CMIODeviceLocator.swift  CMIOSinkClient.swift  ViewerWatcher.swift  SinkFeeder.swift  PreviewOnlySink.swift
      Ink/        InkRouter.swift  ClientRegistry.swift  SessionSaver.swift  PNGExporter.swift
      Server/     WebServer.swift  InkConnection.swift  StaticFiles.swift  BonjourAdvertiser.swift  LocalAddresses.swift  ApiRoutes.swift
      Mirror/     AdbClient.swift  AdbServerPolicy.swift  DeviceTracker.swift  ScrcpySession.swift  H264Decoder.swift  MirrorSource.swift
                  StylusWatcher.swift  UsbOnboarding.swift  WifiMirror.swift
      Resources/  Assets.xcassets  placeholder.png  web/ (folder reference, built by CI)  DaylightInk.apk (from the android job)
                  thirdparty/adb  thirdparty/scrcpy-server-v4.1  thirdparty/NOTICE.txt  thirdparty/LICENSE-scrcpy
      Info.plist  Daylight.entitlements
    DaylightCameraExtension/            the .systemextension target (no DaylightKit dependency)
      main.swift  ProviderSource.swift  DeviceSource.swift  SourceStream.swift  SinkStream.swift  Placeholder.swift
      Info.plist  DaylightCameraExtension.entitlements
    DaylightTests/                      macOS-only XCTest bundle
      Pipeline/  InkRasterizerTests.swift  CompositorTests.swift  PipelineSmokeTests.swift  FailureTextTests.swift
      Camera/    SinkFeederTests.swift
      Server/    WebServerLoopbackTests.swift
      Mirror/    H264DecoderTests.swift  CropInsetsRuntimeTests.swift
  web/
    package.json  package-lock.json  vite.config.ts  tsconfig.json  index.html  playwright.config.ts
    public/manifest.webmanifest  public/icons/*
    src/  main.ts  protocol.ts  ink.ts  ws.ts  ring.ts  chip.ts  tools.ts  caps.ts  styles.css
    tests/ pen.ts  fake-mac.mjs  protocol.spec.ts  pen.spec.ts  app.spec.ts  state.spec.ts  reconnect.spec.ts  secure.spec.ts  golden/solstream-v1.json
  android/
    settings.gradle.kts  build.gradle.kts  gradle.properties  gradlew  gradlew.bat
    gradle/wrapper/gradle-wrapper.jar  gradle/wrapper/gradle-wrapper.properties
    keystore/debug.keystore
    app/build.gradle.kts  app/src/main/AndroidManifest.xml
    app/src/main/kotlin/com/twelve/daylight/ink/
      protocol/  SolStream.kt  Messages.kt
      ink/       WetInkSurface.kt  DryInkView.kt  StrokeSession.kt  InkCanvasLayout.kt
      net/       InkConnection.kt  NoDelaySocketFactory.kt  Discovery.kt  Candidates.kt
      overlay/   OverlayService.kt  PillsView.kt  BootReceiver.kt
      ui/        MainActivity.kt  Toolbar.kt  Chip.kt  OnboardingActivity.kt  SettingsActivity.kt  EdgeToEdge.kt
      prefs/     Prefs.kt
    app/src/main/res/  layout/  drawable/  values/themes.xml  values/colors.xml
    app/src/test/kotlin/com/twelve/daylight/ink/  SolStreamTest.kt  StrokeSessionTest.kt  CandidatesTest.kt  DiscoveryQueueTest.kt
    app/src/test/resources/solstream-v1.json
```

Monorepo addition outside this folder: `/.github/workflows/whiteboard-camera.yml` only (`on.push.branches: [claude/daylight-whiteboard-camera-tzxfjb]`, `paths: [whiteboard-camera/**, .github/workflows/whiteboard-camera.yml]`, `defaults.run.working-directory: whiteboard-camera`). Twelve's files are untouched.

Independence rules: `web/` is a standalone npm project (not added to Twelve's root workspaces; code from `packages/daylight/src/ink.ts` and `ws.ts` is copied and adapted, never imported); `android/` is a standalone Gradle project; `DaylightKit` imports only Foundation (and Dispatch); the extension target imports CoreMediaIO, CoreMedia, CoreVideo, CoreGraphics, IOKit.audio and nothing of ours.

---

## 2. Modules and public interfaces

### 2.1 DaylightKit (Swift language mode 5, `swift-tools-version:5.9`, one library target, one test target with `resources: [.copy("Resources/solstream-v1.json")]`)

```swift
// Protocol
public enum SolStream {
    public static let magic: UInt8 = 0xDA, version: UInt8 = 0x01, headerLength = 16, pointLength = 11
    public static let maxPayload = 1 << 20, maxPointsPerChunk = 4096, maxErasedPerMessage = 1024, maxNameLength = 200
    public enum Opcode: UInt16 { case handshake = 0x0001, handshakeAck = 0x0002, strokeStart = 0x0010, strokeChunk = 0x0011, strokeCommit = 0x0012, strokeCancel = 0x0013, undo = 0x0014, redo = 0x0015, eraseStrokes = 0x0020, laserPoint = 0x0030, clearCanvas = 0x0040, pageChange = 0x0050, autoEngageReturn = 0x0060, togglePin = 0x0061, state = 0x0070, ping = 0x00FE, pong = 0x00FF }
    public enum PointerType: UInt8 { case stylus = 0, finger = 1, palm = 2, mouse = 3, unknown = 4 }
    public enum Phase: UInt8 { case hover = 0, contact = 1, cancel = 2, unknown = 3 }
    public enum Tool: UInt8 { case pen = 0, highlighter = 1, eraser = 2, lasso = 3 }
    public enum AckStatus: UInt32 { case ok = 0, pendingApproval = 1, denied = 2, unsupported = 3 }
    public enum Role: String { case web, ink, overlay, test }
    public struct Point: Equatable { public var x32: Int32, y32: Int32, pressure: UInt8, deltaMs: UInt16 }   // deltaMs since the FIRST point of the stroke
}
public struct Header: Equatable { public var opcode: UInt16; public var payloadLength: UInt32; public var timestampUs: UInt64; public var knownOpcode: SolStream.Opcode? { get } }
public struct StrokeStart: Equatable { public var id: UUID, tool: SolStream.Tool, colorARGB: UInt32, baseWidth: Float, pointer: SolStream.PointerType, phase: SolStream.Phase, pressure: Float }
public struct StateReport: Equatable {   // 20 bytes, PROTOCOL 6.14
    public var governor: UInt8, flags: UInt8, mode: UInt8, inkSource: UInt8, progress: Float, msToReturn: UInt32, pageIndex: UInt16, strokeCount: UInt16, undoDepth: UInt16, redoDepth: UInt16
    public struct Flags: OptionSet { public let rawValue: UInt8; public static let pinned = Flags(rawValue: 1), preWarning = Flags(rawValue: 2), clientAllowed = Flags(rawValue: 4), clientIsActiveSource = Flags(rawValue: 8), cameraAttached = Flags(rawValue: 16), sinkConnected = Flags(rawValue: 32), saving = Flags(rawValue: 64), captureIdle = Flags(rawValue: 128) }
}
public enum Message: Equatable {
    case handshake(canvasWidth: Float, canvasHeight: Float, dpi: Float, name: String)
    case handshakeAck(width: UInt32, height: UInt32, fps: UInt32, status: SolStream.AckStatus)
    case strokeStart(StrokeStart), strokeChunk(id: UUID, points: [SolStream.Point]), strokeCommit(id: UUID, pointCount: UInt32), strokeCancel(id: UUID)
    case undo(pageID: UUID, clientTimeUs: UInt64), redo(pageID: UUID, clientTimeUs: UInt64)
    case eraseStrokes(x1: Float, y1: Float, x2: Float, y2: Float, radius: Float, ids: [UUID])
    case laserPoint(x: Float, y: Float, intensity: Float, decayS: Float)
    case clearCanvas(pageID: UUID?, clientTimeUs: UInt64?), pageChange(pageID: UUID, width: Float, height: Float, index: UInt32)
    case autoEngageReturn(clientTimeUs: UInt64), togglePin(value: Int8, clientTimeUs: UInt64)
    case state(StateReport), ping(sequence: UInt64, clientTimeUs: UInt64), pong(sequence: UInt64, clientTimeUs: UInt64)
    public var opcode: SolStream.Opcode { get }
}
public enum CodecError: Error, Equatable { case badMagic(UInt8), badVersion(UInt8), truncated(needed: Int, have: Int), lengthMismatch(declared: Int, actual: Int), unknownOpcode(UInt16), badPayload(opcode: UInt16, reason: String), limitExceeded(opcode: UInt16, value: Int, max: Int) }
public enum Codec {
    public static func encode(_ m: Message, timestampUs: UInt64, into out: inout [UInt8])
    public static func encode(_ m: Message, timestampUs: UInt64) -> [UInt8]
    public static func decodeHeader(_ bytes: UnsafeRawBufferPointer) throws -> Header
    public static func decode(_ bytes: UnsafeRawBufferPointer) throws -> (Header, Message)        // throws unknownOpcode
    public static func decode(_ bytes: [UInt8]) throws -> (Header, Message)
    public static func decodeLenient(_ bytes: UnsafeRawBufferPointer) throws -> (Header, Message?)  // nil for an unknown opcode; still throws for malformed known ones
}
public struct ByteReader { public init(_ p: UnsafeRawBufferPointer); public mutating func u8() throws -> UInt8; public mutating func u16() throws -> UInt16; public mutating func i8() throws -> Int8; public mutating func i32() throws -> Int32; public mutating func u32() throws -> UInt32; public mutating func u64() throws -> UInt64; public mutating func f32() throws -> Float; public mutating func uuid() throws -> UUID; public mutating func bytes(_ n: Int) throws -> UnsafeRawBufferPointer; public var remaining: Int { get } }
public struct ByteWriter { public init(reserving: Int = 64); public mutating func u8(_: UInt8); public mutating func u16(_: UInt16); public mutating func i8(_: Int8); public mutating func i32(_: Int32); public mutating func u32(_: UInt32); public mutating func u64(_: UInt64); public mutating func f32(_: Float); public mutating func uuid(_: UUID); public mutating func bytes(_: [UInt8]); public var storage: [UInt8] { get } }
public struct Identity: Equatable { public var role: SolStream.Role, clientID: String, label: String; public init?(name: String); public var name: String { get } }   // "role;clientId;label"

// Governor (semantics: SPEC section 5)
public enum GovernorState: UInt8 { case passthrough = 0, engaging = 1, live = 2, returning = 3 }
public enum HoldMode: UInt8 { case auto = 0, split = 1, whiteboard = 2, camera = 3 }
public enum LayoutStyle: UInt8 { case studioSplit = 0, whiteboardOnly = 1 }
public enum InkSource: UInt8 { case web = 0, native = 1, mirror = 2 }
public enum GovernorEvent: Equatable {
    case contact(strokeID: UUID, pointer: SolStream.PointerType, phase: SolStream.Phase, pressure: Float, tool: SolStream.Tool)
    case motion(strokeID: UUID), lift(strokeID: UUID), cancel(strokeID: UUID), activity
    case penContact(down: Bool), eraserContact(down: Bool)          // mirror mode
    case pin(Int8), clear, returnNow, engage, layoutHotkey(LayoutStyle), hold(HoldMode)
    case sourceChanged(InkSource), clientGone(strokeIDs: Set<UUID>), allClientsGone
}
public struct GovernorConfig: Equatable { public var idleTimeout: Double = 90, preWarningLead: Double = 5, snapBackWindow: Double = 0.080, snapBackMaxProgress: Double = 0.15, springK: Double = 1200, engageOnEraser: Bool = false, autoEngage: Bool = true; public init() }
public enum GovernorEffect: Equatable { case stateChanged(from: GovernorState, to: GovernorState), savePage(reason: SaveReason), clearCanvas, preWarningStarted, preWarningCancelled, pinChanged(Bool), holdChanged(HoldMode) }
public enum SaveReason: String, Codable { case returned, cleared, pageChange, autosave, modeChanged, quit }
public struct GovernorOutput: Equatable { public var state: GovernorState, progress: Double, pinned: Bool, hold: HoldMode, layout: LayoutStyle, preWarning: Bool, breath: Double /* 0...1 */, msToReturn: UInt32 /* 0xFFFFFFFF none */, activeContacts: Int, effects: [GovernorEffect] }
public struct EngageGovernor {
    public init(config: GovernorConfig = .init(), now: Double)
    public mutating func handle(_ event: GovernorEvent, now: Double) -> GovernorOutput
    public mutating func tick(now: Double) -> GovernorOutput
    public var snapshot: GovernorOutput { get }
    public var generation: UInt64 { get }
    public var needsTicks: Bool { get }                      // state != passthrough || hold != auto
    public func nextDeadline(now: Double) -> Double?         // only consulted when Settings.deadlineIdle is on
}

// Spring
public struct CriticalSpring: Equatable {
    public let omega: Double
    public private(set) var position: Double, velocity: Double, target: Double
    public init(k: Double = 1200, m: Double = 1, position: Double = 0)
    public mutating func retarget(_ newTarget: Double, at now: Double)    // keeps position and velocity as initial conditions
    public mutating func snap(to value: Double, at now: Double)
    @discardableResult public mutating func evaluate(at now: Double) -> Double
    public var isSettled: Bool { get }                                    // |x - T| < 0.01 && |v| < 0.05
}
public func eulerReferenceStep(x: inout Double, v: inout Double, target: Double, dt: Double, k: Double, m: Double)   // tests only

// Layout (numbers: SPEC section 6)
public struct PixelRect: Equatable { public var x, y, w, h: Double }
public struct UVRect: Equatable { public var u0, v0, u1, v1: Double }
public struct RGBA: Equatable { public var r, g, b, a: Double }
public struct QuadSpec: Equatable { public var dest: PixelRect; public var uv: UVRect }
public enum Tokens { public static let inkBlack, paperBg, surfaceCream, borderSubtle, amber, amberDeep, terracotta, textMuted: RGBA }
public enum StudioLayout {
    public struct Frame: Equatable { public var presenter: QuadSpec?; public var canvas: QuadSpec?; public var canvasClip: PixelRect?; public var borders: [PixelRect]; public var divider: PixelRect?; public var dividerColor: RGBA; public var dividerAlpha: Double }
    public enum CanvasOrientation { case portrait, landscape }
    public static func frame(progress s: Double, layout: LayoutStyle, orientation: CanvasOrientation, canvasAspect: Double, breath: Double) -> Frame
    public static func passthrough() -> Frame
    public static func fit(aspect: Double, into r: PixelRect) -> PixelRect
    public static func clip(_ r: PixelRect) -> (l: Double, t: Double, r: Double, b: Double)
    public static func amberBreath(weight: Double) -> RGBA
}

// Canvas
public struct StrokeStyle: Equatable { public var tool: SolStream.Tool, colorARGB: UInt32, baseWidth: Float }
public struct Stroke { public let id: UUID; public var style: StrokeStyle; public private(set) var points: ContiguousArray<SolStream.Point>; public private(set) var bounds: PixelRect; public var isCommitted: Bool; public mutating func append(_ pts: [SolStream.Point]) }
public struct DirtyRect: Equatable { public var rect: PixelRect?; public mutating func union(_ r: PixelRect) }
public enum CanvasOp: Equatable { case drawSegments(strokeID: UUID, fromIndex: Int), redraw(DirtyRect), clearAll }
public struct StrokeStore {
    public init(canvasWidth: Int = 1200, canvasHeight: Int = 1600)
    public var strokes: [Stroke] { get }; public var activeStrokeIDs: Set<UUID> { get }; public var undoDepth: Int { get }; public var redoDepth: Int { get }
    public var pageID: UUID { get }; public var pageIndex: Int { get }; public var lastInkAt: Double? { get }; public var savedAt: Double? { get }; public var isDirty: Bool { get }
    public mutating func start(_ s: StrokeStart, scale: (Double, Double)) -> CanvasOp?
    public mutating func append(id: UUID, points: [SolStream.Point], now: Double) -> CanvasOp?
    public mutating func commit(id: UUID, pointCount: UInt32) -> CanvasOp?
    public mutating func commitAll(ids: Set<UUID>) -> [CanvasOp]
    public mutating func cancel(id: UUID) -> CanvasOp?
    public mutating func erase(x1: Float, y1: Float, x2: Float, y2: Float, radius: Float, hint: [UUID]) -> CanvasOp?
    public mutating func undo() -> CanvasOp?; public mutating func redo() -> CanvasOp?
    public mutating func clear() -> CanvasOp; public mutating func newPage(id: UUID, index: Int, width: Double, height: Double) -> CanvasOp
    public mutating func markSaved(at now: Double)
    public func document(sessionStart: Date, savedAt: Date, reason: SaveReason, inkSource: InkSource, clientLabel: String) -> PageDocument
    public static func width(base: Double, pressure: Double) -> Double        // base * (0.55 + 0.9 * pressure)
}
public struct PageDocument: Codable, Equatable { /* SPEC section 12 schema */ }
public enum Geometry { public static func distanceSquared(point: (Double, Double), segment a: (Double, Double), b: (Double, Double)) -> Double; public static func strokeHit(_ s: Stroke, segment a: (Double, Double), b: (Double, Double), radius: Double) -> Bool }
public enum CatmullRom { public static func bezierControls(p0: (Double, Double), p1: (Double, Double), p2: (Double, Double), p3: (Double, Double)) -> (c1: (Double, Double), c2: (Double, Double)) }

// HTTP and WebSocket
public struct HTTPRequest: Equatable {
    public var method: String, path: String, query: [String: String], headers: [String: String]   // lower-cased keys
    public static func parse(_ buffer: UnsafeRawBufferPointer) throws -> (request: HTTPRequest, consumed: Int)?   // nil until \r\n\r\n
    public var isWebSocketUpgrade: Bool { get }; public var webSocketProtocols: [String] { get }
    public static func statusText(_ code: Int) -> String
    public static func response(status: Int, headers: [(String, String)], body: [UInt8]) -> [UInt8]
    public static func webSocketAccept(forKey key: String) -> String                          // base64(SHA1(key + GUID))
    public static func upgradeResponse(accept: String, subprotocol: String?) -> [UInt8]
}
public struct WebSocketFrame: Equatable {
    public var fin: Bool, opcode: UInt8, payload: [UInt8]
    public static func parse(_ buffer: inout [UInt8], maxPayload: Int) throws -> (frame: WebSocketFrame, consumed: Int)?   // unmasks in place
    public static func encode(opcode: UInt8, payload: UnsafeRawBufferPointer, into out: inout [UInt8])             // server frames unmasked
    public static func encodeClose(code: UInt16, reason: String) -> [UInt8]
}
public enum WebSocketError: Error, Equatable { case reservedBits, unmaskedClientFrame, oversize(Int), controlFrameTooLong, fragmentedControl }
public enum SHA1 { public static func hash(_ bytes: UnsafeRawBufferPointer) -> [UInt8] }   // pure Swift; macOS test cross-checks CryptoKit Insecure.SHA1
public enum MIME { public static func type(forExtension ext: String) -> String? }
public enum WebRootPath { public static func resolve(_ requestPath: String) -> String? }     // percent-decoded, normalised, nil on traversal

// Mirror parsing (owned by component F; Foundation only)
public enum ScrcpyPacket: Equatable { case deviceMeta(name: String), codec(id: UInt32), session(width: UInt32, height: UInt32), config(annexB: [UInt8]), frame(ptsUs: UInt64, keyFrame: Bool, annexB: [UInt8]) }
public struct ScrcpyDemuxer { public init(); public mutating func feed(_ bytes: UnsafeRawBufferPointer, emit: (ScrcpyPacket) -> Void) throws; public var expectsDummyByte: Bool { get } }
public enum ScrcpyError: Error, Equatable { case codecDisabled, codecConfigError, unknownCodec(UInt32), badPacketSize(UInt32) }
public enum AnnexB { public static func nalUnits(_ annexB: UnsafeRawBufferPointer) -> [Range<Int>]; public static func parameterSets(_ config: UnsafeRawBufferPointer) -> (sps: [[UInt8]], pps: [[UInt8]]); public static func toAVCC(_ annexB: UnsafeRawBufferPointer) -> [UInt8]; public static func containsIDR(_ annexB: UnsafeRawBufferPointer) -> Bool }
public struct EvdevEvent: Equatable { public var tsUs: UInt64, type: String, code: String, value: String }
public struct EvdevParser { public init(); public mutating func feed(_ bytes: UnsafeRawBufferPointer, emit: (EvdevEvent) -> Void) }   // tolerant of the "/dev/input/eventX: " prefix and partial lines
public struct EvdevCapabilities: Equatable { public var path: String, name: String, keys: Set<String>, abs: [String: (min: Int, max: Int)], props: Set<String> }
public enum EvdevCapabilitiesParser { public static func parse(_ text: String) -> [EvdevCapabilities]; public static func penNode(_ caps: [EvdevCapabilities]) -> EvdevCapabilities? }   // BTN_TOOL_PEN + ABS_PRESSURE, no ABS_MT_SLOT
public struct StylusSample: Equatable { public var inRange, eraserInRange, touching, side1, side2: Bool; public var pressure: Double; public var x, y: Int; public var tsUs: UInt64 }
public enum StylusTransition: Equatable { case contactDown(StylusSample), contactUp(StylusSample), eraserDown(StylusSample), eraserUp(StylusSample), side1Down(tsUs: UInt64), side1Up(tsUs: UInt64), side2Down(tsUs: UInt64), side2Up(tsUs: UInt64) }
public struct StylusContactMachine { public init(pressureMax: Int); public mutating func apply(_ e: EvdevEvent) -> [StylusTransition] }   // non-empty only on SYN_REPORT
public enum SideButtonGesture: Equatable { case doublePress, longPress }
public struct SideButtonGestures { public init(doublePressWindowMs: Int = 400, longPressMs: Int = 700); public mutating func down(tsUs: UInt64) -> SideButtonGesture?; public mutating func up(tsUs: UInt64) -> SideButtonGesture?; public mutating func timerFired(tsUs: UInt64) -> SideButtonGesture?; public func pendingDeadline() -> UInt64? }
public struct AdbDevice: Equatable { public var serial: String, state: String, model: String?, product: String?, transportID: Int?; public var isUSB: Bool }
public enum AdbDevicesParser { public static func parse(_ output: String) -> [AdbDevice]; public static func parseHostVersion(_ output: String) -> Int? }
public struct CropInsets: Equatable, Codable { public var top, left, right, bottom: Int; public func uv(sessionWidth: Int, sessionHeight: Int, nativeWidth: Int, nativeHeight: Int) -> UVRect; public func croppedAspect(nativeWidth: Int, nativeHeight: Int) -> Double }

// Settings, session, util
public struct Settings: Codable, Equatable { public static let defaults: Settings; public static let userDefaultsKey = "com.twelve.daylight.settings.v1"; public func validated() -> Settings }   // keys: SPEC section 11
public enum FailureText { public enum Case: CaseIterable { /* one case per SPEC 13.3 row */ }; public static func sentence(_ c: Case, _ args: [String]) -> String; public static func logLine(_ c: Case, _ args: [String]) -> String }
public enum SessionFiles { public static func sessionDirectory(root: URL, sessionStart: Date, calendar: Calendar) -> URL; public static func pageBaseName(index: Int) -> String; public static func mirrorName(sessionStart: Date) -> String; public static func uniqueURL(_ url: URL, exists: (URL) -> Bool) -> URL }
public final class Locked<Value> { public init(_ value: Value); public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R }   // NSLock
public protocol Clock { func now() -> Double }; public struct SystemClock: Clock; public final class ManualClock: Clock { public func advance(_ dt: Double) }
public struct RingBuffer<T> { public init(capacity: Int); public mutating func push(_: T); public mutating func drain() -> [T]; public var count: Int { get } }
public struct RateLimiter { public init(minInterval: Double); public mutating func allow(now: Double) -> Bool }
public enum FixedPoint { public static func toX32(_ v: Double) -> Int32; public static func fromX32(_ v: Int32) -> Double }
public enum Hex { public static func encode(_: [UInt8]) -> String; public static func decode(_: String) -> [UInt8]? }
```

### 2.2 Frozen contracts (`mac/Daylight/Contracts/`, integrator-owned; components implement them in their own directories)

```swift
protocol VirtualCameraSink: AnyObject {                                   // implemented by CMIOSinkClient (C) and PreviewOnlySink (C); FakeSink in tests (B)
    var status: SinkStatus { get }                                        // .notInstalled, .awaitingApproval, .installed, .connected, .error(FailureText.Case, String)
    var onStatusChange: ((SinkStatus) -> Void)? { get set }
    var onQueueAltered: (() -> Void)? { get set }
    var viewerCount: Int { get }                                          // 0 when unknown or not connected
    var onViewerCount: ((Int) -> Void)? { get set }
    func start(); func stop()
    @discardableResult func push(_ sb: CMSampleBuffer) -> Bool             // never blocks; false when dropped
}
protocol MirrorFrameSource: AnyObject {                                   // implemented by MirrorSource (F); consumed by FramePipeline (B)
    func latest() -> (buffer: CVPixelBuffer, uv: UVRect, aspect: Double, orientation: StudioLayout.CanvasOrientation)?
    var frameSeed: UInt64 { get }
    var onGovernorEvent: ((GovernorEvent) -> Void)? { get set }           // penContact, eraserContact, pin, clear
    func start(); func stop()
}
protocol PipelineControl: AnyObject {                                      // implemented by FramePipeline (B); used by InkRouter, Hotkeys, MirrorSource, AppModel
    func post(_ e: GovernorEvent)
    var governorSnapshot: GovernorOutput { get }
    func setViewerCount(_ n: Int); func setPreviewVisible(_ v: Bool); func setSinkConnected(_ c: Bool)
    var onStateForClients: ((StateReport) -> Void)? { get set }
}
```

### 2.3 Daylight app (component B unless marked)

```swift
final class LatestFrameSlot { struct Entry { let buffer: CVPixelBuffer; let hostTimeNs: UInt64; let sequence: UInt64 }; func publish(_ b: CVPixelBuffer, hostTimeNs: UInt64); func take() -> Entry?; func clear() }   // OSAllocatedUnfairLock
final class OutputPool { init(width: Int, height: Int) throws; func acquire() -> CVPixelBuffer?; func release(_ pb: CVPixelBuffer); let formatDescription: CMVideoFormatDescription; var inFlight: Int { get }; func flush() }   // CVPixelBufferPool, min 3, allocation threshold 3, IOSurface + Metal compatible, DispatchSemaphore(3) with wait(timeout: .now())
final class SinkFeeder /* C */ { init(sink: VirtualCameraSink); @discardableResult func push(_ pb: CVPixelBuffer, hostTimeNs: UInt64?) -> Bool; var droppedFrames: UInt64 { get }, pushedFrames: UInt64 { get } }   // CMSampleBufferCreateReadyWithImageBuffer, host-clock PTS, cached format description per (w, h, fmt)
final class WebcamCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Event { case frame(CVPixelBuffer, hostTimeNs: UInt64), formatChanged(width: Int, height: Int, pixelFormat: OSType), lost, restored }
    init(queue: DispatchQueue); var onEvent: ((Event) -> Void)?
    func start(device: AVCaptureDevice) throws; func stop(); var isRunning: Bool { get }; var firstFrameFacts: (iosurface: Bool, width: Int, height: Int, fourcc: OSType)? { get }
    static func cameras() -> [AVCaptureDevice]   // DiscoverySession [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]; nil device = userPreferredCamera
}
final class CanvasSurfaces { init(device: MTLDevice, width: Int = 1200, height: Int = 1600) throws; let ink: IOSurfaceRef, highlight: IOSurfaceRef; let inkTexture: MTLTexture, highlightTexture: MTLTexture; var seed: UInt32 { get }; func resize(width: Int, height: Int) throws }
final class InkRasterizer { init(surfaces: CanvasSurfaces); func apply(_ op: CanvasOp, store: StrokeStore); func clearAll(); var stats: (locks: UInt64, segments: UInt64, redrawPixels: UInt64) { get } }   // one IOSurfaceLock per op; CGContext byteOrder32Little | premultipliedFirst; y-flip CTM
final class Compositor {
    init(device: MTLDevice) throws
    enum CanvasInput { case layers(CanvasSurfaces), mirror(CVPixelBuffer, uv: UVRect), none }
    struct Inputs { var presenter: CVPixelBuffer?; var canvas: CanvasInput; var frame: StudioLayout.Frame }
    func render(_ inputs: Inputs, into target: CVPixelBuffer, completion: @escaping (CFTimeInterval) -> Void)   // one pass, clear SurfaceCream, 4 quads, bgra8Unorm, IOSurface textures with the default storage mode
}
final class FrameClock { init(queue: DispatchQueue, fps: Int = 30); var onTick: ((Double) -> Void)?; func start(); func stop(); var isRunning: Bool { get } }   // DispatchSourceTimer strict, 1 ms leeway, CACurrentMediaTime
final class FramePipeline: PipelineControl {
    init(sink: VirtualCameraSink, settings: Settings, telemetry: Telemetry) throws
    func setCamera(_ device: AVCaptureDevice?); func setInkSource(_ s: InkSource); func setMirrorSource(_ m: MirrorFrameSource?)
    var onPreviewFrame: ((CVPixelBuffer) -> Void)?; var stats: PipelineStats { get }
}
struct PipelineStats { var mode: String; var fps: Double; var cpuMsPerFrame: Double; var gpuMsPerFrame: Double; var dropped: UInt64; var inFlight: Int; var passthroughZeroCopy: Bool; var capturing: Bool; var captureIdleReason: String?; var viewers: Int }
final class Telemetry { let signposter: OSSignposter; func begin(_ name: StaticString) -> OSSignpostIntervalState; func end(_ s: OSSignpostIntervalState, _ name: StaticString); var perfLog: Bool }
final class PreviewWindow { func show(); func hide(); var isVisible: Bool { get }; var onVisibility: ((Bool) -> Void)?; func display(_ pb: CVPixelBuffer) }   // AVSampleBufferDisplayLayer; consumes frames only while visible

// Camera (component C)
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate { enum Status { case unknown, notInstalled, needsApproval, activating, installed, needsReboot, failed(OSSystemExtensionError.Code, String), notInApplications, unsignedBuild }; var status: Status { get }; var onChange: ((Status) -> Void)?; func activate(); func openApprovalPane() }
final class CMIODeviceLocator { init(deviceUUID: UUID); func locate() -> (device: CMIODeviceID, streams: [CMIOStreamID], directions: [UInt32])? }   // OBS walk: kCMIOHardwarePropertyDevices, kCMIODevicePropertyDeviceUID == uuidString, kCMIODevicePropertyStreams, kCMIOStreamPropertyDirection logged
final class CMIOSinkClient: VirtualCameraSink { init(deviceUUID: UUID, sinkUUID: UUID, queue: DispatchQueue); var isConnected: Bool { get } }   // CMIOStreamCopyBufferQueue, CMIODeviceStartStream, CMSimpleQueueEnqueue when count < capacity; retries every 2 s; AVCaptureDevice.wasConnectedNotification triggers a retry
final class ViewerWatcher { init(locator: CMIODeviceLocator, queue: DispatchQueue); var onViewerCount: ((Int) -> Void)?; func start(); func stop() }   // CMIOObjectAddPropertyListenerBlock on the custom property plus a 1 Hz poll fallback
final class PreviewOnlySink: VirtualCameraSink { }                           // status .installed, push is a no-op; used on unsigned builds and in tests

// Ink (B)
final class ClientRegistry { struct Record: Codable, Equatable { var id: String; var label: String; var roles: Set<String>; var allowed: Bool; var seenOverUSB: Bool; var firstSeen: Date; var lastSeen: Date; var lastAddress: String }; func lookup(id: String) -> Record?; func recordLoopback(id: String, label: String, role: String); func allow(id: String); func deny(id: String); func forget(id: String); var all: [Record] { get }; var trustLoopback: Bool }   // ~/Library/Application Support/Daylight/clients.json
final class InkRouter { init(pipeline: PipelineControl, surfaces: CanvasSurfaces, registry: ClientRegistry, saver: SessionSaver, settings: Settings); func handle(_ bytes: UnsafeRawBufferPointer, from c: InkConnection, hostTimeNs: UInt64); func clientOpened(_ c: InkConnection); func clientClosed(_ c: InkConnection); func setActiveSource(_ s: InkSource); func broadcast(_ s: StateReport); var pendingAllow: ((InkConnection) -> Void)? }   // runs on ink.queue; owns StrokeStore + InkRasterizer; RateLimiter for STATE
final class SessionSaver { init(root: URL, queue: DispatchQueue); func save(_ doc: PageDocument, strokes: StrokeStore, reason: SaveReason, completion: ((Result<[URL], Error>) -> Void)?); func saveMirror(_ pb: CVPixelBuffer, uv: UVRect, sessionStart: Date); func startAutosave(every: TimeInterval, isDirty: @escaping () -> Bool, snapshot: @escaping () -> (PageDocument, StrokeStore)?); var onSaved: (([URL]) -> Void)?; var onError: ((Error) -> Void)? }
enum PNGExporter { static func render(_ store: StrokeStore, size: CGSize, paper: Bool) -> CGImage?; static func write(_ img: CGImage, to url: URL) throws }

// Server (B)
final class WebServer { static let defaultPort: UInt16 = 7788, serviceType = "_daylight-camera._tcp"; init(webRoot: URL, apkURL: URL?, preferredPort: UInt16, bonjourName: String, info: @escaping () -> [String: Any], queue: DispatchQueue) throws; func start(); func stop(); var port: UInt16 { get }; var state: NWListener.State { get }; var bonjourRegisteredName: String? { get }; var onInkMessage: ((InkConnection, UnsafeRawBufferPointer) -> Void)?; var onInkClientOpened: ((InkConnection) -> Void)?; var onInkClientClosed: ((InkConnection) -> Void)? }   // NWListener(using: .tcp) with noDelay, allowLocalEndpointReuse; tries 7788...7799; listener.service set before start
final class InkConnection { let id: UUID; let remote: NWEndpoint; var identity: Identity?; var allowed: Bool; var isLoopback: Bool { get }; var isActiveSource: Bool; func send(_ m: Message, timestampUs: UInt64); func close(code: UInt16, reason: String); var lastRxHostTimeNs: UInt64 { get } }
enum LocalAddresses { struct Entry { let ip: String; let interface: String; let kind: Kind }; enum Kind { case tailscale, wifiOrEthernet }; static func list() -> [Entry] }   // getifaddrs; utun + 100.64.0.0/10 first
enum ApiRoutes { static func healthz() -> (Int, String, Data); static func info(_ dict: [String: Any]) -> (Int, String, Data); static func apk(url: URL?) -> (Int, String, Data, [(String, String)]) }

// App (B)
@main struct DaylightApp: App { @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate; var body: some Scene { MenuBarExtra("Daylight", systemImage: "camera") { MenuBarView() }; Settings { SettingsView() }; Window("Welcome to Daylight", id: "onboarding") { OnboardingView() } } }
@MainActor final class AppModel: ObservableObject { /* mirrors PipelineStats at 2 Hz; publishes extension status, cameras, inkSource, hold, governor, clients, pendingAllow, addresses, adb devices, diagnostics; actions pin(), clear(), returnToCamera(), hold(_:), setInkSource(_:), allow(_:remember:), deny(_:), forget(_:), setupAgain() */ }
final class Hotkeys { init(settings: Settings); var onAction: ((HotkeyAction) -> Void)?; func rebind(_ a: HotkeyAction, keyCode: UInt32, modifiers: UInt32) throws }   // Carbon RegisterEventHotKey / UnregisterEventHotKey, InstallEventHandler(GetEventDispatcherTarget(), ...)
enum HotkeyAction: String, Codable, CaseIterable { case whiteboardOnly, studioSplit, keep, clear, camera }
final class AllowClientPanel: NSPanel { /* styleMask includes .nonactivatingPanel; top right; 60 s auto-dismiss; Allow / Not now */ }
enum SelfTest { static func run(arguments: [String]) -> Int32 }                 // `Daylight --self-test [--perf-log]`

// Mirror (component F)
final class AdbClient { init(executable: URL, serverSocket: String?, queue: DispatchQueue); func run(_ args: [String], timeout: Double, completion: @escaping (Result<(status: Int32, stdout: Data, stderr: Data), Error>) -> Void); func spawnStreaming(_ args: [String], onStdout: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) -> Process }   // Foundation Process + Pipe + readabilityHandler; ADB_SERVER_SOCKET in the child environment for private-port mode
final class AdbServerPolicy { enum Decision { case shared5037, privatePort(UInt16), conflict(theirVersion: Int, ours: Int, privatePort: UInt16) }; static func decide(bundled: AdbClient, mode: Settings.AdbServerMode, privatePort: UInt16, completion: @escaping (Decision) -> Void) }   // probes 127.0.0.1:5037 with 000Chost:version; never kill-server
final class DeviceTracker { init(adb: AdbClient); var onDevices: (([AdbDevice]) -> Void)?; func start(); func stop() }   // host:track-devices raw socket; fallback `devices -l` every 2 s
final class ScrcpySession { struct Config { var serial: String; var maxSize = 1600; var bitRate = 8_000_000; var maxFps = 30; var localPort: UInt16 = 27183 }; init(adb: AdbClient, server: URL, config: Config, queue: DispatchQueue); var onPacket: ((ScrcpyPacket) -> Void)?; var onServerLog: ((String) -> Void)?; var onExit: ((Error?) -> Void)?; func start(); func stop() }
final class H264Decoder { init(queue: DispatchQueue); func setParameterSets(sps: [[UInt8]], pps: [[UInt8]]) throws; func decode(annexB: UnsafeRawBufferPointer, ptsUs: UInt64, keyFrame: Bool) throws; var onFrame: ((CVPixelBuffer, UInt64) -> Void)?; var needsKeyFrame: Bool { get } }   // BGRA, IOSurface + Metal compatible; CMBlockBufferCreateWithMemoryBlock over a buffer allocated per access unit (never reused)
final class MirrorSource: MirrorFrameSource { init(session: ScrcpySession, decoder: H264Decoder, stylus: StylusWatcher?, settings: Settings); var sessionSize: (w: Int, h: Int) { get }; var insets: (portrait: CropInsets, landscape: CropInsets) }
final class StylusWatcher { init(adb: AdbClient, serial: String, queue: DispatchQueue, gestures: SideButtonGestures); var onTransition: ((StylusTransition) -> Void)?; var onGesture: ((SideButtonGesture) -> Void)?; var onStatus: ((Status) -> Void)?; enum Status { case probing, watching(path: String, name: String, pressureMax: Int), noPenDevice([String]), error(String) }; func start(); func stop() }
enum UsbOnboarding { static func openWeb(adb: AdbClient, serial: String, port: UInt16, completion: @escaping (Result<Void, Error>) -> Void); static func installInk(adb: AdbClient, serial: String, apk: URL, host: String, pills: Bool, completion: @escaping (Result<Void, Error>) -> Void) }
final class WifiMirror { init(adb: AdbClient); func rememberAfterUSBSession(serial: String); func tryConnect(completion: @escaping (Bool) -> Void) }   // ip route, tcpip 5555, connect <ip>:5555, stdout contains "connected"
```

### 2.4 Camera extension (component C, `DaylightCameraExtension` target)

Exactly the verified OBS/ldenoue shape: `ProviderSource` (provider, `startService`), `DeviceSource` (one device "Daylight Camera", source stream then sink stream, `kIOAudioDeviceTransportTypeVirtual`, BGRA 1920x1080, `CMTime(1, 30)`, `.hostTime`), `SourceStream`, `SinkStream` (`sinkBufferQueueSize 1`, `sinkBuffersRequiredForStartup 1`), `Placeholder` (cream card drawn via `CGContext` with `byteOrder32Little | noneSkipFirst`). Daylight additions:

1. `DeviceSource.consumeStrategy` is a compile-time constant with cases `.timer90Hz` (default: `DispatchSource.makeTimerSource` at 3x frame rate calling `consumeSampleBuffer(from:)` only while `sinkStarted`) and `.recursive` (ldenoue's unconditional loop). A debug build prints the consume rate once per second to the unified log.
2. Custom source-stream property `CMIOExtensionProperty(rawValue: "4cc_dlvw_glob_0000")` returning `streamingCounter` as `UInt32` (ldenoue pattern); the host's `ViewerWatcher` reads it with `CMIOObjectGetPropertyData` on the source stream. UNVERIFIED whether `CMIOObjectAddPropertyListenerBlock` fires for custom properties; the 1 Hz poll is the fallback and is always on.
3. `authorizedToStartStream(for:)` on the sink returns `client.signingID == "com.twelve.daylight"` when `signingID` is non-nil, else `true`.
4. The extension forwards the consumed `CMSampleBuffer` unchanged with `send(_:discontinuity:hostTimeInNanoseconds:)` only when `streamingCounter > 0`, and always calls `notifyScheduledOutputChanged`.
5. `CFBundleVersion` is the CI run number so `request(_:actionForReplacingExtension:withExtension:)` can return `.replace` on every update.

Info.plist: `CMIOExtension` dict with `CMIOExtensionMachServiceName = $(TeamIdentifierPrefix)com.twelve.daylight`; `NSSystemExtensionUsageDescription`; the three UUID keys. Entitlements: `com.apple.security.app-sandbox` true, `com.apple.security.application-groups = [$(TeamIdentifierPrefix)com.twelve.daylight]`, nothing else.

### 2.5 Web (component D)

```ts
// protocol.ts
export const Opcode = { HANDSHAKE: 0x0001, HANDSHAKE_ACK: 0x0002, STROKE_START: 0x0010, STROKE_CHUNK: 0x0011, STROKE_COMMIT: 0x0012, STROKE_CANCEL: 0x0013, UNDO: 0x0014, REDO: 0x0015, ERASE_STROKES: 0x0020, LASER_POINT: 0x0030, CLEAR_CANVAS: 0x0040, PAGE_CHANGE: 0x0050, AUTO_ENGAGE_RETURN: 0x0060, TOGGLE_PIN: 0x0061, STATE: 0x0070, PING: 0x00fe, PONG: 0x00ff } as const;
export interface WirePoint { x: number; y: number; pressure: number; deltaMs: number }   // deltaMs since the first point
export interface StateReport { governor: 0|1|2|3; pinned: boolean; preWarning: boolean; allowed: boolean; activeSource: boolean; cameraAttached: boolean; sinkConnected: boolean; saving: boolean; captureIdle: boolean; mode: 0|1|2|3; inkSource: 0|1|2; progress: number; msToReturn: number | null; pageIndex: number; strokeCount: number; undoDepth: number; redoDepth: number }
export class Encoder { constructor(nowUs: () => bigint); handshake(w, h, dpi, name): ArrayBuffer; strokeStart(id: Uint8Array, tool: 0|1|2, colorARGB: number, baseWidth: number, pressure: number): ArrayBuffer; strokeChunk(id, pts: readonly WirePoint[]): ArrayBuffer; strokeCommit(id, count): ArrayBuffer; strokeCancel(id): ArrayBuffer; undo(pageId): ArrayBuffer; redo(pageId): ArrayBuffer; erase(x1, y1, x2, y2, radius, ids: Uint8Array[]): ArrayBuffer; clear(pageId): ArrayBuffer; pageChange(pageId, w, h, index): ArrayBuffer; returnNow(): ArrayBuffer; togglePin(v: -1|0|1): ArrayBuffer; ping(seq: bigint): ArrayBuffer }
export function decodeServer(buf: ArrayBuffer): { opcode: number; ack?: { w: number; h: number; fps: number; status: 0|1|2|3 }; state?: StateReport; pong?: { seq: bigint; t: bigint } } | null;
export function newUuid16(): Uint8Array;
// ink.ts: InkCanvas(el, events, { canvasW: 1200, canvasH: 1600 }); pen only; buttons !== 0 && pressure > 0; touch-action none in CSS; getCoalescedEvents and pointerrawupdate feature-detected; desynchronized 2D context; per-rAF batching; pointercancel/pointerleave -> commit (>= 2 points and > 80 ms) else cancel; local undo/redo driven by STATE depths
// ws.ts: InkClient(url, enc, { ring, onState, onAck, onConnection }); requests subprotocol "solstream.v1"; binaryType arraybuffer; Twelve's dial() backoff; bufferedAmount policy (64 KiB keep accumulating, 1 MiB thin); re-dial on visibilitychange/online
// ring.ts: Ring(2000 points) replayed after reconnect; chip.ts: the SPEC section 10 chip; caps.ts: capabilities() + enterFullscreenAndWake(); tools.ts: toolbar; main.ts: wiring, ?host= override, /api/info hints
```

### 2.6 Android (component E)

```kotlin
object SolStream { const val MAGIC = 0xDA; const val VERSION = 0x01; const val HEADER_LEN = 16; const val POINT_LEN = 11; object Op { /* same table as TS */ } }
class WirePoint(val x: Float, val y: Float, val pressure: Float, val deltaMs: Int)          // deltaMs since the first point
class Encoder(private val nowUs: () -> Long) { /* same method set as the TS Encoder; one direct little-endian ByteBuffer(64 KiB); UUID via a big-endian temporary */ }
data class StateReport(val governor: Int, val flags: Int, val mode: Int, val inkSource: Int, val progress: Float, val msToReturn: Long, val pageIndex: Int, val strokeCount: Int, val undoDepth: Int, val redoDepth: Int)
object Decoder { fun decode(bytes: ByteArray): ServerMessage? }                               // Ack, State, Pong
class WetInkSurface(context: Context, sink: StrokeSink) : SurfaceView(context)               // CanvasFrontBufferedRenderer with runCatching fallback; setZOrderOnTop(true); TRANSLUCENT; requestUnbufferedDispatch(SOURCE_CLASS_POINTER) in onAttachedToWindow
class DryInkView(context: Context) : View(context)                                           // Bitmap, invalidate(Rect), BlendMode.MULTIPLY for the highlighter
class StrokeSession(conn: InkConnection, enc: Encoder, dry: DryInkView, canvasW: Int = 1200, canvasH: Int = 1600) : WetInkSurface.StrokeSink { var tool: Int; var sendPerEvent = false; fun onFrame(frameTimeNanos: Long); fun undo(); fun redo(); fun clear(); fun newPage(); fun togglePin(); fun returnNow() }
class InkConnection(scope: CoroutineScope, candidates: Candidates, listener: Listener) { fun start(); fun stop(); fun send(frame: ByteArray): Boolean; val queueBytes: Long }   // OkHttp 5.5.0, pingInterval 10 s, NoDelaySocketFactory, subprotocol header Sec-WebSocket-Protocol: solstream.v1, callbacks posted to main; singleton shared by MainActivity and OverlayService (same clientId, role ink vs overlay)
object NoDelaySocketFactory : SocketFactory()                                                 // Socket().apply { tcpNoDelay = true }
class Discovery(ctx: Context) { fun start(onHost: (InetAddress, Int, String) -> Unit, onLost: (String) -> Unit); fun stop() }   // NsdManager legacy path, one resolve at a time, MulticastLock when SdkExtensions.getExtensionVersion(TIRAMISU) < 7, try/catch on stop
class Candidates { fun next(): String?; fun reportFailure(url: String); fun reportSuccess(url: String); fun setManual(host: String?); fun fromDiscovery(host: InetAddress, port: Int) }   // mDNS, 127.0.0.1:7788, manual, --es host
class OverlayService : Service()                                                             // foregroundServiceType connectedDevice; one WRAP_CONTENT TYPE_APPLICATION_OVERLAY window via createDisplayContext(display).createWindowContext(...); FLAG_NOT_FOCUSABLE or FLAG_KEEP_SCREEN_ON; gravity TOP|CENTER_HORIZONTAL, y = 24 (or bottom per --es pills); pills Pin and Clear; labels from STATE
```

---

## 3. Threading model and frame pipeline

### 3.1 Queues (all GCD serial; Swift concurrency is not used)

| Queue | QoS | Owner | Does | Never |
|---|---|---|---|---|
| `capture.queue` | userInteractive | WebcamCapture | AVFoundation delegate; Passthrough: rewrap + `SinkFeeder.push`; otherwise `LatestFrameSlot.publish` | block, hold more than one buffer |
| `render.queue` (target `.global(qos: .userInteractive)`) | userInteractive | FramePipeline | 30 Hz tick: governor tick under lock, layout, pool acquire, `Compositor.render`, telemetry | wait on the GPU, touch the network or AppKit |
| Metal completion thread | Metal's | Compositor | `SinkFeeder.push(target)`, pool release, GPU time sample | anything else |
| `sink.queue` | userInteractive | SinkFeeder | `CMSampleBufferCreateReadyWithImageBuffer` + `CMSimpleQueueEnqueue` (serialises capture and completion producers) | block |
| `net.queue` | userInitiated | WebServer | NWListener and every NWConnection; HTTP; WebSocket parse; `Codec.decodeHeader`; hand-off to ink.queue | rasterise, touch the governor directly |
| `ink.queue` | userInitiated | InkRouter | full decode, `StrokeStore` ops, `InkRasterizer.apply` (IOSurfaceLock), governor events via `PipelineControl.post`, STATE broadcast, save triggers | wait for the render queue or the GPU |
| `mirror.queue` | userInteractive | ScrcpySession, H264Decoder, MirrorSource | socket reads, demux, AVCC build, synchronous VT decode, slot publish | run the getevent parser |
| `stylus.queue` | userInteractive | StylusWatcher | `Pipe` readability -> `EvdevParser` -> `StylusContactMachine` -> `SideButtonGestures` -> governor events; long-press one-shot timer | parse Strings per line |
| `adb.queue` | utility | AdbClient, DeviceTracker, WifiMirror | process spawn and wait, forwards, installs | be in any frame or ink path |
| `io.queue` | utility | SessionSaver, Settings persistence, ClientRegistry writes | PNG render from the model, JSON, file writes | hold the ink queue |
| main | UI | AppModel, SwiftUI, Carbon hotkeys, OSSystemExtension delegate, AllowClientPanel | 2 Hz stats mirror, menus, panels | see a pixel buffer except the preview layer |

Cross-queue hand-offs: `LatestFrameSlot` (unfair lock), `Locked<EngageGovernor>` (held for microseconds; `handle` and `tick` are O(1)), `DispatchQueue.async` with value types for ink messages, `DispatchSemaphore(value: 3)` with `wait(timeout: .now())` for output buffers (drop on contention). The only real `wait` is in tests.

### 3.2 Paths by mode

Passthrough (viewer present). Camera-paced. `capture.queue`: `CMSampleBufferGetImageBuffer` -> first-frame facts recorded once (`CVPixelBufferGetIOSurface != nil`, size, fourcc) -> `SinkFeeder.push(pb)` -> `CMSimpleQueueEnqueue` if `count < capacity`, else drop and count. No timer; `FrameClock` stopped. Fallback when the buffer is not IOSurface-backed, not BGRA or not 1920x1080: `OutputPool.acquire` + Metal blit (same size) or `CIContext.render(_:to:)` (format conversion, letterbox), logged once as failure row 5 and `stats.passthroughZeroCopy = false`.

Engaging, Live, Returning. `FrameClock` at 30 Hz. Each tick on `render.queue`: (1) `now = CACurrentMediaTime()`; `out = governor.withLock { $0.tick(now:) }`; effects dispatched (savePage -> io.queue via InkRouter snapshot, clearCanvas -> ink.queue, STATE -> InkRouter.broadcast). (2) `frame = StudioLayout.frame(progress:layout:orientation:canvasAspect:breath:)`. (3) If `Settings.frameReuse` and nothing changed (progress, camera sequence, canvas seed, mirror seed, no pre-warning): re-push the previous target with a new PTS and return (flag default off). (4) `guard let target = pool.acquire() else { dropped += 1; return }`. (5) `presenter = cameraSlot.take()?.buffer` (nil -> cream placeholder quad); `canvas = .layers(surfaces)` or `.mirror(latest, uv)`. (6) `compositor.render(inputs, into: target) { gpuMs in feeder.push(target); pool.release(target); telemetry }`. On entering ENGAGING the pipeline renders frame 0 synchronously in the same call that starts the clock so the first moved frame leaves within one capture interval.

Whiteboard Only: same loop with the whiteboard layout; the camera slot is ignored.

Mirror: `mirror.queue` publishes decoded BGRA buffers into `MirrorSource`'s slot; the compositor samples the latest with the crop UV computed from `CropInsets.uv(sessionWidth:sessionHeight:nativeWidth:nativeHeight:)`.

### 3.3 Idle rule (D32)

`FramePipeline` keeps `viewers` (from `ViewerWatcher`), `previewVisible` (from `PreviewWindow`) and `sinkConnected` (from the sink status). `wantsCapture = viewers > 0 || previewVisible || !sinkConnected`. Start immediately when it becomes true; when it becomes false arm a 60 s one-shot (`viewerIdleStopSeconds`); if still false when it fires: `WebcamCapture.stop()`, `OutputPool.flush()`, `stats.captureIdleReason = "viewers=0 preview=hidden"`, STATE bit7 set. On restart the host pushes the last cached frame (or a cream card) to the sink immediately so a viewer never sees the extension's placeholder while the camera warms up. `--perf-log` prints `capture=idle` and Diagnostics shows failure row 33.

### 3.4 Back-pressure (newest wins)

| Boundary | Capacity | Policy |
|---|---|---|
| Camera -> slot | 1 | replace |
| Camera -> sink (Passthrough) | sink queue 1 | drop when full, count |
| Pool | 3, semaphore 3 | `wait(timeout: .now())` fails -> skip tick |
| Compositor -> sink | sink queue 1 | drop when full |
| Decoder -> slot | 1 | replace |
| WebSocket receive | 64 KiB reads, 2 MiB max | close 1009 |
| Web send | `bufferedAmount` > 64 KiB keep accumulating; > 1 MiB thin points, keep start/commit | never block input |
| Android send | `send()` false -> reconnect; `queueSize()` > 256 KiB -> thin | same |
| STATE | RateLimiter 100 ms during animation, 1 s LIVE | coalesce |
| getevent | 64 KiB kernel pipe; parser drains every callback | harmless if it ever lags |

### 3.5 Latency budget (pen down to the frame leaving the Mac, web client over Wi-Fi)

Digitizer to Chrome 5 to 10 ms (UNVERIFIED on the DC-1); batching to rAF 0 to 11 ms; WebSocket 2 to 5 ms; decode and raster under 0.5 ms; wait for the next tick 0 to 33 ms; composite under 1 ms; extension forward about 1 ms. Median about 35 ms, worst about 60 ms. Mirror engage adds getevent (single-digit ms over USB, UNVERIFIED) and the picture adds the encoder (20 to 50 ms) and VT decode (5 to 15 ms). A `--latency-probe` flag logs STROKE_START arrival to the first sink enqueue with progress > 0.

---

## 4. Ink path

`net.queue`: WebSocket frame complete -> `Codec.decodeHeader` (magic, version, length sanity) -> copy the payload bytes into a value and `ink.queue.async`. `ink.queue`: `Codec.decodeLenient`; identity and allow gate; `StrokeStore.append` returns `.drawSegments(id, fromIndex)` -> `InkRasterizer.apply`: `IOSurfaceLock(ink, [], nil)`, cached `CGContext` (base address is stable), for each new point `setLineWidth(base * (0.55 + 0.9 p))`, `move(to:)`, `addLine(to:)`, `strokePath()`, `IOSurfaceUnlock`; then `pipeline.post(.motion(id))`. Highlighter goes to the highlight surface with normal blending (the shader multiplies). Eraser: `StrokeStore.erase` -> `.redraw(dirty)` -> one lock: clip to dirty, clear, re-stroke intersecting strokes on both surfaces. Undo and redo likewise. Clear: `clear(fullRect)` on both. Tearing within one dirty rectangle for at most one frame is accepted (no double-buffered canvas).

Client disconnect: `InkRouter.clientClosed` calls `StrokeStore.commitAll(ids:)` for that client's open strokes and posts `.clientGone(strokeIDs:)`; when no ink client remains it posts `.allClientsGone`. Neither changes the governor state.

---

## 5. Server details

- `NWListener(using: params, on: port)` where `params = NWParameters(tls: nil, tcp: tcpOptions)` with `tcpOptions.noDelay = true`, `params.allowLocalEndpointReuse = true`, `params.serviceClass = .interactiveVideo`; `listener.service = NWListener.Service(name: bonjourName, type: "_daylight-camera._tcp", domain: nil, txtRecord: NWTXTRecord(["v": "1", "ws": "/ink", "port": "\(port)"]))` set before `start(queue:)`; `serviceRegistrationUpdateHandler` logs `.add(endpoint)`; `stateUpdateHandler` `.failed` -> try the next port up to 7799, then failure row 16.
- Per connection: `receive(minimumIncompleteLength: 1, maximumLength: 65536)`; `HTTPRequest.parse`; `GET /ink` with upgrade -> `webSocketAccept`, echo `solstream.v1` when offered, 101, frame loop; `/healthz`, `/api/info`, `/daylight-ink.apk` via `ApiRoutes`; everything else from `Resources/web` through `WebRootPath.resolve` with the MIME table (`UTType(filenameExtension:)?.preferredMIMEType` fallback), `Connection: close`.
- Allow gate and STATE cadence exactly as PROTOCOL sections 8 and 6.14. The `AllowClientPanel` is created on main; `InkRouter.pendingAllow` hops to main with the connection id; Allow writes the registry on io.queue and posts back to ink.queue to send ACK 0 + STATE.
- Info.plist keys: `LSUIElement`, `NSCameraUsageDescription`, `NSSystemExtensionUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBonjourServices: [_daylight-camera._tcp]`, `DaylightBuildSigned`, the three UUIDs.

---

## 6. Mirror mode internals (component F)

1. adb server policy (`AdbServerPolicy`): probe `127.0.0.1:5037` with `000Chost:version`. No answer -> default socket (our bundled adb spawns its own server on 5037). Same version as our bundled client -> shared. Different -> run ours on `tcp:localhost:27180` through `ADB_SERVER_SOCKET` in the child environment and show failure row 24. Never `kill-server`. Every command passes `-s SERIAL`.
2. Device tracking (`DeviceTracker`): `host:track-devices` on a raw TCP socket to the chosen server (`0012host:track-devices`), parsed by `AdbDevicesParser` (scan backwards from `transport_id:`); fallback `adb devices -l` every 2 s. DC-1 heuristic: `model:` containing `Daylight` or `DC`, or serial starting `JP` or `DC1`, else the first device; `mirrorDeviceSerial` overrides.
3. Launch (`ScrcpySession`): `adb -s S push Resources/thirdparty/scrcpy-server-v4.1 /data/local/tmp/scrcpy-server.jar`; `adb -s S forward tcp:27183 localabstract:scrcpy` (27184...27199 on failure); `adb -s S shell CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 4.1 log_level=info tunnel_forward=true video=true audio=false control=false cleanup=false video_codec=h264 max_size=1600 video_bit_rate=8000000 max_fps=30 send_device_meta=true send_frame_meta=true send_stream_meta=true send_dummy_byte=true`; `NWConnection` to `127.0.0.1:27183` with `noDelay`; read one byte, expect `0x00`, retry up to 100 x 100 ms; then `adb -s S forward --remove tcp:27183`. `[server] ERROR:` lines from stderr become failure row 25. Stop: cancel the connection, `Process.terminate()` the shell child (the server exits on broken pipe).
4. Demux (`ScrcpyDemuxer`, big-endian): dummy byte, 64-byte `Build.MODEL` (label), codec id (`0x68323634`; 0 and 1 are errors, row 26), 12-byte session packet (bit 7 of byte 0; width, height; re-sent on rotation), then 12-byte frame headers (`u64 pts_flags`: bit 62 config, bit 61 key frame, low 61 bits PTS microseconds; `u32 size`) and Annex-B payloads.
5. Decode (`H264Decoder`): on `.config` -> `AnnexB.parameterSets` -> `CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator:parameterSetCount:parameterSetPointers:parameterSetSizes:nalUnitHeaderLength: 4, formatDescriptionOut:)`; if a session exists and `VTDecompressionSessionCanAcceptFormatDescription` is false -> `VTDecompressionSessionWaitForAsynchronousFrames`, `VTDecompressionSessionInvalidate`, recreate with `VTDecompressionSessionCreate(allocator:formatDescription:decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true], outputCallback: nil, decompressionSessionOut:)`. On `.frame`: `AnnexB.toAVCC` into a freshly allocated `[UInt8]` for this access unit; `CMBlockBufferCreateWithMemoryBlock` over that allocation with a custom block allocator that frees it when the block buffer is released (the buffer is never reused; VideoToolbox may retain the sample buffer beyond the synchronous return); `CMSampleBufferCreateReady` with `presentationTimeStamp = CMTimeMake(ptsUs, 1_000_000)`; `VTDecompressionSessionDecodeFrame(_:sampleBuffer:flags: [], infoFlagsOut:outputHandler:)` synchronously; the handler publishes to the slot. Errors: `needsKeyFrame = true`, drop until bit 61; if none within 12 s, restart the session (row 27). 420v two-plane output is the documented optimisation, not v1.
6. Crop (`CropInsets`): per-orientation insets in native tablet pixels (portrait base 1200x1600, landscape 1600x1200) converted at render time to UV fractions of the CURRENT session size, so a 960x1280 fallback stream and a rotation crop the same screen region; `croppedAspect` feeds `StudioLayout.fit`. Settings shows the live mirror with four draggable edges (`MirrorCropView`); top inset defaults to `pillStripHeight` (96) when pills are enabled and 0 otherwise.
7. Stylus (`StylusWatcher`): `adb -s S shell -T getevent -pl` -> `EvdevCapabilitiesParser.penNode` (log the full listing once; row 28 when none); `adb -s S shell -T getevent -lt /dev/input/eventN` long-running; `EvdevParser` -> `StylusContactMachine(pressureMax:)` -> `.contactDown` = `GovernorEvent.penContact(down: true)`, `.contactUp` = `penContact(down: false)`, eraser edges = `eraserContact`, side button edges -> `SideButtonGestures` (`down`/`up`/`timerFired` with a one-shot `DispatchSourceTimer` at `pendingDeadline()`) -> `.pin(-1)` on double press, `.clear` on long press (swappable), gated by `mirrorPinClearMode`. Restart with backoff 0.5 s doubling to 8 s on EOF; on EOF post `penContact(down: false)` so the idle timer can run.
8. Pills: `UsbOnboarding.installInk(... pills: true)` installs the APK, grants `SYSTEM_ALERT_WINDOW` through `appops set` and `POST_NOTIFICATIONS` through `pm grant`, sets `adb reverse tcp:7788 tcp:7788`, and runs `am start-foreground-service -n com.twelve.daylight.ink/.OverlayService --es pills top`. The pills connect with role `overlay` and the canvas's clientId (auto-allowed).
9. Cable-free interim (`WifiMirror`, D42): after a successful USB session record the tablet IPv4 from `adb -s S shell ip route`, run `adb -s S tcpip 5555`; when no USB device is listed and the toggle is on, `adb connect <ip>:5555` and check stdout for `connected` or `already connected` (`adb connect` exits 0 on failure); otherwise row 32.
10. Mirror session end (return to PASSTHROUGH, Clear, source switch, quit): `SessionSaver.saveMirror(lastFrame, uv:, sessionStart:)` writes `mirror-<HH-mm-ss>.png`.

---

## 7. Onboarding, Allow panel, diagnostics

Implemented per SPEC section 13. `OnboardingSteps` is a state machine fed by `ExtensionInstaller.status`, `VirtualCameraSink.status`, `AVCaptureDevice.wasConnectedNotification` (filtered to the fixed device UUID string), `ClientRegistry` changes and `MirrorSource` first-frame; each failure row is a `FailureText.Case` so the UI, the log and `FailureTextTests` share one table.

---

## 8. Session saving internals

`SessionSaver` runs on `io.queue`. Triggers come from governor effects (`savePage(reason)`), from `InkRouter` (page change, clear), from a 60 s `DispatchSourceTimer` (`startAutosave`) that asks `isDirty()` and `snapshot()` on ink.queue, from `AppModel.hold(.camera)` and from `applicationShouldTerminate` (waits up to 2 s). `StrokeStore.document(...)` is a value copy taken on ink.queue; `PNGExporter.render` draws from the model into a throwaway `CGBitmapContext` (`noneSkipFirst | byteOrder32Little`, PaperBg fill, highlighter `.multiply`, ink normal) and `CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)`; `JSONEncoder` with sorted keys for the document. `markSaved(at:)` runs on ink.queue after success. Session folder per `SessionFiles.sessionDirectory` (first stroke after launch or after a 10-minute gap). STATE bit6 is set for the duration.

---

## 9. CI plan

### 9.1 Workflows

Two files with identical jobs: `/.github/workflows/whiteboard-camera.yml` (monorepo, path-filtered, `working-directory: whiteboard-camera`) and `whiteboard-camera/.github/workflows/ci.yml` (standalone). Triggers: `push` (monorepo: the branch only), `pull_request`, `push.tags: v*`, `workflow_dispatch` with input `notarize` (boolean, default false). `concurrency: { group: wbc-${{ github.ref }}, cancel-in-progress: true }`. `timeout-minutes`: golden 10, kit-linux 20, web 20, android 30, mac 60. Actions pinned to majors verified by `git ls-remote` this session or in the research notes: `actions/checkout@v7`, `actions/upload-artifact@v7`, `actions/download-artifact@v8` (tags v8.0.1 and v7.0.0 both exist; v8 is current), `actions/setup-node@v7`, `actions/setup-java@v6`, `gradle/actions/setup-gradle@v6`, `actions/cache@v6`. Every job's first step is `scripts/ci-env.sh` (prints `uname -a`, tool versions, and on macOS `xcode-select -p`, `xcodebuild -version`, `swift --version`).

### 9.2 Jobs

| Job | Runner | Steps (each a make target) | Cache | Artifacts |
|---|---|---|---|---|
| `golden` | `ubuntu-24.04` | `make golden-check` (python3 regenerates to a temp file, diffs the canonical file and the three copies) | none | none |
| `kit-linux` | `ubuntu-24.04` (Swift 6.4 preinstalled on the image, per research-android-ink 6.1, design-ux 15.1 and design-reliability 13.2 which read the image readme; `ci-env.sh` fails fast with "install swift-actions/setup-swift@v2.4.0 as plan B" if `swift` is missing) | `make kit-test` = `swift test --package-path mac/DaylightKit --parallel` | `actions/cache@v6` on `mac/DaylightKit/.build` keyed by `Package.swift` + `swift --version` | test log on failure |
| `web` | `ubuntu-24.04` | `actions/setup-node@v7` (node 22, `cache: npm`, `cache-dependency-path: whiteboard-camera/web/package-lock.json`); `make web-build` (`npm ci`, `npm run typecheck`, `npm run build`); `make web-test` (`npx playwright install --with-deps chromium`, `npx playwright test`) | npm via setup-node; `~/.cache/ms-playwright` via `actions/cache@v6` keyed by the Playwright version | `web-dist` (`web/dist/`), `playwright-report` on failure |
| `android` | `ubuntu-24.04` | `actions/setup-java@v6` (temurin 17); `gradle/actions/setup-gradle@v6`; `make android-ci` (`./gradlew --no-daemon :app:testDebugUnitTest :app:assembleDebug`) | Gradle user home via setup-gradle | `daylight-ink-debug-apk` (`android/app/build/outputs/apk/debug/*.apk`), test reports on failure |
| `mac` (needs golden, kit-linux, web, android) | `macos-15` (arm64; Xcode 16.4 is the image default at `/Applications/Xcode.app`; `ci-env.sh` logs `xcode-select -p` and never sets `DEVELOPER_DIR` unless `DAYLIGHT_XCODE_PATH` is set and the path exists, in which case it exports it and logs the choice) | `actions/download-artifact@v8` for `web-dist` and `daylight-ink-debug-apk`; `brew install xcodegen` (2.46.0 bottle); `make thirdparty`; `make embed` (web + apk); `make mac-generate`; `make kit-test` (macOS); `make mac-test`; `make mac-build-unsigned`; `make mac-smoke`; then only when `env.HAS_SIGNING == 'true'`: `make mac-sign-import`, `make mac-archive`, `make mac-export`; and only when `env.DO_NOTARIZE == 'true'`: `make mac-notarize` (includes `make mac-dmg`) | `actions/cache@v6` on `build/thirdparty` keyed by the two sha256 pins; no DerivedData cache | `Daylight-unsigned.zip` always; `Daylight-signed.zip` when signed; `Daylight.dmg` + `notarization-log.json` when notarized; `xcodebuild-logs` always (`xcodebuild -version`, `swift --version`, `xcodebuild -help` once, `ls -R Daylight.app`, `lipo -archs adb`, `codesign -dvv` output) |

Secrets gating (the `secrets` context cannot be read in a job or step `if:`): the mac job declares job-level `env: HAS_SIGNING: ${{ secrets.DAYLIGHT_DEVELOPER_ID_P12_BASE64 != '' && secrets.DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64 != '' && secrets.DAYLIGHT_TEAM_ID != '' }}` and `DO_NOTARIZE: ${{ (startsWith(github.ref, 'refs/tags/v') || inputs.notarize == true) && secrets.ASC_API_PRIVATE_KEY_BASE64 != '' }}`; steps use `if: env.HAS_SIGNING == 'true'`. UNVERIFIED wording of the GitHub docs (blocked here); the first run validates the YAML. Secrets are exactly the eight of research-cmio-signing section 6: `DAYLIGHT_TEAM_ID`, `DAYLIGHT_DEVELOPER_ID_P12_BASE64`, `DAYLIGHT_DEVELOPER_ID_P12_PASSWORD`, `DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64`, `DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_PRIVATE_KEY_BASE64`.

Signing path (scripts, from research-cmio-signing sections 3.3 to 3.5): `security create-keychain`, `security import ... -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcrun`, `security set-key-partition-list -S apple-tool:,apple:`, `security list-keychain -d user -s`; profiles decoded with `security cms -D`, `plutil -extract UUID raw` and `plutil -extract Name raw`, copied to both `~/Library/MobileDevice/Provisioning Profiles/<UUID>.provisionprofile` and `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`; `DAYLIGHT_APP_PROFILE` and `DAYLIGHT_EXT_PROFILE` exported for XcodeGen `${VAR}` substitution; `xcodebuild ONLY_ACTIVE_ARCH=NO -project mac/Daylight.xcodeproj -scheme Daylight -destination "generic/platform=macOS" -archivePath build/Daylight.xcarchive archive`; `xcodebuild -exportArchive -archivePath build/Daylight.xcarchive -exportOptionsPlist build/ExportOptions.plist -exportPath build/export` with `method developer-id`, `signingStyle manual`, `signingCertificate Developer ID Application`, `teamID`, `provisioningProfiles` for both bundle ids; pre-notarization checks `codesign -vvv --deep --strict`, `codesign -d --entitlements :-`, `spctl -vvv --assess --type exec`; the nested `Resources/thirdparty/adb` is signed explicitly with `codesign --force --options runtime --timestamp -s "Developer ID Application" ...` before archiving (UNVERIFIED whether required; harmless); `hdiutil create -srcFolder build/export/Daylight.app -format UDZO -o build/Daylight.dmg`, `codesign --timestamp` on the DMG; `xcrun notarytool submit build/Daylight.dmg --key AuthKey.p8 --key-id ... --issuer ... --wait`, `xcrun notarytool log <id> ... notarization-log.json`, `xcrun stapler staple` on the app (before the DMG) and on the DMG. Release settings: `ENABLE_HARDENED_RUNTIME YES`, `OTHER_CODE_SIGN_FLAGS --timestamp`, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS NO`.

Unsigned path: `xcodebuild -project mac/Daylight.xcodeproj -scheme Daylight -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build`; if the system-extension target refuses (UNVERIFIED), retry that target with `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES` and record which path succeeded; if both fail, build the app without the extension dependency (OBS precedent) and say so in the log. `DaylightBuildSigned` is written as `false` into the built Info.plist.

Build number: `scripts/mac-generate.sh` writes `build/BuildNumber.xcconfig` with `CURRENT_PROJECT_VERSION = ${GITHUB_RUN_NUMBER:-1}`; `project.yml` includes it via `configFiles`. `MARKETING_VERSION` comes from the `VERSION` file.

### 9.3 Makefile targets (all phony; bash scripts with `set -euo pipefail`, `set -x` when `CI=true`)

```
help                 list targets
golden               python3 protocol/gen_golden.py; copy to the three test resource paths
golden-check         scripts/check-golden.sh (regenerate to tmp, diff all four copies, fail on drift)
kit-test             swift test --package-path mac/DaylightKit --parallel        (Linux or macOS)
web-build            cd web && npm ci && npm run typecheck && npm run build
web-test             cd web && npx playwright install --with-deps chromium && npx playwright test
web-ci               web-build web-test
android-build        cd android && ./gradlew --no-daemon :app:assembleDebug
android-test         cd android && ./gradlew --no-daemon :app:testDebugUnitTest
android-ci           android-test android-build
thirdparty           scripts/fetch-thirdparty.sh  (scrcpy-server-v4.1 sha256 deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae;
                     platform-tools_r37.0.0-darwin.zip sha256 094a1395683c509fd4d48667da0d8b5ef4d42b2abfcd29f2e8149e2f989357c7; extract platform-tools/adb
                     and platform-tools/NOTICE.txt into mac/Daylight/Resources/thirdparty; log ls -l, lipo -archs, file, unzip -l)
embed                scripts/embed-web.sh web/dist mac/Daylight/Resources/web; scripts/embed-apk.sh <apk dir> mac/Daylight/Resources/DaylightInk.apk (skips with a warning when absent)
mac-generate         scripts/mac-generate.sh (BuildNumber.xcconfig, xcodegen generate in mac/)
mac-test             xcodebuild test -project mac/Daylight.xcodeproj -scheme DaylightTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
mac-build-unsigned   scripts/mac-build-unsigned.sh -> build/Daylight-unsigned.zip (+ xcodebuild-logs)
mac-smoke            build/DerivedData/Build/Products/Release/Daylight.app/Contents/MacOS/Daylight --self-test --perf-log
mac-sign-import      scripts/mac-sign-import.sh (needs the DAYLIGHT_* and ASC_* env from secrets)
mac-archive          xcodebuild archive -> build/Daylight.xcarchive
mac-export           xcodebuild -exportArchive -> build/export/Daylight.app; zip -> build/Daylight-signed.zip
mac-dmg              scripts/make-dmg.sh -> build/Daylight.dmg
mac-notarize         scripts/mac-notarize.sh (stapler app, mac-dmg, notarytool submit --wait, log, stapler dmg)
ci-linux             golden-check kit-test web-ci android-ci
ci-mac               thirdparty embed mac-generate kit-test mac-test mac-build-unsigned mac-smoke
doctor               prints which tools exist (swift, xcodegen, node, java, python3, adb) and which targets can run here
clean
```

Environment contract: `DAYLIGHT_TEAM_ID`, `DAYLIGHT_CODE_SIGN_IDENTITY` (default `Developer ID Application`), `DAYLIGHT_APP_PROFILE`, `DAYLIGHT_EXT_PROFILE`, `GITHUB_RUN_NUMBER` (default 1), `DAYLIGHT_XCODE_PATH` (optional), `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_PRIVATE_KEY_PATH`.

---

## 10. XcodeGen `project.yml` (shape from research-cmio-signing section 5, with these deltas)

- `options.deploymentTarget.macOS: "14.0"`; `options.xcodeVersion: "16.4"`; `settings.base.SWIFT_VERSION: "5.0"`, `SWIFT_STRICT_CONCURRENCY: minimal`, `DEVELOPMENT_TEAM: ${DAYLIGHT_TEAM_ID}`, `CODE_SIGN_STYLE: Manual`, `MARKETING_VERSION` from `VERSION`; `configFiles: { Release: ../build/BuildNumber.xcconfig, Debug: ../build/BuildNumber.xcconfig }`.
- Release config: `ENABLE_HARDENED_RUNTIME: YES`, `OTHER_CODE_SIGN_FLAGS: --timestamp`, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`.
- `packages: { DaylightKit: { path: DaylightKit } }`.
- Target `Daylight` (`type: application`): sources `Daylight` plus `{ path: Daylight/Resources/web, type: folder, buildPhase: resources }` and `{ path: Daylight/Resources/thirdparty, type: folder, buildPhase: resources }`; `Daylight/Resources/DaylightInk.apk` as a resource (optional: present when CI embedded it); dependencies `target: DaylightCameraExtension` (embedded into `Contents/Library/SystemExtensions` by XcodeGen's system-extension copy phase) and `package: DaylightKit`; `PRODUCT_BUNDLE_IDENTIFIER com.twelve.daylight`, `PRODUCT_NAME Daylight`, `CODE_SIGN_IDENTITY ${DAYLIGHT_CODE_SIGN_IDENTITY}`, `PROVISIONING_PROFILE_SPECIFIER ${DAYLIGHT_APP_PROFILE}`; `info.properties`: `LSUIElement true`, `NSCameraUsageDescription`, `NSSystemExtensionUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBonjourServices: [_daylight-camera._tcp]`, `DaylightBuildSigned false` (flipped by the signing script), the three UUIDs; `entitlements.properties`: `com.apple.developer.system-extension.install true`, `com.apple.security.application-groups: ["$(TeamIdentifierPrefix)com.twelve.daylight"]`, `com.apple.security.device.camera true`; a `postBuildScripts` step that signs `Resources/thirdparty/adb` only when `CODE_SIGNING_ALLOWED == YES` (UNVERIFIED identity variable; the archive script re-signs it anyway).
- Target `DaylightCameraExtension` (`type: system-extension`): `PRODUCT_BUNDLE_IDENTIFIER com.twelve.daylight.camera`, `PRODUCT_NAME com.twelve.daylight.camera`, `SKIP_INSTALL YES`, `PROVISIONING_PROFILE_SPECIFIER ${DAYLIGHT_EXT_PROFILE}`; Info.plist and entitlements per section 2.4.
- Target `DaylightTests` (`type: bundle.unit-test`, `platform: macOS`, `dependencies: [target: Daylight, package: DaylightKit]`).
- Schemes: `Daylight` (build both targets, archive Release, a `--self-test` launch-argument variant) and `DaylightTests`.

---

## 11. Test plan (everything runs in CI without a device, a camera or a signed build)

### 11.1 DaylightKit XCTest (ubuntu-24.04 Swift 6.4 and macos-15 Xcode 16.4, same files)

GoldenVectorTests (every case decodes, non-decode-only cases re-encode byte-equal, malformed inputs produce the named `CodecError`, unknown opcode lenient path, 25/31-byte STROKE_START, 0/24-byte CLEAR, UTF-8 name, limits 4096 and 1024, odd-offset point reads); GovernorScenarioTests (SPEC 5.4 under `ManualClock` at 1/30 s); SpringTests (SPEC 5.3 values, retarget continuity, settle at 0.251 s, Euler reference with 14.4 ms substeps within 1e-3, Euler at 1/30 s diverges); LayoutTests (every SPEC 6 number, s = 0 equals passthrough, landscape variant, `fit` for 3:4, 4:3 and the crop aspect, clip-space endpoints); StrokeStoreTests (ops, bounds inflation, dot rule, erase precision, undo/redo depths, dirty and savedAt, JSON round trip); HTTPTests and WebSocketFrameTests (A7 of SPEC 16); SHA1Tests (`abc` and the RFC 6455 accept key); WebRootPathTests (`..`, `%2e%2e`, absolute, empty); MIMETests; ScrcpyDemuxerTests, AnnexBTests, EvdevParserTests, EvdevCapabilitiesTests, StylusContactMachineTests, SideButtonGesturesTests, AdbDevicesParserTests, CropInsetsTests (SPEC F1, F4); SettingsTests (`validated()` clamps); FailureTextTests (every case has a sentence and a log line); SessionFilesTests. PerfTests exist and use `measure {}` to print timings; they assert nothing about wall time.

### 11.2 macOS-only `DaylightTests` bundle

InkRasterizerTests (a 1 px InkBlack dot at canvas (0, 0) lands in the first row of IOSurface memory with B, G, R = 0x11 and A = 0xFF at the dot centre; a segment's pixels are non-zero along its path; erase redraw leaves neighbours intact; highlighter writes only the highlight surface; seed changes on write). CompositorTests (skipped with `XCTSkip` when `MTLCreateSystemDefaultDevice()` is nil): Studio Split at s = 0.5 with a gradient presenter and one stroke, probes of cream margin, divider, paper and presenter pixels; s = 0 equals the presenter input on sampled pixels; landscape frame. SinkFeederTests (SPEC C4). WebServerLoopbackTests (SPEC B2). PipelineSmokeTests: `FramePipeline` with a `FakeCapture` (static IOSurface at 30 Hz), `PreviewOnlySink` and a `FakeSink` (`CMSimpleQueue` capacity 1): after 1 s in passthrough at least 25 pushes; after `.engage` the governor reaches LIVE and composed frames flow; the pool never exceeds 3; no drops with a prompt fake sink; the idle rule stops capture after a shortened hysteresis and the first frame after restart is the cached one; 300 frames through the tick with timings printed by `measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()])`, not asserted. H264DecoderTests (a synthetic SPS/PPS creates a format description; a second SPS triggers the recreate path; no real decode). CropInsetsRuntimeTests (UV for 1200x1600, 960x1280 and 1600x1200 sessions select the same screen region).

### 11.3 `Daylight --self-test` (mac job, `make mac-smoke`)

SPEC B1 verbatim; exits non-zero on any failed probe; prints the perf log, `lipo -archs` of adb, the sha256 of scrcpy-server, the extension bundle's Info.plist keys and whether a Metal device existed.

### 11.4 Web (Playwright 1.56.1, Chromium, viewport 1200x1600, `hasTouch`, `isMobile`, `webServer: tests/fake-mac.mjs`)

`protocol.spec.ts`, `pen.spec.ts` (CDP `Input.dispatchMouseEvent` with `pointerType: "pen"` and `force`; `Input.dispatchTouchEvent` for fingers), `app.spec.ts`, `state.spec.ts`, `reconnect.spec.ts`, `secure.spec.ts` (non-secure branch via `page.addInitScript` stubbing `isSecureContext`): SPEC D2 to D6.

### 11.5 Android (JVM, JUnit 4, no device)

`SolStreamTest`, `StrokeSessionTest`, `CandidatesTest`, `DiscoveryQueueTest` (fake resolver, `FAILURE_ALREADY_ACTIVE` re-queues): SPEC E2 to E4. Android framework classes stay behind interfaces (`InkSink`, `Resolver`), so no Robolectric.

### 11.6 Cross-client parity

`make golden-check` guards the manifest against the Python oracle; the three suites guard each client against the manifest. A protocol change touches `gen_golden.py`, the manifest and all three codecs in one PR or CI goes red.

---

## 12. Implementation order (every milestone ends with all five jobs green and a named owner test)

| M | Scope | Exit criterion |
|---|---|---|
| M0 Scaffold (day 1) | directory layout, Makefile, both workflows, `gen_golden.py` + manifest + copies, DaylightKit Protocol/Governor/Spring/Layout/Canvas/HTTP/Settings with tests, web and android skeletons that build and run their golden tests, `project.yml` with app + extension + tests, the extension as the research note's condensed code with the timer consume strategy, the app as a menu bar with a Preview window showing a cream placeholder, `fetch-thirdparty.sh`, docs stubs, `THIRD_PARTY_NOTICES.md` | all five jobs green; `Daylight-unsigned.zip` shows the menu bar icon and the cream preview on the owner's Mac |
| M1 Camera first (days 2 to 4) | `ExtensionInstaller`, `CMIODeviceLocator`, `CMIOSinkClient`, `ViewerWatcher`, `SinkFeeder`, `PreviewOnlySink`, onboarding steps 0 to 2 with failure rows 1 to 15, `docs/SIGNING.md` with the owner's Apple checklist, signing scripts, `ExportOptions.plist.in`; a test pattern (cream card with a moving InkBlack bar) pushed into the sink | unsigned build compiles app + extension (or logs the ad-hoc fallback); `SinkFeederTests` green; once the owner adds secrets: signed + notarized DMG, "Daylight Camera" with the moving bar in FaceTime. This milestone's code is finished before any ink code; it waits only on the owner's secrets |
| M2 Passthrough + Studio Split (days 4 to 6) | `WebcamCapture`, `LatestFrameSlot`, `OutputPool`, `Compositor` + shaders, `CanvasSurfaces` (empty), `FrameClock`, `FramePipeline` with the idle rule, hotkeys wired as engage / return / pin / clear / hold, `Telemetry`, `--self-test` (render part), `--perf-log` | Ctrl+Opt+Cmd+D slides to an empty cream whiteboard in Zoom and back; return at 90 s with the amber breath; LED off between calls; `CompositorTests`, `PipelineSmokeTests` green |
| M3 Web ink (days 6 to 9) | `WebServer`, `InkConnection`, `ClientRegistry`, `AllowClientPanel`, `InkRouter`, `InkRasterizer`, STATE, `SessionSaver`, `ApiRoutes`, the web client (tools, chip, start overlay, ring), Playwright suite, `UsbOnboarding.openWeb`, `--self-test` loopback round trip, `WebServerLoopbackTests` | owner opens the page on the DC-1, Allow, writes, sees it live in Zoom, Clear returns, PNG + JSON in Documents |
| M4 Native app + pills (days 9 to 12) | APK protocol + JVM tests, discovery, connection, wet/dry ink, toolbar, chip, onboarding, settings, `OverlayService`; `UsbOnboarding.installInk`; APK embedding and `/daylight-ink.apk` | APK artifact; wireless install from the web card; auto-connect over Wi-Fi; pills over a note app (pills only, no mirror yet); `docs/COMPARE.md` started |
| M5 Mirror (days 12 to 16) | `AdbClient`, `AdbServerPolicy`, `DeviceTracker`, `ScrcpySession`, `H264Decoder`, `MirrorSource`, `CropInsets` + `MirrorCropView`, `StylusWatcher`, side button, `WifiMirror`, failure rows 21 to 28b and 32 | owner mirrors the SolOS note app; pen contact engages; double press pins; long press clears; pills visible on the tablet and absent from the camera; rotation keeps the crop |
| M6 Hardening and docs (days 16 to 18) | adversarial review of every lock and queue hop; a 10-minute `FakeCapture` soak in `PipelineSmokeTests` asserting no pool growth; `frameReuse` and `deadlineIdle` measured on the M5 Max and enabled only if they help; docs (SETUP, SIGNING, LOOSE_ENDS, COMPARE, TESTING-CHECKLIST, PERFORMANCE with measured numbers); tag `v0.1.0` | the owner's testing checklist fully run; numbers in PERFORMANCE.md are measured |
| M7 Repo split | `git subtree split --prefix=whiteboard-camera` to `12twelve12hi/whiteboard-camera`, secrets re-added, `ci.yml` green standalone | standalone CI green |

---

## 13. Risk register (ordered by damage if wrong)

| # | Risk | Mitigation |
|---|---|---|
| 1 | The virtual camera cannot be tested until the owner completes the Apple checklist (Developer ID certificate, two profiles, API key, eight secrets); unsigned or ad-hoc system extensions never load with SIP on | M1 first; preview window as the complete fallback; `docs/SIGNING.md` precise to the click; owner action is the critical path |
| 2 | Manual signing of two targets with two profiles fails the first time (wrong specifier, missing capability, profile only in the Xcode 15 directory) | both profile directories, both profiles, `xcodebuild -help` and `codesign -d --entitlements` in logs, failure rows 6, 9, 10 |
| 3 | `CODE_SIGNING_ALLOWED=NO` does not build a `system-extension` product | scripted ad-hoc fallback, then app-without-extension fallback, both logged |
| 4 | The sink is not `streams[1]` or the 90 Hz consume timer misbehaves | directions logged on first run; index-1 fallback; Diagnostics shows queue count and capacity; the recursive strategy is one constant away |
| 5 | macOS `AVCaptureVideoDataOutput` BGRA buffers are not IOSurface-backed or not 1080p for the owner's webcam | first-frame runtime check; Metal blit or CIContext fallback; row 5 |
| 6 | Custom CMIO property or its listener does not report viewers | 1 Hz poll always on; if the counter itself is unreliable the idle rule degrades to "capture runs while the sink is connected" (LED on) |
| 7 | Swift 5-mode code written blind fails to compile on Xcode 16.4 or Linux Swift 6.4 | Foundation-only kit compiled in M0; third-party-confirmed spellings isolated in `CMIOSinkClient`, `SinkFeeder`, `InkRasterizer` |
| 8 | Hand-written HTTP + WebSocket on Network.framework rejects Chrome's or OkHttp's handshake | Linux framing tests; `WebServerLoopbackTests` and `--self-test` exercise the real NWListener; fallback B (second listener with `NWProtocolWebSocket` on 7789, page learns the port from `/api/info`) needs owner sign-off |
| 9 | The DC-1's Wacom node lacks `BTN_TOOL_PEN`, `BTN_TOUCH`, `ABS_PRESSURE` or `BTN_STYLUS` under SolOS | runtime enumeration and logging; rows 28 and 28b; pills remain |
| 10 | scrcpy-server 4.1 does not run on SolOS or the demuxer assumptions fail | pinned by hash and version string; synthetic demuxer tests; row 25 and 26 |
| 11 | graphics-core 1.0.4 front buffer misbehaves on the DC-1 | runCatching fallback to the dry view; settings toggle |
| 12 | mDNS fails on the owner's network | loopback over USB and the remembered manual host; numeric IPs in the menu |
| 13 | Android 11+ revokes the adb authorisation after 7 days | onboarding text about "Disable adb authorization timeout"; loose end; the native app is the no-debugging path |
| 14 | Overlay pills do not appear inside the mirror, or appear elsewhere | crop insets are a 10-second fix in Settings; default top inset 0 when pills are off |
| 15 | Chrome on the DC-1 reports pressure > 0 for a hovering side-button press | pressure-0 rule plus on-screen tools; checklist item |
| 16 | `secrets` in job-level `env` is rejected by GitHub | fails fast at YAML validation; fix is mechanical |
| 17 | Toolchain combinations (AGP 8.13.2 / Gradle 8.14.5 / Kotlin 2.3.10) need iterations | plan B is the sibling's AGP 9.0.1 / Gradle 9.1.0 / Kotlin 2.3.20 |
| 18 | GitHub macOS runners expose no Metal device | render tests skip with a warning; compositing is first truly tested on the owner's Mac |
| 19 | Notarization caps (75 per day, 5 to 15 min) | gated to tags and dispatch |
| 20 | CoreGraphics per-segment stroking is slower than estimated at 240 Hz | measured by `--perf-log`; fallback batch several segments per `strokePath()` |

---

## 14. File-ownership map (parallel agents never edit the same file)

| Component | Owns (exclusively) | Must not touch |
|---|---|---|
| (A) DaylightKit | `mac/DaylightKit/Sources/DaylightKit/{Protocol,Governor,Spring,Layout,Canvas,HTTP,Settings,Session,Util}/**`, the matching `mac/DaylightKit/Tests/DaylightKitTests/{Protocol,Governor,Spring,Layout,Canvas,HTTP,Settings,Session}/**`, `mac/DaylightKit/Tests/DaylightKitTests/GoldenVectorTests.swift`, `protocol/gen_golden.py`, `protocol/golden/**` | `Package.swift` (integrator), `Mirror/` folders (F), the three golden copies (generated by `make golden`) |
| (B) Daylight app core | `mac/Daylight/{App,Onboarding,Settings,Pipeline,Ink,Server}/**`, `mac/Daylight/Resources/{Assets.xcassets,placeholder.png}`, `mac/Daylight/Info.plist`, `mac/Daylight/Daylight.entitlements`, `mac/DaylightTests/{Pipeline,Server}/**` | `Contracts/` (integrator), `Camera/` (C), `Mirror/` (F), `Resources/web` and `Resources/DaylightInk.apk` (generated), `Resources/thirdparty` (generated) |
| (C) Camera extension + host sink | `mac/DaylightCameraExtension/**`, `mac/Daylight/Camera/**`, `mac/DaylightTests/Camera/**` | everything else |
| (D) Web whiteboard | `web/**` except `web/tests/golden/` (generated) | everything else |
| (E) Android app + overlay | `android/**` except `android/app/src/test/resources/solstream-v1.json` (generated) | everything else |
| (F) Mirror mode | `mac/Daylight/Mirror/**`, `mac/DaylightKit/Sources/DaylightKit/Mirror/**`, `mac/DaylightKit/Tests/DaylightKitTests/Mirror/**`, `mac/DaylightTests/Mirror/**` | everything else; the Kit `Mirror/` folder stays Foundation-only |
| Integrator | `mac/project.yml`, `mac/ExportOptions.plist.in`, `mac/DaylightKit/Package.swift`, `mac/Daylight/Contracts/**`, `Makefile`, `scripts/**`, `.github/workflows/ci.yml`, `/.github/workflows/whiteboard-camera.yml`, `README.md`, `SPEC.md`, `docs/**`, `THIRD_PARTY_NOTICES.md`, `LICENSE`, `VERSION`, `android/gradle/wrapper/**` and `android/gradlew*` (copied once from the sibling; E owns everything else under android), the three generated golden copies | component source files |

Contracts frozen at M0 by the integrator: `VirtualCameraSink`, `MirrorFrameSource`, `PipelineControl` (section 2.2), the DaylightKit public interfaces of section 2.1 (A may add members, never rename or remove), the golden manifest schema. A component that needs a contract change files it in `docs/LOOSE_ENDS.md` and the integrator applies it.

---

## 15. Owner-facing failure text

Lives in SPEC section 13.3 and in `DaylightKit/Settings/FailureText.swift` (one enum case per row; `FailureTextTests` asserts the strings; the UI and the log read the same table).

---

## 16. Performance measurement plan (`docs/PERFORMANCE.md` is filled in M6)

Signposts in `capture`, `composite`, `ink.apply`, `sink.push`, `decode`; `--perf-log` one line per second; the owner's Activity Monitor readings for Passthrough (target under 3 percent), Studio Split (under 8 percent) and Idle (LED off, under 1 percent); the engage latency probe; the slide frame count. `frameReuse` and `deadlineIdle` are turned on only when these numbers show a win.

---

## 17. Judges' mustFix resolution log

| mustFix | Repair in this document |
|---|---|
| Idle rule leaves the preview black on unsigned builds | D32 and section 3.3: capture runs when viewers > 0 OR preview visible OR sink not connected; 60 s hysteresis only on stop |
| `delta_ms` since the previous point | PROTOCOL section 4 and D18: since the first point, saturating; golden `stroke_chunk_3pts` pins it; all four implementations and `gen_golden.py` |
| Legacy 28-byte HANDSHAKE without a layout | dropped entirely (ambiguous with a 14-byte name); PROTOCOL 6.1 |
| `Header.opcode` typed as the enum | `Header.opcode: UInt16` with `knownOpcode: Opcode?`; `decodeLenient` returns `nil` for unknown opcodes |
| savePage at LIVE -> RETURNING saves twice | savePage moved to RETURNING -> PASSTHROUGH; `savedAt`/`lastInkAt` dirty rule; SPEC 5.2 and 12 |
| Pin during RETURNING lost | SPEC 5.2 rows RETURNING + pin -> ENGAGING pinned; engage and hotkeys likewise |
| Mirror crop in tablet pixels against the encoded size | `CropInsets` with fractions of the current session size per orientation (D40, section 6.6) |
| APK never present in the mac job | mac needs android and web; `download-artifact@v8`; `embed-apk.sh`; `/daylight-ink.apk` (D43) |
| setup-swift pinned from a future run; setup-node version unspecified; Xcode 26.3 via DEVELOPER_DIR | preinstalled Swift 6.4 with a fail-fast doctor; `setup-node@v7`; Xcode 16.4 default with an optional, existence-checked, logged `DAYLIGHT_XCODE_PATH` (D29) |
| AVCC buffer reuse under VideoToolbox | per-access-unit allocation owned by the block buffer (D41, section 6.5) |
| Moving a running, possibly translocated bundle | "Reveal in Finder" and translocation detection (D45) |
| Recursive consume default in the extension | OBS 90 Hz timer default behind `consumeStrategy` (D33) |
| One-shot deadline timers replace the 30 Hz tick | plain 30 Hz clock while not PASSTHROUGH; `frameReuse` and `deadlineIdle` flags default off (D34) |
| Hard wall-time asserts on shared runners | `measure {}` prints; only functional invariants asserted (D48) |
| STATE bit4 meaning while capture is stopped | bit4 = camera attached; bit7 = capture idle; `--perf-log` and Diagnostics show the reason |
| Overlay role as a second identity | overlay reuses the ink clientId; auto-allowed; PROTOCOL section 7 |
| Eraser engage, side-button Clear, disconnect behaviour as silent product guesses | D36 (eraser off by default, Settings toggle), D10 (long press Clear), D37 (disconnect never changes state); owner lines in LOOSE_ENDS |
| `adb pair` with typed ports | D42: `adb tcpip 5555` interim; pairing documented in SETUP.md only |
| HANDSHAKE within 2 s | 5 s (PROTOCOL 6.1) |
| STROKE_CHUNK unbounded | 4096 points and 1024 erase ids; drop and log, no close |
| Allow prompt as a modal alert; auto-deny after 60 s | non-activating panel, menu item mirror, pending until answered (D44) |
| CMIO device lookup unspecified | `CMIODeviceLocator` does the OBS walk (`kCMIOHardwarePropertyDevices`, `kCMIODevicePropertyDeviceUID`, `kCMIODevicePropertyStreams`, `kCMIOStreamPropertyDirection` logged); AVFoundation only for `wasConnectedNotification` |
| Landscape mirror aspect-fit to 608 px | oracle landscape variant (SPEC 6.4) |
| Manifest location for the SwiftPM test | `resources: [.copy("Resources/solstream-v1.json")]` and `Bundle.module`; copies via `make golden` |
| Hotkey toggle and hold semantics | SPEC 5.2 and 7; hold never touches `pinned` |
| Playwright not gating the Mac artifact | mac needs web (and android) |
