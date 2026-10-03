#!/usr/bin/env bash
# make golden: regenerate the canonical golden file and copy it into the three test trees.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 protocol/gen_golden.py protocol/golden/solstream-v1.json
for dst in mac/DaylightKit/Tests/DaylightKitTests/Resources/solstream-v1.json web/tests/golden/solstream-v1.json android/app/src/test/resources/solstream-v1.json; do
  cp protocol/golden/solstream-v1.json "$dst"
  echo "copied -> $dst"
done
