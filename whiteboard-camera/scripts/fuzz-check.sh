#!/usr/bin/env bash
# make fuzz-check: regenerate the fuzz corpus to a temp file and fail when any committed copy drifts from it.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
python3 protocol/fuzz/gen_fuzz.py "$tmp" >/dev/null
rc=0
for f in protocol/fuzz/corpus.json mac/DaylightKit/Tests/DaylightKitTests/Resources/fuzz-corpus.json web/tests/fuzz/corpus.json android/app/src/test/resources/fuzz-corpus.json; do
  if [[ -f "$f" ]] && diff -q "$tmp" "$f" >/dev/null; then
    echo "ok    $f"
  else
    echo "DRIFT $f (run make fuzz-corpus)"
    if [[ -f "$f" ]]; then diff "$tmp" "$f" | head -c 2000 || true; echo; fi
    rc=1
  fi
done
exit $rc
