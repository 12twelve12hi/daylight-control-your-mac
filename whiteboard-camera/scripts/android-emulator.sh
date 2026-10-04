#!/usr/bin/env bash
# make android-emulator-build / android-emulator: the Daylight Ink instrumented tests on an emulated Android 13 tablet
# shaped like the Daylight DC-1 (1200x1600 portrait, 200 dpi). The tests run with `am instrument`, not Gradle's
# connectedDebugAndroidTest, because Gradle uninstalls the app afterwards and the screenshots go with it.
# Phases (first argument):
#   build                   ./gradlew :app:assembleDebug :app:assembleDebugAndroidTest (CI runs it before the emulator boots)
#   avd-config              the emulator action's pre-emulator-launch-script: hw.keyboard=no in the AVD's config.ini
#   run (default)           needs a booted emulator on adb ($ANDROID_SERIAL picks one); DC-1 screen override, installs both
#                           APKs without -g, runs the instrumentation, then the process-death check; always pulls the
#                           screenshots, logcat and ANR traces into build/android-emulator/ (docs/SCREENSHOTS.md)
#   check-instrument FILE   the pass/fail rule for raw `am instrument -r` output (scripts-check tests it)
#   check-logcat FILE       the crash and ANR rule for a logcat dump (scripts-check tests it)
set -euo pipefail
phase="${1:-run}"
file="${2:-}"
[[ -n "$file" && "$file" != /* ]] && file="$PWD/$file"   # relative to the caller, before the cd
cd "$(dirname "$0")/../android"
[[ "${CI:-}" == "true" ]] && set -x

APP_ID=com.twelve.daylight.ink
APP_RE='com\.twelve\.daylight\.ink'
TEST_ID=$APP_ID.test
RUNNER=androidx.test.runner.AndroidJUnitRunner
MAIN_ACTIVITY=$APP_ID/.ui.MainActivity
# The contract with the tests: they write PNGs to targetContext.getExternalFilesDir("screenshots").
DEVICE_SCREENSHOTS=/sdcard/Android/data/$APP_ID/files/screenshots
DC1_SIZE=1200x1600
DC1_DENSITY=200
OUT="$(cd .. && pwd)/build/android-emulator"

reasons=()
fail() { reasons+=("$1"); echo "::error::android-emulator: $1"; }

# Prints one line per broken rule and returns 1 when any rule is broken.
check_instrument() {
  local f="$1" bad=0
  if grep -q 'INSTRUMENTATION_FAILED' "$f"; then echo "instrumentation: INSTRUMENTATION_FAILED (test APK, runner or target package wrong)"; bad=1; fi
  if grep -q 'Process crashed' "$f"; then echo "instrumentation: Process crashed"; bad=1; fi
  if grep -q 'FAILURES!!!' "$f"; then echo "instrumentation: FAILURES!!! ($(grep -m1 -E '^Tests run:' "$f" || true))"; bad=1; fi
  if ! grep -qE 'OK \([0-9]+ tests?\)' "$f"; then
    echo "instrumentation: no 'OK (' line"; bad=1
  elif grep -qE 'OK \(0 tests\)' "$f"; then
    echo "instrumentation: OK (0 tests), no test ran"; bad=1
  fi
  return "$bad"
}

indent() { local l; while IFS= read -r l; do echo "  $l"; done; }

check_logcat() {
  local f="$1" bad=0 hits
  hits="$(grep -E "Process: ${APP_RE}([,:]|$)" "$f" || true)"
  if [[ -n "$hits" ]]; then echo "logcat: FATAL EXCEPTION in $APP_ID:"; indent <<<"$hits"; bad=1; fi
  hits="$(grep -E "ANR in ${APP_RE}([ :(]|$)" "$f" || true)"
  if [[ -n "$hits" ]]; then echo "logcat: ANR in $APP_ID:"; indent <<<"$hits"; bad=1; fi
  return "$bad"
}

# Status codes of `am instrument -r`: 1 start, 0 pass, -2 failure, -1 error, -3 ignored, -4 assumption failure.
summarize_instrument() {
  awk '
    /^INSTRUMENTATION_STATUS: class=/ { cls = substr($0, index($0, "=") + 1) }
    /^INSTRUMENTATION_STATUS: test=/ { tst = substr($0, index($0, "=") + 1) }
    /^INSTRUMENTATION_STATUS_CODE: / {
      c = $2
      if (c == "1") started++
      else if (c == "0") passed++
      else if (c == "-2") { failed++; bad[++nb] = "FAILED " cls "#" tst }
      else if (c == "-1") { errored++; bad[++nb] = "ERROR  " cls "#" tst }
      else if (c == "-3") ignored++
      else if (c == "-4") assumed++
    }
    END {
      printf "tests: %d started, %d passed, %d failed, %d errors, %d ignored, %d assumption failures\n", started, passed, failed, errored, ignored, assumed
      for (i = 1; i <= nb; i++) print "  " bad[i]
    }' "$1"
}

# The app's lines from a threadtime dump: every line of a process the log shows starting for the package (main and
# :sub processes), plus DaylightInk.* tags, lines naming the package (ActivityManager, PackageManager), AndroidRuntime
# (crash stacks) and TestRunner. A pid filter alone cannot work once the process has exited.
filter_app_logcat() {
  local f="$1" pids
  pids="$(grep -oE "Start proc [0-9]+:${APP_RE}[^ /]*" "$f" | sed -E 's/^Start proc ([0-9]+):.*/\1/' | sort -u | tr '\n' ' ' || true)"
  PIDS="$pids" RE="DaylightInk\\.|${APP_RE}| AndroidRuntime *:| TestRunner *:" awk '
    BEGIN { n = split(ENVIRON["PIDS"], p, " "); for (i = 1; i <= n; i++) want[p[i]] = 1 }
    ($3 in want) || $0 ~ ENVIRON["RE"]' "$f"
}

app_pid() { adb shell pidof "$APP_ID" 2>/dev/null | tr -d '\r' || true; }

avd_config() {
  local name="${AVD_NAME:-test}" cfg="" d
  for d in "${ANDROID_AVD_HOME:-}" "$HOME/.android/avd" "$HOME/.config/.android/avd"; do
    if [[ -n "$d" && -f "$d/$name.avd/config.ini" ]]; then cfg="$d/$name.avd/config.ini"; break; fi
  done
  if [[ -z "$cfg" ]]; then
    echo "::warning::android-emulator: no config.ini for AVD '$name'; hw.keyboard stays at the device profile's value"
    return 0
  fi
  # Delete then append, so a second run (cache hit) leaves the file byte-identical and the cached snapshot still loads.
  sed -i -e '/^hw\.keyboard[[:space:]]*=/d' "$cfg"
  echo 'hw.keyboard=no' >> "$cfg"
  echo "android-emulator: $cfg"
  cat "$cfg"
}

build() {
  if [[ -z "${ANDROID_HOME:-}${ANDROID_SDK_ROOT:-}" && ! -f local.properties ]]; then
    echo "android-emulator: no ANDROID_HOME/ANDROID_SDK_ROOT and no local.properties; the Android Gradle plugin needs an SDK." >&2
    exit 2
  fi
  ./gradlew --no-daemon --stacktrace :app:assembleDebug :app:assembleDebugAndroidTest
  ls -la app/build/outputs/apk/debug/ app/build/outputs/apk/androidTest/debug/
}

wait_for_boot() {
  timeout 300 adb wait-for-device
  local booted=""
  for _ in $(seq 1 150); do
    booted="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    [[ "$booted" == "1" ]] && break
    sleep 2
  done
  if [[ "$booted" != "1" ]]; then echo "android-emulator: the device did not finish booting in 300 s" >&2; exit 1; fi
  for _ in $(seq 1 30); do adb shell pm path android >/dev/null 2>&1 && return 0; sleep 2; done
  echo "android-emulator: the package manager did not come up" >&2; exit 1
}

collected=0
collect() { # idempotent; runs at the end and from the EXIT trap, never fails
  [[ "$collected" == 1 ]] && return 0
  collected=1
  set +e
  mkdir -p "$OUT/screenshots" "$OUT/anr"
  adb pull "$DEVICE_SCREENSHOTS/." "$OUT/screenshots/" || echo "android-emulator: no $DEVICE_SCREENSHOTS on the device"
  ls -la "$OUT/screenshots"
  adb logcat -d -v threadtime > "$OUT/logcat-full.txt"
  filter_app_logcat "$OUT/logcat-full.txt" > "$OUT/logcat-app.txt"
  adb shell wm size reset
  adb shell wm density reset
  # /data/anr needs root: google_apis images allow `adb root` (adbd restarts), user builds refuse; both are tolerated.
  adb root && sleep 2
  timeout 60 adb wait-for-device
  adb shell ls -l /data/anr > "$OUT/anr/ls.txt" 2>&1
  adb pull /data/anr/. "$OUT/anr/" || echo "android-emulator: /data/anr not readable (no root) or empty"
  set -e
  return 0
}

process_death_check() {
  # MAIN/LAUNCHER with -n is what a launcher tap sends: when the task still exists it comes to the front and the
  # activity is recreated from its saved state; when the system dropped the task it starts fresh.
  local launch=(adb shell am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n "$MAIN_ACTIVITY")
  local before after
  if ! "${launch[@]}"; then fail "process death: first launch failed"; return 0; fi
  sleep 3
  adb shell input keyevent KEYCODE_HOME
  sleep 2
  before="$(app_pid)"
  adb shell am kill "$APP_ID" || true
  sleep 1
  after="$(app_pid)"
  if [[ -n "$after" && "$after" == "$before" ]]; then
    # am kill spares a process the system calls unsafe to kill (a foreground service); the debug build is debuggable.
    echo "android-emulator: am kill left pid $after; killing it with run-as"
    adb shell run-as "$APP_ID" kill -9 "$after" || true
    sleep 1
    after="$(app_pid)"
  fi
  if [[ -n "$after" && "$after" == "$before" ]]; then
    fail "process death: $APP_ID still runs as pid $after after am kill and run-as kill"
    return 0
  fi
  echo "android-emulator: process death: pid '${before}' gone (now '${after}')"
  "${launch[@]}" || fail "process death: relaunch after the kill failed"
  sleep 3
  adb exec-out screencap -p > "$OUT/screenshots/90-after-process-death.png" || fail "process death: screencap failed"
  [[ -n "$(app_pid)" ]] || fail "process death: $APP_ID is not running after the relaunch (crash on restore?)"
}

run() {
  command -v adb >/dev/null || { echo "android-emulator: adb not on PATH" >&2; exit 2; }
  shopt -s nullglob
  local apks=(app/build/outputs/apk/debug/*.apk) test_apks=(app/build/outputs/apk/androidTest/debug/*.apk)
  shopt -u nullglob
  if (( ${#apks[@]} == 0 || ${#test_apks[@]} == 0 )); then
    echo "android-emulator: APKs missing; run make android-emulator-build first" >&2; exit 2
  fi
  rm -rf "$OUT"
  mkdir -p "$OUT/screenshots" "$OUT/anr"
  # shellcheck disable=SC2154  # trap_rc is assigned inside the trap string
  trap 'trap_rc=$?; collect; exit "$trap_rc"' EXIT

  wait_for_boot
  adb logcat -G 16M || true
  # The action disables animations already; repeated here so a local run behaves the same.
  adb shell settings put global window_animation_scale 0
  adb shell settings put global transition_animation_scale 0
  adb shell settings put global animator_duration_scale 0
  adb shell svc power stayon true
  adb shell input keyevent KEYCODE_WAKEUP
  adb shell wm dismiss-keyguard || true
  # DC-1 screen on a stock tablet profile (docs/SCREENSHOTS.md, "The emulated device").
  adb shell wm size "$DC1_SIZE"
  adb shell wm density "$DC1_DENSITY"
  {
    echo "release=$(adb shell getprop ro.build.version.release | tr -d '\r') sdk=$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
    echo "model=$(adb shell getprop ro.product.model | tr -d '\r') abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
    adb shell wm size | tr -d '\r'
    adb shell wm density | tr -d '\r'
  } | tee "$OUT/device.txt"

  # A clean install every run (no permission or saved Mac left over); no -g, the tests walk the permission flows.
  adb uninstall "$TEST_ID" >/dev/null 2>&1 || true
  adb uninstall "$APP_ID" >/dev/null 2>&1 || true
  adb install -r "${apks[0]}"
  adb install -r "${test_apks[0]}"
  adb logcat -c

  # A system dialog left from boot ("System UI isn't responding" on a slow emulator) takes focus from the app and
  # every UI test fails at once (run 37182692894). Close it and say which window holds focus before the tests.
  adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1 || true
  adb shell dumpsys window 2>/dev/null | tr -d '\r' | grep -E 'mCurrentFocus|mFocusedApp' | tee "$OUT/focus-before.txt" || true

  set +e
  timeout 1500 adb shell am instrument -w -r "$TEST_ID/$RUNNER" 2>&1 | tr -d '\r' | tee "$OUT/instrument.txt"
  set -e
  local line
  while IFS= read -r line; do [[ -n "$line" ]] && fail "$line"; done < <(check_instrument "$OUT/instrument.txt" || true)

  process_death_check
  collect
  local crashes
  crashes="$(check_logcat "$OUT/logcat-full.txt" || true)"
  if [[ -n "$crashes" ]]; then
    echo "$crashes"
    # The stacks go into the job log too: the artifact is not always downloadable by whoever reads the run.
    echo "::group::crash stacks (AndroidRuntime, first 200 lines)"
    grep -E ' AndroidRuntime *:' "$OUT/logcat-full.txt" | head -200 || true
    echo "::endgroup::"
    while IFS= read -r line; do [[ "$line" != "  "* ]] && fail "$line"; done <<<"$crashes"
  fi

  # Any process's ANR (a system one covers the app as much as our own) and the trace files, in the job log.
  echo "::group::ANR lines of every process, /data/anr listing"
  grep -E ' ANR in ' "$OUT/logcat-full.txt" | head -20 || true
  cat "$OUT/anr/ls.txt" 2>/dev/null || true
  echo "::endgroup::"

  {
    echo "### android-emulator"
    summarize_instrument "$OUT/instrument.txt"
    echo "screenshots: $(find "$OUT/screenshots" -name '*.png' | wc -l) PNG files"
    echo "anr traces: $(find "$OUT/anr" -type f ! -name ls.txt | wc -l) files"
    if (( ${#reasons[@]} == 0 )); then echo "result: PASS"; else echo "result: FAIL"; printf -- '- %s\n' "${reasons[@]}"; fi
  } | tee "$OUT/summary.txt"
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$OUT/summary.txt" >> "$GITHUB_STEP_SUMMARY"
  (( ${#reasons[@]} == 0 ))
}

case "$phase" in
  build) build ;;
  avd-config) avd_config ;;
  run) run ;;
  check-instrument) check_instrument "${file:?usage: check-instrument FILE}" ;;
  check-logcat) check_logcat "${file:?usage: check-logcat FILE}" ;;
  *) echo "usage: $0 [build|avd-config|run|check-instrument FILE|check-logcat FILE]" >&2; exit 2 ;;
esac
