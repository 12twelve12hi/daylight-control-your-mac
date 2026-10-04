#!/usr/bin/env bash
# Finish a notarization that outran the mac job (docs/SIGNING.md, "A slow notarization"). Run by the notary workflow
# (.github/workflows/notary.yml) on a macOS runner with the three ASC_* secrets and two dispatch inputs:
#   NOTARY_SUBMISSION_ID  the id printed by mac-release ("notarization submission <id>", release-logs/notary-submission-id.txt)
#   NOTARY_SOURCE_RUN_ID  the run whose Daylight-dmg-pending artifact holds the signed DMG that was submitted (optional:
#                         without it the status and the notary log are reported and nothing is stapled)
# Steps: wait for Apple (DAYLIGHT_NOTARY_WAIT, default 80m), fetch the notary log, download the pending DMG with gh,
# check it is the submitted file (notarytool info reports the sha256 of the submission), staple it, assess it with
# spctl and leave it at build/Daylight.dmg for the Daylight-dmg artifact. Everything written goes to build/release-logs.
# Gate first (tested by scripts/scripts-check.sh on Linux): missing secrets or inputs exit 1 naming them;
# DAYLIGHT_RELEASE_CHECK_ONLY=1 stops after the gate.
set -euo pipefail
cd "$(dirname "$0")/.."

missing=""
for v in ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_PRIVATE_KEY_BASE64 NOTARY_SUBMISSION_ID; do
  if [[ -z "${!v:-}" ]]; then missing="$missing $v"; fi
done
if [[ -n "$missing" ]]; then
  echo "notary-resume: ERROR: missing or empty:$missing (the three ASC_* secrets and the submission_id input)" >&2
  exit 1
fi
if ! [[ "$NOTARY_SUBMISSION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  echo "notary-resume: ERROR: submission_id '$NOTARY_SUBMISSION_ID' is not a UUID (copy it from the mac job's 'notarization submission' notice or release-logs/notary-submission-id.txt)" >&2
  exit 1
fi
if [[ -n "${NOTARY_SOURCE_RUN_ID:-}" ]] && ! [[ "$NOTARY_SOURCE_RUN_ID" =~ ^[0-9]+$ ]]; then
  echo "notary-resume: ERROR: source_run_id '$NOTARY_SOURCE_RUN_ID' is not a run id (the number in the run's URL)" >&2
  exit 1
fi
echo "notary-resume: submission $NOTARY_SUBMISSION_ID, source run '${NOTARY_SOURCE_RUN_ID:-none}'"
if [[ "${DAYLIGHT_RELEASE_CHECK_ONLY:-}" == "1" ]]; then echo "notary-resume: check-only mode, stopping before notarytool"; exit 0; fi
command -v xcrun >/dev/null 2>&1 || { echo "notary-resume: xcrun not found (macOS only)" >&2; exit 2; }

mkdir -p build/release-logs
logs="build/release-logs"
if [[ -n "${RUNNER_TEMP:-}" ]]; then tmp="$RUNNER_TEMP"; else tmp="$(mktemp -d)"; fi
cleanup() { local rc=$?; rm -f "$tmp/AuthKey.p8"; exit "$rc"; }
trap cleanup EXIT
printf '%s' "$ASC_API_PRIVATE_KEY_BASE64" | base64 --decode > "$tmp/AuthKey.p8"
id="$NOTARY_SUBMISSION_ID"
notary_args=(--key "$tmp/AuthKey.p8" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" --output-format json)
json_field() { # $1 key, $2 file -> the value, or nothing (plutil prints its errors on stdout, so check the exit code)
  local v
  if [[ -s "$2" ]] && v="$(plutil -extract "$1" raw -o - "$2" 2>/dev/null)"; then printf '%s' "$v"; fi
}

# ---- 1. Wait for Apple ---------------------------------------------------------------------------------------
wait_for="${DAYLIGHT_NOTARY_WAIT:-80m}"
echo "notary-resume: notarytool wait $id --timeout $wait_for"
set +e
xcrun notarytool wait "$id" --timeout "$wait_for" "${notary_args[@]}" > "$logs/notarytool-wait.json" 2> "$logs/notarytool-wait.err"
wrc=$?
set -e
echo "notary-resume: notarytool wait exit $wrc"; cat "$logs/notarytool-wait.json"; echo; cat "$logs/notarytool-wait.err"
set +e
xcrun notarytool info "$id" "${notary_args[@]}" > "$logs/notarytool-info.json" 2> "$logs/notarytool-info.err"
irc=$?
set -e
echo "notary-resume: notarytool info exit $irc"; cat "$logs/notarytool-info.json"; echo; cat "$logs/notarytool-info.err"
status="$(json_field status "$logs/notarytool-info.json")"
[[ -n "$status" ]] || status="$(json_field status "$logs/notarytool-wait.json")"
echo "notary-resume: status '${status:-unknown}' for $id"
if (( irc != 0 )) && [[ -z "$status" ]]; then
  echo "notary-resume: ERROR: notarytool could not read the submission (exit $irc); a 401 means the ASC_* secrets are wrong, a 404 means this id belongs to another team or does not exist" >&2
  exit 1
fi
if [[ "$status" == "Accepted" || "$status" == "Invalid" || "$status" == "Rejected" ]]; then
  xcrun notarytool log "$id" --key "$tmp/AuthKey.p8" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" "$logs/notarization-log.json" || echo "notary-resume: notarytool log failed for $id"
  [[ -f "$logs/notarization-log.json" ]] && cat "$logs/notarization-log.json"
fi
case "$status" in
  Accepted) ;;
  Invalid|Rejected)
    echo "notary-resume: Apple rejected $id (status '$status'); notarization-log.json in the release-logs artifact lists the issues" >&2
    exit 1 ;;
  *)
    echo "::warning::notary-resume: $id is still '${status:-unknown}' after $wait_for; run this workflow again later with the same two inputs"
    echo "notary-resume: still pending" >&2
    exit 1 ;;
esac
echo "::notice::notary-resume: $id Accepted"

# ---- 2. Staple the DMG that was submitted ----------------------------------------------------------------------
if [[ -z "${NOTARY_SOURCE_RUN_ID:-}" ]]; then
  echo "notary-resume: no source_run_id, nothing to staple; the DMG of the original run (Daylight-dmg-pending) now opens on an online Mac, re-run with source_run_id for a stapled Daylight-dmg"
  exit 0
fi
command -v gh >/dev/null 2>&1 || { echo "notary-resume: gh not found on this runner" >&2; exit 2; }
rm -rf build/pending; mkdir -p build/pending
gh run download "$NOTARY_SOURCE_RUN_ID" -n Daylight-dmg-pending -D build/pending ${GITHUB_REPOSITORY:+-R "$GITHUB_REPOSITORY"}
dmg="$(find build/pending -name '*.dmg' | head -1)"
[[ -n "$dmg" ]] || { echo "notary-resume: the Daylight-dmg-pending artifact of run $NOTARY_SOURCE_RUN_ID holds no .dmg (expired after 90 days, or that run was not a notarize run)" >&2; exit 1; }
cp "$dmg" build/Daylight.dmg
# notarytool info reports the sha256 of what Apple received; the DMG must be that file or stapler refuses (65) anyway.
want="$(json_field sha256 "$logs/notarytool-info.json" | tr 'A-F' 'a-f')"
have="$(shasum -a 256 build/Daylight.dmg | awk '{print $1}')"
if [[ -n "$want" && "$want" != "$have" ]]; then
  echo "notary-resume: ERROR: the downloaded DMG ($have) is not the submitted file ($want); the source_run_id names another run" >&2
  exit 1
fi
echo "notary-resume: sha256 $have matches the submission"
xcrun stapler staple build/Daylight.dmg
xcrun stapler validate build/Daylight.dmg
spctl -vvv --assess --type open --context context:primary-signature build/Daylight.dmg 2>&1 | tee "$logs/spctl-dmg.txt" || true
printf '%s\n' "$id" > "$logs/stapled.ok"
ls -la build/Daylight.dmg
echo "notary-resume: Daylight.dmg stapled; the Daylight-dmg artifact of this run is the one to install"
