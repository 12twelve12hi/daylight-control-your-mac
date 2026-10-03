#!/usr/bin/env bash
# make embed-apk: copy the Daylight Ink debug APK into the app's resources (SPEC D43, IMPLEMENTATION-PLAN P0.5).
# Usage: scripts/embed-apk.sh <dir with *.apk> <destination file>. Warns and exits 0 when no APK is present, so a
# local build without the android job still works; the app then answers 404 for /daylight-ink.apk.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == "true" ]] && set -x
src="${1:-android/app/build/outputs/apk/debug}"
dst="${2:-mac/Daylight/Resources/Apk/DaylightInk.apk}"
apk="$(find "$src" -maxdepth 2 -name '*.apk' 2>/dev/null | sort | head -1 || true)"
if [[ -z "$apk" ]]; then
  echo "embed-apk: WARNING no *.apk under $src; the app will serve 404 for /daylight-ink.apk"
  exit 0
fi
mkdir -p "$(dirname "$dst")"
cp "$apk" "$dst"
ls -l "$dst"
if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$dst"; else sha256sum "$dst"; fi
echo "embed-apk: embedded $apk -> $dst"
