#!/usr/bin/env bash
# make kit-test: DaylightKit XCTest on Linux or macOS.
#
# A crash of the swift-package process itself is retried with the whole suite, up to KIT_TEST_ATTEMPTS runs in all
# (default 3). On the swift:6.4-noble container it has segfaulted in libdispatch's event loop while planning the build,
# before any test ran (run 37135358460, exit 139 at "[Pre-planning 1 / 154]"). Only an exit by a crash signal is
# retried (132 SIGILL, 133 SIGTRAP, 134 SIGABRT, 135 SIGBUS, 139 SIGSEGV), never a test failure: with --parallel every
# test runs in its own process and a test that crashes is reported by swift-package as a failure (exit 1). The retry
# starts from an empty .build so it does not inherit the state the crashed planner left behind.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == "true" ]] && set -x
if ! command -v swift >/dev/null 2>&1; then
  echo "kit-test: swift not found. On GitHub use the swift:6.4-noble container or swift-actions/setup-swift." >&2
  exit 2
fi
swift --version
attempts="${KIT_TEST_ATTEMPTS:-3}"
attempt=1
while :; do
  rc=0
  swift test --package-path mac/DaylightKit --parallel || rc=$?
  [[ "$rc" == 0 ]] && exit 0
  case "$rc" in
    132|133|134|135|139) ;;
    *) exit "$rc" ;;
  esac
  if (( attempt >= attempts )); then
    echo "kit-test: swift test crashed with exit $rc on attempt $attempt of $attempts; giving up" >&2
    exit "$rc"
  fi
  attempt=$((attempt + 1))
  echo "kit-test: swift test crashed with exit $rc (signal $((rc - 128))): the SwiftPM process itself crashed, not a test; cleaning mac/DaylightKit/.build and running the whole suite again (attempt $attempt of $attempts)" >&2
  rm -rf mac/DaylightKit/.build
done
