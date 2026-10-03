#!/usr/bin/env bash
# make scripts-check: bash tests for the parts of the release scripts that run before any Apple tool, so they
# can be proved on Linux (the golden job) long before the first signed run on the owner's secrets.
#   mac-release.sh gate: exit 0 with no secrets, exit 1 naming a missing or misnamed secret of a partial set,
#                        exit 1 when notarization was requested without the ASC_* secrets, check-only mode.
#   ci-env.sh:           DAYLIGHT_XCODE_PATH writes DEVELOPER_DIR to $GITHUB_ENV (an export alone never reaches
#                        the later steps of a job), and a wrong path leaves it untouched.
#   fetch-tools.sh:      the committed Apache-2.0 text exists and is the license (shipped as Vendor/LICENSE-Apache-2.0.txt).
set -euo pipefail
cd "$(dirname "$0")/.."
fails=0; passes=0
out=""; rc=0
run_release() { # env assignments as NAME=value words; runs mac-release.sh with a clean environment
  set +e
  out="$(env -i PATH="$PATH" HOME="$HOME" "$@" bash scripts/mac-release.sh 2>&1)"
  rc=$?
  set -e
}
expect() { # $1 case name, $2 expected rc, $3 regex the output must match
  if [[ "$rc" == "$2" ]] && grep -Eq -- "$3" <<<"$out"; then
    echo "ok    $1"; passes=$((passes + 1))
  else
    echo "FAIL  $1: expected exit $2 matching /$3/, got exit $rc:"; sed 's/^/        /' <<<"$out"; fails=$((fails + 1))
  fi
}
four="DAYLIGHT_TEAM_ID=ABCDE12345 DAYLIGHT_DEVELOPER_ID_P12_BASE64=cDEy DAYLIGHT_DEVELOPER_ID_P12_PASSWORD=pw DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64=cHJvZmlsZQ=="
asc="ASC_API_KEY_ID=KEY ASC_API_ISSUER_ID=ISSUER ASC_API_PRIVATE_KEY_BASE64=cDg="

run_release
expect "no secrets: skip with exit 0" 0 "skipping the signed build"
expect "no secrets: the message points at an existing file" 0 "docs/handoff/c-camera-extension-and-host-sink-client.md section 7"
run_release DAYLIGHT_TEAM_ID=ABCDE12345 DAYLIGHT_DEVELOPER_ID_P12_BASE64=cDEy DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64=cHJvZmlsZQ==
expect "three of four signing secrets: exit 1 naming the password" 1 "missing or misnamed: DAYLIGHT_DEVELOPER_ID_P12_PASSWORD$"
run_release HAS_SIGNING=true
expect "HAS_SIGNING=true with an empty step env: exit 1" 1 "missing or misnamed:.*DAYLIGHT_TEAM_ID"
run_release ASC_API_KEY_ID=KEY
expect "only an ASC secret: exit 1 (partial set)" 1 "missing or misnamed:.*DAYLIGHT_DEVELOPER_ID_P12_BASE64"
run_release $four DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "four signing secrets, check-only: exit 0, notarize=false" 0 "notarize=false \\("
expect "four signing secrets, check-only: stops before the keychain" 0 "check-only mode"
run_release $four NOTARIZE_REQUESTED=true DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "notarization requested by tag or dispatch without ASC secrets: exit 1" 1 "notarization was requested.*ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_PRIVATE_KEY_BASE64"
run_release $four DO_NOTARIZE=true ASC_API_KEY_ID=KEY ASC_API_PRIVATE_KEY_BASE64=cDg= DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "DO_NOTARIZE=true with the issuer missing: exit 1 naming it" 1 "DO_NOTARIZE=true but these are missing or misnamed: ASC_API_ISSUER_ID$"
run_release $four ASC_API_KEY_ID=KEY DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "partial ASC set on a plain push: exit 1" 1 "partial ASC_\\* secret set"
run_release $four $asc DO_NOTARIZE=true DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "all eight secrets with DO_NOTARIZE=true, check-only: exit 0, notarize=true" 0 "notarize=true \\(DO_NOTARIZE=true"
run_release $four $asc DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "all eight secrets on a plain push: exit 0, notarize=false" 0 "notarize=false"

# ci-env.sh and DAYLIGHT_XCODE_PATH
tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/Xcode_26.3.app/Contents/Developer"; : > "$tmpdir/github.env"
set +e; out="$(DAYLIGHT_XCODE_PATH="$tmpdir/Xcode_26.3.app" GITHUB_ENV="$tmpdir/github.env" bash scripts/ci-env.sh 2>&1)"; rc=$?; set -e
expect "ci-env: a valid DAYLIGHT_XCODE_PATH is logged" 0 "DEVELOPER_DIR set from DAYLIGHT_XCODE_PATH"
if grep -qx "DEVELOPER_DIR=$tmpdir/Xcode_26.3.app/Contents/Developer" "$tmpdir/github.env"; then
  echo "ok    ci-env: DEVELOPER_DIR written to GITHUB_ENV"; passes=$((passes + 1))
else
  echo "FAIL  ci-env: GITHUB_ENV does not carry DEVELOPER_DIR:"; sed 's/^/        /' "$tmpdir/github.env"; fails=$((fails + 1))
fi
: > "$tmpdir/github.env"
set +e; out="$(DAYLIGHT_XCODE_PATH="$tmpdir/missing.app" GITHUB_ENV="$tmpdir/github.env" bash scripts/ci-env.sh 2>&1)"; rc=$?; set -e
expect "ci-env: a wrong DAYLIGHT_XCODE_PATH keeps the default Xcode" 0 "does not exist, keeping the default Xcode"
if [[ ! -s "$tmpdir/github.env" ]]; then echo "ok    ci-env: GITHUB_ENV untouched for a wrong path"; passes=$((passes + 1)); else echo "FAIL  ci-env: GITHUB_ENV written for a wrong path"; fails=$((fails + 1)); fi

# The committed license text fetch-tools.sh copies into Vendor/.
lic="scripts/licenses/Apache-2.0.txt"
if [[ -f "$lic" ]] && grep -q "Apache License" "$lic" && grep -q "Version 2.0, January 2004" "$lic" && grep -q "Genymobile" "$lic"; then
  echo "ok    $lic is the Apache License 2.0 with the scrcpy attribution"; passes=$((passes + 1))
else
  echo "FAIL  $lic missing or not the Apache License 2.0"; fails=$((fails + 1))
fi
grep -q 'cp scripts/licenses/Apache-2.0.txt "$out/LICENSE-Apache-2.0.txt"' scripts/fetch-tools.sh && { echo "ok    fetch-tools.sh ships the license text"; passes=$((passes + 1)); } || { echo "FAIL  fetch-tools.sh does not copy the license text"; fails=$((fails + 1)); }

echo "scripts-check: $passes passed, $fails failed"
(( fails == 0 ))
