# Status after the integration pass (Integrator-sync-4) and review round 1

What is done, what is not, every UNVERIFIED fact with its fallback, what the owner must do to test, and the exact commands CI runs. Binding documents stay `SPEC.md`, `docs/ARCHITECTURE.md` (section 18 first), `docs/PROTOCOL.md`; open items live in `docs/LOOSE_ENDS.md`; each component's own account is in `docs/handoff/`.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

Last CI run on the final integration commit: see the "CI" section (run id, commit, every job green). Section 7 is the review round that followed: what was found, confirmed, fixed, and deliberately left as it was.

---

## 1. Where the product stands in one paragraph

Everything in IMPLEMENTATION-PLAN sections 4 to 9 is written, compiled by GitHub Actions and covered by tests that run without a device: 233 DaylightKit tests on Linux and macOS, 161 hosted `DaylightTests` on macos-15, 53 Playwright tests plus 23 Node tests for the web page, 72 JVM tests for the APK, the golden drift check, and `Daylight --self-test` as a CI step. The Mac app is wired end to end (sink, installer, pipeline, server, router, saver, hotkeys, menu, onboarding, Allow panel, Settings, Diagnostics, mirror facade). What nobody has seen yet is the product on real hardware: the camera extension loads only on a Developer ID signed and notarized build (LOOSE_ENDS A1), and every tablet-side fact of LOOSE_ENDS section D needs the DC-1 in the owner's hands. `VERSION` stays `0.1.0`; the `v0.1.0` tag (first notarization) waits for the owner's secrets.

---

## 2. Per component

### A. DaylightKit (Foundation-only Swift package)

Done (SPEC 16 A1 to A8, verified against the code and the kit-linux and mac logs): golden decode and byte-equal re-encode for every case; `Header.opcode` is `UInt16`; `decodeLenient` returns nil on an unknown opcode; governor scenario tests under a manual 1/30 s clock (31 scenario methods plus 25 table methods); `CriticalSpring` closed form within 1e-4 with retarget continuity and the diverging Euler reference; every SPEC 6 number asserted in `LayoutTests`; `StrokeStore` start/append/commit/cancel/undo/redo/erase/dirty rects/dot rule/SPEC 12 JSON round trip; RFC 6455 framing at 0, 1, 125, 126, 127, 65535, 65536 and 100000 bytes with fragmentation, control frames, oversize and reserved-bit rejection; `acceptKey` and SHA1 vectors; `Settings.validated()` clamps every SPEC 11 range; `FailureText` has the 35 cases of SPEC 13.3 in row order with exact sentences; `SessionFiles` names and collision suffixes. The Mirror parsers of component F live here too (F1 below).

Unmet: nothing inside the Kit. The three optional golden vectors of IMPLEMENTATION-PLAN 4 step 8 are deliberately not in `gen_golden.py` (LOOSE_ENDS F14); their bytes are pinned by `CodecLimitsTests`.

### B. Daylight app core (pipeline, server, ink router, saving, UI, self-test)

Done: B1 `--self-test` (render probes at s = 0, 0.5 and 1 for Studio Split portrait, plus Whiteboard Only, landscape Studio Split and the mirror crop fit since Integrator-sync-4; the WebSocket round trip with the golden handshake, stroke, chunk, commit, ACK 0 bytes 16 to 31, STATE bit2 then governor 1; ink alpha along the stroke; undo and redo; the ink-source switch to Daylight Ink, mirror and back with the STATE `ink_source` byte and bit3; a stand-in tablet frame composed while the source is mirror; vendor facts; extension facts). B2 `WebServerLoopbackTests` (subprotocol echo, STATE bit2 after ACK 0, 2 MiB frame to close 1009, pending branch ACK 1 with bit2 clear, HTTP routes). B3 zero-copy passthrough with the one logged fallback (row 5). B4 idle rule observable in `--perf-log` and Diagnostics, cached frame or cream card first on restart. B5 `AllowClientPanel` as a `.nonactivatingPanel`, mirrored as a menu item, `clients.json` with `seenOverUSB`. B6 every SPEC 13.3 row maps to one `FailureText.Case` (`FailureCoverageTests`). B7 `page-NN.png` and `page-NN.json` in the SPEC 12 schema, autosave rewrites, Clear twice saves once. B8 Carbon hotkeys with the SPEC 14 defaults and conflict reporting.

Fixed by the integrator in Integrator-sync-4 (LOOSE_ENDS B19, B24): whole-second dates in `ClientRegistry`, `OnboardingSteps.canFinish` ignores the unsigned-build row, `OutputPool` is bounded by its semaphore alone.

Unmet, and why: the Zoom-keeps-focus check of B5 and the hotkey semantics of B8 are manual by SPEC definition (owner's Mac). Component C's optional Diagnostics lines (`queueCountAndCapacity`, `enqueuedFrames`, `droppedFrames`, `queueAlteredCount`) are not shown in Diagnostics yet (C handoff request 3, optional).

### C. Camera extension and host-side sink client

Done: C1 the unsigned build compiles the `.systemextension` with `CODE_SIGNING_ALLOWED=NO` and embeds it (`ls -R` in `xcodebuild-logs/app-contents.txt`). C2 both Info.plists carry the same three UUIDs, `CMIOExtensionMachServiceName` is `$(TeamIdentifierPrefix)com.twelve.daylight`, the extension entitlements are app-sandbox plus the app group (`ExtensionBundleTests`). C3 the 90 Hz consume timer only while `sinkStarted`, `authorizedToStartStream` accepts only `signingID == "com.twelve.daylight"` when non-nil, the placeholder card only while `!sinkStarted && streamingCounter > 0`, the viewers property returns the counter (as `sc=<n>`). C4 `SinkFeederTests` on a real `CMSimpleQueue` of capacity 1. Host side: `CMIODeviceLocator`, `CMIOSinkClient`, `ViewerWatcher`, `SinkFeeder`, `PreviewOnlySink`, `ExtensionInstaller` with every `OSSystemExtensionError` code mapped to its SPEC 13.3 row; wired into `AppDelegate` (Integrator-sync-3).

Fixed by the integrator in Integrator-sync-4 (LOOSE_ENDS B22, B24): five test expectations now compare `FailureText.logLine` with its `failure.<case> (row N): ` prefix; `extensionListing` reads "(missing)" for an absent directory.

Unmet, and why: C5 (Daylight Camera visible in FaceTime, `systemextensionsctl list` showing `[activated enabled]`) needs the owner's signed and notarized build (LOOSE_ENDS A1). Nothing camera-related can be seen in Zoom before that.

### D. Web whiteboard

Done (verified in the web job logs: 17 Node tests, 46 Playwright tests, Chromium 141, viewport 1200x1600, `hasTouch`, `isMobile`): D1 typecheck, build and the suite; D2 every c2s golden hex encoded in the browser, every s2c case decoded; D3 the CDP pen stroke (31-byte STROKE_START, canvas-unit chunk, monotonic `delta_ms`, COMMIT), finger, palm, hover and pressure-0 rejected, `pointercancel` commit versus cancel, the dot, pressure 1.4 clamped; D4 chip texts and classes for every SPEC 10 row, tap and 600 ms long press, undo and redo from STATE depths; D5 re-dial backoff 1000 ms x 1.7 capped at 15 s, the offline ring replays, ACK 1 and ACK 2 behaviour, the incompatibility probe; D6 `touch-action: none`, `binaryType` arraybuffer, the manifest type, fullscreen and wake lock on Start, the flag string from `/api/info` on a non-secure origin.

Unmet: nothing in CI. The DC-1 facts (Chrome version, DPR, pressure range, side button, palm cancels, home-screen display mode) are LOOSE_ENDS D3, D4, D8, D9, collected by the two console lines the page prints.

### E. Android app and overlay (Daylight Ink)

Done (verified in the android job logs: 70 JVM tests, 2.9 MB debug APK embedded into `Daylight-unsigned.zip`): E1 the committed Gradle 8.14.5 wrapper, AGP 8.13.2, Kotlin 2.3.10, JDK 17, compileSdk 36, minSdk 30, targetSdk 33, debug keystore; E2 `SolStreamTest` byte-equal golden vectors, ACK and STATE decode, UUID byte order; E3 `StrokeSessionTest` ordering, `delta_ms`, pressure normalisation, cancel, batching, chunk split, thinning, eraser, undo and redo depths; E4 `CandidatesTest` ordering and rotation; E5 `ManifestTest` exported flags and `foregroundServiceType="connectedDevice"`, the pills window rules; E6 static half (stylus and eraser only, `requestUnbufferedDispatch`, cancel handling, front-buffer fallback, `NoDelaySocketFactory`). Every CI APK carries `versionCode = <UTC build hour yymmddHH>` (the run number until review round 1, which restarts in the public repository) so a sideload upgrades the previous one; the Mac's USB path installs with `-r -d`.

Unmet, and why: the device half of E6 (what the inverted pen reports, `FLAG_CANCELED` on palm cancels, `CanvasFrontBufferedRenderer` creation on SolOS, the pills inside the mirror's top strip) needs the DC-1 (handoff steps 5 to 18).

### F. Mirror mode

Done (verified in the kit-linux and mac logs: every Kit Mirror test on both platforms, 50 `DaylightTests/Mirror` tests green including the six `H264DecoderTests` on the runner's VideoToolbox): F1 demuxer, Annex-B, evdev, stylus machine, side-button gestures, adb parsers; F2 the exact scrcpy 4.1 launch line, dummy byte with retries, forward removed after connecting, child terminated on stop (`ScrcpySessionTests` against a loopback server); F3 the VideoToolbox decoder (SPS/PPS, NAL length 4, BGRA IOSurface Metal-compatible output, format change, fresh block buffer per access unit, drop until a key frame, 12 s restart); F4 crop insets as fractions of the session size; F5 `AdbServerPolicy` (never `kill-server`, shared 5037 or private port with row 24); F6 the cable-free toggle (D42) with row 32. `MirrorController` is constructed by `AppDelegate` (Integrator-sync-3) and the menu's Ink source > Mirror starts it.

Unmet, and why: F7 (pen contact engages within 90 ms, double press pins, long press clears, pills on the tablet and absent from the camera, rotation keeps the crop) needs the DC-1 and the owner's Mac (handoff section 2).

### Integrator (project.yml, Makefile, CI, scripts)

Done: I1 both workflows are thin (`make <target>` per step) and differ only in `working-directory`, path filters and artifact paths; the mac job needs golden, web, kit-linux and android; artifacts `Daylight-unsigned.zip` (always), `daylight-ink-debug-apk`, `web-dist`, `playwright-report` on failure, `xcodebuild-logs` always, and since review round 1 `release-logs` whenever signing was attempted (even on failure: archive.log, export.log, identities.txt, profile-check.txt, signed-flag.txt, codesign-*.txt, ExportOptions.plist, notarytool-submit.json and .err, notarization-log.json), `Daylight-signed` (the zip) when signed, `Daylight-dmg` on a notarized run only. I2 `make golden-check` diffs the four copies against `gen_golden.py`. I3 the unsigned build path is recorded (`build-path.txt`), `xcodebuild -version`, `swift --version`, `xcodebuild -help` and `ls -R Daylight.app` are in `xcodebuild-logs`. I4 `CURRENT_PROJECT_VERSION` equals `GITHUB_RUN_NUMBER` through `${DAYLIGHT_BUILD_NUMBER}` substitution in `project.yml` (ARCHITECTURE 18 replaces the xcconfig), `DaylightBuildSigned` is written as false into Info.plist by `project.yml` and flipped to a Bool true by `plutil -replace DaylightBuildSigned -bool true mac/Daylight/Info.plist` in `scripts/mac-release.sh` right after `scripts/mac-generate.sh` (review round 1 ci-01; before it the script only claimed to flip it, so every signed artifact would have behaved as unsigned); the exported app is asserted to carry true plus `embedded.provisionprofile`. `make scripts-check` (golden job, 19 bash checks) proves the secrets gate, the `DEVELOPER_DIR` hand-off and the license text on Linux. `make mac-smoke` is a CI step since Integrator-sync-4.

End-to-end paths traced in the integration pass (by reading the wiring, not the handoffs): web client to `WebServer` to `InkRouter` to `EngageGovernor` to `Compositor` to the sink (`--self-test` exercises it with `PreviewOnlySink`); the Android app takes the same server path with role `ink`; mirror to governor (`MirrorSource.onGovernorEvent` posts `penContact`, `eraserContact`, `pin`, `clear`) to compositor (`.mirror` canvas input); the Allow panel (`InkRouter.pendingAllow` to `AppModel.setPendingAllow` to `AllowClientPanel`, Allow and Not now back through `AppModel` to the router, the menu item mirrors the pending list); the ink-source switch (`SettingsStore.onChange` to `AppDelegate.applySettings` to `AppModel.applyInkSource`, which updates the pipeline, the router's active client and the mirror controller); Settings keys (one `Settings` value with the SPEC 11 names, persisted as one JSON blob, `holdMode` never persisted, the tablet keys of SPEC 11 in `Prefs.kt` and `localStorage`); `FailureText` cases used through the enum everywhere, no duplicated sentences; the golden copies identical (`make golden-check`); `/api/info` carries `app`, `inkSource` and `pillStripHeight` for the web card and the APK; the Bonjour type `_daylight-camera._tcp` and the subprotocol `solstream.v1` are the same constants in all three clients; `UsbOnboarding` uses the manifest's component names.

---

## 3. UNVERIFIED facts, each with its fallback

Everything here shipped without a device, a signed build or a compiler for the component in question; the fallback is what the code does if the fact is wrong, and the owner's checklist confirms or refutes each one. LOOSE_ENDS sections D and E hold the same list with log lines and owners.

### Mac side (LOOSE_ENDS E)

| Fact | Fallback |
|---|---|
| E1 `consumeSampleBuffer` completion semantics on an empty queue | the extension consumes on a strict 90 Hz timer only while `sinkStarted`; the recursive loop is a compile-time option |
| E2 which `kCMIOStreamPropertyDirection` value marks the sink | stream index 1 is the sink (OBS, ldenoue); both directions are logged once per device; a notice when they differ from `[1, 0]` |
| E3 `CMIOObjectAddPropertyListenerBlock` firing for the custom viewers property | the 1 Hz poll is always on; the extension calls `notifyPropertiesChanged` on every change; the property travels as the string `sc=<n>` (the verified transport); `parseCount` also accepts a bare number, a 4-byte UInt32 and a CFNumber |
| E4 the owner's webcam hands out IOSurface-backed 1920x1080 BGRA buffers | first-frame facts logged once; composed passthrough with failure row 5 |
| E5 `activeFormat` versus preset reconciliation on macOS | 1080p requested through `videoSettings`; the first-frame log tells |
| E6 `AVCaptureSession.synchronizationClock` equals the host clock | frames are restamped with the host clock |
| E7 AVFoundation removing a disconnected device's input itself | removed explicitly |
| E8 Metal storage mode for IOSurface textures | left at the default; `InkRasterizerTests` and `CompositorTests` pass on the macos-15 runner |
| E9 CGBitmapContext row order and the y-flip | `InkRasterizerTests` dot test |
| E11 what a viewer sees during the capture restart | the cached frame or a cream card is pushed immediately |
| E12 frame reuse accepted by CMIO | `frameReuse` defaults to off |
| E13 the System Settings URL of the Camera Extensions pane | the sentence spells the text path; the modern URL, then the legacy URL, then the text path |
| E14 `.nonactivatingPanel` keeps Zoom focused in an LSUIElement app | standard AppKit; checklist step |
| E15 the APK MIME type Chrome needs to offer Install | `application/vnd.android.package-archive` plus `Content-Disposition: attachment` |
| E16 Chrome and OkHttp accept the hand-written RFC 6455 upgrade | tested with `URLSessionWebSocketTask` and the Playwright suite against the Node fake Mac; plan B is a second listener with `NWProtocolWebSocket` |
| E17 the 2 MiB frame cap versus Chrome's send chunking | no shipping client fragments; the cap is enforced per frame and per message |
| E18 Chromium rejects a non-echoed subprotocol before `onopen` | five failed dials plus a `GET /api/info` probe show "Update Daylight on your Mac"; the Swift server echoes `solstream.v1`, so this path should never show |
| E19 `AVSampleBufferDisplayLayer.enqueue` with `DisplayImmediately` and no control timebase | the preview layer is flushed on `.failed`; the camera path does not depend on the preview |
| E22 `NWListener` reports a busy port as `.failed` or `.waiting` | both advance to the next port (7788 to 7799) with row 16 |
| E23 PAGE_CHANGE numbering | the Mac numbers pages itself (`pageIndex + 1`) and ignores the client's `page_index` |
| E24 `Vendor/adb` keeps its executable bit through signing and notarization | `AdbClient.locateExecutable` copies the binary to Application Support and `chmod`s it there |
| E25 `NWConnection` reports a refused loopback connection as `.waiting` | both `.waiting` and `.failed` are handled, plus a 1 s probe timeout |
| E26 `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder` bridging | `usingHardware` stays nil; Diagnostics says unknown |
| E28 `OSSystemExtensionError` codes 11 and 12 | 11 (`requestCanceled`) reads as row 12, 12 (`requestSuperseded`) stays `.activating`; CoreText inside the sandboxed extension draws the placeholder sentence (declarations from Apple docs) |
| Governor judgement calls (A handoff, SPEC 5.2 since review round 1) | ink during RETURNING (stylus contact, motion, pen contact, eraser contact) re-engages only while auto-engage is armed (`autoEngage && hold != camera`), otherwise it is bookkeeping; a snap-back needs `!pinned && hold == auto`; a disconnect that empties the contacts of an ENGAGING or LIVE board restarts the idle timer; `pin(1)` from PASSTHROUGH engages even under hold camera; `savePage` and `clearCanvas` effects are gated twice (governor heuristic, then `StrokeStore.isDirty`); `PageDocument.page.index` is 1-based while STATE `page_index` is 0-based |
| `$(TeamIdentifierPrefix)` expansion in the unsigned extension Info.plist | `ExtensionBundleTests` accepts the unexpanded, TEAMID-prefixed and bare forms and prints the actual value |
| `CMIOStreamCopyBufferQueue` ownership of the returned queue | taken unretained like ldenoue (a possible one-time over-retain, never an over-release) |
| Highlighter round-cap overlap at 50 percent alpha | visual, owner check |
| Encoder settings changed while mirroring | apply to the next session (rotation or replug) |
| `systemextensionsctl uninstall` subcommand name | owner steps only; the research note marks it unverified |

### Tablet side (LOOSE_ENDS D)

| Fact | Fallback |
|---|---|
| D1 Wacom evdev node name, number, axes, pressure max, `BTN_STYLUS` under SolOS | runtime `getevent -pl` plus the pen-node rule; rows 28 and 28b; the pills remain |
| D2 `Build.MODEL`, Android release, `wm size`, `wm density` | label only; the DC-1 choice also accepts JP or DC1 serials or any single device; the APK toolbar is dp-sized and scrolls sideways if it does not fit |
| D3 pressure range 0..1 or raw 0..4095 (Android), above 1.0 (Chrome) | both quantisers clamp and normalise; the first stroke logs raw values |
| D4 side button `BUTTON_STYLUS_PRIMARY` or `SECONDARY`, and Chrome's `button`/`buttons` | bound to nothing in the apps; a pen pointerdown with pressure 0 is ignored; logged once |
| D5 where the pills appear inside the scrcpy mirror | the row is fixed inside the top 96 px (y 24, height 48); `--es pills bottom` alternative; the Mac crop is a setting |
| D6 adb authorization timeout on SolOS | checklist item |
| D7 `stay_on_while_plugged_in` value | only if A13 is approved |
| D8 Chrome version, DPR, viewport, `.local` resolution, home-screen display mode | canvas units are DPR-independent; Start always offers the Fullscreen API; `.local` never relied upon; collected by the `daylight-web caps` console line |
| D9 touch suppression while the pen is in range; palm rejection cancelling the PEN pointer | touch pointers ignored; `pointercancel` commits after 2 points and 80 ms, else cancels |
| D10 which app handles `http://` VIEW intents | the `am start` result is logged |
| D11 Tethering T extension version | `MulticastLock` when `getExtensionVersion(TIRAMISU) < 7`; legacy NsdManager path always |
| D12 getevent latency; device-side getevent exiting with the adb child | timestamps logged; `terminate()` on stop |
| D13 B-frames or PTS reordering from the DC-1 encoder | decode order is published; out-of-order PTS counted and logged once |
| D14 front-buffer rendering (graphics-core 1.0.4) on the DC-1 | `runCatching` creation; the dry view draws every segment regardless; the `frontBuffer` setting for A/B |
| D15 `appops set SYSTEM_ALERT_WINDOW allow` and `am start-foreground-service` from the shell | the service checks `canDrawOverlays` and shows row 29 instead of crashing; onboarding is the manual path; `onFailure(.pillsInvisible)` when the sequence fails |
| D17 OkHttp exposing the echoed `Sec-WebSocket-Protocol` header in `onOpen` | read via `response.header`; a missing echo shows "Update Daylight on your Mac" with no re-dial |
| D18 `usesCleartextTraffic` sufficing for plain `ws://` on SolOS | a block surfaces as `onFailure` lines under `DaylightInk.net` |
| `pointerrawupdate` removed on non-secure origins from Chrome 142 | feature-detected per load; `getCoalescedEvents`, then plain `pointermove` |
| wake lock behaviour on SolOS Chrome in fullscreen | re-requested on `visibilitychange`; the card shows held or refused |
| `onServiceFound` serviceType dot variants | `contains("_daylight-camera._tcp")` |
| OkHttp callback thread | every callback is posted to the main looper |
| `findPointerIndex` and `WindowInsets.Type` API levels | compiled against the API 33 framework jar by AGP in CI |
| `adb tcpip 5555` surviving reboot on SolOS | `tcpip` is re-run after every USB session; row 32 |
| two adb servers and one USB tablet | private-port mode plus row 24 |
| `host:track-devices` on adb 37 | FAIL or a closed socket falls back to `devices -l` every 2 s |
| `max_size=1600` yielding 1200x1600 on the DC-1 | insets are fractions of the session size either way |

---

## 4. What the owner must do to test

1. Signing (nothing camera-related can be seen in Zoom before this): LOOSE_ENDS A1, about 30 minutes on any Mac with Keychain Access. Create the Developer ID Application certificate, the two App IDs (`com.twelve.daylight` with System Extension and App Groups, `com.twelve.daylight.camera` with App Groups), the two Developer ID profiles, and an App Store Connect API Team Key; add the eight secrets with `gh secret set` (`DAYLIGHT_TEAM_ID`, `DAYLIGHT_DEVELOPER_ID_P12_BASE64`, `DAYLIGHT_DEVELOPER_ID_P12_PASSWORD`, `DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64`, `DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_PRIVATE_KEY_BASE64`); re-run the workflow with `notarize: true` or push the `v0.1.0` tag; download `Daylight.dmg`. The step-by-step owner checklist is `docs/SIGNING.md` (since review round 1; it also says what `scripts/mac-release.sh` asserts and which artifacts appear).
2. Decisions still open: LOOSE_ENDS A2 (macOS 15 or 26 on the M5 Max), A3 (package name `com.twelve.daylight.ink`), A4 (three product defaults), A5 (the Chrome flag paste), A6 (redistributing `adb`), A14 (the license).
3. Until the signed build exists, the unsigned `Daylight-unsigned.zip` from any green run shows the menu bar item, the preview window, the web page, the Allow panel, Studio Split in the preview, saving, hotkeys and the APK download; the device steps are in each handoff's section 2 (B for the Mac and web, E for the APK, F for mirror mode, C for the first light of the camera on the signed build).
4. Device facts to collect on the DC-1: LOOSE_ENDS section D, each row with its log line; the checklist rows for `docs/TESTING-CHECKLIST.md` are in every handoff's owner-text section (fold at M6).

---

## 5. Exactly what CI runs

Workflow `whiteboard-camera` (`.github/workflows/whiteboard-camera.yml`; the standalone twin is `whiteboard-camera/.github/workflows/ci.yml`), on every push to `claude/**` and `master` that touches `whiteboard-camera/**`, on pull requests, on `v*` tags and on `workflow_dispatch` (input `notarize`). Every step is a make target; `scripts/ci-env.sh` runs first in every job.

| Job | Runner | Steps |
|---|---|---|
| `golden` | ubuntu-latest | `make golden-check` (`scripts/check-golden.sh`: `python3 protocol/gen_golden.py` to a temp file, diff against `protocol/golden/solstream-v1.json` and the three copies); `make scripts-check` (`scripts/scripts-check.sh`: 19 bash checks of the mac-release secrets gate, the ci-env `DEVELOPER_DIR` hand-off and the shipped license text) |
| `web` | ubuntu-latest, Node 22 | `make web` (`npm ci`, `npm run typecheck`, `npm run build`), `make web-test` (`node --test`, `npx playwright install --with-deps chromium`, `npx playwright test`); artifacts `web-dist`, `playwright-report` on failure |
| `android` | ubuntu-latest, Temurin 17, setup-gradle | `make android` (`./gradlew --no-daemon --stacktrace -PdaylightVersionCode=$(date -u +%y%m%d%H) -PdaylightVersionName=$(cat VERSION) :app:testDebugUnitTest :app:assembleDebug`); artifacts `daylight-ink-debug-apk`, `android-test-reports` on failure |
| `kit-linux` | ubuntu-latest, container `swift:6.4-noble` | `scripts/kit-test.sh` (`swift test --package-path mac/DaylightKit --parallel`) |
| `mac` (needs the four above) | macos-15, Xcode 16.4 | download `daylight-ink-debug-apk`; `brew install xcodegen`; `make fetch-tools`; `make embed-apk`; `make web`; `make mac-generate`; `make kit-test`; `make mac-debug` (`xcodebuild ... -configuration Release CODE_SIGNING_ALLOWED=NO build`, ad-hoc fallback, `Daylight-unsigned.zip`); `make mac-test` (`xcodebuild test -scheme DaylightTests`); `make mac-smoke` (`Daylight --self-test --perf-log` under a 120 s alarm); upload `Daylight-unsigned` and `xcodebuild-logs`; `make mac-release` (signs, exports, notarizes only when the secrets exist, otherwise prints what is missing and exits 0); upload `Daylight-signed` when `HAS_SIGNING` |

Concurrency is per job: the Linux jobs cancel their older runs, the mac job always finishes (LOOSE_ENDS B16). Locally, `make help` lists the targets, `make doctor` says which can run here; `make golden-check`, `make web`, `make web-test` work anywhere with Python 3 and Node 22.

---

## 6. CI

Runs of the integration pass (workflow `whiteboard-camera`, branch `claude/daylight-whiteboard-camera-tzxfjb`):

| Run | Commit | Result |
|---|---|---|
| 37120036901 | f395315 (Integrator-sync-4) | golden, web, android, kit-linux green; mac red: the hosted test process aborted in `OutputPoolTests` (a `DispatchSemaphore` deallocated below its initial value, LOOSE_ENDS B24) and the relaunched `PipelineSmokeTests` counted one cold-GPU drop |
| 37120607515 | ca94b55 (Integrator-sync-4b) | golden, web, android, kit-linux (233 tests) green; `make mac-debug` and `make mac-test` green for the first time with every component in the tree (161 hosted tests, 0 failures); `make mac-smoke` red on one probe: "sink: frames pushed while engaged" sampled the sink counter before the first composed frame's command buffer completed (about 70 ms cold); every other probe passed, including the layouts, the ink-source switch, REDO and the composed mirror frame |
| 37121036066 | 6ec23fc (Integrator-sync-4c) | every job green: golden, web (17 Node and 46 Playwright tests), android (70 JVM tests), kit-linux (233 tests), mac (`make kit-test`, `make mac-debug`, `make mac-test` with 161 hosted tests, `make mac-smoke` with `self-test: PASS`, `make mac-release` self-skipped without secrets). The first fully green run with all six components and the smoke step. The docs-only commit after it (this table row) is proved by the run of `git log -1 -- docs/STATUS.md` |

Runs of review round 1 (the fixers' own runs are in their commit messages; these are the integrator's):

| Run | Commit | Result |
|---|---|---|
| 37129936705 | cd00836 (last fixer commit) | golden, web, android, kit-linux green; mac red on two `InkRouterTests` written by the app fixer (`testAutosaveThenClearKeepsOnePairPerBoard` expected a second save that SPEC 12 forbids; `testOverlayRoleSendsOnlyControlMessagesAndIsNeverTheActiveSource` expected one log line for three opcodes), the same two as in run 37129194342 |
| 37131641571 | 516e3a0 (ten integrator commits: the two test corrections, Diagnostics row 5, UsbOnboarding, the web fixes, the Daylight Ink fixes, android.sh) | golden (19 scripts-check), web (23 Node and 53 Playwright tests), kit-linux green; android red on one boundary: the existing `pressureIsNormalisedForUnitAndRawRanges` asserts `looksRaw(2f)` and the new threshold was exclusive; mac skipped |
| 37131914413 | e8e1dc1 (threshold inclusive) | golden, web, android (72 JVM tests), kit-linux green; mac red on `MirrorControllerTests.testSetUpOverUSBForWebAndNative` (spelled the pre-android-09 commands) and `CMIOSinkClientTests.testStaleConnectionIsDroppedByTheRunningTimer` (a race with the 0.2 s test timer, green once in the fixer's run); every other hosted test green, including the two corrected `InkRouterTests` and the new `UsbOnboardingTests` |
| 37132513946 | fdfa2a6 (the two hosted tests fixed; `docs/SIGNING.md`; the folded documentation) | every job green: golden, web, android, kit-linux, mac (`make mac-test` TEST SUCCEEDED, `make mac-smoke` self-test: PASS, `make mac-release` self-skipped without secrets). The docs-only commit after it (this table row) is proved by the run of `git log -1 -- docs/STATUS.md` |

Facts the self-test logged on the runner: Metal device "Apple Paravirtual device"; first command buffer 71 ms, then 13.5 ms and 1.2 ms; `Vendor/adb` 19,993,936 bytes `x86_64 arm64`; `scrcpy-server-v4.1` 733,706 bytes with the pinned sha256; the embedded `DaylightInk.apk` 7,841,168 bytes; the unsigned extension's `CMIOExtensionMachServiceName` reads `com.twelve.daylight` (`$(TeamIdentifierPrefix)` expands to an empty string without a team), with the three UUIDs identical in both Info.plists.

---

## 7. Review round 1 (2026-10-03)

Six adversarial reviewers read the shipped tree by area (DaylightKit, Daylight app core, camera extension and host sink client, web whiteboard, Daylight Ink, CI and signing), two verifiers judged every finding against the code, and six fixers landed what the verifiers confirmed; the integrator applied the cross-area leftovers, folded the notes into the documents and drove CI to green. The code ships blind, so the round was the review the hardware cannot give yet. Commit range `f5375fe..` to the run listed in section 6; `docs/LOOSE_ENDS.md` section G holds what stays open.

Counts: 60 findings reached the verifiers; 59 confirmed, 1 rejected (kit, see below); 58 fixed in code, 1 recorded as a judgement call (G12 keeps the fix, the owner may flip it).

### DaylightKit

| Finding | Confirmed | Outcome |
|---|---|---|
| kit-01 ink during RETURNING re-engaged even under Hold: Camera or with auto-engage off | yes | fixed (f5375fe): `handleReturning` gates the re-engage on `autoEngageArmed` for contact, motion, pen and eraser contact, bookkeeping kept; pin, engage, hotkeys and hold(split or whiteboard) unguarded per D38; two table tests |
| kit-02 a stray cancel within 80 ms snapped back a board a pin or a hold had brought up | yes | fixed (f5375fe): the snap-back guard adds `!pinned && hold == .auto`; no `pinChanged` from a snap-back; scenario test with springK 90 |
| kit-03 a disconnect that emptied the contacts of a LIVE board could fire the return at once (the pen on the glass had frozen the timer) | yes | fixed (f5375fe): the any-state rows set `lastActivity = max(lastActivity, now)` when a non-empty contact set became empty while ENGAGING or LIVE; no transition; `testClientGoneNeverChangesState` still holds; a 110 s clientGone gives the pre-warning at 195 s and the return at 200 s |
| kit-04 (rejected by the verifiers) | no | not fixed on purpose: the verifiers found the reported behaviour matches SPEC 5.2 |
| kit-05 WebSocket reserved opcodes 0x3 to 0x7 and 0xB to 0xF were parsed as data | yes | fixed (b7bd0e0): `WebSocketError.reservedOpcode`, the connection closes 1002; test |
| kit-06 failure row 5 printed a literal "1280x720 NV12" | yes | fixed (01cce16, 7cc2104): the template takes `<w> <h> <fourcc>`; Diagnostics passes the first-frame facts; SPEC 13.3 row 5 shows the placeholders |

### Daylight app core

| Finding | Confirmed | Outcome |
|---|---|---|
| app-01 `SessionSaver.forgetPage` ran before the queued write, so Clear rebound the saved page | yes | fixed (7f55dd7): forgets are queued on io.queue after the pending writes; `InkRouterTests` draw, Clear, draw, Clear writes `page-01` and `page-01-2`; the integrator corrected one new test that contradicted SPEC 12 (a Clear right after an autosave writes nothing new, f199fac) |
| app-02 a Settings change rebuilt the governor mid-board (the board vanished) | yes | fixed (a51f365): `FramePipeline.pendingConfig` applies on the next return to PASSTHROUGH; the Kit's `GovernorConfig` stays a `let` (G13) |
| app-03 Daylight could capture its own virtual camera | yes | fixed (335680b): `WebcamCapture.choose` excludes the fixed device UUID and the name "Daylight Camera" |
| app-04 the SPEC 11 camera choice was evaluated once, not live | yes | fixed (335680b): evaluated at every start and on `wasConnected`; `preferredUniqueID` replaces the pinned device; G5 records the one path left |
| app-05, app-14 capture ran before camera authorization and onboarding ignored the TCC status | yes | fixed (2119453): `Flags.captureAuthorized` gates `wantsCapture`; `refreshOnboardingInputs` maps the status and starts the pipeline when it flips; G7 |
| app-06 zero-copy eligibility was decided once; a format change mid-run went unlogged | yes | fixed (a43e979): per-frame eligibility, `Flags.lastFormat` re-arms the row 5 message; `FakeCapture.switchFormat` test |
| app-07 "Not now" denied a tablet for the whole session | yes | fixed (5bfe92c): the next dial prompts again (PROTOCOL 8) |
| app-08 `/api/info` origin ignored the request's Host header; the web card trusted it | yes | fixed (fb6b6d0 Mac, c41c027 web): origin follows the Host header; the page prefers its own http origin |
| app-09 menu "Whiteboard now" toggled instead of engaging | yes | fixed (2cbf475): `AppModel.whiteboardNowEvent` |
| app-10 hotkeys registered non-exclusively and a same-app duplicate read as "another app" | yes | fixed (8605ce5): `kEventHotKeyExclusive`, `HotkeyError.duplicate(action, other)`, Settings shows the reason; SPEC 14 and the B handoff reworded; G6 |
| app-11 the preview window could hold every capture buffer while the main thread stalled | yes | fixed (3a7d0ae): `LatestSampleCoalescer`, one pending sample, pool release after the preview |
| app-12 the `CVMetalTextureCache` was never flushed | yes | fixed (cec9d4c): flushed every 30 frames on the render queue; G14 asks for the resident set after 30 minutes of mirroring |
| app-13 a lost camera in PASSTHROUGH left the last frame frozen in Zoom | yes | fixed (93c931e): the cream card is pushed through the feeder and the preview |
| app-15 the overlay role could send ink and become the active source | yes | fixed (5bfe92c): non-control messages from an overlay connection are dropped and logged once per opcode; overlay connections are never the active source |

### Camera extension and host sink client

| Finding | Confirmed | Outcome |
|---|---|---|
| camera-01 `scripts/mac-release.sh` never flipped `DaylightBuildSigned`, so every signed artifact would have behaved as unsigned (the extension never activated) | yes | fixed (78bd616, with ci-01): `plutil -replace ... -bool true` after `mac-generate.sh`, asserted on the exported app; the project.yml `${VAR}` variant was rejected because XcodeGen substitution yields a string and the readers need a Bool |
| camera-02 the sink never noticed a replaced or relaunched extension | yes | fixed (05b8d1d): the 2 s timer re-validates device and sink stream ids for the life of `start()`; `WasDisconnected` observed; G1 |
| camera-03 `push` raced `disconnect()` on the queue | yes | fixed (05b8d1d): `pushLock` from the connection read through the enqueue; 4 x 2000 concurrent pushes test |
| camera-04 `ViewerWatcher` re-registered its listener every poll and after failed reads | yes | fixed (a460ab6): one listener per distinct stream id, after the first successful read |
| camera-05 a finished deactivation reported `.installed` | yes | fixed (37fa39f): the result maps by request kind |
| camera-06 a `CMIODeviceStartStream` failure left the proc registered | yes | fixed (05b8d1d): unregistered with the NULL-proc call; ownership stays unretained (E28) |

### Web whiteboard

| Finding | Confirmed | Outcome |
|---|---|---|
| web-01 the stroke tail was held by backpressure, so COMMIT's `point_count` undercounted | yes | fixed (fe61586): `flush(true)` at the end of a stroke; whole-stroke and partial hold tests |
| web-02 a STATE older than the page's COMMIT hid the stroke just drawn | yes | fixed (fe61586): in-flight commit guard, at most two stale STATEs in a row without the Mac's total growing (a Mac-side Clear still lands); test |
| web-03 Clear and New page were dropped while offline while the page bumped its page index | yes | fixed (c41c027): the controls are disabled while not live; New page advances only when the Mac heard it; test |
| web-04 depths from a Mac holding more strokes than the page misaligned; the eraser reach differed from the Kit; erasing dropped the redo tail | yes | fixed (fe61586): newest-end alignment, `geometry.ts` mirrors `Geometry.strokeHit`, the redo tail survives; Node and Playwright tests; G2 |
| web-05 a cancelled dot stayed on the ink layer | yes | fixed (fe61586): redraw plus wet clear on cancel; pixel test |
| web-06 a pen contact arriving with pressure 0 never became a stroke | yes | fixed (fe61586): the contact is armed and starts on the first pressured sample; the pressure-0 tap still counts as ignored (D4) |
| web-07 a restarted stroke ringed its unsent points under the old id (dropped by the Mac after its COMMIT) | yes | fixed (fe61586): the points stay with the new id, `delta_ms` rebased, START ringed ahead; G3 |
| web-08 pointermove doubled eraser samples under pointerrawupdate | yes | fixed (fe61586): one frame per sample; test |
| web-09 the ring had no frame bound (erase frames carry no points) | yes | fixed (771627f): 4096 frames, oldest first, counted apart |
| web-10 ERASE_STROKES could carry more than 1024 ids | yes | fixed (fe61586): `ids.slice(0, 1024)` |
| web-11 the card's innerHTML was rebuilt on every STATE | yes | fixed (c41c027): rendered only while open and when the text changed |
| web-12 "Update Daylight on your Mac" was shown for a refused socket with no re-dial | yes | fixed (c41c027): "refused" phase with a 60 s re-dial and the SPEC 10 web-only row; G4 |

### Daylight Ink (Android)

| Finding | Confirmed | Outcome |
|---|---|---|
| android-01 a junk host crashed the dial inside OkHttp | yes | fixed (1824334): try/catch around the request, junk hosts never become candidates |
| android-02 a PING before the HANDSHAKE_ACK made the Mac close 1002 | yes | fixed (1824334): PING only in PENDING or LIVE; test |
| android-03 the TOP pills window could be pushed below the status bar into the camera picture | yes | fixed (a3f772f): fit-insets none, `pills frame` log line (D5) |
| android-04 Settings toggles did not apply until the app restarted | yes | fixed (a3f772f): re-read on every return; the front-buffer toggle rebuilds the canvas |
| android-05 the connection stopped while the owner typed the address in Settings | yes | fixed (a3f772f): Settings holds the link like onboarding |
| android-06 pressure 1.0 to 2.0 read as a raw ADC count | yes (one verifier: optional) | fixed (d9d3de6, e8e1dc1): threshold 2 inclusive, calibrated overshoot clamps to 1 |
| android-07 a link-local Bonjour resolve was dialled without its scope | yes | fixed (1824334): logged and skipped (D11) |
| android-08 the multicast lock was held for the life of the app | yes | fixed (1824334): held only while searching |
| android-09 the USB path reversed `tcp:P tcp:P` and handed over a port-less host, so a Mac listener on 7789 was unreachable | yes | fixed (28f6ecc, Mac side): `tcp:7788 tcp:<bound port>` and `host:port`; SPEC 9.3 reworded |
| android-10 `install -r` refused a downgrade; run numbers restart in the public repository | yes | fixed (28f6ecc, 516e3a0): `install -r -d`; versionCode is the UTC build hour; G16 |

### CI, signing and packaging

| Finding | Confirmed | Outcome |
|---|---|---|
| ci-01 the signed flag was never flipped | yes | fixed (78bd616), see camera-01 |
| ci-02 the release script used bash 4 arrays under `set -u` on the runner's bash 3.2 | yes | fixed (78bd616): rewritten for bash 3.2 |
| ci-03 a partial or misnamed secret set skipped green | yes | fixed (78bd616, cd00836): fail-fast gate naming the missing names; `make scripts-check`; G9 |
| ci-04 the notarized app was not stapled | yes | fixed, minimal variant (78bd616): DMG stapled, app stapled and the zip re-created; the app inside the DMG stays un-stapled, G8 |
| ci-05 `notarytool` had no timeout and no log on failure | yes | fixed (78bd616): `--wait --timeout 30m`, the log fetched whenever an id exists; G10 |
| ci-06 the Apache-2.0 text was not shipped although THIRD_PARTY_NOTICES said so | yes | fixed (4f28601): `Vendor/LICENSE-Apache-2.0.txt` and `Vendor/THIRD_PARTY_NOTICES.md`; G15 |
| ci-07 no team check before a five-minute archive | yes | fixed (78bd616): team compared across the secret, the certificate and the app profile; entitlement checks warn |
| ci-08 `set -x` printed the secrets | yes | fixed (78bd616): no xtrace by default; `RUNNER_DEBUG` enables it for the build part only |
| ci-09 the temporary keychain and decoded files survived a failure | yes | fixed (78bd616): trap on EXIT |
| ci-10 `DAYLIGHT_XCODE_PATH` never reached the later steps | yes | fixed (02fdc95): `ci-env.sh` writes `DEVELOPER_DIR` to `GITHUB_ENV`; G11 |
| ci-11 the skip message pointed at a document that did not exist | yes | fixed (78bd616, and `docs/SIGNING.md` created by the integrator) |

### Deliberately not changed

- `CMIOStreamCopyBufferQueue` ownership stays unretained (E28): the verifiers disagreed and the documented decision stands until a `CFGetRetainCount` reading on the first signed run.
- `EngageGovernor` keeps `GovernorConfig` as a `let` (G13); the pipeline holds the pending config instead.
- The `/api/info` protocol field (G4) waits for a Server change that has passed the mac job.
- A second restart inside one glass contact (G3) is accepted as rare.
- The eraser remains not undoable (F13), and the Mac still never replays its canvas (G2).

### Lessons recorded for the next round

- A fixer's test that contradicts the SPEC is a finding about the test: `testAutosaveThenClearKeepsOnePairPerBoard` expected a second save that SPEC 12's dirty stamp forbids; the integrator corrected the test, not the code (f199fac).
- Findings must be routed to the area that owns the file: one fixer received the twelve web findings and another the ten Android findings and could not act; the integrator applied them (fe61586, c41c027, 771627f, 1824334, a3f772f, d9d3de6, 28f6ecc, 516e3a0).
- A test that asserts an exact frame count across an animation-frame boundary is flaky (the chunk may split); the web suite now accepts one or two STROKE_CHUNKs and asserts the point total instead.
- A test that shortens a timer to 0.2 s and then asserts between two dispatches on the timer's queue is a race (`testStaleConnectionIsDroppedByTheRunningTimer`, green once, red in run 37131914413); the adopt and the pushes now run inside one block on that queue.
- A command-shape change (android-09) must be grepped across every test that spells the commands, not only the unit's own file (`MirrorControllerTests.testSetUpOverUSBForWebAndNative` spelled the old `install -r` and the port-less host).
