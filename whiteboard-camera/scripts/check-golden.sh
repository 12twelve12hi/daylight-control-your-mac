#!/usr/bin/env bash
# make golden-check: regenerate to a temp file and fail when any committed copy drifts from the oracle.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
python3 protocol/gen_golden.py "$tmp" >/dev/null
rc=0
for f in protocol/golden/solstream-v1.json mac/DaylightKit/Tests/DaylightKitTests/Resources/solstream-v1.json web/tests/golden/solstream-v1.json android/app/src/test/resources/solstream-v1.json; do
  if diff -q "$tmp" "$f" >/dev/null; then echo "ok    $f"; else echo "DRIFT $f (run make golden)"; diff "$tmp" "$f" | head -20 || true; rc=1; fi
done
exit $rc
