# Status after the integration pass (Integrator-sync-4) and review round 1

What is done, what is not, every UNVERIFIED fact with its fallback, what the owner must do to test, and the exact commands CI runs. Binding documents stay `SPEC.md`, `docs/ARCHITECTURE.md` (section 18 first), `docs/PROTOCOL.md`; open items live in `docs/LOOSE_ENDS.md`; each component's own account is in `docs/handoff/`.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

Last CI run on the final integration commit: see the "CI" section (run id, commit, every job green). Section 7 is the review round that followed: what was found, confirmed, fixed, and deliberately left as it was. Section 8 records the owner decisions applied on 2026-10-03; section 9 is review round 2; section 10 is the Platform phase 2; section 11 is the phase 2 integration (what the three phase 2 VPs delivered, what was verified and corrected); sections 12, 13 and "Review round 3" are phase 3; section 14 is the phase 3 integration. The owner's short summary is `docs/WHATS-NEW.md`.

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

Mirror v2, the Wi-Fi transport (LOOSE_ENDS A9, 2026-10-03): built and green in CI, unverified on the device. Daylight Ink streams its screen (MediaProjection, MediaCodec H.264) over its WebSocket as the PROTOCOL 14 mirror stream family; the Mac's `WifiMirrorSource` reuses the scrcpy demuxer and VideoToolbox decoder and engages by frame differencing (or the USB pen stream when present). Proof: run 37149475227, all jobs green, self-test probe `wifi mirror: composed frame`. Details, UNVERIFIED items and requests: `docs/handoff/vp-mirror-v2.md`; owner steps: SETUP 2.4, TESTING-CHECKLIST Session 4b, LOOSE_ENDS D19 to D23.

### Integrator (project.yml, Makefile, CI, scripts)

Done: I1 both workflows are thin (`make <target>` per step) and differ only in `working-directory`, path filters and artifact paths; the mac job needs golden, web, kit-linux and android; artifacts `Daylight-unsigned.zip` (always), `daylight-ink-debug-apk`, `web-dist`, `playwright-report` on failure, `xcodebuild-logs` always, and since review round 1 `release-logs` whenever signing was attempted (even on failure: archive.log, export.log, identities.txt, profile-check.txt, signed-flag.txt, codesign-*.txt, ExportOptions.plist, notarytool-submit.json and .err, notarization-log.json), `Daylight-signed` (the zip) when signed, `Daylight-dmg` on a notarized run only. I2 `make golden-check` diffs the four copies against `gen_golden.py`. I3 the unsigned build path is recorded (`build-path.txt`), `xcodebuild -version`, `swift --version`, `xcodebuild -help` and `ls -R Daylight.app` are in `xcodebuild-logs`. I4 `CURRENT_PROJECT_VERSION` equals `GITHUB_RUN_NUMBER` through `${DAYLIGHT_BUILD_NUMBER}` substitution in `project.yml` (ARCHITECTURE 18 replaces the xcconfig), `DaylightBuildSigned` is written as false into Info.plist by `project.yml` and flipped to a Bool true by `plutil -replace DaylightBuildSigned -bool true mac/Daylight/Info.plist` in `scripts/mac-release.sh` right after `scripts/mac-generate.sh` (review round 1 ci-01; before it the script only claimed to flip it, so every signed artifact would have behaved as unsigned); the exported app is asserted to carry true plus `embedded.provisionprofile`. `make scripts-check` (golden job, 25 bash checks) proves the secrets gate, the `DEVELOPER_DIR` hand-off, the license text and the kit-test crash retry on Linux. `make mac-smoke` is a CI step since Integrator-sync-4.

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
2. Decisions: A2, A3, A4, A5 and A14 were settled by the owner on 2026-10-03 (section "Owner decisions applied" below); A6 became the engineering ticket LOOSE_ENDS H1 (bundled adb stays the default, two alternatives to build).
3. Until the signed build exists, the unsigned `Daylight-unsigned.zip` from any green run shows the menu bar item, the preview window, the web page, the Allow panel, Studio Split in the preview, saving, hotkeys and the APK download; the device steps are in each handoff's section 2 (B for the Mac and web, E for the APK, F for mirror mode, C for the first light of the camera on the signed build).
4. Device facts to collect on the DC-1: LOOSE_ENDS section D, each row with its log line; the checklist rows for `docs/TESTING-CHECKLIST.md` are in every handoff's owner-text section (fold at M6).

---

## 5. Exactly what CI runs

Workflow `whiteboard-camera` (`.github/workflows/whiteboard-camera.yml`; the standalone twin is `whiteboard-camera/.github/workflows/ci.yml`), on every push to `claude/**` and `master` that touches `whiteboard-camera/**`, on pull requests, on `v*` tags and on `workflow_dispatch` (input `notarize`). Every step is a make target; `scripts/ci-env.sh` runs first in every job.

| Job | Runner | Steps |
|---|---|---|
| `golden` | ubuntu-latest | `make golden-check` (`scripts/check-golden.sh`: `python3 protocol/gen_golden.py` to a temp file, diff against `protocol/golden/solstream-v1.json` and the three copies); `make scripts-check` (`scripts/scripts-check.sh`: 26 bash checks of the mac-release secrets gate, the ci-env `DEVELOPER_DIR` hand-off, the shipped license text, the project's `LICENSE` and the kit-test crash retry) |
| `web` | ubuntu-latest, Node 22 | `make web` (`npm ci`, `npm run typecheck`, `npm run build`), `make web-test` (`node --test`, `npx playwright install --with-deps chromium`, `npx playwright test`); artifacts `web-dist`, `playwright-report` on failure |
| `android` | ubuntu-latest, Temurin 17, setup-gradle | `make android` (`./gradlew --no-daemon --stacktrace -PdaylightVersionCode=$(date -u +%y%m%d%H) -PdaylightVersionName=$(cat VERSION) :app:testDebugUnitTest :app:assembleDebug`); artifacts `daylight-ink-debug-apk`, `android-test-reports` on failure |
| `kit-linux` | ubuntu-latest, container `swift:6.4-noble` | `scripts/kit-test.sh` (`swift test --package-path mac/DaylightKit --parallel`; when swift-package itself exits by a crash signal the whole suite runs again from an empty `.build`, up to three runs, never after a test failure) |
| `mac` (needs the four above) | macos-15, Xcode 16.4 | download `daylight-ink-debug-apk`; `brew install xcodegen`; `make fetch-tools`; `make embed-apk`; `make web`; `make mac-generate`; `make kit-test`; `make mac-debug` (`xcodebuild ... -configuration Release CODE_SIGNING_ALLOWED=NO build`, ad-hoc fallback, `Daylight-unsigned.zip`); `make mac-test` (`xcodebuild test -scheme DaylightTests`); `make mac-smoke` (`Daylight --self-test --perf-log` under a 120 s alarm); upload `Daylight-unsigned` and `xcodebuild-logs`; `make mac-release` (signs, exports, notarizes only when the secrets exist, otherwise prints what is missing and exits 0); upload `Daylight-signed` when `HAS_SIGNING` |

| `mac-26` (needs the same four; non-blocking, `continue-on-error`) | macos-26, its default Xcode (26.6) | the same steps as `mac` up to `make mac-smoke`; artifacts `Daylight-unsigned-macos-26`, `xcodebuild-logs-macos-26`; no signing (LOOSE_ENDS H2) |

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

### CI stabilization after the round (2026-10-03)

Two docs-only commits went red (5e917e4 in run 37134646725, 88b7a0e in run 37135358460) and the next one too (fcde1e7, run 37136061242), so the failures were nondeterministic. The last 20 runs on the branch were read job by job: every other red run on a docs-only commit (37117976348, 37118886042) failed on the eight deterministic tests of LOOSE_ENDS B19 and B22, fixed in f395315; the other red runs were code changes caught by CI (fixed in later commits) or the two races already fixed before this pass (the stale-connection timer in fdfa2a6, the self-test sink probe in 6ec23fc). LOOSE_ENDS G17 holds the details.

| Flake | Root cause | Fix | Commit |
|---|---|---|---|
| `PipelineSmokeTests.testCaptureWaitsForCameraAuthorization` (mac, runs 37134646725 and 37136061242) | the cream card was built on the render queue by a per-byte Swift loop over 8 MB, 0.6 to 0.9 s in the unoptimized test build on the shared runner; the test asserted the card after a fixed 0.3 s, and every capture start without a cached frame held the render queue the same way | `memset_pattern4` fill; the test waits for the card, keeps its 0.3 s no-camera window, drains the render queue, asserts `startCount == 0` and the cream pixel | 8056725 |
| `CMIOSinkClientTests.testStaleConnectionIsDroppedByTheRunningTimer` (mac, red once in run 37131914413 on another race, fixed in fdfa2a6) | still waited a fixed 0.7 s for a 0.2 s timer tick with 0.2 s leeway that walks the CMIO devices | an expectation fulfilled by the status change itself, 10 s timeout, same assertions | e524f5b |
| kit-linux segfault (run 37135358460) | `swift-package` on `swift:6.4-noble` crashed in libdispatch's event loop during build planning, exit 139, before any test ran (a toolchain crash, not a test) | `scripts/kit-test.sh` reruns the whole suite from an empty `.build` on a crash signal (132 to 135, 139), up to three runs, with a log line; exit 1 is never retried; `make scripts-check` proves it with a stub | 3c3fbdc |
| no assertion message in any mac log | XCTest assertion lines start with the source path, so the `mac-test.sh` filter dropped them and the 40-line failure summary filled up with `nw_` socket lines | the live filter keeps `: error: -[` and relaunch lines; the summary prints the assertions first | f71c7d9 |

Proof: run 37136962637 (push, run number 46) and run 37137398073 (workflow_dispatch on the same commit, run number 47) are green on 3c3fbdc, every job: golden (25 scripts-check), web, android, kit-linux, mac (`make mac-test` TEST SUCCEEDED with 0 failed cases, `make mac-smoke` self-test: PASS).

Lessons:

- A test that waits a fixed time for work queued behind other work on a serial queue is a race on a shared runner; wait for the condition, then drain the queue with `sync {}` before asserting that something did not happen.
- The hosted tests run the Debug build: a per-pixel Swift loop that is instant in Release can hold a queue for most of a second there. Fill buffers with `memset_pattern4` or vImage.
- A red job must print its assertion message in the job log; the artifact store is not reachable from every environment that reads the logs.

---

## 8. Owner decisions applied (2026-10-03)

The owner settled the open decisions of LOOSE_ENDS section A; each is recorded in its row there and in SPEC section 2 (Owner-confirmed).

- A2: the M5 Max most likely runs macOS 26, so every approval-pane text names it first: "macOS 26 and 15" use System Settings > General > Login Items & Extensions > Camera Extensions; macOS 13 and 14 keep Privacy & Security > Security (SPEC D51). The row 12 sentence itself has no version in it and is unchanged, as are its exact-sentence tests. A macos-26 CI leg is backlog H2.
- A3: the Android package `com.twelve.daylight.ink` is confirmed (D15).
- A4: the three product defaults stay: eraser does not engage, side button long press Clear and double press Pin, a disconnect leaves the governor alone (D10, D36, D37).
- A5: the Chrome flag paste stays optional and offered (D52).
- A6: the bundled adb stays the default; downloading platform-tools on first use and reusing an installed adb are the engineering ticket LOOSE_ENDS H1, with the legal note kept in A6 and `THIRD_PARTY_NOTICES.md`.
- A14: Apache-2.0. `LICENSE` is the standard text; the scrcpy copy moved to `LICENSES/Apache-2.0.txt` (G15 closed); `make scripts-check` now runs 26 checks, one of them asserting `LICENSE`.
- The public standalone repository is https://github.com/12twelve12hi/whiteboard-camera-draw (created by the owner, populated on 2026-10-03 by `git subtree split --prefix=whiteboard-camera`, 92 commits, tree identical to this directory); its `ci.yml` runs the same jobs, and CI also keeps running in the monorepo.

---

## 9. Review round 2 (2026-10-03)

A second adversarial pass over the areas round 1 changed most (camera sink client and extension, frame pipeline, ink router and server, web ink) plus the app core, the governor and the tests. Twelve finders (six areas, two lenses each) audited every round-1 fix against its own finding; an independent refuter whose default was "not real" judged every finding; one fixer per area landed the confirmed ones with a test that fails before and passes after. `docs/handoff/vp-review-2.md` holds the per-finding table, the rejected findings with reasons, and the requests to other owners; `docs/LOOSE_ENDS.md` section I holds what stays open.

Counts: 57 findings reached the refuters; 45 confirmed and 6 confirmed-unverified (three of them duplicates across lenses, so 47 distinct), 6 rejected; the VP reopened one rejected finding (WEBA-02, a one-line fix of G3). Every confirmed finding is fixed except PIPB-06 test 1's B24 bound (I9).

What changed for the owner:

- Camera: SPEC 13.3 row 13's second sentence now reaches the menu, Diagnostics and onboarding, timed from losing the device; the "Daylight is not running" card after Quit no longer depends on undocumented CMIO cleanup (the host stops the sink on Quit, the extension stops it when the host's client disconnects); a packaging mistake no longer crash-loops the extension (the charter's item 6 decision: log a fault and keep running with built-in UUIDs pinned by a test).
- Pipeline: unplugging the webcam in use falls back to another present camera at once (round-1 app-04 only handled a plug-in); a viewer that starts while the camera is off, lost or not authorized gets the cream card instead of no frame; Settings "Layout when engaging" reaches the governor; a capture restart never pushes a raw frame that is not zero-copy eligible, nor one while the board is up.
- Ink and server: a tablet demoted mid-stroke can still finish its stroke (the board returns); an Allow clicked after the tablet's socket closed is remembered; closed connections are freed; a web page from another site in a browser on the Mac can no longer connect over loopback without the Allow panel (Origin rule, PROTOCOL 8); a malformed first HANDSHAKE gets ACK 3 and 1002 (PROTOCOL 9); the governor's late Clear effects no longer wipe a stroke drawn right after a Clear.
- Web: strokes the offline ring drops leave the page too, and after a Mac relaunch the tablet keeps the strokes the Mac holds (newest-end alignment); a stale STATE after an Undo is recognised; a dead socket is given up after 25 s of silence with an unanswered PING, so ink is ringed instead of lost; a second drop inside one contact restarts the stroke (G3 closed).
- App: onboarding "Done" stops its 1 s poll (and its 5 s `adb devices`); the menu's red line clears when its problem is fixed; one Daylight runs at a time; a new save folder applies to the next save; the hotkey recorder names every key.
- Governor (SPEC D54 to D56): an explicit request that brings the board up releases Hold: Camera; engage or Hold: Auto during the pre-warning cancels it; snap-back applies only to a board a stroke brought up.
- Tests: 12 hosted-test timing assumptions became condition waits (the e524f5b flake class, a mid-animation pixel probe, Playwright fixed waits); the self-test and the loopback test use a PING/PONG ordering barrier; the self-test asserts the bundled web build, adb architectures, scrcpy-server and APK under `CI=true`; SPEC C3's extension rules are finally exercised by tests.

CI: runs 37151145122 (push) and 37151813557 (workflow_dispatch) on 58d140e, the branch tip containing every round-2 change, are both green in every job; run 37149014837 on 200667a was the first green run of the round, every job (golden, kit-linux, web, android, mac with `make mac-test` and `make mac-smoke`); the earlier red runs of the round and the final confirmation runs are listed at the end of `docs/handoff/vp-review-2.md`.

Lessons:

- Two lenses per area paid off: the duplicates (PIPA-01/PIPB-02, PIPA-02/PIPB-01, CAMB-03/TSTA-01) were found independently, and each lens also found what the other missed.
- A refuter that defaults to "not real" removed six findings, among them one that needed the compiler source to settle (APPA-03).
- `scripts/mac-debug.sh` hides Swift compile errors from the job log; a compile break in another owner's files cost one cycle to locate by reading the code (I7).

---

## 10. Platform phase 2 (2026-10-03)

- adb source (LOOSE_ENDS H1, closed): Settings > Mirror > "adb source" offers "Bundled (default)", "Download on first use" (Google's Android SDK License once, then platform-tools 37.0.0 from dl.google.com, SHA-256 checked before unpacking and before every use, kept in `~/Library/Application Support/Daylight/platform-tools`, offline afterwards) and "Use installed adb" (PATH, Homebrew, Android Studio; platform-tools 35 or newer). Diagnostics prints `mirror.adb.source`, `mirror.adb.path`, `mirror.adb.version`; failure rows 39 to 43; `make fetch-tools mac-generate mac-debug DAYLIGHT_BUNDLE_ADB=0` builds without the bundled adb. A new source applies at once since hardening round 3 (7b3e53b). Proved by run 37150435613 (every job green).
- macOS 26 (LOOSE_ENDS H2, closed): a non-blocking `mac-26` job runs the whole mac pipeline on macos-26 and was green in runs 37149301627 and 37150435613.
- CI: `make mac-debug` now prints Swift compile errors into the job log (LOOSE_ENDS I7 a). The one red run of the phase on shared files was the `Settings` name clash between SwiftUI and DaylightKit in the new Settings view (run 37149873273, fixed in 9790133). `StylusWatcherTests.testProbeFindsThePenNodeAndStreamsIt` raced once (run 37149301627, Mirror v2's file; request in the Platform handoff).
- Owner checks: TESTING-CHECKLIST 4.19 to 4.21; SETUP 2.3 "adb source".

---

## 11. Phase 2 integration (2026-10-03)

The integrator read the three phase 2 handoffs (`docs/handoff/vp-platform.md`, `vp-mirror-v2.md`, `vp-review-2.md`), checked every acceptance claim against the code and the CI logs of run 37152400371 (e1ee58c, every job green), ran what runs on Linux, fixed what was small, and recorded the rest in LOOSE_ENDS J.

### What each VP delivered

- Platform: the adb source (Settings > Mirror > "adb source": "Bundled (default)", "Download on first use", "Use installed adb"; `AdbClientSources.swift`; rows 39 to 43; Diagnostics `mirror.adb.source`, `mirror.adb.path`, `mirror.adb.version`; the `DAYLIGHT_BUNDLE_ADB=0` build switch) and the non-blocking `mac-26` job; compile errors in the job log.
- Mirror v2: the Wi-Fi mirror transport (LOOSE_ENDS A9). Daylight Ink shares its screen with MediaProjection and MediaCodec H.264 from a mediaProjection foreground service; the Mac's `WifiMirrorSource` conforms to `MirrorFrameSource`, engages by frame differencing (or by the USB pen stream when present); PROTOCOL 14 (MIRROR_HELLO 0x0080, MIRROR_PACKET 0x0081, MIRROR_STATUS 0x0082, MIRROR_CONTROL 0x0071) with ten `mirror_cases` golden vectors; rows 34 to 38; Settings > Mirror > "Transport"; a self-test probe.
- Review 2: 57 findings, 47 distinct confirmed and fixed across camera, pipeline, ink router and server, web, app core and governor, each with a test; no `fatalError` left in the camera extension.

### What the integrator verified (and how)

- CI: run 37152400371 on e1ee58c, six jobs green. Counted in the logs: 320 DaylightKit tests (`[320/320]` in the mac job's kit-test), 261 hosted `DaylightTests` with 0 failures, `self-test: PASS`, 143 Android JVM tests, 32 scripts-check checks; locally 28 Node and 58 Playwright web tests, `make golden-check` (four copies identical) and `make scripts-check` (32 passed).
- adb source: `AdbClient.locateExecutable(vendorDirectory:)` keeps its signature and resolves the persisted `adbSource` through `AdbSourceRequest` (`Mirror/AdbClient.swift` 76 to 115); Diagnostics merges `AdbSourceStatus.diagnostics()` as `mirror.adb.*` (`App/Diagnostics.swift` 26 and 56); `locateBundled` is the old body; 19 `AdbClientSourcesTests` and 6 `AdbSourceSettingsTests` ran green.
- macOS 26: the `mac-26` job exists in both workflows with `runs-on: macos-26` and `continue-on-error: true`; it ran every step green on Xcode 26.6, Swift 6.3.3. The two workflows differ only in the header comment, the name, the `main` branch, the path filters and `working-directory` (diff after stripping the `whiteboard-camera/` prefix).
- Wi-Fi mirror: the Android side (`mirror/ScreenStreamService.kt` with `foregroundServiceType="mediaProjection"`, `ScreenEncoder.kt` with MediaCodec and an input surface, `ConsentActivity.kt` with `createScreenCaptureIntent`), the Mac side (`WifiMirrorSource: MirrorFrameSource`, `FrameDiffEngage` from the Kit, the "Transport" picker with "USB (adb)" and "Wi-Fi (Daylight Ink screen stream)"), PROTOCOL 14 and `mirror_cases` (10 cases) in all four golden copies, rows 34 to 38 in SPEC 13.3, `FailureText` and `FailureCoverageTests`; the self-test log shows `ok wifi mirror: MIRROR_CONTROL START after MIRROR_STATUS`, `ok wifi mirror: key frame decoded through the ingest` and `ok wifi mirror: composed frame`.
- Review 2: each of the 18 fix commits carries its test (named in the commit and green in the log, for example `testClientDemotedMidStrokeStillFinishesItsStroke`, `testMalformedFirstHandshakeIsRejectedWithAck3AndClose1002`, `testBuiltInFallbackUUIDsMatchTheExtensionInfoPlist`, `testSecondCopyDecision`); `DaylightCameraExtension/Sources/` has no `fatalError`, `precondition` or `try!`.
- Seams: `FailureText` has 45 cases with distinct rows (1 to 43 plus 12b and 28b), every one in SPEC 13.3 with the same sentence, and `FailureCoverageTests` asserts 45. The Settings keys of the two VPs (`adbSource`, `adbTermsAcceptedVersion`; `mirrorTransport`, `mirrorStream*`, `mirrorDiffThreshold`) are distinct in `CodingKeys` and SPEC 11; the "Settings clash" of 9790133 was the SwiftUI `Settings` scene name against `DaylightKit.Settings` in one view, qualified there, and nothing else in the tree is ambiguous (the build is green on Xcode 16.4 and 26.6). The Wi-Fi source peels the mirror family off `server.onInkMessage` before `InkRouter.handle`, sends START only to allowed `ink`, `overlay` or `test` connections, and posts `penContact` events through the same `pipeline.post` path as USB; Review 2's router changes (the active-source guard for open strokes, the Origin rule, `applyGovernorEffect` ignoring the late Clear effects) leave that path untouched, and the governor's snap-back only reacts to `cancel`, which the mirror never sends. A transport change re-points the pipeline (`AppDelegate.applySettings`).

### What did not hold, and what the integrator corrected

| Finding | Where | Fix |
|---|---|---|
| A Download or Installed adb failure reached the owner only as Diagnostics `mirror.status: error: The screen mirror could not start: launchFailed("...")` (a Swift enum description, and no menu line); the controller read the source from UserDefaults instead of its own settings | `Mirror/MirrorController.swift` `ensureAdb` (Platform request 1 a, not picked up by Mirror v2) | 068215c: `ensureAdb` resolves `AdbSourceRequest(settings:vendorDirectory:)`, raises row 39 to 43 through `onFailure` (the menu's red line) and puts the row's sentence inside row 25 in the status; Bundled missing keeps row 25's wording; `testAdbSourceFailureRaisesItsOwnRowAndAReadableStatus` |
| The Mirror tab is taller than the fixed 560 by 520 Settings window since phase 2, so its first rows ("Transport", the first step of Session 4b) could be clipped | `Settings/SettingsWindow.swift` `mirrorTab` (Platform request 4) | 7250886: the tab's Form sits in a ScrollView. Compile-checked only; no hosted test can see a SwiftUI tab's layout, so the owner's look at the tab is the check (LOOSE_ENDS J1) |
| `StylusWatcherTests.testProbeFindsThePenNodeAndStreamsIt` read the transition count when the gesture fired, before the sixth transition was appended (red in run 37149301627) | `DaylightTests/Mirror/StylusWatcherTests.swift` (Platform request 3, open) | f2f8e79: waits for the sixth transition too; the assertions are unchanged |
| The web side never read the PROTOCOL 14 vectors of its golden copy | `web/tests/unit/protocol.test.ts` | 070deaf: the page decodes every s2c MIRROR_CONTROL case to `{ opcode }` alone and the mirror opcodes stay unknown to it |
| OWNER-NEXT-STEPS named neither the Wi-Fi transport nor the adb source; COMPARE section 2 said mirror always needs USB debugging; TESTING-CHECKLIST still said five sessions; ARCHITECTURE 18 lacked the phase 2 files | docs | 0b537c4: Step 4b and the adb source note, COMPARE section 2 and the SPEC 17 row, SETUP's distinction between the Wi-Fi transport and "Mirror over Wi-Fi after a USB session", ARCHITECTURE 18 file lists. Every menu and settings string quoted there was found verbatim in the code |
| Mirror v2's handoff counts are one high per Kit and hosted class: MirrorStreamTests 14 (not 15), FrameDiffEngageTests 18 (not 19), LumaGridTests 10 (not 11), WifiMirrorSourceTests 13 (not 14) | `docs/handoff/vp-mirror-v2.md` section 2 | recorded (J4); the tests exist and pass |

### CI after the integration

Run 37155240617 on 070deaf: golden, web, android, kit-linux and mac-26 green; in the mac job `make kit-test`, `make mac-debug`, `make mac-test` (with the new test) and `make mac-smoke` (`self-test: PASS`) were green, and then the "Signed and notarized build" step went red with `mac-release: ERROR: some signing secrets are set (or HAS_SIGNING=true) but these are missing or misnamed: DAYLIGHT_DEVELOPER_ID_P12_BASE64 DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64`. Between run 37152400371 (20:48 UTC, all secrets absent) and this run (21:37 UTC) the repository gained `DAYLIGHT_TEAM_ID`, `DAYLIGHT_DEVELOPER_ID_P12_PASSWORD`, `ASC_API_KEY_ID` and `ASC_API_ISSUER_ID`; the gate (LOOSE_ENDS G9) turns a partial set red on purpose. It is the owner's signing in progress, not a code fault: adding the remaining secrets (`DAYLIGHT_DEVELOPER_ID_P12_BASE64` and `DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64`, plus `DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64` for the extension and `ASC_API_PRIVATE_KEY_BASE64` for notarization) makes the step sign, and `docs/SIGNING.md` "Every failure and its remedy" has the row (LOOSE_ENDS J9). Run 37155763919 on 0b537c4 (every code and docs fix of the pass): golden, web, android, kit-linux green; the mac job green through `make mac-test` (262 hosted tests, including `testAdbSourceFailureRaisesItsOwnRowAndAReadableStatus` and the repaired `testProbeFindsThePenNodeAndStreamsIt`) and `make mac-smoke` (`self-test: PASS`), then the same signing gate; the non-blocking `mac-26` leg hit the known cold-GPU bound of `PipelineSmokeTests.testEngageReachesLiveAndComposedFramesFlow` (7 skipped ticks against at most 2, LOOSE_ENDS I9; the steady-state assertions after it passed, and the same test passed on macos-15 in the same run and on macos-26 in run 37155240617). The assertion stays as it is. Run 37156432987 on 9c1ed61 (this section): the same picture, with `mac-26` green again; LOOSE_ENDS J9 keeps the list.

### Still unverified until hardware

Everything in LOOSE_ENDS D19 to D23 (consent wording and lock behaviour, the frame-difference engage delay and false engages, the DC-1 encoder's repeat frames, the background consent notification, battery and heat), the adb source paths on the owner's Mac (TESTING-CHECKLIST 4.19 to 4.21: a downloaded adb launched from Application Support by a notarized app, an installed Homebrew adb), the Mirror tab layout, the `DAYLIGHT_BUNDLE_ADB=0` build (no CI job builds it), and every item of LOOSE_ENDS I.

## 12. Presenter Overlay (phase 3, 2026-10-03)

Overlay mode (LOOSE_ENDS A11) is built and off by default: Settings > Overlay > "Enable overlay mode". With it off, nothing changes: no controller, no queue, no Vision, no menu item, no hotkey, and the passthrough `perf` line is byte-identical. SPEC 6.7 has the geometry, SPEC 11 the eight `overlay*` keys, SPEC 13.3 rows 48 and 49, and D57 the decisions. Vision person segmentation runs on its own serial queue (`VNGeneratePersonSegmentationRequest`, Fast by default), dropping a frame rather than queueing it. Metal applies IIR smoothing and a separable feather blur. The compositor draws the cutout as a fourth step. After 15 failed segmentations the picture falls back to Studio Split; on low coverage it shows the plain camera rectangle. Details, tests and requests are in `docs/handoff/vp-overlay.md`.

CI: in run 37159468412 on 46db978, the mac-26 leg was green through `make mac-test`: the hosted overlay suites (OverlayCompositorTests, MaskProcessorTests, OverlayControllerTests, OverlayPipelineTests, OverlayAppModelTests, HotkeysTests with the overlay case, FailureCoverageTests at 51) all passed. It was also green through `make mac-smoke`: every `overlay` self-test probe was ok, the Vision probe returned a real 256x192 mask, and the run ended with `self-test: PASS`. Golden, web, android and kit-linux were green too. The macos-15 mac job stopped at `make mac-debug`, on `App/Export/ZipArchive.swift:44` ("unable to type-check this expression in reasonable time" on Xcode 16.4). That file belongs to the Diagnostics VP, not this feature. After their fix, run 37160970105 on c32357b was green on all six jobs. In the macos-15 `mac` job the same overlay suites and probes passed, and the run ended with `self-test: PASS`. The overlay code is unverified on device until TESTING-CHECKLIST session 6 (LOOSE_ENDS E29 to E31).

## Review round 3: hardening of the phase 2 mirror code (2026-10-03)

The hardening VP ran an adversarial round over what phase 2 added in the mirror area: twelve finders (two lenses per sub-area: adb sources, the USB path after the transport switch, Wi-Fi demux and decode, frame-difference engage, the Android stream service, PROTOCOL 14 parity), six refuters defaulting to "not real", six managers fixing what held, each fix with a test that fails before it. `docs/handoff/vp-hardening-3.md` has every finding, verdict, commit and test; LOOSE_ENDS R3 holds what stays open.

Counts: 62 findings, 46 distinct after merging, 35 confirmed (2 high), 6 plausible (each guarded), 3 rejected, 2 duplicates of known loose ends. All confirmed items are fixed in code with tests except one App request and one new failure row (R3-1, R3-3).

What changed for the owner:
- Wi-Fi mirror: tapping Cancel on the tablet's prompt (or Stop in its notification) and then "Share screen with your Mac" now streams at once; before, both ends waited for each other forever (W1, fixed on both ends). Row 34 now points at that button.
- Frame-difference engage now engages on handwriting: the old sampler read one pixel per cell and could not see a 2 to 4 px stroke (DIFF-A1). It pools 8x8 px cells and sums a run against a baseline; a Python model of the Swift code engaged on 216 of 216 synthetic strokes within 0.53 s and on none of the cursor, clock and codec-noise cases. Device measurement is LOOSE_ENDS D20 and R3-5.
- Wi-Fi decode errors recover (key frame request, then a stream restart after 12 s, row 27), a rejected HELLO no longer takes over, the tablet drops dependent frames after a back-pressure drop, and leaving Daylight Ink's Settings while sharing keeps the socket.
- adb source: a new source applies at once (J2); "not downloaded yet" no longer claims a network error; a tampered download is deleted; Settings keeps the way to the terms.
- Quit sends RELEASE and waits up to 0.3 s for it (J3); settings from a newer build no longer reset everything on a downgrade (J5).
- CI: the cold-GPU bound of the engage smoke test is a condition and a time bound (I9); the mirror tests wait on conditions (I8), and the pen watcher reports watching only once getevent runs.

CI: run https://github.com/12twelve12hi/daylight-control-your-mac/actions/runs/37158885096 (7bb9dc6, J2 to I9) and run https://github.com/12twelve12hi/daylight-control-your-mac/actions/runs/37160970105 (c32357b, every fix of the round): golden, web, android, kit-linux, mac and mac-26 green; the mac job ran 364 of 364 Kit tests, every hosted test passed (each new test of the round found by name in the log) and `self-test: PASS`. Two reds on the way were not this round's code: `OverlaySettingsTests` (run 37159402591, fixed by its owner in 46db978) and `App/Export/ZipArchive.swift:44` type-check time (runs 37159468412, 37160202127, fixed by its owner before c32357b). One was: `LumaGridTests` hit the type checker's time limit on kit-linux (run 37160015702), fixed in 28b61d1. Acceptance: two consecutive green runs on bb5e439 (the branch head carrying this round's last docs commit bcb1d38): push run https://github.com/12twelve12hi/daylight-control-your-mac/actions/runs/37161767621 and workflow_dispatch run https://github.com/12twelve12hi/daylight-control-your-mac/actions/runs/37162231668, golden, web, android, kit-linux, mac and mac-26 green in both.

Still unverified until hardware: frame-difference engage on the DC-1 (delay, false engages, sampler cost, encoder noise), the double consent grant and the STOP inside the encoder's configure window on the tablet, the J3 flush on a real quit.

## 13. Diagnostics export and tablet facts (phase 3, 2026-10-03)

One click on the Mac (menu bar > "Export diagnostics...") writes `~/Documents/Daylight Camera/diagnostics-<yyyy-MM-dd-HH-mm>.zip` and reveals it: `MANIFEST.txt`, `diagnostics.txt`, `system.txt`, `settings.json`, `unified-log.txt` (2000 lines of `log show` for com.twelve.daylight, last 2 h), `extension-status.txt`, `self-test.txt` (optional, child process), `perf-log.txt`, `vendor.txt`, `clients.json`, `tablet-facts.json`. Every part is bounded, one `Redactor` cuts IPs to the last octet, SSIDs, tokens and paths outside the app's folders, and SPEC 13.3 rows 44 to 47 report progress, success, a missing part and failure. The web page and Daylight Ink each gained "Send facts to Mac", which posts PROTOCOL 15 JSON to the Mac's new `POST /api/facts`; the Mac keeps the latest facts per sender in memory and in the export. `docs/FEEDBACK.md` tells the owner how to send the zip and maps LOOSE_ENDS D1 to D23 to files and keys; TESTING-CHECKLIST no longer asks for pasted lines.

Tests: Kit `FailureTextTests` (49 cases, rows 44 to 47 exact); hosted `ZipArchiveTests`, `RedactorTests`, `TabletFactsStoreTests`, `DiagnosticsExportTests` (zip from fakes reads back, MANIFEST sizes exact, `unzip -t` and `ditto -x -k` accept it, redaction, 4 MiB log cap, rows 46 and 47, file name stamp), `FactsRouteTests` and `FactsLoopbackTests` (every PROTOCOL 15.2 status, eviction at 17, a real loopback POST); the self-test's export probe (mac-smoke); web `tests/unit/facts.test.ts` and `tests/facts.spec.ts` against the Node fake Mac; Android `SettingsFactsTest` (12 cases).

CI: run 37160970105 on c32357b green in golden, web, android, kit-linux, mac (`make mac-test`, `make mac-smoke`) and mac-26. Open items: LOOSE_ENDS K1 to K5; details in `docs/handoff/vp-diagnostics.md`.

## 14. Phase 3 integration (2026-10-04)

The integrator read the three phase 3 handoffs (`docs/handoff/vp-overlay.md`, `vp-diagnostics.md`, `vp-hardening-3.md`) with the phase 2 ones for context, checked every acceptance claim against the code and the CI logs of run 37162231668 (bb5e439, every job green), ran what runs on Linux, fixed what was small, and recorded the rest in LOOSE_ENDS P3.

### What was verified, and how

- CI logs of run 37162231668, mac job: 364 of 364 DaylightKit tests (`[364/364]`), 346 hosted `DaylightTests` with 346 passed and none failed (`** TEST SUCCEEDED **`), `self-test: PASS`, and the signing step's `::warning::` naming `DAYLIGHT_DEVELOPER_ID_P12_BASE64` and `DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64` (exit 0, expected). Android job: 173 JVM tests passed, among them `SettingsFactsTest` 12, `HolderRolesTest` 6, `MirrorSessionTest` 38, `MirrorBackpressureTest` 10, `SourceRulesTest` 14, `LinkTest` 15, `ManifestTest` 7 (the hardening handoff's numbers hold exactly). Locally: 36 Node and 60 Playwright web tests, `make golden-check` (four copies identical), `make scripts-check` (45 passed).
- Overlay is off by default and invisible: `Settings.overlayEnabled = false`; the menu adds "Whiteboard now (Overlay)" only under `if model.settings.overlayEnabled` (`App/MenuBar.swift`); "Layout when engaging" offers "Overlay" only while enabled (`Settings/SettingsWindow.swift`); the Hotkeys tab and the onboarding hotkey list filter `.overlay` out while disabled; `Hotkeys.setOverlayEnabled` registers Ctrl+Opt+Cmd+O only while enabled and `Hotkeys` drops the action otherwise; `GovernorConfig` maps a stored Overlay layout to Studio Split while disabled; `FramePipeline.applyOverlaySetting` creates no controller while disabled. Tests by name in the log: `HotkeysTests.testOverlayHotkeyOnlyWhileOverlayIsEnabled`, `OverlayPipelineTests.testNoControllerWhileTheSettingIsOff`, `testStudioSplitWithTheControllerNeverOffers`, `testOverlayPerfLineOnlyWithAController`, Kit `OverlaySettingsTests` (7).
- Passthrough with Overlay off: the self-test's passthrough line is byte-identical to phase 2's run 37152400371 (`perf mode=passthrough fps=0.0 dropped=0 cpu_ms=0.000 gpu_ms=0.000 inflight=0 zerocopy=true capture=idle viewers=0`), no `perf overlay` line appears without a controller, and the render probes match (s=1 GPU 1.465 ms against 1.498 ms; the s=0 first command buffer 109 ms against 151 ms, cold). The runner has no camera, so the line counts no frames (LOOSE_ENDS P3-4).
- Vision fallback: `MaskProcessor` wraps the mask through `CVMetalTextureCache` and falls back to one r8 copy logged once (`testVisionShapedBuffersTakeTheCacheOrTheCopyPath`); 15 failures latch Studio Split with one row 48 (`testFifteenFailuresFallBackWithExactlyOneRow48`, `testOverlayFallbackRendersStudioSplitAndReportsRow48`); low coverage or a stale mask shows the rectangle (`testAMaskGivesTheMatteAndAnEmptyOneTheRectangle`). The self-test's overlay probes all print `ok` (s=0 equals the camera picture, matte, clear, paper, amber halo, mask processing plus encode 1.33 ms under 50 ms, IIR plus blur within 0.0005 of the Kit), and the Vision probe returned a real 256x192 mask on macos-15.
- Diagnostics export: `DiagnosticsExportTests` (9) build the zip from fakes and read it back, check MANIFEST sizes, `unzip -t` and `ditto -x -k`, redaction, the 10 MiB log cut to its cap, rows 46 and 47 and the file name; `ZipArchiveTests` (4), `RedactorTests` (3), `TabletFactsStoreTests` (2), `FactsRouteTests` (4) and `FactsLoopbackTests` (2) passed. The self-test's export probe printed `ok export: POST /api/facts stores the sender (status 200)`, `zip written ... 9 files, 105369 bytes in 1.9 s`, `zip reads back (9 entries, CRC-32 checked)`, `tablet-facts.json holds the sender, address cut to the last octet` and `rows 44 and 45 raised`. `POST /api/facts` lives in `Server/ApiRoutes.swift` and `WebServer.swift`; PROTOCOL 15 exists (15.1 to 15.3). "Send facts to Mac" is in `web/src/main.ts` with the four result lines in `web/src/facts.ts`, and in Daylight Ink's `ui/SettingsFacts.kt` with the same four plus "Connect to your Mac first." and "Sending to your Mac."; `docs/FEEDBACK.md` names the files and keys `DiagnosticsExporter` writes.
- Hardening round 3: every test the handoff names was found by name, passed, in the logs (49 Swift test names across the Kit and hosted lists, plus `SettingsLenientDecodingTests` (3); the handoff's `testASlowThinStroke` is `testASlowThinStrokeEngages`). J2 (`MirrorController.adbSourceChanged`), J3 (`WifiMirrorSource.release(timeout:)` called from `AppDelegate` through `releaseWifiStream`), J5 (`Settings.lenient` on all seven enum keys plus `lenientHotkeys`), I8 (`StylusWatcher` reports `.watching` after the child runs) and I9 (the GPU warm-up and the 2.5 s cold bound in `PipelineSmokeTests`) match the code. The two acceptance runs 37161767621 and 37162231668 (bb5e439) are green in all six jobs.

### Seams between the VPs

- `AppDelegate.swift`: the Overlay VP added only the onboarding hotkey filter; the Diagnostics VP added the export controller, the menu hook and the facts store wiring. The menu has every phase 2 item plus "Whiteboard now (Overlay)" (while enabled) and "Export diagnostics..." between "Diagnostics..." and "Setup again"; nothing was lost (diff against e1ee58c).
- `SettingsWindow.swift`: tabs General, Hotkeys, Network, Mirror, Overlay, Saving, Advanced, Diagnostics; the Overlay tab scrolls like the Mirror tab; no earlier control changed except the frame-diff threshold label (hardening round 3).
- FailureText: 51 cases with 51 distinct rows (1 to 49 plus 12b and 28b); rows 44 to 49 carry the same owner sentence and log line in SPEC 13.3; `FailureCoverageTests.testFiftyOneCasesAndTheRowsBTriggers` asserts 51.
- Android: the Diagnostics VP's four lines in `ui/SettingsActivity.kt` use `conn.phase` and `conn.currentUrl`; the hardening round changed `net/HolderRoles.kt`, `InkConnection.kt` and the mirror classes, not `SettingsActivity.kt`; the two do not overlap.
- Self-test: the overlay probes and the export probe both run in the same `mac-smoke` (log above).
- Workflows: the two files differ only in the header, the name, `main`, the path filters and `working-directory`, plus one comment, aligned in dabbbd8.

### What did not hold, and what the integrator corrected

| Finding | Where | Fix |
|---|---|---|
| 411 and 415 went out as `411 Unknown` and `415 Unknown` (K2) | `DaylightKit/HTTP/HTTPRequest.swift` | 017d9a2, `HTTPRequestTests` asserts both |
| Three integrator requests left open by the VPs: row 37 never withdrawn (DIFF-B4), a transport switch could save the wrong board (USB-A2/B3), the Overlay hotkey conflict text not refreshed on the toggle (VP Overlay request 1) | `App/AppDelegate.swift` `wireMirror`, `applySettings` | e69b84b (compile-checked; LOOSE_ENDS P3-1) |
| The Perf log toggle claimed the unified log (K3); PERFORMANCE did not know `mode=overlay` or the `perf overlay` line | `Settings/SettingsWindow.swift`, `docs/PERFORMANCE.md`, `docs/SETUP.md` | bfb9ab8 |
| OWNER-NEXT-STEPS still asked to paste and copy lines into LOOSE_ENDS and never named "Export diagnostics..." or "Send facts to Mac"; SETUP named neither nor Overlay; COMPARE 4.8 said "facts to paste"; TESTING-CHECKLIST 1.4 listed the menu without "Export diagnostics..." and 6.11 asked to copy perf lines; FEEDBACK did not cover Overlay | owner docs | 425ee27 (OWNER-NEXT-STEPS step 9, SETUP's Overlay table and section 7, COMPARE 3.1 and 4.8, checklist 1.4 and 6.11, FEEDBACK 5); every quoted string grep-verified in the code |
| TESTING-CHECKLIST 4.19 to 4.21 still asked for a relaunch after an adb source change (J2 applies at once) | `docs/TESTING-CHECKLIST.md` | the docs commit of this section |
| `docs/handoff/vp-platform.md` named a model outside a commit trailer | handoff | the docs commit of this section |
| Handoff details that were off but harmless: the Overlay handoff lists OverlayControllerTests cases that are three tests (each covers several), STATUS 13 counts 49 Kit FailureText cases (51 since Overlay) | handoffs | recorded here |

New owner page: `docs/WHATS-NEW.md` (phase 2 and phase 3 features with the exact menu and setting names and their checklist rows, and the two steps that are still the owner's).

### CI after the integration

Run https://github.com/12twelve12hi/daylight-control-your-mac/actions/runs/37163486060 on dabbbd8 (the four code and docs fixes above): golden, web, android, kit-linux, mac and mac-26 green. In the mac job `make kit-test` ran 364 of 364 (with the extended `HTTPRequestTests.testStatusTextAndResponse`), `make mac-debug` compiled the `AppDelegate` and Settings changes on Xcode 16.4 (and 26.6 in mac-26), `make mac-test` printed `** TEST SUCCEEDED **` with 345 passed lines and none failed (the 346th, `WebServerLoopbackTests.testTwoMiBFrameClosesWith1009`, started and its suite passed; its result line was dropped by the log filter), `make mac-smoke` ended with the same passthrough `perf` line and `self-test: PASS`, and the signing step warned and exited 0. The docs commit of this section is proved by the run of `git log -1 -- docs/STATUS.md`.

## 15. The "too small" problem: share window and follow the pen (2026-10-04)

`docs/product/TOO-SMALL.md` is the research (tile sizes and stream resolutions per call app, the content track, every lever scored, the ranked proposal); `docs/handoff/vp-too-small.md` is the handoff with the patch proposal for the second camera device.

| What | State | Proved by |
|---|---|---|
| Share window "Daylight Whiteboard": the page only (the two ink layers composed like `daylight_canvas`, or the mirror picture), canvas aspect, redrawn only on change (SH1), 85 % of the screen (SH2), menu bar > "Share the whiteboard", Settings > Share, `share:` self-test probes | built | mac job: `mac-test` (`ShareRendererTests`, `ShareWindowTests`, `ShareSettingsTests`, `ShareMenuTests`), `mac-smoke` (`share:` and `follow:` lines) |
| Follow the pen: `FollowRegion` and `FollowCamera` in DaylightKit (FP1 to FP9, hysteresis) | math built, not wired into the compositor | kit-linux and mac `kit-test` (`FollowRegionTests`, green in run 37179989574 on kit-linux) |
| Second camera device "Daylight Whiteboard (share)" for Zoom "Second camera", Meet "Present content from camera", Teams "Content from camera" | scoped: patch proposal in the handoff; the extension belongs to the Review 4 team tonight | none yet |
| PostEvent automation of the call app's share shortcut | not built (one saved click for a permission prompt; TOO-SMALL.md section 10) | none |

Run 37180339019 (head ea26915, which contains 8caff9d) proved it on macos-15: the 13 hosted `Share*Tests` passed in `make mac-test`, `make mac-smoke` printed `share:` and `follow:` probes all ok and `self-test: PASS`, and mac-26 was green. Its non-blocking UI suite failed only on the four assertions that already failed before the Share commits (Overlay popups, Advanced cut off, Diagnostics log; run 37179989574); the new Share tab and the "Share the whiteboard" submenu assertions raised nothing.

Nothing here has run on the owner's Mac. The share window works on the unsigned build (it needs no camera extension); OWNER-NEXT-STEPS step 8c is the owner run.

## Review round 4: phase 3 code and protocol fuzz parity (2026-10-04)

Full record: `docs/handoff/vp-review-4.md`. Acceptance run 37181016158 (2c2a847): golden (with `make fuzz-check`), web, kit-linux, android, mac and mac-26 all green.

- **Presenter Overlay**: confirmed and fixed OV-1 (no Vision work while the fallback is latched), OV-2 (row 48 once on a creation failure), OV-3 (the mask texture cache is flushed), OV-4 (no blend with a history older than 0.5 s) and OV-6 (a creation failure at launch still reaches row 48). OV-5 (the menu keeps row 48 after a quality change) is a request to the Mac UI VP. OV-7 and OV-8 are by design.
- **Diagnostics export and `/api/facts`**: fixed WF-1 (stale result line on a resend), AF-1 (10 s head deadline), AF-2 (413 for an overflowing Content-Length), AF-3 (no control characters from a posted key in logs), DX-1 and DX-3 (IPv6 after `web:` and before `:` is redacted), DX-2 ("killed by signal N"), DX-4 (only UUID-shaped posted ids are rewritten) and DX-5 (no truncated zip after a failed write). DX-6 (self-test output is lost on a hang because stdout is buffered) is a request to the Mac UI VP.
- **Fuzz parity**: `protocol/fuzz/` holds a seeded generator, a 761-case corpus and three harnesses (TypeScript, DaylightKit, Kotlin). `make fuzz-corpus` regenerates it; `make fuzz-check` runs in the golden job. Fixed FZ-1 (1 MiB cap, TypeScript), FZ-2 (non-UTF-8 names, Swift) and FZ-4 (STATE enums out of range, TypeScript and Swift). PROTOCOL 9 and 10 record the rules. Kotlin FZ-1, FZ-3, FZ-4 and FZ-5 are pinned as expected failures, with precise requests to the android owner.
- **Open**: CI-1, a single mac-26 crash in `PipelineSmokeTests.testMirrorSourceIsComposedWhenSelected` (run 37179989574). It did not recur in two later runs. The test now reports state instead of crashing, and the crash frame needs the run's artifact (LOOSE_ENDS R4-5).

## Emulator: Daylight Ink on an emulated DC-1 (phase 4, 2026-10-04)

The new CI job `android-emulator` installs the debug APK and a test APK on an emulated Android 13 tablet (API 33 `google_apis` x86_64, forced to the DC-1's 1200x1600 at 200 dpi), runs 25 instrumented tests, kills and restores the app process, and uploads every screen as the artifact `android-screenshots` (`docs/SCREENSHOTS.md`). Details: `docs/handoff/vp-emulator.md`.

- **What it found:** the APK crashed on every launch on Android 13 (EM-1, `EdgeToEdge` before `setContentView`), and the whiteboard canvas was 0 px tall (EM-2, `Toolbar` layout). Four smaller defects followed: buttons invisible to accessibility, ink lost on rotation, strokes lost on recreate, and a stray service start crashing. All six are fixed, each with a test.
- **Why nothing caught them before:** the android job builds the APK and runs JVM tests; nothing had ever launched it.
- **What still needs the DC-1:** the pen hardware (tool type, pressure, side button, hover), SolOS dialogs and status bar, the front-buffer renderer on SolOS, and the LivePaper transflective LCD.
- **Checklist:** rows 3.2, 3.3, 3.6, 3.17, 4b.1 and 4b.12 are marked "proved in CI, confirm on device".

Runs of the job that finished (cancelled runs do not count). Promoted to blocking after the three green runs in a row marked below:

| Run | Commit | Job | Result |
|---|---|---|---|
| 37181876257 | 238ac9c | 111375916311 | green: `OK (25 tests)`, 12 screenshots, process-death check passed |
| 37182541606 | afaed7d | 111377836433 | green |
| 37182692894 | cdab9e7 | 111378272816 | red: a system dialog held focus (an ANR trace on the device, none of the app), 19 of 25 tests failed at once; fixed in 5874bbf (the script closes system dialogs) and 742d056 (the tests require window focus first) |
| 37183448543 | 5874bbf | 111380456579 | green, streak 1 |
| 37183673841 | b121134 | 111381109320 | green, streak 2 |
| 37184526410 | 5302551 | 111383580460 | green, streak 3: `continue-on-error` removed from both workflows |
