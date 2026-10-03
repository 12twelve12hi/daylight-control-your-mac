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
./gradlew --no-daemon --stacktrace :app:testDebugUnitTest :app:assembleDebug
ls -la app/build/outputs/apk/debug/
