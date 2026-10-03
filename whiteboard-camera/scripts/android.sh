#!/usr/bin/env bash
# make android: JVM unit tests (protocol golden vectors) and the debug APK.
set -euo pipefail
cd "$(dirname "$0")/../android"
[[ "${CI:-}" == "true" ]] && set -x
if [[ -z "${ANDROID_HOME:-}${ANDROID_SDK_ROOT:-}" && ! -f local.properties ]]; then
  echo "android: no ANDROID_HOME/ANDROID_SDK_ROOT and no local.properties; the Android Gradle plugin needs an SDK." >&2
  echo "android: on GitHub's ubuntu runner the SDK is preinstalled at /usr/local/lib/android/sdk." >&2
  exit 2
fi
# Every CI APK upgrades the previous sideload: versionCode is the UTC build hour (yymmddHH, default 1 locally), which
# stays monotonic when the project moves to its public repository and the run numbers start again at 1 (review round 1,
# android-10); versionName is the VERSION file (E handoff request 1; app/build.gradle.kts reads both properties with
# defaults 1 and 0.1.0). The Mac's USB path installs with `-r -d` anyway, so a downgrade there never blocks.
version_name="$(tr -d '[:space:]' < ../VERSION)"
if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then version_code="$(date -u +%y%m%d%H)"; else version_code=1; fi
echo "android: versionCode=$version_code versionName=$version_name"
./gradlew --no-daemon --stacktrace \
  -PdaylightVersionCode="$version_code" -PdaylightVersionName="$version_name" \
  :app:testDebugUnitTest :app:assembleDebug
ls -la app/build/outputs/apk/debug/
