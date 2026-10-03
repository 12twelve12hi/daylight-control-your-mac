# Component B handoff: Daylight app core

Owner paths: `mac/Daylight/Sources/{App,Onboarding,Settings,Pipeline,Ink,Server}/`, `mac/DaylightTests/{Pipeline,Server,Ink,App}/`, this file. The handoff README names the B file `B-app.md`; the orchestrator's task named `b-daylight-app-core.md`. This is the only copy.

Writing rules apply: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

---

## 1. What was built

Everything in IMPLEMENTATION-PLAN section 5, against the frozen contracts (`VirtualCameraSink`, `MirrorFrameSource`, `PipelineControl`, `MirrorControl`) and the corrected Kit of the A handoff.

### 1.1 Pipeline (`Sources/Pipeline/`)

| File | What it does |
|---|---|
| `LatestFrameSlot.swift` | One-deep camera to render hand-off under `OSAllocatedUnfairLock`; `take()` peeks (keeps the frame) so a 30 Hz render loop re-uses a 30 fps frame when the clocks interleave. |
| `OutputPool.swift` | `CVPixelBufferPool` 1920x1080 BGRA, IOSurface and Metal compatible, minimum 3, allocation threshold 3, `DispatchSemaphore(3)` with `wait(timeout: .now())`: `acquire()` never blocks and never hands out a fourth buffer. |
| `FrameClock.swift` | Strict `DispatchSourceTimer` at 30 Hz with 1 ms leeway on the render queue; ticks pass `CACurrentMediaTime()`. |
| `CanvasSurfaces.swift` | The two 1200x1600 premultiplied BGRA IOSurfaces (ink, highlighter) plus their Metal textures when a device exists (storage mode left at the macOS default). Works without Metal so the rasterizer and the self-test run on a runner with no GPU. |
| `InkRasterizer.swift` | CoreGraphics into the IOSurfaces: one `IOSurfaceLock` per op, cached `CGContext` per layer (`byteOrder32Little | premultipliedFirst`, y-flipped CTM), per-segment widths `base * (0.55 + 0.9 * pressure)`, round caps and joins, dot rule as a filled disc, dirty-rect redraw for erase, undo and cancel. |
| `Compositor.swift` + `Shaders.metal` | One Metal pass: SurfaceCream clear, presenter quad (crop, no scaling, `CVMetalTextureCache`), the studio panel scissored to `canvasClip` (cream, canvas quad with the SPEC 6.6 fragment math or the mirror picture, 1 px BorderSubtle lines), the 2 px divider with alpha = s and the amber breath colour. Non-BGRA cameras are converted once per frame through `CIContext` and logged once (row 5). |
| `FrameFeeder.swift` | B-internal: `CMSampleBufferCreateReadyWithImageBuffer` with a host-clock PTS that is strictly increasing and one cached format description per (w, h, fourcc), pushed through the `VirtualCameraSink` contract. Component C's `SinkFeeder` does the same job; the pipeline only ever calls `sink.push(CMSampleBuffer)`. |
| `WebcamCapture.swift` | `AVCaptureSession` with the 1080p preset, 30 fps pinned when the active format allows it, BGRA `videoSettings`, `alwaysDiscardsLateVideoFrames`, the macOS 14 device types, disconnect and reconnect handling; behind `protocol CaptureSource` so `FakeCapture` (DaylightTests) conforms too. |
| `FramePipeline.swift` | Implements `PipelineControl`. Governor under `Locked<EngageGovernor>`; passthrough forwards the camera buffer with zero pixel work when it is IOSurface-backed 1920x1080 BGRA (`stats.passthroughZeroCopy`), otherwise one composed pass per frame logged once; 30 Hz composition while the governor is not in PASSTHROUGH or a hold mode is active; frame 0 rendered in the same call that starts the clock; the idle rule of SPEC D32 (`viewers > 0 || previewVisible || !sinkConnected`, 60 s hysteresis, cached frame or cream card pushed on restart); STATE cadence of SPEC D47 (immediate on a governor change, 10 Hz while ENGAGING, RETURNING or pre-warning, 1 Hz LIVE, silent in PASSTHROUGH); `--latency-probe`; `PipelineStats`. |
| `Telemetry.swift` | `OSSignposter` intervals `capture`, `composite`, `sink.push`; the `--perf-log` line (`perf mode= fps= dropped= cpu_ms= gpu_ms= inflight= zerocopy= capture= viewers=`); the last 200 log lines for Diagnostics. |
| `PreviewWindow.swift` | `AVSampleBufferDisplayLayer` with `kCMSampleAttachmentKey_DisplayImmediately`; consumes frames only while visible; visibility feeds the idle rule; the cream "No camera found" overlay (row 4). |

### 1.2 Server (`Sources/Server/`)

`WebServer` is one `NWListener` (`NWParameters(tls: nil, tcp:)` with `noDelay`, `allowLocalEndpointReuse`, `serviceClass .interactiveVideo`), ports 7788...7799 tried in order (row 16), Bonjour `_daylight-camera._tcp` with TXT `v=1 ws=/ink port=<n>` set before `start`, `serviceRegistrationUpdateHandler` logging `.add` (row 17). Per connection: `HTTPRequest.parse`, `/healthz`, `/api/info` (`"app":"daylight"`), `/daylight-ink.apk` (`application/vnd.android.package-archive`, attachment), static files from `Resources/web` (`WebRootPath.resolve`, `MIME.type` then `UTType`, `/assets/*` immutable), and the `/ink` upgrade: `Sec-WebSocket-Protocol: solstream.v1` echoed when offered, `WebSocketFrame.parse` loop with `WebSocketMessageAssembler`, 2 MiB cap (1009), 5 s handshake deadline and 30 s idle (1002, 1001), close codes of PROTOCOL 1 and 9. `InkConnection` wraps an `InkTransport` (the NWConnection in the app, `FakeTransport` in tests). `LocalAddresses` lists IPv4 through `getifaddrs`, Tailscale (`utun*` in 100.64.0.0/10) first. Under `--self-test` and in tests the listener binds 127.0.0.1 only and advertises nothing.

### 1.3 Ink (`Sources/Ink/`)

`InkRouter` (ink.queue): decode with `Codec.decodeLenient`, the PROTOCOL 9 validation table, the allow gate of PROTOCOL 8 (allowed record, loopback with `trustLoopback`, overlay reusing the ink clientId, pending with ACK 1 and STATE bit2 clear, "Not now" with ACK 2 and 1008), the active-source rule (newest allowed client of the role matching the ink source; `test` and `overlay` always pass bit3), `StrokeStore` plus `InkRasterizer`, the PROTOCOL 13 governor events, STATE broadcast with the page fields and per-client bits, sessions (first stroke after launch or a 10-minute gap), saving on every SPEC 12 trigger with `StrokeStore.isDirty` as the second gate, autosave timer, `saveOnQuit(timeout: 2)`. `ClientRegistry` is `clients.json` with `seenOverUSB`. `SessionSaver` writes `page-NN.png` and `page-NN.json` on io.queue (first write unique, later writes of the same page overwrite, `forgetPage` after Clear and New page picks `-2`), `saveMirror` writes `mirror-<HH-mm-ss>.png`. `PNGExporter` renders from the model (PaperBg, highlighter multiplied, ink normal) through ImageIO.

### 1.4 App, Onboarding, Settings

`main.swift` (AppKit lifecycle, `--self-test` exits before any UI), `AppDelegate` (all wiring; skips the camera and the network inside the hosted test bundle), `AppModel` (main-thread mirror at 2 Hz, actions of SPEC 7), `MenuBar` (status item, Ink source and Hold submenus, Keep whiteboard, Clear, Camera, Whiteboard now, the address lines, the pending "Allow <label>" item, Preview, Settings, Diagnostics, Setup again, Quit; the icon becomes `video.slash` without a camera), `Hotkeys` (Carbon `RegisterEventHotKey`, defaults of SPEC 14, conflicts reported as "Already used by another app"), `Diagnostics` (SPEC 13.2 text, window, Copy diagnostics), `SelfTest` (SPEC B1), `LaunchArguments`, `UnwiredSink` (see section 5). `Onboarding/`: `OnboardingSteps` (SPEC 13.1 as a pure state machine with `FailureText` rows), `OnboardingWindow` (SwiftUI in an `NSWindow`), `AllowClientPanel` (`NSPanel` with `.nonactivatingPanel`, floating, top right, 60 s auto-dismiss, Allow / Not now). `Settings/`: `SettingsStore` (one JSON blob under `com.twelve.daylight.settings.v1`, `SMAppService` read live), `SettingsWindow` (General, Hotkeys, Network with Forget, Mirror with the crop view, Saving, Advanced, Diagnostics), `HotkeyRecorder`, `MirrorCropView` (four draggable edges over the latest mirror frame).

### 1.5 Tests (`mac/DaylightTests/`)

| Folder | Files | Proves |
|---|---|---|
| `Pipeline/Fakes/` | `FakeSink`, `FakeCapture`, `FakeMirrorSource` | IMPLEMENTATION-PLAN section 10 stand-ins |
| `Pipeline/` | `PipelineUnitTests` (slot, pool never hands out a fourth buffer, clock about 30 ticks per second, feeder PTS and format description, perf line format), `InkRasterizerTests` (dot in the right rows, segments, pressure width 5.5 and 14.5, erase leaves the neighbour, undo and redo, highlighter layer only, eraser tool never drawn), `CompositorTests` (SPEC 6 probes at s = 0, 0.5, 1, landscape, Whiteboard Only, amber breath; `XCTSkip` without Metal), `PipelineSmokeTests` (25+ zero-copy pushes per second, engage to LIVE with composed frames, cadence constants, idle rule with a shortened hysteresis and the cached frame first after restart, preview counts as a viewer, mirror composition, 300 frames measured) | SPEC B3, B4, D32, D34, D47 |
| `Server/` | `WebServerLoopbackTests` (golden round trip over the real listener with `URLSessionWebSocketTask`: ACK 0 bytes 16...31, subprotocol echoed, STATE bit2 after ACK, governor 1 after the stroke, ink alpha, undo, PONG; 2 MiB frame closes 1009; pending branch with loopback trust off; HTTP routes and cache headers), `ServerUnitTests` (ApiRoutes, StaticFiles traversal and types, LocalAddresses order, InkConnection framing) | SPEC B2, PROTOCOL 1 and 9 |
| `Ink/` | `InkRouterTests` (loopback allowed and `seenOverUSB`, pending until Allow, Not now, remembered client, overlay reuse, bad name ACK 3, handshake first, golden stroke to store and governor, finger and pressure 0 dropped, active-source rule, disconnect commits and never changes state, Clear saves once then clears, page change, control mapping, validation table, PING, receiveState), `SessionSaverTests` (schema, autosave overwrites, `-2` after forget, PNG, mirror name), `ClientRegistryTests` | SPEC B7, D37, PROTOCOL 8 and 13 |
| `App/` | `AppUnitTests` (launch arguments, hotkey defaults and ids, recorder modifiers, onboarding rows for every extension state, 35 failure cases and the exact rows B shows, SPEC timeouts as constants, the Allow panel's style mask, the diagnostics text) | SPEC B5 (panel part), B6, B8 (defaults part) |

---

## 2. How to test on the real device (atomic steps)

Unsigned build (what CI produces today): download `Daylight-unsigned.zip`, unzip, right-click Daylight.app > Open.

1. The menu bar shows a camera icon. The preview window opens by itself (unsigned build, SPEC D19) and shows your webcam within a second. Expect the "Welcome to Daylight" window with step 0 reading "This is an unsigned test build..." and step 1 asking for camera access the first time.
2. Menu bar > the first "Open http://...:7788 on your Daylight" line is the address to type on the tablet; clicking it copies the URL. Tailscale addresses come first.
3. On the DC-1, open that address in Chrome, tap Start. The Mac shows the Allow panel at the top right (Zoom keeps focus); the menu bar also lists "Allow <tablet>". Click Allow. The chip on the tablet reads "Camera".
4. Touch the pen to the glass: the preview slides into Studio Split in about a quarter second, ink appears as you write, the chip reads "LIVE".
5. Lift the pen and wait: at 85 s the divider breathes amber; at 90 s the picture slides back and `~/Documents/Daylight Camera/<date>/<HH-mm-ss>/page-01.png` plus `page-01.json` appear.
6. Press Ctrl+Opt+Cmd+K: the menu shows "Keep whiteboard" ticked and the chip reads KEEP WHITEBOARD. Ctrl+Opt+Cmd+C clears (saves first), Ctrl+Opt+Cmd+Esc returns to the camera, Ctrl+Opt+Cmd+D and W bring the board up without drawing; the same hotkey again returns.
7. Quit Zoom (or close the preview on a signed build): with the extension connected the camera LED goes off 60 s later; Diagnostics shows "Webcam capture is paused because no app is viewing Daylight Camera (LED off)...". Open a call again: the picture is back within a second.
8. Menu bar > Diagnostics... > Copy diagnostics, and paste into the testing checklist.
9. Terminal: `Daylight.app/Contents/MacOS/Daylight --self-test --perf-log` prints every probe line and `self-test: PASS`.
10. Unplug the webcam: the icon becomes a camera with a slash and the preview shows "No camera found"; plug it back: capture resumes.

Rows of SPEC 13.3 the owner triggers on purpose with this component: 1 (open from Downloads), 3 (deny camera access once), 4 (unplug the webcam), 16 (`nc -l 7788` before launching Daylight: the menu says "Port 7788 is in use. Daylight is using 7789."), 18 (wait 60 s with no tablet), 19 (let the Allow panel time out, then use the menu item), 31 (make `~/Documents/Daylight Camera` read-only), 33 (close every viewer for 60 s).

---

## 3. Device facts and CI facts

- Filled in after the first green mac run of this component (run ids below).
- The hosted DaylightTests bundle: `AppDelegate.isUnderTest` detects `XCTestConfigurationFilePath` or the loaded `XCTestCase` class and starts neither the camera nor the listener in the host app; the tests build their own pipelines and servers on 127.0.0.1.

---

## 4. UNVERIFIED items shipped behind a fallback

| Fact | Fallback | How the owner confirms |
|---|---|---|
| `AVCaptureVideoDataOutput` BGRA buffers are IOSurface-backed 1920x1080 for the owner's webcam (LOOSE_ENDS E4) | first-frame facts logged once; `passthroughZeroCopy` false switches to one composed pass per frame (row 5) | Diagnostics "first frame: ... zeroCopy=true" |
| `AVSampleBufferDisplayLayer.enqueue` with `kCMSampleAttachmentKey_DisplayImmediately` shows frames without a control timebase (not in a research note) | the layer is flushed when its status is `.failed`; the preview is a convenience, the camera path does not depend on it | the preview window shows the webcam |
| `OSAllocatedUnfairLock(uncheckedState:)` and `withLockUnchecked` compile on Xcode 16.4 (plan: `NSLock` if not) | one-file change to `NSLock` | CI mac job |
| `CVMetalTextureCache` with `kCVMetalTextureUsage` renderTarget plus shaderRead produces a render target texture for pool buffers | `CompositorTests` and the self-test render probes fail loudly | self-test render lines |
| Metal validation and `MTLStorageMode` for IOSurface textures on macOS 14/15 (E8) | storage mode left at the default | `InkRasterizerTests` and the render probes |
| `CGBitmapContext` row order and the y-flip (E9) | `InkRasterizerTests.testDotLandsAtItsCanvasCoordinatesInTheFirstRows` | CI |
| `NSPanel` `.nonactivatingPanel` keeps Zoom focused in an LSUIElement app (E14) | standard AppKit; the menu item mirrors the prompt | checklist step 3 |
| `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` opens the Camera Extensions pane (E13) | the text path is in the sentence; a second URL and plain text are the fallbacks | onboarding step 2 button |
| URLSessionWebSocketTask and Chrome accept the hand-written upgrade (E16) | `WebServerLoopbackTests` with `URLSessionWebSocketTask`; Chrome on the DC-1 is the first real client | checklist step 3 |
| `NWListener` reports a busy port as `.failed` or `.waiting` | both move to the next port | row 16 test on the Mac |
| Highlighter overlap: consecutive round-capped segments at 50 percent alpha darken where caps overlap (LOOSE_ENDS F7 family) | visible only on the Mac picture; the tablet draws its own | look at a highlighter stroke in the preview |
| PAGE_CHANGE: the Mac numbers pages itself (`pageIndex + 1`) and ignores the client's `page_index` so file names never collide | STATE `page_index` tells the client the Mac's number | `page-02` after New page |

---

## 5. Requests for the integrator

1. Add `make mac-smoke` after `make mac-test` in both workflows once the first mac run of this component is green (LOOSE_ENDS B17): `--self-test` exists, binds 127.0.0.1 only, never calls `requestAccess`, exits 0 on the runner with the render probes skipped when `MTLCreateSystemDefaultDevice()` is nil. Not yet applied (Integrator-sync-2, 99366ee): the first mac run with B (37113456015) is red on four B tests, recorded with diagnoses in LOOSE_ENDS B19; the step joins both workflows in the sync pass after the first green mac job that contains B (B17). The runner does have a Metal device (B5), so the render probes will run there too.
2. When component C lands: in `AppDelegate.makeSink()` replace `UnwiredSink()` with `signed ? CMIOSinkClient(deviceUUID:sinkUUID:queue:) : PreviewOnlySink()` (UUIDs from `Bundle.main.object(forInfoDictionaryKey:)`), construct `ExtensionInstaller` and `ViewerWatcher` there, map `ExtensionInstaller.Status` onto `ExtensionState` in `sinkStatusChanged`, and delete `UnwiredSink.swift`. B's `FrameFeeder` can stay or be swapped for `SinkFeeder` behind the same `sink.push` call. I will do this myself if C lands while I am still active. Noted in 99366ee: the seam is recorded in ARCHITECTURE section 18 ("B's `AppDelegate` wiring") for C's integration pass.
3. When component F lands: in `AppDelegate.applicationDidFinishLaunching` construct `MirrorController(settings:vendorDirectory:pipeline:queue:)` with `vendorDirectory = Bundle.main.resourceURL!.appendingPathComponent("Vendor")`, assign it to `mirror`, call `pipeline.setMirrorSource(mirror.source)`, forward `mirror.source.onGovernorEvent` to `pipeline.post`, and `mirror.start()` when the ink source is mirror. The onboarding "Set up over USB" button and the Settings crop view already read through `MirrorControl`. Noted in 99366ee: same ARCHITECTURE section 18 row, for F's integration pass.
4. No plist, entitlement or `project.yml` change is needed: `Shaders.metal` compiles as a source of the `Daylight` target (XcodeGen treats `.metal` as a source file); the web root is `Resources/web`, the APK `Resources/DaylightInk.apk`, the vendor folder `Resources/Vendor` as the scaffold defines them. Confirmed in 99366ee: `project.yml`, `Package.swift` and the workflows are unchanged for B; `make mac-debug` built the whole app in run 37113456015.
5. The handoff README's file name for B is `B-app.md`; this file is `b-daylight-app-core.md` per the task text. Rename or link as you prefer. Applied in 99366ee: the README table now names `b-daylight-app-core.md`; this file keeps its name. B's UNVERIFIED items of section 4 are LOOSE_ENDS E19 to E23 (E20 and E21 verified by the first mac run); the owner-facing text of section 7 is folded at M6 (plan rule 5).

---

## 6. Red CI runs caused by someone else's files

None at the time of writing.

---

## 7. Text for the owner-facing documents

### SETUP.md (Mac first run)

Open Daylight once from your Applications folder. The menu bar gets a camera icon. The first run shows "Welcome to Daylight": allow camera access, install the camera extension (signed builds only; approve it in System Settings > General > Login Items & Extensions > Camera Extensions, then click Check again), and type the address from the menu bar into Chrome on your Daylight. Click Allow when the Mac asks "Allow '<your tablet>' to draw on Daylight Camera?". That is the whole setup; from now on Daylight starts at login (toggle in the Welcome window or Settings) and the tablet reconnects by itself.

Menu bar items: the address lines (click to copy), Ink source (Web whiteboard, Daylight Ink app, Mirror the tablet), Hold (Auto, Camera, Studio Split, Whiteboard Only), Keep whiteboard, Clear, Camera, Whiteboard now, Preview window, Settings, Diagnostics, Setup again, Quit.

Hotkeys (change them in Settings > Hotkeys): Ctrl+Opt+Cmd+W Whiteboard Only, Ctrl+Opt+Cmd+D Studio Split, Ctrl+Opt+Cmd+K Keep whiteboard, Ctrl+Opt+Cmd+C Clear, Ctrl+Opt+Cmd+Esc Camera. Pressing the active layout hotkey again returns to the camera.

Where pages go: `~/Documents/Daylight Camera/<yyyy-MM-dd>/<HH-mm-ss>/page-01.png` and `page-01.json`; mirror sessions write `mirror-<HH-mm-ss>.png`.

### COMPARE.md (what B measures for every source)

`Daylight --perf-log` prints one line per second: `perf mode=<passthrough|engaging|split|whiteboard|returning> fps=<pushed per second> dropped=<n> cpu_ms=<encode time per frame> gpu_ms=<GPU time per frame> inflight=<pool buffers busy> zerocopy=<true when passthrough forwards the camera buffer untouched> capture=<running|idle> viewers=<n>`. `Daylight --latency-probe` adds `engage probe: STROKE_START to first moved frame <ms>` for the first engage of each session; the same line works for web and native (mirror engages through `penContact` and reads its own probe from F).

### TESTING-CHECKLIST.md rows (about 12 minutes)

- 🟢 Launch from Downloads: "Move Daylight to your Applications folder" with Reveal in Finder (30 s)
- 🟢 First run: Welcome window, camera access, the address line in the menu bar (1 min)
- 📋 Tablet connects over Wi-Fi: Allow panel at the top right, Zoom keeps focus, "Allow <tablet>" also in the menu (1 min)
- ✍️ Pen touch slides to Studio Split in the preview; ink appears live (30 s)
- ⏱️ `nc -l 7788` then launch: menu says "Port 7788 is in use. Daylight is using 7789." (1 min)
- 🟡 Wait 60 s with no tablet: "Nobody has connected yet. Same Wi-Fi?..." in the menu (1 min)
- 🟣 Clear with ink: one `page-01.png` plus `page-01.json`; Clear again: nothing new (1 min)
- 🟣 Make `~/Documents/Daylight Camera` read-only, draw, Clear: menu shows "Could not save the whiteboard: ..." (1 min)
- ⏱️ Close every viewer for 60 s: LED off, Diagnostics row 33 text; open Zoom: picture back within a second (2 min)
- 🟢 Unplug the webcam: slashed icon and "No camera found"; replug: picture back (1 min)
- 📋 Diagnostics > Copy diagnostics pastes the full report (30 s)
- 📋 `Daylight --self-test --perf-log` ends with `self-test: PASS` (1 min)
