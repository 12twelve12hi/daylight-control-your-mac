#!/usr/bin/env bash
# make scripts-check: bash tests for the parts of the release scripts that run before any Apple tool, so they
# can be proved on Linux (the golden job) long before the first signed run on the owner's secrets.
#   mac-release.sh gate: exit 0 with no secrets; a partial or misnamed set warns (::warning::, naming the gap) and
#                        exits 0 on an ordinary push but exits 1 on a v* tag, a notarize dispatch or DO_NOTARIZE=true;
#                        exit 1 when notarization was requested without the ASC_* secrets; the complete DAYLIGHT_* set
#                        proceeds to the signed build; check-only mode.
#   notary-resume.sh:    the notary workflow's gate: missing ASC_* secrets or inputs exit 1 naming them, a submission id
#                        that is not a UUID or a run id that is not a number exits 1, the complete set stops in check-only
#                        mode; the sed fallback of mac-release.sh recovers the id from notarytool's timeout message.
#   ci-env.sh:           DAYLIGHT_XCODE_PATH writes DEVELOPER_DIR to $GITHUB_ENV (an export alone never reaches
#                        the later steps of a job), and a wrong path leaves it untouched.
#   fetch-tools.sh:      the committed Apache-2.0 text exists and is the license (shipped as Vendor/LICENSE-Apache-2.0.txt).
#   LICENSE:             the project's own license is the standard Apache-2.0 text, identical to LICENSES/Apache-2.0.txt
#                        apart from the appendix copyright lines (scrcpy's attribution there, the template here).
#   kit-test.sh:         a crash of swift-package (exit 139) is retried with the whole suite and a log line; a test
#                        failure (exit 1) is never retried; a crash on every attempt still fails (a stub swift).
#   android-emulator.sh: parses; the am instrument rule (OK passes; FAILURES!!!, INSTRUMENTATION_FAILED, Process crashed,
#                        no OK line and OK (0 tests) fail); the logcat rule (a FATAL EXCEPTION or ANR in the app fails,
#                        another package's crash does not).
#   ui-expectations.sh:  the docs-to-UI string extraction: a fixture gives the exact expected JSON; the real docs give
#                        at least 40 Mac strings with the known ones (Transport, adb source, Export diagnostics..., Setup again,
#                        the Share tab and its menu).
#   crash-summary.sh:    mac-test.sh's crash lines: a sample test log and a sample .ips report give the exception, the
#                        crashed thread's frames with their image names; a report older than the start stamp is ignored.
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
expect_no() { # $1 case name, $2 regex the output must not match
  if ! grep -Eq -- "$2" <<<"$out"; then
    echo "ok    $1"; passes=$((passes + 1))
  else
    echo "FAIL  $1: output matches /$2/:"; sed 's/^/        /' <<<"$out"; fails=$((fails + 1))
  fi
}
four="DAYLIGHT_TEAM_ID=ABCDE12345 DAYLIGHT_DEVELOPER_ID_P12_BASE64=cDEy DAYLIGHT_DEVELOPER_ID_P12_PASSWORD=pw DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64=cHJvZmlsZQ=="
asc="ASC_API_KEY_ID=KEY ASC_API_ISSUER_ID=ISSUER ASC_API_PRIVATE_KEY_BASE64=cDg="

run_release
expect "no secrets: skip with exit 0" 0 "skipping the signed build"
expect "no secrets: the message points at an existing file" 0 "docs/SIGNING.md"
[[ -f docs/SIGNING.md ]] && { echo "ok    docs/SIGNING.md exists"; passes=$((passes + 1)); } || { echo "FAIL  docs/SIGNING.md is missing"; fails=$((fails + 1)); }
# A partial set: an ordinary push warns and exits 0 (the owner adds secrets over hours); a release run fails.
partial="DAYLIGHT_TEAM_ID=ABCDE12345 DAYLIGHT_DEVELOPER_ID_P12_PASSWORD=pw ASC_API_KEY_ID=KEY ASC_API_ISSUER_ID=ISSUER"
gap="DAYLIGHT_DEVELOPER_ID_P12_BASE64 DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64"
run_release $partial DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "partial set on a plain push: exit 0 with a ::warning:: naming the gap" 0 "^::warning::mac-release: WARNING: .*missing or misnamed: $gap \\("
expect "partial set on a plain push: the signing skipped line" 0 "^mac-release: skipping the signed build \\(partial set, ordinary push\\)\\. Missing: $gap$"
expect_no "partial set on a plain push: no signed build" "signing secrets complete|ERROR"
run_release $partial NOTARIZE_REQUESTED=true GITHUB_REF=refs/tags/v1.0.0 DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "partial set on a v* tag: exit 1 naming the gap" 1 "^mac-release: ERROR: some signing secrets are set .*missing or misnamed: $gap$"
expect_no "partial set on a v* tag: no warning downgrade" "::warning::"
run_release $partial GITHUB_REF=refs/tags/v1.0.0 DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "partial set with only GITHUB_REF a v* tag: exit 1" 1 "missing or misnamed: $gap$"
run_release $partial NOTARIZE_REQUESTED=true GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "partial set with a notarize dispatch: exit 1 naming the gap" 1 "^mac-release: ERROR: some signing secrets are set .*missing or misnamed: $gap$"
run_release $partial DO_NOTARIZE=true DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "partial set with DO_NOTARIZE=true: exit 1" 1 "missing or misnamed: $gap$"
run_release DAYLIGHT_TEAM_ID=ABCDE12345 DAYLIGHT_DEVELOPER_ID_P12_BASE64=cDEy DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64=cHJvZmlsZQ==
expect "three of four signing secrets on a plain push: warn naming the password, exit 0" 0 "^::warning::.*missing or misnamed: DAYLIGHT_DEVELOPER_ID_P12_PASSWORD \\("
run_release DAYLIGHT_TEAM_ID=ABCDE12345 DAYLIGHT_DEVELOPER_ID_P12_BASE64=cDEy DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64=cHJvZmlsZQ== NOTARIZE_REQUESTED=true
expect "three of four signing secrets on a tag: exit 1 naming the password" 1 "missing or misnamed: DAYLIGHT_DEVELOPER_ID_P12_PASSWORD$"
run_release HAS_SIGNING=true
expect "HAS_SIGNING=true with an empty step env (misnamed) on a plain push: warn, exit 0" 0 "^::warning::.*missing or misnamed:.*DAYLIGHT_TEAM_ID"
run_release HAS_SIGNING=true NOTARIZE_REQUESTED=true
expect "HAS_SIGNING=true with an empty step env on a tag: exit 1" 1 "missing or misnamed:.*DAYLIGHT_TEAM_ID"
run_release ASC_API_KEY_ID=KEY
expect "only an ASC secret on a plain push: warn, exit 0" 0 "^::warning::.*missing or misnamed:.*DAYLIGHT_DEVELOPER_ID_P12_BASE64"
run_release ASC_API_KEY_ID=KEY DO_NOTARIZE=true
expect "only an ASC secret with DO_NOTARIZE=true: exit 1 (partial set)" 1 "missing or misnamed:.*DAYLIGHT_DEVELOPER_ID_P12_BASE64"
run_release $four DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "four signing secrets, check-only: exit 0, notarize=false" 0 "notarize=false \\("
expect "four signing secrets, check-only: stops before the keychain" 0 "check-only mode"
run_release $four NOTARIZE_REQUESTED=true DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "notarization requested by tag or dispatch without ASC secrets: exit 1" 1 "notarization was requested.*ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_PRIVATE_KEY_BASE64"
run_release $four DO_NOTARIZE=true ASC_API_KEY_ID=KEY ASC_API_PRIVATE_KEY_BASE64=cDg= DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "DO_NOTARIZE=true with the issuer missing: exit 1 naming it" 1 "DO_NOTARIZE=true but these are missing or misnamed: ASC_API_ISSUER_ID$"
run_release $four ASC_API_KEY_ID=KEY DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "partial ASC set on a plain push: warn naming the gap" 0 "^::warning::.*partial ASC_\\* secret set.*missing or misnamed: ASC_API_ISSUER_ID ASC_API_PRIVATE_KEY_BASE64 \\("
expect "partial ASC set on a plain push: the complete DAYLIGHT_* set still signs" 0 "signing secrets complete; notarize=false"
run_release $four ASC_API_KEY_ID=KEY GITHUB_REF=refs/tags/v1.0.0 DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "partial ASC set with GITHUB_REF a v* tag: exit 1" 1 "partial ASC_\\* secret set"
run_release $four $asc DO_NOTARIZE=true DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "all eight secrets with DO_NOTARIZE=true, check-only: exit 0, notarize=true" 0 "notarize=true \\(DO_NOTARIZE=true"
run_release $four $asc DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "all eight secrets on a plain push: exit 0, notarize=false" 0 "notarize=false"

# notary-resume.sh (the notary workflow, docs/SIGNING.md "A slow notarization"): the gate on Linux.
run_notary() { set +e; out="$(env -i PATH="$PATH" HOME="$HOME" "$@" bash scripts/notary-resume.sh 2>&1)"; rc=$?; set -e; }
sub="7e8ea93d-c846-4fec-99fe-a9597c6739ba"
run_notary
expect "notary-resume: nothing set: exit 1 naming the three secrets and the input" 1 "missing or empty: ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_PRIVATE_KEY_BASE64 NOTARY_SUBMISSION_ID \\("
run_notary $asc
expect "notary-resume: secrets without a submission id: exit 1 naming it" 1 "missing or empty: NOTARY_SUBMISSION_ID \\("
run_notary $asc NOTARY_SUBMISSION_ID=not-a-uuid DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "notary-resume: a submission id that is not a UUID: exit 1" 1 "is not a UUID"
run_notary $asc NOTARY_SUBMISSION_ID=$sub NOTARY_SOURCE_RUN_ID=run-37220975435 DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "notary-resume: a run id that is not a number: exit 1" 1 "is not a run id"
run_notary $asc NOTARY_SUBMISSION_ID=$sub NOTARY_SOURCE_RUN_ID=37220975435 DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "notary-resume: complete inputs, check-only: exit 0 before notarytool" 0 "check-only mode"
expect "notary-resume: complete inputs: both ids echoed" 0 "submission $sub, source run '37220975435'"
run_notary $asc NOTARY_SUBMISSION_ID=$sub DAYLIGHT_RELEASE_CHECK_ONLY=1
expect "notary-resume: no source run id is allowed (status only)" 0 "source run 'none'"
# mac-release.sh reads the submission id from notarytool's stderr when the JSON on stdout is empty (the timeout of run
# 37220975435 printed exactly this line there); the expression under test is the one in the script.
idsed="$(grep -o "sed -n 's/\.\*\"id\"[^']*'" scripts/mac-release.sh | head -1)"
msg='{"id":"7e8ea93d-c846-4fec-99fe-a9597c6739ba","message":"Timeout of 1800 second(s) was reached before processing completed."}'
got="$(eval "$idsed" <<<"$msg" | head -1)"
if [[ -n "$idsed" && "$got" == "$sub" ]]; then echo "ok    mac-release: the stderr fallback recovers the submission id from the timeout message"; passes=$((passes + 1)); else echo "FAIL  mac-release: id fallback gave '$got' from '$idsed'"; fails=$((fails + 1)); fi
grep -q 'notarytool wait "\$id" --timeout "\$wait_for"' scripts/mac-release.sh && { echo "ok    mac-release: submit and wait are separate calls"; passes=$((passes + 1)); } || { echo "FAIL  mac-release: no separate notarytool wait"; fails=$((fails + 1)); }
grep -q 'NOTARIZATION-PENDING.txt' scripts/mac-release.sh && grep -q 'Daylight-dmg-pending' .github/workflows/ci.yml && { echo "ok    mac-release: a pending notarization keeps the signed DMG (Daylight-dmg-pending)"; passes=$((passes + 1)); } || { echo "FAIL  mac-release: no pending DMG path"; fails=$((fails + 1)); }

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

# The committed license text fetch-tools.sh copies into Vendor/ (LICENSES/, LOOSE_ENDS G15).
lic="LICENSES/Apache-2.0.txt"
if [[ -f "$lic" ]] && grep -q "Apache License" "$lic" && grep -q "Version 2.0, January 2004" "$lic" && grep -q "Genymobile" "$lic"; then
  echo "ok    $lic is the Apache License 2.0 with the scrcpy attribution"; passes=$((passes + 1))
else
  echo "FAIL  $lic missing or not the Apache License 2.0"; fails=$((fails + 1))
fi
grep -q 'cp LICENSES/Apache-2.0.txt "$out/LICENSE-Apache-2.0.txt"' scripts/fetch-tools.sh && { echo "ok    fetch-tools.sh ships the license text"; passes=$((passes + 1)); } || { echo "FAIL  fetch-tools.sh does not copy the license text"; fails=$((fails + 1)); }
# The project's own LICENSE (LOOSE_ENDS A14): the standard Apache-2.0 text with the unfilled appendix template.
if [[ -f LICENSE ]] && grep -qx '   Copyright \[yyyy\] \[name of copyright owner\]' LICENSE \
  && diff -q <(grep -v '^   Copyright ' LICENSE) <(grep -v '^   Copyright ' "$lic" | sed -e :a -e '/^$/{$d;N;ba' -e '}') >/dev/null; then
  echo "ok    LICENSE is the standard Apache License 2.0 text"; passes=$((passes + 1))
else
  echo "FAIL  LICENSE missing or not the standard Apache License 2.0 text"; fails=$((fails + 1))
fi

# kit-test.sh against a stub swift in a scratch copy of the tree (the retry wipes mac/DaylightKit/.build). The stub
# exits with the codes listed in $tmpdir/kit/codes, one per `swift test` call, and logs each call.
mkdir -p "$tmpdir/kit/tree/scripts" "$tmpdir/kit/tree/mac/DaylightKit/.build" "$tmpdir/kit/bin"
cp scripts/kit-test.sh "$tmpdir/kit/tree/scripts/kit-test.sh"
cat > "$tmpdir/kit/bin/swift" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "Swift version stub"; exit 0; }
echo "$*" >> "$KIT_STUB_DIR/calls"
n=$(( $(wc -l < "$KIT_STUB_DIR/calls") ))
code=$(sed -n "${n}p" "$KIT_STUB_DIR/codes")
exit "${code:-0}"
STUB
chmod +x "$tmpdir/kit/bin/swift"
run_kit() { # $@ exit codes of the successive swift test calls
  printf '%s\n' "$@" > "$tmpdir/kit/codes"; : > "$tmpdir/kit/calls"
  set +e
  out="$(env -u CI PATH="$tmpdir/kit/bin:$PATH" KIT_STUB_DIR="$tmpdir/kit" bash "$tmpdir/kit/tree/scripts/kit-test.sh" 2>&1)"
  rc=$?
  set -e
  out="$out
calls=$(( $(wc -l < "$tmpdir/kit/calls") )) args=$(head -1 "$tmpdir/kit/calls")"
}
run_kit 139 0
expect "kit-test: a swift-package crash (139) is retried and the second run passes" 0 "crashed with exit 139 \\(signal 11\\).*attempt 2 of 3"
expect "kit-test: the retry runs the whole suite again with --parallel" 0 "calls=2 args=test --package-path mac/DaylightKit --parallel$"
[[ ! -d "$tmpdir/kit/tree/mac/DaylightKit/.build" ]] && { echo "ok    kit-test: the retry starts from an empty .build"; passes=$((passes + 1)); } || { echo "FAIL  kit-test: .build survived the retry"; fails=$((fails + 1)); }
run_kit 1
expect "kit-test: a test failure (exit 1) is not retried" 1 "calls=1 "
run_kit 139 139 139
expect "kit-test: a crash on every attempt fails with its exit code" 139 "attempt 3 of 3; giving up"
expect "kit-test: a crash on every attempt stops after three runs" 139 "calls=3 "

# LOOSE_ENDS H1: the download pins in the app equal the bundled pins in fetch-tools.sh; the build switch is wired.
check_eq() { # $1 name, $2 got, $3 want
  if [[ -n "$2" && "$2" == "$3" ]]; then echo "ok    $1"; passes=$((passes + 1)); else echo "FAIL  $1: got '$2' want '$3'"; fails=$((fails + 1)); fi
}
swift_src=mac/Daylight/Sources/Mirror/AdbClientSources.swift
check_eq "adb pin: Swift platformToolsVersion equals fetch-tools PT_VERSION" \
  "$(sed -n 's/.*static let platformToolsVersion = "\([^"]*\)".*/\1/p' "$swift_src")" \
  "$(sed -n 's/^PT_VERSION="${PT_VERSION:-\([^}]*\)}"$/\1/p' scripts/fetch-tools.sh)"
check_eq "adb pin: Swift platformToolsSHA256 equals fetch-tools PT_SHA256" \
  "$(sed -n 's/.*static let platformToolsSHA256 = "\([0-9a-f]*\)".*/\1/p' "$swift_src")" \
  "$(sed -n 's/^PT_SHA256="\([0-9a-f]*\)"$/\1/p' scripts/fetch-tools.sh)"
check_eq "adb switch: project.yml writes DaylightBundlesAdb from DAYLIGHT_BUNDLE_ADB" \
  "$(grep -c 'DaylightBundlesAdb: "${DAYLIGHT_BUNDLE_ADB}"' mac/project.yml)" "1"
check_eq "adb switch: mac-generate.sh defaults DAYLIGHT_BUNDLE_ADB to 1" \
  "$(grep -c 'export DAYLIGHT_BUNDLE_ADB="${DAYLIGHT_BUNDLE_ADB:-1}"' scripts/mac-generate.sh)" "1"
check_eq "adb switch: fetch-tools.sh leaves adb out on DAYLIGHT_BUNDLE_ADB=0" \
  "$(grep -c 'if \[\[ "$DAYLIGHT_BUNDLE_ADB" == "0" \]\]; then' scripts/fetch-tools.sh)" "1"
check_eq "adb switch: the Swift key name matches project.yml" \
  "$(sed -n 's/.*static let bundlesAdbInfoKey = "\([^"]*\)".*/\1/p' "$swift_src")" "DaylightBundlesAdb"

# android-emulator.sh: the pass/fail rules the CI emulator job applies (no adb needed for these phases).
emu() { # $1 phase, $2 fixture text
  printf '%b' "$2" > "$tmpdir/emu.txt"
  set +e; out="$(env -u CI bash scripts/android-emulator.sh "$1" "$tmpdir/emu.txt" 2>&1)"; rc=$?; set -e
}
bash -n scripts/android-emulator.sh && { echo "ok    android-emulator.sh parses"; passes=$((passes + 1)); } || { echo "FAIL  android-emulator.sh has a syntax error"; fails=$((fails + 1)); }
emu check-instrument 'INSTRUMENTATION_STATUS_CODE: 1\nINSTRUMENTATION_STATUS_CODE: 0\nINSTRUMENTATION_RESULT: stream=\n\nOK (3 tests)\n\nINSTRUMENTATION_CODE: -1\n'
expect "emulator: OK (3 tests) passes" 0 ""
emu check-instrument 'OK (1 test)\n'
expect "emulator: OK (1 test) passes" 0 ""
emu check-instrument 'INSTRUMENTATION_STATUS_CODE: -2\nFAILURES!!!\nTests run: 3,  Failures: 1\n'
expect "emulator: FAILURES!!! fails" 1 "FAILURES!!! \\(Tests run: 3"
emu check-instrument 'INSTRUMENTATION_FAILED: com.twelve.daylight.ink.test/androidx.test.runner.AndroidJUnitRunner\n'
expect "emulator: INSTRUMENTATION_FAILED fails" 1 "INSTRUMENTATION_FAILED"
emu check-instrument 'INSTRUMENTATION_RESULT: shortMsg=Process crashed.\nINSTRUMENTATION_CODE: 0\n'
expect "emulator: Process crashed fails" 1 "Process crashed"
emu check-instrument 'INSTRUMENTATION_STATUS_CODE: 1\n'
expect "emulator: output without an OK line fails" 1 "no 'OK \\(' line"
emu check-instrument 'OK (0 tests)\n'
expect "emulator: OK (0 tests) fails" 1 "no test ran"
emu check-logcat '10-04 12:00:00.400   777   777 E AndroidRuntime: FATAL EXCEPTION: main\n10-04 12:00:00.401   777   777 E AndroidRuntime: Process: com.android.other, PID: 777\n10-04 12:00:01.000   500   520 E ActivityManager: ANR in com.android.other\n'
expect "emulator: another package's crash and ANR pass" 0 ""
emu check-logcat '10-04 12:00:00.400  4321  4321 E AndroidRuntime: FATAL EXCEPTION: main\n10-04 12:00:00.401  4321  4321 E AndroidRuntime: Process: com.twelve.daylight.ink, PID: 4321\n'
expect "emulator: a FATAL EXCEPTION in the app fails" 1 "FATAL EXCEPTION in com.twelve.daylight.ink"
emu check-logcat '10-04 12:00:01.000   500   520 E ActivityManager: ANR in com.twelve.daylight.ink (com.twelve.daylight.ink/.ui.MainActivity)\n'
expect "emulator: an ANR in the app fails" 1 "ANR in com.twelve.daylight.ink"

# ui-expectations.sh (VP Mac UI, Docs to UI check): a fixture with every chain form and every skip rule gives exactly
# the expected JSON (deterministic, byte for byte), and the real owner docs give at least 40 strings including the
# ones the UI suite must find.
mkdir -p "$tmpdir/uix"
cat > "$tmpdir/uix/FIXTURE.md" <<'MD'
Open menu bar > "Diagnostics..." and Menu bar > "Ink source" > "Web whiteboard" / "Mirror the tablet".
Then menu bar > "Settings..." > Mirror > "Transport" > "Wi-Fi (Daylight Ink screen stream)".
Settings > Mirror > "Change threshold: N canvas cells" and Settings > Overlay > switch on "Enable overlay mode".
Skip System Settings > General > Login Items, Daylight Ink > Settings > "This tablet", Settings > Video > Camera.
Settings > Hotkeys and Settings > General > "Layout when engaging" > "Overlay". Menu bar > "Diagnostics..." again.
The first run shows "Welcome to Daylight" ("Set up once."). Its rows, in order: Location, Finish. Not "Welcome to Daylight Ink".
Finish the Welcome window: tick "Launch Daylight at login", click "Done". Then more.
- Location: "In Applications." On an unsigned build: "Unsigned sentence." with a button "Open the preview window".
- Finish: "Open Zoom.", the toggle "Launch Daylight at login". Closing the window with "Other" hides it.
MD
cat > "$tmpdir/uix/expected.json" <<'JSON'
[
 {
  "text": "Diagnostics...",
  "kind": "menu",
  "source": "FIXTURE.md:1"
 },
 {
  "text": "Ink source",
  "kind": "menu",
  "source": "FIXTURE.md:1"
 },
 {
  "text": "Web whiteboard",
  "kind": "submenu",
  "parent": "Ink source",
  "source": "FIXTURE.md:1"
 },
 {
  "text": "Mirror the tablet",
  "kind": "submenu",
  "parent": "Ink source",
  "source": "FIXTURE.md:1"
 },
 {
  "text": "Settings...",
  "kind": "menu",
  "source": "FIXTURE.md:2"
 },
 {
  "text": "Mirror",
  "kind": "tab",
  "source": "FIXTURE.md:2"
 },
 {
  "text": "Transport",
  "kind": "setting",
  "tab": "Mirror",
  "source": "FIXTURE.md:2"
 },
 {
  "text": "Wi-Fi (Daylight Ink screen stream)",
  "kind": "option",
  "tab": "Mirror",
  "parent": "Transport",
  "source": "FIXTURE.md:2"
 },
 {
  "text": "Change threshold:",
  "kind": "setting",
  "tab": "Mirror",
  "source": "FIXTURE.md:3"
 },
 {
  "text": "Overlay",
  "kind": "tab",
  "source": "FIXTURE.md:3"
 },
 {
  "text": "Enable overlay mode",
  "kind": "setting",
  "tab": "Overlay",
  "source": "FIXTURE.md:3"
 },
 {
  "text": "Hotkeys",
  "kind": "tab",
  "source": "FIXTURE.md:5"
 },
 {
  "text": "General",
  "kind": "tab",
  "source": "FIXTURE.md:5"
 },
 {
  "text": "Layout when engaging",
  "kind": "setting",
  "tab": "General",
  "source": "FIXTURE.md:5"
 },
 {
  "text": "Overlay",
  "kind": "option",
  "tab": "General",
  "parent": "Layout when engaging",
  "source": "FIXTURE.md:5"
 },
 {
  "text": "Welcome to Daylight",
  "kind": "welcome",
  "source": "FIXTURE.md:6"
 },
 {
  "text": "Set up once.",
  "kind": "welcome",
  "source": "FIXTURE.md:6"
 },
 {
  "text": "Location",
  "kind": "welcome",
  "source": "FIXTURE.md:6"
 },
 {
  "text": "Finish",
  "kind": "welcome",
  "source": "FIXTURE.md:6"
 },
 {
  "text": "Launch Daylight at login",
  "kind": "welcome",
  "source": "FIXTURE.md:7"
 },
 {
  "text": "Done",
  "kind": "welcome",
  "source": "FIXTURE.md:7"
 },
 {
  "text": "Unsigned sentence.",
  "kind": "welcome",
  "source": "FIXTURE.md:8"
 },
 {
  "text": "Open the preview window",
  "kind": "welcome",
  "source": "FIXTURE.md:8"
 },
 {
  "text": "Open Zoom.",
  "kind": "welcome",
  "source": "FIXTURE.md:9"
 }
]
JSON
set +e; out="$(bash scripts/ui-expectations.sh --out "$tmpdir/uix/got.json" "$tmpdir/uix/FIXTURE.md" 2>&1)"; rc=$?; set -e
expect "ui-expectations: the fixture runs and prints a summary" 0 "^ui-expectations: 24 strings from 1 docs \\(menu 3, submenu 2, tab 4, setting 4, option 2, welcome 9\\)"
if [[ -f "$tmpdir/uix/got.json" ]] && diff -u "$tmpdir/uix/expected.json" "$tmpdir/uix/got.json" > "$tmpdir/uix/diff.txt"; then
  echo "ok    ui-expectations: the fixture gives exactly the expected JSON"; passes=$((passes + 1))
else
  echo "FAIL  ui-expectations: fixture JSON differs:"; sed 's/^/        /' "$tmpdir/uix/diff.txt" 2>/dev/null || true; fails=$((fails + 1))
fi
set +e; out="$(bash scripts/ui-expectations.sh --out "$tmpdir/uix/docs.json" 2>&1)"; rc=$?; set -e
expect "ui-expectations: the owner docs run" 0 "^ui-expectations: [0-9]+ strings from 3 docs"
bash scripts/ui-expectations.sh --out "$tmpdir/uix/docs2.json" >/dev/null 2>&1 || true
cmp -s "$tmpdir/uix/docs.json" "$tmpdir/uix/docs2.json" && { echo "ok    ui-expectations: two runs give identical bytes"; passes=$((passes + 1)); } || { echo "FAIL  ui-expectations: output is not deterministic"; fails=$((fails + 1)); }
out="$(python3 - "$tmpdir/uix/docs.json" <<'PY' 2>&1 || true
import json, sys
items = json.load(open(sys.argv[1]))
have = {(i["kind"], i["text"], i.get("tab", "")) for i in items}
need = [("setting", "Transport", "Mirror"), ("setting", "adb source", "Mirror"), ("menu", "Export diagnostics...", ""),
        ("menu", "Setup again", ""), ("menu", "Settings...", ""), ("submenu", "Mirror the tablet", ""),
        ("option", "Wi-Fi (Daylight Ink screen stream)", "Mirror"), ("welcome", "Welcome to Daylight", ""),
        ("menu", "Share the whiteboard", ""), ("submenu", "Show share window", ""), ("tab", "Share", ""),
        ("setting", "Hide the share window's title bar", "Share")]
missing = [n for n in need if n not in have]
bad = [i for i in items if i.get("tab") and i["tab"] not in
       ["General", "Hotkeys", "Network", "Mirror", "Overlay", "Share", "Saving", "Advanced", "Diagnostics"]]
leaks = [i for i in items if i["text"] in ("This tablet", "Send facts to Mac", "Video", "Developer options")]
sources = [i for i in items if not i["source"].startswith("docs/")]
print("count=%d missing=%s badtabs=%d leaks=%d badsources=%d" % (len(items), missing, len(bad), len(leaks), len(sources)))
PY
)"; rc=0
expect "ui-expectations: at least 40 strings, the known items present, Mac tabs only, no tablet strings" 0 "^count=([4-9][0-9]|[1-9][0-9]{2,}) missing=\\[\\] badtabs=0 leaks=0 badsources=0$"

# crash-summary.sh (Review 4 CI-1): the crash lines of the test log and a summary of each crash report newer than the
# start stamp; an older report is not read.
mkdir -p "$tmpdir/crash/reports"
printf 'Test Case started\nRestarting after unexpected exit, crash, or test timeout\nFatal error: Unexpectedly found nil\n' > "$tmpdir/crash/test.log"
printf '{"app_name":"Daylight","bug_type":"309"}\n{"procName":"Daylight","old":true}\n' > "$tmpdir/crash/reports/Daylight-old.ips"
touch -d '2000-01-01 00:00:00' "$tmpdir/crash/reports/Daylight-old.ips"
touch -d '2000-01-02 00:00:00' "$tmpdir/crash/start.stamp"
cat > "$tmpdir/crash/reports/Daylight-2026-10-04-072600.ips" <<'IPS'
{"app_name":"Daylight","bug_type":"309"}
{"procName":"Daylight","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x0"},"termination":{"namespace":"SIGNAL","indicator":"Segmentation fault: 11"},"faultingThread":1,"threads":[{"frames":[]},{"queue":"com.twelve.daylight.render","frames":[{"imageOffset":4096,"symbol":"FramePipeline.renderFrame(now:out:)","symbolLocation":120,"imageIndex":0},{"imageOffset":8192,"imageIndex":1}]}],"usedImages":[{"name":"Daylight"},{"name":"libdispatch.dylib"}]}
IPS
set +e; out="$(bash scripts/crash-summary.sh "$tmpdir/crash/test.log" "$tmpdir/crash/start.stamp" "$tmpdir/crash/reports" "$tmpdir/crash/copied" 2>&1)"; rc=$?; set -e
expect "crash-summary: the test log's crash lines" 0 "Fatal error: Unexpectedly found nil"
expect "crash-summary: the exception and termination of a new report" 0 "exception: EXC_BAD_ACCESS SIGSEGV KERN_INVALID_ADDRESS at 0x0"
expect "crash-summary: the crashed thread's frames with image names" 0 " 0 Daylight +FramePipeline.renderFrame\\(now:out:\\) \\+120"
expect "crash-summary: one report from this run (the older one is skipped)" 0 "crash-summary: 1 crash report\\(s\\) from this run"
expect_no "crash-summary: the older report is not read" "Daylight-old.ips"
out="$(ls "$tmpdir/crash/copied" 2>&1)"; rc=0
expect "crash-summary: the new report is copied for the artifact, the old one is not" 0 "^Daylight-2026-10-04-072600.ips$"

echo "scripts-check: $passes passed, $fails failed"
(( fails == 0 ))
