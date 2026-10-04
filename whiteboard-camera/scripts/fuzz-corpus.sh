#!/usr/bin/env bash
# make fuzz-corpus: regenerate protocol/fuzz/corpus.json and copy it into the three test trees (protocol/fuzz/README.md).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 protocol/fuzz/gen_fuzz.py protocol/fuzz/corpus.json
for dst in mac/DaylightKit/Tests/DaylightKitTests/Resources/fuzz-corpus.json web/tests/fuzz/corpus.json android/app/src/test/resources/fuzz-corpus.json; do
  mkdir -p "$(dirname "$dst")"
  cp protocol/fuzz/corpus.json "$dst"
  echo "copied -> $dst"
done
