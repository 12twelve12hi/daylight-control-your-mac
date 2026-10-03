#!/usr/bin/env bash
# make mac-test: the macOS-only DaylightTests XCTest bundle (hosted by Daylight.app, IMPLEMENTATION-PLAN P0.2).
# Same tee + grep gate shape as mac-debug.sh: the log is kept under build/xcodebuild-logs for the artifact.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == "true" ]] && set -x
command -v xcodebuild >/dev/null 2>&1 || { echo "mac-test: xcodebuild not found" >&2; exit 2; }
[[ -d mac/Daylight.xcodeproj ]] || scripts/mac-generate.sh
mkdir -p build/xcodebuild-logs
xcodebuild test -project mac/Daylight.xcodeproj -scheme DaylightTests -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO 2>&1 \
  | tee build/xcodebuild-logs/test.log | grep -E '^(error|Test Case|Test Suite|Executed|hosted-test|\*\* TEST)' || true
if grep -q 'TEST SUCCEEDED' build/xcodebuild-logs/test.log; then
  echo "mac-test: TEST SUCCEEDED"
else
  echo "mac-test: tests failed or did not run; see build/xcodebuild-logs/test.log" >&2
  grep -E 'error:|failed|Failing tests' build/xcodebuild-logs/test.log | head -40 >&2 || true
  exit 1
fi
