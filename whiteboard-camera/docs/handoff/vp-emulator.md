# VP Emulator: Daylight Ink on an emulated DC-1 in CI (phase 4, 2026-10-04)

Ticket: prove the APK runs on an Android 13 tablet before the owner sideloads it. Where the pictures are: `docs/SCREENSHOTS.md`.

## 1. What was built

| Part | Files | Commits |
|---|---|---|
| CI job `android-emulator` in both workflows (API 33 `google_apis` x86_64, `Nexus 10` profile forced to 1200x1600 at 200 dpi, KVM, AVD snapshot cache, artifact `android-screenshots`) | `.github/workflows/whiteboard-camera.yml`, `whiteboard-camera/.github/workflows/ci.yml` | 294e4bd, 3822e57 |
| Script and make targets (`make android-emulator-build`, `make android-emulator`): install without `-g`, `am instrument`, process-death check, logcat, ANR traces, crash stacks printed into the job log | `scripts/android-emulator.sh`, `Makefile`, 11 new checks in `scripts/scripts-check.sh` | 294e4bd, b3ad1fa |
| Instrumented tests, 25 in 6 classes, plus a fake Mac (RFC 6455 server inside the test APK, golden vectors from `src/test/resources` packaged as test assets, no fifth copy) | `android/app/src/androidTest/**`, `android/app/build.gradle.kts` | ea26915, 238ac9c |
| Fixes of what the emulator revealed | `android/app/src/main/**` (section 3) | 951bab1, e652d9f, 8974893 |

The tests: `OnboardingTest` (cold launch with the exact Texts strings, the four onboarding buttons found as accessible Buttons, manual address persisted and handed to the connection, overlay permission screen in `com.android.settings` and Back, "Allowed" once granted), `WhiteboardTest` (stylus draws and finger does not, toolbar tools toggle, accessibility click selects a tool, eraser removes a stroke, rotation keeps the instance and the ink, `recreate()` keeps strokes and tool, no second onboarding after a recreate, the front-buffer toggle rebuilds the canvas, the toolbar leaves the canvas most of the screen), `SettingsTest` ("This tablet" facts and the "Send facts to Mac" button, settings survive a recreate), `MirrorConsentTest` (the system capture dialog: Cancel leaves the app healthy and denied; "Start now" runs `ScreenStreamService` until "Stop sharing"), `ServicesTest` (pills service without permission stops itself; with the app-op it shows Pin and Clear in the top 96 px and stops on ACTION_STOP; a stray `ScreenStreamService` start stops without a crash), `FakeMacTest` (accept key matches the golden vector, onboarding reaches "Connected to ws://127.0.0.1:<port>/ink", the whiteboard goes LIVE, shows "KEEP WHITEBOARD" from golden `state_live_pinned` and sends START, CHUNKs, COMMIT whose START bytes match golden `stroke_start`, Send facts reaches the fake and shows "Sent to your Mac.").

Process death: killing the app process also kills the in-process instrumentation, so the script does it: launch, Home, `am kill`, check the pid is gone, relaunch from the launcher intent, check a new pid and no `FATAL EXCEPTION`, screenshot `90-after-process-death.png`. The tests cover the save and restore path with `ActivityScenario.recreate()`.

## 2. CI facts

- `reactivecircus/android-emulator-runner@v2` (v2.38.0 the latest tag), inputs as in its README and `action.yml` (fetched). `actions/cache@v6`. Device after the overrides (run 37181876257): `release=13 sdk=33`, `model=sdk_gphone64_x86_64`, physical 2560x1600 at 320, override 1200x1600 at 200.
- First green run: 37181876257 on 238ac9c, job 111375916311: `OK (25 tests)` in 142.9 s, 12 screenshots (01 to 11 and 90), 0 ANR traces, process-death check passed, artifact 11295159019.
- The green streak toward blocking is in section 5.
- Concurrency: `cancel-in-progress: false` (3822e57). With three teams pushing, cancel-in-progress killed the job before the emulator booted (runs 37179633847, 37179738620).
- This container cannot download artifacts (the proxy blocks the blob host), so the script prints the summary, the instrumentation output and the crash stacks into the job log. Whoever reads a run without the artifact still sees why it failed.

## 3. Defects the emulator found, all fixed with a test

| # | Defect | Effect on the owner | Fix | Test |
|---|---|---|---|---|
| EM-1 | `EdgeToEdge.apply` read `window.insetsController` before `setContentView`; on API 33 `PhoneWindow` dereferences the not yet installed decor (run 37180339019, NullPointerException in OnboardingActivity and MainActivity) | **Daylight Ink crashed on every launch on Android 13**, the DC-1's version | e652d9f: read `window.decorView` first | `SourceRulesTest.edgeToEdgeInstallsTheDecorBeforeAskingForTheInsetsController`; every activity test |
| EM-2 | `Toolbar`: the density was declared after the pill initializers that read it (0 px pills), and gaps and spacers went through `add()` with WRAP_CONTENT height, so the toolbar row took the whole height and the canvas got 0 px (run 37180986677) | **A toolbar and no place to write** | 8974893 | `ToolbarSourceTest` (2, both fail on the old source), `WhiteboardTest.toolbarLeavesTheCanvasMostOfTheScreen` |
| EM-3 | `PillView` drew its text but exposed none to accessibility | TalkBack mute; no UI test could find a button | 951bab1: content description follows the text, Button class, selected state, `performClick` runs `onTap` | `OnboardingTest.onboardingButtonsAreAccessibleButtons`, `WhiteboardTest.accessibilityClickSelectsATool` |
| EM-4 | `DryInkView`: the size-change replay list never held pen strokes | Ink vanished on rotation or any resize | 951bab1 | `WhiteboardTest.rotationKeepsTheInstanceAndTheInk` |
| EM-5 | `MainActivity.recreate()` (front-buffer toggle, unlisted config changes) dropped strokes and tool; a recreate stacked a second onboarding; `onStop` released a hold `onStart` never took | Lost page on a settings change | 951bab1: `StrokeSession.snapshot()`/`restore()` while `isChangingConfigurations`, `onboardingShown` saved, `holding` flag | `StrokeSessionRestoreTest` (5 JVM), `recreateKeepsStrokesAndTool`, `recreateDoesNotOpenOnboardingTwice`, `frontBufferToggleRebuildsTheCanvasAndKeepsTheStroke` |
| EM-6 | `ScreenStreamService` started without a consent result stopped before `startForeground` | A crash after `startForegroundService` | 951bab1: foreground (guarded), then stop | `ServicesTest.screenStreamServiceWithoutConsentStopsWithoutCrash` |

EM-1 and EM-2 were invisible to the JVM tests and the android job, which build the APK but never run it. Both would have been the owner's first impression.

Noted, not fixed (no defect seen on the emulator):
- OnboardingActivity reconnects on every keystroke in the host field. That is wasteful but harmless.
- `OverlayService.onCreate` calls `startForeground` unguarded. Only a background plain `startService` would throw, and only Settings sends one, from the foreground.

## 4. Only a real DC-1 can answer

The emulator injects `MotionEvent`s with `TOOL_TYPE_STYLUS` and pressure 0.2 to 0.8 (`UiAutomation.injectInputEvent`); it has no digitizer. These questions stay on the device checklist:
- Whether the Wacom driver reports `TOOL_TYPE_STYLUS` and `TOOL_TYPE_ERASER`, and normalised or raw pressure (D3).
- Side-button events (D4).
- Hover.
- Whether `CanvasFrontBufferedRenderer` is valid on SolOS (D14).
- SolOS's screen-capture dialog: its package, wording and buttons (D19).
- SolOS's overlay-permission screen.
- Whether the pills sit under the SolOS status bar (D5).
- Whether rotation recreates the activity on the device.
- The toolbar at the real density.
- The LivePaper transflective LCD, the DC-dimmed backlight and the 45 to 90 Hz refresh.

TESTING-CHECKLIST rows that the emulator already proves are marked "proved in CI, confirm on device".

## 5. Green streak and promotion to blocking

The record is the table in `docs/STATUS.md`, section "Emulator: Daylight Ink on an emulated DC-1". The job stays `continue-on-error: true` until three consecutive non-cancelled runs are green; the commit that removes it names the three runs.

## 6. UNVERIFIED, each with its guard

- **The `Nexus 10` avdmanager id:** it worked in every run. If an image update drops it, switch to `pixel_tablet` and bump the cache key.
- **androidx.test library versions:** runner 1.7.0, ext junit 1.3.0, espresso 3.7.0 and uiautomator 2.3.0 are from the release-notes pages. The AAR metadata was not readable here, but the build passes in CI.
- **API 33 system dialogs:** the systemui buttons "Cancel" and "Start now" are matched case-insensitively, and the Start-now test skips if that button is missing. This holds on the API 33 image; SolOS is D19.

## 7. Process notes

- **Commit trailers:** every commit carries this session's own attribution trailers, not the charter's pair, which names another session.
- **Delegation:** an Opus manager built the CI job and another the tests and fixes. Sonnet workers only extracted CI log excerpts. The VP read every diff before committing and checked every claim against the CI logs.
- **Review 4 request 3:** the Kotlin codec divergences FZ-1, FZ-3, FZ-4 and FZ-5 (LOOSE_ENDS R4-3) are taken up in this domain; see LOOSE_ENDS EM.
