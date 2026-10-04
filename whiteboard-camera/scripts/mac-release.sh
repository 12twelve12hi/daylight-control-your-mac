#!/usr/bin/env bash
# make mac-release: manual Developer ID signing (archive + export), optional notarization + DMG.
# Gate (runs on any OS, tested by scripts/scripts-check.sh): with no signing secrets at all it prints what is
# missing and exits 0. With a partial secret set (a missing or misnamed name) it depends on the run: a release run
# (NOTARIZE_REQUESTED=true for a v* tag or a notarize dispatch, DO_NOTARIZE=true, or GITHUB_REF refs/tags/v*) exits 1
# naming the gap, because a green release with the wrong artifact is the worst outcome for the owner; an ordinary push
# prints a ::warning:: annotation naming the gap and exits 0 like the no-secrets case (the unsigned artifact is already
# uploaded), so secrets added over several hours do not block unrelated work. DAYLIGHT_RELEASE_CHECK_ONLY=1 stops after
# the gate. The signed flag: project.yml writes DaylightBuildSigned=false and this script flips the generated
# mac/Daylight/Info.plist to true with plutil before the archive (a ${VAR} substitution would yield a string, which
# the app's `as? Bool` rejects), then asserts the exported app carries true plus embedded.provisionprofile.
# Everything the owner needs to read after a failure is under build/release-logs (uploaded by the release-logs
# artifact even when this step fails). No xtrace by default: the step would print the .p12, its password, the
# profiles and the .p8 as command arguments; RUNNER_DEBUG enables it only for the xcodebuild/codesign/notarytool part.
# Facts and command shapes: docs/ARCHITECTURE.md section 9.2, research note research-cmio-signing sections 3.3 to 3.5
# (OBS setup-macos-codesigning action, Apple TN3125 and TN3147). Written for the runner's /bin/bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/.."
checklist="docs/SIGNING.md (owner checklist and what this script asserts)"

# ---- 0. Gate: which secrets exist, and is the set complete? -------------------------------------------------
required="DAYLIGHT_TEAM_ID DAYLIGHT_DEVELOPER_ID_P12_BASE64 DAYLIGHT_DEVELOPER_ID_P12_PASSWORD DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64"
notarize_vars="ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_PRIVATE_KEY_BASE64"
missing=""; any_set=false; unset_all=""
for v in $required DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64 $notarize_vars; do
  if [[ -n "${!v:-}" ]]; then any_set=true; else unset_all="$unset_all $v"; fi
done
for v in $required; do [[ -n "${!v:-}" ]] || missing="$missing $v"; done
# A release run must never pass with the wrong artifact; an ordinary push only warns about a partial set.
release=false
if [[ "${NOTARIZE_REQUESTED:-false}" == "true" || "${DO_NOTARIZE:-false}" == "true" || "${GITHUB_REF:-}" == refs/tags/v* ]]; then release=true; fi
if [[ -n "$missing" ]]; then
  if [[ "$any_set" == true || "${HAS_SIGNING:-}" == "true" ]]; then
    if [[ "$release" == true ]]; then
      echo "mac-release: ERROR: some signing secrets are set (or HAS_SIGNING=true) but these are missing or misnamed:$missing" >&2
      echo "mac-release: a partial secret set is always a mistake; the exact names are in $checklist" >&2
      exit 1
    fi
    echo "::warning::mac-release: WARNING: partial signing secret set on an ordinary push, signing skipped; missing or misnamed:$missing (a v* tag or notarize run fails here until they are set)"
    echo "mac-release: skipping the signed build (partial set, ordinary push). Missing:$missing"
    echo "mac-release: all names not set in this step:$unset_all"
    echo "mac-release: no Daylight-signed artifact this run; the unsigned artifact is uploaded as usual. Exact names: $checklist"
    exit 0
  fi
  echo "mac-release: skipping the signed build. Missing:$missing"
  echo "mac-release: optional: DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64; notarization needs a v* tag or the notarize dispatch input plus ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_PRIVATE_KEY_BASE64."
  echo "mac-release: see $checklist for how to create each one."
  exit 0
fi
asc_missing=""; asc_any=false
for v in $notarize_vars; do if [[ -n "${!v:-}" ]]; then asc_any=true; else asc_missing="$asc_missing $v"; fi; done
notarize=false
if [[ "${DO_NOTARIZE:-false}" == "true" ]]; then
  [[ -z "$asc_missing" ]] || { echo "mac-release: ERROR: DO_NOTARIZE=true but these are missing or misnamed:$asc_missing" >&2; exit 1; }
  notarize=true
elif [[ "${NOTARIZE_REQUESTED:-false}" == "true" ]]; then
  # The workflow asked for notarization (v* tag or dispatch input) and turned DO_NOTARIZE off only because an ASC
  # secret is empty. A signed but un-notarized extension fails with OSSystemExtensionError 8 on the Mac, so stop here.
  echo "mac-release: ERROR: notarization was requested (tag or dispatch) but these are missing or misnamed:$asc_missing" >&2
  exit 1
elif [[ "$asc_any" == true && -n "$asc_missing" ]]; then
  if [[ "$release" == true ]]; then
    echo "mac-release: ERROR: a partial ASC_* secret set; missing or misnamed:$asc_missing" >&2
    exit 1
  fi
  # Notarization is not requested on an ordinary push, so the complete DAYLIGHT_* set still signs.
  echo "::warning::mac-release: WARNING: partial ASC_* secret set on an ordinary push, notarization not requested so signing continues; missing or misnamed:$asc_missing (a v* tag or notarize run fails here until they are set)"
fi
echo "mac-release: signing secrets complete; notarize=$notarize (DO_NOTARIZE=${DO_NOTARIZE:-unset}, NOTARIZE_REQUESTED=${NOTARIZE_REQUESTED:-unset})"
if [[ "${DAYLIGHT_RELEASE_CHECK_ONLY:-}" == "1" ]]; then echo "mac-release: check-only mode, stopping before the keychain"; exit 0; fi
command -v xcodebuild >/dev/null 2>&1 || { echo "mac-release: xcodebuild not found" >&2; exit 2; }
mkdir -p build/release-logs
logs="build/release-logs"

# ---- 1. Temporary keychain with the Developer ID Application certificate ------------------------------------
made_tmp=false
if [[ -n "${RUNNER_TEMP:-}" ]]; then tmp="$RUNNER_TEMP"; else tmp="$(mktemp -d)"; made_tmp=true; fi
kc="$tmp/daylight-signing.keychain-db"
kcpw="${DAYLIGHT_KEYCHAIN_PASSWORD:-$(uuidgen)}"
# Remember the user's keychain search list so a local run can put it back (a CI runner is discarded).
saved_count=0
while IFS= read -r line; do
  line="${line#"${line%%[! ]*}"}"; line="${line#\"}"; line="${line%\"}"
  if [[ -n "$line" ]]; then saved_keychains[$saved_count]="$line"; saved_count=$((saved_count + 1)); fi
done < <(security list-keychains -d user)
cleanup() {
  local rc=$?
  set +x
  rm -f "$tmp/developer-id.p12" "$tmp/AuthKey.p8" "$tmp/app.provisionprofile" "$tmp/ext.provisionprofile" "$tmp/app.plist" "$tmp/ext.plist"
  if [[ -f "$kc" ]]; then security delete-keychain "$kc" >/dev/null 2>&1 || true; fi
  if [[ -z "${RUNNER_TEMP:-}" && "$saved_count" -gt 0 ]]; then security list-keychains -d user -s "${saved_keychains[@]}" || true; fi
  if [[ "$made_tmp" == true ]]; then rmdir "$tmp" 2>/dev/null || true; fi
  exit "$rc"
}
trap cleanup EXIT
security delete-keychain "$kc" >/dev/null 2>&1 || true
printf '%s' "$DAYLIGHT_DEVELOPER_ID_P12_BASE64" | base64 --decode > "$tmp/developer-id.p12"
security create-keychain -p "$kcpw" "$kc"
security set-keychain-settings -lut 21600 "$kc"
security unlock-keychain -p "$kcpw" "$kc"
security import "$tmp/developer-id.p12" -P "$DAYLIGHT_DEVELOPER_ID_P12_PASSWORD" -A -t cert -f pkcs12 -k "$kc" -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcrun
security set-key-partition-list -S 'apple-tool:,apple:' -k "$kcpw" "$kc" >/dev/null
security list-keychains -d user -s "$kc" "$HOME/Library/Keychains/login.keychain-db"
security find-identity -p codesigning -v "$kc" | tee "$logs/identities.txt"
identity="$(security find-identity -p codesigning -v "$kc" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
[[ -n "$identity" ]] || { echo "mac-release: no 'Developer ID Application' identity in the imported .p12" >&2; exit 1; }
identity_team="${identity##*(}"; identity_team="${identity_team%)}"
echo "mac-release: identity '$identity' (team $identity_team)"

# ---- 2. Provisioning profiles into both directories Xcode reads (pre and post Xcode 16) -----------------------
install_profile() { # $1 base64, $2 label -> prints profile Name; leaves the decoded plist at $tmp/<label>.plist
  local b64="$1" label="$2" f="$tmp/$2.provisionprofile" plist="$tmp/$2.plist" uuid name
  printf '%s' "$b64" | base64 --decode > "$f"
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
# Fail in seconds, not after a five-minute archive: the team must agree across the secret, the certificate and the
# app profile (OBS reads TeamIdentifier.0 the same way). The restricted entitlement check only warns, so an
# unexpected PlistBuddy output can never block a valid build (research-cmio-signing 0.3: Xcode 16 refuses to sign
# when the app profile does not allowlist com.apple.developer.system-extension.install).
{
  profile_team="$(plutil -extract TeamIdentifier.0 raw -expect string "$tmp/app.plist" 2>/dev/null || true)"
  echo "team: secret=$DAYLIGHT_TEAM_ID certificate=$identity_team app-profile=${profile_team:-?}"
  if [[ -n "$identity_team" && "$identity_team" != "$DAYLIGHT_TEAM_ID" ]]; then
    echo "mac-release: ERROR: DAYLIGHT_TEAM_ID '$DAYLIGHT_TEAM_ID' is not the team of the certificate '$identity' ($identity_team)" >&2; exit 1
  fi
  if [[ -n "$profile_team" && "$profile_team" != "$DAYLIGHT_TEAM_ID" ]]; then
    echo "mac-release: ERROR: DAYLIGHT_TEAM_ID '$DAYLIGHT_TEAM_ID' is not the TeamIdentifier of the app profile '$DAYLIGHT_APP_PROFILE' ($profile_team)" >&2; exit 1
  fi
  sysext="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.system-extension.install' "$tmp/app.plist" 2>&1 || true)"
  echo "app profile Entitlements com.apple.developer.system-extension.install: $sysext"
  [[ "$sysext" == "true" ]] || echo "mac-release: WARNING: the app profile does not allowlist com.apple.developer.system-extension.install (tick System Extension on the App ID, regenerate the profile); Xcode 16 will most likely refuse to sign"
  appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$tmp/app.plist" 2>&1 || true)"
  echo "app profile Entitlements com.apple.application-identifier: $appid (expected $DAYLIGHT_TEAM_ID.com.twelve.daylight)"
  [[ "$appid" == "$DAYLIGHT_TEAM_ID.com.twelve.daylight" ]] || echo "mac-release: WARNING: the app profile is not for com.twelve.daylight"
  echo "app profile ExpirationDate: $(plutil -extract ExpirationDate raw "$tmp/app.plist" 2>/dev/null || echo '?')"
} 2>&1 | tee "$logs/profile-check.txt"
if grep -q '^mac-release: ERROR' "$logs/profile-check.txt"; then exit 1; fi
export DAYLIGHT_CODE_SIGN_IDENTITY="Developer ID Application"
export DAYLIGHT_TEAM_ID

# ---- 3. Regenerate the project with the signing settings, flip the signed flag, archive, export ---------------
scripts/mac-generate.sh
plutil -replace DaylightBuildSigned -bool true mac/Daylight/Info.plist
echo "mac-release: mac/Daylight/Info.plist DaylightBuildSigned=$(plutil -extract DaylightBuildSigned raw mac/Daylight/Info.plist)" | tee "$logs/signed-flag.txt"
if [[ -n "${RUNNER_DEBUG:-}" ]]; then set -x; fi
# The vendored adb is a Mach-O inside Resources; Xcode signs only the bundle, notarization wants every executable
# signed with the hardened runtime and a timestamp (LOOSE_ENDS B6), so sign the source file before it is copied.
vendor_adb="mac/Daylight/Resources/Vendor/adb"
if [[ -f "$vendor_adb" ]]; then
  codesign --force --options runtime --timestamp --keychain "$kc" -s "$identity" "$vendor_adb" 2>&1 | tee "$logs/codesign-vendor-adb.txt"
  codesign -dvv "$vendor_adb" 2>&1 | tee -a "$logs/codesign-vendor-adb.txt" || true
else
  echo "mac-release: $vendor_adb not present (make fetch-tools not run); mirror mode will be unavailable in this build" | tee "$logs/codesign-vendor-adb.txt"
fi
xcodebuild ONLY_ACTIVE_ARCH=NO -project mac/Daylight.xcodeproj -scheme Daylight -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/Daylight.xcarchive \
  OTHER_CODE_SIGN_FLAGS="--keychain $kc --timestamp" archive 2>&1 | tee "$logs/archive.log" | grep -E '^(error|\*\* ARCHIVE)' || true
grep -q 'ARCHIVE SUCCEEDED' "$logs/archive.log" || { echo "mac-release: archive failed, see archive.log in the release-logs artifact" >&2; exit 1; }
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
cp build/ExportOptions.plist "$logs/ExportOptions.plist"
rm -rf build/export
xcodebuild -exportArchive -archivePath build/Daylight.xcarchive -exportOptionsPlist build/ExportOptions.plist -exportPath build/export 2>&1 | tee "$logs/export.log" | grep -E '^(error|\*\* EXPORT)' || true
app="build/export/Daylight.app"
[[ -d "$app" ]] || { echo "mac-release: export produced no Daylight.app, see export.log in the release-logs artifact" >&2; exit 1; }
# The two facts that decide whether the signed app behaves as signed: the flag the app reads at launch (SPEC I4) and
# the profile that authorises the restricted system-extension entitlement (TN3125).
flag="$(plutil -extract DaylightBuildSigned raw "$app/Contents/Info.plist" 2>&1 || true)"
echo "mac-release: exported Info.plist DaylightBuildSigned=$flag" | tee -a "$logs/signed-flag.txt"
[[ "$flag" == "true" ]] || { echo "mac-release: ERROR: the exported app still carries DaylightBuildSigned=$flag; the app would run as an unsigned test build" >&2; exit 1; }
if [[ -f "$app/Contents/embedded.provisionprofile" ]]; then
  echo "mac-release: Contents/embedded.provisionprofile present" | tee -a "$logs/signed-flag.txt"
else
  echo "mac-release: ERROR: $app/Contents/embedded.provisionprofile is missing; com.apple.developer.system-extension.install would be unauthorised" >&2; exit 1
fi

# ---- 4. Pre-notarization checks (Apple: resolving common notarization issues) -------------------------------
codesign -vvv --deep --strict "$app" 2>&1 | tee "$logs/codesign-verify.txt"
codesign -d --entitlements :- "$app" 2>&1 | tee "$logs/entitlements.txt"
codesign -dvv "$app" 2>&1 | tee "$logs/codesign-dvv.txt"
spctl -vvv --assess --type exec "$app" 2>&1 | tee "$logs/spctl.txt" || echo "mac-release: spctl rejects until notarized (expected before notarization)"
rm -f build/Daylight-signed.zip; ditto -c -k --keepParent "$app" build/Daylight-signed.zip
ls -la build/Daylight-signed.zip

# ---- 5. Notarize + staple + DMG, only when asked (the gate already proved the ASC_* secrets are complete) -----
if [[ "$notarize" != "true" ]]; then echo "mac-release: notarization not requested; signed zip only."; exit 0; fi
set +x
printf '%s' "$ASC_API_PRIVATE_KEY_BASE64" | base64 --decode > "$tmp/AuthKey.p8"
if [[ -n "${RUNNER_DEBUG:-}" ]]; then set -x; fi
rm -rf build/dmg-root build/Daylight.dmg; mkdir -p build/dmg-root; cp -R "$app" build/dmg-root/
ln -s /Applications build/dmg-root/Applications
hdiutil create -volname "Daylight" -srcfolder build/dmg-root -format UDZO -ov build/Daylight.dmg
codesign --force --timestamp --keychain "$kc" -s "$identity" -i com.twelve.daylight.dmg build/Daylight.dmg
# Notarization in two calls (run 37220975435, the first signed run: Apple took more than 30 minutes for the first
# submission of a new team, `submit --wait --timeout 30m` exited 124 with the submission id only in the timeout
# message on stderr, and the id parse read plutil's error text as the id). `submit` returns the id in seconds;
# `wait` holds the runner for up to DAYLIGHT_NOTARY_WAIT (default 75m, inside the 120 minute notarize job budget).
# Whatever Apple does, the signed DMG leaves the runner: stapled as Daylight-dmg when accepted, otherwise as
# Daylight-dmg-pending next to NOTARIZATION-PENDING.txt (the id and this run's id), which the notary workflow
# (.github/workflows/notary.yml, scripts/notary-resume.sh) turns into the stapled Daylight-dmg once Apple has finished.
# An accepted but un-stapled DMG already opens on an online Mac: Gatekeeper fetches the ticket from Apple.
notary_args=(--key "$tmp/AuthKey.p8" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" --output-format json)
json_field() { # $1 key, $2 file -> the value, or nothing (plutil prints its errors on stdout, so check the exit code)
  local v
  if [[ -s "$2" ]] && v="$(plutil -extract "$1" raw -o - "$2" 2>/dev/null)"; then printf '%s' "$v"; fi
}
is_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
set +e
xcrun notarytool submit build/Daylight.dmg "${notary_args[@]}" > "$logs/notarytool-submit.json" 2> "$logs/notarytool-submit.err"
rc=$?
set -e
echo "mac-release: notarytool submit exit $rc"; cat "$logs/notarytool-submit.json"; echo; cat "$logs/notarytool-submit.err"
id="$(json_field id "$logs/notarytool-submit.json")"
if ! is_uuid "${id:-}"; then
  # The timeout and some errors print their JSON on stderr; one more place to look before giving up.
  id="$(sed -n 's/.*"id" *: *"\([0-9a-fA-F-]\{36\}\)".*/\1/p' "$logs/notarytool-submit.err" | head -1)"
fi
if (( rc != 0 )) || ! is_uuid "${id:-}"; then
  echo "mac-release: notarization failed: notarytool submit exit $rc, no submission id; see notarytool-submit.err in the release-logs artifact (401: swapped Key ID and Issuer ID or the wrong .p8; 403: the key's role)" >&2
  exit 1
fi
printf '%s\n' "$id" > "$logs/notary-submission-id.txt"
echo "::notice::mac-release: notarization submission $id (run ${GITHUB_RUN_ID:-local}); the notary workflow can finish it later with these two ids"
wait_for="${DAYLIGHT_NOTARY_WAIT:-75m}"
echo "mac-release: notarytool wait $id --timeout $wait_for"
set +e
xcrun notarytool wait "$id" --timeout "$wait_for" "${notary_args[@]}" > "$logs/notarytool-wait.json" 2> "$logs/notarytool-wait.err"
wrc=$?
set -e
echo "mac-release: notarytool wait exit $wrc"; cat "$logs/notarytool-wait.json"; echo; cat "$logs/notarytool-wait.err"
status="$(json_field status "$logs/notarytool-wait.json")"
if [[ -z "$status" ]]; then
  # A timeout prints only a message; ask for the current status so the log and the pending note name it.
  xcrun notarytool info "$id" "${notary_args[@]}" > "$logs/notarytool-info.json" 2> "$logs/notarytool-info.err" || true
  status="$(json_field status "$logs/notarytool-info.json")"
fi
echo "mac-release: notarization status '${status:-unknown}' for $id"
# The notary log exists once processing has finished (Accepted or Invalid); while In Progress it is empty.
if [[ "$status" == "Accepted" || "$status" == "Invalid" || "$status" == "Rejected" ]]; then
  xcrun notarytool log "$id" --key "$tmp/AuthKey.p8" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" "$logs/notarization-log.json" || echo "mac-release: notarytool log failed for $id"
  [[ -f "$logs/notarization-log.json" ]] && cat "$logs/notarization-log.json"
fi
if [[ "$status" != "Accepted" ]]; then
  if [[ "$status" == "Invalid" || "$status" == "Rejected" ]]; then
    echo "mac-release: notarization failed: status '$status', id $id; notarization-log.json in the release-logs artifact lists the issues" >&2
    exit 1
  fi
  # Still In Progress (or unknown): keep the signed DMG, say how to finish, and fail this run honestly.
  cp build/Daylight.dmg build/Daylight-pending.dmg
  {
    echo "submission_id=$id"
    echo "source_run_id=${GITHUB_RUN_ID:-local}"
    echo "status=${status:-unknown}"
    echo "The DMG next to this file is signed and submitted but not yet notarized."
    echo "Finish: Actions > notary > Run workflow with submission_id=$id and source_run_id=${GITHUB_RUN_ID:-local} (docs/SIGNING.md, 'A slow notarization')."
  } > "$logs/NOTARIZATION-PENDING.txt"
  cat "$logs/NOTARIZATION-PENDING.txt"
  echo "::warning::mac-release: Apple has not finished notarizing $id after $wait_for (status '${status:-unknown}'). The signed DMG is uploaded as Daylight-dmg-pending; run the notary workflow with submission_id=$id source_run_id=${GITHUB_RUN_ID:-local} to staple it once Apple accepts."
  echo "mac-release: notarization pending: status '${status:-unknown}', id $id; see docs/SIGNING.md 'A slow notarization'" >&2
  exit 1
fi
xcrun stapler staple build/Daylight.dmg
printf '%s\n' "$id" > "$logs/stapled.ok"
# The ticket covers the app's cdhashes too; staple the exported app and re-zip it so Daylight-signed.zip ships the
# stapled copy. The app inside Daylight.dmg is the pre-staple copy (validated online on first launch), see LOOSE_ENDS.
if xcrun stapler staple "$app"; then
  rm -f build/Daylight-signed.zip; ditto -c -k --keepParent "$app" build/Daylight-signed.zip
else
  echo "mac-release: stapling the exported app failed (the DMG is stapled; Daylight-signed.zip keeps the un-stapled app)"
fi
spctl -vvv --assess --type exec "$app" 2>&1 | tee "$logs/spctl-after.txt" || true
ls -la build/Daylight.dmg build/Daylight-signed.zip
