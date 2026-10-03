# Handoff: component A, DaylightKit

Owner of this file: the DaylightKit agent. Paths owned: `mac/DaylightKit/Sources/DaylightKit/{Protocol,Governor,Spring,Layout,Canvas,HTTP,Settings,Session,Util}/`, the matching test folders under `mac/DaylightKit/Tests/DaylightKitTests/`, `protocol/gen_golden.py`, `protocol/golden/`, and this file. Proven by the `kit-linux` job (Swift 6.4 in the `swift:6.4-noble` container, language mode 5) and the `make kit-test` step of the `mac` job (Xcode 16.4).

Writing rules apply: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

---

## 1. What was built

The kit imports Foundation only (`grep -rn "^import" mac/DaylightKit/Sources` shows nothing else; Dispatch is used through Foundation's re-export in `Locked` tests only). Nothing in it logs, allocates a thread or knows about Apple frameworks. Every number in SPEC sections 5, 6, 11, 12 and 13.3 has a test before the code that uses it.

### 1.1 The section 3.5 fixes (first commits, so B, C and F compile against the frozen surface)

| File | What changed |
|---|---|
| `Settings/Settings.swift` | Every SPEC 11 key with the plan 3.3 property names and types; `HotkeyAction`, `HotkeyBinding`, `MirrorPinClearMode`, `PillsPosition`, `AdbServerMode`; `Settings.defaults`; `validated()` clamps 15...600, 0...30, 300...2400, 10...600, 15...600, `preWarningSeconds <= idleTimeoutSeconds - 1`, a port under 1024 becomes 7788, missing hotkeys come back as defaults. `holdMode` is omitted from `CodingKeys`. Decoding tolerates missing and unknown keys (every absent key keeps its default) so an older blob loads after an upgrade. `mirrorPillsEnabled` and `layout` are gone. |
| `Settings/FailureText.swift` | 35 cases in SPEC 13.3 row order with the plan 3.4 names; `sentence(_:_:)` is the "Owner sees (exact)" column, `logLine(_:_:)` the "Log line" column, both with in-order `<...>` substitution; `Case.row` gives the row label; `followUp(.sinkDeviceNotFound)` is the "after 30 s" sentence of row 13; row 12 defaults its one argument to `approvalPathModern` (`approvalPathLegacy` is the 13 and 14 wording). Row 16 has two shapes: two arguments give "Port 7788 is in use. Daylight is using 7789.", one argument gives the "Quit the other app..." form. Row 17 (nothing visible) returns an empty sentence and a real log line. |
| `Layout/StudioLayout.swift` | `frame(progress:layout:orientation:canvasAspect:breath:)` with every SPEC 6 rectangle; `amberBreath` mixes InkBlack toward Amber; `CanvasOrientation.aspect`, `.zoneWidth`, `init(width:height:)`; `passthrough()` divider colour is InkBlack at alpha 0. |
| `Session/SessionFiles.swift` | `<root>/Daylight Camera/<yyyy-MM-dd>/<HH-mm-ss>/`; `startsNewSession(lastInkAt:now:)` for the 10-minute gap; `uniqueURL` keeps working for names without an extension. |
| `Canvas/PageDocument.swift` | The SPEC 12 schema (`schema`, `app`, `canvas`, `session`, `page`, `strokes[]` with `[x, y, pressure, tMs]` point arrays); helpers `isoString`, `colorString`, `colorValue`, `toolName`, `tool(named:)`, `strokeValues()`. |
| `Canvas/StrokeStore.swift` | `start(_:scale:)`, `append`, `commit`, `commitAll`, `cancel`, `erase`, `undo`, `redo`, `clear`, `newPage`, `markSaved`, `document(...)`, `committedCount`, `hasInk`, `isDirty`, `pageAspect`, `stroke(id:)`. |
| `Canvas/Geometry.swift`, `Canvas/CatmullRom.swift` | New: point-to-segment and segment-to-segment distance, the eraser hit test; the Catmull-Rom to Bezier control points with the research note's formula, verified against the basis-matrix form. |
| `Protocol/Identity.swift` | Label at most 64 UTF-8 bytes (longer rejected), clientId non-empty and at most 64 bytes; `mayControl(_:)` for the PROTOCOL 8 role rule. |
| `HTTP/WebSocketFrame.swift` | Real RFC 6455 `parse`: 7, 16 and 64-bit lengths, mask required, reserved bits, control frames at most 125 bytes and never fragmented, `maxPayload` checked from the header before the payload arrives (`.oversize`); `encodeMasked` for test clients; `closeCode`; `WebSocketMessageAssembler` for fragment reassembly (`WebSocketError.badContinuation` added). |
| `HTTP/HTTPRequest.swift` | `statusText` for 403, 405, 413, 426 and a few more; `maxHeadLength` 16 KiB with `HTTPError.headTooLarge`; `isWebSocketUpgrade` also requires `Connection: upgrade`; `webSocketKey`, `webSocketVersion`; a `[UInt8]` overload of `parse`. |
| `Governor/Clock.swift` | `SystemClock.now()` is `ProcessInfo.processInfo.systemUptime` (monotonic); `ManualClock.set(_:)`. |
| `Governor/GovernorEvent.swift` | `InkSource`, `LayoutStyle`, `HoldMode` are `Codable`; `HoldMode.forcedLayout`; `InkSource.displayName` ("web", "Daylight Ink", "mirror") and `.jsonName`; `GovernorConfig(settings:)`. |
| `Governor/GovernorOutput.swift` | `GovernorOutput.stateReport(clientFlags:inkSource:pageIndex:strokeCount:undoDepth:redoDepth:)` builds the 20-byte STATE (pinned and pre-warning bits from the governor, the rest from the caller; counts saturate at 65535); `breathWeight(secondsSincePreWarning:)`. |
| `Governor/EngageGovernor.swift` | The full SPEC 5.2 table (section 1.2 below). |

### 1.2 EngageGovernor

A pure value. `handle(_:now:)` and `tick(now:)` return a `GovernorOutput` whose `effects` array is the only side channel; `snapshot` returns the same output with no effects. Time is the caller's monotonic seconds (B feeds `CACurrentMediaTime()` on the render path). The governor owns no timers: tick at 30 Hz while `needsTicks` (`state != .passthrough || hold != .auto`); `nextDeadline(now:)` serves the optional `deadlineIdle` flag.

Behaviour notes B must know:

- `stateChanged(from: .passthrough, to: .engaging)` is the signal to start the 30 Hz clock and render frame 0 synchronously; `stateChanged(to: .passthrough)` is the signal to stop it (unless a hold mode keeps `needsTicks` true).
- `savePage(reason:)` and `clearCanvas` are requests. The governor tracks "ink since the last save" and "ink since the last clear" heuristically from the events it sees (stylus contact, motion of a tracked stroke, activity, pen contact), so Clear on an untouched board emits nothing and a pinned board cleared twice saves once. SessionSaver still re-checks `StrokeStore.isDirty` before writing (an autosave the governor never saw may already have saved the page). `StrokeStore.isDirty` is false for a page with no strokes, so nothing empty is ever written.
- Eraser rule (D36): an eraser-tool stylus contact never engages from PASSTHROUGH unless `engageOnEraser`; its id is tracked so the lift clears it. In ENGAGING and LIVE it counts as activity; in RETURNING it re-engages (D36 says "cancels a return"), both as `.contact(... tool: .eraser)` and as `.eraserContact(down: true)`.
- `penContact(down: true)` engages with one sentinel id and freezes the idle timer until `penContact(down: false)`. It is honoured in every ink source (only F emits it, so no source check is needed inside the governor).
- `pin` from PASSTHROUGH engages even under `hold == .camera` (the table has no guard on that row); `engage` and `layoutHotkey` are blocked by `hold == .camera` as the table says. `autoEngage == false` tracks contacts but never engages from a contact or a pen contact.
- `msToReturn`: `idleTimeout - (now - lastActivity)` in milliseconds while LIVE and idle (hold auto, not pinned, no contact), 0 while RETURNING, `0xFFFFFFFF` otherwise. `breath` is `0.5 * (1 - cos(2 * pi * t / 2))` while the pre-warning is on, else 0.
- `generation` increments on every state change only (bookkeeping never bumps it), so B can use it as the stale-callback guard.
- Effects order: pin changes before state changes; for Clear: `savePage`, `clearCanvas`, then `stateChanged` when unpinned.

### 1.3 StrokeStore contract for the rasterizer

- `start` returns nil (nothing to draw); the first `append` returns `.drawSegments(strokeID:, fromIndex: 0)`. For `fromIndex > 0` the rasterizer strokes the segments from point `fromIndex - 1` to the end.
- Dot rule: a committed stroke with exactly one point returns `.drawSegments(strokeID:, fromIndex: 0)` from `commit`; the rasterizer fills a disc of diameter `Stroke.dotDiameter` at that point (CoreGraphics draws nothing for a zero-length line, and a round-capped zero-length path is UNVERIFIED on macOS, so the disc is explicit).
- `Stroke.bounds` is the point bounding box; `Stroke.dirtyBounds` inflates it by half the maximum width plus one pixel and is what `cancel`, `undo` and `erase` return in `.redraw`. `DirtyRect.clipped(toWidth:height:)` gives integer canvas pixels.
- Undo and redo are stroke based: `undoDepth` = committed strokes present, `redoDepth` = undone and redoable; a new commit discards the redo stack; `redo` returns `.drawSegments(fromIndex: 0)` (draw the whole stroke). Erase removes strokes for good (not undoable in v1; the clients redraw from STATE depths and their own erase hints, LOOSE_ENDS candidate).
- `erase`, `undo` and `redo` take an optional `now:` so the dirty stamp moves; pass it.
- `scale` is `(1200 / canvas_width, 1600 / canvas_height)` from the HANDSHAKE; points are scaled into our x32 units on append.
- `document(...)` writes `page.index` 1-based (like the file name `page-01`) and `baseWidth` rounded to three decimals (the wire carries a Float; 3.2 would otherwise print as 3.2000000476837158). Encode with `JSONEncoder` and `outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`: without the second option Foundation writes `"daylight-whiteboard-strokes\/1"` (valid JSON, ugly to read; CI run 37108706001 caught it).

### 1.4 Tests (acceptance A1 to A8)

| SPEC 16 | Test file(s) |
|---|---|
| A1 | every file; `kit-linux` and the mac `kit-test` step run the same sources |
| A2 | `Protocol/GoldenVectorTests.swift` (26 cases decode and re-encode), `Protocol/CodecLimitsTests.swift` (ACK 2 and 3, 24-byte STATE, limits, 26-byte start rejected, odd offsets) |
| A3 | `Governor/GovernorScenarioTests.swift` (31 methods, one per SPEC 5.4 sentence, several sentences get two), `Governor/GovernorTableTests.swift` (25 methods for the remaining rows), `Governor/GovernorHarness.swift` (manual clock at exactly `tickIndex / 30`) |
| A4 | `Spring/CriticalSpringTests.swift` (values at 0.100, 0.150, 0.200, 0.250, 0.333 within 1e-4; frames 0.321 ... 0.997; settle at tick 8 = 0.267 s, within one tick of 0.251; retarget continuity; Euler at 1/30 s diverges by step 3; 14.4 ms Euler stays bounded) |
| A5 | `Layout/LayoutTests.swift` (235, 810, 1045, 1279, 1280, 640, 555, 1365, 1440, 480, 240, UV 1/3..2/3, landscape 720..1200, clip-space values, s = 0 equals passthrough, mirror crop fit 810x1015.2) |
| A6 | `Canvas/StrokeStoreTests.swift`, `Canvas/GeometryTests.swift` |
| A7 | `HTTP/WebSocketFrameTests.swift` (0, 1, 125, 126, 127, 65535, 65536, 100000; split reads; fragmentation; control frames; oversize from the header; reserved bits; unmasked), `HTTP/HTTPRequestTests.swift` (split reads, lower-cased headers, traversal, accept key, `SHA1("abc")`) |
| A8 | `Settings/SettingsTests.swift`, `Settings/FailureTextTests.swift`, `Session/SessionFilesTests.swift`, `Util/UtilTests.swift` |

The snap-back scenario ("cancel at 60 ms with progress 0.11") is tested with `springK = 90` because the default spring is already at 0.61 after 60 ms; a second test pins the default spring (snap-back at 15 ms, none at one tick).

---

## 2. How to test on the real device (atomic steps, DaylightKit view)

The kit has no device-facing surface; these are the owner-visible behaviours that the governor and layout numbers produce, in the order they are easiest to check with Daylight Camera showing in the preview window or in FaceTime.

1. Touch the pen to the DC-1 and write one letter. Expect the picture to slide into Studio Split in about a quarter second with no pop at the start (frame 0 is the full webcam) and the whiteboard letterboxed in cream on the left two thirds.
2. Rest a palm, swipe a finger, hover the pen 5 mm above the glass, press the pen side button in the air. Expect nothing to engage.
3. Lift the pen and wait. At 85 s the divider starts breathing amber (one full breath every 2 s); at 90 s the picture slides back to the camera.
4. During the amber breathing, touch the pen once. Expect the breathing to stop and a fresh 90 s.
5. During the slide back, touch the pen. Expect the picture to turn around smoothly (no jump) and come back to the board.
6. Tap the chip (or press Ctrl+Opt+Cmd+K). Expect KEEP WHITEBOARD and no return for as long as you like; tap again and the return happens 90 s later.
7. Hold the pen on the glass without moving for two minutes. Expect no return (a pen on the glass freezes the timer).
8. Press Clear with the board unpinned. Expect a saved `page-01.png` and `page-01.json` under `~/Documents/Daylight Camera/<date>/<HH-mm-ss>/` and the picture back on the camera. Pin, draw, press Clear twice. Expect one new file pair, not two.
9. Open the `.json`: it starts with `"app"`, `"canvas"` and lists `"points"` as `[x, y, pressure, tMs]` arrays; `"page": {"index": 1}` matches `page-01`.
10. Press Ctrl+Opt+Cmd+W from the camera. Expect Whiteboard Only (paper centred, cream margins 555 px each side, no presenter). Press it again: back to the camera. Press Ctrl+Opt+Cmd+D while the board is up: Studio Split without a second slide.

---

## 3. Device facts and CI facts

- CI: actions run 37108531802 (kit-linux) compiled every new file on the first try with Swift 6.4 on x86_64 Linux; the only failures were four tolerance assertions comparing widths derived from a `Float` baseWidth at 1e-9 (fixed to 1e-6 in commit b59e898). The following run proves the kit on both platforms; its id is in the structured result of this component.
- `CodingKeyRepresentable` on `HotkeyAction` makes `Settings.hotkeys` encode as a JSON object keyed by action name (`{"whiteboardOnly": {"keyCode": 13, "modifiers": 6400}}`); it needs macOS 12.3 or later, fine for the 14.0 target, and works on Linux.
- `ProcessInfo.processInfo.systemUptime` exists in swift-corelibs-foundation; `UtilTests.testClocks` asserts monotonicity and that the value is an uptime, not an epoch.

---

## 4. UNVERIFIED items shipped behind a fallback

A is pure Swift, so there are no Apple API facts here. Judgement calls the owner or the integrator may want to flip (each is one line of code):

1. Eraser contact during RETURNING re-engages (D36 "cancels a return"); the literal table would leave it as bookkeeping. Fallback: none needed; flipping it means deleting two lines in `handleReturning`.
2. `pin(1)` from PASSTHROUGH engages even under `hold == .camera` (the table row has no guard). If the owner prefers the hold to win, add `guard hold != .camera` in `handlePassthrough`.
3. Clear and save effects are gated by the governor's own ink heuristic; the saver's `StrokeStore.isDirty` check is the second gate. Confirm on the Mac that a Clear on a board with ink always writes exactly one file pair.
4. The dot rule asks the rasterizer to fill a disc for one-point strokes; whether CoreGraphics also draws a round cap for a zero-length segment is unverified, so the disc is explicit.
5. The JSON `page.index` is 1-based to match `page-01`; the STATE `page_index` and `PAGE_CHANGE` stay 0-based. If the owner prefers 0-based in the file, change one `+ 1` in `StrokeStore.document`.

---

## 5. Requests for the integrator

1. None blocking. `Package.swift` needs no change (no new resources; fixtures are literals).
2. Optional golden additions (plan 4, step 8: `handshake_ack_denied`, `handshake_ack_unsupported`, a decode-only `state_extended_24`) were NOT added to `gen_golden.py`, to avoid turning `golden-check`, D's and E's case counts red on the same day. The same bytes are pinned by `CodecLimitsTests` instead (`da0102001000000040e2cfeeb540060080070000380400001e00000002000000` and `...03000000`). Add them to the oracle at M6 if the cross-client parity list (ARCHITECTURE 11.6) wants them; D and E then bump their counts from 26 to 29.
3. LOOSE_ENDS candidates: erase is not undoable in v1 (UNDO and REDO are stroke based per PROTOCOL 6.7); the web and native clients should mirror that rule.
4. The handoff README names this file `A-daylightkit.md`; the orchestrator's task text spelled it `a-daylightkit.md`. This is the only copy.

---

## 6. Text for the owner-facing documents

### SETUP.md (DaylightKit section, folded into the Mac section)

Nothing to set up: the kit is compiled into Daylight. The two numbers you may want to change live in Settings: the return delay (default 90 s, 15 to 600) and the amber warning (default 5 s before the return, 0 to 30). Advanced: `springK` 1200 is the quarter-second slide; 600 is a slower one that takes the whole third of a second.

### COMPARE.md (what the kit measures identically for all three ink sources)

The engage detector is the same value type for web, native and mirror: stylus contact with pressure above zero, never hover, never a finger. The slide, the 90 s return, the 85 s warning and the pin rules do not change between sources, so any difference you see in COMPARE is transport latency, not governor behaviour.

### TESTING-CHECKLIST.md rows (kit behaviours, about 6 minutes)

- 🟢 Pen touch engages, finger and palm do not (30 s)
- ⏱️ Amber breathing at 85 s, return at 90 s (2 min)
- ✍️ Pen during the return turns the slide around smoothly (20 s)
- 📋 Pin holds the board; unpin gives a fresh 90 s (2 min)
- 🟣 Clear saves once even when pressed twice on a pinned board (30 s)
- 🟡 `page-01.json` starts with `"app"` and has `[x, y, pressure, tMs]` points (30 s)

---

## 7. Red CI runs caused by someone else's files

None observed at the time of writing.
