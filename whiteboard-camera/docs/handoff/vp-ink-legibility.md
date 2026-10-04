# VP Ink Legibility (phase 5A)

Charter: T1 camera line weight (D14), T2 follow the pen wired, T3 laser pointer (LOOSE_ENDS F3). Branch
`claude/daylight-whiteboard-camera-tzxfjb`. This file is kept current after every push.

## T1. Camera line weight (D14)

State: DONE. Acceptance met in run https://github.com/12twelve12hi/daylight-control-your-mac/actions/runs/37230614396 (fa949ce): every job green, mac `make mac-test` with the new tests, `make mac-smoke` PASS. The first run (37229982052, 5653043) failed one of my assertions: the "1 px" test stroke is 1.0018 px because pressure 0.5 quantizes to 128/255; fa949ce widened that one tolerance, the clamp assertions were unchanged.

What changed:
- `DaylightKit/Layout/CameraLineWeight.swift`: the minimums, in output pixels at 1080p: pen (and every ink-layer
  tool) 2.5, highlighter 6.0, eraser none. The ink canvas reaches the output at `outputHeight / 1600` at rest (the page
  fills the frame height in Studio Split and Whiteboard Only), so the clamp is one canvas-space width for every output
  height: 3.70 canvas px for the pen, 8.89 for the highlighter. A call app's 720p downscale shows 1.67 px.
- `Pipeline/InkRasterizer.swift`: every segment and every dot is drawn at `max(tablet width, minimum)`. Redraw
  rectangles (erase, undo, redo) grow by `CameraLineWeight.redrawMargin()` (6 canvas px) and so does the hit test,
  because `Stroke.dirtyBounds` inflates by the true width and a clamped thin stroke would otherwise leave an edge.
- The stroke JSON, the PNG export (`Ink/PNGExporter.swift`, renders the store) and the tablet keep the true widths. The
  share window ("Daylight Whiteboard") samples the same canvas surfaces as the camera, so it shows the bolder line
  too; that is intended (it is a live output for the far side).

Decision: no setting. The pen's tablet width is 1.76 to 4.64 canvas px (base 3.2, pressure 0 to 1); the floor is 3.70,
so only light-pressure segments change, by at most 1.9 canvas px (1.3 output px at 1080p), and only on the live
outputs. A "Match the tablet" choice would cost a Settings field, a control and two docs strings for a difference the
owner cannot see on the tablet. If the 20-minute legibility test shows the floor is wrong, the two constants change.

Tests: `CameraLineWeightTests` (kit-linux and mac), `InkRasterizerTests` (a 1 px stroke covers at least 3.70 canvas
px, so 2.5 output px at 1080p and 1.67 at 720p; a 6 px stroke is unchanged; the highlighter minimum; erase of a
clamped stroke leaves no edge; a 1 px dot), `CompositorTests.testCameraLineWeightReachesTheOutput` (the same through
the Metal compositor into the 1080p output).

Requests:
- Ink (owner of `Sources/Ink/PNGExporter.swift`): the same clamp for the PNG is possible with one call to
  `CameraLineWeight.cameraWidth(_:tool:)` per segment and dot; it is not applied, so the saved page stays true to the
  tablet. Decide with the owner after the legibility test.
- SPEC: D14 needs a SPEC number (the two constants, the 1080p reference, "live outputs only").

## T2. Follow the pen, wired

State: DONE. Acceptance met in run https://github.com/12twelve12hi/daylight-control-your-mac/actions/runs/37231417812 (1928554): every job green; on macos-15 `make mac-test` (FollowFrameTests, FollowPenTests), `make mac-smoke` (PASS) and the UI test suite (with `checkFollowPen`) all succeeded.

What changed:
- `DaylightKit/Layout/FollowFrame.swift`: the rest zone per layout (Studio Split 1280 x 1080 at x 0, Whiteboard Only the whole frame, Overlay none), the slide offset, and `apply`, which swaps a frame's canvas quad for the follow quad moved by the slide offset and keeps the border lines on the quad's edges only while they lie inside the zone. At the full page it reproduces today's frames (tested through the slide).
- `Pipeline/FollowPen.swift`: `FollowPenSwitch` (process-wide, UserDefaults key `com.twelve.daylight.followPen.v1`), `InkActivity` (the rasterizer's inbox: segment boxes and page clears, ink.queue to render queue under a lock, at most 64 boxes between frames), `FollowDriver` (render queue: drains the inbox, stamps boxes with the frame time, `FollowCamera` for FP1 to FP9, reset on Clear and a new page, `setGeometry` without animation on a layout change, returns the layout's own frame untouched when off, for mirror pictures, for Overlay, and at rest on the full page).
- `Pipeline/InkRasterizer.swift`: `.drawSegments` reports the box of the new points, `.clearAll` (Clear and new page) reports a clear; erase, undo and redo redraws are not writing and report nothing.
- `Pipeline/FramePipeline.swift`: `renderFrame` passes the laid-out frame through `follow.frame(...)`; the perf log prints `follow: zoom <z> centre (<x>, <y>) <full page|following>` once a second while the switch is on.
- Zero copy holds: only the canvas quad's `dest` and `uv` change; the same two IOSurface-backed textures are sampled in the same single pass.
- Settings > Advanced (first row): "Follow the pen on camera", with the sentence under it: "On camera, the board zooms in on the area you are writing in, up to 2.5 times, and returns to the full page after 30 s without ink, on Clear and on a new page." Off by default. The menu bar has nothing.

Why the switch is not in the Kit's `Settings`: `DaylightKit/Settings/Settings.swift` is not in this charter. `SettingsStore` (mine) keeps it under its own key, as `ShareSettingsStore` does for the share window, and `FollowPenSwitch` carries it to the render queue without new wiring in `App/AppDelegate.swift`.

Tests: `FollowFrameTests` (kit-linux and mac: rest zones, full page equals today's frames at progress 0.1 to 1 in both layouts, zoomed quad and borders, Overlay and passthrough untouched, the scripted sequence on the frame), `FollowPenTests` (mac: the rasterizer reports boxes and clears, undo is not ink; the scripted ink sequence through the driver: no jump on the first stroke, nothing before FP6, zoom to the FP1 cap after it, full page after FP7, Clear snaps in the same frame; layout change refits in the same frame; off, mirror, Overlay and passthrough keep today's frame; the switch defaults off and persists; a compositor probe of the magnified ink and the GPU cost), the UI suite (`checkFollowPen`: exists, inside the window, off with fresh defaults, on with a click, off again, screenshots `NN-settings-advanced-followpen` and `-on` in light and dark), docs-to-UI (`Follow the pen on camera` quoted in OWNER-NEXT-STEPS and TESTING-CHECKLIST 7.11).

Measured cost (run 37232483589, GPU mean of 60 frames): Whiteboard Only full page 1.350 ms, followed 1.143 ms; Studio Split full page 1.402 ms, followed 1.014 ms on macos-15 (mac-26: 0.833, 0.610, 0.946, 0.630). Following costs nothing measurable; `docs/PERFORMANCE.md` section 6.

## T3. Laser pointer (LOOSE_ENDS F3)

State: built on all three sides; the Mac draws it once the router calls it (request R1 below). CI: run https://github.com/12twelve12hi/daylight-control-your-mac/actions/runs/37232483589 (10a7c89): golden, web, android, kit-linux, mac (mac-test, mac-smoke PASS, UI suite) and mac-26 green. Two of my own test slips cost cycles: run 37232225890 failed kit-linux (a LaserTrail "outside" probe sat exactly on the visible edge) and android-emulator in both runs failed `WhiteboardTest.toolbarLeavesTheCanvasMostOfTheScreen`, which counts the toolbar pills (9, now 10 with Laser); 82caef5 sets 10 and asserts the Laser pill, proved by run 37233524706 or the run of the docs commit after it (same code).

- Mac: `DaylightKit/Layout/LaserTrail.swift` (up to 48 samples; each fades linearly from its intensity over its decay, 0.5 s when the message carries 0, capped at 3 s; radius 9 canvas px shrinking to half; off-canvas, non-finite and zero-intensity samples dropped; `place` maps a dot through the canvas quad, so it follows the pen camera). `InkRasterizer.laser(x:y:intensity:decay:)` adds a sample to `CanvasSurfaces.laser` and touches neither the canvas surfaces nor the store: never saved, undone or erased. `FramePipeline.laserDots` places the dots; the compositor draws them inside the panel scissor with the new `daylight_dot` fragment (a soft-edged disc, colour `0xE5372A`). Mirror pictures and passthrough get none. Tests: `LaserTrailTests` (kit), `LaserTests` (no stroke, no pixel on either layer, no surface lock, the saved PNG is byte-identical to the blank page, the laser is not ink for follow; placement and fade; a compositor probe of the dot and of the faded frame).
- Web: a "Laser" toolbar button (`web/src/laser.ts`: contact intensity 1.0, hovering pen 0.5, decay 0.5 s, one LASER_POINT per animation frame with the newest point; sent on the now-or-never control path, dropped while not live). Tests: `tests/unit/laser.test.ts` (the golden `laser_point` vector byte for byte, the intensity rule, the throttle), `tests/laser.spec.ts` (Playwright: the fake Mac receives 0x0030 and no STROKE, ERASE or UNDO frame; back to Pen draws again). Verified locally too: 42 unit tests and 62 Playwright tests pass, `make golden-check` unchanged.
- Daylight Ink (Android): a Laser pill after Erase (`Texts.TOOL_LASER`), `ink/LaserPointer.kt` (contact 1.0, stylus hover 0.5 via `onHoverEvent` on both ink views, decay 0.5 s, coalesced to one message per Choreographer frame, only while the Mac accepts ink; picking Laser cancels an open stroke). Tests: `LaserPointerTest` (golden vector, intensity, mapping like strokes, coalescing, nothing sent when not accepted or after a tool switch, the session untouched). `SourceRulesTest`: the old rule "PenInput never mentions ACTION_HOVER" became "the one ACTION_HOVER branch is `onHover`, it checks the stylus tool type and feeds only the laser; nothing before or after it mentions hover", plus `theLaserToolNeverReachesTheStrokeSession`. That is the same guarantee (hover never reaches the session), stated for the new code; no rule was dropped.
- UNVERIFIED (Android): `View.onHoverEvent` delivery of stylus hover on the DC-1 (the source comment said `onGenericMotion`; Android delivers hover to a view through `dispatchHoverEvent`/`onHoverEvent`). Fallback: contact still drives the laser.
- UNVERIFIED (web): pointer hover events from the DC-1's pen in its browser. Fallback: contact still drives the laser.
- `make golden-check` unchanged: the existing opcode, no protocol change.

## Requests for other domains

- R1 (owner of `Sources/Ink/InkRouter.swift`), blocks the laser on the Mac: replace `case .laserPoint:` with
  `case let .laserPoint(x, y, intensity, decayS):` and add `rasterizer?.laser(x: Double(x), y: Double(y), intensity: Double(intensity), decay: Double(decayS))` before `pipeline.post(.activity)`. One line; every other piece is in and tested. A router test can then assert that a LASER_POINT leaves `store.committedCount` at 0.
- R2 (Kit settings owner): add `followPen: Bool = false` to `Settings` (CodingKeys, lenient decode) and migrate `com.twelve.daylight.followPen.v1` into it; then `SettingsStore.followPen` becomes `settings.followPen` and `FramePipeline.followEnabled` reads the pipeline's settings.
- R3 (Ink, `PNGExporter.swift`): the same camera line weight for the saved PNG is one call to `CameraLineWeight.cameraWidth(_:tool:)` per segment and dot. Not applied: the page stays true to the tablet. Decide after the legibility test.
- R4 (SPEC owner): numbers for D14 (2.5 and 6.0 output px at 1080p, live outputs only), follow the pen (FP1 to FP9 as SPEC rows, off by default, Advanced) and the laser (default decay 0.5 s, cap 3 s, 48 samples, radius 9 canvas px, colour 0xE5372A, contact 1.0 and hover 0.5 on both clients).
- R5 (App, `SelfTest.swift`): a self-test probe that renders one followed frame and one laser dot, so `mac-smoke` covers them on every push (today the hosted tests do).
- R6 (owner, after R1): the TESTING-CHECKLIST row for the laser, added once the Mac draws it.
