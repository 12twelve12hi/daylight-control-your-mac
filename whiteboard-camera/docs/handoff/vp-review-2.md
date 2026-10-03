# Review round 2 (VP review, 2026-10-03)

Scope: `mac/Daylight/Sources/{App,Onboarding,Settings,Pipeline,Camera,Ink,Server,Contracts}`, `mac/DaylightCameraExtension`, `mac/DaylightKit` (except the Mirror parsers), `web/`, and their tests. Not touched: `Sources/Mirror/`, `android/`, `scripts/`, workflows, `project.yml`, `protocol/gen_golden.py`.

## How the round ran

- Twelve independent finders read the tree in six areas, two lenses each: camera (correctness and Apple API contract; concurrency and lifetime under extension replacement), frame pipeline (correctness and reproduction; start/stop races), ink router and server (two tablets and reconnects; protocol parity), web (flush/commit/undo alignment; protocol parity and the first-day owner), app core and DaylightKit (first-day owner; governor correctness), tests (hosted timing assumptions; `--self-test` coverage against SPEC 16). Every finder also audited the round-1 fixes of its area against their own findings.
- Every finding went to an independent refuter whose default verdict was "not real": it re-read the code, looked for guards, SPEC decisions and LOOSE_ENDS rows, and checked reachability. Verdicts: CONFIRMED, CONFIRMED-UNVERIFIED (real only if an unverified Apple or device behaviour holds), REJECTED.
- Confirmed findings were fixed by six fixers, one per area, each in its own worktree, with a test that fails before and passes after; the VP merged, resolved the cross-area conflicts and pushed in batches. GitHub Actions is the compiler.

Counts: 57 findings reached the refuters (including 14 test-timing findings and 4 coverage findings); 45 confirmed and 6 confirmed-unverified (3 of them duplicates across lenses, so 47 distinct, plus WEBA-01 and WEBB-02 fixed as one), 6 rejected; KITB-03 was split (hotkey part confirmed, ink part rejected); the VP reopened one rejected finding (WEBA-02). Every confirmed finding is fixed except the ones listed under "Deliberately not fixed".

## Findings, verdicts and fixes

Proving runs: see "CI runs" at the end of this file.

### Camera extension and host sink client

| ID | Finding | Verdict | Fix |
|---|---|---|---|
| CAMA-01 | SPEC 13.3 row 13's second sentence ("Open Zoom or FaceTime once, or restart your Mac.") never reached the menu, Diagnostics or onboarding: `FailureText.sentence` dropped the detail because the template has no placeholder; the 30 s clock ran from install, not from losing the device | CONFIRMED | `FailureText.sentence(_:detail:)`; AppModel and the onboarding row use it; `notFoundSince` resets on every connect (61f8cf4) |
| CAMA-02 | `ExtensionInstaller` delegate callbacks did not check which request they belonged to; a superseded request's callback cleared the live request (re-opens camera-05 once `deactivate()` is wired; "Check again" ordering variant) | CONFIRMED-UNVERIFIED (latent) | `request === self.request` guard in the three result callbacks; DEBUG `beginForTesting` (f817390) |
| CAMA-03 / CAMB-02 | The "Daylight is not running" card after Quit depended on CMIO calling the sink's `stopStream` for a dead client; the host never stopped the sink on Quit and the extension ignored `disconnect(from:)` | CONFIRMED-UNVERIFIED | Host: `CMIOSinkClient.stopAndWait(timeout: 0.5)` in `applicationShouldTerminate`; extension: `disconnect(from:)` stops the sink when the departing client is the authorised sink client (compared by `clientID`) (61f8cf4, d97e55d) |
| CAMB-01 | `stopStreamingSink` cleared `sinkStarted` while another host still had the sink started | CONFIRMED-UNVERIFIED | `DaylightExtensionRules.sinkStateAfterStop`: only the last stop clears it (d97e55d) |
| CAMB-03 = TSTA-01 | `testRow13GainsItsSecondSentenceAfterTheFollowUpDelay` waited a fixed 0.8 s for a 0.2 s timer with 0.2 s leeway (the e524f5b flake class) | CONFIRMED | expectation fulfilled by the status change, 10 s (61f8cf4) |
| Charter item 6 | Startup `fatalError`s in the extension: a packaging mistake (Info.plist keys missing or not UUIDs, `addDevice`/`addStream` failing, an unexpected device source) crash-looped the extension process | VP decision | No `fatalError` left in the extension: the UUIDs fall back to built-in values pinned against the built bundle's Info.plist (and asserted distinct); `addDevice`/`addStream` failures log a fault and the provider keeps running; a wrong device source throws an NSError (d97e55d) |
| TSTB-02 | SPEC C3 extension rules were compiled into the tests but never called | CONFIRMED | `ExtensionRulesTests`: sink signing-ID truth table, placeholder and forward tables, viewers value round trip through `ViewerWatcher.parseCount` (d97e55d) |

Round-1 audit: camera-03, camera-04, camera-06 close their holes; camera-02 is complete for new ids (same ids stay G1) and its new "device lost while connected" path led to CAMA-01; camera-05 led to CAMA-02. The CMIOSinkClient reconnect and re-validation logic and the ViewerWatcher listener lifecycle came out clean under both lenses (old listeners on dead ids are weak and never fire; the count is corrected within 1 s of a replacement).

### Frame pipeline

| ID | Finding | Verdict | Fix |
|---|---|---|---|
| PIPA-02 = PIPB-01 | Unplugging the webcam in use never fell back to another present camera (round-1 app-04 only handled a plug-in); the cream card stayed for the rest of the call | CONFIRMED | `handleLost` re-runs the SPEC 11 choice without the lost device (`WebcamCapture.replacement(afterLosing:)`) and emits restored (013be75) |
| PIPA-01 = PIPB-02 | The cream card was pushed once, before the sink connected or into a sink nobody watched; a later viewer got no frame at all | CONFIRMED | re-pushed on a viewer rise, a sink connect or the preview opening, in PASSTHROUGH with no camera picture flowing (7369d90) |
| PIPA-03 | Settings "Layout when engaging" never reached the governor | CONFIRMED | `GovernorConfig.preferredLayout`, applied through the pending-config path (66f9213) |
| PIPA-04, PIPB-03 | On capture restart the cached frame was pushed raw (even when not zero-copy eligible), after the blocking `startRunning()`, and even while the board was up | CONFIRMED (narrowed: the stale-overwrites-live part refuted) | pushed before `start()`, only in PASSTHROUGH, raw only when `isZeroCopyEligible`, else composed (7369d90) |
| PIPA-05 | A composed camera frame's GPU completion could push after the lost-camera card | CONFIRMED-UNVERIFIED (narrow window) | generation counter bumped on lost, checked under the card's lock (7369d90) |
| PIPB-04 | WebcamCapture's session, `running` and `input` mutated on two queues without a lock | CONFIRMED (low) | private `sessionQueue`; frames stay on the capture queue (013be75) |
| PIPB-05 | Pipeline callbacks assigned on main after render-queue work that reads them was queued | CONFIRMED (low) | every callback assigned before the first `setCaptureAuthorized` (222cf8f) |
| PIPB-06, TSTA-02, 08, 10, 11, 14, TSTB-04 | Pipeline tests with fixed windows or undrained queues | CONFIRMED | condition waits per the refuters' replacements; row 5 asserted exactly once (7369d90) |

Round-1 audit: app-02, app-03, app-06, app-11, app-12 and the 8056725 card fill hold; app-04 and app-13 were incomplete (PIPA-02, PIPA-05). Zero-copy eligibility per frame and the output pool bound (3 in flight, released after sink push and preview hand-off) came out clean.

### Ink router and server

| ID | Finding | Verdict | Fix |
|---|---|---|---|
| INKA-01 | A client demoted from active source mid-stroke had its CHUNK/COMMIT dropped; the governor contact leaked and the board never auto-returned | CONFIRMED | stroke frames for the connection's own open ids pass the active-source guard (bdec982) |
| INKA-03 | Allow clicked after the pending socket closed wrote nothing; the panel was never dismissed | CONFIRMED | registry written by clientId; panel rebinds to a pending redial or dismisses (bdec982) |
| INKB-01 | Every `/ink` connection leaked (HTTPConnection and InkConnection held each other) | CONFIRMED | `ink = nil` in `finish()`; weak-reference test (13a4de8) |
| INKB-02 | No Origin check on the `/ink` upgrade: any web page in a browser on the Mac could connect over loopback as role `test`, be auto-allowed, become the active source and draw into the live camera | CONFIRMED | a loopback socket whose Origin does not match its Host header is treated as a network client (Allow panel); role `test` only over loopback (13a4de8, bdec982) |
| INKB-03 | A HANDSHAKE the router dropped still disarmed the 5 s deadline (close 1001 at 30 s instead of 1002) | CONFIRMED (low) | ACK 3 and close 1002 for a malformed first HANDSHAKE (bdec982) |
| KITB-04 | The governor's late `clearCanvas`/`savePage(.cleared)` effects reached the ink queue after a stroke drawn after the Clear and wiped it | CONFIRMED (low) | `InkRouter.applyGovernorEffect` ignores the two effects the router already applied (e7fe41c) |
| TSTB-03, TSTA-07 | Self-test and loopback test read the store after a STATE that STROKE_START alone produces; "dropped" probes used fixed sleeps | CONFIRMED | PING/PONG ordering barrier (13a4de8) |

Round-1 audit: app-01, app-07, app-15 and the ACK/STATE order hold.

### Web whiteboard

| ID | Finding | Verdict | Fix |
|---|---|---|---|
| WEBA-01 + WEBB-02 | Strokes the offline ring dropped stayed in the page's list, and when the Mac held fewer strokes (ring drop or Mac relaunch) the prefix rule kept the oldest and deleted the newest, the ones the Mac had | CONFIRMED | `Ring.onDropStroke` and `InkCanvas.forget` (a partly dropped stroke goes whole; the stroke being drawn restarts under a new id); newest-end alignment; the ringed COMMITs counted on the first STATE after ACK 0 (7bfb613) |
| WEBA-03 | The in-flight commit guard compared totals, so a stale STATE after an Undo passed and blanked the tablet for one STATE | CONFIRMED (low) | stale while `undoDepth < visible` during an in-flight commit (7bfb613) |
| WEBB-01 | No receive liveness: after an outage over 30 s with no FIN or RST the page stayed live and sent ink, Clear and New page into a dead socket | CONFIRMED | 25 s since the last received frame plus a PING unanswered for a full interval closes the socket through the `onclose` path (7bfb613) |
| WEBA-02 | A stroke whose START went out by ring replay was not restarted on a second drop in the same contact | REJECTED (G3), reopened by the VP | `ink.markLive()` when the phase becomes live (7bfb613) |
| TSTA-03, 04, 06, 09, 13 | Playwright fixed waits and chunk-count assumptions | CONFIRMED | condition waits per the verdicts (b8a98de) |

Round-1 audit: web-01 and web-10 hold; web-02, web-04, web-07 and web-09 were incomplete (WEBA-01 to WEBA-03).

### App core and DaylightKit

| ID | Finding | Verdict | Fix |
|---|---|---|---|
| APPA-01 | Onboarding "Done" only hid the window; its 1 s poll (and a 5 s `adb devices`, starting an adb server even for web ink) ran all session | CONFIRMED | `close()` really closes; the poll belongs to the window controller (68cdc55) |
| APPA-02 | The menu's red banner was never cleared; the port sentence showed twice | CONFIRMED | banner cleared when the failure that set it resolves; `visibleBanner` (6982034) |
| APPA-04 | No single-instance guard (translocated copy plus the /Applications copy) | CONFIRMED-UNVERIFIED | pure `instanceDecision`; skipped under XCTest and `--self-test` (be24e37) |
| APPA-05 | A new save folder showed in Settings but applied after a restart | CONFIRMED (low) | `SessionSaver.setRoot`, ordered on io.queue (71591d1) |
| APPA-06 | The hotkey recorder named only five keys | CONFIRMED (low) | `Hotkeys.describe` (62f1aca) |
| KITB-01 | In LIVE, `engage` or `hold(auto)` during the pre-warning left it on for 90 s | CONFIRMED | through `touch()`; SPEC D55 (b5b958e) |
| KITB-02 | Pin (and engage or a layout hotkey during a return) under Hold: Camera brought the board up with the hold still set, so after unpinning it never returned | CONFIRMED | an explicit request releases the camera hold; SPEC D54 (b5b958e) |
| KITB-03 | Snap-back could fire for a board a hotkey or the menu brought up | CONFIRMED (hotkey/menu part) | `strokeCausedEngage`; SPEC D56 (b5b958e) |

Round-1 audit: kit-01, kit-02, kit-03, kit-05, kit-06, app-05/14, app-09, app-10 hold.

### Rejected (with the reason)

- INKA-02 (reconnect mid-stroke loses the tail on the Mac): the web client restarts the stroke under a new id with a fresh START (fe61586, pinned by `reconnect.spec.ts`), and the Mac committing the first part is SPEC D37 and PROTOCOL 13/6.4. Android has no ring and loses the tail of that one stroke: parity note for the Android owner (LOOSE_ENDS I).
- WEBB-03 (a second tab takes the active slot and the first is stuck): the newest web handshake taking the slot and the chip text are specified (SPEC 8, 10; PROTOCOL 8). Recorded as a spec gap (LOOSE_ENDS I).
- APPA-03 (`SettingsStore` didSet re-assignment): with `@Published` the re-assignment goes through the setter and `didSet` runs again (compiler source: a property wrapper has no direct storage), so the clamped value is saved and applied.
- KITB-03 ink re-engage part: allowed by SPEC 5.4; no save is lost (the page stays dirty).
- TSTA-05: zero pool drops once warm is the recorded decision of LOOSE_ENDS B24; the proposed tolerance would hide a pool regression.
- TSTA-12: the backoff upper bounds are what tell the steps apart.

### Reopened by the VP

- WEBA-02: a stroke whose START went out by ring replay was not restarted when the socket dropped again in the same contact, so the Mac discarded its tail. The refuter rejected it as recorded in G3; the VP reopened it because the fix is one call (`ink.markLive()` when the phase becomes live after the replay) and it closes a data-loss path.

## Deliberately not fixed

- PIPB-06 test 1 keeps `stats.dropped == coldDrops` and `coldDrops <= 2` (B24 decision); the GPU-stall flake risk the pipe-B refuter described stays recorded there.
- A Thread Sanitizer CI leg for PIPB-04/05 needs workflow and script changes (not this VP's files): requested below.

## UNVERIFIED items (each guarded or harmless if false)

- Whether CMIO delivers sink `startStream`/`stopStream` once per client (CAMB-01): the counter rule is correct either way; the consume timer stays bound to the newest client.
- Whether CMIO calls the sink's `stopStream` when a host process dies (CAMA-03): the provider's `disconnect(from:)` now stops the sink for the authorised client, and the host stops it on Quit; owner check: quit Daylight and `kill -9` it with FaceTime open, the card must appear.
- Whether macOS launches a second copy of Daylight from another path (APPA-04): the guard does nothing if it never triggers.
- Whether `ExtensionInstaller` can see a superseded request's error after the new request's approval prompt (CAMA-02): guarded by request identity.
- Whether Chrome's Local Network Access blocks a foreign page's WebSocket to 127.0.0.1 (INKB-02): the Origin rule holds either way.
- `CMIOExtensionClient.clientID` (macOS 12.3, Apple documentation fetched by the camera fixer).

## Requests to other owners

- Integrator (`scripts/`): `mac-debug.sh` and `embed-apk.sh` could fail under `CI=true` when the web build or the APK is missing (the self-test now asserts them, TSTB-01).
- Integrator (workflows): a Thread Sanitizer leg for the hosted tests (PIPB-04, PIPB-05).
- Android owner: a redial mid-stroke loses the tail of that stroke (no ring, no restart under a new id): parity with web-07 (INKA-02 note).
- Mirror owner (timing, not reviewed in depth): `DeviceTrackerTests` :34-38 and :49-58, `StylusWatcherTests` :136-139, `ScrcpySessionTests` :106-110 and :124-136 wait fixed windows.

## CI runs

| Run | Commit | Result |
|---|---|---|
| 37146462331 | be24e37 (camera, governor, app core) | golden, kit-linux, web, android green; mac compiled every fix and failed one assertion, `FailureCoverageTests` expecting 35 cases after a2ceaa1 added SPEC 13.3 rows 34 to 38 (fixed in fafc581) |
| 37146946169 | fafc581 (ink, server, self-test, pipeline) | golden, kit-linux, web, android green; mac failed to build on the mirror owner's f9c0102 (`Sources/Mirror/`), fixed by its owner in 54b5088 |
| 37148222326 | b8a98de (web) | golden, kit-linux, web, android green; mac built and every test in this review's areas passed; one failure in the mirror owner's new `WifiMirrorSourceTests.testFixtureStreamDecodesIntoTheSourceWithTheUSBCropRule` (LOOSE_ENDS I8), so `make mac-smoke` did not run |
| 37149014837 | 200667a (round-2 docs, on top of the mirror owner's edc0009) | every job green: golden, kit-linux, web, android, mac (`make mac-test` and `make mac-smoke`, including the new self-test bundle checks under `CI=true`) |
