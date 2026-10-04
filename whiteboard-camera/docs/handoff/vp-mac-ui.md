# VP Mac UI handoff (phase 4)

Owner of the `DaylightUITests` XCUITest target (`mac/project.yml`), `mac/DaylightUITests/**`, `scripts/mac-ui-test.sh`, `scripts/ui-expectations.sh` and their make targets, the "mac-ui-test" step of the mac job in both workflows, `docs/SCREENSHOTS.md` (Mac section), and UI fixes in `mac/Daylight/Sources/{App,Onboarding,Settings}` that the screenshots reveal.

## Status

Acceptance met: the UI suite was green three times in a row and is blocking; `mac-screenshots` holds every window in light and dark; the docs-to-UI check passes (55 of 55); the defects the screenshots showed are fixed, each with an assertion; open items are in LOOSE_ENDS section MU.

| Item | State | Proof |
|---|---|---|
| App side: `--ui-test` mode and identifiers (e2f00dd) | built; UITestModeTests green | run 37180339019, mac and mac-26 jobs |
| Suite, scripts, CI step (a3fba2a) | first run compiled and ran (195 s, 76 screenshots, the status item menu reached by a real click; the `--ui-test-open menu` fallback was never needed); 4 failures per appearance | run 37180339019, mac job 111371850861 |
| Round 2 (77c7ab6, 725eea1, 71531cb, e7b7897) | green, streak 1: `TEST SUCCEEDED in 168 s` | run 37182692894, mac job 111378699546 |
| Round 3 (e70f64b, cf7b3c6) | green, streak 2: `TEST SUCCEEDED in 195 s`; I decoded and looked at all 42 images | run 37183673841, mac job 111381458448 |
| Round 4 (a0d8aa9) | green, streak 3: `TEST SUCCEEDED in 177 s` | run 37184558756, mac job 111384053539 |
| Promoted to blocking (2f7fec1), accessibility fix (757a18d) | green with the step blocking | run 37185248641, mac job 111386117975 (its mac-26 leg crashed in `PipelineSmokeTests.testThreeHundredTicksMeasured`, Pipeline owner's R4-5, not this change) |

Suite time: 168 to 195 s for both appearances (budget 6 minutes, step limit 12).

## Defects found and fixed (each guarded by an assertion)

| Defect | Fix | Guard |
|---|---|---|
| Settings and Welcome windows were centred while still zero wide, so on the runner's 1024 by 768 screen the Settings window's right part (the last tabs) was off screen | sized to content before centring, kept on screen | every window inside the screen; a tab not reachable by a click fails |
| Nine tabs (Share arrived this phase) did not fit 560 pt | Settings is 720 by 520 | same |
| Advanced "Perf log" label ran past the right edge; Overlay's Form laid out wider than the window | plain stacks with wrapping labels; no text changed | every element horizontally inside its window, on every surface |
| Mirror: the crop view (400 pt intrinsic in a 260 pt row) drew over "Quality" and the footnote and under the window bottom | the crop view takes the offered size and clips; the tab is a stack | no two visible elements overlap (the crop view carries `daylight.settings.mirror.cropview`); every popup hittable after scrolling to it |
| Saving: two misaligned columns; Saving and Share vertically centred with an empty band | one left-aligned column; every tab top-aligned at the container | the first element of each tab starts within 40 pt of the tab bar |
| Hotkeys: each chord field grew to about 40 pt with the chord at its bottom | fixed 220 by 24 pt, chord centred | each field 20 to 30 pt tall, its label centred on it within 4 pt |
| Hotkeys: the chord fields read as disabled to accessibility (VoiceOver would say dimmed) | `setAccessibilityEnabled(true)` | each field enabled |

Test-side corrections (not UI defects): Form popups carry no label (found by label or value, options compared exactly); the Diagnostics text view exposes only about 512 characters to accessibility, so the report is checked on the pasteboard after "Copy diagnostics".

## Reading the results from a cloud session

Artifacts and raw logs are on productionresultssa17.blob.core.windows.net, which this cloud environment's network policy blocks. `mcp__github__get_job_logs` (return_content, tail_lines 5000) still works: the mac job's log carries every image as one base64 JPEG line between `UI-THUMB-BEGIN <path>` and `UI-THUMB-END` (42 images, about 1.2 MB), then the suite's notes and an accessibility dump per surface (`DaylightUITests [<appearance>] ax <surface>:`), then the verdict.

## Requests for other owners

1. Pipeline owner: `PreviewWindow.makeWindow()` could call `w.setAccessibilityIdentifier("daylight.window.preview")`; today `UITestMode.tagPreviewWindow()` finds the window by its title.
2. Share owner: `ShareSettingsView` is top-aligned from the Settings container; if it gains rows, keep its labels wrapping so the overflow check stays green.

## Design contract

### How the suite reaches the app

- The suite drives the already built unsigned Release app, `build/DerivedData/Build/Products/Release/Daylight.app` (the one `make mac-debug` zips as `Daylight-unsigned`), through `XCUIApplication(url:)`. The UI test target has no target dependency on Daylight, so building it does not rebuild or re-sign the app; it is built with its own derived data path `build/DerivedData-ui` and the ad-hoc identity (`CODE_SIGN_IDENTITY=-`), because an XCUITest runner bundle needs a signature to load.
- The script passes the app path to the runner in the environment (`TEST_RUNNER_DAYLIGHT_APP`, which xcodebuild forwards as `DAYLIGHT_APP` with the `TEST_RUNNER_` prefix removed) and the screenshot directory (`TEST_RUNNER_DAYLIGHT_SCREENSHOTS`).
- Every launch passes `--ui-test` plus options. `--ui-test` makes the app:
  - use a throwaway defaults suite `com.twelve.daylight.uitest` that it clears at launch (first launch every time; the runner's real defaults are never touched);
  - skip camera capture, the extension installer, the mirror, hotkey registration and Bonjour (no TCC or Local Network prompt on the runner), but keep every window and the status item;
  - not defer to or quit another running copy.
- Options, each also valid alone after `--ui-test`:
  - `--ui-test-appearance light|dark` sets `NSApp.appearance` to `.aqua` or `.darkAqua`.
  - `--ui-test-open welcome|settings|preview|diagnostics|allow|menu` opens that surface directly (the fallback when the status item is unreachable on the runner). `allow` shows `AllowClientPanel` for label "UI test tablet", address "192.168.1.40" (no network client involved). `menu` opens the status item's menu by `performClick` on its button.
  - `--ui-test-settings-tab <name>` selects that Settings tab at open.
  - `--ui-test-overlay-enabled` stores `overlayEnabled = true` before the windows open (the Overlay menu item, Layout option and hotkey row appear only then).
- Accessibility identifiers (set in app code, read by the suite): window identifiers `daylight.window.welcome`, `daylight.window.settings`, `daylight.window.preview`, `daylight.window.diagnostics`, `daylight.panel.allow`; the last element of each Settings tab carries `daylight.settings.<tab>.last` so "scrolled to the bottom, nothing cut off" is a frame check.

### What the suite proves

1. Welcome on first launch: title, subtitle, rows 0 to 5 with the unsigned-build sentence exactly as `FailureText` and `docs/OWNER-NEXT-STEPS.md` quote it, the Launch at login toggle and Done.
2. Every Settings tab (General, Hotkeys, Network, Mirror, Overlay, Share, Saving, Advanced, Diagnostics; the window is 720 by 520 since round 2 so all nine tabs show): clicked directly (a tab that is not clickable fails), scrolled to the bottom where it scrolls, the `.last` element exists and its frame lies inside the window frame; every element lies horizontally inside its window, every window inside the screen; Mirror also shows "Transport" and "adb source" with their options.
3. Preview, Diagnostics and the Allow panel each appear with their texts and buttons. The Diagnostics report is checked on the pasteboard after "Copy diagnostics", because the text view's accessibility value stops after about 512 characters.
4. The menu lists every item in order, read from the status item or from `--ui-test-open menu`.
5. Docs to UI: `scripts/ui-expectations.sh` extracts every Mac UI string the owner docs quote in a `menu bar > ...` or `Settings > <Tab> > ...` chain (and the Welcome window phrases) from `docs/OWNER-NEXT-STEPS.md`, `docs/SETUP.md` and `docs/TESTING-CHECKLIST.md` into `build/ui-expectations.json` (text, kind, file:line; 55 strings on 2026-10-04). The suite logs "docs: checked N of M, misses K" and fails unless N equals M and K is 0. The suite asserts each string appears in the UI as written; drift in the docs or the UI fails the test with the doc line.
6. Each surface in light and in dark appearance; a screenshot (XCUIScreen.main.screenshot) at every step, attached to the result and uploaded as the artifact `mac-screenshots` under `<appearance>/NN-<step>[-window].png`. The test runner is sandboxed and cannot write into `build/`, so `scripts/ui-thumbs.sh` exports the attachments from `build/ui-test.xcresult` and names them from its manifest; it also prints each image as a base64 JPEG line between `UI-THUMB-BEGIN` and `UI-THUMB-END` in the job log, with an accessibility dump per surface, for sessions that cannot download artifacts.

### CI

`make mac-ui-test` runs after `make mac-smoke` in the mac job of both workflows blocking since runs 37182692894, 37183673841 and 37184558756 (it was `continue-on-error: true` until then), with a 12 minute step limit and the script's own 480 s limit; the suite budget is 6 minutes. The mac-26 leg does not run it.
