# Handoff: component E, Android app and overlay (Daylight Ink)

Owner of this file: the Android agent. Paths owned: `android/**` except `android/app/src/test/resources/solstream-v1.json` (generated), `android/gradle/wrapper/**` and `android/gradlew*` (integrator), plus this file. Proven by the `android` CI job (`make android`: `./gradlew --no-daemon :app:testDebugUnitTest :app:assembleDebug`, JDK 17, AGP 8.13.2, Kotlin 2.3.10, Gradle 8.14.5, compileSdk 36, minSdk 30, targetSdk 33, the committed debug keystore).

Writing rules apply: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

---

## 1. What was built

Every Android framework class sits behind a small interface (`Transport`, `InkSink`, `FrameScheduler`, `MotionLike`, `Resolver`, `LinkActions`), so the protocol, the stroke machine, the connection rules, discovery and the chip are plain Kotlin that the JVM tests run without Robolectric. No AppCompat, Material, Compose or lifecycle; Views only, built in code (no layout XML, no `R` references in Kotlin, which is also what lets the sources be type-checked on this box against the API 33 framework jar).

| File (under `app/src/main/kotlin/com/twelve/daylight/ink/`) | Role |
|---|---|
| `protocol/SolStream.kt`, `protocol/Messages.kt` | Kept from M0: the encoder (one 64 KiB little-endian ByteBuffer per connection, UUIDs through a big-endian temporary) and the server-message decoder (ACK, STATE with "read the first 20 bytes", PONG). |
| `ink/StrokeSession.kt` | The SPEC E3 state machine. Input in view pixels, output in canvas units (1200 x 1600) times 32. `delta_ms` from the FIRST point, saturating at 65535; pressure normalised for 0..1 and raw 0..4095; one STROKE_CHUNK per Choreographer frame, or one per MotionEvent with `sendPerEvent`; chunks split at 4096 points; `ACTION_CANCEL` and `FLAG_CANCELED` give STROKE_CANCEL and no COMMIT; a pressure-0 down (the side button in the air) never opens a stroke until a positive sample arrives; OkHttp queue above 256 KiB thins each frame to its newest sample; the eraser sends ERASE_STROKES (radius 12) per sample with the ids it believes it hit and never opens a tool-2 stroke; undo and redo only send UNDO and REDO and wait for STATE depths; a smaller depth from STATE is applied only after our own UNDO or when the Mac's page is empty (a 1 Hz STATE emitted between a START and its COMMIT must not hide a fresh stroke); Clear and New page send CLEAR_CANVAS and PAGE_CHANGE and blank the local list. |
| `ink/PageGeometry.kt`, `ink/LocalStroke.kt`, `ink/Pressure.kt`, `ink/MotionSamples.kt` | The 3:4 letterbox and the canvas-unit mapping; the local stroke model with the hit test; pressure normalisation; "history samples first, then the current one" behind the `MotionLike` interface. |
| `ink/PenInput.kt` | MotionEvent router shared by the two layers: only `TOOL_TYPE_STYLUS` and `TOOL_TYPE_ERASER` draw, fingers and palms are swallowed, hover never reaches the session, `requestUnbufferedDispatch(event)` per stroke (setting `unbufferedInput`), the pointer is tracked by id with `findPointerIndex`, `FLAG_CANCELED` on `ACTION_POINTER_UP` cancels; the first pressure sample and the first side-button press are logged as device facts. |
| `ink/DryInkView.kt` | The dry layer: committed ink in a page-sized Bitmap, `invalidate(Rect)` per segment; stroke width `baseWidth * (0.55 + 0.9 * pressure)` (SPEC 6.6); the highlighter is one Path while wet and is baked once on commit with `BlendMode.MULTIPLY`, so its own joints never darken; redraws replay highlighters first, then pens. |
| `ink/WetInkSurface.kt` | The wet layer: a translucent SurfaceView (`setZOrderOnTop(true)` before attach, `PixelFormat.TRANSLUCENT`) driven by `CanvasFrontBufferedRenderer` (graphics-core 1.0.4) created inside `runCatching`; `requestUnbufferedDispatch(SOURCE_CLASS_POINTER)` in `onAttachedToWindow`; the multi-buffered layer only clears because the dry view below already shows the stroke; `release(cancelPending = true)` on detach. When the renderer is missing (or the `frontBuffer` setting is off) the dry view is the wet view. |
| `ink/InkCanvasLayout.kt` | Letterboxes the page in SolOS cream with a 1.5 dp BorderSubtle line; both layers are laid out exactly on the page, so their coordinates are page coordinates. |
| `net/Candidates.kt` | SPEC 9.3 dial order: Bonjour results (newest first), `127.0.0.1:7788` (alive only under `adb reverse`), the remembered manual host, the `--es host` extra; duplicates collapse; a failed candidate is skipped until every candidate failed once, then the rotation restarts and the caller backs off. `Candidates.url()` accepts `host`, `host:port`, `[v6]:port`, bare v6 and full `ws://` or `http://` strings. |
| `net/Backoff.kt` | 0.5 s doubling to 8 s with 20 percent jitter (PROTOCOL 1). |
| `net/Link.kt` | The connection state machine behind `LinkActions`: dial the next candidate, HANDSHAKE on open with `<role>;<clientId>;<label>`, ACK 0 live, ACK 1 pending (ink gate shut), ACK 2 denied and ACK 3 unsupported stop re-dialling until the chip is tapped, a server that does not echo `Sec-WebSocket-Protocol: solstream.v1` is incompatible (close 1002, no re-dial), a role change re-opens the socket, PING every 10 s with RTT from PONG, failures walk the candidates and back off only when the rotation restarts or after a working session dropped. |
| `net/InkConnection.kt` | The one OkHttp WebSocket of the process, shared by the activity (role `ink`) and the overlay service (role `overlay`) with the same `clientId` from SharedPreferences: `NoDelaySocketFactory` (TCP_NODELAY), `pingInterval(10 s)`, 3 s connect timeout, the subprotocol header, every callback hopped to the main thread, `send()` false triggers a reconnect, `queueSize()` feeds the thinning rule. Holders `acquire(tag, role)` and `release(tag)`; the role is `ink` while any holder is the canvas. |
| `net/Discovery.kt`, `net/DiscoveryQueue.kt` | NsdManager legacy path (`discoverServices`, `resolveService`), type matched with `contains("_daylight-camera._tcp")`, one resolve at a time with `FAILURE_ALREADY_ACTIVE` re-queued at the front, a `MulticastLock` when `SdkExtensions.getExtensionVersion(TIRAMISU) < 7`, try/catch around `stopServiceDiscovery`, IPv6 scope suffix stripped. |
| `net/NoDelaySocketFactory.kt`, `net/Identity.kt` | TCP_NODELAY on every socket; the handshake name with the label clamped to 64 UTF-8 bytes on a code point boundary, semicolons removed, default `Daylight Ink on <Build.MODEL>`. |
| `ui/ChipState.kt`, `ui/Chip.kt`, `ui/PillView.kt` | The SPEC 10 chip as a pure function (same precedence as the web `chip-state.ts`: not allowed, not the active source, pinned, pre-warning countdown with ceil and local 250 ms ticks, Camera, Returning, LIVE) bound to a flat pill view: tap = TOGGLE_PIN -1 (or retry, or "how to switch"), long press 600 ms = AUTO_ENGAGE_RETURN, the amber dot breathes with `0.5 * (1 - cos(2 pi t / 2))`. |
| `ui/Toolbar.kt`, `ui/MainActivity.kt` | Pen, Highlight, Erase, Undo, Redo, the chip, New page, Clear, Settings; undo and redo enabled from STATE depths only; the row scrolls sideways on a dense screen. The activity wires everything, handles `--es host` (remembered as the manual host and dialled at once), keeps the screen on (`FLAG_KEEP_SCREEN_ON` through `EdgeToEdge`), pads only the toolbar for the system bars, and opens the onboarding screen on the first run. |
| `ui/OnboardingActivity.kt` | "Looking for your Mac... Enter its address if this takes long" with a host field (row 30); "Allow display over other apps" with the Android 13 wording ("tap Daylight Ink, switch on Allow display over other apps, press Back", the package URI being ignored on 11+), `ACTION_MANAGE_OVERLAY_PERMISSION` in try/catch; the `POST_NOTIFICATIONS` request; Skip and Start writing. |
| `ui/SettingsActivity.kt` | `frontBuffer`, `unbufferedInput`, `sendPerEvent`, `pillsAtBoot`, `pillsPosition`, manual host, Forget this Mac, Show or Hide the pills, Setup again, and the "This tablet" facts block (section 3). |
| `ui/Texts.kt`, `ui/Tokens.kt`, `ui/EdgeToEdge.kt` | Every owner-facing sentence in one object; the SPEC 3 tokens; platform-only edge to edge. |
| `overlay/OverlayService.kt` | Foreground service (`foregroundServiceType="connectedDevice"`, `startForeground(id, n, FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)` in `onCreate`, a low-importance channel, a programmatic icon) holding ONE `WRAP_CONTENT` `TYPE_APPLICATION_OVERLAY` window with `FLAG_NOT_FOCUSABLE or FLAG_KEEP_SCREEN_ON` through `createDisplayContext(display).createWindowContext(...)`, gravity TOP (or BOTTOM per `--es pills bottom`) and CENTER_HORIZONTAL, y = 24 px, row 48 px: the whole row sits inside the top 96 px strip the Mac crops away. Without `canDrawOverlays` it shows "Allow display over other apps" (row 29) and stops. `ACTION_STOP` hides the pills. |
| `overlay/PillsState.kt`, `overlay/PillsView.kt`, `overlay/BootReceiver.kt` | Labels from STATE (Pin, KEEP when pinned, an amber dot while the board is up, both pills disabled until the Mac accepted us); `PillsLayout` is the pure placement rule; the boot receiver starts the service only when `pillsAtBoot` is on and the permission is granted. |
| `prefs/Prefs.kt`, `Facts.kt` | SPEC 11 tablet keys (`clientId` generated once, `deviceName`, `manualHost`, `frontBuffer`, `unbufferedInput`, `sendPerEvent`, `pillsAtBoot`, `pillsPosition`, `flagHintDismissed`, `onboardingDone`) plus the remembered device facts; `Facts.logOnce` writes the section 3 lines under `DaylightInk.facts`. |

Manifest: nine permissions (INTERNET, ACCESS_NETWORK_STATE, ACCESS_WIFI_STATE, CHANGE_WIFI_MULTICAST_STATE, SYSTEM_ALERT_WINDOW, FOREGROUND_SERVICE, FOREGROUND_SERVICE_CONNECTED_DEVICE, POST_NOTIFICATIONS, RECEIVE_BOOT_COMPLETED), `usesCleartextTraffic="true"` (plain `ws://`, no TLS in v1), `.ui.MainActivity` exported with the LAUNCHER filter and `singleTop`, `.ui.OnboardingActivity` and `.ui.SettingsActivity` not exported, `.overlay.OverlayService` not exported with `foregroundServiceType="connectedDevice"`, `.overlay.BootReceiver` exported with the BOOT_COMPLETED filter.

Tests (`app/src/test/kotlin/com/twelve/daylight/ink/`, 67 JUnit 4 tests): `SolStreamTest` (E2, kept), `StrokeSessionTest` and `StrokeSessionStateTest` (E3 and the depth guard), `CandidatesTest` (E4), `DiscoveryQueueTest`, `LinkTest` (ACK rules, subprotocol rule, backoff values 400 to 9600 ms, identity clamp), `ChipStateTest` (the SPEC 10 table, countdown, breath, pills, the 96 px strip), `ManifestTest` (E5, the manifest parsed as XML), `SourceRulesTest` (E5 and E6 facts that live in Android code, asserted on the source text like the web suite's `touch-action` grep: overlay window type and flags, `requestUnbufferedDispatch` inside `onAttachedToWindow`, stylus-only drawing, `NoDelaySocketFactory` on the client, plus the writing rules for every file under `android/`).

Acceptance mapping (SPEC 16): E1 the `android` job; E2 `SolStreamTest`; E3 `StrokeSessionTest`; E4 `CandidatesTest`; E5 `ManifestTest` plus `SourceRulesTest` plus `ChipStateTest.pillRowSitsInsideTheTop96PixelStrip`; E6 `SourceRulesTest` for the static half, the device for the rest (section 2).

Deviations from the plan text, on purpose:

- No `kotlinx-coroutines-android` dependency: the reconnect loop is a `Handler` on the main looper (`Link` schedules, `InkConnection.dial` posts). One fewer library in a blind build; the behaviour is the same.
- `com.squareup.okhttp3:okhttp-jvm:5.5.0` instead of the `okhttp` coordinate: Gradle module metadata resolves `okhttp` to `okhttp-android`, whose AAR metadata demands compileSdk 37 (beyond AGP 8.13.2's maximum of 36; run 37112754944). The JVM artifact is the same WebSocket client. If a later AGP allows compileSdk 37, the plain coordinate can come back.
- The local wet highlighter is drawn with simple alpha in the front buffer and multiplied only once committed (LOOSE_ENDS F7); the Mac is the source of truth either way.
- The native app does not bind the pen side button (SPEC 7 lists it under mirror mode only); it logs which button the DC-1 reports (LOOSE_ENDS D4).

---

## 2. How to test on the real device (atomic steps)

Prerequisites: Daylight running on the Mac with "Ink source: Daylight Ink app"; the DC-1 on the same Wi-Fi, or on USB with debugging on.

Install, path A (USB, SPEC 9.3 step 1): plug in, click "Set up over USB" on the Mac with the Daylight Ink card. Expect the app to open on the tablet within a few seconds, the chip reading "Camera" with no Allow prompt (loopback is trusted).

Install, path B (no cable): open the web whiteboard on the tablet, open its "?" card, tap "Get the Daylight Ink app", Install, allow the one-time "install from this source", open the app.

1. First launch: the "Welcome to Daylight Ink" screen appears. Step 1 reads "Looking for your Mac... Enter its address if this takes long" and switches to "Look at your Mac" or "Connected to ws://..." by itself on the same Wi-Fi. If it does not within 10 s, type the Mac's address from the menu bar (the numbers before `:7788`).
2. Step 2: tap "Open the permission screen", find Daylight Ink in the list, switch on "Allow display over other apps", press Back. Expect the step to read "Allowed".
3. Step 3: tap "Allow notifications", Allow. Tap "Start writing".
4. On the Mac, click Allow in the floating panel (Wi-Fi path only). Expect the chip to read "Camera".
5. Touch the pen to the page and write one word. Expect ink under the pen immediately (front buffer) and the chip reading "LIVE" with an amber dot within a quarter second; the board appears in Daylight Camera a little later.
6. Rest the palm, swipe a finger, hover the pen 5 mm above the glass. Expect nothing drawn and no camera change.
7. Press the side button in the air. Expect nothing drawn. Later, Settings > "This tablet" shows `sideButton=BUTTON_STYLUS_PRIMARY (...)` or SECONDARY (LOOSE_ENDS D4) and `pressureRange=...` (D3).
8. Flip the pen (if it has an eraser end) or tap "Erase", rub across the word. Expect the touched strokes to vanish on both sides.
9. Tap "Highlight", draw across a word. Expect an amber band under the black ink on both sides.
10. Tap "Undo". Expect the last stroke to vanish on the Mac first, then on the tablet (it waits for STATE). "Redo" brings it back. Both buttons grey out when the Mac has nothing to undo or redo.
11. Stop drawing. At 85 s the chip reads "Returning in 5" with the dot breathing in step with the Mac divider; at 90 s "Returning", then "Camera".
12. Draw, tap the chip: "KEEP WHITEBOARD" (InkBlack fill). Wait 2 minutes: the board stays. Tap again: "LIVE" with a fresh 90 s. Hold the chip for one second: back to "Camera".
13. Tap "Clear": the page blanks on both sides and the picture returns to the camera unless pinned. Tap "New page" while LIVE: blank page, board still up.
14. Settings: switch "Front buffer" off, back out, draw. Compare the wet-ink lag with the toggle on (LOOSE_ENDS D14). "This tablet" shows `frontBuffer=available (...)` or `fallback to the dry view (...)`.
15. Settings: switch "Send every pen sample at once" on; compare smoothness and the Mac's `--perf-log` (SPEC D49 A/B).
16. Turn Wi-Fi off for 5 s while writing, then on. Expect the chip to read "Looking for your Mac" and then "Camera" or "LIVE" within about 10 s (strokes drawn during the gap stay on the tablet only; the APK has no offline ring).
17. Pills over a note app (mirror mode): on the Mac pick "Ink source: Mirror" with pills on; or from the tablet, Settings > "Show the pills now". Expect two pills, Pin and Clear, top centre inside the strip the mirror crops away (not visible in the camera picture; adjust the Mac's crop if they are, LOOSE_ENDS D5). Pin shows KEEP when pinned and an amber dot while the board is up. Clear saves and returns. Settings > "Hide the pills" removes them.
18. Over USB: `adb shell am start-foreground-service -n com.twelve.daylight.ink/.OverlayService --es pills top` from the Mac shows the same pills without opening the app (LOOSE_ENDS D15: confirm that `appops set ... SYSTEM_ALERT_WINDOW allow` made `canDrawOverlays` true first; the Settings screen shows `canDrawOverlays=`).
19. Reboot with "Start the pills at boot" on: the pills come back by themselves (A12, opt-in).

Logcat tags: `DaylightInk.facts` (device facts, once per process), `DaylightInk.net` (dial, phase, closed, failure, resolved services, multicast lock), `DaylightInk.ink` (pressure range, side button, front buffer), `DaylightInk.overlay` (pills window placement, permission), `DaylightInk.ui`. One line to copy per fact: `adb logcat -s DaylightInk.facts DaylightInk.ink DaylightInk.net`.

---

## 3. Device facts to collect (LOOSE_ENDS section D)

| Row | Fact | Where it is logged |
|---|---|---|
| D2 | `Build.MODEL`, release, display size and density | `DaylightInk.facts: model=... release=... display=WxH density=...` and Settings > This tablet |
| D3 | pressure 0..1 or raw 0..4095 | `DaylightInk.ink: pressure range: normalised 0..1 (first sample p)` or `raw ADC (first sample p, divided by 4095)` |
| D4 | which button the side button is on Android | `DaylightInk.ink: side button: BUTTON_STYLUS_PRIMARY (ACTION_BUTTON_PRESS)` or SECONDARY, or `buttonState while touching` |
| D5 | pills visible inside the mirror and where | eye test, step 17; the window is logged as `pills window added: TOP y=24 row=48px` |
| D11 | Tethering extension version | `DaylightInk.facts: ... tiramisuExt=N` and `DaylightInk.net: multicast lock acquired (tiramisuExt=N)` when below 7 |
| D14 | front buffer on graphics-core 1.0.4 | `DaylightInk.ui: front buffer: available (renderer valid)` or `fallback to the dry view (...)` |
| D15 | `appops set` flipping `canDrawOverlays`, `am start-foreground-service` from the shell | `DaylightInk.facts: canDrawOverlays=true` after the Mac's USB setup; the pills appear on step 18 |

---

## 4. UNVERIFIED items shipped behind a runtime fallback

| # | Fact | Fallback in place | How the owner confirms |
|---|---|---|---|
| 1 | Pressure range of the DC-1 driver (0..1 or raw 0..4095) | `Pressure.normalize` treats anything above 1 as raw ADC; both paths tested | D3 line |
| 2 | Side button is `BUTTON_STYLUS_PRIMARY` or `SECONDARY` | both are accepted for the log; nothing is bound to it in the native app | D4 line |
| 3 | Tethering T extension version (multicast lock, modern NSD API) | branch at runtime: lock below 7, legacy `discoverServices` path always | D11 line |
| 4 | `onServiceFound` type string with a leading or trailing dot | `contains("_daylight-camera._tcp")` | discovery works on Wi-Fi (step 1) |
| 5 | OkHttp callback thread | every callback is posted to the main looper | none needed |
| 6 | Overlay pills visible inside the scrcpy mirror and where | row fixed inside the top 96 px (`PillsLayout`); `--es pills bottom` moves it; the Mac's crop is a setting | step 17 |
| 7 | `appops set ... SYSTEM_ALERT_WINDOW allow` flipping `canDrawOverlays`; `am start-foreground-service` from the shell bypassing background limits | the service checks `canDrawOverlays` and shows row 29 instead of crashing; the onboarding screen is the manual path | step 18 |
| 8 | Front buffer on graphics-core 1.0.4 on the DC-1 (1.0.2 proven by the sibling app) | `runCatching` creation; the dry view draws every segment anyway, so a missing renderer only costs latency; setting `frontBuffer` | step 14 |
| 9 | `findPointerIndex` and `WindowInsets.Type` API levels (old APIs, not re-read) | both compile against the API 33 framework jar on this box | nothing to do |
| 10 | `wm density` of the SolOS viewport (the toolbar is sized in dp, the pills in px) | the toolbar scrolls sideways when it does not fit; the pills ignore density by design | D2 line, eye test |
| 11 | OkHttp's `onOpen` exposing the echoed `Sec-WebSocket-Protocol` header (OkHttp does not validate it itself) | read from `response.header(...)`; a missing echo is "Update Daylight on your Mac" with no re-dial; the Swift server echoes it (ARCHITECTURE 18) | the chip never shows that text against a real Mac |
| 12 | `android:usesCleartextTraffic="true"` being the only thing plain `ws://` needs on SolOS (no network security config) | none beyond the attribute; a cleartext block would surface as `onFailure` lines under `DaylightInk.net` | step 1 connects |

---

## 5. Requests for the integrator

1. `scripts/android.sh`: pass the build number so every CI APK upgrades the previous sideload: `./gradlew --no-daemon --stacktrace -PdaylightVersionCode="${GITHUB_RUN_NUMBER:-1}" -PdaylightVersionName="$(cat ../VERSION)" :app:testDebugUnitTest :app:assembleDebug`. `app/build.gradle.kts` already reads `daylightVersionCode` (default 1) and `daylightVersionName` (default 0.1.0). Applied in 99366ee: `scripts/android.sh` passes both properties (`GITHUB_RUN_NUMBER` or 1, and the `VERSION` file with whitespace stripped); proven by the android job on that commit.
2. ARCHITECTURE 2.6 and the directory layout: additional files `ink/PageGeometry.kt`, `ink/LocalStroke.kt`, `ink/Pressure.kt`, `ink/MotionSamples.kt`, `ink/PenInput.kt`, `net/Backoff.kt`, `net/DiscoveryQueue.kt`, `net/Link.kt`, `net/Identity.kt`, `ui/ChipState.kt`, `ui/PillView.kt`, `ui/Texts.kt`, `ui/Tokens.kt`, `overlay/PillsState.kt`, `Facts.kt`; test files `LinkTest.kt`, `ChipStateTest.kt`, `ManifestTest.kt`, `SourceRulesTest.kt`, `TestFrames.kt`. `InkConnection` takes no `CoroutineScope` (Handler based) and `OverlayService` is started with `--es pills top|bottom` and an optional `--es host`. Applied in 99366ee: ARCHITECTURE section 18 rows "Android file list (2.6)", "`InkConnection` (2.6)", "`OverlayService` (2.6)" and "OkHttp coordinate (2.6)"; section 18 wins over 1 and 2.6 by its own rule.
3. LOOSE_ENDS: the rows of section 3 above with the logcat lines as the collection method; a line for the okhttp-android compileSdk 37 fact (section 1, deviations) under B or E; UNVERIFIED 11 and 12 above. Applied in 99366ee: LOOSE_ENDS D2, D3, D4, D5, D11, D14 and D15 carry the logcat lines; B20 records the okhttp-android compileSdk 37 fact; D17 and D18 carry UNVERIFIED 11 and 12; B9 is resolved by the green android runs.
4. SETUP, COMPARE and TESTING-CHECKLIST text: section 6 below. Deferred to M6 in 99366ee: those documents do not exist yet and plan rule 5 folds every handoff into them at M6; the text stays here until then.
5. Nothing else: no plist key, no make target beyond request 1, no golden change. `make android` runs unchanged. Noted in 99366ee: `make android` still runs `scripts/android.sh`, now with the two gradle properties of request 1; the shared working tree finding became LOOSE_ENDS B21.

---

## 6. Text for the owner-facing documents

### 6.1 SETUP.md, section "Daylight Ink (the native app)"

Plug the tablet in once and click "Set up over USB" on the Mac: it installs Daylight Ink, grants the two permissions, and opens the app connected over the cable with no Allow prompt. Without a cable, open the web whiteboard, tap "Get the Daylight Ink app" in its "?" card, install it, open it: it finds the Mac by itself on the same Wi-Fi and the Mac asks you to Allow it once. The first screen asks for two permissions: "Allow display over other apps" (for the floating Pin and Clear pills in mirror mode; Android 13 shows a list, pick Daylight Ink) and notifications (the pills run as a quiet service). Both can be skipped and redone from Settings.

Every later day: open the app. It reconnects on its own (Bonjour first, then the USB cable, then the address it remembered). Only the pen draws; fingers and palms never do. The chip at the bottom tells you what the camera is doing: "Camera", "LIVE", "Returning in 5", "KEEP WHITEBOARD". Tap it to pin, hold it for a second to go back to the camera. On an office network that blocks Bonjour, type the Mac's address (the Tailscale 100.x one if you have it) in Settings once.

### 6.2 COMPARE.md, row "Daylight Ink"

Pen to ink on the tablet: the front buffer draws the wet segment before the next display frame (the sibling app measured well under one frame on this device; confirm with the toggle in Settings). Pen to chip LIVE: well under a quarter second. Samples per stroke: the full digitizer rate, unbuffered dispatch, one chunk per 45 to 90 Hz frame (or per sample with the A/B setting). Vector record: yes. Needs: one install, no USB debugging. Measured numbers to fill in: `DaylightInk.net` RTT lines (`pong N rtt=... ms`), the Mac's `--perf-log` engage latency, the front-buffer A/B impression.

### 6.3 TESTING-CHECKLIST.md rows (ADHD-friendly, atomic)

- 🟢 **Install over USB** (2 min): plug in, "Set up over USB" with the Daylight Ink card. The app opens, chip reads "Camera". ⏱️ 2 min
- 🟢 **Two permissions** (2 min): "Allow display over other apps" (pick Daylight Ink in the list), "Allow notifications", "Start writing". ⏱️ 2 min
- ✍️ **Write one word** (1 min): ink under the pen at once, chip "LIVE", board in the call. ⏱️ 1 min
- 🟡 **Palm, finger, hover, side button** (1 min): nothing drawn. Then Settings > This tablet: copy `pressureRange=` and `sideButton=` into LOOSE_ENDS D3 and D4. ⏱️ 1 min
- ✍️ **Highlight, erase, undo, redo** (2 min): amber under black; erase removes; undo and redo follow the Mac and grey out when empty. ⏱️ 2 min
- ⏱️ **Wait for the return** (2 min): "Returning in 5" at 85 s with the breathing dot, "Camera" at 90 s. ⏱️ 2 min
- 📋 **Pin and hold** (2 min): tap the chip, "KEEP WHITEBOARD"; hold it, back to camera. ⏱️ 2 min
- 🟣 **Clear and New page** (1 min): Clear blanks and returns; New page keeps the board up. ⏱️ 1 min
- 🟣 **Front buffer A/B** (2 min): Settings > Front buffer off, draw, compare, back on. Copy `frontBuffer=` into LOOSE_ENDS D14. ⏱️ 2 min
- 🟣 **Wi-Fi blip** (1 min): Wi-Fi off 5 s, on again; the chip comes back by itself. ⏱️ 1 min
- 📋 **Pills over a note app** (3 min): Ink source Mirror on the Mac (pills on), or Settings > Show the pills now. Pin shows KEEP when pinned; Clear saves and returns; the pills are absent from the camera picture (else move the Mac crop, LOOSE_ENDS D5). ⏱️ 3 min
- 📋 **Copy the facts** (1 min): Settings > This tablet, copy `model=`, `release=`, `tiramisuExt=`, `canDrawOverlays=` into LOOSE_ENDS D2, D11, D15. ⏱️ 1 min
- 🟢 **Next day** (1 min): open the app; it reconnects without a prompt. ⏱️ 1 min

---

## 7. CI facts and red runs

- Run 37112754944 (commit dea0311), job `android` 111173712941, failed in my own files: `checkDebugAarMetadata` rejected `com.squareup.okhttp3:okhttp-android:5.5.0` ("requires ... compile against version 37 or later"; AGP 8.13.2's maximum is 36). Fixed in 4c58a4f by depending on `okhttp-jvm:5.5.0`. The other four jobs of that run were green; `mac` was skipped by the `needs` edge.
- Local verification on this box (no Android SDK): the sources are type-checked against the Robolectric `android-all` API 33 framework jar from Maven Central with a scratch stub for `CanvasFrontBufferedRenderer` (Google Maven is blocked here), and the 67 JVM tests run with the Kotlin 2.3.10 JVM plugin before every push. The scratch harness lives outside the repository.
- Red runs caused by someone else's files: none observed for the android job.

Green runs: 37113048216 (commit 4c58a4f, all five jobs green, `android` job 111174518991 in 1 min 40 s: 67 tests, APK artifact `daylight-ink-debug-apk` 2,920,633 bytes, embedded by the `mac` job into `Daylight-unsigned.zip`, 12,962,788 bytes); 37113456015 (head 8845c42 carrying E's 9f005eb, `android` green with 70 tests; run 37113419943 for 9f005eb itself was cancelled by that newer push, as the job-level `cancel-in-progress` intends).
