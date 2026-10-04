#!/usr/bin/env bash
# make mac-ui-test (first step) and scripts-check: extract the Mac UI strings the owner docs quote
# (docs/OWNER-NEXT-STEPS.md, docs/SETUP.md, docs/TESTING-CHECKLIST.md) into build/ui-expectations.json for the
# DaylightUITests Docs to UI check. The rules are in scripts/ui_expectations.py (python3 stdlib only; runs on Linux).
# Usage: scripts/ui-expectations.sh [--out FILE] [DOC ...]
set -euo pipefail
cd "$(dirname "$0")/.."
command -v python3 >/dev/null 2>&1 || { echo "ui-expectations: python3 not found" >&2; exit 2; }
exec python3 scripts/ui_expectations.py --root "$PWD" "$@"
