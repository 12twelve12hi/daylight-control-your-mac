# Daylight Whiteboard Camera: product specification and decisions log

Status: binding for v1. This document is what a reviewer checks the implementation against. The architecture that realises it is `docs/ARCHITECTURE.md`; the wire protocol is `docs/PROTOCOL.md`; open items are `docs/LOOSE_ENDS.md`. The Python prototype at `DaylightWhiteboardCamera/` is a specification oracle only (constants, protocol layouts, governor transitions, design tokens); nothing from it ships.

Writing rules for every human-facing string in this repository: no em-dashes; LivePaper is a transflective LCD (never "MIP"); the backlight is DC dimming (never "PWM"); VRR is 45 to 90 Hz (never 120 Hz).

---

## 1. The product in one paragraph

Daylight is a macOS menu-bar app that publishes a virtual camera called "Daylight Camera". In a call it shows the owner's webcam untouched. The moment the owner touches the Wacom pen to the Daylight DC-1, the picture slides (critically damped spring, visually settled in about 250 ms, budget 333 ms) into Studio Split: the whiteboard page (3:4, letterboxed in SolOS cream) on the left two thirds and the presenter's webcam, cropped not scaled, on the right third. After 90 s without ink the picture slides back; from 85 s the divider breathes amber as a warning, and any pen contact cancels the return. A pin keeps the board up indefinitely; Clear saves the page, blanks it and returns to camera unless pinned. Three ink sources are built so the owner can compare them from the menu bar: the web whiteboard served by the Mac, the native "Daylight Ink" app, and a mirror of the tablet screen. Everything is set up once and never again.

---

## 2. Decisions log

Every row is binding. `Owner` means the owner said it (DECISIONS.md, grill sessions 1 and 2, and the harness-relayed answers to Q1 to Q7). `Assumed` means an assumption the owner has not yet confirmed; each Assumed row has a line in `docs/LOOSE_ENDS.md`. `Resolved` means a conflict between the three design proposals settled by the judges' verdicts and recorded here. `Owner-confirmed` means an Assumed or Resolved row the owner later approved as it stands, with the date and the LOOSE_ENDS row that carried the question.

| # | Decision | Source |
|---|---|---|
| D1 | Virtual camera named "Daylight Camera"; menu-bar app named "Daylight". Output 1920x1080 at 30 fps, BGRA, no mirroring. | Owner |
| D2 | Passthrough forwards the webcam frame with zero pixel work; Studio Split and Whiteboard Only are the only composed modes. Presenter segmentation and Overlay mode are dropped for v1 (Camo lesson: utility over spectacle). | Owner |
| D3 | Engage on the first pen CONTACT with pressure > 0, never on hover; fingers and palms never draw and never engage. | Owner |
| D4 | Slide is a critically damped spring with k = 1200, m = 1 (settles by the oracle rule at 251 ms; 333 ms is the budget, not the settle time). | Owner (333 ms), Resolved (k = 1200 kept; k = 600 would take the full 333 ms) |
| D5 | Return after 90 s without ink; amber pre-warning from 85 s on the divider only; ink always wins during the return. | Owner |
| D6 | Pin ("KEEP WHITEBOARD") keeps the board up indefinitely. Clear clears the canvas AND returns to camera unless pinned ("if I hit clear at any time, I can also end it"). | Owner |
| D7 | Pages are saved as PNG plus strokes JSON under `~/Documents/Daylight Camera/<yyyy-MM-dd>/` (one `<HH-mm-ss>/` session subfolder per session inside the day folder, section 12). | Owner (folder), Resolved (session subfolder) |
| D8 | Three ink sources, all built, selectable in the menu bar as "Ink source": (a) web whiteboard, (b) native APK "Daylight Ink", (c) mirror via bundled adb and scrcpy-server. | Owner |
| D9 | Mirror mode Pin/Clear: both the floating pills (APK overlay service) and the pen side button are built; Settings chooses pills, pen button or both (default both). | Owner |
| D10 | Pen side button gestures: double press = Pin, long press (700 ms) = Clear; swappable in Settings. Triple press is not used. | Resolved (both judges; triple press is hard to perform and delays the double), Owner-confirmed (2026-10-03, LOOSE_ENDS A4) |
| D11 | Pairing has no codes and no QR (the DC-1 has no camera). Bonjour `_daylight-camera._tcp`; the APK auto-connects; the web page is opened from a numeric URL shown in the menu bar (Tailscale 100.x first) or opened on the tablet over USB. One-click "Allow this Daylight?" on the Mac the first time a new tablet connects, remembered forever. | Owner |
| D12 | Priority order: simplest possible experience, wireless, one-time onboarding then never again; security may be lighter at first. No TLS in v1. | Owner (Q7) |
| D13 | USB debugging on the DC-1 is acceptable for v1 (owner already uses adb). A path that needs no USB debugging is a tracked loose end. | Owner (Q4) |
| D14 | Bundling adb and scrcpy-server in the Mac app is fine for v1 (Apache-2.0, small); the long-term answer is a SolOS-native service. The owner's scalability question is answered in section 17. The bundled adb is the default adb source; downloading platform-tools on first use and reusing an installed adb are built as Settings alternatives (LOOSE_ENDS H1). | Owner (Q5), Resolved, Owner-confirmed (2026-10-03, LOOSE_ENDS A6: bundled adb stays the default) |
| D15 | Identity (baked into signing): bundle ids `com.twelve.daylight` (app) and `com.twelve.daylight.camera` (extension); app group `$(TeamIdentifierPrefix)com.twelve.daylight` (macOS Team-ID form, no `group.` prefix, no portal registration); Android package `com.twelve.daylight.ink`. | Owner (ids), Resolved (app group form verified by research-cmio-signing section 0.6), Owner-confirmed (Android package, 2026-10-03, LOOSE_ENDS A3) |
| D16 | Mac stack: Swift, one menu-bar `.app` embedding a CMIO camera extension (system extension, sink-stream pattern as OBS), AVCaptureSession webcam, Metal compositor over IOSurface-backed textures, CoreGraphics ink into IOSurfaces, pure-Swift `DaylightKit` package tested on Linux and macOS, Network.framework server and Bonjour, Carbon global hotkeys. | Owner |
| D17 | Protocol: SolStream-v1 binary framing in WebSocket binary frames on `ws://<mac>:7788/ink`; keep the oracle's opcodes; add UNDO 0x0014, REDO 0x0015 and a server-to-client STATE 0x0070; pointer type and phase are honoured. | Owner (framing, additions), Resolved (opcode numbers, no CLIENT_HELLO, 20-byte STATE with undo/redo depths) |
| D18 | `delta_ms` in a point is milliseconds since the FIRST point of the stroke, saturating at 65535 (oracle `models.py:138`). | Resolved (judges' mustFix) |
| D19 | Day-one fallback: a preview window of the camera output (also usable with OBS Virtual Camera through window capture). `previewOnLaunch` defaults to true on unsigned builds. | Owner, Resolved |
| D20 | Separate app now (`Daylight`), shared `DaylightKit`; Twelve's gate untouched; merging into one Daylight Mac app is a loose end. | Owner (Q4) |
| D21 | GitHub Actions is the only compiler (no Xcode, no Swift, no Android SDK locally). Every push to `claude/daylight-whiteboard-camera-tzxfjb` triggers CI; agents read CI logs and iterate to green. | Owner |
| D22 | Signing: Developer ID Application + notarization in CI when secrets exist; without secrets CI builds unsigned (`CODE_SIGNING_ALLOWED=NO`) for compile verification and uploads an unsigned artifact. Notarize only on tags `v*` or a manual `workflow_dispatch` input. | Owner, Resolved (notarize gating) |
| D23 | Android: debug-signed APK from the ubuntu runner, committed debug keystore so `adb install -r` always upgrades. Release key is a loose end. | Owner, Resolved |
| D24 | Web: Vite + TypeScript, Playwright tests simulating pen pointer events through CDP; built `dist/` embedded in the Mac app Resources by the mac CI job. | Owner |
| D25 | Repository: `whiteboard-camera/` inside the monorepo is the root of the public standalone repo `12twelve12hi/whiteboard-camera-draw` (https://github.com/12twelve12hi/whiteboard-camera-draw, created by the owner, populated by a subtree split on 2026-10-03; its `ci.yml` runs the same jobs); thin monorepo workflow at `/.github/workflows/whiteboard-camera.yml` plus `whiteboard-camera/.github/workflows/ci.yml`; all build logic in `Makefile` + `scripts/`. | Owner (Q1; the standalone repo named on 2026-10-03) |
| D26 | Commit messages end with the two attribution trailers given in the session; model names appear nowhere else in the repo. User-facing docs end with the ADHD-friendly testing checklist convention. | Owner |
| D27 | Deployment target macOS 14.0 for both Mac targets (gives `.external` and `.continuityCamera` without availability gates and the modern approval flow). | Assumed (recommended by every research note) |
| D28 | Swift language mode 5 (`SWIFT_VERSION 5.0`, `SWIFT_STRICT_CONCURRENCY minimal`) in all Mac targets; `swift-tools-version:5.9`; no actors, no strict concurrency, no NWProtocolFramer. | Resolved (buildability) |
| D29 | Xcode 16.4 (the macos-15 default) builds the Mac targets; no `DEVELOPER_DIR` override unless a script finds the path and logs the fallback. The Kit tests run on Linux inside the `swift:6.4-noble` container (the `kit-linux` job); the first green run (actions run 37104560769) used Xcode 16.4 with Apple Swift 6.1.2 on macos-15. | Resolved (judges' mustFix), Verified (CI run 37104560769) |
| D30 | Host app is NOT sandboxed (serves HTTP, spawns adb, writes ~/Documents); hardened runtime on. Extension is sandboxed with the app group only and never carries hardened-runtime exceptions. | Assumed (OBS parity) |
| D31 | Both Developer ID provisioning profiles are created and embedded: "Daylight Developer ID" (app) and "Daylight Camera Developer ID" (extension). | Assumed (cheap insurance) |
| D32 | Idle rule: webcam capture runs when at least one app is viewing Daylight Camera OR the preview window is visible OR the extension sink is not connected (unsigned build or extension absent); it stops 60 s after none of these holds. The camera LED off between calls is the user-visible proof. | Resolved (perf graft + judges' mustFix) |
| D33 | The extension consumes the sink with the OBS 3x-frame-rate timer (90 Hz, only while `sinkStarted`); the recursive consume loop stays behind a compile-time strategy switch, default off. | Resolved (judges' mustFix) |
| D34 | Render clock: a plain 30 Hz `DispatchSourceTimer` runs while the governor is not in PASSTHROUGH or a hold mode is active; frame reuse and deadline idling exist behind `frameReuse` and `deadlineIdle` flags, default off, enabled only after measurement on the M5 Max. | Resolved (judges' mustFix) |
| D35 | Canvas backing 1200x1600 (DC-1 native), two premultiplied BGRA layers (ink, highlighter) composed in the shader (highlighter multiplied under ink). | Assumed (research-mac-pipeline recommendation) |
| D36 | Eraser contact does NOT engage from PASSTHROUGH by default; it counts as activity (keeps LIVE alive, cancels a return). Setting `engageOnEraser`, default false. | Owner-confirmed (2026-10-03, LOOSE_ENDS A4) |
| D37 | A client disconnect never changes the governor state: in-flight strokes are committed as they stand, that client's ids leave `activeContacts`, the idle timer continues. `.reset` to PASSTHROUGH happens only on app quit. | Resolved (both judges), Owner-confirmed (2026-10-03, LOOSE_ENDS A4) |
| D38 | Pin during RETURNING re-engages with `pinned = true` ("keep it" during the countdown). Engage or a layout hotkey during RETURNING re-engages. | Resolved (both judges) |
| D39 | A page is saved when the board arrives in PASSTHROUGH (RETURNING completion), on Clear (before clearing), on New page, every 60 s while dirty (autosave overwriting the same files), on hold-to-camera, and on quit. A `savedAt` stamp per page prevents duplicate saves. Mirror mode saves `mirror-<HH-mm-ss>.png` (last decoded frame, cropped) at session end. | Resolved (both judges) |
| D40 | Mirror crop is stored as pixel insets per orientation (portrait `{top 96, left 0, right 0, bottom 0}`, landscape `{top 72, ...}`) converted to fractions of the CURRENT session packet size, so encoder fallback sizes and rotation crop the same screen region; top inset is 0 when pills are disabled. | Resolved (judges' mustFix) |
| D41 | VideoToolbox outputs BGRA (one shader path). Each decoded access unit gets a block buffer that owns its memory (no buffer reuse across frames). | Resolved (judges' mustFix) |
| D42 | Cable-free mirror interim: Settings toggle "Mirror over Wi-Fi" using scrcpy's `--tcpip` method (`adb shell ip route`, `adb tcpip 5555`, `adb connect <ip>:5555`, stdout checked for `connected`). Android 11 wireless debugging pairing is documented in SETUP.md, not automated. | Resolved (judges' mustFix) |
| D43 | The mac CI job needs the android and web jobs, downloads the debug APK and `web-dist`, embeds `Resources/DaylightInk.apk` and serves it at `/daylight-ink.apk`, so the native app installs with no USB. | Resolved (both judges) |
| D44 | The Allow prompt is a non-activating floating panel (never a modal alert), 60 s auto-dismiss, mirrored as a menu item while pending; the connection stays pending until the owner answers; loopback (USB) clients are auto-allowed and flagged `seenOverUSB` so they are trusted later over Wi-Fi. | Resolved (both judges) |
| D45 | "Not in /Applications" is handled with "Reveal in Finder" and the DMG drag arrow; the app never moves itself. Translocated paths are detected and explained. | Resolved (judges' mustFix) |
| D46 | Hotkeys default to Ctrl+Opt+Cmd + W (Whiteboard Only), D (Studio Split), K (Keep/Pin), C (Clear), Esc (Camera); pressing the active layout hotkey again returns to camera (unpinning first). | Assumed (defaults), Resolved (toggle semantics) |
| D47 | STATE cadence: on every change; 10 Hz while ENGAGING, RETURNING or pre-warning; 1 Hz while LIVE; silent in PASSTHROUGH with no change. | Resolved (both judges) |
| D48 | No hard wall-time performance assertions on shared CI runners; perf numbers are measured and printed, functional invariants (pool <= 3, no drops with a prompt fake sink) are asserted. | Resolved (judges' mustFix) |
| D49 | Android: OkHttp 5.5.0 with a `SocketFactory` that sets `tcpNoDelay = true` (OkHttp leaves Nagle on), points batched per Choreographer frame by default, `sendPerEvent` as an A/B setting. | Resolved (perf graft) |
| D50 | Owner-facing text for every first-run failure is fixed in section 13.3 and wired to one enum case each. | Resolved (reliability graft) |
| D51 | The owner's Mac (M5 Max) most likely runs macOS 26. Every approval-pane text names macOS 26 first ("macOS 26 and 15": System Settings > General > Login Items & Extensions > Camera Extensions); the macOS 13 and 14 path (Privacy & Security > Security) stays as the legacy variant. CI keeps the macos-15 image. | Owner-confirmed (2026-10-03, LOOSE_ENDS A2) |
| D52 | The one-time `chrome://flags/#unsafely-treat-insecure-origin-as-secure` paste stays an optional, offered onboarding step for wireless web use (section 9.2 item 4); it is never required. | Owner-confirmed (2026-10-03, LOOSE_ENDS A5) |
| D53 | The project is licensed under the Apache License 2.0 (`LICENSE`, the standard text). Bundled third parties: scrcpy-server (Apache-2.0) and adb (Google's notice and SDK terms), listed in `THIRD_PARTY_NOTICES.md`. | Owner-confirmed (2026-10-03, LOOSE_ENDS A14) |

---

## 3. Identity constants (do not change; baked into signing)

| Item | Value |
|---|---|
| App bundle id | `com.twelve.daylight` |
| Extension bundle id and product name | `com.twelve.daylight.camera` (product `com.twelve.daylight.camera.systemextension` in `Contents/Library/SystemExtensions/`) |
| App group and Mach service name | `$(TeamIdentifierPrefix)com.twelve.daylight` |
| Device name in Zoom/Meet/Teams | `Daylight Camera` |
| Fixed CMIO UUIDs | three UUIDs committed in both Info.plists under `DaylightCameraDeviceUUID`, `DaylightCameraSourceUUID`, `DaylightCameraSinkUUID` (generated once at M0 with `uuidgen`) |
| Android package | `com.twelve.daylight.ink` |
| Bonjour | `_daylight-camera._tcp`, instance `Daylight Camera on <hostname>` |
| Port | 7788 (configurable) |
| Documents folder | `~/Documents/Daylight Camera/` |
| Settings key | `com.twelve.daylight.settings.v1` (one JSON blob in `UserDefaults`); `clients.json` in `~/Library/Application Support/Daylight/` |

Design tokens: InkBlack `#111111`, InkSubtle `#1E1D1B`, TextMuted `#736F68`, PaperBg `#FAF8F5`, SurfaceCream `#EAE5DC`, CardBg `#FFFFFF`, BorderSubtle `#CDC6B8`, Amber `#D97706`, AmberDeep `#C87D20`, Terracotta `#9C271D`, Indigo `#1E3A8A`. The webcam and these colours pass through byte-exact (non-sRGB `bgra8Unorm` everywhere).

---

## 4. Modes and output

| Mode | What viewers see | Compute |
|---|---|---|
| Passthrough | the webcam frame, untouched, camera-paced | zero pixel work: the captured `CVPixelBuffer` is re-wrapped in a host-clock `CMSampleBuffer` and handed to the extension (logged fallback: one GPU copy when a camera hands out non-IOSurface or non-BGRA or non-1080p buffers) |
| Studio Split | canvas left two thirds, presenter crop right third (section 6) | one Metal pass at 30 Hz |
| Whiteboard Only | canvas centred, cream margins, no presenter | one Metal pass at 30 Hz; with `frameReuse` on, zero GPU when the canvas is unchanged |
| Idle (no viewer, preview closed, extension connected) | the extension emits nothing (Zoom is not open) | capture stopped after 60 s (D32); the camera LED is off; under 1 percent of one core |

Studio Split is the default layout when engaging; Whiteboard Only is reached by its hotkey or by the Settings default `preferredLayout`. The extension shows a cream card "Daylight is not running. Open Daylight from the menu bar." only when the host is not connected and a viewer is streaming; it never draws text in a working call.

---

## 5. Engage and return state machine

Owner of truth: `EngageGovernor` in DaylightKit, a pure value type with injected time (monotonic seconds), driven by the pipeline under one lock. Deterministic scenario tests run on Linux and macOS.

### 5.1 States and variables

| State | Progress | Meaning |
|---|---|---|
| PASSTHROUGH | 0 | webcam forwarded untouched; no Metal work; render clock stopped |
| ENGAGING | spring 0 to 1 | sliding into the board layout |
| LIVE | 1 | board visible; idle timer runs unless pinned, held, or a pen is on the glass |
| RETURNING | spring 1 to 0 | sliding back to the full webcam |

Variables: `spring: CriticalSpring` (position = progress), `pinned`, `hold` (auto, split, whiteboard, camera), `preferredLayout` (studioSplit, whiteboardOnly), `activeContacts: Set<UUID>` (uncommitted stylus strokes; mirror mode uses one sentinel id while BTN_TOUCH is down), `lastActivity`, `engageStart`, `preWarningFired`, `preWarningStart`, `generation` (increments on every state change; stale-callback guard), plus per-page `lastInkAt` and `savedAt` (section 12).

Events: `contact(id, pointer, phase, pressure, tool)`, `motion(id)`, `lift(id)`, `cancel(id)`, `activity` (erase, undo, redo, laser, page change), `penContact(down)` and `eraserContact(down)` (mirror), `pin(v)` with v in {-1 toggle, 0 off, 1 on}, `clear`, `returnNow`, `engage` (menu "Whiteboard now"), `layoutHotkey(L)`, `hold(m)`, `sourceChanged`, `clientGone(ids)`, `allClientsGone`, `tick`.

Effects (consumed by the pipeline): `stateChanged(from, to)`, `savePage(reason)`, `clearCanvas`, `preWarningStarted`, `preWarningCancelled`, `pinChanged(Bool)`, `holdChanged`.

Guards used below: STYLUS = `pointer == stylus && phase == contact && pressure > 0 && (tool != eraser || engageOnEraser)`. SETTLED = `|position - target| < 0.01 && |velocity| < 0.05`. IDLE = `hold == auto && !pinned && activeContacts.isEmpty`.

### 5.2 Transition table (state x event -> next state, actions, timers)

| From | Event | Guard | To | Actions and timers |
|---|---|---|---|---|
| PASSTHROUGH | contact | STYLUS | ENGAGING | `spring.retarget(1)`; `engageStart = lastActivity = now`; add id; generation += 1; start the 30 Hz clock; render frame 0 synchronously; stateChanged |
| PASSTHROUGH | contact | stylus but eraser tool and `!engageOnEraser` | PASSTHROUGH | id tracked (so lift clears it); no engage |
| PASSTHROUGH | contact | finger, palm, mouse, hover, or pressure 0 | PASSTHROUGH | dropped (the stroke's chunks are dropped too) |
| PASSTHROUGH | penContact(down) | ink source is mirror | ENGAGING | as the first row with the sentinel id |
| PASSTHROUGH | pin(1 or -1) | | ENGAGING | `pinned = true`; pinChanged; as the first row (the pill brings the board up without drawing) |
| PASSTHROUGH | pin(0) | | PASSTHROUGH | nothing |
| PASSTHROUGH | engage or layoutHotkey(L) | hold != camera | ENGAGING | `preferredLayout = L` for the hotkey; as the first row |
| PASSTHROUGH | hold(split or whiteboard) | | ENGAGING | `hold = m`; `preferredLayout` follows m; idle timer disabled; as the first row |
| PASSTHROUGH | hold(camera) | | PASSTHROUGH | `hold = camera`; auto-engage disarmed (ink is still recorded in the stroke store so nothing is lost) |
| PASSTHROUGH | clear | | PASSTHROUGH | `savePage(.cleared)` if dirty; `clearCanvas` if the page has strokes; no transition |
| PASSTHROUGH | motion, lift, cancel, activity, returnNow | | PASSTHROUGH | bookkeeping only (lift and cancel remove the id) |
| PASSTHROUGH | tick | | PASSTHROUGH | nothing; no timer runs in PASSTHROUGH |
| ENGAGING | tick | SETTLED | LIVE | `spring.snap(1)`; stateChanged |
| ENGAGING | cancel(id) | `now - engageStart < 0.080 && position < 0.15 && activeContacts \ {id} is empty && !pinned && hold == auto` | PASSTHROUGH | snap-back: `spring.snap(0)`; stop clock; stateChanged; no save (a board a pin, a hold or a hotkey brought up never snaps back on a stray cancel) |
| ENGAGING | cancel(id) | otherwise | ENGAGING | remove id; `lastActivity = now` |
| ENGAGING | contact (STYLUS), motion, activity | | ENGAGING | track id; `lastActivity = now` |
| ENGAGING | lift | | ENGAGING | remove id; `lastActivity = now` |
| ENGAGING | pin(v) | | ENGAGING | `pinned` set per v; pinChanged |
| ENGAGING | clear | | ENGAGING or RETURNING | `savePage(.cleared)` if dirty; `clearCanvas`; if `!pinned` -> RETURNING (`spring.retarget(0)`, generation += 1, stateChanged) |
| ENGAGING | returnNow or hold(camera) | | RETURNING | `pinned = false`; `spring.retarget(0)`; generation += 1; stateChanged |
| ENGAGING | layoutHotkey(L) | L == preferredLayout | RETURNING | toggle off: `pinned = false`; as returnNow |
| ENGAGING | layoutHotkey(L) | L != preferredLayout | ENGAGING | `preferredLayout = L` (the compositor switches target layout; the slide continues) |
| ENGAGING | hold(auto) | | ENGAGING | `hold = auto`; `lastActivity = now` |
| LIVE | tick | IDLE && `now - lastActivity >= idleTimeout - preWarningLead && !preWarningFired` | LIVE | `preWarningFired = true`; `preWarningStart = now`; preWarningStarted (STATE goes to 10 Hz) |
| LIVE | tick | IDLE && `now - lastActivity >= idleTimeout` | RETURNING | `spring.retarget(0)`; generation += 1; `preWarningFired = false`; preWarningCancelled if it was on; stateChanged (no save yet) |
| LIVE | contact (STYLUS), motion, activity, eraserContact(down) | | LIVE | track id; `lastActivity = now`; if `preWarningFired` -> `preWarningFired = false`, preWarningCancelled |
| LIVE | lift, cancel | | LIVE | remove id; `lastActivity = now` |
| LIVE | pin(v) | | LIVE | `pinned` set per v; if it became false: `lastActivity = now` (fresh 90 s); pre-warning cancelled if on; pinChanged |
| LIVE | clear | | LIVE or RETURNING | `savePage(.cleared)` if dirty; `clearCanvas`; if `!pinned` -> RETURNING (as above) else `lastActivity = now` |
| LIVE | returnNow or hold(camera) | | RETURNING | `pinned = false`; `spring.retarget(0)`; generation += 1; stateChanged |
| LIVE | engage | | LIVE | `lastActivity = now` |
| LIVE | layoutHotkey(L) | L == preferredLayout | RETURNING | as returnNow |
| LIVE | layoutHotkey(L) | L != preferredLayout | LIVE | `preferredLayout = L` (layout switches; no slide) |
| LIVE | hold(split or whiteboard) | | LIVE | `hold = m`; `preferredLayout` follows m; idle timer disabled; pre-warning cancelled if on; holdChanged |
| LIVE | hold(auto) | | LIVE | `hold = auto`; `lastActivity = now`; `pinned` unchanged; holdChanged |
| RETURNING | contact (STYLUS), motion(active id), penContact(down), eraserContact(down) | `autoEngage && hold != camera` (auto-engage armed) | ENGAGING | ink wins: `spring.retarget(1)` from the current position and velocity (no discontinuity); generation += 1; `lastActivity = now`; stateChanged (eraserContact per D36) |
| RETURNING | contact (STYLUS), motion(active id), penContact(down), eraserContact(down) | hold == camera, or auto-engage off | RETURNING | bookkeeping only: id tracked, ink recorded in the stroke store; the owner asked for the camera, so the return completes |
| RETURNING | pin(1), or pin(-1) when `!pinned` | | ENGAGING | keep it: `pinned = true`; pinChanged; `spring.retarget(1)`; generation += 1; stateChanged |
| RETURNING | pin(0), or pin(-1) when pinned | | RETURNING | `pinned = false` |
| RETURNING | engage, layoutHotkey(L), hold(split or whiteboard) | | ENGAGING | set `preferredLayout` / `hold`; `spring.retarget(1)`; stateChanged |
| RETURNING | tick | SETTLED at 0 | PASSTHROUGH | `spring.snap(0)`; `activeContacts` cleared; `pinned = false`; pre-warning cleared; `savePage(.returned)` if dirty; stop clock; stateChanged |
| RETURNING | clear | | RETURNING | `savePage(.cleared)` if dirty; `clearCanvas`; no transition |
| RETURNING | returnNow, hold(camera), lift, cancel | | RETURNING | bookkeeping only |
| any | sourceChanged | | same | `activeContacts` cleared (ids from the old source will never end); if that removed the last contact of an ENGAGING or LIVE board, `lastActivity = now` (a fresh idle period: a pen that was on the glass froze the timer, and the drop must not fire a return at once); a drop that removes nothing leaves the timer alone; the board stays where it is |
| any | clientGone(ids) | | same | ids removed from `activeContacts` (the ink router commits those strokes as they stand); the same `lastActivity` rule; no transition |
| any | allClientsGone | | same | `activeContacts` cleared; the same `lastActivity` rule; otherwise the idle timer carries on (a Wi-Fi blip must not yank the board away mid-sentence) |
| any (not PASSTHROUGH) | hold(camera) | | RETURNING | as returnNow, plus `hold = camera` |

Timers: the governor owns none. The pipeline calls `tick(now)` at 30 Hz while `state != PASSTHROUGH || hold != auto`; nothing can expire in PASSTHROUGH. `nextDeadline(now:)` exists for the optional `deadlineIdle` flag (D34). Pre-warning breath weight at time t since `preWarningStart`: `0.5 * (1 - cos(2 * pi * t / 2))` (0.5 Hz); the tablet chip uses the same formula from STATE.

`ms_to_return` reported in STATE: `idleTimeout - (now - lastActivity)` while LIVE and IDLE; 0 while RETURNING; `0xFFFFFFFF` otherwise.

### 5.3 Spring

Closed form for the critically damped case, exact at any dt: `x(t) = T + (A + B t) e^(-omega t)`, `v(t) = (B - omega (A + B t)) e^(-omega t)` with `A = x0 - T`, `B = v0 + omega A`, `omega = sqrt(k/m) = 34.641`. From rest, 0 to 1: x(0.100) = 0.8603, x(0.150) = 0.9657, x(0.200) = 0.9922, x(0.250) = 0.9983, x(0.333) = 0.99988; frame values at 30 fps: 0.321, 0.671, 0.860, 0.945, 0.979, 0.992, 0.997, then settled (8 distinct frames). Semi-implicit Euler at 1/30 s is unstable (c dt = 2.31) and is used only as a test reference with 14.4 ms substeps.

### 5.4 Scenario list (each is a DaylightKit test)

Engage only on stylus contact with pressure > 0 (finger, palm, hover, pressure 0, mouse rejected); eraser contact engages only with `engageOnEraser`; ENGAGING settles to LIVE at 0.251 s (within one tick); progress at 0.100 s = 0.8603 within 1e-3; snap-back at cancel 60 ms with progress 0.11 -> PASSTHROUGH, cancel at 90 ms stays ENGAGING; pre-warning at exactly 85.0 s, RETURNING at 90.0 s, PASSTHROUGH 0.251 s later with exactly one `savePage(.returned)`; any ink cancels pre-warning; ink mid-return retargets with |progress(t+) - progress(t-)| < 1e-9; pin during RETURNING -> ENGAGING pinned; engage during RETURNING -> ENGAGING; pin suppresses return at 200 s, unpin returns at unpin + 90 s; pin from PASSTHROUGH engages; pen on glass (start without commit at 80 s) freezes the timer (no return at 300 s); clear unpinned -> [savePage, clearCanvas] then RETURNING; clear pinned -> [savePage, clearCanvas], stays LIVE; clear twice on a pinned board saves once; clientGone and allClientsGone never change state; sourceChanged clears contacts; hold modes disable the timer and `hold(auto)` restarts it without touching `pinned`; layout hotkey toggle semantics; `ms_to_return` values per state; STATE fields derived from output; ink during RETURNING under `hold(camera)` or with auto-engage off stays RETURNING (bookkeeping only); a snap-back needs an engage the stroke itself caused (`!pinned`, `hold == auto`); a clientGone that empties the contacts of a LIVE board at 110 s gives the pre-warning at 195 s and the return at 200 s.

---

## 6. Studio Split geometry (1920x1080 output, exact)

### 6.1 Static Studio Split, portrait canvas (s = 1)

| Element | Rect (x, y, w, h) | Notes |
|---|---|---|
| Studio zone | (0, 0, 1280, 1080) | two thirds |
| Canvas, 3:4 letterboxed, height-limited | (235, 0, 810, 1080) | 1080 * 3/4 = 810; (1280 - 810) / 2 = 235 |
| Cream margins (SurfaceCream) | (0, 0, 235, 1080) and (1045, 0, 235, 1080) | painted by the clear colour |
| Paper border lines (BorderSubtle, 1 px) | (235, 0, 1, 1080) and (1045, 0, 1, 1080) | |
| Divider (InkBlack, 2 px) | (1279, 0, 2, 1080) | |
| Presenter column | dest (1280, 0, 640, 1080); source x in [640, 1280) of the 1920-wide frame, UV u in [1/3, 2/3], v in [0, 1] | crop, no scaling |

Clip-space values at s = 1 (l, t, r, b): canvas (-0.75521, 1, 0.08854, -1); presenter (0.33333, 1, 1, -1); divider (0.33229, 1, 0.33438, -1). Conversion: `l = x/1920*2-1`, `r = (x+w)/1920*2-1`, `t = 1-y/1080*2`, `b = 1-(y+h)/1080*2`.

### 6.2 Animation (progress s in [0, 1], divider position d = 1280 s)

- Presenter dest `(d, 0, 1920 - d, 1080)`, source x in `[d/2, 1920 - d/2)`, UV u in `[d/3840, 1 - d/3840]`. At s = 0 this is the full untouched frame, so frame 0 of the slide is pixel-identical to passthrough (no pop). No scaling at any s.
- Studio panel offset `ox = d - 1280`: canvas `(235 + ox, 0, 810, 1080)`, border lines at `235 + ox` and `1045 + ox`, cream margins move with the panel; scissor rect `(0, 0, d, 1080)`.
- Divider `(d - 1, 0, 2, 1080)`, alpha = s.
- Return uses the same formulas with s running down; retarget mid-flight is continuous.
- Pre-warning: divider colour = `mix(InkBlack, Amber, breath)`; nothing else moves.

### 6.3 Whiteboard Only

Canvas `(555, 0, 810, 1080)`, cream margins 555 px each side, border lines at 555 and 1365, no presenter, no divider. Slide: the panel enters from the left with the same spring, `ox = 1920 (s - 1)`, presenter fades out under it (scissored). Switching between Studio Split and Whiteboard Only while LIVE is an immediate layout switch (no second spring in v1).

### 6.4 Landscape canvas (mirror session packet 1600x1200, or a 4:3 PAGE_CHANGE)

Oracle variant: canvas `(0, 0, 1440, 1080)`, presenter dest `(1440, 0, 480, 1080)` with source x in `[720, 1200)` (central 480 px), divider `(1439, 0, 2, 1080)`; animation with `d = 1440 s`, presenter source `[d/2, 1920 - d/2)`. Whiteboard Only landscape: canvas `(240, 0, 1440, 1080)`. Aspect-fitting 4:3 into the 810x1080 slot would give a 608 px tall picture and is not done.

### 6.5 Mirror crop fit

The cropped tablet image is aspect-fitted into the canvas slot with cream bars: the default portrait crop 1200x1504 (top 96 px removed) fits at scale 0.675 to 810x1015 with about 32 px cream bars top and bottom. Crop insets are fractions of the session size at render time (D40).

### 6.6 Canvas sampling

Ink and highlighter are 1200x1600 premultiplied BGRA IOSurfaces sampled with linear filtering into the slot (1.48x supersample). Fragment: `paper = PaperBg; hl = sample(highlight); under = paper * ((1 - hl.a) + hl.rgb); ink = sample(ink); out = ink.rgb + (1 - ink.a) * under; alpha = 1`. Stroke width per segment: `baseWidth * (0.55 + 0.9 * pressure)`, round caps and joins.

---

## 7. Pin, Clear, Return, New page (one place)

| Action | Inputs (all equivalent) | Behaviour |
|---|---|---|
| Pin toggle | tablet chip tap; overlay pill "Pin"; pen side button double press (mirror mode, when the mode includes the pen button); hotkey K; menu "Keep whiteboard" | Pinned: no idle return, no pre-warning, chip reads KEEP WHITEBOARD. From camera it brings the board up without drawing. During the return countdown it keeps the board (re-engages). Unpinning gives a fresh 90 s. |
| Clear | tablet toolbar "Clear"; overlay pill "Clear"; pen side button long press (700 ms); hotkey C; menu "Clear" | (1) save the page if it has ink, (2) clear both layers and the undo stack, (3) return to camera unless pinned (from ENGAGING too). In mirror mode step 2 is skipped (the note app owns its canvas) and step 1 saves `mirror-<HH-mm-ss>.png`; the return still happens unless pinned. |
| Return | chip long press (600 ms); hotkey Esc; menu "Camera"; AUTO_ENGAGE_RETURN | unpin and slide back now |
| New page | tablet toolbar; PAGE_CHANGE | save the current page if it has ink, start a blank page, board stays up |
| Whiteboard now | menu; hotkey W or D from camera | engage without drawing (Whiteboard Only for W, Studio Split for D) |
| Hold | menu "Hold: Camera / Studio Split / Whiteboard Only / Auto" | forces a layout and disables the idle timer; "Auto" re-arms; `pinned` is untouched |

Side-button windows are settings (`sideButtonDoublePressMs` 400, `sideButtonLongPressMs` 700, `sideButtonSwap` false). If no side-button event is observed on the pen node after 30 s of inking while the mode includes the pen button, the Mac shows "Pen button events not seen; use the pills" (failure row 28b).

---

## 8. The three ink sources and how the owner switches

Menu bar > "Ink source" > Web / Daylight Ink app / Mirror (also in Settings). Switching takes effect immediately: the Mac broadcasts STATE with the new `ink_source` byte and bit3 (active source) so a tablet on the wrong source shows "Ink source is <web|native|mirror> on the Mac" instead of silently not drawing. Exactly one connection is the active ink client per source (the most recent allowed handshake of that role); overlay pills, the self-test client and hotkeys work in every source.

| Source | Tablet side | What crosses the wire | Latency class | Engage detector | Pin/Clear inputs |
|---|---|---|---|---|---|
| Web | Chrome on the DC-1 at `http://<mac>:7788`, added to the home screen | SolStream strokes (tens of bytes per sample) | pen to camera about 35 to 60 ms | STROKE_START with stylus, contact, pressure > 0 | chip, toolbar, hotkeys |
| Native (Daylight Ink) | the APK, mDNS auto-connect, adb reverse on USB | SolStream strokes | same as web, slightly lower (unbuffered dispatch, TCP_NODELAY) | same | chip, toolbar, hotkeys, pills |
| Mirror | the tablet's own note app, mirrored over USB debugging | H.264 video of the screen (about 1 MB/s) plus `getevent` lines | 60 to 90 ms engage, 100 to 200 ms picture | `BTN_TOUCH DOWN` while `BTN_TOOL_PEN` on the Wacom evdev node | pills, pen side button, hotkeys |
| Mirror over Wi-Fi (Daylight Ink screen stream) | the tablet's own note app; Daylight Ink captures the screen (MediaProjection) and streams it over its WebSocket, no USB debugging | H.264 of the screen inside MIRROR_PACKET frames (PROTOCOL 14, up to about 1 MB/s) | engage on the second changed frame plus decode (estimated 100 to 250 ms; not yet measured), picture estimated 100 to 250 ms | frame differencing inside the canvas crop (`FrameDiffEngage`, failure row 37) | pills, hotkeys |

Mirror over Wi-Fi is the Mirror source with Settings > Mirror > Transport set to "Wi-Fi (Daylight Ink screen stream)" (`mirrorTransport = wifiStream`): the same crop, compositor and decoder as USB mirror, fed from the PROTOCOL 14 stream of an allowed Daylight Ink connection instead of scrcpy over adb, and engaged by frame differencing because no pen watcher exists without adb.

Web and native produce a vector record (JSON) and let the Mac render the ink; mirror shows any app on the tablet but produces no vectors. `docs/COMPARE.md` records the owner's measured numbers side by side.

---

## 9. Pairing flows per ink source

### 9.1 What must be true for "never again"

Persisted on the Mac: camera permission (system), extension approval (system), `onboardingDone`, allowed client ids with `seenOverUSB` (`clients.json`), login item (`SMAppService`), chosen webcam, ink source, hotkeys, mirror crop. Persisted on the tablet: web client id in `localStorage` plus the home screen icon; native client id in SharedPreferences; overlay permission (system); adb RSA authorisation ("Always allow from this computer"). Nothing is persisted per call.

### 9.2 Web (zero install)

1. The Mac menu bar shows "Open http://100.x.y.z:7788 on your Daylight" (Tailscale first when present, then Wi-Fi IPv4; a muted "http://<hostname>.local:7788 may also work on Wi-Fi" line last). Over USB with debugging on, one button "Open on the tablet" runs `adb reverse tcp:7788 tcp:7788` then `adb shell am start -a android.intent.action.VIEW -d http://localhost:7788`, which is a secure context (wake lock, coalesced events, installable).
2. On the tablet: one full-screen "Tap to start" sheet calls `requestFullscreen({navigationUI: "hide"})` and `navigator.wakeLock.request("screen")` when available; the page generates its client id once and connects to `ws://<same host>:<port>/ink`.
3. Wireless first connection: the Mac shows the Allow panel; loopback connections are allowed silently and marked `seenOverUSB`.
4. The chip's expanded card offers, as optional one-time steps: "Add to Home screen", "Get the Daylight Ink app" (link to `/daylight-ink.apk`), and the exact `chrome://flags/#unsafely-treat-insecure-origin-as-secure` string for this origin (from `/api/info`) with the explanation "better ink and the screen stays awake over Wi-Fi".
5. Every later day: tap the home screen icon.

### 9.3 Native (Daylight Ink)

1. Over USB: the Mac's "Set up over USB" runs `adb -s SERIAL install -r -d <Resources/DaylightInk.apk>` (`-d` lets the embedded debug APK replace a newer sideload), `adb -s SERIAL shell appops set com.twelve.daylight.ink SYSTEM_ALERT_WINDOW allow`, `adb -s SERIAL shell pm grant com.twelve.daylight.ink android.permission.POST_NOTIFICATIONS`, `adb -s SERIAL reverse tcp:7788 tcp:<bound port>` (the tablet always dials 127.0.0.1:7788; the Mac listener may sit on 7788 to 7799, section 11 and failure row 16), `adb -s SERIAL shell am start -n com.twelve.daylight.ink/.ui.MainActivity --es host <ip>:<bound port>` with the Tailscale 100.x address when present, else the Wi-Fi IPv4 (an IPv6 host takes the `[v6]:port` form). The app connects over loopback, is auto-allowed, and remembers the `--es host` value as its manual host for later wireless use.
2. Without USB: the web chip card's "Get the Daylight Ink app" downloads `/daylight-ink.apk`; the owner taps Install (one-time "allow from this source"), opens the app, which finds the Mac via Bonjour and waits for the Allow click.
3. Every later day: open the app (or it is still running); it reconnects by itself: mDNS, then 127.0.0.1:7788, then the remembered host.

### 9.4 Mirror (USB debugging in v1)

1. Tablet: Settings > About > tap Build number 7 times; Developer options > USB debugging; plug in; accept "Allow USB debugging" with "Always allow from this computer"; if SolOS shows "Disable adb authorization timeout", enable it (otherwise the authorisation expires after 7 days; UNVERIFIED on SolOS).
2. Mac: `adb track-devices` sees the serial; the Mac pushes `scrcpy-server-v4.1`, forwards the port, starts the server, enumerates input devices with `getevent -pl`, starts the pen watcher, and, if the Pin/Clear mode includes pills, installs the APK as in 9.3 and runs `adb shell am start-foreground-service -n com.twelve.daylight.ink/.OverlayService`. Settings shows the live mirror with four draggable crop edges.
3. Every later day: plug in; everything happens within about two seconds. Optional Settings toggle "Mirror over Wi-Fi" (D42) tries `adb connect <ip>:5555` when no USB device is present and says "Plug in once to re-enable Wi-Fi mirroring" when it fails.

### 9.4b Mirror over Wi-Fi without USB debugging

1. Mac: Settings > Mirror > Transport = "Wi-Fi (Daylight Ink screen stream)" with the ink source Mirror. Tablet: Daylight Ink is running, connected and allowed (9.3), and has announced the capability with MIRROR_STATUS (PROTOCOL 14.3); without one the Mac shows failure row 38.
2. The Mac sends MIRROR_CONTROL START (PROTOCOL 14.4) with `mirrorStreamMaxSize`, `mirrorStreamBitRate`, `mirrorStreamMaxFps` and `mirrorStreamKeyIntervalMs`.
3. The tablet shows the Android screen-capture prompt (Cancel / Start now). Start now begins the stream (MIRROR_HELLO, session, config, frames); Cancel reports CONSENT_DENIED and the Mac shows failure row 34.
4. While streaming, the tablet shows a persistent notification "Sharing screen with your Mac" with a Stop action; Stop ends the projection (PROJECTION_ENDED).
5. Consent is asked again after the projection ends (Stop, the system's cast control, or the app ending it); MIRROR_CONTROL STOP keeps the projection, so the next START needs no new prompt, and RELEASE ends it.

### 9.5 The Allow prompt

`AllowClientPanel`: a non-activating floating panel at the top right (never steals focus from Zoom), text "Allow 'Mike's DC-1' to draw on Daylight Camera? It connected from 192.168.1.40." Buttons Allow / Not now. 60 s auto-dismiss; while pending a menu item "Allow Mike's DC-1" mirrors it, so a dismissed panel is recoverable; the socket stays pending (ACK 1) until answered, never auto-denied. Allow writes `clients.json` and the waiting connection receives ACK 0 and STATE with bit2 set. Settings lists allowed tablets with Forget. The `overlay` role reusing an allowed ink client id never prompts.

### 9.6 Networks

Same Wi-Fi: Bonjour for the APK, numeric URL for the web page. Client-isolated office or school networks: USB (adb reverse, loopback) or Tailscale (100.x listed first; Bonjour and `.local` do not cross VPNs, so the APK gets the Tailscale host over USB once via `--es host`). No TLS in v1; Tailscale HTTPS is a loose end.

---

## 10. The tablet chip (web and native)

One pill, bottom centre of the toolbar in the apps, top centre overlay in mirror mode. Tokens only; 1.5 dp InkBlack border; zero elevation; PaperBg background by default.

| State (from STATE and connection) | Look | Text |
|---|---|---|
| searching / connecting | outline, TextMuted text | "Looking for your Mac" |
| ACK status 1 (bit2 clear) | outline, Amber dot | "Look at your Mac" |
| denied | outline, Terracotta text | "Not allowed by the Mac" (tap retries) |
| incompatible (ACK status 3, or the server did not echo `solstream.v1`; PROTOCOL 1 and 10) | outline, Terracotta text | "Update Daylight on your Mac" (tap retries once; no automatic re-dial) |
| refused (web only: five failed dials while `GET /api/info` answers as Daylight; Chromium hides whether the upgrade was refused or the subprotocol not echoed, LOOSE_ENDS E18) | outline, Terracotta text | "Mac found, socket refused. Tap to retry" (tap retries at once; otherwise one quiet re-dial every 60 s) |
| allowed but bit3 clear | outline | "Ink source is <web / Daylight Ink / mirror> on the Mac" (tap shows how to switch) |
| governor PASSTHROUGH | SurfaceCream fill, InkBlack text | "Camera" |
| ENGAGING or LIVE, not pinned | PaperBg fill, Amber dot | "LIVE" |
| pre-warning | Amber dot breathing in phase with the Mac divider | "Returning in N" with N = ceil(ms_to_return / 1000), counting down locally between STATE messages |
| RETURNING | outline, Amber dot | "Returning" |
| pinned (any state) | InkBlack fill, PaperBg text | "KEEP WHITEBOARD" |

Gestures: tap = pin toggle (during a countdown this is "keep it"); long press 600 ms = return to camera. Undo and redo toolbar buttons are enabled from STATE `undo_depth` and `redo_depth` (the Mac's truth). The chip never covers the canvas area that is mirrored; the pills live in the top strip the mirror crop hides.

---

## 11. Settings (`Settings` value, `Settings.validated()` clamps every range)

| Key | Type and range | Default | Used by |
|---|---|---|---|
| `onboardingDone`, `onboardingVersion` | Bool, Int | false, 1 | onboarding; menu "Setup again" resets the flag |
| `cameraUniqueID` | String? | nil (= `AVCaptureDevice.userPreferredCamera`) | WebcamCapture |
| `inkSource` | web / native / mirror | web | InkRouter, MirrorSource, STATE |
| `preferredLayout` | studioSplit / whiteboardOnly | studioSplit | compositor, hotkeys |
| `holdMode` | auto / camera / studioSplit / whiteboardOnly | auto (not persisted across launches) | governor |
| `autoEngage` | Bool | true | governor |
| `idleTimeoutSeconds` | Int 15...600 | 90 | governor |
| `preWarningSeconds` | Int 0...30 | 5 | governor |
| `springK` | Double 300...2400 | 1200 | governor (hidden; 600 for a slower slide) |
| `engageOnEraser` | Bool | false | governor (advanced) |
| `hotkeys` | action -> {keyCode, modifiers} | Ctrl+Opt+Cmd + W / D / K / C / Esc | Hotkeys (Carbon) |
| `port` | UInt16 | 7788 | WebServer (tries 7788...7799 when busy and shows the bound port) |
| `bonjourName` | String | "Daylight Camera on <hostname>" | WebServer |
| `trustLoopback` | Bool | true | ClientRegistry (advanced) |
| `allowedClients` | file `clients.json` | empty | ClientRegistry |
| `mirrorPinClearMode` | pills / penButton / both | both | mirror |
| `sideButtonDoublePressMs`, `sideButtonLongPressMs`, `sideButtonSwap` | Int, Int, Bool | 400, 700, false | SideButtonGestures |
| `mirrorCropInsetsPortrait`, `mirrorCropInsetsLandscape` | {top, left, right, bottom} tablet px | {96, 0, 0, 0}, {72, 0, 0, 0} | MirrorSource (fractions at render time); top inset 0 when pills are off |
| `pillStripHeight` | Int | 96 | published via `/api/info` so the APK places the pills inside the hidden strip |
| `mirrorPillsPosition` | top / bottom | top | sent to the APK (`--es pills`) |
| `mirrorMaxSize`, `mirrorBitRate`, `mirrorMaxFps` | Int | 1600, 8000000, 30 | ScrcpySession ("Low bandwidth" preset 1200 / 4000000 / 24) |
| `mirrorDeviceSerial` | String? | nil (first DC-1-looking device) | DeviceTracker |
| `adbServerMode`, `adbPrivatePort` | auto / shared / private, UInt16 | auto, 27180 | AdbServerPolicy |
| `mirrorOverWiFi` | Bool | false | mirror (D42) |
| `mirrorTransport` | usb / wifiStream ("USB (adb)" / "Wi-Fi (Daylight Ink screen stream)") | usb | mirror (9.4b, PROTOCOL 14) |
| `mirrorStreamMaxSize`, `mirrorStreamBitRate`, `mirrorStreamMaxFps`, `mirrorStreamKeyIntervalMs` | Int 320...1600, Int 1000000...8000000, Int 1...30, Int 500...10000 | 1600, 7000000, 30, 2000 | MIRROR_CONTROL START (PROTOCOL 14.4) |
| `mirrorDiffThreshold` | Double 0.0005...0.05 | 0.002 | `FrameDiffEngage.Config.changedFraction` (Wi-Fi mirror engage) |
| `viewerIdleStopSeconds` | Int 10...600 | 60 | idle rule (D32) |
| `saveDirectory`, `saveStrokesJSON`, `autosaveSeconds` | URL?, Bool, Int 15...600 | ~/Documents/Daylight Camera, true, 60 | SessionSaver |
| `previewOnLaunch`, `previewFloats` | Bool, Bool | false (true on unsigned builds), true | PreviewWindow |
| `frameReuse`, `deadlineIdle`, `perfLog` | Bool | false, false, false | pipeline (D34), Telemetry |
| `launchAtLogin` | read live from `SMAppService.mainApp.status` | | Settings toggle |

Tablet side (SharedPreferences / `localStorage`): `clientId`, `deviceName`, `manualHost`, `frontBuffer`, `unbufferedInput`, `sendPerEvent`, `pillsAtBoot`, `pillsPosition`, `flagHintDismissed`.

---

## 12. Saving

- Location: `~/Documents/Daylight Camera/<yyyy-MM-dd>/<HH-mm-ss>/` where `HH-mm-ss` is the session start (the first stroke after launch or after a 10-minute gap since the last ink). Files `page-01.png`, `page-01.json`, `page-02.png`, ... ; mirror mode writes `mirror-<HH-mm-ss>.png` (last decoded frame, cropped) and no JSON. `SessionFiles.uniqueURL` appends `-2`, `-3` on collision.
- Triggers: arrival in PASSTHROUGH after a return (`.returned`), Clear before clearing (`.cleared`), New page (`.pageChange`), autosave every 60 s while the page is dirty (overwrites the same two files), hold-to-camera (`.modeChanged`), and app quit (`.quit`, the app waits up to 2 s for the writer). Only pages with at least one stroke are saved; a page is dirty when `lastInkAt > savedAt`, so a pinned board cleared twice saves once and the ink-wins loop (LIVE -> RETURNING -> ENGAGING -> ... -> PASSTHROUGH) saves once.
- PNG: rendered from the stroke model (not the live IOSurfaces) at 1200x1600: PaperBg fill, highlighter strokes with multiply, ink strokes normal, `CGImageDestinationCreateWithURL` with `UTType.png.identifier`.
- JSON schema v1:

```json
{ "schema": "daylight-whiteboard-strokes/1", "app": "Daylight <version> (<build>)",
  "canvas": { "width": 1200, "height": 1600, "dpi": 200, "units": "canvas" },
  "session": { "started": "2026-10-03T14:05:09Z", "saved": "2026-10-03T14:21:40Z", "reason": "returned", "inkSource": "web", "clientLabel": "Chrome on Daylight" },
  "page": { "id": "uuid", "index": 1 },
  "strokes": [ { "id": "uuid", "tool": "pen", "color": "#FF111111", "baseWidth": 3.2, "points": [ [x, y, pressure, tMs], ... ] } ] }
```

`tMs` is milliseconds since the first point of the stroke (the wire `delta_ms` definition). Failure: menu shows "Could not save the whiteboard: <error>"; the page stays in memory and the next trigger retries.

---

## 13. Onboarding (Mac first run) and the failure matrix

### 13.1 Steps (window "Welcome to Daylight", shown while `onboardingDone == false`, reopened by menu "Setup again")

0. Location: if `Bundle.main.bundleURL.path` is not under `/Applications` or contains `/AppTranslocation/`, the step shows "Move Daylight to your Applications folder, then open it from there." with "Reveal in Finder" (the app never moves itself); the Install button of step 2 is disabled. On an unsigned build (`DaylightBuildSigned` false in Info.plist, written by CI) the step says "This is an unsigned test build. The virtual camera cannot be installed on this Mac. Use Daylight > Preview window to see the output." and the preview opens.
1. Camera: `AVCaptureDevice.requestAccess(for: .video)`; the preview shows the webcam immediately.
2. Install Daylight Camera: the activation request was already submitted at launch; the step mirrors its status; `requestNeedsUserApproval` shows the path for the running macOS (26 and 15: System Settings > General > Login Items & Extensions > Camera Extensions; 13 and 14: Privacy & Security > Security) with "Open System Settings" and "Check again"; the step turns green on `AVCaptureDevice.wasConnectedNotification` for a device whose `uniqueID` equals the fixed device UUID string, or when the sink connects.
3. Your Daylight: the primary card is chosen by context (a DC-1 on USB -> "Set up over USB", which does everything for the chosen source; otherwise the web URL card). All three source cards are reachable. The step turns green on the first allowed client or the first mirror frame.
4. Allow this Daylight? (wireless clients only).
5. Finish: launch at login (`SMAppService.mainApp.register()`), hotkey list, "Open Zoom and pick Daylight Camera" with a live thumbnail. Sets `onboardingDone`.

### 13.2 Diagnostics screen (Settings > Diagnostics)

Shows: build signed or not; extension status and the two `kCMIOStreamPropertyDirection` values; sink queue count and capacity; capture running or stopped by the idle rule with the viewer count; first-frame camera facts (size, fourcc, IOSurface-backed); passthrough zero-copy flag; listener state, bound port, Bonjour registered name, IP list; clients and their roles; adb server mode and version; scrcpy session size and codec; pen node name and path; last 200 log lines; a "Copy diagnostics" button.

### 13.3 Failure matrix (exact owner-facing text, log line, cause and fix); each row is one enum case

| # | Where | Owner sees (exact) | Log line | Cause and fix |
|---|---|---|---|---|
| 1 | launch | "Move Daylight to your Applications folder, then open it from there." (+ Reveal in Finder) | `bundle path not under /Applications: <path>` | Downloads or translocation; eject the DMG, drag to Applications |
| 2 | launch, unsigned build | "This is an unsigned test build. The virtual camera cannot be installed on this Mac. Use Daylight > Preview window to see the output." | `DaylightBuildSigned=false` | expected until signing secrets exist |
| 3 | camera permission | "Camera access is off for Daylight." (+ Open System Settings) | `AVAuthorizationStatus = denied` | Privacy & Security > Camera |
| 4 | no webcam | menu icon with a slash; preview shows a cream card "No camera found" | `cameras() returned 0` | plug in or Continuity Camera; retried on `wasConnectedNotification` |
| 5 | webcam not 1080p BGRA | Diagnostics: "Camera delivers <w>x<h> <fourcc>; composing every frame" (for example "Camera delivers 1280x720 NV12; composing every frame") | `first frame <w>x<h> <fourcc> iosurface=<bool>` | informational; passthrough runs through the compositor |
| 6 | extension error 2 | "The camera extension is missing an entitlement (build signing problem)." | `OSSystemExtensionError 2 missingEntitlement` | profile lacks System Extension; regenerate, re-run CI |
| 7 | extension error 3 | as row 1 | `... 3 unsupportedParentBundleLocation` | not in /Applications |
| 8 | extension error 4, 5, 6, 7 | "The camera extension inside this build is damaged. Download the build again." | code + `ls -R Contents/Library/SystemExtensions` | packaging bug; CI logs the bundle listing |
| 9 | extension error 8 | "macOS refused the extension's signature. This build is not notarized." | `... 8 codeSignatureInvalid` | notarize (tag or dispatch) |
| 10 | extension error 9 | "The extension's service name does not match its app group (build configuration)." | `... 9 validationFailed` | `CMIOExtensionMachServiceName` not under the app group; fix project.yml |
| 11 | extension error 10 | "Your Mac's security policy blocks system extensions (MDM or SIP setting)." | `... 10 forbiddenBySystemPolicy` | managed Mac |
| 12 | extension needs approval (13) | "Approve 'Daylight Camera' in System Settings > General > Login Items & Extensions > Camera Extensions, then click Check again." (13/14 wording variant) | `requestNeedsUserApproval` | user action |
| 12b | extension reboot | "Restart your Mac once to finish installing Daylight Camera." | `willCompleteAfterReboot` | reboot |
| 13 | extension ok, no device | "Daylight Camera is installed but not found yet. Retrying..." then after 30 s "Open Zoom or FaceTime once, or restart your Mac." | `sink: no CMIO device with UID <uuid>; devices=[...]` | slow enumeration; retry loop every 2 s |
| 14 | sink stream not found | "Daylight Camera has an unexpected stream layout." | `streams=[ids] directions=[v0, v1]` | index-1 fallback already applied; real bug otherwise |
| 15 | Zoom shows black | SETUP.md: "If Zoom shows a black picture, quit and reopen Zoom." | extension placeholder log | client cached the old extension |
| 16 | port busy | menu red dot "Port 7788 is in use. Daylight is using 7789." or "...Quit the other app or change the port in Settings." | `NWListener failed: <error>` | another instance or app |
| 17 | Bonjour renamed | nothing visible | `serviceRegistrationUpdateHandler .add <endpoint>` | harmless |
| 18 | nobody connects | after 60 s: "Nobody has connected yet. Same Wi-Fi? Office networks often block this: use USB or Tailscale." | none | client isolation |
| 19 | Allow dismissed | tablet chip "Look at your Mac"; Mac menu "Allow Mike's DC-1" | `client <id> pending` | click the menu item |
| 20 | web non-secure | tablet card shows the flag tip; everything else works | n/a | optional one-time flag |
| 21 | adb no device | "No Daylight found over USB. Is USB debugging on?" | `adb devices -l` output | enable debugging, cable |
| 22 | adb unauthorized | "Tap Allow on your Daylight (tick Always allow)." | `state=unauthorized` | RSA prompt |
| 23 | adb offline | "The Daylight is connected but not responding. Unplug and plug again." | `state=offline` | cable, adbd |
| 24 | adb version clash | "Another adb is running (Android Studio?). Daylight is using its own copy; a tablet already claimed by the other adb will not be visible." | `host:version mismatch <a> vs <b>` | private-port mode |
| 25 | scrcpy server fails | "The screen mirror could not start: <first [server] ERROR line>" | server stderr | version string, SolOS incompatibility |
| 26 | codec id 0 or 1 | "Your Daylight refused screen capture (codec error)." | `codec id = 0x...` | encoder issue |
| 27 | decoder error | picture freezes; status "Recovering video..." | `VTDecompressionSessionDecodeFrame status <n>` | drop until key frame; restart server after 12 s |
| 28 | no pen node | "Pen events not found on this Daylight. Mirror works, but auto-engage and the pen button do not. Use the pills or the Whiteboard hotkey." | `getevent -pl devices: [names]` | SolOS SELinux or different node |
| 28b | no side-button events | "Pen button events not seen; use the pills." | `no BTN_STYLUS after 30 s of inking` | SolOS swallows the button |
| 29 | pills invisible | tablet shows "Allow display over other apps" onboarding | APK log | grant overlay permission (or USB appops) |
| 30 | mDNS not found (APK) | APK "Looking for your Mac... Enter its address if this takes long" with a field | `discoverServices ...` | manual host |
| 31 | save failed | menu "Could not save the whiteboard: <error>" | `SessionSaver error` | Documents permission, disk |
| 32 | Wi-Fi mirror failed | "Plug in once to re-enable Wi-Fi mirroring." | `adb connect <ip>:5555 -> <stdout>` | TCP mode reset after reboot |
| 33 | capture stopped by the idle rule | Diagnostics: "Webcam capture is paused because no app is viewing Daylight Camera (LED off). It restarts within a second when a call starts." | `capture stopped: viewers=0 preview=hidden` | expected behaviour |
| 34 | Wi-Fi mirror consent denied | "Daylight Ink was not allowed to share the tablet screen. Tap the Daylight Ink notification on the tablet and choose Start now." | `mirror stream: consent denied by <label>` | MIRROR_STATUS CONSENT_DENIED; the owner tapped Cancel on the screen-capture prompt |
| 35 | Wi-Fi mirror encoder unavailable | "Your Daylight could not start its screen encoder. Restart Daylight Ink, or use Mirror over USB." | `mirror stream: encoder unavailable on <label> (state <n>)` | MIRROR_STATUS ENCODER_UNAVAILABLE or UNSUPPORTED |
| 36 | Wi-Fi mirror stalled | "The tablet's screen stream paused. Reconnecting..." | `mirror stream: no packet for <s> s from <label>; key frame requested` | no MIRROR_PACKET for 2 s while STREAMING (PROTOCOL 14.5); REQUEST_KEY_FRAME every 2 s |
| 37 | Wi-Fi mirror engage by frame differencing | "Mirror over Wi-Fi starts the whiteboard when the tablet screen changes. Plug in with USB debugging for pen-exact engage." | `mirror stream: engage source frame-diff (no USB pen watcher)` | informational; no `getevent` without adb |
| 38 | Wi-Fi mirror, no capable tablet | "Open Daylight Ink on your Daylight to mirror over Wi-Fi." | `mirror stream: no capable Daylight Ink connection` | no allowed connection announced MIRROR_STATUS |

`docs/TESTING-CHECKLIST.md` lists rows 1, 12, 13, 19, 21, 22, 28, 33 as the ones the owner triggers on purpose on day one.

---

## 14. Hotkeys

Carbon `RegisterEventHotKey` (no Accessibility permission). Defaults Ctrl+Opt+Cmd + W (Whiteboard Only toggle), D (Studio Split toggle), K (Keep/Pin toggle), C (Clear), Esc (Camera). Key codes: W 0x0D, D 0x02, K 0x28, C 0x08, Escape 0x35; modifiers cmdKey 1<<8, optionKey 1<<11, controlKey 1<<12. Semantics in section 7. Recorded in Settings; chords are registered with `kEventHotKeyExclusive`; a conflict shows "Already used by another app" (another process holds the chord exclusively) or "Already used by <Daylight action>" (the same chord bound twice inside Daylight). A chord another app registered non-exclusively fires in both apps and cannot be detected, a Carbon limit.

---

## 15. Performance budgets (measured, not asserted, on shared runners)

| Mode | Budget |
|---|---|
| Idle (no viewer) | under 1 percent of one core; capture stopped; camera LED off |
| Passthrough (viewer present) | our code under 0.1 ms per frame; Activity Monitor under 3 percent (AVFoundation's own delivery dominates) |
| Studio Split LIVE | CPU under 0.2 ms per frame for encode, GPU under 1 ms, Activity Monitor under 8 percent; resident set under 120 MB |
| Mirror LIVE | plus hardware decode; resident set under 180 MB |
| Engage | pen contact to the first moved frame leaving the Mac: under 60 ms (web, native), under 90 ms (mirror) |
| Slide | 8 distinct frames, no dropped frame during the slide |

Measurement: `OSSignposter` intervals (`capture`, `composite`, `ink.apply`, `sink.push`, `decode`), `Daylight --perf-log` (one line per second: mode, fps pushed, dropped, CPU ms per frame, GPU ms per frame, in-flight, zero-copy flag, capture running or idle), `docs/PERFORMANCE.md` with the owner's Activity Monitor readings.

---

## 16. Acceptance criteria per component (reviewer-checkable)

### A. DaylightKit (pure Swift, Foundation only)

- A1 `swift test` passes on ubuntu-24.04 and on macos-15 with the same sources; no `import` outside Foundation (and Dispatch) in `Sources/`.
- A2 Every golden case in `solstream-v1.json` decodes to the expected fields and every non-decode-only case re-encodes byte-equal; `Header.opcode` is `UInt16` and `decodeLenient` returns `nil` for an unknown opcode.
- A3 Governor scenario tests of section 5.4 pass under a manual clock stepping 1/30 s.
- A4 `CriticalSpring` closed form matches the section 5.3 values within 1e-4; retarget continuity asserted; the Euler reference at 1/30 s is shown to diverge.
- A5 Layout tests assert every number in section 6 (235, 810, 1045, 1279, 1280, 640, 555, 1365, 1440, 480, 240, UV 1/3..2/3, landscape source [720, 1200)) and that s = 0 equals passthrough for the presenter.
- A6 `StrokeStore` tests: start/append/commit produce one stroke in canvas units (x32 / 32); cancel removes; undo/redo depths; erase hit test precision at the radius edge; dirty rects; dot rule for one-point strokes; JSON round trip of section 12.
- A7 HTTP and WebSocket tests: request split across reads; lower-cased headers; traversal strings rejected; masked frames at 0, 125, 126, 65535, 65536 payload lengths; fragmentation; control frames; oversize rejection; `acceptKey("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="`; `SHA1("abc")` hex.
- A8 `Settings.validated()` clamps every range in section 11; `SessionFiles` names and collision suffixes.

### B. Daylight app core (capture, compositor, server, ink router, saving, UI)

- B1 `Daylight --self-test` exits 0 on the macOS runner: renders Studio Split at s = 0, 0.5, 1 and probes cream margin, divider, paper and presenter pixels (render checks skipped with a warning when `MTLCreateSystemDefaultDevice()` is nil); starts `WebServer` on an ephemeral port; connects with `URLSessionWebSocketTask`; sends the golden handshake, stroke start, chunk and commit; receives ACK 0 (loopback) and a STATE with governor 1; asserts ink alpha along the stroke in the ink IOSurface; undo returns alpha to zero; prints `lipo -archs` of adb and the sha256 of scrcpy-server.
- B2 `WebServerLoopbackTests` cover the same socket round trip plus a 2 MiB frame -> close 1009 and an unknown-client handshake -> ACK 1 with STATE bit2 clear.
- B3 Passthrough is zero copy when the camera hands out IOSurface-backed 1920x1080 BGRA buffers (`stats.passthroughZeroCopy == true`), logs exactly once otherwise, and the first composed frame at s = 0 equals the presenter input on sampled pixels.
- B4 The idle rule (D32) is observable in `--perf-log` and Diagnostics; capture restarts within 1 s of a viewer appearing and the host pushes the last cached frame or a cream card immediately so the viewer never sees the extension placeholder flicker.
- B5 The Allow panel is `NSPanel` with `.nonactivatingPanel`; Zoom keeps focus while it is shown (manual check); the menu item mirrors it; `clients.json` records `seenOverUSB`.
- B6 Every failure row in section 13.3 maps to one enum case with the exact text; a unit test enumerates the cases and asserts the strings.
- B7 Saving produces `page-NN.png` and `page-NN.json` in the session folder with the schema of section 12; a pinned board cleared twice produces one file pair; autosave rewrites the same files.
- B8 Hotkeys register without an Accessibility prompt and follow the section 7 semantics (manual check on the owner's Mac).

### C. Camera extension and host-side sink client

- C1 The unsigned CI build compiles the `.systemextension` (with `CODE_SIGNING_ALLOWED=NO`, or with the logged ad-hoc fallback) and `ls -R` of `Contents/Library/SystemExtensions` appears in the log.
- C2 Both Info.plists carry the same three UUIDs; `CMIOExtensionMachServiceName` is `$(TeamIdentifierPrefix)com.twelve.daylight`; the extension's entitlements are exactly app-sandbox plus the app group.
- C3 The extension consumes the sink with a 90 Hz timer only while `sinkStarted`; `authorizedToStartStream` on the sink accepts only `signingID == "com.twelve.daylight"` when `signingID` is non-nil; the placeholder card is drawn only while `!sinkStarted && streamingCounter > 0`; the custom viewers property returns `streamingCounter`.
- C4 `SinkFeederTests`: with a `CMSimpleQueue` of capacity 1, two pushes give one enqueue and one drop; PTS strictly increasing; format description cached across 100 buffers and recreated on a size change.
- C5 On the owner's signed build: "Daylight Camera" appears in FaceTime with the placeholder before the host connects and with the webcam after; `systemextensionsctl list` shows `[activated enabled]`.

### D. Web whiteboard

- D1 `npm run typecheck`, `npm run build` and `npx playwright test` pass in CI with Chromium, viewport 1200x1600, `hasTouch`, `isMobile`.
- D2 `protocol.spec.ts`: the encoder reproduces every `c2s` golden hex inside the browser context; `decodeState` and the ACK decoder parse the `s2c` cases.
- D3 `pen.spec.ts`: a CDP pen stroke with forces 0.3, 0.6, 0.9 yields a 31-byte STROKE_START (pointer 0, phase 1, pressure 0.3), chunks in canvas units with monotonic `delta_ms` from the first point, and a COMMIT; a finger tap yields nothing; a pen `mousePressed` with `force: 0` yields nothing; hover yields nothing; `pointercancel` after >= 2 points and > 80 ms yields COMMIT, otherwise CANCEL.
- D4 `state.spec.ts`: chip texts and classes for scripted STATE sequences (section 10), tap sends TOGGLE_PIN -1, long press sends AUTO_ENGAGE_RETURN, undo/redo buttons follow depths, "Ink source is ... on the Mac" when bit3 is clear.
- D5 `reconnect.spec.ts`: re-dial with backoff; the offline ring replays a stroke; ACK 1 shows "Look at your Mac" and no ink is sent until ACK 0.
- D6 `touch-action: none` is set in CSS; `binaryType` is `arraybuffer`; the manifest is served as `application/manifest+json`; the page requests fullscreen and the wake lock on the Start tap when available and shows the flag string from `/api/info` on a non-secure origin.

### E. Android app and overlay

- E1 `./gradlew --no-daemon :app:assembleDebug :app:testDebugUnitTest` passes on ubuntu-24.04 with the committed wrapper (8.14.5), AGP 8.13.2, Kotlin 2.3.10, JDK 17, compileSdk 36, minSdk 30, targetSdk 33; the APK is signed with the committed debug keystore.
- E2 `SolStreamTest`: every `c2s` golden vector byte-equal; ACK and STATE decode; the UUID byte order is pinned by the stroke id vector.
- E3 `StrokeSessionTest`: history-then-current ordering, `delta_ms` from the first point, pressure normalisation for 0..1 and raw 0..4095 inputs, cancel emits STROKE_CANCEL and no COMMIT, per-frame batching with `sendPerEvent` off and per-event with it on.
- E4 `CandidatesTest` ordering: mDNS, 127.0.0.1:7788, manual host, `--es host`; de-duplication; failure rotation.
- E5 Manifest: every component with an intent filter declares `android:exported`; `OverlayService` has `foregroundServiceType="connectedDevice"`; the pills window is WRAP_CONTENT `TYPE_APPLICATION_OVERLAY` with `FLAG_NOT_FOCUSABLE | FLAG_KEEP_SCREEN_ON`, placed top centre inside the top 96 px; the overlay reuses the canvas's client id with role `overlay`.
- E6 Only `TOOL_TYPE_STYLUS` and `TOOL_TYPE_ERASER` draw; `requestUnbufferedDispatch(SOURCE_CLASS_POINTER)` in `onAttachedToWindow`; `ACTION_CANCEL` and `FLAG_CANCELED` cancel; the wet layer falls back to the dry view when `CanvasFrontBufferedRenderer` creation fails; `NoDelaySocketFactory` is installed on the OkHttp client.

### F. Mirror mode

- F1 Kit tests: `ScrcpyDemuxer` yields the same packets for a synthetic stream chunked at 1, 7 and 1460 bytes, re-emits a session on rotation, and reports codec ids 0 and 1 as errors; `AnnexB` splits 3- and 4-byte start codes, trims trailing zeros, extracts SPS/PPS, converts to AVCC; `EvdevParser` + `StylusContactMachine` emit contact edges only on `SYN_REPORT`, hover emits nothing, eraser and side buttons are distinguished, lines with and without the device prefix parse; `SideButtonGestures` double at 0 and 0.3 s, none at 0 and 0.5 s, long press at 0.7 s, swap setting; `AdbDevicesParser` handles the official example, serials with spaces, `*` noise lines and all states.
- F2 The launch sequence uses exactly the verified server arguments (`4.1`, `tunnel_forward=true video=true audio=false control=false cleanup=false video_codec=h264 max_size=1600 video_bit_rate=8000000 max_fps=30 send_device_meta=true send_frame_meta=true send_stream_meta=true send_dummy_byte=true`), reads the dummy byte with 100 x 100 ms retries, removes the forward after connecting, and terminates the child on stop.
- F3 `H264Decoder` creates the format description from SPS/PPS with NAL length 4, requests BGRA IOSurface-backed Metal-compatible output, allocates a block buffer that owns its memory per access unit, handles a format change through `CanAcceptFormatDescription` else wait/invalidate/recreate, and drops until a key frame after an error (restarting the server after 12 s without one).
- F4 Crop insets convert to fractions of the current session size; a 960x1280 fallback stream crops the same screen region (unit test with two session sizes).
- F5 `AdbServerPolicy` never runs `kill-server`; shared 5037 when versions match, private port otherwise with failure row 24.
- F6 The cable-free toggle follows D42 and shows row 32 on failure.
- F7 On the owner's device: pen contact engages within 90 ms, double press pins, long press clears, pills appear on the tablet and are absent from the camera picture, rotation keeps the crop region.
- F8 Wi-Fi stream golden (Kit `MirrorStreamTests`): every `mirror_cases` vector decodes to its fields and every non-decode-only case re-encodes byte-equal; the payloads of HELLO, session, config, key and delta fed to `ScrcpyDemuxer(expectsDummyByte: false)` yield device meta "DC-1", codec h264, session 1200x1600, config, key frame (pts 33333) and delta (pts 66666); `Control.resolved` follows the PROTOCOL 14.4 table (0 = default; max_size 320...1600 rounded down to a multiple of 16; bit rate 1000000...8000000, default 7000000; fps 1...30; key interval 500...10000 ms); the HELLO name is truncated to 63 bytes on a UTF-8 boundary.
- F9 Wi-Fi stream receiver rules (Kit `MirrorStreamReceiverTests`, PROTOCOL 14.5): MIRROR_PACKET before MIRROR_HELLO is logged once and dropped; a media packet whose size field differs from n, or a session packet with a payload, is dropped, resets the demuxer and requests a key frame at most once per second; no MIRROR_PACKET for 2.0 s while the last status said STREAMING emits the stall (row 36) and REQUEST_KEY_FRAME, again every 2.0 s.
- F10 Frame-diff engage (Kit `FrameDiffEngageTests`, `LumaGridTests`): a 48x64 luma grid (64x48 landscape) sampled at cell centres inside the crop with Y = (54 R + 183 G + 19 B) >> 8; a frame changed when at least max(4, ceil(0.002 x cells)) cells (7 on 48x64) moved by 24 or more; engage on the second changed frame within 0.25 s of the previous one, so a single clock tick followed by identical repeats never engages; release after 1.0 s without a changed frame.

### Integrator (project.yml, Makefile, CI, Package.swift, scripts)

- I1 Both workflows are thin (`make <target>` per step) and behave identically; the mac job needs golden, kit-linux, web and android; artifacts `Daylight-unsigned.zip` (always), `Daylight-signed.zip` (secrets), `Daylight.dmg` + `notarization-log.json` (tags or dispatch), `daylight-ink-debug.apk`, `web-dist`, Playwright report on failure, `xcodebuild-logs` always.
- I2 `make golden-check` fails when any of the four manifest copies drifts from `gen_golden.py`.
- I3 The unsigned mac build either builds the extension with `CODE_SIGNING_ALLOWED=NO` or records the ad-hoc fallback in the log; `xcodebuild -version`, `swift --version`, `xcodebuild -help` (once) and `ls -R Daylight.app` are in `xcodebuild-logs`.
- I4 `CURRENT_PROJECT_VERSION` equals `GITHUB_RUN_NUMBER` via an xcconfig; `DaylightBuildSigned` is written into Info.plist by the script.

---

## 17. The owner's two questions

**Is bundling adb and scrcpy-server a scalable customer strategy?** Size is not the problem: scrcpy-server is 717 KB, adb is one self-contained universal binary of a few MB (the exact size and `lipo -archs` are printed by the first mac CI run); the whole app stays well under 30 MB. The real costs for a general customer are: (1) every customer must enable Developer options and USB debugging and accept the RSA prompt, a developer gesture; (2) Android 11+ drops the authorisation after 7 days unless a hidden developer toggle is set, which contradicts "never again" (UNVERIFIED on SolOS); (3) a second adb on the same Mac (Android Studio, Homebrew) can fight ours for the USB interface; (4) Google's SDK License section 3.4 versus 3.5 for redistributing the prebuilt adb needs a legal read (scrcpy is the precedent; we ship Google's NOTICE and the Apache-2.0 text; the owner keeps the bundled adb as the default, and LOOSE_ENDS H1 adds a first-use download and an installed-adb option so either can become the default without a release redesign); (5) scrcpy-server uses hidden Android APIs and is pinned per Android release; (6) Android 13 wireless debugging has random ports and no auto-reconnect. Verdict: right for v1 and for a developer-leaning early customer base; make the native app the default consumer path (it needs no debugging at all) and measure how many customers actually use mirror mode. The end state for mirror mode is a Daylight-signed SolOS service exposing stylus state and a low-latency screen stream over a local socket with a one-tap trust flow, which replaces adb, scrcpy-server and getevent in one move. The APK's MediaProjection stream (same 12-byte framing so the Mac demuxer is reused) is the interim no-adb option.

**Strokes versus video?** The web and native sources send stroke deltas: tens of bytes per sample, roughly 20 to 40 ms from glass to the Mac's canvas, a vector export, and only our whiteboard. Mirror sends encoded video: 100 to 200 ms from glass to camera through the encoder, adb and VideoToolbox, any app on the tablet, no vector export. The "Ink source" switch exists so the owner can compare both on the same call; `docs/COMPARE.md` records the measured numbers. Sending "delta operations" between frames is what the H.264 encoder already does; a stroke protocol is the lower-latency, smaller, exportable form of the same idea and is the recommended default.
