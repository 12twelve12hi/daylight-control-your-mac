# VP Mac UI handoff (phase 4)

Owner of the `DaylightUITests` XCUITest target (`mac/project.yml`), `mac/DaylightUITests/**`, `scripts/mac-ui-test.sh`, `scripts/ui-expectations.sh` and their make targets, the "mac-ui-test" step of the mac job in both workflows, `docs/SCREENSHOTS.md` (Mac section), and UI fixes in `mac/Daylight/Sources/{App,Onboarding,Settings}` that the screenshots reveal.

## Status

| Item | State | Proof |
|---|---|---|
| Design contract (below) | written | this file |
| App side: `--ui-test` mode and identifiers (e2f00dd) | built; UITestModeTests green | run 37180339019, mac and mac-26 jobs |
| Suite, scripts, CI step (a3fba2a) | first run: compiled, ran in 195 s, 76 screenshots, status item menu reached directly (no fallback needed); 4 failures per appearance (round 2 below) | run 37180339019, mac job 111371850861 |

### Round 1 findings (run 37180339019)

- Defect: Settings > Advanced "Perf log (one line per second, kept for Diagnostics and the export)" runs past the right edge of the window (label frame x 771 to 1191, window 511 to 1103).
- Settings > Diagnostics tab not clickable by the suite (suspected: the eight tabs do not fit the 560 pt window).
- Overlay popups matched only by label; SwiftUI popups expose an empty label.
- Diagnostics window: the suite did not find the "log (last N lines):" line.
- Artifacts and raw logs are on productionresultssa17.blob.core.windows.net, which this cloud environment's network policy blocks; the suite therefore also prints accessibility dumps and JPEG thumbnails into the job log.

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
2. Every Settings tab (General, Hotkeys, Network, Mirror, Overlay, Saving, Advanced, Diagnostics): selected, scrolled to the bottom where it scrolls, the `.last` element exists and its frame lies inside the window frame; Mirror also shows "Transport" and "adb source" with their options.
3. Preview, Diagnostics and the Allow panel each appear with their texts and buttons.
4. The menu lists every item in order, read from the status item or from `--ui-test-open menu`.
5. Docs to UI: `scripts/ui-expectations.sh` extracts every Mac UI string the owner docs quote in a `menu bar > ...` or `Settings > <Tab> > ...` chain (and the Welcome window phrases) from `docs/OWNER-NEXT-STEPS.md`, `docs/SETUP.md` and `docs/TESTING-CHECKLIST.md` into `build/ui-expectations.json` (text, kind, file:line). The suite asserts each string appears in the UI as written; drift in the docs or the UI fails the test with the doc line.
6. Each surface in light and in dark appearance; a screenshot (XCUIScreen.main.screenshot) at every step, attached to the result and saved as PNG under `build/ui-screenshots/<appearance>/NN-<step>.png`, uploaded as the artifact `mac-screenshots`.

### CI

`make mac-ui-test` runs after `make mac-smoke` in the mac job of both workflows (`continue-on-error: true` until green three times in a row, then blocking), with its own time limit; the suite budget is 6 minutes.
