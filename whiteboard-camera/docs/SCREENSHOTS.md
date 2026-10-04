# Emulator screenshots: where every CI run puts them

The `android-emulator` CI job runs the Daylight Ink instrumented tests on an emulated Android 13 tablet shaped like the Daylight DC-1 and keeps what the screen showed. It is in both workflows (`/.github/workflows/whiteboard-camera.yml` in the monorepo, `.github/workflows/ci.yml` standalone), runs beside the other Linux jobs and is blocking: a red run fails the workflow. It ran with `continue-on-error: true` until it had been green three runs in a row (37183448543, 37183673841, 37184526410). Locally: boot any API 33 emulator, then `make android-emulator-build android-emulator`.

## Where to find them

GitHub > Actions > pick the run > scroll to **Artifacts** at the bottom of the run page > **android-screenshots** (a zip). It is uploaded on every run, green or red, so a failing run still has its pictures and logs. The run page's summary also carries the job's result block (tests started, passed, failed, the failed test names, screenshot and ANR counts, the failure reasons).

## What is in the zip

| File | What it is |
|---|---|
| `screenshots/NN-name.png` | One PNG per test checkpoint, written by the tests themselves (see the contract below). The two-digit prefix orders them in the sequence the tests took them; each name says the screen, for example a first launch, a permission prompt, the onboarding, the canvas. The test sources under `android/app/src/androidTest/` are the list of names and what each one asserts before it shoots. |
| `screenshots/90-after-process-death.png` | Taken by the script, not a test: the app was opened, sent Home, its process killed (`am kill`, then `run-as ... kill -9` if a foreground service kept it alive), then reopened. It shows the screen the app restores after the system dropped its process. The onboarding on it is fine: the emulator has no Mac saved. A crash on restore fails the job instead. |
| `instrument.txt` | The raw `am instrument -w -r` output: every test start and result with its status code, stack traces of failures, and the final `OK (N tests)` or `FAILURES!!!` block. |
| `summary.txt` | The same result block as the run page summary. |
| `device.txt` | Android release and SDK level, model, ABI, and the `wm size` and `wm density` in force, so a picture can be checked against the screen it came from. |
| `logcat-full.txt` | `adb logcat -d -v threadtime` for the whole run after the install (buffer raised to 16 MB). |
| `logcat-app.txt` | The app's share of it: every line of a process the log shows starting for `com.twelve.daylight.ink` (main and `:sub` processes), the app's tags `DaylightInk.ui`, `.net`, `.ink`, `.overlay`, `.mirror`, `.facts`, any line naming the package (ActivityManager, PackageManager), `AndroidRuntime` (crash stacks) and `TestRunner`. |
| `anr/` | `ls.txt` (the listing of `/data/anr` on the device) and the ANR trace files pulled from it. The script runs `adb root` first, which the google_apis image allows; on an image that refuses, `ls.txt` holds the permission error and the folder stays otherwise empty. |

The job fails (and with it the workflow run) when the instrumentation output lacks `OK (`, reports `OK (0 tests)`, contains `FAILURES!!!`, `INSTRUMENTATION_FAILED` or `Process crashed`, when logcat shows a `FATAL EXCEPTION` in `com.twelve.daylight.ink` or `ANR in com.twelve.daylight.ink`, or when the process-death check fails. Each reason is printed as a `::error::` annotation and listed in `summary.txt`. `make scripts-check` proves these rules on Linux against sample outputs.

## The emulated device and why

| Setting | Value | Why |
|---|---|---|
| System image | API 33, `google_apis`, `x86_64` | Android 13 is what the DC-1 runs. x86_64 runs under KVM on the GitHub ubuntu runner. `google_apis` rather than `default` because it allows `adb root`, which reading `/data/anr` needs, and `google_apis_playstore` does not. |
| AVD hardware profile | `Nexus 10` (avdmanager device id) | There is no DC-1 profile. The emulator runner takes an avdmanager device id; `Nexus 10` is a long-standing stock 10 inch tablet definition with a 2560x1600 panel and no hardware keyboard, so the DC-1's 1200x1600 portrait screen fits inside its panel without upscaling. |
| Screen | `adb shell wm size 1200x1600` and `adb shell wm density 200` before the tests, reset after | The DC-1 is 1200x1600 portrait at about 200 dpi (10.5 inch). Overriding the window manager works the same on any profile and needs no custom skin or edited panel values that the runner's AVD creation could overwrite; apps see 1200x1600 and density 200 (DisplayMetrics, resource qualifiers, layout). The physical panel behind it stays the profile's; nothing in the app reads that. |
| Hardware keyboard | `hw.keyboard=no` in the AVD's `config.ini` | Set by the runner's `pre-emulator-launch-script` (`scripts/android-emulator.sh avd-config`), so the soft keyboard behaves as on the DC-1. The runner's `enable-hw-keyboard` input is left at its default `false` (it only ever adds `hw.keyboard=yes`). |
| RAM, disk | 4096 MB, 6000 MB | Headroom for the app plus the test APK on a swiftshader-rendered emulator. |
| Animations | off | The runner's `disable-animations: true`, repeated by the script so a local run matches. |
| Emulator options | `-no-snapshot-save -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim -camera-back none` | The runner README's caching recipe: the first run on a cache miss boots once and saves a snapshot, later runs load it and never save over it. |

What the emulator does not reproduce: the LivePaper panel (a transflective LCD, so the screenshots show colour and contrast as an ordinary LCD would, not as the DC-1 does in sunlight), the DC-dimmed backlight, the 45 to 90 Hz variable refresh rate, and the pen digitizer (tests inject stylus `MotionEvent`s). Those stay on `docs/TESTING-CHECKLIST.md`.

## How a run goes

1. Checkout, Temurin 17, setup-gradle, `scripts/ci-env.sh`.
2. KVM group permissions (the udev rule from the runner README).
3. `make android-emulator-build`: `./gradlew --no-daemon :app:assembleDebug :app:assembleDebugAndroidTest`, before the emulator starts.
4. AVD cache restore (`~/.android/avd/*`, `~/.android/adb*`, key `avd-33-google_apis-x86_64-nexus10-r1`); on a miss, one boot that creates the AVD and its snapshot.
5. The runner boots the emulator and runs `make android-emulator`, which: waits for `sys.boot_completed` and the package manager, applies the DC-1 screen, uninstalls any earlier copy, installs the app APK and the test APK with `adb install -r` (no `-g`: the tests walk the permission prompts themselves), clears logcat, runs `am instrument -w -r com.twelve.daylight.ink.test/androidx.test.runner.AndroidJUnitRunner`, runs the process-death check, then pulls screenshots, logcat and ANR traces into `build/android-emulator/` (also from an exit trap, so an early failure still collects).
6. `android-screenshots` is uploaded with `if: always()`.

The tests run through `am instrument` and not through Gradle's `connectedDebugAndroidTest` because Gradle uninstalls the app at the end, and the screenshots live in the app's own storage.

## Contract for the tests

- Application id `com.twelve.daylight.ink`; test package `com.twelve.daylight.ink.test`; `testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"`.
- Screenshots are PNGs written to `targetContext.getExternalFilesDir("screenshots")`, which is `/sdcard/Android/data/com.twelve.daylight.ink/files/screenshots/` on the emulator. Names `NN-name.png`, two-digit prefix in shooting order; 90 and above are reserved for the script.
- No `clearPackageData` and no test orchestrator: clearing the package data would delete the screenshots before they are pulled.
- The launcher activity is `com.twelve.daylight.ink/.ui.MainActivity` (the process-death check starts it).

## Process death: what the check really does

Killing the app process from inside a test would also kill the instrumentation, which runs in the same process, so the check is in the script after the tests. It sends the same intent a launcher tap sends (`am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n com.twelve.daylight.ink/.ui.MainActivity`), waits 3 s, presses Home, kills the process, confirms `pidof` no longer reports the old pid, sends the launcher intent again, waits 3 s and takes `90-after-process-death.png`. Because the task still exists, the second launch brings it to the front and Android recreates the activity from its saved state, as when the system reclaims a backgrounded app and the owner returns to it. It is not literally a tap in Recents; if the system had dropped the task the launch would start fresh, which the picture would show.

# Mac screenshots: the app's real windows on the CI runner

The `mac` job (macos-15) runs `make mac-ui-test` after `make mac-smoke`: the XCUITest suite `mac/DaylightUITests` launches the unsigned Release `Daylight.app` that the same job built, once in light and once in dark appearance, drives every window and the menu bar item, takes a screenshot at every step and checks what it sees. Owner: `docs/handoff/vp-mac-ui.md` (design, rounds, runs). Locally on a Mac with Xcode: `make mac-generate mac-debug mac-ui-test`.

## Where to find them

GitHub > Actions > pick the run > **Artifacts** > **mac-screenshots** (a zip, uploaded green or red). The suite's log is `ui-test.log` in the **xcodebuild-logs** artifact. For a session that cannot download artifacts, the mac job's log also carries every image as a small JPEG (one base64 line between `UI-THUMB-BEGIN <path>` and `UI-THUMB-END`) and one accessibility line per element per surface (`DaylightUITests [<appearance>] ax <surface>:`).

## What is in the zip

`light/` and `dark/`, each with the same numbered steps; `-window` images show the window alone, the others the whole 1024 by 768 runner screen.

| Step | What it shows |
|---|---|
| `01-welcome` | The Welcome window on a first launch: rows 0 to 5, the unsigned-build sentence, "Allow camera access", the Ink source picker, "Launch Daylight at login", "Done" |
| `02-menu`, `03-menu-ink-source`, `04-menu-hold`, `05-menu-share-the-whiteboard` | The menu bar item opened by a real click, then each submenu |
| `06` to `18` `settings-<tab>-top`, `-bottom`, `-wifi` | Every Settings tab (General, Hotkeys, Network, Mirror, Overlay, Share, Saving, Advanced, Diagnostics) at the top, at the bottom where it scrolls, and Mirror with the Wi-Fi transport chosen |
| `19-preview` | The preview window (cream and empty: the runner has no camera) |
| `20-diagnostics` | The Diagnostics window |
| `21-allow` | The Allow panel for a fixture tablet ("UI test tablet", 192.168.1.40) |

## What the suite checks

- Every window lies on the screen; every Settings tab is reachable by a click; every element lies horizontally inside its window; no two visible elements overlap; every tab's content starts under the tab bar; every popup is visible and hittable; the last element of each tab is inside the window after scrolling.
- The texts: the Welcome rows, the menu items in order with their submenus, every popup's options, the Allow prompt, and the Diagnostics report (read from the pasteboard after "Copy diagnostics").
- Docs to UI: `scripts/ui-expectations.sh` collects every Mac menu item, tab, setting label, option and Welcome phrase that `docs/OWNER-NEXT-STEPS.md`, `docs/SETUP.md` and `docs/TESTING-CHECKLIST.md` quote (55 on 2026-10-04) and the suite fails, naming the doc line, when one is not in the UI as written.

The app runs with `--ui-test`: a throwaway settings suite (so every launch is a first launch), no camera, no camera extension, no mirror, no global hotkeys and no network listener, so the runner never shows a permission prompt. What the screenshots cannot show: the real camera picture, the virtual camera in Zoom, a connected tablet. Those stay on `docs/TESTING-CHECKLIST.md`.
