#!/usr/bin/env bash
# Prints the toolchain facts every CI job logs first, and which make targets can run on this machine.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== Daylight Whiteboard Camera: environment"
uname -a
have() { command -v "$1" >/dev/null 2>&1; }
show() { if have "$1"; then printf '  %-10s %s\n' "$1" "$("$@" 2>&1 | head -1)"; else printf '  %-10s missing\n' "$1"; fi; }
show node --version
show npm --version
show python3 --version
show java -version
show swift --version
show xcodegen --version
show xcodebuild -version
show adb --version
if have xcode-select; then echo "  xcode-select -p: $(xcode-select -p 2>/dev/null || true)"; fi
if [[ -n "${DAYLIGHT_XCODE_PATH:-}" ]]; then
  if [[ -d "$DAYLIGHT_XCODE_PATH" ]]; then
    export DEVELOPER_DIR="$DAYLIGHT_XCODE_PATH/Contents/Developer"
    echo "  DEVELOPER_DIR set from DAYLIGHT_XCODE_PATH: $DEVELOPER_DIR"
  else
    echo "  DAYLIGHT_XCODE_PATH is set but does not exist, keeping the default Xcode"
  fi
fi
echo "== Targets that can run here"
have node && echo "  make web, make web-test" || echo "  (no node: web targets skipped)"
have swift && echo "  make kit-test" || echo "  (no swift: kit-test needs a Swift toolchain)"
have java && echo "  make android (also needs an Android SDK at ANDROID_HOME)" || echo "  (no java: android skipped)"
have xcodebuild && echo "  make mac-generate, make mac-debug, make mac-release" || echo "  (no Xcode: mac targets skipped)"
echo "  HAS_SIGNING=${HAS_SIGNING:-unset} DO_NOTARIZE=${DO_NOTARIZE:-unset}"
