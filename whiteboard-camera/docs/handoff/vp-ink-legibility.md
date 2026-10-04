# VP Ink Legibility (phase 5A)

Charter: T1 camera line weight (D14), T2 follow the pen wired, T3 laser pointer (LOOSE_ENDS F3). Branch
`claude/daylight-whiteboard-camera-tzxfjb`. This file is kept current after every push.

## T1. Camera line weight (D14)

State: code and tests pushed; CI result recorded below.

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
