# Implementation plan: six parallel components and one integrator

Status: binding for the implementation phase (M1 to M6 of ARCHITECTURE section 12). Written after the completeness review of the M0 skeleton (actions run 37104560769, commit fb0574a, all five jobs green). Order of truth when documents disagree: `SPEC.md` (behaviour), `docs/PROTOCOL.md` (bytes), `docs/ARCHITECTURE.md` section 18 (scaffold deltas), the rest of `docs/ARCHITECTURE.md`, this plan, then the scaffold code. Scaffold code that disagrees with a document is wrong and is fixed by its owner.

Writing rules for everything a human reads: no em-dashes; LivePaper is a transflective LCD (never "MIP"); the backlight is DC dimming (never "PWM"); VRR is 45 to 90 Hz (never 120 Hz). Model names never appear in the repository except in commit trailers.

---

## 0. The shape of the work

Six implementation agents run in parallel, one per component:

| Letter | Component | Compiler that proves it | Runs without a device, a camera or a signed build? |
|---|---|---|---|
| A | DaylightKit (pure Swift, Foundation only) | `kit-linux` and `mac` jobs (`swift test`) | yes, fully |
| B | Daylight app core (pipeline, server, ink router, saving, UI) | `mac` job (`mac-debug`, `mac-test`, `mac-smoke`) | yes, with fakes (section 7) |
| C | Camera extension and host-side sink client | `mac` job (`mac-debug` compiles the extension, `mac-test` runs `SinkFeederTests`) | compile plus unit tests; the real camera needs the owner's signed build |
| D | Web whiteboard | `web` job (typecheck, build, node tests, Playwright) | yes, fully (fake Mac in Node) |
| E | Android app and overlay | `android` job (JVM tests, debug APK) | protocol and session logic yes; UI only on the DC-1 |
| F | Mirror mode (adb, scrcpy, VideoToolbox, getevent) | `kit-linux` (parsers) and `mac` (`mac-test`) | parsers and a real H.264 fixture decode yes; adb paths with a fake adb |

One integrator owns `project.yml`, `Package.swift`, `Makefile`, `scripts/`, both workflows, `Sources/Contracts/`, the golden copies and every document outside `docs/handoff/`. The integrator runs a pre-flight commit (section 1) BEFORE the six agents start, then merges component work in the order of section 9.

Every agent reads, in this order, before writing a line: `SPEC.md`, `docs/PROTOCOL.md`, `docs/ARCHITECTURE.md` (section 18 first), this plan, `docs/LOOSE_ENDS.md`, and the research note for its area in the orchestrator's scratchpad (`research-mac-pipeline.md` for B, `research-cmio-signing.md` for C and the integrator, `research-web-server.md` for B and D, `research-android-ink.md` for E, `research-scrcpy-adb.md` for F). The research notes are the only place an agent may take an Apple or Android API name from; anything not in a note and not in the Apple or Android documentation it fetches itself is UNVERIFIED and gets a runtime fallback plus a line in its handoff file.

---

## 1. Pre-flight (integrator, one commit, CI green before anyone else starts)

| # | Deliverable | Detail | Checked by |
|---|---|---|---|
| P0.1 | `mac/Daylight/Sources/Contracts/{VirtualCameraSink.swift, MirrorFrameSource.swift, PipelineControl.swift, MirrorControl.swift}` | exactly the text of section 3 of this plan | `make mac-debug` compiles |
| P0.2 | `DaylightTests` target | `project.yml`: `DaylightTests: { type: bundle.unit-test, platform: macOS, sources: [DaylightTests], dependencies: [{ target: Daylight }, { package: DaylightKit }], settings: { base: { PRODUCT_BUNDLE_IDENTIFIER: com.twelve.daylight.tests } } }` plus a scheme `DaylightTests` with `test: { targets: [DaylightTests] }`; XcodeGen sets `TEST_HOST` because the target depends on the application (`PBXProjGenerator.swift:1366-1376` in the XcodeGen clone). `mac/DaylightTests/Placeholder/PlaceholderTests.swift` with one passing test so the bundle is never empty. `scripts/mac-test.sh`: `xcodebuild test -project mac/Daylight.xcodeproj -scheme DaylightTests -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO 2>&1 \| tee build/xcodebuild-logs/test.log` and a `grep -q 'TEST SUCCEEDED'` gate (the same `tee` and `grep` shape `mac-debug.sh` uses). `Makefile`: `mac-test` target; `ci-mac` includes it. Both workflows: a `make mac-test` step after `make mac-debug`. | the step is green; LOOSE_ENDS B13 records whether the hosted bundle launched cleanly |
| P0.3 | `mac-smoke` target | `scripts/mac-smoke.sh` runs `build/DerivedData/Build/Products/Release/Daylight.app/Contents/MacOS/Daylight --self-test --perf-log` with a 120 s timeout (`perl -e 'alarm 120; exec @ARGV'` or a background process plus `kill`; `timeout(1)` is not on macOS by default) and fails on a non-zero exit. The CI step is added by the integrator only after B's first merge makes `--self-test` exit 0 (section 9); until then the target exists but is not called. | `make mac-smoke` exits 0 after B lands |
| P0.4 | Vendor binaries in the bundle | `scripts/fetch-tools.sh`: output directory becomes `mac/Daylight/Resources/Vendor/`; `.gitignore`: replace `mac/Vendor/` with `mac/Daylight/Resources/Vendor/`. `scripts/mac-generate.sh`: when the directory is missing, create it with a one-line `README.txt` ("run make fetch-tools") so the folder reference resolves. `project.yml`: add `{ path: Daylight/Resources/Vendor, type: folder, buildPhase: resources }` to the `Daylight` target sources. Both workflows: `make fetch-tools` step before `make mac-generate` in the mac job (the runner reaches dl.google.com and github.com; this box does not). Log `ls -l`, `lipo -archs`, `file` and the sha256 of both files into `build/xcodebuild-logs/vendor.txt` (fills LOOSE_ENDS B2). | the mac job log shows the two sha256 checks passing and the `Vendor/` folder inside `ls -R Daylight.app` |
| P0.5 | APK embedded (SPEC D43) | mac job `needs: [golden, web, kit-linux, android]`; `actions/download-artifact@v8` with `name: daylight-ink-debug-apk`, `path: whiteboard-camera/android/app/build/outputs/apk/debug` (standalone workflow: without the prefix); `scripts/embed-apk.sh <dir> mac/Daylight/Resources/DaylightInk.apk` copies the first `*.apk` found or warns and exits 0; `.gitignore` adds `mac/Daylight/Resources/DaylightInk.apk`; `project.yml` adds `{ path: Daylight/Resources/DaylightInk.apk, optional: true, buildPhase: resources }` (XcodeGen `optional: true` tolerates a missing file); `Makefile`: `embed-apk`. | `ls -R Daylight.app` in the log lists `Contents/Resources/DaylightInk.apk` |
| P0.6 | Tag trigger | both workflows: `on.push.tags: ['v*']` next to `branches:`. GitHub ignores `paths:` for tag pushes, which is the desired behaviour. | a later `v0.1.0` tag starts the workflow (verified at M6) |
| P0.7 | Handoff directory | `docs/handoff/README.md` explaining the rule: each component owns exactly one file `docs/handoff/<letter>-<name>.md` for text the integrator folds into SETUP, SIGNING, COMPARE, TESTING-CHECKLIST, PERFORMANCE and LOOSE_ENDS, plus any contract-change request. | files exist |
| P0.8 | `LICENSE` and `THIRD_PARTY_NOTICES.md` | `THIRD_PARTY_NOTICES.md` with the scrcpy-server entry (Apache-2.0, Genymobile) and the adb entry (Google platform-tools 37.0.0, `NOTICE-platform-tools.txt` shipped in `Vendor/`). `LICENSE` waits for the owner's choice (LOOSE_ENDS A14; added on 2026-10-03 as Apache-2.0); the integrator writes a placeholder paragraph in README "License: to be chosen by the owner" until then. | files exist |
| P0.9 | Golden check still green | nothing changes in `protocol/`; confirm `make golden-check` passes after the pre-flight. | `golden` job |

The pre-flight does not add features. It makes every acceptance criterion in sections 4 to 6 checkable in CI.

---

## 2. Rules for all six agents

1. Branch: `claude/daylight-whiteboard-camera-tzxfjb` in `12twelve12hi/daylight-control-your-mac`, the only branch anyone pushes to. Work in `whiteboard-camera/` only. Never touch `packages/`, `apps/`, `scripts/`, `docs/`, `README.md`, `SPEC.md` at the monorepo root.
2. Files: edit only the paths your row in ARCHITECTURE section 14 gives you. If you need a change outside them (a plist key, a make target, a contract member, a golden vector), write the request into your `docs/handoff/<letter>-*.md` file under a heading "Requests for the integrator" and keep working with a local stub. The integrator applies it.
3. Commits: small, one concern each, message body states what CI job proves it. Every commit message ends with the two attribution trailers given in the session. Commit only your own paths (`git add <your dirs>`; never `git add -A`).
4. Push: `git pull --rebase origin claude/daylight-whiteboard-camera-tzxfjb` first; on a rebase conflict in a file you do not own, abort and ask the integrator. Push with the retry rule: on a non-fast-forward or network failure wait 20 s, pull with rebase, retry; five attempts with doubling waits (20, 40, 80, 160, 320 s), then stop and report.
5. CI: after every push read the run with the GitHub MCP tools (`actions_list` with `list_workflow_runs` filtered to the branch, `list_workflow_jobs`, `get_job_logs` with `return_content: true`). A red job in your component is yours to fix before anything else. A red job caused by someone else's files: do not fix it; note the run id in your handoff file and continue on your own files (your next push will re-run everything).
6. Golden vectors: only A edits `protocol/gen_golden.py`; the three copies are regenerated with `make golden` by the integrator. A protocol change is one commit by A (oracle plus Kit) followed by D and E updating their encoders; `golden-check` goes red in between and that is acceptable for at most one working day.
7. Public interfaces: section 3 contracts and the DaylightKit surface of ARCHITECTURE 2.1 are frozen. A may add members, never rename or remove. B, C and F may add internal types freely inside their folders; anything another component calls must appear in this plan or in a handoff request first.
8. Apple and Android facts: use only API names, plist keys, entitlements and CLI flags that appear in the research notes, in ARCHITECTURE, or in a documentation page you fetched yourself in this session. Everything else is UNVERIFIED: wrap it in a runtime check with a fallback and list it in your handoff file. Section 8 of this plan lists the UNVERIFIED items known today per component.
9. Threading: Swift language mode 5, GCD serial queues as ARCHITECTURE 3.1, no actors, no `async`/`await` in shipping code, no `Task {}`; the kit stays Foundation plus Dispatch only.
10. Tests first for anything with numbers: every SPEC number (geometry, spring values, timeouts, byte offsets) is asserted by a test before the code that uses it exists.
11. Logging: `os.Logger(subsystem: "com.twelve.daylight", category: "<area>")` in the app and the extension; the kit logs nothing. Owner-facing text comes only from `FailureText` (A owns the table, section 3.4 freezes the case names).
12. Done means: your acceptance criteria (sections 4 to 6) are green in CI, your handoff file is written, and `docs/LOOSE_ENDS.md` requests (if any) are listed in the handoff file.

---

## 3. Frozen interfaces

### 3.1 Contracts (`mac/Daylight/Sources/Contracts/`, integrator writes them in P0.1 exactly as below)

```swift
// VirtualCameraSink.swift
import CoreMedia
import DaylightKit

enum SinkStatus: Equatable {
    case notInstalled            // extension not activated yet
    case awaitingApproval        // activation submitted, System Settings approval pending
    case installed               // device visible, sink stream not open
    case connected               // sink stream open, frames flow
    case error(FailureText.Case, String)
}

/// Implemented by CMIOSinkClient (C) and PreviewOnlySink (C); FakeSink in DaylightTests (B).
protocol VirtualCameraSink: AnyObject {
    var status: SinkStatus { get }
    var onStatusChange: ((SinkStatus) -> Void)? { get set }
    var onQueueAltered: (() -> Void)? { get set }
    var viewerCount: Int { get }                        // 0 when unknown or not connected
    var onViewerCount: ((Int) -> Void)? { get set }
    func start()
    func stop()
    @discardableResult func push(_ sampleBuffer: CMSampleBuffer) -> Bool   // never blocks; false when dropped
}
```

```swift
// MirrorFrameSource.swift
import CoreVideo
import DaylightKit

/// Implemented by MirrorSource (F); consumed by FramePipeline (B). FakeMirrorSource in DaylightTests (B).
protocol MirrorFrameSource: AnyObject {
    func latest() -> (buffer: CVPixelBuffer, uv: UVRect, aspect: Double, orientation: StudioLayout.CanvasOrientation)?
    var frameSeed: UInt64 { get }                       // increments on every new decoded frame
    var onGovernorEvent: ((GovernorEvent) -> Void)? { get set }   // penContact, eraserContact, pin, clear
    func start()
    func stop()
}
```

```swift
// PipelineControl.swift
import DaylightKit

/// Implemented by FramePipeline (B); used by InkRouter (B), Hotkeys (B), MirrorController (F), AppModel (B).
protocol PipelineControl: AnyObject {
    func post(_ event: GovernorEvent)
    var governorSnapshot: GovernorOutput { get }
    func setViewerCount(_ n: Int)
    func setPreviewVisible(_ visible: Bool)
    func setSinkConnected(_ connected: Bool)
    var onStateForClients: ((StateReport) -> Void)? { get set }
}
```

```swift
// MirrorControl.swift
import CoreVideo
import DaylightKit

enum MirrorStatus: Equatable {
    case idle                                  // mirror source not selected or stopped
    case noDevice                              // tracking, no DC-1 visible
    case connecting(serial: String)
    case mirroring(serial: String, width: Int, height: Int)
    case error(FailureText.Case, String)
}

/// Implemented by MirrorController (F); the only F type that B constructs or calls.
protocol MirrorControl: AnyObject {
    var source: MirrorFrameSource { get }
    var status: MirrorStatus { get }
    var onStatusChange: ((MirrorStatus) -> Void)? { get set }
    var devices: [AdbDevice] { get }
    var onDevicesChange: (([AdbDevice]) -> Void)? { get set }
    var diagnostics: [String: String] { get }  // adb server mode and version, pen node, session size, codec
    func start()                               // start device tracking; mirror the chosen DC-1 when present
    func stop()
    /// USB onboarding for the other two sources (SPEC 9.2 step 1 and 9.3 step 1).
    func setUpOverUSB(source: InkSource, host: String?, pills: Bool, completion: @escaping (Result<Void, Error>) -> Void)
    /// Last decoded frame and its crop, for SessionSaver.saveMirror (SPEC 12).
    func latestFrameForSave() -> (buffer: CVPixelBuffer, uv: UVRect)?
    func tryWiFiMirror(completion: @escaping (Bool) -> Void)   // SPEC D42
}
```

### 3.2 Concrete initialisers B constructs (frozen; owners may add defaulted parameters only)

| Owner | Type and initialiser | Where B calls it |
|---|---|---|
| C | `ExtensionInstaller(extensionBundleIdentifier: String = "com.twelve.daylight.camera")`; `activate()`, `openApprovalPane()`, `status`, `onChange` (ARCHITECTURE 2.3) | `AppDelegate` at launch |
| C | `CMIODeviceLocator(deviceUUID: UUID)` | inside `CMIOSinkClient`; B only passes UUIDs |
| C | `CMIOSinkClient(deviceUUID: UUID, sinkUUID: UUID, queue: DispatchQueue)` conforming to `VirtualCameraSink` | `AppDelegate` when `DaylightBuildSigned` is true in Info.plist |
| C | `PreviewOnlySink()` conforming to `VirtualCameraSink` | `AppDelegate` when unsigned, and in tests |
| C | `ViewerWatcher(locator: CMIODeviceLocator, queue: DispatchQueue)`; `onViewerCount`, `start()`, `stop()` | `AppDelegate`; B forwards counts to `PipelineControl.setViewerCount` |
| C | `SinkFeeder(sink: VirtualCameraSink)`; `push(_ pb: CVPixelBuffer, hostTimeNs: UInt64?) -> Bool`; `droppedFrames`, `pushedFrames` | `FramePipeline` (capture queue and Metal completion) |
| F | `MirrorController(settings: Settings, vendorDirectory: URL, pipeline: PipelineControl, queue: DispatchQueue)` conforming to `MirrorControl` | `AppDelegate`; `vendorDirectory = Bundle.main.resourceURL!.appendingPathComponent("Vendor")` |
| A | everything in ARCHITECTURE 2.1 | everywhere |

The UUID strings come from `Bundle.main.object(forInfoDictionaryKey:)` for `DaylightCameraDeviceUUID`, `DaylightCameraSourceUUID`, `DaylightCameraSinkUUID` (already in `project.yml`).

### 3.3 `Settings` (A owns the type; property names are frozen so B and F can read them on day 1)

Swift property names equal the SPEC section 11 keys verbatim. Types: `onboardingDone: Bool`, `onboardingVersion: Int`, `cameraUniqueID: String?`, `inkSource: InkSource`, `preferredLayout: LayoutStyle`, `holdMode: HoldMode` (not persisted: `CodingKeys` omits it), `autoEngage: Bool`, `idleTimeoutSeconds: Int`, `preWarningSeconds: Int`, `springK: Double`, `engageOnEraser: Bool`, `hotkeys: [HotkeyAction: HotkeyBinding]` where `enum HotkeyAction: String, Codable, CaseIterable { case whiteboardOnly, studioSplit, keep, clear, camera }` and `struct HotkeyBinding: Codable, Equatable { var keyCode: UInt32; var modifiers: UInt32 }` both live in `Settings.swift` (A), `port: UInt16`, `bonjourName: String?` (nil means "Daylight Camera on <hostname>", resolved by B), `trustLoopback: Bool`, `mirrorPinClearMode: MirrorPinClearMode` (`enum MirrorPinClearMode: String, Codable { case pills, penButton, both }`), `sideButtonDoublePressMs: Int`, `sideButtonLongPressMs: Int`, `sideButtonSwap: Bool`, `mirrorCropInsetsPortrait: CropInsets`, `mirrorCropInsetsLandscape: CropInsets`, `pillStripHeight: Int`, `mirrorPillsPosition: PillsPosition` (`enum PillsPosition: String, Codable { case top, bottom }`), `mirrorMaxSize: Int`, `mirrorBitRate: Int`, `mirrorMaxFps: Int`, `mirrorDeviceSerial: String?`, `adbServerMode: AdbServerMode` (`enum AdbServerMode: String, Codable { case auto, shared, privatePort }`), `adbPrivatePort: UInt16`, `mirrorOverWiFi: Bool`, `viewerIdleStopSeconds: Int`, `saveDirectory: URL?`, `saveStrokesJSON: Bool`, `autosaveSeconds: Int`, `previewOnLaunch: Bool`, `previewFloats: Bool`, `frameReuse: Bool`, `deadlineIdle: Bool`, `perfLog: Bool`. `Settings.defaults` holds the SPEC 11 defaults; `validated()` clamps every range in SPEC 11 (15...600, 0...30, 300...2400, 10...600, 15...600; `preWarningSeconds <= idleTimeoutSeconds - 1`; `port` 1024...65535 else 7788). `InkSource`, `LayoutStyle`, `HoldMode` gain `Codable` conformance (raw values). `CropInsets` is already `Codable`. `launchAtLogin` is not a stored property (read live by B from `SMAppService`). The scaffold's `mirrorPillsEnabled` and `layout` properties are removed (A).

### 3.4 `FailureText.Case` (A owns the enum; names frozen so B, C and F can reference them on day 1)

One case per SPEC 13.3 row, in row order: `notInApplications` (1), `unsignedBuild` (2), `cameraAccessDenied` (3), `noWebcam` (4), `webcamFormatComposed` (5), `extensionMissingEntitlement` (6), `extensionUnsupportedLocation` (7), `extensionDamaged` (8), `extensionSignatureInvalid` (9), `extensionValidationFailed` (10), `extensionForbiddenByPolicy` (11), `extensionNeedsApproval` (12), `extensionNeedsReboot` (12b), `sinkDeviceNotFound` (13), `sinkStreamLayout` (14), `viewerShowsBlack` (15), `portInUse` (16), `bonjourRenamed` (17), `nobodyConnected` (18), `allowDismissed` (19), `webNonSecure` (20), `adbNoDevice` (21), `adbUnauthorized` (22), `adbOffline` (23), `adbVersionClash` (24), `scrcpyServerFailed` (25), `scrcpyCodecError` (26), `decoderError` (27), `noPenDevice` (28), `noSideButtonEvents` (28b), `pillsInvisible` (29), `mdnsNotFound` (30), `saveFailed` (31), `wifiMirrorFailed` (32), `captureIdle` (33). `sentence(_:_:)` returns the "Owner sees (exact)" column with `args` substituted in order for every `<...>` placeholder; `logLine(_:_:)` returns the "Log line" column the same way. Row 12 takes one argument, the macOS-specific path text, chosen by B. The scaffold's nine cases are replaced (A).

### 3.5 Kit signatures the scaffold gets wrong (A fixes these in its first commit, before B consumes them)

| File | Scaffold | Contract (ARCHITECTURE 2.1 or SPEC) |
|---|---|---|
| `Layout/StudioLayout.swift` | `amberBreath` blends from `Tokens.borderSubtle` | SPEC 6.2: `mix(InkBlack, Amber, breath)`; `frame(progress:layout:orientation:canvasAspect:breath:)` missing |
| `Canvas/StrokeStore.swift` | `start(_ s: StrokeStart) -> CanvasOp?` | `start(_ s: StrokeStart, scale: (Double, Double)) -> CanvasOp?`; `commitAll`, `erase`, `undo`, `redo`, `newPage`, `document(...)`, `pageIndex` increments, `undoDepth` semantics per SPEC |
| `Canvas/` | no `Geometry.swift`, no `CatmullRom.swift` | both exist (Catmull-Rom ships as a tested helper, approach A rendering is what B uses first; LOOSE_ENDS F6) |
| `Canvas/PageDocument.swift` | flat struct, `version`, `app: "daylight"` | SPEC 12 schema: `schema: "daylight-whiteboard-strokes/1"`, `app`, nested `canvas`, `session`, `page`, `strokes[]` with `points` as `[[x, y, pressure, tMs]]`; `Codable` with sorted keys through the encoder B configures |
| `Governor/EngageGovernor.swift` | tracks pin, hold and contacts only; always PASSTHROUGH | the full SPEC 5.2 table, `GovernorConfig` consumed, `generation`, `needsTicks`, `nextDeadline`, `msToReturn`, `breath` |
| `Governor/Clock.swift` | `SystemClock.now()` is wall-clock | monotonic: `ProcessInfo.processInfo.systemUptime` (Foundation, both platforms); B feeds `CACurrentMediaTime()` directly and never uses `SystemClock` on the render path |
| `Session/SessionFiles.swift` | `<root>/Daylight Camera/<yyyy-MM-dd>/` | SPEC 12: `<root>/Daylight Camera/<yyyy-MM-dd>/<HH-mm-ss>/`; `pageBaseName(index:)` is 1-based in the name as now |
| `Settings/Settings.swift` | nine ad-hoc keys | section 3.3 |
| `Settings/FailureText.swift` | nine cases | section 3.4 |
| `Protocol/Identity.swift` | rejects clientID over 64 bytes, never checks the label | PROTOCOL 7: label at most 64 UTF-8 bytes (reject longer), clientID non-empty; keep the 64-byte clientID cap as an extra limit |
| `HTTP/WebSocketFrame.swift` | `parse` returns nil | full RFC 6455 parse: masks, 7/16/64-bit lengths, `maxPayload` -> `.oversize`, reserved bits, control frames at most 125 bytes, fragmentation flags; `WebSocketError` as declared |
| `HTTP/HTTPRequest.swift` | `response(status:headers:body:)` always appends `Connection: close` | keep, and add `statusText` for 403, 405, 413, 426 as needed by B |
| `Mirror/*.swift` (F, not A) | `ScrcpyDemuxer.feed` buffers only, `EvdevParser.feed` buffers only, `AnnexB` returns empty, no `EvdevCapabilitiesParser`, `StylusContactMachine`, `SideButtonGestures`, `AdbDevicesParser` | ARCHITECTURE 2.1 Mirror block, one file per type |

---

## 4. Component A: DaylightKit

Owns: `mac/DaylightKit/Sources/DaylightKit/{Protocol,Governor,Spring,Layout,Canvas,HTTP,Settings,Session,Util}/`, the matching test folders plus `Tests/DaylightKitTests/Protocol/GoldenVectorTests.swift` (already there), `protocol/gen_golden.py`, `protocol/golden/`, `docs/handoff/A-daylightkit.md`. Never touches `Package.swift`, `Mirror/`, the three golden copies.

Consumes: nothing (Foundation and Dispatch only; `swift test` on Linux is the proof).

Order of work:
1. Section 3.5 fixes that other components wait on, in this order: `Settings`, `FailureText`, `StudioLayout.frame` and `amberBreath`, `SessionFiles`, `PageDocument`, `StrokeStore` surface, `Identity`. Push after each file's tests pass locally in thought and in CI (every push runs `kit-linux` in about 40 s).
2. `EngageGovernor`: write `Tests/DaylightKitTests/Governor/GovernorScenarioTests.swift` from SPEC 5.4 first (one test per sentence, `ManualClock` stepping 1/30 s), then the transition table. `tick(now:)` returns effects; `handle` never allocates beyond the effects array.
3. `WebSocketFrame.parse` plus `Tests/.../HTTP/WebSocketFrameTests.swift` (SPEC A7 list: masked frames at payload lengths 0, 125, 126, 65535, 65536, fragmentation, control frames, oversize, reserved bits, unmasked client frame).
4. `StrokeStore` complete plus `Tests/.../Canvas/StrokeStoreTests.swift` (SPEC A6), `Geometry` (point to segment distance squared, stroke hit test at the radius edge), `CatmullRom.bezierControls` with the research note's numeric check (`c1 = p1 + (p2 - p0) / 6`, `c2 = p2 - (p3 - p1) / 6`).
5. `Tests/.../Layout/LayoutTests.swift` asserting every SPEC 6 number and that `frame(progress: 0, ...)` presenter equals `passthrough()` presenter.
6. `Tests/.../Spring/` additions: values at 0.100, 0.150, 0.200, 0.250, 0.333 within 1e-4; settle at 0.251 within one 1/30 s tick; Euler at 1/30 s diverges (position magnitude exceeds 2 within 10 steps).
7. `Tests/.../Settings/{SettingsTests,FailureTextTests}.swift`, `Tests/.../Session/SessionFilesTests.swift`, `Tests/.../Util/` for `RingBuffer`, `RateLimiter`, `FixedPoint`, `Hex`.
8. Optional golden additions (one commit, then tell D and E through the handoff file): `handshake_ack_denied`, `handshake_ack_unsupported`, and a decode-only `state_extended_24` (20-byte STATE plus 4 appended bytes) to pin the "read the first 20" rule; bump the case count in all three suites in the same commit set.
9. `docs/handoff/A-daylightkit.md`: the final public surface (copy of the `public` declarations), anything B must know about allocation or thread safety.

Acceptance (CI): `kit-linux` and the mac `make kit-test` step green with every test file above present; `grep -rn "^import" mac/DaylightKit/Sources` shows only `Foundation` and `Dispatch`; `make golden-check` green; `GovernorScenarioTests` has at least one test method per SPEC 5.4 sentence (the integrator counts them). Reviewer-checkable: SPEC 16 A1 to A8.

---

## 5. Component B: Daylight app core

Owns: `mac/Daylight/Sources/{App,Onboarding,Settings,Pipeline,Ink,Server}/`, the three scaffold files (moved into `Sources/App/` in B's first commit), `mac/Daylight/Resources/{Assets.xcassets,placeholder.png}`, `mac/DaylightTests/{Pipeline,Server,Ink,App}/`, `docs/handoff/B-app.md`.

Consumes:
- A: everything in ARCHITECTURE 2.1 (sections 3.3 to 3.5 above fix the day-1 surface). Until A lands a type, B writes against the contract and lets CI go red for at most one push; B never adds a copy of a Kit type to its own folders.
- C: `SinkFeeder`, `PreviewOnlySink`, `CMIOSinkClient`, `ExtensionInstaller`, `ViewerWatcher` by the initialisers in 3.2. Until C lands, B compiles against `FakeSink` in `DaylightTests/Pipeline/Fakes/FakeSink.swift` and a local `PreviewOnlySinkStub` INSIDE `DaylightTests` only (never in `Sources/`).
- F: `MirrorController` through `MirrorControl` only.
- Contracts: implements `PipelineControl` in `Pipeline/FramePipeline.swift`.

Rules specific to B: `Sources/{Pipeline,Ink,Server,Onboarding,Settings}` must not reference anything in `Sources/App/` (so the DaylightTests plan B of LOOSE_ENDS B13 stays possible); `App/` is the only place that knows about `NSStatusItem`, `AppDelegate`, `MirrorControl` wiring and `ExtensionInstaller`. No SwiftUI `App` or `@main`: windows are `NSWindow` with `NSHostingController(rootView:)`. The server binds `0.0.0.0` in the app and `127.0.0.1` under `--self-test`.

Order of work (each step ends with CI green):
1. Move the scaffold files to `Sources/App/`; `--self-test` argument parsing in `App/SelfTest.swift` that exits 0 and prints "self-test: no probes yet" (lets the integrator add `mac-smoke` immediately).
2. `Pipeline/`: `LatestFrameSlot` (`OSAllocatedUnfairLock`, macOS 13+, target is 14.0), `OutputPool` (pool attributes from research-mac-pipeline section 2 item 4, `DispatchSemaphore(value: 3)` with `wait(timeout: .now())`), `FrameClock`, `CanvasSurfaces` (IOSurface + `makeTexture(descriptor:iosurface:plane:)`, storage mode left at default), `InkRasterizer` (one `IOSurfaceLock` per op, `byteOrder32Little | premultipliedFirst`, y-flip CTM), `Compositor` + `Shaders.metal` (one pass, SurfaceCream clear, four quads, `bgra8Unorm`, canvas fragment math of SPEC 6.6, scissor to `canvasClip`), `Telemetry`, `FramePipeline` with the idle rule (SPEC D32) and the three paths of ARCHITECTURE 3.2. Tests: `DaylightTests/Pipeline/{InkRasterizerTests, CompositorTests (XCTSkip when no Metal device), PipelineSmokeTests}` with `Fakes/{FakeSink,FakeCapture,FakeMirrorSource}.swift`. `WebcamCapture` behind `protocol CaptureSource` (B-internal) so `FakeCapture` conforms too.
3. `Server/`: `WebServer` (one `NWListener`, `NWParameters(tls: nil, tcp:)` with `noDelay`, ports 7788...7799, Bonjour service set before `start`), `InkConnection` (HTTP head parse via `HTTPRequest.parse`, upgrade, frame loop via `WebSocketFrame.parse`, 2 MiB cap, close codes of PROTOCOL 1), `StaticFiles` (`WebRootPath.resolve`, `MIME.type` then `UTType(filenameExtension:)?.preferredMIMEType`, `/assets/*` immutable), `ApiRoutes` (`/healthz`, `/api/info`, `/daylight-ink.apk`), `LocalAddresses` (getifaddrs, utun + 100.64/10 first), `BonjourAdvertiser` (part of WebServer; `serviceRegistrationUpdateHandler` logs `.add`). Test: `DaylightTests/Server/WebServerLoopbackTests.swift` with `URLSessionWebSocketTask` on an ephemeral port: golden handshake, stroke start, chunk, commit -> ACK 0 (loopback) and STATE governor 1; a 2 MiB frame -> close 1009; an unknown-client handshake from a non-loopback-looking identity is not testable over loopback, so test the registry branch directly in `DaylightTests/Ink/ClientRegistryTests.swift`.
4. `Ink/`: `ClientRegistry` (`clients.json`, `seenOverUSB`), `InkRouter` (ink.queue, allow gate, active-source rule, `StrokeStore` + `InkRasterizer`, governor events of PROTOCOL 13, STATE cadence of SPEC D47 with `RateLimiter`), `SessionSaver` + `PNGExporter` (io.queue, SPEC 12 triggers, `markSaved`). Tests: `DaylightTests/Ink/{InkRouterTests,SessionSaverTests}.swift` (router fed with golden bytes through a fake connection; saver writes into a temp dir and the JSON decodes back into `PageDocument`).
5. `App/`: `AppModel` (2 Hz mirror of stats, menu state), `MenuBar` (status item menu: Ink source submenu, Hold submenu, Keep whiteboard, Clear, Camera, Open Preview, Settings, Setup again, Diagnostics, Quit; pending "Allow <label>" item), `Hotkeys` (Carbon `RegisterEventHotKey`, defaults of SPEC 14), `AllowClientPanel` (`NSPanel` with `.nonactivatingPanel`, top right, 60 s auto-dismiss), `Diagnostics` (SPEC 13.2), `SelfTest` (SPEC B1 complete), `PreviewWindow` (`AVSampleBufferDisplayLayer`), onboarding steps 0 to 5 (SPEC 13.1) in `Onboarding/`, Settings window in `Settings/` including `MirrorCropView` fed by `MirrorControl.source.latest()` and `HotkeyRecorder`.
6. `--perf-log`, `--latency-probe`, `frameReuse` and `deadlineIdle` flags (default off).
7. `docs/handoff/B-app.md`: SETUP text for the owner (first run, menu items, hotkeys), TESTING-CHECKLIST rows B triggers on purpose (SPEC 13.3 rows 1, 12, 13, 19, 33 plus 16, 18, 31), diagnostics copy format, requests for the integrator (new plist keys such as `NSLocalNetworkUsageDescription` text changes).

Acceptance (CI): `make mac-debug` green; `make mac-test` green with the test files listed above; `make mac-smoke` green with `--self-test` performing SPEC B1 (render probes skipped with a warning when `MTLCreateSystemDefaultDevice()` is nil, the socket round trip never skipped); the smoke log prints `passthroughZeroCopy`, the perf line format, `lipo -archs` of `Vendor/adb` and the sha256 of `Vendor/scrcpy-server-v4.1`. Reviewer-checkable: SPEC 16 B1 to B8 (B5 and B8 are manual on the owner's Mac and go to the checklist).

---

## 6. Component C: camera extension and host-side sink client

Owns: `mac/DaylightCameraExtension/Sources/`, `mac/Daylight/Sources/Camera/`, `mac/DaylightTests/Camera/`, `docs/handoff/C-camera.md`.

Consumes: `VirtualCameraSink` and `SinkStatus` (Contracts), `FailureText.Case` names of 3.4 (A). Nothing from B or F. The extension target imports CoreMediaIO, CoreMedia, CoreVideo, CoreGraphics, IOKit.audio, os.log only (no DaylightKit; `project.yml` does not link it to the extension and C does not ask for it).

Order of work:
1. Extension (ARCHITECTURE 2.4): `consumeStrategy` compile-time constant (`.timer90Hz` default, `.recursive` kept), the debug-only once-per-second consume rate log, `authorizedToStartStream(for:)` on the sink checking `client.signingID == "com.twelve.daylight"` when non-nil, the custom source-stream property `CMIOExtensionProperty(rawValue: "4cc_dlvw_glob_0000")` returning `streamingCounter`, the placeholder card with the SPEC 4 text drawn with CoreGraphics (text only when no sink is connected and a viewer streams), `notifyScheduledOutputChanged` on every consumed buffer. Nothing in the extension may block.
2. Host `Camera/`: `CMIODeviceLocator` (OBS walk, directions logged, index 1 fallback), `CMIOSinkClient` (`CMIOStreamCopyBufferQueue`, `CMIODeviceStartStream`, `CMSimpleQueueEnqueue` when `count < capacity`, retry every 2 s, `AVCaptureDevice.wasConnectedNotification` triggers a retry, status transitions to `SinkStatus`), `SinkFeeder` (`CMSampleBufferCreateReadyWithImageBuffer`, host-clock PTS strictly increasing, cached format description per (w, h, fmt)), `ViewerWatcher` (property read with `CMIOObjectGetPropertyData` plus a 1 Hz poll; `CMIOObjectAddPropertyListenerBlock` attempted and logged), `PreviewOnlySink` (status `.installed`, `push` returns true and drops), `ExtensionInstaller` (`OSSystemExtensionRequest.activationRequest`, delegate mapping every `OSSystemExtensionError.Code` to the `FailureText.Case` of SPEC 13.3 rows 6 to 12b, `.replace` always, `openApprovalPane()` tries `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` and otherwise shows the text path).
3. Tests `DaylightTests/Camera/`: `SinkFeederTests` (a `QueueSink: VirtualCameraSink` over `CMSimpleQueueCreate` capacity 1: two pushes give one enqueue and one drop; PTS strictly increasing over 100 buffers; one format description across 100 same-size buffers, a new one after a size change), `ExtensionBundleTests` (hosted tests run inside Daylight.app, so `Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")` lists one `.systemextension`; its `Info.plist` carries the same three UUIDs as `Bundle.main`, `CMIOExtension.CMIOExtensionMachServiceName` equals `$(TeamIdentifierPrefix)com.twelve.daylight` expanded or unexpanded, and `CFBundleIdentifier` is `com.twelve.daylight.camera`), `PreviewOnlySinkTests`.
4. `docs/handoff/C-camera.md`: the SIGNING.md owner checklist text (research-cmio-signing section 7, reworded for the owner, ending with the ADHD-friendly checklist), the FaceTime first-light procedure, which `kCMIOStreamPropertyDirection` values the first owner run logged (fills LOOSE_ENDS E2), requests for the integrator (none expected; the plist and entitlements are already correct).

Acceptance (CI): the extension compiles and is embedded in `mac-debug` (already true); `make mac-test` green with the three test files; `grep -rn "DaylightKit" mac/DaylightCameraExtension` is empty. Reviewer-checkable: SPEC 16 C1 to C4 (C5 is the owner's signed build).

---

## 7. Component D: web whiteboard

Owns: `web/` except `web/tests/golden/`, `docs/handoff/D-web.md`.

Consumes: `docs/PROTOCOL.md` and the golden manifest; `/api/info` JSON shape (PROTOCOL 1); STATE chip mapping (SPEC 10). Nothing from the Mac code. D adds `ws` as a devDependency for the fake Mac (D owns `package.json`).

Order of work:
1. `src/protocol.ts` is complete; keep it. Add `src/ring.ts` (2000 points, replay after reconnect), `src/caps.ts` (`capabilities()` reporting `isSecureContext`, wake lock, coalesced events, rawupdate; `enterFullscreenAndWake()`), `src/chip.ts` (SPEC 10 states and texts; tap = `togglePin(-1)`, long press 600 ms = `returnNow()`; breath formula from PROTOCOL 6.14), `src/tools.ts` (pen, highlighter, eraser, undo, redo, new page, Clear, chip), `src/ink.ts` (pen-only, `buttons !== 0 && pressure > 0`, clamp pressure to [0, 1], `getCoalescedEvents` and `pointerrawupdate` feature-detected, `desynchronized: true`, per-rAF batching, `delta_ms` from the first point, `pointercancel`/`pointerleave` -> COMMIT when at least 2 points and over 80 ms else CANCEL, local undo/redo redraw driven by STATE depths, highlighter drawn with simple alpha locally), `src/ws.ts` (subprotocol `solstream.v1` offered and required when echoed, backoff 1000 ms x 1.7 capped at 15 s, PING every 10 s, `bufferedAmount` policy of ARCHITECTURE 3.4, re-dial on `visibilitychange` and `online`, ring replay, ACK 1 -> no ink sent until ACK 0), `src/main.ts` wiring with the Start overlay (fullscreen + wake lock on tap), `?host=` override, the expanded chip card (Add to Home screen hint, `/daylight-ink.apk` link, the exact `chrome://flags` string from `/api/info` on a non-secure origin). Styles with tokens only, `touch-action: none` on the canvas, 1.5 px borders, no shadows.
2. `tests/fake-mac.mjs`: Node server on 127.0.0.1:4173 serving `dist/` statically plus `/api/info`, `/healthz`, and a `ws` WebSocket on `/ink` that decodes SolStream (shared decoder in `tests/solstream-node.mjs` or the compiled `build/node-tests/src/protocol.js`), answers HANDSHAKE with the golden `handshake_ack_ok` or `handshake_ack_pending` per a scenario selected by the page URL query (`?scenario=pending`), emits STATE sequences on request (`?scenario=prewarn`), records every received frame and exposes them at `GET /__frames` for the tests to assert. Replace the Playwright `webServer` command with `node tests/fake-mac.mjs`.
3. Specs: `tests/protocol.spec.ts` (encoder reproduces every `c2s` golden hex inside the browser context; `decodeServer` parses every `s2c` case), `tests/pen.spec.ts` (SPEC D3 verbatim, through the CDP helper already in `smoke.spec.ts`), `tests/app.spec.ts` (Start overlay, tools, toolbar actions produce the right opcodes at `/__frames`), `tests/state.spec.ts` (SPEC D4), `tests/reconnect.spec.ts` (SPEC D5, kill and restart the fake Mac's socket), `tests/secure.spec.ts` (SPEC D6, `page.addInitScript` stubbing `isSecureContext` to false). Keep `smoke.spec.ts` or fold it into `app.spec.ts`.
4. `public/icons/` (192 and 512 px PNG plus SVG, drawn from tokens), manifest `display: fullscreen`, `orientation: portrait`.
5. `docs/handoff/D-web.md`: owner text for the web pairing flow (SPEC 9.2) ending with the checklist; the device facts to collect (LOOSE_ENDS D3, D4, D8, D9) with the exact console lines the page logs; requests for the integrator (none expected).

Acceptance (CI): `web` job green: `npm run typecheck`, `npm run build`, `npm run test:unit`, `npx playwright test` with the six spec files; `dist/` has `index.html`, `manifest.webmanifest`, `assets/*`; `grep -n "touch-action: none" src/styles.css` hits. Reviewer-checkable: SPEC 16 D1 to D6.

---

## 8. Component E: Android app and overlay

Owns: `android/` except `android/app/src/test/resources/solstream-v1.json`, `android/gradle/wrapper/`, `android/gradlew*`; `docs/handoff/E-android.md`.

Consumes: `docs/PROTOCOL.md` and the golden manifest; the `--es host` and `--es pills` extras and the `appops`/`pm grant` commands F runs (SPEC 9.3, ARCHITECTURE 6 item 8); the `pillStripHeight` value from `/api/info` (default 96).

Order of work:
1. Dependencies (research-android-ink section 8, all verified): `androidx.graphics:graphics-core:1.0.4`, `com.squareup.okhttp3:okhttp:5.5.0`, `org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2`; no AppCompat, Material, Compose or lifecycle. Manifest permissions and components of research-android-ink section 9 (`android:exported` on every component with an intent filter, `OverlayService` with `foregroundServiceType="connectedDevice"`, optional `BootReceiver`).
2. `protocol/` is complete; keep it. `ink/`: `StrokeSession` (history-then-current, `delta_ms` from the first point, pressure normalisation for 0..1 and raw 0..4095, per-Choreographer-frame batching with `sendPerEvent` toggle, cancel -> STROKE_CANCEL and no COMMIT, undo and redo wait for STATE depths), `DryInkView` (Bitmap, `invalidate(Rect)`, `BlendMode.MULTIPLY` for the highlighter), `WetInkSurface` (`CanvasFrontBufferedRenderer` in `runCatching`, `setZOrderOnTop(true)`, TRANSLUCENT, `requestUnbufferedDispatch(SOURCE_CLASS_POINTER)` in `onAttachedToWindow`, fallback to the dry view), `InkCanvasLayout` (3:4 letterbox, canvas units 1200x1600). Android framework classes stay behind `InkSink`, `Resolver` and `Transport` interfaces so the JVM tests need no Robolectric.
3. `net/`: `Candidates` (mDNS results, `127.0.0.1:7788`, manual host, `--es host`; de-duplication; failure rotation), `Discovery` (NsdManager legacy path, one resolve at a time, `MulticastLock` when `SdkExtensions.getExtensionVersion(TIRAMISU) < 7`, try/catch on stop, `contains("_daylight-camera._tcp")`), `NoDelaySocketFactory`, `InkConnection` (OkHttp, `pingInterval(10, SECONDS)`, `Sec-WebSocket-Protocol: solstream.v1`, backoff 0.5 s doubling to 8 s with 20 percent jitter, `send()` false -> reconnect, `queueSize()` over 256 KiB -> thin points; singleton shared by the activity and the overlay with role `ink` or `overlay` and the same `clientId`).
4. `ui/`: `MainActivity` (toolbar, chip of SPEC 10, canvas, `--es host` handling, Start-like first screen only when onboarding is incomplete), `OnboardingActivity` (overlay permission with the Android 13 wording "tap Daylight Ink, switch on Allow display over other apps, press Back", notification permission request, manual host field with "Looking for your Mac... Enter its address if this takes long"), `SettingsActivity` (`frontBuffer`, `unbufferedInput`, `sendPerEvent`, `pillsAtBoot`, `pillsPosition`, manual host, Forget this Mac), `Chip`, `Toolbar`, `EdgeToEdge` (exists). `prefs/Prefs.kt` (SharedPreferences keys of SPEC 11 tablet side).
5. `overlay/`: `OverlayService` (research-android-ink 10.2 shape: foreground service with the channel, `createDisplayContext(display).createWindowContext(TYPE_APPLICATION_OVERLAY, null)`, one WRAP_CONTENT window, `FLAG_NOT_FOCUSABLE or FLAG_KEEP_SCREEN_ON`, gravity TOP or BOTTOM per `--es pills`, y inside the top 96 px strip), `PillsView` (Pin and Clear pills, labels from STATE: Pin / KEEP, LIVE dot), `BootReceiver` (only when `pillsAtBoot`).
6. JVM tests `app/src/test/kotlin/com/twelve/daylight/ink/`: `SolStreamTest` (exists), `StrokeSessionTest`, `CandidatesTest`, `DiscoveryQueueTest` (fake resolver, `FAILURE_ALREADY_ACTIVE` re-queue). Keep `org.json` on the test classpath as now.
7. `docs/handoff/E-android.md`: the owner's sideload and pairing text (SPEC 9.3) ending with the checklist; device facts to log at first run (LOOSE_ENDS D2, D3, D4, D11, D14, D15) with the exact logcat tags; requests for the integrator (an APK `versionCode` bump rule: `versionCode = GITHUB_RUN_NUMBER` through `-PdaylightVersionCode` is E's own change in `app/build.gradle.kts`; the make target passing it is an integrator request).

Acceptance (CI): `android` job green with the four test classes; the APK artifact exists and `aapt` is not needed (the manifest checks of SPEC E5 are asserted by a JVM test that parses `src/main/AndroidManifest.xml` as XML: every component with an intent filter has `android:exported`, `OverlayService` has `foregroundServiceType="connectedDevice"`, the five required permissions are present). Reviewer-checkable: SPEC 16 E1 to E6 (E6 partially on device).

---

## 9. Component F: mirror mode

Owns: `mac/Daylight/Sources/Mirror/`, `mac/DaylightKit/Sources/DaylightKit/Mirror/`, `mac/DaylightKit/Tests/DaylightKitTests/Mirror/`, `mac/DaylightTests/Mirror/`, `docs/handoff/F-mirror.md`.

Consumes: `MirrorFrameSource`, `MirrorControl`, `PipelineControl` (Contracts); `Settings`, `FailureText.Case`, `CropInsets`, `GovernorEvent`, `InkSource`, `UVRect`, `StudioLayout.CanvasOrientation` (A); the `Vendor/` directory URL from B. Never calls into `Sources/{App,Pipeline,Ink,Server,Camera}`.

Order of work:
1. Kit `Mirror/` (Foundation only), one file per type: `ScrcpyDemuxer` (big-endian: dummy byte, 64-byte device meta, codec id with 0 and 1 as `ScrcpyError`, 12-byte session packet with bit 7 of byte 0, 12-byte frame headers with bits 62 and 61 and the 61-bit PTS), `AnnexB` (3- and 4-byte start codes, trailing-zero trim, `parameterSets` picks NAL types 7 and 8, `toAVCC` writes 4-byte big-endian lengths, `containsIDR` is NAL type 5), `EvdevParser` (lines with and without the `/dev/input/eventX: ` prefix, partial lines, `[sec.usec]` stamps), `EvdevCapabilitiesParser` and `penNode` (`BTN_TOOL_PEN` plus `ABS_PRESSURE` and no `ABS_MT_SLOT`), `StylusContactMachine` (edges only on `SYN_REPORT`), `SideButtonGestures`, `AdbDevicesParser` (scan backwards from `transport_id:`, serials with spaces, `*` noise lines, all states, `parseHostVersion`), `CropInsets` (exists; add the two-session-size test). Tests in `Tests/DaylightKitTests/Mirror/` with text fixtures under `Tests/DaylightKitTests/Mirror/Fixtures/` (the integrator adds `resources: [.copy("Mirror/Fixtures")]` to `Package.swift` on request, or F keeps fixtures as Swift string literals, which needs no request). A synthetic scrcpy stream builder in the tests feeds the demuxer at chunk sizes 1, 7 and 1460.
2. H.264 fixture: generate once with the verified command `ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=size=320x240:rate=30 -frames:v 6 -c:v libx264 -profile:v baseline -pix_fmt yuv420p -g 3 -bf 0 -x264-params repeat-headers=1:annexb=1 -f h264 fixture.h264` (ffmpeg 6.1.1 with libx264 is on the development box; output 7846 bytes, NAL types 7, 8, 6, 5, 1, 1, 7, 8, 5, 1, 1). Commit it as `mac/DaylightTests/Mirror/Fixtures/testsrc-320x240-6f.h264` and add a `resources` entry for the `DaylightTests` target through a handoff request (XcodeGen `sources` with `buildPhase: resources` on the fixture folder). `AnnexBTests` on Linux can embed the SPS and PPS bytes of that file as literals.
3. Mac `Mirror/`: `AdbClient` (Foundation `Process` plus `Pipe` readability handlers, `ADB_SERVER_SOCKET` in the child environment for private-port mode) behind `protocol AdbRunning` (F-internal) so `FakeAdb` can replay canned outputs; `AdbServerPolicy` (probe `127.0.0.1:5037` with `000Chost:version`, never `kill-server`), `DeviceTracker` (`host:track-devices` raw socket with the `devices -l` 2 s fallback), `ScrcpySession` (exact argument list of SPEC F2, dummy byte with 100 x 100 ms retries, forward removed after connect, `terminate()` on stop, `[server] ERROR:` lines -> `scrcpyServerFailed`), `H264Decoder` (SPEC F3 and ARCHITECTURE 6 item 5, per-access-unit block buffer that owns its memory), `MirrorSource` (slot, `CropInsets.uv` at render time, orientation from the session size), `StylusWatcher` (`getevent -pl` enumeration, `getevent -lt /dev/input/eventN`, backoff 0.5 s doubling to 8 s, `penContact(down: false)` on EOF, 30 s side-button sanity -> `noSideButtonEvents`), `UsbOnboarding` (SPEC 9.2 step 1 and 9.3 step 1 command lists), `WifiMirror` (SPEC D42), `MirrorController` (the `MirrorControl` facade; owns `mirror.queue`, `stylus.queue`, `adb.queue`; the only F type with a public initialiser used by B).
4. Tests `DaylightTests/Mirror/`: `H264DecoderTests` (format description from the fixture's SPS/PPS; decode the six access units of the fixture synchronously and assert six BGRA 320x240 IOSurface-backed frames in PTS order; a second SPS triggers the recreate path; the test is `XCTSkip`ped if `VTDecompressionSessionCreate` returns an error code that means no hardware or software decoder on the runner, and the handoff file records what the runner did), `CropInsetsRuntimeTests` (UV for 1200x1600, 960x1280 and 1600x1200 sessions select the same screen region), `AdbServerPolicyTests` and `DeviceTrackerTests` with `FakeAdb`, `ScrcpySessionTests` (argument list equality against SPEC F2, dummy-byte retry count), `StylusWatcherTests` (fixture getevent transcript through `FakeAdb` -> governor events in order).
5. `docs/handoff/F-mirror.md`: the owner's mirror onboarding text (SPEC 9.4) ending with the checklist; the device facts F logs (LOOSE_ENDS D1, D2, D5, D6, D10, D12, D13, D15) with the exact log lines; COMPARE.md skeleton (latency columns per source); requests for the integrator (fixture resources, `Package.swift` resources if used).

Acceptance (CI): `kit-linux` green with the eight Kit Mirror test files; `make mac-test` green with the six DaylightTests Mirror files; `grep -rn "^import" mac/DaylightKit/Sources/DaylightKit/Mirror` shows only Foundation. Reviewer-checkable: SPEC 16 F1 to F6 (F7 on the owner's device).

---

## 10. Mock and stub strategy (how everything runs with no extension, no camera, no tablet)

| Layer | Stand-in | Owner | Where |
|---|---|---|---|
| Time | `ManualClock`; the governor takes `now` as a parameter | A | Kit tests |
| Virtual camera | `PreviewOnlySink` (shipping fallback on unsigned builds); `FakeSink` (records pushes); `QueueSink` over a real `CMSimpleQueue` capacity 1 | C ships `PreviewOnlySink`; B owns `FakeSink`; C owns `QueueSink` | `Sources/Camera/`, `DaylightTests/Pipeline/Fakes/`, `DaylightTests/Camera/` |
| Webcam | `FakeCapture: CaptureSource` (static IOSurface at 30 Hz, or a gradient for pixel probes) | B | `DaylightTests/Pipeline/Fakes/` |
| Tablet ink | the Mac's own `test`-role client in `--self-test` (`URLSessionWebSocketTask`), `WebServerLoopbackTests`, golden bytes fed straight into `InkRouter.handle` | B | `Sources/App/SelfTest.swift`, `DaylightTests/{Server,Ink}/` |
| Mac (for the web page) | `tests/fake-mac.mjs` (static dist, `/api/info`, `/ink` with scripted ACK and STATE, `/__frames` recorder) | D | `web/tests/` |
| Mac (for the APK) | none at runtime (the Mac is real or absent); `Transport` and `Resolver` fakes in JVM tests | E | `android/app/src/test/` |
| Mirror video | `FakeMirrorSource: MirrorFrameSource` (static BGRA buffer, fixed uv); synthetic scrcpy byte stream; the H.264 fixture | B owns the fake; F owns the streams | `DaylightTests/Pipeline/Fakes/`, Kit Mirror tests, `DaylightTests/Mirror/Fixtures/` |
| adb and the DC-1 | `FakeAdb: AdbRunning` replaying `devices -l`, `getevent -pl`, `getevent -lt` transcripts and a scrcpy socket from the synthetic stream | F | `DaylightTests/Mirror/` |
| Signed build | never faked: `DaylightBuildSigned` false selects `PreviewOnlySink` and opens the preview window (SPEC D19, 13.1 step 0) | B, integrator | `project.yml`, `Sources/App/` |
| Owner device facts | logged at first run into Diagnostics; the owner pastes them into the checklist | all | `docs/TESTING-CHECKLIST.md` (integrator, M6) |

The preview window is the end-to-end proof on an unsigned build: webcam (or `FakeCapture` under `--self-test`) -> compositor -> `PreviewOnlySink` plus `PreviewWindow.display`. The same frames go to `CMIOSinkClient` on a signed build; nothing else changes.

---

## 11. UNVERIFIED facts an implementer needs, by component (each has a fallback; keep the list in sync with LOOSE_ENDS B to E)

| Component | Item | Fallback already decided |
|---|---|---|
| A | none (pure Swift; `Bundle.module` and Swift 6.4 on Linux are verified by run 37104560769) | |
| B | macOS `AVCaptureVideoDataOutput` BGRA buffers are IOSurface-backed and 1920x1080 for the owner's webcam (E4); explicit `activeFormat` versus the 1080p preset on macOS (E5); `synchronizationClock` equals the host clock (E6); AVFoundation removes a disconnected input itself (E7); Metal validation storage-mode rule for IOSurface textures on macOS 14/15 (E8); CGBitmapContext row order and the y-flip (E9); frozen frame versus placeholder during the idle restart (E11); frame reuse accepted by CMIO (E12); System Settings URL for the Camera Extensions pane and `isTemplate` (E13); `.nonactivatingPanel` behaviour in an LSUIElement app (E14); APK MIME type Chrome needs (E15); hand-written RFC 6455 upgrade accepted by Chrome and OkHttp (E16, tested by `WebServerLoopbackTests` with `URLSessionWebSocketTask` only); Local Network prompt on macOS 15 for a Bonjour listener (C4); hosted XCTest bundle on a headless runner (B13); `OSAllocatedUnfairLock` is macOS 13+ (fine on 14.0, not re-read) | first-frame facts and the one logged fallback copy; preset plus frame-duration pinning; restamp with the host clock; remove the input explicitly; leave storage mode at default; `InkRasterizerTests` dot test; cached frame pushed on restart; `frameReuse` off; text path shown; standard AppKit; `Content-Disposition: attachment`; fallback B (second listener with `NWProtocolWebSocket`) needs owner sign-off; keys included regardless; plan B non-hosted bundle; `NSLock` if it fails to compile |
| C | `consumeSampleBuffer` completion semantics on an empty queue (E1); which `kCMIOStreamPropertyDirection` value is the sink (E2); `CMIOObjectAddPropertyListenerBlock` for a custom property (E3); `SKIP_INSTALL` default for system-extension targets (B7); re-signing the nested `Vendor/adb` for notarization (B6); `xcodebuild -help` export keys (B8); the exact Camera Extensions approval pane URL (E13) | 90 Hz timer default; both directions logged, index 1 fallback; 1 Hz poll always on; `SKIP_INSTALL YES` set explicitly; explicit `codesign` of `Vendor/adb` in `mac-release.sh` (integrator); saved into `xcodebuild-logs`; text path |
| D | DC-1 Chrome version, `devicePixelRatio`, viewport (D8); digitizer touch suppression while the pen is in range and PEN `pointercancel` (D9); side button `button`/`buttons` values on the DC-1 (D4); pressure above 1.0 (D3); legacy A2HS shortcut honouring `display: fullscreen` on a non-secure origin (D8); `<mac>.local` resolution (D8); Chrome 142 removing `pointerrawupdate` on non-secure origins (noted in research F14) | DPR-independent canvas units; commit on `pointercancel` after 2 points and 80 ms; side button never bound; clamp pressure; Fullscreen API tap always offered; numeric URLs first; feature detection |
| E | pressure range 0..1 or raw 0..4095 (D3); `BUTTON_STYLUS_PRIMARY` or `SECONDARY` (D4); Tethering T extension version (D11); `onServiceFound` serviceType dots; OkHttp callback thread; overlay pills visible inside the scrcpy mirror and where (D5); `am start-foreground-service` from the shell bypassing background limits and `appops set` flipping `canDrawOverlays` (D15); front buffer on graphics-core 1.0.4 (D14); `findPointerIndex` and `WindowInsets.Type` API levels (old APIs) | handle both ranges; accept both buttons and log; branch at runtime; `contains()`; post to main; `pillStripHeight` setting both sides; manual onboarding fallback; `runCatching` fallback to the dry view |
| F | Wacom evdev node name, axes, pressure max, `BTN_STYLUS` reporting on SolOS (D1); `Build.MODEL` (D2); adb size and `lipo -archs` (B2, filled by P0.4's log); `NOTICE.txt` path in the zip (B2); 7-day adb authorization expiry and the "Disable adb authorization timeout" toggle on SolOS (D6); `adb tcpip 5555` surviving reboot (C2); two adb servers and one USB device (C5); `host:track-devices-l` and `adb mdns` wording in adb 37 (F10); `/proc/bus/input/devices` readability under SELinux; getevent latency and exit-on-kill (D12); B-frames or PTS reordering from the DC-1 encoder (D13); `stay_on_while_plugged_in` value (D7); which app handles `http://` VIEW intents (D10); whether the macos-15 runner can create a `VTDecompressionSession` for the fixture | runtime enumeration with `getevent -pl` and rows 28 and 28b; label from the device meta; logged by P0.4; `fetch-tools.sh` warns; onboarding text and LOOSE_ENDS; `WifiMirror` re-runs `tcpip` after every USB session; private-port mode and row 24; `AdbDevicesParser` on `devices -l` only; parsers tolerate the prefix; measured on device; decode order assumed, sorted by PTS defensively; A13 is off by default; the first `am start` run tells; `XCTSkip` with a logged reason |

---

## 12. Integrator rules and merge order

1. Merge order when two components are both green and waiting: A, then C, then B, then F, then D and E (D and E never block anyone). A's section 3.5 fixes are the only hard dependency and land first; the integrator pings B when they are in.
2. CI steps are added to the workflows only when the thing they run exists: `mac-test` in P0.2 (placeholder test), `mac-smoke` after B's first merge, `embed-apk` in P0.5 (the script tolerates a missing APK).
3. Golden regeneration: when A changes `gen_golden.py`, the integrator runs `make golden` and commits the three copies in the same push as A's change (A's commit alone turns `golden-check` red; the integrator closes the gap within the day). D and E update their case counts and encoder mappings in their next push.
4. A red CI run caused by a cross-component mismatch (B compiled against an A signature that A then changed) is fixed by the consumer, not by reverting the producer, unless the producer broke a frozen contract.
5. Handoff files are folded into `docs/{SETUP,SIGNING,COMPARE,TESTING-CHECKLIST,PERFORMANCE}.md` and `docs/LOOSE_ENDS.md` at M6 by the integrator; components never edit those files. Every user-facing document ends with the ADHD-friendly checklist (atomic steps, time estimates, emoji anchors), and all of them follow the writing rules.
6. The integrator keeps ARCHITECTURE section 18 current: every build-system fact learned from CI (adb size, directions logged, hosted test behaviour) is recorded there or in LOOSE_ENDS the same day.
7. `VERSION` stays `0.1.0` until M6; the `v0.1.0` tag is the first notarization (needs the owner's secrets, LOOSE_ENDS A1).
8. M7 (subtree split) happens only after the owner has run the checklist on a notarized build.
9. The integrator never writes component code. If a component is stuck, the integrator adjusts the contract or the build, not the component's files.

---

## 13. Open gaps after this review (also in LOOSE_ENDS)

- LICENSE for the public repo (owner choice, A14): settled on 2026-10-03, Apache-2.0 (`LICENSE`).
- Hosted XCTest bundle behaviour on the headless runner (B13), decided by the pre-flight run.
- Tag-triggered notarization path (B12), fixed by P0.6.
- `Vendor/` binaries not yet fetched in CI (B14) and the APK not yet embedded (B15), fixed by P0.4 and P0.5.
- Whether the macos-15 runner decodes the H.264 fixture (F, section 9 step 4), decided by F's first `mac-test` run.
- Everything in `docs/LOOSE_ENDS.md` section D needs the DC-1 in the owner's hands; nothing in sections 4 to 9 depends on those answers except mirror-mode polish.
