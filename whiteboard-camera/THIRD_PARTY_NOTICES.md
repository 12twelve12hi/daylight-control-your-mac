# Third-party notices

Daylight.app bundles two binaries it did not write, both inside `Contents/Resources/Vendor/`. `make fetch-tools` (`scripts/fetch-tools.sh`) downloads them with pinned versions and sha256 checks; nothing is committed to this repository. The exact `ls -l`, `lipo -archs`, `file` and sha256 output of the copies that went into a build is in the `xcodebuild-logs` artifact of that CI run (`vendor.txt`).

| Component | Version | Source | License | Shipped as |
|---|---|---|---|---|
| scrcpy-server | 4.1 (`scrcpy-server-v4.1`, sha256 `deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae`) | https://github.com/Genymobile/scrcpy/releases/tag/v4.1 (Genymobile, Romain Vimont and contributors) | Apache License 2.0 | `Vendor/scrcpy-server-v4.1`, pushed to the tablet at `/data/local/tmp/` for mirror mode only |
| adb (Android Debug Bridge) | platform-tools 37.0.0 for macOS (`platform-tools_r37.0.0-darwin.zip`, sha256 `094a1395683c509fd4d48667da0d8b5ef4d42b2abfcd29f2e8149e2f989357c7`) | https://dl.google.com/android/repository/platform-tools_r37.0.0-darwin.zip (Google, Android Open Source Project) | Apache License 2.0 for the AOSP code; the download is governed by the Android Software Development Kit License Agreement | `Vendor/adb` plus Google's notice file as `Vendor/NOTICE-platform-tools.txt` |

The Apache License 2.0 text is at https://www.apache.org/licenses/LICENSE-2.0. The notice file shipped next to `adb` is the `platform-tools/NOTICE.txt` from the same zip (LOOSE_ENDS B2 records whether it sat at that path in the first CI run).

The question of redistributing Google's prebuilt `adb` under sections 3.4 and 3.5 of the Android SDK License is open with the owner (LOOSE_ENDS A6). scrcpy and Homebrew ship the same binary; the fallbacks if counsel objects are to build adb from AOSP in CI, to download platform-tools on first launch after the user accepts Google's terms, or to reuse an installed adb.

Nothing else in the Mac app is third-party code: `DaylightKit`, the app and the camera extension are written in this repository on Apple's SDKs. The web whiteboard's build-time dependencies (Vite, TypeScript, Playwright) and the Android app's libraries (AndroidX graphics-core, OkHttp, kotlinx-coroutines) are declared in `web/package.json` and `android/app/build.gradle.kts` with their own licenses and are not redistributed by the Mac app except as the compiled web page and the Daylight Ink APK.

The license of this repository itself is the owner's choice (LOOSE_ENDS A14); `LICENSE` is added once chosen.
