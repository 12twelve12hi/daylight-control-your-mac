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
# Every CI APK upgrades the previous sideload: versionCode is the run number (default 1 locally), versionName the
# VERSION file (E handoff request 1; app/build.gradle.kts reads both properties with defaults 1 and 0.1.0).
version_name="$(tr -d '[:space:]' < ../VERSION)"
./gradlew --no-daemon --stacktrace \
  -PdaylightVersionCode="${GITHUB_RUN_NUMBER:-1}" -PdaylightVersionName="$version_name" \
  :app:testDebugUnitTest :app:assembleDebug
ls -la app/build/outputs/apk/debug/
