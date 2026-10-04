#!/usr/bin/env bash
# make mac-ui-test: the DaylightUITests XCUITest suite against the unsigned Release app that make mac-debug built
# (docs/handoff/vp-mac-ui.md "Design contract"). The UI test target has no dependency on Daylight, builds into its
# own derived data (build/DerivedData-ui) with the ad-hoc identity (an XCUITest runner needs a signature to load) and
# launches build/DerivedData/Build/Products/Release/Daylight.app by URL. Same tee + grep gate as mac-test.sh; the log
# is build/xcodebuild-logs/ui-test.log, the screenshots land in build/ui-screenshots/<appearance>/NN-<step>.png
# (uploaded as the artifact mac-screenshots) and printed as JPEG thumbnails into the log by scripts/ui-thumbs.sh.
# Wall-clock limit DAYLIGHT_UI_TEST_TIMEOUT (default 480 s) via perl alarm like mac-smoke.sh, since timeout(1) is not
# on macOS by default.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == "true" ]] && set -x
command -v xcodebuild >/dev/null 2>&1 || { echo "mac-ui-test: xcodebuild not found" >&2; exit 2; }
app="build/DerivedData/Build/Products/Release/Daylight.app"
[[ -x "$app/Contents/MacOS/Daylight" ]] || { echo "mac-ui-test: $app not found; run make mac-debug first" >&2; exit 2; }
[[ -d mac/Daylight.xcodeproj ]] || scripts/mac-generate.sh
mkdir -p build/xcodebuild-logs
scripts/ui-expectations.sh
rm -rf build/ui-screenshots build/ui-test.xcresult
mkdir -p build/ui-screenshots
# A leftover copy (mac-smoke, an earlier run) would own the status item; --ui-test never quits another copy itself.
pkill -x Daylight || true
# xcodebuild passes TEST_RUNNER_<NAME> to the test runner as <NAME> (UNVERIFIED for this Xcode); the suite falls back
# to the same paths derived from its own source location.
export TEST_RUNNER_DAYLIGHT_APP="$PWD/$app"
export TEST_RUNNER_DAYLIGHT_SCREENSHOTS="$PWD/build/ui-screenshots"
export TEST_RUNNER_DAYLIGHT_UI_EXPECTATIONS="$PWD/build/ui-expectations.json"
limit="${DAYLIGHT_UI_TEST_TIMEOUT:-480}"
start=$(date +%s)
set +e
perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!"' "$limit" \
  xcodebuild test -project mac/Daylight.xcodeproj -scheme DaylightUITests -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-ui CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= OTHER_CODE_SIGN_FLAGS= -resultBundlePath build/ui-test.xcresult 2>&1 \
  | tee build/xcodebuild-logs/ui-test.log \
  | grep -E '^(error|Test Case|Test Suite|Executed|\*\* TEST)|: error: -\[|DaylightUITests \[' || true
rc=${PIPESTATUS[0]}
set -e
elapsed=$(( $(date +%s) - start ))
echo "mac-ui-test: xcodebuild exited with $rc after ${elapsed} s (limit ${limit} s)"
pkill -x Daylight || true
shots=$(find build/ui-screenshots -name '*.png' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$shots" == "0" && -d build/ui-test.xcresult ]]; then
  # The runner could not write the PNGs (sandbox); export the attachments from the result bundle instead.
  # `xcresulttool export attachments` is UNVERIFIED on Xcode 16.4, hence the guard.
  mkdir -p build/ui-screenshots/xcresult
  xcrun xcresulttool export attachments --path build/ui-test.xcresult --output-path build/ui-screenshots/xcresult \
    > build/xcodebuild-logs/ui-test-attachments.log 2>&1 || echo "mac-ui-test: exporting the xcresult attachments failed; see build/xcodebuild-logs/ui-test-attachments.log" >&2
  shots=$(find build/ui-screenshots -name '*.png' 2>/dev/null | wc -l | tr -d ' ')
fi
echo "mac-ui-test: $shots screenshots in build/ui-screenshots"
# Thumbnails in the job log, pass or fail (UI-THUMB-BEGIN/END blocks); without the trace, so each line is printed once.
{ set +x; } 2>/dev/null
scripts/ui-thumbs.sh build/ui-screenshots || echo "mac-ui-test: ui-thumbs.sh failed (ignored)"
[[ "${CI:-}" == "true" ]] && set -x
if (( rc == 142 )); then
  echo "mac-ui-test: the suite did not finish within ${limit} s (SIGALRM); see build/xcodebuild-logs/ui-test.log" >&2
fi
if (( rc != 142 )) && grep -q 'TEST SUCCEEDED' build/xcodebuild-logs/ui-test.log; then
  echo "mac-ui-test: TEST SUCCEEDED in ${elapsed} s"
else
  echo "mac-ui-test: UI tests failed or did not run; see build/xcodebuild-logs/ui-test.log" >&2
  echo "mac-ui-test: failing assertions:" >&2
  grep -E ': error: -\[' build/xcodebuild-logs/ui-test.log | head -80 >&2 || true
  echo "mac-ui-test: failed test cases and the xcodebuild summary:" >&2
  grep -E "' failed \(|Failing tests|^[[:space:]]+DaylightUITests\.|^error:|: (fatal )?error: |\*\* (TEST|BUILD)" build/xcodebuild-logs/ui-test.log \
    | grep -v ': error: -\[' | sort -u | head -60 >&2 || true
  exit 1
fi
