# Handoff: VP "too small" (phase 4, 2026-10-04)

Domain: the whiteboard is unreadable in a small call tile. Research and the ranked proposal: `docs/product/TOO-SMALL.md`. Owner run: `docs/OWNER-NEXT-STEPS.md` step 8c. Open items: `docs/LOOSE_ENDS.md` section TS. Status: `docs/STATUS.md` section 15.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming.

## What shipped

| Commit | What | Proved by |
|---|---|---|
| ee69a2c | DaylightKit `Layout/FollowRegion.swift`: `FollowRegion` (fit, clamp, quad, helpers) and `FollowCamera` (hysteresis FP3 to FP7, springs FP8), tests `Layout/FollowRegionTests.swift` | kit-linux run 37179989574 green; mac `kit-test` |
| 8caff9d | `mac/Daylight/Sources/Share/` (share window, renderer, settings, Settings tab view, menu, self-test probes), tests `mac/DaylightTests/Share/ShareTests.swift` | mac job `mac-test`, `mac-smoke` |
| this docs commit | TOO-SMALL.md, this handoff, OWNER-NEXT-STEPS step 8c, STATUS 15, LOOSE_ENDS TS | the docs-to-UI step of `mac-ui-test` reads step 8c |

Numbers with tests: FP1 to FP9 (`FollowRegionTests.testConstants` and the behaviour tests), SH1 and SH2 (`ShareWindowTests.testConstants`, `testContentSizeFitsTheScreen`, the "no change, no redraw" assertion in `testWindowShowsTheCanvasAndFollowsSettings`).

## Lines changed outside `Share/` (all small, all mine to explain)

| File | Change | Why |
|---|---|---|
| `Sources/App/MenuBar.swift` | `var shareMenu: (() -> NSMenuItem)?` and one `menu.addItem` after "Preview window" | the status menu is built in MenuBar, not AppDelegate; the charter's "submenu in AppDelegate" needs this hook |
| `Sources/App/AppDelegate.swift` | `shareWindow`, `shareMenu`, `wireShare()` (called from `launch()` and `launchForUITest()`), two lines in `governorChanged` ("open with the board") | wiring |
| `Sources/Settings/SettingsWindow.swift` | `SettingsTab.share` after Overlay, the tab line, `SettingsContext.shareStore` and `showShareWindow` | the Share tab |
| `Sources/App/SelfTest.swift` | `ShareSelfTest.run(report:)` after the Overlay probes | the self-test probe |
| `DaylightTests/App/UITestModeTests.swift` | the tab list gains "Share" | `SettingsTab.allCases` changed |
| `DaylightUITests/DaylightUITests.swift` | the tab list gains "Share", `menuOrder` gains "Share the whiteboard", the submenu is read and asserted | so the docs-to-UI check finds step 8c's menu strings |

Not touched: the camera extension, `Sources/Camera`, `Pipeline/` internals, Kit `Settings.swift`, FailureText (no failure rows were needed: the share window has no failure state of its own), `scripts/`, workflows, `android/`, `web/`. `scripts/ui_expectations.py` keeps its eight tabs, so "Settings > Share > ..." chains in the docs are skipped by the docs-to-UI check rather than asserted (request 4 below).

## Design decisions

1. **The share window reads the canvas, not the composed camera frame.** The camera frame is 1920 x 1080 with the page at 810 x 1080; the canvas is 1200 x 1600. Reading the IOSurfaces gives the viewers 1.5 times more page pixels and works while the pipeline idles (no viewer of Daylight Camera). The composition copies `daylight_canvas` (paper, highlighter multiplied, ink over) in CoreGraphics; `ShareRendererTests` pins it pixel by pixel.
2. **Titled window by default.** Pickers list it with certainty, and the macOS green-button "share this window" path needs the button (TOO-SMALL section 4). Borderless is a setting.
3. **No PostEvent automation.** Command-Shift-S only opens Zoom's picker, which still needs the owner's click; one saved click does not pay for a permission prompt and a shortcut that breaks on Zoom updates.
4. **No FailureText rows.** The window shows cream when there is nothing to draw (Mirror without a picture); the how-to and step 8c explain it. If the owner reports confusion, a row "Start mirroring to see the page here" is the natural first one.
5. **Settings outside the Kit schema.** `ShareSettings` is its own JSON blob (`com.twelve.daylight.share.v1`), lenient on decode, so the Kit `Settings` (SPEC 3) stays untouched tonight. Moving it into `Settings` later is a mechanical change.

## Follow the pen wiring (scoped, not built)

The compositor already draws the layers canvas through `QuadSpec.uv` (`Compositor.swift` around line 189, `drawQuad(encoder, dest: canvasQuad.dest, uv: canvasQuad.uv)`), so no shader change is needed.

1. Kit `Settings.swift` (owner: Kit settings): `followPen: Bool = false`, lenient decode, a Settings > Share toggle "Follow the pen (magnify where you write)".
2. `Pipeline/InkRasterizer.swift` `drawSegments(of:fromIndex:)`: compute the bounding box of `points[start - 1 ..< points.count]` (canvas units, `Stroke.points` x32 fixed point) and call a new `onInkBox: ((PixelRect) -> Void)?`; `clearAll()` calls `onReset`.
3. `Pipeline/FramePipeline.swift`: a `Locked<FollowCamera?>` created when `followPen` turns on; `onInkBox` hops onto the render queue and calls `noteInk(box, at: CACurrentMediaTime())`; `onClearCanvas` and a page change call `reset(at:)`. In `renderFrame(now:out:)`, after `let frame = ... StudioLayout.frame(...)`, when following and `canvas` is `.layers` and `out.progress >= 1`: `camera.setGeometry(canvasWidth: 1200, canvasHeight: 1600, zone: <the slot of the current layout>, at: now)` and replace `frame.canvas` with `camera.quad(now: now)`. During the slide (progress below 1) keep the full page so the slide stays SPEC 6 exact. The zone is `StudioLayout.fit(aspect: orientation.aspect, into: zone)` today; following can use the whole studio zone (1280 x 1080 in Studio Split, 1920 x 1080 in Whiteboard Only), which is where the extra size comes from.
4. Frame reuse (`frameReuse`): the canvas seed no longer covers a moving camera; render while `!camera.isSettled`.
5. Tests: a `PipelineUnitTests` case with a fake ink box that the composed frame's canvas quad zooms after 2.5 s (render clock injected), and a self-test probe that a following frame's paper fills the 1280 x 1080 zone.
6. Mirror: no ink boxes over USB without the evdev positions; follow is off for Mirror until `StylusWatcher` positions are mapped to the crop (a later item).

## Patch proposal: second camera device "Daylight Whiteboard (share)"

Drafted read-only against the tree at 8caff9d; line numbers drift, so re-read before applying. Spot-checked by the VP: `DaylightDeviceSource.init(localizedName:deviceUUID:sourceUUID:sinkUUID:)` exists (DeviceSource.swift line 50) and `ProviderSource` adds one device today (line 17); the 30 Hz clock runs only while `needsTicks` (FramePipeline line 482), hence item 5 of the proposal.

### Patch proposal: second virtual camera "Daylight Whiteboard (share)"

Scope: `whiteboard-camera/mac`. Read-only proposal; nothing in the repository was changed. Line numbers are from the current files.
Goal: one more CMIO device in the existing extension, picked in Zoom (Share Screen > Advanced > Content from 2nd Camera), Meet (Present > Camera) and Teams (Share > Content from camera). It shows the whiteboard page only, full frame, 1920x1080 BGRA at 30 fps.

Verified facts this design rests on (not re-researched): one `CMIOExtensionProvider` may `addDevice` several devices (Apple CMIOExtensionProvider docs; WWDC22 10022 "lets you add and remove devices as needed"); AVFoundation ignores all but the first input stream of a device, so this must be a second DEVICE, not a third stream; each device needs its own `deviceID` and `localizedName`, each stream its own `streamID`; one `CMIOExtensionMachServiceName` per extension (unchanged). UNVERIFIED: no public sample ships two devices that each carry a sink.

Doc note: the camera material is ARCHITECTURE 2.4 (extension) and 3.3 (idle rule D32); section 4 is the ink path. SPEC rows: C3 (SPEC.md:560), D32 (:52), D33 (:53).

#### 1. New UUIDs and Info.plist keys

Fresh `uuid4` values:

| Key | Value |
|---|---|
| `DaylightShareDeviceUUID` | `EAB5746E-09E0-4A21-9D13-884694894592` |
| `DaylightShareSourceUUID` | `A111A9DD-0E67-498E-8AA2-3566847EB7B0` |
| `DaylightShareSinkUUID` | `793238C8-D1EE-4992-BCAC-8166CE9862BA` |

`mac/project.yml`: insert after line 78 (app `info.properties`) and after line 109 (extension `info.properties`), same indentation (8 spaces):

```yaml
        DaylightShareDeviceUUID: EAB5746E-09E0-4A21-9D13-884694894592
        DaylightShareSourceUUID: A111A9DD-0E67-498E-8AA2-3566847EB7B0
        DaylightShareSinkUUID: 793238C8-D1EE-4992-BCAC-8166CE9862BA
```

Optional wording: line 106 `NSSystemExtensionUsageDescription: Publishes the Daylight Camera and Daylight Whiteboard (share) virtual cameras.` The Mach service name (line 105), entitlements (lines 110-114) and bundle id stay as they are.

#### 2. Extension changes (`mac/DaylightCameraExtension/Sources/`)

**ExtensionRules.swift.** After line 52 add the fallbacks (same pattern as lines 50-52) plus the names:

```swift
    static let defaultShareDeviceUUID = UUID(uuid: (0xEA, 0xB5, 0x74, 0x6E, 0x09, 0xE0, 0x4A, 0x21, 0x9D, 0x13, 0x88, 0x46, 0x94, 0x89, 0x45, 0x92))
    static let defaultShareSourceUUID = UUID(uuid: (0xA1, 0x11, 0xA9, 0xDD, 0x0E, 0x67, 0x49, 0x8E, 0x8A, 0xA2, 0x35, 0x66, 0x84, 0x7E, 0xB7, 0xB0))
    static let defaultShareSinkUUID = UUID(uuid: (0x79, 0x32, 0x38, 0xC8, 0xD1, 0xEE, 0x49, 0x92, 0xBC, 0xAC, 0x81, 0x66, 0xCE, 0x98, 0x62, 0xBA))
    static let cameraDeviceName = "Daylight Camera"
    static let shareDeviceName = "Daylight Whiteboard (share)"
```

Frame size and rate (lines 19-21) are shared: the share device uses the same 1920x1080 / 30 fps format.

**DeviceSource.swift.** The initializer (line 50) already takes `localizedName`, `deviceUUID`, `sourceUUID`, `sinkUUID`, so it is reusable as is. Three hard-coded strings must follow the name:
- Line 79: `localizedName: "Daylight Camera Source"` becomes `"\(localizedName) Source"`.
- Line 80: `"Daylight Camera Sink"` becomes `"\(localizedName) Sink"`.
- Line 104: `deviceProperties.model = "Daylight Camera"` becomes `deviceProperties.model = localizedName`; store it as `private let localizedName: String` set before `super.init()`.
- Lines 32-37: the timer queue label should carry the name (`"com.twelve.daylight.camera.timer.\(deviceUUID.uuidString)"`) so logs and spindumps tell the two devices apart; it must move into `init` (it is a `let` property initializer today).
- Log lines 122, 177, 218, 246, 253, 275: prefix `\(localizedName)` (or keep a short `tag`) so the unified log separates the two devices.

`SourceStream` and `SinkStream` need no change: they reach their own device through `device.source as? DaylightDeviceSource` (SourceStream lines 41, 82, 89; SinkStream lines 78, 89) and the viewers property name `4cc_dlvw_glob_0000` is per stream, so each device publishes its own `sc=<n>`. Sink authorisation (SinkStream line 67-75) stays `com.twelve.daylight` only.

**Placeholder.swift.** No change needed. `Placeholder.shared` (line 11) is one immutable pre-rendered byte array read by `fill` (lines 26-47), safe to share between both devices' timer queues. Its sentence ("Daylight is not running. Open Daylight from the menu bar.") is right for the share device too. If a distinct card is wanted later, add `init(width:height:text:)` and a `Placeholder.share` static; not required for v1 and it would change the pinned text test.

**ProviderSource.swift.** Replace the single device (lines 6-23) with two:

```swift
    private var deviceSources: [DaylightDeviceSource] = []

    init(clientQueue: DispatchQueue?, devices: [(name: String, device: UUID, source: UUID, sink: UUID)]) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        for spec in devices {
            let source = DaylightDeviceSource(localizedName: spec.name, deviceUUID: spec.device, sourceUUID: spec.source, sinkUUID: spec.sink)
            do {
                try provider.addDevice(source.device)
                deviceSources.append(source)
            } catch let error {
                extensionLog.fault("addDevice \(spec.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
```

Order matters for apps that default to the first enumerated camera: the existing "Daylight Camera" is added first. `disconnect(from:)` (lines 30-32) becomes `for source in deviceSources { source.clientDisconnected(client) }`; each device compares the client id with its own sink client (`stopsSinkOnDisconnect`), so Zoom leaving one device never stops the other's sink. A failure to add the share device leaves the main camera intact.

**main.swift.** After line 20:

```swift
let shareDeviceUUID = resolvedUUID("DaylightShareDeviceUUID", fallback: DaylightExtensionRules.defaultShareDeviceUUID)
let shareSourceUUID = resolvedUUID("DaylightShareSourceUUID", fallback: DaylightExtensionRules.defaultShareSourceUUID)
let shareSinkUUID = resolvedUUID("DaylightShareSinkUUID", fallback: DaylightExtensionRules.defaultShareSinkUUID)
```

Line 23 logs both device UUIDs; line 25 becomes `DaylightProviderSource(clientQueue: nil, devices: [(DaylightExtensionRules.cameraDeviceName, deviceUUID, sourceUUID, sinkUUID), (DaylightExtensionRules.shareDeviceName, shareDeviceUUID, shareSourceUUID, shareSinkUUID)])`.

Extension cost with no share viewer: the share device's placeholder timer runs only while its `streamingCounter > 0` (DeviceSource lines 119-165); its 90 Hz consume timer (lines 220-230) runs while the host holds the share sink open, as for the main device today. To make the share device cost strictly nothing, see risk R6 (lazy sink connect).

#### 3. Host side

**AppDelegate.swift**
- New stored properties next to line 26: `private var shareSink: CMIOSinkClient?` and `private let shareCameraQueue = DispatchQueue(label: "com.twelve.daylight.camera.share", qos: .userInitiated)` (next to line 48; a separate queue so a slow HAL locate for one device never delays the other's 2 s retry and 1 Hz viewer poll).
- New `makeShareSink() -> CMIOSinkClient?` after `makeSink` (lines 267-278): returns nil unless `signed` and both `DaylightShareDeviceUUID` and `DaylightShareSinkUUID` parse; else `CMIOSinkClient(deviceUUID:sinkUUID:queue: shareCameraQueue)` (constructor at CMIOSinkClient.swift:67). No `PreviewOnlySink` fallback: an unsigned build simply has no share output.
- `wirePipeline` (lines 361-412): after line 365 add `WebcamCapture.excludeOwnCamera(uniqueID:)` for `DaylightShareDeviceUUID` (see R4). Line 370 passes `shareSink: shareSink` to `FramePipeline`. After line 411: `shareSink.onViewerCount = { [weak pipeline] n in pipeline?.setShareViewerCount(n) }`, `shareSink.onStatusChange = { [weak self] s in self?.telemetry.note("camera", "share sink \(s)") }` (log only: onboarding and the menu status keep reading the main sink, `sinkStatusChanged` lines 461-469), then `shareSink.start()`.
- `installerChanged` (line 293): also `shareSink?.noteExtensionStatus(status)`.
- `applicationShouldTerminate` (line 257): also `shareSink?.stopAndWait(timeout: 0.5)` so the share device shows its card after Quit.

**FramePipeline.swift**
- Init (line 122): add `shareSink: VirtualCameraSink? = nil` (default keeps every existing test and SelfTest line 199 compiling). New lets next to lines 20-28: `let shareSink: VirtualCameraSink?`, `let shareFeeder: FrameFeeder?` (own PTS sequence; `FrameFeeder` lines 12-72 is per sink), `let sharePool: OutputPool?`. In the `if let device` block (lines 133-136) create `sharePool = shareSink == nil ? nil : try OutputPool(width: 1920, height: 1080)`. Do not create a second `Compositor`: both passes run on `renderQueue`, which the compositor's texture-cache flush counter already assumes.
- `Flags` (lines 34-62): add `var shareViewers = 0`.
- New `setShareViewerCount(_ n: Int)` modelled on `setViewerCount` (lines 181-193): under the flags lock store `max(0, n)` and note a rise; on `renderQueue`: on a rise, start the clock if it is not running and call `renderShareFrame(now:)` at once (a viewer otherwise sees no frame until the next tick, because the extension forwards nothing until a buffer arrives and the host sink is "started" so no placeholder is drawn); on a fall to 0, `sharePool?.flush()`. It must NOT call `recomputeCapture()`: the share frame has no presenter, so a share viewer never starts the webcam.
- Clock: today the 30 Hz clock runs only while `governor.needsTicks` (`consume` lines 482-484) and `tick` (lines 488-494) renders only outside passthrough. Change line 482 to `let needsTicks = governor.withLock { $0.needsTicks } || flags.withLock { $0.shareViewers } > 0`, and in `tick` after line 493 add `if flags.withLock({ $0.shareViewers }) > 0 { renderShareFrame(now: now) }`. With no share viewer both lines reduce to today's behaviour, so the share device costs zero host CPU and GPU.
- Factor the canvas selection of `renderFrame` (lines 532-543: layers vs mirror, orientation, aspect) into `private func canvasInput(_ f: Flags) -> (Compositor.CanvasInput, StudioLayout.CanvasOrientation, Double)` and use it in both passes.
- New `renderShareFrame(now:)` next to `renderFrame` (after line 576):

```swift
    private func renderShareFrame(now: Double) {
        guard let compositor = compositor, let pool = sharePool, let feeder = shareFeeder else { return }
        let (canvas, orientation, aspect) = canvasInput(flags.withLock { $0 })
        let frame = StudioLayout.frame(progress: 1, layout: .whiteboardOnly, orientation: orientation, canvasAspect: aspect, breath: 0)
        guard let target = pool.acquire() else { counters.withLock { $0.dropped += 1 }; return }
        compositor.render(Compositor.Inputs(presenter: nil, canvas: canvas, frame: frame), into: target) { _ in
            feeder.push(target, hostTimeNs: nil)
            pool.release(target)
        }
    }
```

`StudioLayout.frame(.whiteboardOnly)` at progress 1 (StudioLayout.swift lines 104-121) returns `presenter: nil` and the page fitted in the portrait (3:4) or landscape slot with two border lines; the compositor clears to SurfaceCream (Compositor.swift lines 152-155) and draws the page on PaperBg (lines 178-203). If the margins must be PaperBg rather than cream, add an optional `clearColor` to `Compositor.Inputs`; cosmetic, not needed for v1. A FollowRegion zoom (DaylightKit `FollowRegion.fit`/`quad`, Layout/FollowRegion.swift lines 100-114, already used by ShareSelfTest line 41) can replace the canvas quad later: it only changes `frame.canvas`, nothing in the transport.
- No `onPreviewFrame` for share frames; the preview keeps showing the main output.
- `stats` (lines 405-435): add `shareViewers` and `sharePushed = shareFeeder?.pushedFrames` to `PipelineStats` for Diagnostics and `--perf-log`.
- Idle rule `wantsCapture` (lines 737-740) is unchanged on purpose; `stopCaptureForIdle` (lines 818-827) flushes only `pool`, the share pool is flushed by `setShareViewerCount`.

**Self-test (`App/SelfTest.swift`)**
- `extensionFacts` line 636: add the three `DaylightShare*` keys to `keys`.
- Next to the pipeline probe (lines 196-341): build a second `FramePipeline(sink: PreviewOnlySink(), ..., shareSink: share)` with `let share = PreviewOnlySink()`; check `share.pushCount == 0` after 0.3 s; `setShareViewerCount(1)`; check `pushCount > 0` within 1 s ("share: frames pushed only while viewed"); `setShareViewerCount(0)`, read the count, wait 0.3 s, check it did not grow. Skip with a note when `device == nil`.

**Tests**
- `ExtensionBundleTests.swift`: line 9 `uuidKeys` gains the three share keys; line 46 and line 63 expect 6 distinct values; `testBuiltInFallbackUUIDsMatchTheExtensionInfoPlist` (lines 51-64) gets the three `defaultShare*` entries. New assertion in `testExtensionSourcesStayFreeOfDaylightKitAndPinTheRules`: `allText.contains("Daylight Whiteboard (share)")`.
- `ExtensionRulesTests.swift` `testPlistUUIDParsingAndDistinctDefaults` (lines 66-76): six defaults distinct, and the three new `uuidString` values pinned as above.
- New `DaylightTests/Pipeline/PipelineShareTests.swift` using `FakeSink` (Fakes/FakeSink.swift, `setViewers`, `pushCount`, `resetRecording`, `lastPixelBuffer`) and the `waitUntil` helper shape of PipelineSmokeTests lines 8-20, `XCTSkip` without Metal:
  1. `testShareSinkGetsFramesOnlyWhileItHasViewers`: main `FakeSink`, share `FakeSink`, `FakeCapture`; wire `share.onViewerCount = { pipeline.setShareViewerCount($0) }`; start; wait 0.5 s: `share.pushCount == 0`. `share.setViewers(1)`: `waitUntil(1) { share.pushCount >= 5 }`. `share.setViewers(0)`, wait 0.2 s, `resetRecording()`, wait 0.5 s: `pushCount == 0`.
  2. `testShareFrameIsWhiteboardOnly`: with one share viewer, `lastPixelBuffer` is 1920x1080 BGRA; the centre pixel is PaperBg and pixel (10, 540) is SurfaceCream (no presenter even while the capture feeds frames).
  3. `testShareViewersDoNotStartTheWebcam`: `setCaptureAuthorized(true)`, main sink `.connected`, main viewers 0, preview hidden, share viewers 1: after `idleStopOverrideSeconds = 0.2` the `FakeCapture` is stopped.
  4. `testMainSinkUnaffectedInPassthrough`: with share viewers 1 and the governor in PASSTHROUGH, every buffer the main sink receives is a camera buffer (`didPush(cameraBuffer)`), never a share target.

#### 4. Risks and test plan

**R1, two sinks in one extension (UNVERIFIED combination).** Each device has its own `DaylightSinkStream`, consume timer and client bookkeeping, so the code paths are independent; what is unproven is the CMIO side (two `CMIOStreamCopyBufferQueue` queues from one host process into one extension). Fallback if it fails on the owner's Mac: the extension has no renderer of its own, so remove the share device from `main.swift` (one line) and keep the existing Share window (`Share/ShareWindowController.swift`) as the screen-share path. Log lines to look for: `sink connected: device=<id>` twice, with two different device ids.

**R2, extension update and approval.** `ExtensionInstaller` submits an activation request at every launch (lines 64-77) and answers `actionForReplacingExtension` with `.replace` always (lines 201-204); ARCHITECTURE 2.4 item 5 and ExtensionBundleTests line 80 rely on `CFBundleVersion` changing per CI build. So the new device appears after the replaced extension starts. Approval is generally kept across a replace for the same team id and bundle id, so no new System Settings approval is expected, but this repo has not observed it: if the installer status goes to `.needsApproval`, the existing row 12 flow handles it. Two caveats: a local rebuild with an unchanged `CFBundleVersion` may not be replaced (bump `DAYLIGHT_BUILD_NUMBER`); and apps that enumerated cameras before the replace (Zoom, Chrome for Meet, Teams) must be quit and reopened to list the new device (handoff section 2 step 11, row 15: "quit and reopen Zoom").

**R3, conferencing apps picking the wrong camera.** The share device is a full camera, so Zoom's main video menu, Meet and FaceTime list it too, and an app that defaults to "the new camera" or follows `AVCaptureDevice.systemPreferredCamera` may switch the owner's face to the whiteboard (UNVERIFIED which apps do). Mitigations: add it second (ProviderSource order); a distinct name and model; the owner picks it only under Share > Content from camera. Test it explicitly (step 6 below).

**R4, webcam exclusion.** `WebcamCapture.isOwnCamera` (WebcamCapture.swift lines 110-113) matches the name `"Daylight Camera"` (line 51) or a registered uniqueID; "Daylight Whiteboard (share)" matches neither. Without `excludeOwnCamera(DaylightShareDeviceUUID)` in `wirePipeline`, `choose` (line 125 onwards) could pick the share camera when it is the system preferred camera or the first connected one, a feedback loop that also turns the share sink's viewers into a webcam viewer. Add the call and a unit test: `WebcamCapture.excludeOwnCamera(uniqueID: shareUUID)` then `isOwnCamera(uniqueID: shareUUID.lowercased(), name: "Daylight Whiteboard (share)") == true`.

**R5, first frame delay.** The viewer count reaches the host by the property listener (unverified, E3) or the 1 Hz poll, so a new share viewer may see up to about 1 s of no frame (black in Zoom's preview). Acceptable for content share; if not, the extension can draw the placeholder for the share device while `streamingCounter > 0` and no buffer was consumed in the last 500 ms.

**R6, idle cost in the extension.** The host opens the share sink at launch like the main one, so the extension runs a second 90 Hz consume timer on an empty queue (D33). Measure with Activity Monitor; if it is visible, make `CMIOSinkClient` connect the share sink only while its `ViewerWatcher` reports viewers (the watcher locates the device itself when no stream is set, ViewerWatcher.swift lines 70-77), and disconnect 60 s after the last one leaves.

**R7, GPU cost while sharing.** Two compositor passes per tick while share viewers > 0 and the board is up; one pass in passthrough. Check `--perf-log` gpuMs stays well under the 33 ms budget.

**Test plan on the owner's Mac (signed build, about 20 minutes)**
1. Bump the build number, install to /Applications, open. `log stream --predicate 'subsystem == "com.twelve.daylight"'` shows `replacing extension ...`, then `device ready: Daylight Camera` and `device ready: Daylight Whiteboard (share)`, then two `sink connected` lines with different device ids. No new approval prompt (record if there is one).
2. `system_profiler SPCameraDataType` lists both cameras. Photo Booth: both selectable; Daylight Camera shows the webcam, the share camera shows the page on paper.
3. Idle: no app open. Activity Monitor: Daylight and the extension near 0 percent; `--perf-log` shows `shareViewers=0 sharePushed` not growing.
4. Zoom (quit and reopen first): Share Screen > Advanced > Content from 2nd Camera > Daylight Whiteboard (share). Write on the tablet: strokes appear within the usual latency; main video stays the webcam. Stop share: log shows `viewers=0` for the share device, sharePushed stops.
5. Meet in Chrome (relaunch Chrome): Present > Camera, pick the share device. Teams: Share > Content from camera. Same checks.
6. Default camera check: with Zoom's main camera set to Daylight Camera, open and close the share several times and restart Zoom; the main camera must not jump to the share device. Repeat in FaceTime.
7. Feedback check: unplug the webcam while sharing; Daylight must report row 4 (no webcam), never pick the share camera.
8. Quit Daylight while sharing: the share device shows the "Daylight is not running" card within 2 s; reopen: the page returns.

## Requests to other teams

1. Camera owner (Review 4 VP, after `vp-review-4.md` is final): the patch proposal above. Before building, ask the owner for step 8c item 5's answer (does Zoom's "Second camera" offer Daylight Camera at all).
2. Kit settings owner: `HotkeyAction.shareWindow` (suggested Ctrl+Opt+Cmd+S, unbound by default if it clashes) and `followPen`; then `Hotkeys.swift` registers it and `ShareMenu` shows the chord.
3. Pipeline owner: the follow-the-pen wiring above.
4. UI suite owner: `scripts/ui_expectations.py` `TABS` can gain "Share" once the suite has run the Share tab green, so the docs' "Settings > Share > ..." strings are asserted too.
5. Product: the legibility test of ROADMAP-PROPOSAL item 0 should compare three routes, not two: camera tile, share window, and (once built) the second camera.
