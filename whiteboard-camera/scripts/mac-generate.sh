#!/usr/bin/env bash
# make mac-generate: run XcodeGen for mac/project.yml.
# project.yml reads these environment variables (XcodeGen ${VAR} substitution); defaults make an unsigned build work.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == "true" ]] && set -x
command -v xcodegen >/dev/null 2>&1 || { echo "mac-generate: xcodegen not found (brew install xcodegen)" >&2; exit 2; }
export DAYLIGHT_BUILD_NUMBER="${DAYLIGHT_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
export DAYLIGHT_MARKETING_VERSION="${DAYLIGHT_MARKETING_VERSION:-$(tr -d '[:space:]' < VERSION)}"
export DAYLIGHT_TEAM_ID="${DAYLIGHT_TEAM_ID:-}"
export DAYLIGHT_CODE_SIGN_IDENTITY="${DAYLIGHT_CODE_SIGN_IDENTITY:-Developer ID Application}"
export DAYLIGHT_APP_PROFILE="${DAYLIGHT_APP_PROFILE:-}"
export DAYLIGHT_EXT_PROFILE="${DAYLIGHT_EXT_PROFILE:-}"
# The web whiteboard is a folder reference inside the app bundle. CI runs `make web` first; when the
# build is missing we still generate with a one-line placeholder page so the project opens.
webres="mac/Daylight/Resources/web"
if [[ -d web/dist && -f web/dist/index.html ]]; then
  rm -rf "$webres"; mkdir -p "$webres"; cp -R web/dist/. "$webres/"
elif [[ ! -f "$webres/index.html" ]]; then
  mkdir -p "$webres"
  printf '<!doctype html><meta charset="utf-8"><title>Daylight</title><p>The web whiteboard was not built into this app (run make web before make mac-generate).</p>\n' > "$webres/index.html"
  echo "mac-generate: web/dist missing, wrote a placeholder page into $webres"
fi
# The vendored adb + scrcpy-server folder is a folder reference too (make fetch-tools fills it in CI). When it is
# missing, a one-line README keeps the reference resolvable so a local build without the tools still works.
vendor="mac/Daylight/Resources/Vendor"
if [[ ! -d "$vendor" ]]; then
  mkdir -p "$vendor"
  printf 'Bundled tools are missing from this build. Run make fetch-tools (needs dl.google.com and github.com).\n' > "$vendor/README.txt"
  echo "mac-generate: $vendor missing, wrote a placeholder README.txt (mirror mode needs make fetch-tools)"
fi
echo "mac-generate: build $DAYLIGHT_BUILD_NUMBER, version $DAYLIGHT_MARKETING_VERSION, team '${DAYLIGHT_TEAM_ID}', identity '${DAYLIGHT_CODE_SIGN_IDENTITY}', profiles '${DAYLIGHT_APP_PROFILE}' / '${DAYLIGHT_EXT_PROFILE}'"
xcodegen --version
(cd mac && xcodegen generate --spec project.yml)
ls mac/Daylight.xcodeproj
