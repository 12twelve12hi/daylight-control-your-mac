#!/usr/bin/env bash
# Builds TwelveGate in release mode and wraps the binary into build/TwelveGate.app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/build/TwelveGate.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/TwelveGate" "$APP/Contents/MacOS/TwelveGate"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature so macOS is happy to launch it from /Applications.
codesign --force --deep --sign - "$APP"

echo "$APP"
