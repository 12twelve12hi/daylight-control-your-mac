# VP Platform handoff (phase 2)

Owner of `scripts/`, `Makefile`, both workflows, `mac/project.yml`, `mac/Daylight/Sources/Mirror/AdbClient*.swift` and `AdbServerPolicy*.swift`, the adb-source Settings key and rows, the adb Diagnostics lines, FailureText rows 39 to 43 and their tests.

## Status

| Ticket | State | Proof |
|---|---|---|
| H1 adb sources | done in code, see the acceptance table below | run RUN_H1 |
| H2 macos-26 leg | done | run RUN_H2 |
| Keep the branch green | no red run caused by shared files during this phase | runs listed below |

## H1: what was built

- Kit: `AdbSource` (`bundled`, `download`, `installed`, labels "Bundled (default)", "Download on first use", "Use installed adb"), `Settings.adbSource` (default `bundled`) and `Settings.adbTermsAcceptedVersion` (nil until Accept). The decoder reads `adbSource` as a raw string, so an unknown value (or a number) loads as `bundled` without discarding the rest of the blob; that is where "validated() maps an unknown value to bundled" lives, because an enum value can never be unknown after decoding. `AdbSource.effective(bundledAvailable:)` turns Bundled into Download on a build without the bundled adb. Tests: `AdbSourceSettingsTests` (kit-linux and the mac job's kit-test).
- FailureText rows 39 to 43 (`adbTermsDeclined`, `adbDownloadFailed`, `adbChecksumMismatch`, `adbInstalledMissing`, `adbInstalledTooOld`), SPEC 13.3 rows added in the same commit, `FailureTextTests` (45 cases, exact sentences) and `FailureCoverageTests` (45) updated. Rows 34 to 38 were already taken by the Wi-Fi stream, so the LOOSE_ENDS proposal "rows 34 to 37" became 39 to 43; the charter's five failures got one row each (download failure and checksum mismatch are separate rows).
- `mac/Daylight/Sources/Mirror/AdbClientSources.swift`: `AdbPins` (37.0.0 and the fetch-tools sha256; `make scripts-check` compares them with `scripts/fetch-tools.sh`), `AdbVersionInfo` (parses `adb version`), `AdbInstalledProbe`, `AdbDownloader`, `AdbSourceRequest`, `AdbSourceError` (maps to the rows and to the existing `AdbError`), `AdbSourceStatus` (Diagnostics).
- The seam: `AdbClient.locateExecutable(vendorDirectory:fileManager:)` keeps its signature (so `MirrorController.ensureAdb` is unchanged) and now resolves the source chosen in the persisted settings through `AdbClient.locateExecutable(_ request:)`. Bundled is the old function, renamed `locateBundled`, bit for bit. A missing bundled adb is still `AdbError.executableMissing(path)`, so row 25's wording is unchanged. The other sources fail with `AdbError.launchFailed(<row sentence>)`, which the mirror shows through row 25 as "The screen mirror could not start: <row sentence>" until the request below lands.
- Download on first use: never runs before the pinned version's terms are accepted (`adbTermsAcceptedVersion == 37.0.0`); `AdbDownloader.ensure` fetches the pinned URL, checks the zip's sha256 before unzipping with `/usr/bin/ditto`, installs `adb` (0755) and `NOTICE.txt` under `~/Library/Application Support/Daylight/platform-tools/`, writes `daylight-platform-tools.json` (version, zip sha256, adb sha256), removes `adb.partial` and the temp folder on every path. `locateInstalled` re-hashes the adb against that manifest before every use; a mismatch deletes the manifest (row 41), so the next download replaces the copy. A new pin re-downloads. `locateExecutable` itself never touches the network.
- Use installed adb: PATH entries, `/opt/homebrew/bin/adb`, `/usr/local/bin/adb`, `$ANDROID_HOME/platform-tools/adb`, `$ANDROID_SDK_ROOT/platform-tools/adb`, `~/Library/Android/sdk/platform-tools/adb`, duplicates dropped; the first executable wins; `adb version` must show bridge 1.0.41 or newer and a "Version" line of platform-tools 35 or newer (the charter's "at least 35" and LOOSE_ENDS' "1.0.41" are both enforced; a missing Version line counts as too old). An older first match is refused (row 43) rather than skipped, so the owner sees which copy is in the way.
- Settings > Mirror > "adb source" (`mac/Daylight/Sources/Settings/AdbSourceSettingsView.swift`, inserted under "Transport"): the picker (Bundled hidden on a build without it), the terms alert ("Download adb from Google?", Accept or Cancel, the license URL in the text and a "Android SDK License" link), "Downloading adb...", the path and version found, the row text on failure with "Try again" and "Use bundled", and "A new adb source applies the next time Daylight starts."
- Diagnostics: `DiagnosticsReport.Facts.adbSource` (default: the last resolution) prints `mirror.adb.source`, `mirror.adb.path`, `mirror.adb.version` (and `mirror.adb.error` after a failure) beside `mirror.adb.mode`; a key the mirror controller reports itself wins. It is part of "Copy diagnostics" because that copies the same text.
- Build switch: `make fetch-tools mac-generate mac-debug DAYLIGHT_BUNDLE_ADB=0` leaves `Vendor/adb` and its NOTICE out and writes `DaylightBundlesAdb = "0"` into the app's Info.plist (`project.yml`, exported by `mac-generate.sh`, which refuses anything but 0 or 1). Default 1 everywhere, so CI and releases still bundle adb. `make scripts-check` asserts the pins and the wiring.

### Acceptance (LOOSE_ENDS H1)

| # | Criterion | State |
|---|---|---|
| 1 | Settings key and picker, default bundled, unknown maps to bundled, SPEC 11 and SETUP rows | met (AdbSourceSettingsTests; SPEC 11, SETUP 2.3 and 4) |
| 2 | every path through `locateExecutable`, returns URL, source, version; AdbServerPolicy unchanged | met for the seam; `MirrorController` still receives only the URL (request 1) |
| 3 | Bundled bit for bit | met (`locateBundled` is the old body; `testBundledIsTheVendorCopy`, `testBundledMissingKeepsTheExistingError`) |
| 4 | Download: pins, scripts-check, terms once, HTTPS, sha before unzip, Application Support, re-download on a new pin, partial removal | met (AdbClientSourcesTests download cases against a local file URL; scripts-check) |
| 5 | Installed: probing order, first executable, version minimum, Settings shows path and version | met (probe cases with fake adb scripts) |
| 6 | Diagnostics source, path, version | met (`testDiagnosticsShowSourcePathAndVersion`) |
| 7 | rows with exact sentences, FailureCoverageTests and the Kit count | met (rows 39 to 43); the dedicated rows reach the menu only through row 25 until request 1 |
| 8 | build switch | met (scripts-check; the 0 build itself is not run in CI, see UNVERIFIED) |
| 9 | tests without a device | met; the owner rows are TESTING-CHECKLIST 4.19 to 4.21 |

## H2: the macos-26 leg

`mac-26` job in `/.github/workflows/whiteboard-camera.yml` and `whiteboard-camera/.github/workflows/ci.yml`, identical apart from the monorepo path prefix: `runs-on: macos-26` (the actions/runner-images README lists `macos-26` as the GA Arm64 image, fetched 2026-10-03), `continue-on-error: true`, its own concurrency group `wbc-mac26-<ref>`, the same steps as the mac job up to `make mac-smoke`, artifacts `Daylight-unsigned-macos-26` and `xcodebuild-logs-macos-26`, no signing step. It uses the image's default Xcode (no `DAYLIGHT_XCODE_PATH`). macos-15 stays the required leg; make macos-26 required after a week of green legs (LOOSE_ENDS H2). A separate job instead of a matrix keeps the required check named `mac`.

## UNVERIFIED, with the fallback in place

- URLSession `dataTask` with a `file://` URL in the hosted tests: the download tests depend on it. Fallback if the runner refuses: a `URLProtocol` stub (LOOSE_ENDS H1 (9) names it); not needed if `AdbClientSourcesTests` are green.
- A downloaded adb launched from Application Support by a hardened, notarized app: files written by the app carry no quarantine attribute (the app sets no `LSFileQuarantineEnabled`), so Gatekeeper should not prompt. Fallback: the owner picks Bundled or Installed; checklist row 4.20 checks it on the Mac.
- The Mirror tab is taller with the new section; the Settings window is a fixed 560 by 520 (B's file). If the tab clips, it needs a ScrollView (request 3).
- `DAYLIGHT_BUNDLE_ADB=0` builds: the script, plist and picker logic are covered by scripts-check and unit tests, but no CI job builds that variant.

## Requests to other domains

1. Mirror v2 (`MirrorController.swift`): (a) call `AdbClient.locateExecutable(AdbSourceRequest(settings: settings, vendorDirectory: vendorDirectory))` in `ensureAdb` and, on failure, raise `onFailure?(error.failure)` with the dedicated row 39 to 43 instead of wrapping the sentence in row 25; (b) when `updateSettings` sees `adbSource` or `adbTermsAcceptedVersion` change, drop the cached `adb` and clear `adbUnavailable`, so a new source applies without a relaunch (then remove "applies the next time Daylight starts" from the Settings row and SETUP).
2. App (`AppDelegate.usbSetupErrorText`): for `AdbError.launchFailed` the detail is already the row sentence for the new sources; nothing breaks, but the text reads "adb could not be launched (<sentence>)".
3. Mirror v2 (`mac/DaylightTests/Mirror/StylusWatcherTests.swift`): `testProbeFindsThePenNodeAndStreamsIt` raced in run 37149301627 (commit c119b82, a workflow-only change; the same code was green in run 37149014837): `gotDouble` is fulfilled by the gesture before the sixth transition (`side1Up` at 11.4 s) is appended, so `seen.count` read 5. Wait for six transitions (an expectation with `expectedFulfillmentCount = 6`, or poll `transitions` until the count reaches 6) before asserting.
4. App/Settings owner: wrap the Mirror tab's `Form` in a `ScrollView` if 4.19 shows it clipped.

## Decisions recorded

- Commit trailers: the charter and a later message from the CEO session asked for "Claude Fable 5.1" and the CEO's session URL. The harness of this session sets this session's own model and session URL for attribution, and a co-author line naming a model and session that did not write the commit would be inaccurate, so the commits carry this session's own trailers.
- No managers or workers were spawned: the scope fitted one context, and every claim here is checked against the code and the CI run named.

## Owner-facing text

SETUP.md 2.3 gains "adb source" (the three choices, the five messages, the restart note) and the section 4 Mirror table gains `adbSource` and `adbTermsAcceptedVersion`. TESTING-CHECKLIST.md Session 4 gains 4.19 (Bundled), 4.20 (Download, Cancel then Accept, offline) and 4.21 (Installed).

## Runs

- RUN_H2: H2 commit c119b82.
- RUN_H1: H1 commit 82a6641.
