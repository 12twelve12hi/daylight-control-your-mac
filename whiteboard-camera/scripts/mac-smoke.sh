#!/usr/bin/env bash
# make mac-smoke: run the unsigned Release build with --self-test --perf-log (SPEC 16 B1) under a 120 s timeout.
# timeout(1) is not on macOS by default, so perl's alarm wraps the process (IMPLEMENTATION-PLAN P0.3).
# A CI step of the mac job since Integrator-sync-4 (IMPLEMENTATION-PLAN section 12 rule 2: added once --self-test existed).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == "true" ]] && set -x
bin="build/DerivedData/Build/Products/Release/Daylight.app/Contents/MacOS/Daylight"
[[ -x "$bin" ]] || { echo "mac-smoke: $bin not found; run make mac-debug first" >&2; exit 2; }
mkdir -p build/xcodebuild-logs
limit="${DAYLIGHT_SMOKE_TIMEOUT:-120}"
set +e
perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!"' "$limit" "$bin" --self-test --perf-log 2>&1 | tee build/xcodebuild-logs/self-test.log
rc=${PIPESTATUS[0]}
set -e
if (( rc == 142 )); then echo "mac-smoke: --self-test did not finish within ${limit} s (SIGALRM)" >&2; exit 1; fi
(( rc == 0 )) || { echo "mac-smoke: --self-test exited with $rc" >&2; exit "$rc"; }
echo "mac-smoke: ok"
