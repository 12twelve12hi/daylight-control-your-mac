#!/usr/bin/env bash
# make mac-release: manual Developer ID signing (archive + export), optional notarization + DMG.
# Self-skips (exit 0) when the signing secrets are absent, printing exactly what is missing.
# Facts and command shapes: docs/ARCHITECTURE.md section 9.2, research note research-cmio-signing sections 3.3 to 3.5
# (OBS setup-macos-codesigning action, Apple TN3125 and TN3147).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == "true" ]] && set -x
required=(DAYLIGHT_TEAM_ID DAYLIGHT_DEVELOPER_ID_P12_BASE64 DAYLIGHT_DEVELOPER_ID_P12_PASSWORD DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64)
missing=()
for v in "${required[@]}"; do [[ -n "${!v:-}" ]] || missing+=("$v"); done
if (( ${#missing[@]} )); then
  echo "mac-release: skipping the signed build. Missing: ${missing[*]}"
  echo "mac-release: optional: DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64; notarization needs DO_NOTARIZE=true plus ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_PRIVATE_KEY_BASE64."
  echo "mac-release: see docs/SIGNING.md (owner checklist) for how to create each one."
  exit 0
fi
command -v xcodebuild >/dev/null 2>&1 || { echo "mac-release: xcodebuild not found" >&2; exit 2; }
mkdir -p build/release-logs
tmp="${RUNNER_TEMP:-$(mktemp -d)}"
# 1. Temporary keychain with the Developer ID Application certificate.
kc="$tmp/daylight-signing.keychain-db"
kcpw="${DAYLIGHT_KEYCHAIN_PASSWORD:-$(uuidgen)}"
echo -n "$DAYLIGHT_DEVELOPER_ID_P12_BASE64" | base64 --decode > "$tmp/developer-id.p12"
security create-keychain -p "$kcpw" "$kc"
security set-keychain-settings -lut 21600 "$kc"
security unlock-keychain -p "$kcpw" "$kc"
security import "$tmp/developer-id.p12" -P "$DAYLIGHT_DEVELOPER_ID_P12_PASSWORD" -A -t cert -f pkcs12 -k "$kc" -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcrun
security set-key-partition-list -S 'apple-tool:,apple:' -k "$kcpw" "$kc" >/dev/null
security list-keychains -d user -s "$kc" "$HOME/Library/Keychains/login.keychain-db"
security find-identity -p codesigning -v "$kc" | tee build/release-logs/identities.txt
identity="$(security find-identity -p codesigning -v "$kc" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
[[ -n "$identity" ]] || { echo "mac-release: no 'Developer ID Application' identity in the imported .p12" >&2; exit 1; }
# 2. Provisioning profiles into both directories Xcode reads (pre and post Xcode 16).
install_profile() { # $1 base64, $2 label -> prints profile Name
  local b64="$1" label="$2" f="$tmp/$2.provisionprofile" plist="$tmp/$2.plist" uuid name
  echo -n "$b64" | base64 --decode > "$f"
  security cms -D -i "$f" -o "$plist"
  uuid="$(plutil -extract UUID raw "$plist")"; name="$(plutil -extract Name raw "$plist")"
  mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  cp "$f" "$HOME/Library/MobileDevice/Provisioning Profiles/$uuid.provisionprofile"
  cp "$f" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$uuid.provisionprofile"
  echo "mac-release: installed $label profile '$name' ($uuid)" >&2
  printf '%s' "$name"
}
export DAYLIGHT_APP_PROFILE; DAYLIGHT_APP_PROFILE="$(install_profile "$DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64" app)"
export DAYLIGHT_EXT_PROFILE=""
if [[ -n "${DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64:-}" ]]; then DAYLIGHT_EXT_PROFILE="$(install_profile "$DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64" ext)"; fi
export DAYLIGHT_CODE_SIGN_IDENTITY="Developer ID Application"
export DAYLIGHT_TEAM_ID
# 3. Regenerate the project with the signing settings, archive, export.
scripts/mac-generate.sh
xcodebuild ONLY_ACTIVE_ARCH=NO -project mac/Daylight.xcodeproj -scheme Daylight -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/Daylight.xcarchive \
  OTHER_CODE_SIGN_FLAGS="--keychain $kc --timestamp" archive 2>&1 | tee build/release-logs/archive.log | grep -E '^(error|\*\* ARCHIVE)' || true
grep -q 'ARCHIVE SUCCEEDED' build/release-logs/archive.log || { echo "mac-release: archive failed, see build/release-logs/archive.log" >&2; exit 1; }
EXT_PROFILE_LINE=""
if [[ -n "$DAYLIGHT_EXT_PROFILE" ]]; then EXT_PROFILE_LINE="    <key>com.twelve.daylight.camera</key><string>${DAYLIGHT_EXT_PROFILE}</string>"; fi
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>${DAYLIGHT_TEAM_ID}</string>
  <key>provisioningProfiles</key><dict>
    <key>com.twelve.daylight</key><string>${DAYLIGHT_APP_PROFILE}</string>
${EXT_PROFILE_LINE}
  </dict>
</dict></plist>
PLIST
rm -rf build/export
xcodebuild -exportArchive -archivePath build/Daylight.xcarchive -exportOptionsPlist build/ExportOptions.plist -exportPath build/export 2>&1 | tee build/release-logs/export.log | grep -E '^(error|\*\* EXPORT)' || true
app="build/export/Daylight.app"
[[ -d "$app" ]] || { echo "mac-release: export produced no Daylight.app, see build/release-logs/export.log" >&2; exit 1; }
# 4. Pre-notarization checks (Apple: resolving common notarization issues).
codesign -vvv --deep --strict "$app" 2>&1 | tee build/release-logs/codesign-verify.txt
codesign -d --entitlements :- "$app" 2>&1 | tee build/release-logs/entitlements.txt
codesign -dvv "$app" 2>&1 | tee build/release-logs/codesign-dvv.txt
spctl -vvv --assess --type exec "$app" 2>&1 | tee build/release-logs/spctl.txt || echo "mac-release: spctl rejects until notarized (expected before notarization)"
rm -f build/Daylight-signed.zip; ditto -c -k --keepParent "$app" build/Daylight-signed.zip
ls -la build/Daylight-signed.zip
# 5. Notarize + staple + DMG, only when asked and the API key is present.
if [[ "${DO_NOTARIZE:-false}" != "true" ]]; then echo "mac-release: DO_NOTARIZE is not true; signed zip only."; exit 0; fi
for v in ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_PRIVATE_KEY_BASE64; do [[ -n "${!v:-}" ]] || { echo "mac-release: DO_NOTARIZE=true but $v is missing; skipping notarization"; exit 0; }; done
echo -n "$ASC_API_PRIVATE_KEY_BASE64" | base64 --decode > "$tmp/AuthKey.p8"
rm -rf build/dmg-root build/Daylight.dmg; mkdir -p build/dmg-root; cp -R "$app" build/dmg-root/
ln -s /Applications build/dmg-root/Applications
hdiutil create -volname "Daylight" -srcfolder build/dmg-root -format UDZO -ov build/Daylight.dmg
codesign --force --timestamp --keychain "$kc" -s "$identity" -i com.twelve.daylight.dmg build/Daylight.dmg
sub="$(xcrun notarytool submit build/Daylight.dmg --key "$tmp/AuthKey.p8" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" --wait --output-format json | tee build/release-logs/notarytool-submit.json)"
id="$(echo "$sub" | plutil -extract id raw -o - - 2>/dev/null || echo "$sub" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' | head -1)"
status="$(echo "$sub" | sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p' | head -1)"
[[ -n "$id" ]] && xcrun notarytool log "$id" --key "$tmp/AuthKey.p8" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" build/notarization-log.json || true
[[ "$status" == "Accepted" ]] || { echo "mac-release: notarization status '$status', see build/notarization-log.json" >&2; exit 1; }
xcrun stapler staple build/Daylight.dmg
xcrun stapler staple "$app" || echo "mac-release: stapling the exported app failed (the DMG is stapled)"
spctl -vvv --assess --type exec "$app" 2>&1 | tee build/release-logs/spctl-after.txt || true
ls -la build/Daylight.dmg
