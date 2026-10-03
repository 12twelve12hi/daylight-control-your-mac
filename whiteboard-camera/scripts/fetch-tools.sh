#!/usr/bin/env bash
# make fetch-tools: pinned scrcpy-server + Google platform-tools adb (macOS zip), sha256 verified, into
# mac/Daylight/Resources/Vendor (a folder reference in project.yml, copied to Contents/Resources/Vendor/).
# Pins come from scrcpy 4.1 (app/deps/adb_macos.sh) and the scrcpy v4.1 release SHA256SUMS.txt; see docs/ARCHITECTURE.md 9.3.
# Only runs in CI or on a Mac: dl.google.com is blocked from the development Linux box.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == "true" ]] && set -x
SCRCPY_VERSION="${SCRCPY_VERSION:-4.1}"
SCRCPY_SERVER_SHA256="deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae"
PT_VERSION="${PT_VERSION:-37.0.0}"
PT_SHA256="094a1395683c509fd4d48667da0d8b5ef4d42b2abfcd29f2e8149e2f989357c7"
out="mac/Daylight/Resources/Vendor"; mkdir -p "$out" build/tools build/xcodebuild-logs
rm -f "$out/README.txt"   # placeholder written by mac-generate.sh when the tools were never fetched
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
check() { local got; got="$(sha256 "$1")"; [[ "$got" == "$2" ]] || { echo "fetch-tools: sha256 mismatch for $1: got $got want $2" >&2; exit 1; }; echo "fetch-tools: sha256 ok $1"; }
if [[ ! -f "$out/scrcpy-server-v${SCRCPY_VERSION}" ]]; then
  curl -fsSL --retry 3 -o "build/tools/scrcpy-server-v${SCRCPY_VERSION}" "https://github.com/Genymobile/scrcpy/releases/download/v${SCRCPY_VERSION}/scrcpy-server-v${SCRCPY_VERSION}"
  check "build/tools/scrcpy-server-v${SCRCPY_VERSION}" "$SCRCPY_SERVER_SHA256"
  cp "build/tools/scrcpy-server-v${SCRCPY_VERSION}" "$out/"
fi
if [[ ! -f "$out/adb" ]]; then
  curl -fsSL --retry 3 -o build/tools/platform-tools.zip "https://dl.google.com/android/repository/platform-tools_r${PT_VERSION}-darwin.zip"
  check build/tools/platform-tools.zip "$PT_SHA256"
  unzip -l build/tools/platform-tools.zip | tee build/tools/platform-tools-listing.txt | grep -E 'platform-tools/(adb|NOTICE.txt)$' || echo "fetch-tools: WARNING adb or NOTICE.txt not at the expected path (LOOSE_ENDS B2)"
  (cd build/tools && unzip -o -q platform-tools.zip platform-tools/adb platform-tools/NOTICE.txt)
  cp build/tools/platform-tools/adb "$out/adb"; chmod +x "$out/adb"
  [[ -f build/tools/platform-tools/NOTICE.txt ]] && cp build/tools/platform-tools/NOTICE.txt "$out/NOTICE-platform-tools.txt"
fi
# Apache-2.0 section 4(a): a copy of the License ships with every redistribution of scrcpy-server and adb, and the
# notices file carries the scrcpy attribution (SPEC 17, THIRD_PARTY_NOTICES.md). Both are committed, so no download.
cp scripts/licenses/Apache-2.0.txt "$out/LICENSE-Apache-2.0.txt"
cp THIRD_PARTY_NOTICES.md "$out/THIRD_PARTY_NOTICES.md"
# Facts for LOOSE_ENDS B2 and THIRD_PARTY_NOTICES.md, kept in the xcodebuild-logs artifact.
{
  echo "== fetch-tools: $(date -u +%Y-%m-%dT%H:%M:%SZ) scrcpy-server v${SCRCPY_VERSION}, platform-tools r${PT_VERSION}"
  ls -l "$out"
  if command -v lipo >/dev/null 2>&1; then echo "lipo -archs adb: $(lipo -archs "$out/adb" 2>&1)"; fi
  if command -v file >/dev/null 2>&1; then file "$out/adb"; fi
  echo "sha256 adb: $(sha256 "$out/adb")"
  echo "sha256 scrcpy-server-v${SCRCPY_VERSION}: $(sha256 "$out/scrcpy-server-v${SCRCPY_VERSION}")"
  echo "license texts: $(ls "$out"/LICENSE-Apache-2.0.txt "$out"/THIRD_PARTY_NOTICES.md "$out"/NOTICE-platform-tools.txt 2>&1 | tr '\n' ' ')"
  [[ -f build/tools/platform-tools-listing.txt ]] && { echo "unzip -l platform-tools.zip (adb, NOTICE):"; grep -E 'platform-tools/(adb|NOTICE.txt)$' build/tools/platform-tools-listing.txt || true; }
  echo "adb --version:"; "$out/adb" --version 2>&1 || echo "(adb --version failed: $?)"
} | tee build/xcodebuild-logs/vendor.txt
