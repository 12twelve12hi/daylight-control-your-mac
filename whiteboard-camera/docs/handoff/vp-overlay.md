# VP Overlay handoff (phase 3)

Owner of Presenter Overlay mode (LOOSE_ENDS A11, v2, off by default): `mac/Daylight/Sources/Pipeline/Overlay/`, the overlay hooks in `Compositor.swift` and `FramePipeline.swift`, `Layout/OverlayLayout.swift` in DaylightKit, the eight `overlay*` Settings keys, `LayoutStyle.overlay`, `HotkeyAction.overlay`, FailureText rows 48 and 49, Settings > Overlay, the "Whiteboard now (Overlay)" menu item, `mac/DaylightTests/Overlay/` and the Kit overlay tests.

## Status

| Item | State | Proof |
|---|---|---|
| Overlay mode built, off by default | proven on mac-26 (build, mac-test, mac-smoke); macos-15 mac job blocked by another domain's compile error | https://github.com/12twelve12hi/daylight-control-your-mac/actions/runs/37159468412 |
| Feature invisible unless enabled | met by construction and tests (below) | same run |
| Passthrough unchanged when off | met: no controller, no queue, no extra lock; the existing `perf` line is byte-identical; OverlayPipelineTests asserts it | same run |
| On-device quality and cost | UNVERIFIED until the owner runs TESTING-CHECKLIST session 6 | LOOSE_ENDS E29 to E31 |

## What was built

- **Geometry (SPEC 6.7, `OverlayLayout`)**: the Whiteboard Only panel slides in from the left; there is no full-frame presenter quad; the presenter is drawn only as a cutout. At s = 1 the cutout is a square of side `overlayScale * 1080` (default 0.28, 302.4 px) inset 32 px from the chosen corner (default bottom-right, (1585.6, 745.6)), showing the central 1080x1080 square of the camera frame. During the slide it morphs without distortion from the full camera picture (s = 0, pixel-identical to passthrough) to the corner square; the matte strength and the opacity follow s.
- **Segmentation**: `PersonSegmenter` runs `VNGeneratePersonSegmentationRequest` (quality fast by default, balanced, accurate; output OneComponent8) through a reused `VNSequenceRequestHandler` on its own serial queue `com.twelve.daylight.overlay.segment`. A frame offered while a request is in flight is dropped and counted, never queued. Frames are offered only while a controller exists (overlayEnabled), the governor is not in PASSTHROUGH and the layout is Overlay.
- **Mask processing**: `MaskProcessor` wraps the Vision mask as a Metal texture through `CVMetalTextureCache` (no CPU copy), then `daylight_mask_iir` (out = k * previous + (1 - k) * new, `overlaySmoothing`, default 0.6) and the separable `daylight_mask_blur` (Gaussian weights from `OverlayLayout.featherWeights(radius: overlayFeather)`, default radius 2) into one of three rotating r16Float textures. If the texture cache refuses a Vision buffer, one small copy per frame into an own r8 texture is made and logged once (E29).
- **Composition**: `Compositor` step 4 draws the cutout with the lazily created `daylight_overlay` pipeline: presenter rgb, alpha = mix(1, mask, maskStrength) * opacity, optional amber `#D97706` halo (8-tap ring at 3 mask texels, `overlayHalo`, default off). A nil mask draws the plain camera rectangle through a 1x1 white mask. The frame's alpha stays opaque. If the overlay pipeline cannot be created, the cutout is drawn as a plain rectangle and logged once.
- **Fallbacks (`OverlayHealth`)**: 15 consecutive failed segmentations latch the fallback: the pipeline renders Studio Split geometry, row 48 is posted once and the menu shows its sentence as a disabled line; toggling "Enable overlay mode" (or changing the quality) resets it. A missing mask, a mask older than 0.5 s, or coverage below 0.01 shows the plain camera rectangle; row 49 goes to Diagnostics once per transition.
- **Governor**: unchanged. Overlay is a third `LayoutStyle` (raw 2, not on the wire; the STATE `mode` byte is HoldMode). A stored `preferredLayout == .overlay` with the feature off engages in Studio Split (`GovernorConfig(settings:)`), and the stored value is kept for re-enabling.
- **UI**: Settings > Overlay tab (Enable overlay mode; Segmentation quality; Smoothing; Edge softness; Amber outline; Size; Position; Opacity; rows greyed out while off; scrolls inside the fixed window). "Layout when engaging" offers Overlay only while enabled; the Hotkeys list and the onboarding hotkey list hide the Overlay row while disabled. Menu "Whiteboard now (Overlay)" after the Whiteboard Only item, only while enabled; status line "Overlay". Hotkey Ctrl+Opt+Cmd+O (`HotkeyAction.overlay`, appended last so the Carbon ids 1 to 5 stay) registered only while enabled.
- **Performance**: `perf overlay seg_ms=<x> mask_age_ms=<x> seg_dropped=<n> state=<matte|rectangle|fellBack>` once per second under `--perf-log`, only while a controller exists. The existing `perf` line is unchanged.
- **Self-test**: `OverlaySelfTest` (one call line in `SelfTest.run`): overlay render probes with a synthetic mask (s = 0 equals passthrough, matte half shows the presenter, clear half shows cream, paper at (960, 540)), the mask processor on a synthetic mask, a generous 50 ms budget assertion for mask processing plus the overlay encode on the synthetic frame, and a Vision probe that is skipped with a logged reason when Vision is unavailable on the runner (it never fails the run).

## Tests

- Kit (kit-linux and the mac job's kit-test): `OverlayLayoutTests` (four corner targets, s = 0, 0.5, 1 numbers, no distortion at any s, panel equals Whiteboard Only, feather weights, smoothing formula, halo colour), `OverlayHealthTests` (14 failures stay, the 15th falls back once and latches, success resets the count, stale and low-coverage rectangle, `.lowCoverage` and `.matteRestored` once per transition), `OverlaySettingsTests` (defaults, clamps, NaN, round trip, unknown raw values, missing keys, the GovernorConfig mapping), `SettingsTests` and `FailureTextTests` updated (6 hotkey actions, 51 failure cases, rows 48 and 49 exact).
- Hosted (mac-test): `OverlayCompositorTests` (pixel assertions with synthetic r8 masks: passthrough identity at s = 0, matte and clear halves, rectangle at maskStrength 0 and with a nil mask, halo on and off, opacity 0.5, uniforms layout), `MaskProcessorTests` (IIR and blur against the Kit reference, identity at radius 0 and smoothing 0, settling, texture-cache and copy paths, coverage sampling), `OverlayControllerTests` (15 failures, one row 48, reset on quality change, busy engine drops without queueing, presentation states, perf line format), `OverlayPipelineTests` (no controller by default, lifetime follows the setting, no offers in passthrough or Studio Split, offers and mode "overlay" while LIVE in Overlay, fallback renders "split" and posts row 48 once, the overlay perf line only with a controller), plus AppModel and Hotkeys cases in `AppUnitTests` and `FailureCoverageTests` (51).

## Decisions taken (recorded as SPEC D57)

- No "Hold > Overlay": HoldMode raw values are the STATE `mode` byte (PROTOCOL 6.14); a new hold would be a protocol change in another domain. "Whiteboard now (Overlay)" plus Keep covers the need. The charter's "menu items under Hold and Whiteboard now" is therefore the one Whiteboard now item.
- Rows 48 and 49 (not 44 and 45): the Diagnostics VP took 44 to 47 first.
- Settings changes reach `Hotkeys` through a notification posted by `AppModel` (it observes `settingsStore.$settings`), because the only existing path is `AppDelegate.applySettings`, which another VP edits. Gap: the Settings hotkey conflict text is not refreshed on the toggle until the next rebind (request 1).

## UNVERIFIED (with fallbacks)

| Item | Fallback | Row |
|---|---|---|
| Vision's mask buffers are IOSurface-backed, so the texture cache wraps them without a copy | one small per-frame copy into an own r8 texture, logged once | E29 |
| Segmentation time per quality on the owner's Mac | Fast by default; the `perf overlay` line measures it; frames are dropped, never queued | E30 |
| Matte quality in the owner's room and lighting | camera rectangle on low coverage; Studio Split after 15 failures | E31 |
| Vision on the CI runners | every test uses a fake engine; the self-test Vision probe is skipped with a logged reason | n/a |

## Requests for other domains

1. AppDelegate (Diagnostics VP or integrator): in `applySettings`, refresh `settingsContext.hotkeyConflicts` after the overlay toggle (one line), so a conflict on Ctrl+Opt+Cmd+O shows at once in Settings.
2. Diagnostics VP: the export could include the last `perf overlay` line and `overlayController` state (matte, rectangle, fellBack) when Overlay is on.

## Owner-facing text

- SETUP: nothing (the feature is off by default and needs no setup).
- OWNER-NEXT-STEPS: step 8b "Try overlay mode" (written).
- TESTING-CHECKLIST: session 6, rows 6.1 to 6.13 (written).
- COMPARE: section 3.1, Overlay versus Studio Split and its cost (written).

## Runs

- 37159335185 on 991bf21: kit-linux red on my test `OverlaySettingsTests.testMissingKeysKeepDefaults` (the blob had no `hotkeys` key, so the full default map applied); fixed in 46db978. Mac jobs skipped behind it.
- 37159468412 on 46db978: golden, web, android and kit-linux green. mac-26 green on every step: all overlay suites passed, every overlay self-test probe was ok, the Vision probe returned a real 256x192 mask, the encode took 2.31 ms, and the run ended with `self-test: PASS`. The macos-15 `mac` job was red at `make mac-debug` on `App/Export/ZipArchive.swift:44` (type-check timeout on Xcode 16.4). That is the Diagnostics VP's file, recorded here and not touched.
