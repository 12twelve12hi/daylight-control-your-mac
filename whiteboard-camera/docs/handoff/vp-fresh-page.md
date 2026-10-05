# Handoff: VP "fresh page and follow-up" (phase 5A, 2026-10-04)

Domain: the last call's drawing must never show in the next call (DRAWING-DEEP-DIVE D6), and the board is the follow-up after a call (D39, D40, D41, IDEAS-FROM-OTHER-PROJECTS Top 25 #5). Open items: `docs/LOOSE_ENDS.md` section FP. Status: `docs/STATUS.md` section "Fresh page and follow-up". Owner rows: `docs/TESTING-CHECKLIST.md` 2.24.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

## T1. Fresh page for a new call (D6)

| Piece | Where | Proved by |
|---|---|---|
| The rule: viewers 0 to 1 or more, the page has ink, no stroke open, the newest ink older than `FreshPage.idleSeconds` (600 s, a constant, not a setting), measured on the wall clock | Kit `Session/FreshPage.swift` | kit-linux and mac `kit-test`: `FreshPageTests` (9:59 keeps, 10:00 keeps, 10:01 starts, empty page, viewers 1 to 2, 1 to 1, 2 to 0, pen on the glass, clock moved backwards, a page from before a night's sleep) |
| The router: `viewersChanged(_:)` saves the page (snapshot first), starts a blank page with index 0 (the new call is a new session, so its first page is `page-01` again) and broadcasts STATE; `noteWake()` treats the next count as a new call; the ink time is also kept on the wall clock (`lastInkWall`), and the SPEC 12 session gap now counts a sleep too | `Ink/InkRouter.swift` | mac `make mac-test`: `InkRouterTests.testNewCallOnAStalePageSavesItBeforeAnnouncingABlankPage` (9:59 keeps the page; at 10:01 the save starts while the last STATE still shows the old page, the next STATE shows page 0 with no strokes and depths 0, the stroke is in `page-01.json` and dark in `page-01.png` at 1200x1600, the log line, a second viewer and an empty page do nothing, the next stroke opens a new session folder), `testAPageFromBeforeASleepIsFreshAfterTheWake`, `testAnOpenStrokeKeepsThePage` |
| Wiring: the sink's `onViewerCount` hops to ink.queue after `PipelineControl.setViewerCount` (so a STROKE_START that follows the count is handled after the fresh page); `NSWorkspace.didWakeNotification` calls `noteWake` | `App/AppDelegate.swift` `wirePipeline` | compile only (no hosted test drives `AppDelegate`); the router side is tested |

Log line (os.Logger through Telemetry, category `ink`): `fresh page: saved <n> strokes, idle <s> s, reason=new_call`. `<n>` is the page's committed stroke count; the page was saved now, or earlier by a return or an autosave (a clean page is not written twice).

The tablets see the new page without a protocol change: STATE carries `page_index` 0, `stroke_count` 0 and depths 0. Daylight Ink's `StrokeSession.applyState` clears on the index change or on the depths; the web page clears through `InkCanvas.applyDepths` (the Mac holds fewer strokes than the page, so the page drops them), as it already does for a Mac-side Clear.

Relaunch: the stroke store is not persisted, so a relaunched Daylight always starts on a blank page; nothing more was needed.

## T3. Strokes inside the PNG and T2. The board as the follow-up (D39, D40, D41)

Prepared by a manager in a separate worktree, then merged into T1 and reviewed line by line by the VP (APIs checked against the code base: `HotkeyBinding.defaultModifiers`, `Hotkeys.title`, `Hotkeys.keyName` maps P, `NSApp.activate()` is used elsewhere with the macOS 14 target). Nothing here has been compiled yet: CI is the first compiler.

| Piece | Where | Tests |
|---|---|---|
| `iTXt` chunk `daylight-strokes` with the page JSON (the same bytes as the sidecar), inserted before `IEND`, CRC32 by hand, always embedded | Kit `Session/PNGTextChunk.swift`; `Ink/PNGExporter.pngData`, `Ink/SessionSaver` (PNG built in memory, chunk added, `Data.write(.atomic)`) | `PNGTextChunkTests` (CRC vectors AE426082 and CBF43926, layout, round trip, one chunk after two inserts, bad signature, truncated, keyword rules); `SessionSaverTests` (chunk equals sidecar, PNG decodes at 1200x1600, chunk kept with the sidecar off) |
| `session.pdf` per session folder: one page per page PNG (then mirror PNGs) at the image's pixel size in points, atomic, `session-2.pdf` beside a PDF this app did not write, rewritten when the session grows | Kit `Session/SessionHandout.swift` (ordering, naming, idle rule on wall or monotonic clock, `HandoutTracker`, the send choice); `SessionSaver.writeSessionPDF`; `InkRouter.finishSessionHandout`, `writeHandoutIfIdle` (autosave tick), quit, a new session, and the T1 fresh page | `SessionHandoutTests`; `SessionPDFTests` (three pages and media boxes, four after a fourth save, a foreign PDF kept, no pages no PDF, through the router at 601 s) |
| Menu "Copy last page  (Ctrl+Opt+Cmd+P)" and "Send today's board..." after the "Whiteboard now" items; the chord is fixed (id 100, exclusive), a clash is logged | `App/MenuBar.swift`, `App/Hotkeys.swift`, `App/LastPage.swift`, `App/AppModel.swift`, two lines in `AppDelegate.wireHotkeys` | `SessionPDFTests` (clipboard PNG 1200x1600 on a private pasteboard, `canCopyLastPage`, the sentence "No saved board to send yet.", today's PDF chosen) |

Owner-facing strings: "Copy last page", "Send today's board...", "No saved board to send yet." (alert, button "OK"). OWNER-NEXT-STEPS "The daily gestures" quotes both menu items; TESTING-CHECKLIST 7.12 to 7.14.

Not done: request R1 of `docs/handoff/vp-ink-legibility.md` (draw LASER_POINT in `InkRouter`) needs `InkRasterizer.laser`, which is on the branch head but not in this checkout; it goes in after the next `git pull --rebase`.

## Requests for other domains

1. Kit `Governor/GovernorOutput.swift` (integrator): add `case newCall` to `SaveReason`; then `InkRouter.startFreshPageForNewCall` passes it through `newPage` (today the JSON says `pageChange`, LOOSE_ENDS FP-2). One line in `newPage`: take a `reason: SaveReason = .pageChange` parameter.
2. SPEC (integrator), exact new wording:
   - SPEC 5.2, after the table's "Timers" paragraph: "Fresh page for a new call (D6): when Daylight Camera's viewer count goes from 0 to 1 or more and the page holds ink whose newest stroke is older than 10 minutes (wall clock, so a sleep counts; no stroke open), the ink router saves the page and starts a blank page before any pen-down of the new call is handled. This is not a governor event: the board's state does not change."
   - SPEC 7, a new row after "New page": "| Fresh page for a new call | Daylight Camera's viewer count goes from 0 to 1 or more, the page's newest ink is older than 10 minutes | save the page if it has unsaved ink, start a blank page (index 0, a new session), board state unchanged; log `fresh page: saved <n> strokes, idle <s> s, reason=new_call` |"
   - SPEC 12, Triggers: add "a new call on a page whose newest ink is older than 10 minutes (`.newCall`, D6)"; and in Location: "the 10-minute gap is measured on the wall clock as well as the monotonic clock, so a sleep counts".
3. Web (`web/src/main.ts`): follow STATE `page_index` like Daylight Ink does (set the local `pageIndex` and a new `pageId` when the Mac's index differs and no local PAGE_CHANGE is pending), so the web page's next New page sends the right index. Today the Mac ignores the client's index, so nothing breaks.
4. Kit Settings (integrator): add `HotkeyAction.copyLastPage` with the default Ctrl+Opt+Cmd+P, so the chord gets a Settings > Hotkeys row and can be rebound; `Hotkeys.registerCopyLastPage` then goes away.
5. UI tests (Mac UI owner): insert `"Copy last page", "Send today's board..."` between `"Whiteboard now (Overlay)"` and `"Preview window"` in `DaylightUISession.menuOrder` (the subsequence check passes without it; the docs-to-UI check already asserts both through OWNER-NEXT-STEPS).
6. SPEC 12 (integrator): "Files also include `session.pdf` (every page image of the session folder, one PDF page each at the image's pixel size in points, written when the session ends: 10 minutes without ink by the wall or the monotonic clock, a new session, a fresh page for a new call, quit, or Send today's board; `session-2.pdf` when a PDF the app did not write is already there). Every `page-NN.png` carries the page JSON in an uncompressed `iTXt` chunk with the keyword `daylight-strokes`, also when Save strokes JSON is off." SPEC 14: "plus a fixed Ctrl+Opt+Cmd+P (Copy last page), not shown in Settings; a Daylight action bound to that chord takes it over."
7. Mirror sessions: one line after `saver.saveMirror(...)` in `AppDelegate.saveMirrorSessionIfNeeded` (`saver.writeSessionPDF(sessionStart: start)`) would give them a PDF; left out until the owner asks.
