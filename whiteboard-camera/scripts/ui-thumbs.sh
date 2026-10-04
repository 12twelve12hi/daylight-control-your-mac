#!/usr/bin/env bash
# make mac-ui-test (last step, pass or fail): print the UI test screenshots into the job log as small JPEGs so they can
# be seen without artifact access. For every NN-<step>.png under DIR (default build/ui-screenshots) it prints
#   UI-THUMB-BEGIN <path relative to the repo root>
#   <base64 of `sips -Z 560 -s format jpeg -s formatOptions 45`, 76 columns>
#   UI-THUMB-END
# using NN-<step>-window.png when the suite saved the window alone, else the full screenshot. The total base64 is
# capped at DAYLIGHT_UI_THUMBS_MAX_BYTES (default 2500000); the rest is skipped with a line naming how many.
# Decode a block with: sed -n '/UI-THUMB-BEGIN <path>/,/UI-THUMB-END/p' log | sed '1d;$d' | cut -c30- | base64 -d
# (cut removes the GitHub timestamp prefix). Never fails the build: no sips, no folder or a bad image only prints a line.
# Usage: scripts/ui-thumbs.sh [DIR]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 0
dir="${1:-build/ui-screenshots}"
cap="${DAYLIGHT_UI_THUMBS_MAX_BYTES:-2500000}"
if ! command -v sips >/dev/null 2>&1; then
  echo "ui-thumbs: sips not found (macOS only); no thumbnails"
  exit 0
fi
if [[ ! -d "$dir" ]]; then
  echo "ui-thumbs: $dir does not exist; no thumbnails"
  exit 0
fi
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ui-thumbs.XXXXXX")" || exit 0
trap 'rm -rf "$tmp"' EXIT
# The screenshots of each step: the window image when there is one, else the screen.
picks=()
while IFS= read -r shot; do
  window="${shot%.png}-window.png"
  if [[ -f "$window" ]]; then picks+=("$window"); else picks+=("$shot"); fi
done < <(find "$dir" -name '*.png' ! -name '*-window.png' | LC_ALL=C sort)
total=0; printed=0; skipped=0
for pick in "${picks[@]+"${picks[@]}"}"; do
  out="$tmp/thumb.jpg"
  rm -f "$out"
  if ! sips -Z 560 -s format jpeg -s formatOptions 45 "$pick" --out "$out" >/dev/null 2>&1 || [[ ! -s "$out" ]]; then
    echo "ui-thumbs: sips could not convert $pick"
    continue
  fi
  encoded="$(base64 < "$out" | tr -d '\n\r' | fold -w 76)"
  size=${#encoded}
  if (( total + size > cap )); then
    skipped=$((skipped + 1))
    continue
  fi
  total=$((total + size))
  printed=$((printed + 1))
  echo "UI-THUMB-BEGIN $pick"
  printf '%s\n' "$encoded"
  echo "UI-THUMB-END"
done
if (( skipped > 0 )); then
  echo "ui-thumbs: skipped $skipped more screenshot(s) over the ${cap}-byte cap"
fi
echo "ui-thumbs: printed $printed of ${#picks[@]} screenshot(s), $total bytes of base64"
exit 0
