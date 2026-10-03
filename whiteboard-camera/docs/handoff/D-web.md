# Handoff: component D, web whiteboard

Owner of this file: the web whiteboard agent. Paths owned: `web/**` (except `web/tests/golden/`, generated) and this file. Proven by the `web` CI job (`make web`: npm ci, typecheck, Vite build; `make web-test`: 17 Node unit tests, 46 Playwright tests against the fake Mac).

Writing rules apply: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

---

## 1. What was built

| File | Role |
|---|---|
| `web/src/protocol.ts` | SolStream-v1 encoder and server-message decoder (kept from M0; every c2s golden vector byte-equal, every s2c case decoded, in Node and inside Chromium). |
| `web/src/ring.ts` | Offline ring, 2000 points. Frames drawn while the socket is down or still pending Allow wait here and replay in order after ACK 0. Overflow drops the OLDEST whole stroke (start, chunks, commit together), never a partial one. |
| `web/src/chip-state.ts` | The SPEC section 10 chip as a pure function: connection phase plus the last STATE in, text, state token, tap meaning and long-press meaning out. Local countdown between STATE messages, breath formula `0.5 * (1 - cos(2 pi t / 2))`. |
| `web/src/chip.ts` | DOM binding of the chip: 250 ms countdown refresh, breathing amber dot (rAF), tap = TOGGLE_PIN -1, long press 600 ms = AUTO_ENGAGE_RETURN, tap on "Not allowed by the Mac" retries, tap on "Ink source is ... on the Mac" opens the card. |
| `web/src/tools.ts` | Toolbar: pen, highlighter, eraser, undo, redo, new page, Clear, the "?" card button. Undo and redo enabled only from STATE `undo_depth` and `redo_depth`. |
| `web/src/ink.ts` | Pen-only canvas. Three stacked canvases over PaperBg: highlight (amber under the ink), ink, wet (receives pointer events). Rules: `pointerType === "pen" && buttons !== 0 && pressure > 0` to start; fingers, palms, hover and pressure-0 presses are ignored and counted; pressure clamped to [0, 1]; `pointerrawupdate` used when present, else `getCoalescedEvents` when present, else plain `pointermove`; one STROKE_CHUNK per animation frame (chunks split at 4096 points); `delta_ms` since the first point, monotonic, saturating in the encoder; `pointerup` always COMMITs (a dot is a one-point stroke); `pointercancel` or `pointerleave` while down COMMITs when at least 2 points and over 80 ms, else STROKE_CANCEL; eraser sends ERASE_STROKES (radius 12) per sample with the ids it believes it erased; local undo and redo redraw from STATE depths (the local list and the Mac's list hold the same strokes in the same order); a new stroke after an undo discards the local redo tail. `bufferedAmount` policy: over 64 KiB keep accumulating, over 1 MiB thin intermediate points (start and commit always kept). |
| `web/src/ws.ts` | `InkClient`: offers `solstream.v1`; `binaryType = "arraybuffer"` before the first message; HANDSHAKE on open (`web;<clientId>;<label>`, 1200 x 1600, dpi 200); backoff 1000 ms x 1.7 capped at 15 s; PING every 10 s with RTT from PONG; re-dial on `visibilitychange` to visible and on `online`; ACK 0 -> live and ring replay; ACK 1 -> pending (ink ringed, nothing sent); ACK 2 -> denied, no re-dial until the owner taps the chip; ACK 3 -> incompatible. Incompatibility fallback: see UNVERIFIED 7. |
| `web/src/caps.ts` | `capabilities()` (secure context, wake lock, coalesced events, rawupdate, fullscreen, DPR, viewport, display mode) and `enterFullscreenAndWake()` (`requestFullscreen({navigationUI: "hide"})` plus `navigator.wakeLock.request("screen")`, re-requested on visibility). |
| `web/src/main.ts` | Wiring; the Start overlay (one tap = transient activation for fullscreen and the wake lock); `?host=<ip[:port]>` override; `/api/info` read once; the expanded card (Add to Home screen, `./daylight-ink.apk` link, the exact `chrome://flags/#unsafely-treat-insecure-origin-as-secure` string with this origin on a non-secure context, device facts); `window.__daylight` debug surface for the tests; two console lines for the owner's checklist. |
| `web/index.html`, `web/src/styles.css`, `web/public/manifest.webmanifest`, `web/public/icons/*` | Tokens only, 1.5 px borders, no shadows, `touch-action: none` on the paper and every layer, `viewport-fit=cover` with safe-area padding; manifest `display: fullscreen`, `orientation: portrait`, 192 and 512 px PNG plus SVG icons drawn from the tokens. |
| `web/tests/fake-mac.mjs` | The fake Mac (Node `ws` 8.22.0): serves `dist/`, `/healthz`, `/api/info`, `/daylight-ink.apk` (404 by default), upgrades `/ink`, echoes `solstream.v1`, answers HANDSHAKE per scenario (ACK 0, 1, 2, 3 or none), pushes STATE, records every frame at `GET /__frames`. Control: `/__reset`, `/__scenario`, `/__ack`, `/__state`, `/__close`, `/__dials`, `/__clients`. |
| `web/tests/solstream-node.mjs` | Independent Node decoder for every c2s opcode and encoder for ACK, STATE, PONG (the fake never shares code with the page it tests). |
| `web/tests/pen.ts` | CDP helpers: `penStroke` (`Input.dispatchMouseEvent` with `pointerType: "pen"` and `force`), `fingerTap`, `fingerDrag`, `penHover`, `penZeroPressureTap`, `penCancel` (synthetic `pointercancel`, CDP has none for pens), `FakeMac` client, `openWhiteboard`. |
| `web/tests/{protocol,pen,app,state,reconnect,secure}.spec.ts` | SPEC 16 D2 to D6 (the M0 smoke test is folded into `app.spec.ts`). |
| `web/tests/unit/{protocol,ring,chip-state}.test.ts` | Node tests for the pure modules (the SPEC numbers: 2000 points, 600 ms, breath values, ceil(ms / 1000), the chip table). |

Acceptance mapping (SPEC 16): D1 `npm run typecheck` (three tsconfigs: app, Node tests, Playwright specs), `npm run build`, `npx playwright test` with viewport 1200 x 1600, `hasTouch`, `isMobile`; D2 `protocol.spec.ts`; D3 `pen.spec.ts`; D4 `state.spec.ts`; D5 `reconnect.spec.ts`; D6 `secure.spec.ts` (plus `grep -n "touch-action: none" web/src/styles.css`).

Design choices worth knowing:

- The highlighter is drawn opaque on the wet layer (the layer element is 50 percent translucent in CSS) and transferred to the highlight layer as ONE path with alpha 0.5 on commit, so overlapping segments never darken. The Mac multiplies; the tablet shows simple alpha (LOOSE_ENDS F7).
- A stroke whose STROKE_START went out on a socket that then died is restarted: the Mac commits the first half on disconnect (SPEC D37) and the rest becomes a new stroke whose START is ringed in front of its points.
- Control messages (pin, return, undo, redo, Clear, New page) are never ringed: they mean something now or never. Ink and erase are ringed.
- The eraser sends ERASE_STROKES only; it never opens a stroke with tool 2 (the Mac's hit test is authoritative; the id list is a hint).

---

## 2. How to test on the real device (atomic steps)

Prerequisites: Daylight running on the Mac with "Ink source: Web"; the DC-1 on the same Wi-Fi (or on USB with debugging on).

1. On the Mac, read the line "Open http://<ip>:7788 on your Daylight" in the menu bar.
2. On the DC-1, open Chrome, type that URL exactly, press Go. Expect the cream page with "Tap to start".
3. Tap once. Expect: Chrome goes full screen (the status bar disappears); the chip at the bottom reads "Looking for your Mac" for under a second, then "Look at your Mac".
4. On the Mac, click Allow in the floating panel (or the menu item "Allow Chrome on Daylight"). Expect the chip to read "Camera".
5. Touch the pen to the page and write one word. Expect the chip to read "LIVE" with an amber dot within a quarter second and the ink to appear in Daylight Camera (Zoom or the preview window) a little later.
6. Rest your palm on the glass and swipe with a finger. Expect nothing drawn and no camera change.
7. Hover the pen 5 mm above the glass and move it. Expect nothing drawn.
8. Press the pen side button in the air. Expect nothing drawn; open the "?" card later to read the logged `button/buttons/pressure` values.
9. Tap "Highlight", draw across the word. Expect an amber band UNDER the black ink on the tablet and in the camera picture.
10. Tap "Erase", drag across part of the word. Expect the touched strokes to disappear on both sides.
11. Tap "Undo". Expect the last stroke to vanish on the Mac first, then on the tablet (the tablet waits for STATE). Tap "Redo". Expect it back.
12. Stop drawing and wait. At 85 s the chip reads "Returning in 5" and the dot breathes in step with the amber divider in the camera picture; at 90 s the chip reads "Returning", then "Camera".
13. Draw, then tap the chip. Expect "KEEP WHITEBOARD" (InkBlack fill). Wait 2 minutes: the board stays. Tap again: "LIVE" with a fresh 90 s.
14. Hold the chip for one second. Expect the picture to slide back to the camera and the chip to read "Camera".
15. Draw, tap "Clear". Expect the page blank on both sides and the picture back to the camera (unless pinned); a `page-01.png` and `.json` appear under `~/Documents/Daylight Camera/<date>/<session>/`.
16. Tap "New page" while LIVE. Expect a blank page, the board still up, the previous page saved.
17. Turn Wi-Fi off on the DC-1 for 5 s while writing, then on again. Expect the chip to read "Looking for your Mac" then "Camera" or "LIVE" again, and the strokes drawn during the gap to appear on the Mac a moment after the reconnect.
18. Chrome menu > Add to Home screen > Add. Close Chrome. Tap the new icon. Expect the page to open; tap Start once (full screen).
19. USB path: plug in, click "Open on the tablet" on the Mac. Expect Chrome to open `http://localhost:7788` on the DC-1 with no Allow prompt (loopback is trusted), and the "?" card to show "secure true", "wake lock true held", "coalesced true".
20. Wi-Fi path, optional one-time step: open the "?" card, copy the `chrome://flags/...` string and the origin, paste them in Chrome's flags page, Enabled, Relaunch. Expect the card to show "secure true" afterwards.

Console lines to copy into LOOSE_ENDS section D (Chrome menu > More tools is not available on the tablet; the "?" card shows the same facts, so read them there):

- `daylight-web caps {"secureContext":...,"wakeLock":...,"coalescedEvents":...,"rawUpdate":...,"predictedEvents":...,"fullscreen":...,"bigUint64":...,"devicePixelRatio":...,"viewport":[w,h],"userAgent":"...","displayMode":"..."}` (D8: Chrome version from the user agent, DPR, viewport, display mode of an A2HS launch)
- `daylight-web first pen pointerdown button=<n> buttons=<n> pressure=<p> tiltX=<n> tiltY=<n>` (D3 pressure range, D4 side button; the first pen contact only)

---

## 3. UNVERIFIED items shipped behind a runtime fallback

| # | Fact | Fallback in place | How the owner confirms |
|---|---|---|---|
| 1 | DC-1 Chrome version, `devicePixelRatio`, CSS viewport, display mode of a home-screen launch (LOOSE_ENDS D8) | Canvas units are DPR-independent (1200 x 1600 fixed; backing store scales with DPR); the Start tap always offers the Fullscreen API regardless of the manifest | the `daylight-web caps` line and the "?" card |
| 2 | Pressure above 1.0 from the digitizer (D3) | `clampPressure` before quantising; the suite proves 1.4 becomes 255 | the first-pen console line |
| 3 | Side button `button` / `buttons` values in Chrome on the DC-1 (D4; source says left button, pressure 0 while hovering) | the side button is bound to nothing; a pen `pointerdown` with pressure 0 is ignored (counted as `ignored`) | step 8 above; the first-pen console line while pressing the button in the air |
| 4 | Whether the digitizer suppresses finger touch while the pen is in range, and whether SolOS palm rejection ever cancels the PEN pointer (D9) | touch pointers are ignored entirely; `pointercancel` on the pen pointer commits after 2 points and 80 ms, else cancels | step 6 with the palm resting; watch for truncated strokes |
| 5 | `pointerrawupdate` removed on non-secure origins from Chrome 142 (research F14) | feature-detected each load: rawupdate, else `getCoalescedEvents`, else plain `pointermove` at the frame rate | the "?" card shows `rawupdate` and `coalesced` |
| 6 | Legacy Add to Home screen honouring `display: fullscreen` on a non-secure origin | the Start tap calls `requestFullscreen` every launch; leaving fullscreen brings the Start tap back | step 18 |
| 7 | Chromium refuses an upgrade whose offered subprotocol is not echoed before `onopen` (observed with Chromium 141 headless in the suite; the page only sees closes, never `ws.protocol`) | after five consecutive failures without an ACK the page fetches `/api/info`; a `"app":"daylight"` answer means reachable but refusing the socket (an old protocol looks the same from the page): since review round 1 (web-12) the chip reads "Mac found, socket refused. Tap to retry" (SPEC 10, web-only row), a tap retries at once and the client re-dials by itself every 60 s; "Update Daylight on your Mac" is kept for ACK status 3. With a real Mac the Swift server echoes the subprotocol, so this path should never show | none needed; `reconnect.spec.ts` covers the fake |
| 8 | Wake lock behaviour on SolOS Chrome in fullscreen (released on hide, re-requested on visible) | `caps.ts` re-requests on `visibilitychange`; the card shows "wake lock true held" or "refused" | step 19: leave the tablet alone for its screen-timeout period while LIVE |
| 9 | `http://<hostname>.local:7788` resolving on SolOS (research F32, F33) | the page never relies on it; the Mac shows numeric URLs first | the owner may try the `.local` line once |
| 10 | The wire `Content-Type` Chrome needs to offer Install for `/daylight-ink.apk` (E15, Mac side) | the card links `./daylight-ink.apk`; a 404 in a build without the APK is shown by Chrome as a plain error | step: tap "Download Daylight Ink" in the card on a build with the APK |

---

## 4. Requests for the integrator

1. Owner-facing text not in the SPEC section 10 chip table: `"Update Daylight on your Mac"` for the incompatible phase (UNVERIFIED 7 above). Please add a row to SPEC section 10 (or tell D to reuse an existing row) so the text lives in one place; D changes `web/src/chip-state.ts` on request. Applied in f2d0d43: SPEC 10 has the row "incompatible" with that exact text; PROTOCOL 6.14 maps ACK 3 and the non-echoed subprotocol onto it; no change to chip-state.ts needed.
2. LOOSE_ENDS: a line for UNVERIFIED 7 (Chromium rejects a non-echoed subprotocol; the probe heuristic), and the web rows of section D above for D3, D4, D8, D9 with the two console lines as the collection method. Applied in f2d0d43: LOOSE_ENDS E18 and the D3, D4, D8, D9 rows.
3. The Mac server must keep three things the suite relies on, all already in PROTOCOL: echo `Sec-WebSocket-Protocol: solstream.v1`; send STATE with bit2 set right after ACK 0 (the chip reads `allowed` from STATE, not only from the ACK); `GET /api/info` with `"app":"daylight"` (the incompatibility probe and the card use it). Applied in f2d0d43: recorded for B in ARCHITECTURE section 18 ("Facts B needs from the wave 1 handoffs") and LOOSE_ENDS E18.
4. ARCHITECTURE 2.5 file list: `web/src/chip-state.ts` (pure chip logic, Node-tested) and `web/tests/solstream-node.mjs` are additional files; `web/tsconfig.e2e.json` typechecks the specs. No change needed elsewhere. Applied in f2d0d43: ARCHITECTURE section 18 row "Web file list (2.5)".
5. Nothing else: no plist key, no make target, no golden change. `make web` and `make web-test` run unchanged (`web-test.sh` runs `npm run test:unit` then `npx playwright test`; the Playwright `webServer` is now `node tests/fake-mac.mjs 4173`). Noted in f2d0d43; the CI cancellation finding of section 5 became LOOSE_ENDS B16 and per-job concurrency in both workflows.

---

## 5. CI facts and red runs

CI facts (for ARCHITECTURE section 18 and LOOSE_ENDS): actions run 37108373686 (commit 312c82d), job `web` 111161238913: `make web` 8 s (npm ci, three tsc passes, Vite build: `index.html` 2.19 kB, CSS 4.44 kB, JS 31.64 kB); `make web-test` 72 s including the Chromium Headless Shell 141.0.7390.37 download (Playwright build 1194, the same build this box has at `/opt/pw-browsers`); 17 Node tests and `Running 46 tests using 1 worker ... 46 passed (43.1s)`; `web-dist` artifact 15823 bytes, 7 files. Slowest specs: the incompatibility probe (14.2 s, five backoff dials) and the backoff test (5.9 s).

Red CI runs caused by someone else's files: run 37108597555 (commit 9c2829d), job `kit-linux` failed (DaylightKit, component A); the web job of that run was then cancelled by the next push to the branch (`cancel-in-progress`), as were runs 37108373686 (web job already green) and 37108531802. With six agents pushing to one branch, a run survives only when no push lands within about five minutes; the web job needs about 2 min 30 s from queue to green.

---

## 6. Text for the owner-facing documents

### 6.1 SETUP.md, section "Web whiteboard (zero install)"

Open Chrome on your Daylight and type the address shown in the Mac's menu bar (it starts with `http://` and ends with `:7788`). Tap "Tap to start" once: the page goes full screen and keeps the screen on when it can. The first time, click Allow on the Mac. The chip at the bottom tells you what the camera is doing: "Camera" (the call sees your webcam), "LIVE" (the call sees the board), "Returning in 5" (five seconds of silence left; touch the pen to keep writing), "KEEP WHITEBOARD" (pinned). Tap the chip to pin; hold it for a second to go back to the camera. Only the pen draws; fingers and palms never do.

Over Wi-Fi the page runs on a plain `http://` address, which Chrome treats as not secure: the screen may dim on its own and strokes get one sample per frame. Two cures, pick one: plug the tablet in once and click "Open on the tablet" on the Mac (the `localhost` address is secure), or open the "?" card on the page and paste its `chrome://flags` line once into Chrome. Add the page to the Home screen from the Chrome menu so later days are one tap.

### 6.2 COMPARE.md, row "Web"

Pen to chip LIVE: well under a quarter second (the chip waits for the Mac's STATE). Samples per stroke: one per display frame on `http://<ip>` (45 to 90 Hz on the DC-1), the full digitizer rate on `localhost` or with the flag. Vector record: yes (the Mac saves PNG plus strokes JSON). Works without any install. Measured numbers to fill in: RTT from the "?" card (`rtt ... ms`), engage latency with the Mac's `--perf-log`.

### 6.3 TESTING-CHECKLIST.md rows (ADHD-friendly, atomic)

- 🟢 **Web page opens** (1 min): type the menu-bar URL in Chrome on the Daylight. See "Tap to start". ⏱️ 1 min
- 🟢 **Allow once** (1 min): tap Start, click Allow on the Mac. Chip reads "Camera". ⏱️ 1 min
- ✍️ **Write one word** (1 min): chip turns "LIVE", the board appears in the call. ⏱️ 1 min
- 🟡 **Palm and finger** (1 min): rest the palm, swipe a finger. Nothing happens. ⏱️ 1 min
- 🟡 **Side button in the air** (1 min): press it while hovering. Nothing drawn. Open "?" and copy the `first pen pointerdown` line into LOOSE_ENDS D4. ⏱️ 1 min
- ✍️ **Highlight, erase, undo, redo** (2 min): amber under black, erase removes, undo/redo follow the Mac. ⏱️ 2 min
- ⏱️ **Wait for the return** (2 min): "Returning in 5" at 85 s with the breathing dot, "Camera" at 90 s. ⏱️ 2 min
- 📋 **Pin and hold** (2 min): tap the chip, "KEEP WHITEBOARD"; hold it, back to camera. ⏱️ 2 min
- 🟣 **Clear and New page** (1 min): Clear blanks and returns; New page keeps the board up; files appear in Documents. ⏱️ 1 min
- 🟣 **Wi-Fi blip** (1 min): Wi-Fi off 5 s while writing, on again; the missing strokes arrive. ⏱️ 1 min
- 📋 **Home screen** (1 min): Add to Home screen, relaunch from the icon. ⏱️ 1 min
- 📋 **Copy the caps line** (1 min): open "?", copy the "This tablet" facts into LOOSE_ENDS D8. ⏱️ 1 min
- 🟣 **USB path** (2 min): plug in, "Open on the tablet"; "?" shows `secure true`, `wake lock true held`. ⏱️ 2 min
