#!/usr/bin/env bash
# make kit-test: DaylightKit XCTest on Linux or macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == "true" ]] && set -x
if ! command -v swift >/dev/null 2>&1; then
  echo "kit-test: swift not found. On GitHub use the swift:6.4-noble container or swift-actions/setup-swift." >&2
  exit 2
fi
swift --version
swift test --package-path mac/DaylightKit --parallel
