# Twelve Daylight — Android kiosk wrapper

A thin, optional Android app for the Daylight DC-1 that opens the Twelve
Daylight PWA (served by your Mac at `http://<mac-ip>:7712/?token=…`) in a
full-screen WebView. It adds nothing of its own beyond a one-field setup
screen. The web app is the product; this is polish.

**The supported path is the PWA.** Open the pairing link in Chrome on the DC-1
and use *Add to Home screen*; it opens full-screen and needs no build tools.
Use this wrapper only if you want an icon that can never be navigated out of,
or want to make the DC-1 a single-purpose device.

## What it does

- Loads the saved server URL in a hardware-accelerated WebView (JavaScript,
  DOM storage, media autoplay, cleartext http for the LAN).
- Immersive full screen: status and navigation bars are hidden; swipe from an
  edge to peek at them. The screen stays on while the app is in front.
- Stays inside the app: Back goes back within the page or does nothing; links
  to any other origin are dropped.
- Voice scaffold: when the page asks for the microphone, the app requests the
  `RECORD_AUDIO` runtime permission (once) and grants it to the paired origin
  only.
- Setup screen: shown on first launch, or **hold a finger on the top-left
  corner for 3 seconds** (stylus touches are ignored there so writing never
  opens it). Paste one of the links printed on the Mac's pairing page
  (`http://127.0.0.1:7712/pair` on the Mac). No camera scanner on purpose.
- If the Mac is unreachable it shows a plain "Cannot reach your Mac" page that
  retries every five seconds.

## Build

Requirements: JDK 17 and Android SDK platform 34 (Android Studio installs
both). The Gradle wrapper jar and `gradlew` scripts are deliberately not
committed; `gradle/wrapper/gradle-wrapper.properties` is, so Android Studio
picks Gradle 8.7 by itself.

Android Studio (Koala 2024.1 or newer):

1. *File → Open…* and choose `apps/android` (not the repository root).
2. Let it sync and accept any SDK or licence prompts.
3. *Build → Build App Bundle(s) / APK(s) → Build APK(s)*. The APK lands in
   `app/build/outputs/apk/debug/app-debug.apk`.

Command line (a local Gradle 8.7+ is needed once, to generate the wrapper):

```sh
cd apps/android
gradle wrapper --gradle-version 8.7
./gradlew assembleDebug
```

If Gradle cannot find the SDK, set `ANDROID_HOME` or create `local.properties`
with `sdk.dir=/path/to/Android/sdk` (it is git-ignored).

## Install on the DC-1

1. On the DC-1: *Settings → About tablet*, tap *Build number* seven times,
   then *Settings → System → Developer options → USB debugging*.
2. Connect over USB (or enable *Wireless debugging* and `adb pair` /
   `adb connect <dc1-ip>:<port>`), then:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

3. Open **Twelve**, paste the pairing link, tap *Connect*.

## Optional: make it the launcher (Home app)

By default Twelve is an ordinary app. To let Android offer it as the Home app:

1. In `app/src/main/AndroidManifest.xml`, uncomment the second
   `<intent-filter>` (the one with `android.intent.category.HOME`).
2. Rebuild and reinstall. Press Home, pick *Twelve*, choose *Always*.
3. To undo: *Settings → Apps → Default apps → Home app* and pick the stock
   launcher, or reinstall with the filter commented out again.

A lighter alternative is Android's app pinning (*Settings → Security → App
pinning*), which keeps one app in front until you unpin it.

## Notes and limits

- The DC-1 runs Android 13 (API 33); the app targets 34 and requires 30+.
- The server is plain http on your LAN or Tailscale. Chromium treats non-https
  origins other than localhost as insecure, so `getUserMedia` (the voice
  scaffold's microphone) may be unavailable in the WebView exactly as it is in
  Chrome. The permission plumbing is ready for when the server is reached over
  https (for example via Tailscale Serve).
- Orientation is locked to landscape, either direction. Change
  `android:screenOrientation` in the manifest if you want portrait as well.
- The app icon is Android's stock placeholder; drop real launcher icons into
  `res/mipmap-*` and point `android:icon` at them when there is a logo.
- Debug builds enable WebView remote debugging (`chrome://inspect` on a
  connected computer).
