#!/usr/bin/env bash
# make mac-debug: compile app + camera extension + DaylightKit without signing and zip the .app.
# Primary path: CODE_SIGNING_ALLOWED=NO. Fallback (LOOSE_ENDS B1): ad-hoc identity for the whole scheme.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == "true" ]] && set -x
command -v xcodebuild >/dev/null 2>&1 || { echo "mac-debug: xcodebuild not found" >&2; exit 2; }
[[ -d mac/Daylight.xcodeproj ]] || scripts/mac-generate.sh
if [[ -d web/dist && -f web/dist/index.html ]]; then
  rm -rf mac/Daylight/Resources/web; mkdir -p mac/Daylight/Resources/web; cp -R web/dist/. mac/Daylight/Resources/web/
fi
mkdir -p build/xcodebuild-logs
xcodebuild -version | tee build/xcodebuild-logs/xcodebuild-version.txt
swift --version 2>&1 | tee build/xcodebuild-logs/swift-version.txt
xcodebuild -help > build/xcodebuild-logs/xcodebuild-help.txt 2>&1 || true
common=(-project mac/Daylight.xcodeproj -scheme Daylight -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData ONLY_ACTIVE_ARCH=NO)
path="unsigned"
if ! xcodebuild "${common[@]}" CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build/xcodebuild-logs/build-unsigned.log | grep -E '^(error|warning: .*(error|fail)|\*\* BUILD)' ; then
  :
fi
if ! grep -q 'BUILD SUCCEEDED' build/xcodebuild-logs/build-unsigned.log; then
  echo "mac-debug: CODE_SIGNING_ALLOWED=NO build failed; retrying with the ad-hoc identity (LOOSE_ENDS B1)"
  path="adhoc"
  xcodebuild "${common[@]}" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= build 2>&1 | tee build/xcodebuild-logs/build-adhoc.log | grep -E '^(error|\*\* BUILD)' || true
  if ! grep -q 'BUILD SUCCEEDED' build/xcodebuild-logs/build-adhoc.log; then
    # The compiler's own lines (file:line: error:) reach the job log; the artifact host is not reachable from every
    # session that reads these logs.
    echo "mac-debug: compiler errors (first 40):" >&2
    grep -hE ': (fatal )?error: ' build/xcodebuild-logs/build-unsigned.log build/xcodebuild-logs/build-adhoc.log | sort -u | head -40 >&2 || true
    echo "mac-debug: both build paths failed; see build/xcodebuild-logs" >&2
    exit 1
  fi
fi
echo "mac-debug: build path that succeeded: $path" | tee build/xcodebuild-logs/build-path.txt
app="build/DerivedData/Build/Products/Release/Daylight.app"
[[ -d "$app" ]] || { echo "mac-debug: $app not found" >&2; find build/DerivedData/Build/Products -maxdepth 2 -name '*.app' >&2 || true; exit 1; }
ls -R "$app" > build/xcodebuild-logs/app-contents.txt
codesign -dvv "$app" > build/xcodebuild-logs/codesign-app.txt 2>&1 || true
plutil -p "$app/Contents/Info.plist" > build/xcodebuild-logs/app-info-plist.txt || true
ext="$(find "$app/Contents/Library/SystemExtensions" -maxdepth 1 -name '*.systemextension' 2>/dev/null | head -1 || true)"
if [[ -n "$ext" ]]; then plutil -p "$ext/Contents/Info.plist" > build/xcodebuild-logs/extension-info-plist.txt || true; echo "mac-debug: embedded extension $ext"; else echo "mac-debug: WARNING no .systemextension embedded"; fi
rm -f build/Daylight-unsigned.zip
ditto -c -k --keepParent "$app" build/Daylight-unsigned.zip
ls -la build/Daylight-unsigned.zip
