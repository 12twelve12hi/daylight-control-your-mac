#!/usr/bin/env bash
# make mac-test: the macOS-only DaylightTests XCTest bundle (hosted by Daylight.app, IMPLEMENTATION-PLAN P0.2).
# Same tee + grep gate shape as mac-debug.sh: the log is kept under build/xcodebuild-logs for the artifact.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == "true" ]] && set -x
command -v xcodebuild >/dev/null 2>&1 || { echo "mac-test: xcodebuild not found" >&2; exit 2; }
[[ -d mac/Daylight.xcodeproj ]] || scripts/mac-generate.sh
mkdir -p build/xcodebuild-logs
touch build/xcodebuild-logs/test-start.stamp   # crash-summary.sh reads only crash reports newer than this
xcodebuild test -project mac/Daylight.xcodeproj -scheme DaylightTests -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO 2>&1 \
  | tee build/xcodebuild-logs/test.log \
  | grep -E '^(error|Test Case|Test Suite|Executed|hosted-test|\*\* TEST)|: error: -\[|Restarting after unexpected exit' || true
if grep -q 'TEST SUCCEEDED' build/xcodebuild-logs/test.log; then
  echo "mac-test: TEST SUCCEEDED"
else
  echo "mac-test: tests failed or did not run; see build/xcodebuild-logs/test.log" >&2
  # XCTest assertion lines start with the source path ("<file>:<line>: error: -[Suite test] : XCTAssert... failed"),
  # so they lead the summary; the host app's network log lines that also say "failed" would otherwise crowd them out.
  echo "mac-test: failing assertions:" >&2
  grep -E ': error: -\[' build/xcodebuild-logs/test.log | head -60 >&2 || true
  echo "mac-test: failed test cases, relaunches and the xcodebuild summary:" >&2
  grep -E "' failed \(|Restarting after unexpected exit|Failing tests|^[[:space:]]+[A-Za-z]+Tests\.|^error:|\*\* TEST" build/xcodebuild-logs/test.log \
    | grep -v 'nw_' | head -60 >&2 || true
  # A crash ("Restarting after unexpected exit") names its frame here, not only in the artifact (Review 4 CI-1).
  scripts/crash-summary.sh build/xcodebuild-logs/test.log build/xcodebuild-logs/test-start.stamp >&2 || true
  exit 1
fi
