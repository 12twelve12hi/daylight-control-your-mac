# Setup: the Mac, the tablet, the network, the settings

The reference for installing and configuring Daylight Camera. `docs/OWNER-NEXT-STEPS.md` is the guided first day; this page is where you come back to look something up. `docs/SIGNING.md` covers the Apple side; `docs/COMPARE.md` helps you choose an ink source; `docs/TESTING-CHECKLIST.md` is the device run.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

---

## 1. The Mac

### 1.1 Which build

| Build | Where | Camera in calls | Good for |
|---|---|---|---|
| `Daylight-unsigned.zip` | the `Daylight-unsigned` artifact of any green run | no (row 2) | the preview window, the web page, pairing, saving, hotkeys |
| `Daylight.dmg` | the `Daylight-dmg` artifact of a `v*` tag or a notarize run | yes | daily use |

`gh run list --workflow whiteboard-camera --branch claude/daylight-whiteboard-camera-tzxfjb --limit 3` then `gh run download <run id> -n Daylight-dmg` (or `-n Daylight-unsigned`).

### 1.2 Install

1. Open the DMG, drag Daylight to Applications, eject. The signed app must live in `/Applications`: anywhere else gives row 1, "Move Daylight to your Applications folder, then open it from there." (the Welcome window offers "Reveal in Finder").
2. Open it from Applications. An unsigned build needs right-click > Open or System Settings > Privacy & Security > Open Anyway; a notarized build opens normally while the Mac is online.
3. The menu bar gets a camera icon. The first run shows "Welcome to Daylight" ("Set up once; after this Daylight Camera is just there."). Its rows, in order: Location, Camera, Install Daylight Camera, Your Daylight, Allow this Daylight?, Finish.

### 1.3 First run, row by row

- Location: "Daylight is in your Applications folder." or row 1. On an unsigned build: "This is an unsigned test build. The virtual camera cannot be installed on this Mac. Use Daylight > Preview window to see the output." with a button "Open the preview window".
- Camera: "Allow camera access so Daylight can show your webcam." with "Allow camera access"; the first launch does not ask on its own, the button does: macOS asks; the preview fills within a second of Allow. Denied once: "Camera access is off for Daylight." with "Open System Settings" (Privacy & Security > Camera). macOS 26 and 15 may also ask about the local network: Allow.
- Install Daylight Camera (signed builds): the install request goes to macOS by itself at launch, so the row reads "Installing..." and then "Approve 'Daylight Camera' in System Settings > General > Login Items & Extensions > Camera Extensions, then click Check again." > "Open System Settings" > switch it on, password > "Check again" > "Daylight Camera is installed and connected." ("Click Install to add the Daylight Camera extension." with an "Install" button shows only when no request is pending.) That path is the one macOS 26 and 15 use; on macOS 13 and 14 the path is System Settings > Privacy & Security > Security. "Restart your Mac once to finish installing Daylight Camera." means a reboot is pending.
- Your Daylight: the picker "Ink source" (Web whiteboard, Daylight Ink app, Mirror the tablet) and either "A Daylight is on USB (<serial>). Set up over USB does everything for the chosen ink source." with "Set up over USB", or "Open http://<ip>:7788 on your Daylight." with "Copy the address", or "Connect your Daylight to the same Wi-Fi, or plug it in over USB." The USB sentence appears with every ink source: while the window is open Daylight runs `adb devices -l` every 5 s (mirror mode tracks devices continuously). When "Set up over USB" stops on a step after the tablet was found, the menu shows "Set up over USB failed: <reason>" instead of row 21.
- Allow this Daylight?: "Shown when a tablet connects over Wi-Fi." then "Allowed and remembered."
- Finish: "Open Zoom and pick Daylight Camera.", the toggle "Launch Daylight at login", "Done". Closing the window with its red button only hides it until the next launch; "Done" finishes it. Menu bar > "Setup again" reopens the window any time.

### 1.4 The menu bar

Top to bottom: the version line; "Open http://<ip>:7788 on your Daylight" (one line per address, Tailscale first with "(Tailscale)", click to copy) and a muted "http://<hostname>.local:7788 may also work on Wi-Fi"; while a tablet waits, "Allow <tablet>"; "Ink source" > "Web whiteboard" / "Daylight Ink app" / "Mirror the tablet"; "Hold" > "Auto" / "Camera" / "Studio Split" / "Whiteboard Only"; "Keep whiteboard" (ticked while pinned); "Clear"; "Camera"; "Whiteboard now (Studio Split)"; "Whiteboard now (Whiteboard Only)"; "Preview window"; "Settings..."; "Diagnostics..."; "Setup again"; "Quit Daylight". The icon shows a slashed camera when no webcam is found (row 4). A red dot with "Port 7788 is in use. Daylight is using 7789." (row 16) or "Nobody has connected yet. Same Wi-Fi? Office networks often block this: use USB or Tailscale." (row 18, after 60 s without a tablet) or "Set up over USB failed: <reason>" appears when relevant.

### 1.5 Picking the camera in apps

FaceTime: Video > "Daylight Camera". Zoom: Settings > Video > Camera. Google Meet in Chrome: More options > Settings > Video > Camera (Chrome asks for camera permission once). Teams, Slack huddles and anything else that lists cameras shows "Daylight Camera" too. If Zoom shows a black picture after an update of Daylight, quit and reopen Zoom (row 15). When Daylight is not running, a call that selects Daylight Camera sees a cream card "Daylight is not running. Open Daylight from the menu bar."

---

## 2. The three ink sources on the tablet

Menu bar > "Ink source" (also Settings > General) picks one; the change applies at once and a tablet on another source shows "Ink source is <web / Daylight Ink / mirror> on the Mac" in its chip.

### 2.1 Web whiteboard (zero install)

Open Chrome on your Daylight and type the address shown in the Mac's menu bar (it starts with `http://` and ends with `:7788`). Tap "Tap to start" once: the page goes full screen and keeps the screen on when it can. The first time, click "Allow" on the Mac. The chip at the bottom tells you what the camera is doing: "Camera" (the call sees your webcam), "LIVE" (the call sees the board), "Returning in 5" (five seconds of silence left; touch the pen to keep writing), "KEEP WHITEBOARD" (pinned). Tap the chip to pin; hold it for a second to go back to the camera. Only the pen draws; fingers and palms never do.

Toolbar: "Pen", "Highlight" (amber, drawn under the ink), "Erase", the chip, "Undo", "Redo" (enabled from the Mac's state), "New page", "Clear", "?" (the card: "Add to Home screen", "Get the Daylight Ink app" with "Download Daylight Ink", the flag tip, "This tablet" facts and the `rtt` line).

Over Wi-Fi the page runs on a plain `http://` address, which Chrome treats as not secure: the screen may dim on its own and strokes get one sample per frame. Two cures, pick one: plug the tablet in once and click "Set up over USB" on the Mac with the Web whiteboard source selected (the `localhost` address it opens is secure), or open the "?" card on the page and paste its `chrome://flags/#unsafely-treat-insecure-origin-as-secure` line and the origin once into Chrome (LOOSE_ENDS A5). Add the page to the Home screen from the Chrome menu so later days are one tap.

### 2.2 Daylight Ink (the native app)

Plug the tablet in once and click "Set up over USB" on the Mac with "Daylight Ink app" selected: it installs Daylight Ink, grants the two permissions, and opens the app connected over the cable with no Allow prompt. Without a cable, open the web whiteboard, tap "Get the Daylight Ink app" in its "?" card, install it, open it: it finds the Mac by itself on the same Wi-Fi and the Mac asks you to Allow it once. The first screen ("Welcome to Daylight Ink") asks for two permissions: "Allow display over other apps" (for the floating Pin and Clear pills in mirror mode; Android 13 shows a list, pick Daylight Ink) and "Allow notifications" (the pills run as a quiet service). Both can be skipped and redone from the app's Settings ("Setup again").

Every later day: open the app. It reconnects on its own (Bonjour first, then the USB cable, then the address it remembered). Only the pen draws; fingers and palms never do. The chip at the bottom tells you what the camera is doing: "Camera", "LIVE", "Returning in 5", "KEEP WHITEBOARD". Tap it to pin, hold it for a second to go back to the camera. On an office network that blocks Bonjour, type the Mac's address (the Tailscale 100.x one if you have it) in the app's Settings under "Mac address (when Bonjour does not find it)" once.

The app's Settings: "Front buffer (lowest latency wet ink)", "Unbuffered input", "Send every pen sample at once (A/B against per-frame batching)", "Start the pills at boot", "Pills at the bottom instead of the top", the Mac address, "Forget this Mac", "Show the pills now" / "Hide the pills", "Setup again", and "This tablet" (the device facts for `docs/LOOSE_ENDS.md` section D).

The tablet needs no USB debugging for this source once the app is installed over Wi-Fi; the "Set up over USB" shortcut does need it. The APK is debug-signed in v1 (LOOSE_ENDS A8); a later release key means uninstall and reinstall.

### 2.3 Mirror mode

Mirror mode shows whatever is on your Daylight's screen inside the whiteboard slot, so you can write in the SolOS note app and the camera follows your pen. It needs USB debugging once:

1. On the tablet: Settings > About > tap Build number seven times. Back in Settings > Developer options, switch on USB debugging. If you see "Disable adb authorization timeout", switch it on too so the permission never expires (LOOSE_ENDS D6).
2. Plug the tablet into the Mac. The tablet asks "Allow USB debugging?": tick "Always allow from this computer" and tap Allow.
3. On the Mac: menu bar > "Ink source" > "Mirror the tablet". About two seconds later the preview shows your tablet screen when you touch the pen to the glass. That is the whole setup; from now on plugging in is enough.

Pin and Clear in mirror mode: the two floating pills "Pin" and "Clear" at the top of the tablet (Daylight installs its small Daylight Ink app over the cable to show them), or the pen's side button (double press keeps the whiteboard, hold for 0.7 s clears and returns to the camera), or both; choose in Settings > Mirror > "Pin and Clear in mirror mode". The top strip where the pills live is cropped out of the camera picture; adjust the crop in Settings > Mirror if needed. With "Pen side button" alone the top inset is 0 and the whole screen is mirrored.

Cable free (optional): Settings > Mirror > "Mirror over Wi-Fi after a USB session". After one USB session Daylight remembers the tablet's Wi-Fi address and reconnects over Wi-Fi when you unplug ("Try Wi-Fi mirror now" forces it). If the tablet was restarted, plug in once more ("Plug in once to re-enable Wi-Fi mirroring.", row 32). Android 11 wireless debugging pairing (Developer options > Wireless debugging > Pair device with pairing code, then `adb pair` and `adb connect` in Terminal with Daylight's own adb at `Daylight.app/Contents/Resources/Vendor/adb`) also works and is not automated in v1 (LOOSE_ENDS C1).

#### adb source

Mirror mode talks to the tablet through Google's adb. Settings > Mirror > "adb source" decides which copy Daylight runs:

| Choice | What happens | When to pick it |
|---|---|---|
| "Bundled (default)" | the adb inside Daylight (`Daylight.app/Contents/Resources/Vendor/adb`, platform-tools 37.0.0). Nothing to do. | always, unless a build ships without it |
| "Download on first use" | Daylight shows Google's Android SDK License once ("Download adb from Google?", Accept or Cancel). After Accept it downloads platform-tools 37.0.0 (about 15 MB) from dl.google.com, checks its SHA-256 before unpacking and again every time mirror mode starts, and keeps `adb` and `NOTICE.txt` in `~/Library/Application Support/Daylight/platform-tools`. After that it works offline; a new Daylight release with a newer pin downloads once more. | builds made without the bundled adb (`make fetch-tools mac-generate mac-debug DAYLIGHT_BUNDLE_ADB=0`), where it is the default and "Bundled" is hidden |
| "Use installed adb" | the first `adb` found in your PATH, then Homebrew (`/opt/homebrew/bin/adb`, `/usr/local/bin/adb`), then Android Studio (`$ANDROID_HOME/platform-tools`, `$ANDROID_SDK_ROOT/platform-tools`, `~/Library/Android/sdk/platform-tools`). It must be platform-tools 35 or newer (`adb version` prints "Version 35..." or later). | you already keep adb up to date with Homebrew or Android Studio and want one adb on the Mac |

The row under the picker shows the path and version Daylight found, or what went wrong:

- Cancel on the license: "Downloading adb needs Google's Android SDK License accepted. Choose Download again in Settings > Mirror to review it, or pick another adb source." (row 39)
- No internet: "Could not download adb: <reason>. Check the internet connection and try again, or choose Use bundled." with Try again and Use bundled (row 40)
- A damaged download: "The downloaded adb did not match its checksum and was deleted. Try again, or choose Use bundled." (row 41)
- No installed adb: "No installed adb found. Daylight looked in your PATH, in Homebrew (/opt/homebrew/bin, /usr/local/bin) and in the Android Studio SDK (ANDROID_HOME, ~/Library/Android/sdk)." (row 42); `brew install android-platform-tools` fixes it
- An old one: "The adb at <path> is version <version>. Daylight needs platform-tools 35 or newer: update it, or choose another adb source." (row 43)

When mirror mode starts with a source that fails, the menu bar shows the same sentence as a red line and Diagnostics reads `mirror.status: error: The screen mirror could not start: <the sentence>`. A new adb source applies at once: a running mirror stops and starts again with it, and after a download Daylight picks up the new adb within a few seconds. Diagnostics shows the one in use as `mirror.adb.source`, `mirror.adb.path` and `mirror.adb.version`, next to `mirror.adb.mode`. Whatever the source, Daylight never runs `adb kill-server` and shares or avoids another adb server by the same rule (row 24).

If the menu says "Another adb is running (Android Studio?). Daylight is using its own copy; a tablet already claimed by the other adb will not be visible." (row 24), quit the other adb or accept that the tablet is invisible until you do.

### 2.4 Mirror over Wi-Fi without USB debugging (Daylight Ink screen stream)

The second mirror transport: Daylight Ink captures the tablet screen itself and sends it to the Mac over the Wi-Fi connection it already uses for ink and the pills. No developer options, no cable, no adb. It needs Daylight Ink installed and allowed once (section 2.2). It is a different thing from "Mirror over Wi-Fi after a USB session" in section 2.3, which keeps the USB (adb) transport and needs USB debugging.

1. On the Mac: Settings > Mirror > "Transport" > "Wi-Fi (Daylight Ink screen stream)". Then menu bar > "Ink source" > "Mirror the tablet".
2. On the tablet: open Daylight Ink > Settings. Under "Share this screen with the Mac over Wi-Fi (no cable, no USB debugging)" tap "Share screen with your Mac".
3. Android shows its screen-capture prompt (on Android 13 it reads like "Start recording or casting with Daylight Ink?", with Cancel and Start now; the SolOS wording may differ). Tap "Start now". This is Android's rule: an app must ask before it can see the screen, and it asks again whenever sharing ends.
4. A notification "Sharing screen with your Mac" stays while sharing is ready; its "Stop" ends sharing. The Daylight Ink state line reads "Ready. The Mac starts the picture when it needs it", then "Sharing with your Mac" once the Mac asks for the picture. Within a couple of seconds the Mac's preview shows the tablet when the screen changes.
5. Open the SolOS note app and write. The board slides in when the screen changes inside the canvas crop (frame differencing); Pin and Clear are the floating pills. If the tablet is also plugged in with USB debugging on, the Mac uses the pen stream instead and the slide is as fast as the USB transport.

If the Mac asks for the picture while Daylight Ink is closed, the tablet shows a notification "Your Mac wants to mirror this screen. Tap to allow."; tap it, then "Start now". That notification needs the "Notifications" permission for Daylight Ink (the USB setup grants it; otherwise Android asks the first time). The Mac shows these failure lines: "Daylight Ink was not allowed to share the tablet screen. On the tablet open Daylight Ink > Settings > Share screen with your Mac and choose Start now." (row 34), "Your Daylight could not start its screen encoder. Restart Daylight Ink, or use Mirror over USB." (row 35), "The tablet's screen stream paused. Reconnecting..." (row 36), "Mirror over Wi-Fi starts the whiteboard when the tablet screen changes. Plug in with USB debugging for pen-exact engage." (row 37, information) and "Open Daylight Ink on your Daylight to mirror over Wi-Fi." (row 38).

Battery: the tablet encodes its screen continuously while sharing and nothing charges it; stop sharing from the notification when the call ends. Details and honest expectations in `docs/COMPARE.md` section 2.1.


---

## 3. Networking

| Situation | What works | Notes |
|---|---|---|
| Home Wi-Fi, both devices on it | everything: the web page by numeric address, Daylight Ink by Bonjour, the Allow panel once | the menu shows the Wi-Fi address; `.local` may also work |
| Office or school Wi-Fi with client isolation | USB (the cable is a network: `adb reverse` makes the Mac reachable as `localhost` on the tablet), or Tailscale | the Mac shows row 18 after 60 s without a tablet; Bonjour and `.local` do not cross isolation |
| USB cable | the web page at `http://localhost:7788` (secure context, no Allow prompt), Daylight Ink over the forwarded port, mirror mode | needs USB debugging on the tablet; "Set up over USB" does the forwarding |
| Tailscale on both devices | the web page and Daylight Ink over the 100.x address (listed first in the menu with "(Tailscale)"); the APK learns it once over USB (`--es host`) or you type it in its Settings | Bonjour does not cross the VPN; no TLS in v1 (LOOSE_ENDS C3) |

Ports: the Mac listens on 7788 and walks to 7799 when busy (Settings > Network > "Port"; "Daylight tries 7788 to 7799 when the port is busy; a restart applies a new port."). Bonjour type `_daylight-camera._tcp`, name "Daylight Camera on <hostname>" (Settings > Network > "Bonjour name"). The page and the APK talk to `ws://<mac>:<port>/ink`; nothing leaves the local network.

### 3.1 The Allow panel

The first time a tablet connects over Wi-Fi, a small floating panel appears at the top right of the Mac's screen: "Allow '<tablet>' to draw on Daylight Camera? It connected from <ip>." with "Allow" and "Not now". It never steals focus from Zoom. It disappears after 60 s; the menu bar then shows "Allow <tablet>" so you can still answer; the tablet waits ("Look at your Mac"). "Not now" denies this connection; the next dial asks again. Allowed tablets are remembered forever in `~/Library/Application Support/Daylight/clients.json` and listed under Settings > Network > "Allowed tablets" with "Forget". Connections over the USB cable are trusted without asking (Settings > Network > "Trust tablets connected over USB without asking"). The pills reuse the app's identity and never prompt.

---

## 4. Settings reference (menu bar > "Settings...")

Every key of SPEC section 11, by tab, in plain words. Values outside the range are clamped.

### General

| Control | Key | Default | Plain words |
|---|---|---|---|
| "Camera" picker | `cameraUniqueID` | "System default" | which webcam feeds the presenter; "System default" follows the Mac's preferred camera; the choice is re-evaluated whenever cameras come and go, and Daylight never picks its own virtual camera |
| "Ink source" | `inkSource` | Web whiteboard | web, Daylight Ink app or mirror; same as the menu |
| "Layout when engaging" | `preferredLayout` | Studio Split | Studio Split (board left two thirds, you right third) or Whiteboard Only (board centred, no presenter) |
| "Engage on pen contact" | `autoEngage` | on | off means the pen never brings the board up by itself; hotkeys, menu and pin still do |
| "Return to camera after N s" | `idleTimeoutSeconds` | 90 (15 to 600) | silence before the board slides back; changed while the board is up, the new value applies after the next return |
| "Amber warning N s before" | `preWarningSeconds` | 5 (0 to 30) | how long the divider breathes amber and the chip counts down before the return |
| "Open the preview window at launch" | `previewOnLaunch` | off (on for unsigned builds) | the preview is what the camera shows |
| "Preview window floats above other windows" | `previewFloats` | on | |
| "Launch at login" | `launchAtLogin` | off | registered with macOS; "Approve in System Settings" appears when macOS wants a confirmation |
| (Welcome window) | `onboardingDone`, `onboardingVersion` | false, 1 | "Setup again" clears the flag |

### Hotkeys

| Control | Key | Default | Plain words |
|---|---|---|---|
| "Whiteboard Only", "Studio Split", "Keep whiteboard (Pin)", "Clear", "Camera" | `hotkeys` | Ctrl+Opt+Cmd + W, D, K, C, Esc | click a field, press the new chord (at least one modifier); "Reset to defaults"; "Pressing the active layout hotkey again returns to the camera (unpinning first)."; a chord in use shows "Already used by another app" or "Already used by <Daylight action>" |

### Network

| Control | Key | Default | Plain words |
|---|---|---|---|
| "Port" | `port` | 7788 | 7788 to 7799 are tried in order when busy; a restart applies a new port |
| "Bonjour name" | `bonjourName` | "Daylight Camera on <hostname>" | what the APK sees while searching |
| "Trust tablets connected over USB without asking" | `trustLoopback` | on | USB connections skip the Allow panel |
| "Allowed tablets" with "Forget" | `allowedClients` (`clients.json`) | empty | the remembered tablets; Forget makes the next connection ask again |

### Mirror

| Control | Key | Default | Plain words |
|---|---|---|---|
| "Pin and Clear in mirror mode" | `mirrorPinClearMode` | "Both" | "Floating pills", "Pen side button" or both |
| "Double press window N ms" | `sideButtonDoublePressMs` | 400 | two presses within this window = Pin |
| "Long press N ms" | `sideButtonLongPressMs` | 700 | holding the side button this long = Clear |
| "Swap: double press = Clear, long press = Pin" | `sideButtonSwap` | off | |
| "Pills position" | `mirrorPillsPosition` | "Top" | "Top" or "Bottom"; sent to the APK |
| "Transport" | `mirrorTransport` | "USB (adb)" | or "Wi-Fi (Daylight Ink screen stream)" (section 2.4) |
| "Stream size N px" | `mirrorStreamMaxSize` | 1600 | Wi-Fi transport: the long side of the tablet's encoded picture, 320 to 1600 |
| "Bit rate N Mbit/s" | `mirrorStreamBitRate` | 7.0 | Wi-Fi transport: 1 to 8 Mbit/s |
| "Frame rate N fps" | `mirrorStreamMaxFps` | 30 | Wi-Fi transport: 1 to 30 |
| "Key frame every N ms" | `mirrorStreamKeyIntervalMs` | 2000 | Wi-Fi transport: 500 to 10000; shorter recovers faster after a dropped frame, longer saves bandwidth |
| "Change threshold: N canvas cells" | `mirrorDiffThreshold` | 7 cells (0.20 %) | Wi-Fi transport without the USB pen stream: how many canvas cells (about 8 x 8 px each) must change during a burst of changing frames to start the slide, ceil(value x 3072): 7 cells at the default 0.20 %, and each 0.05 % step adds 1.5 cells. Raise it if scrolling or animations start the board; lower it if slow, small writing starts it late |
| "Mirror over Wi-Fi after a USB session", "Try Wi-Fi mirror now" | `mirrorOverWiFi` | off | the `adb connect <ip>:5555` interim (LOOSE_ENDS C1) |
| "Quality" | `mirrorMaxSize`, `mirrorBitRate`, `mirrorMaxFps` | "Standard (1600 px, 8 Mbit/s, 30 fps)" | or "Low bandwidth (1200 px, 4 Mbit/s, 24 fps)"; applies to the next session (replug or rotate) |
| "Crop (portrait, tablet pixels; the top strip hides the pills)" with the Top and Bottom steppers and the live crop view | `mirrorCropInsetsPortrait`, `mirrorCropInsetsLandscape` | top 96 portrait, top 72 landscape, 0 elsewhere | what part of the tablet screen fills the board slot; the top inset is 0 when the pills are off |
| (hidden) | `pillStripHeight` | 96 | told to the APK through `/api/info` so the pills sit inside the cropped strip |
| (hidden) | `mirrorDeviceSerial` | none | which tablet when several are plugged in; the first DC-1-looking one otherwise |
| "adb source" | `adbSource` | "Bundled (default)" | or "Download on first use" or "Use installed adb" (section 2.3, adb source); applies at once |
| (hidden) | `adbTermsAcceptedVersion` | none | the platform-tools version whose Android SDK License you accepted for the download |
| (hidden) | `adbServerMode`, `adbPrivatePort` | auto, 27180 | share the Mac's adb server on 5037 when its version matches, else a private port (row 24) |

### Saving

| Control | Key | Default | Plain words |
|---|---|---|---|
| "Folder:" with "Choose..." | `saveDirectory` | `~/Documents/Daylight Camera` | |
| "Save the strokes as JSON next to each PNG" | `saveStrokesJSON` | on | the vector record |
| "Autosave every N s while drawing" | `autosaveSeconds` | 60 (15 to 600) | rewrites the same files while the page changes |

"Pages are saved when the board returns to the camera, on Clear, on New page, every autosave interval while dirty, on Hold: Camera and on quit."

### Advanced

| Control | Key | Default | Plain words |
|---|---|---|---|
| "Eraser contact engages the whiteboard" | `engageOnEraser` | off | the eraser end of the pen brings the board up from the camera (LOOSE_ENDS A4) |
| "Spring stiffness N (1200 settles in a quarter second)" | `springK` | 1200 (300 to 2400) | 600 is a slower slide that takes the whole third of a second (LOOSE_ENDS F11) |
| "Stop the webcam N s after the last viewer" | `viewerIdleStopSeconds` | 60 (10 to 600) | the LED goes off this long after the last call ends; capture restarts within a second when a call starts |
| "Frame reuse (measure first)" | `frameReuse` | off | re-send the same frame when nothing changed in Whiteboard Only; measure before enabling (LOOSE_ENDS E12) |
| "Deadline idling (measure first)" | `deadlineIdle` | off | sleep the render clock until the next governor deadline; measure first |
| "Perf log (one line per second in the unified log)" | `perfLog` | off | the `perf` line of `docs/PERFORMANCE.md`, also kept in Diagnostics' last 200 lines |
| (menu "Hold", never persisted) | `holdMode` | Auto | "Camera", "Studio Split", "Whiteboard Only" force a layout and stop the idle timer; "Auto" re-arms |

Tablet-side keys. Daylight Ink (SharedPreferences): `clientId` (generated once; this is what the Mac remembers), `deviceName`, `manualHost`, `frontBuffer`, `unbufferedInput`, `sendPerEvent`, `pillsAtBoot`, `pillsPosition`, `flagHintDismissed`, `onboardingDone` and the collected facts `fact.pressureRaw`, `fact.actionButton`, `fact.frontBufferOk`. The web page (`localStorage`): `daylight.clientId`, `daylight.deviceName`, `daylight.flagHintDismissed`.

---

## 5. Hotkeys

Ctrl+Opt+Cmd+W Whiteboard Only, Ctrl+Opt+Cmd+D Studio Split, Ctrl+Opt+Cmd+K Keep whiteboard, Ctrl+Opt+Cmd+C Clear, Ctrl+Opt+Cmd+Esc Camera. Pressing the active layout hotkey again returns to the camera. They work in every ink source, in every app, without an Accessibility permission. Change them in Settings > Hotkeys.

## 6. Saving

`~/Documents/Daylight Camera/<yyyy-MM-dd>/<HH-mm-ss>/page-01.png` and `page-01.json`, then `page-02...` after New page; a session starts with the first stroke after launch or after a 10-minute gap. Mirror sessions write `mirror-<HH-mm-ss>.png` (the last decoded frame, cropped) and no JSON. The PNG is 1200x1600, paper white with the highlighter multiplied under the ink; the JSON holds every stroke as `[x, y, pressure, tMs]` points (schema `daylight-whiteboard-strokes/1`). Clearing twice saves once; a pinned board is saved by autosave and on Clear. A failed save shows "Could not save the whiteboard: <error>" in the menu (row 31) and retries on the next trigger.

## 7. Logs and Diagnostics

- Menu bar > "Diagnostics..." (also Settings > Diagnostics): build signed or not, extension state, sink status with the two direction values, capture state and viewers, first-frame camera facts and the zero-copy flag, pipeline numbers, governor state, ink source, listener and port, addresses, clients, allowed tablets, every `mirror.*` fact, the failures seen, and the last 200 log lines. "Copy diagnostics" puts the whole report on the clipboard; paste it into `docs/TESTING-CHECKLIST.md` results or a GitHub issue.
- Unified log in Terminal: `log stream --predicate 'subsystem == "com.twelve.daylight"' --level info` while Daylight runs; the categories are `app`, `capture`, `failure`, `governor`, `hotkeys`, `ink`, `latency`, `perf`, `pipeline`, `save`, `server`, `camera`, `cmio`, `installer`, `mirror`, `scrcpy`, `stylus`, `decode` and `adb`.
- Perf line: Settings > Advanced > "Perf log (one line per second in the unified log)" and read it in Diagnostics, or quit Daylight and run `/Applications/Daylight.app/Contents/MacOS/Daylight --perf-log` from Terminal (one `perf mode=... fps=... dropped=... cpu_ms=... gpu_ms=... inflight=... zerocopy=... capture=... viewers=...` line per second on stdout). `--latency-probe` adds `engage probe: STROKE_START to first moved frame <ms>` once per session. `docs/PERFORMANCE.md` explains the fields.
- Self-test: `/Applications/Daylight.app/Contents/MacOS/Daylight --self-test --perf-log` (quit the menu bar app first so the port is free) prints one line per probe and ends with `self-test: PASS`.
- Tablet, Daylight Ink: `adb logcat -s DaylightInk.facts DaylightInk.ink DaylightInk.net` with Daylight's adb (`/Applications/Daylight.app/Contents/Resources/Vendor/adb`), or the app's Settings > "This tablet". Web page: the "?" card shows the capability facts (`secure`, `wake lock`, `coalesced`, `rawupdate`, `fullscreen`, `display`, `dpr`, `viewport`, `rtt`, `mac`, the user agent); the Chrome console prints `daylight-web caps {...}` and `daylight-web first pen pointerdown ...` (read it with desktop Chrome's `chrome://inspect#devices` over the cable, or `__daylight.consoleFacts` in that console).

## 8. Uninstall

1. Settings > General > "Launch at login" off. Menu bar > "Quit Daylight".
2. Trash `/Applications/Daylight.app`. macOS removes the camera extension with the app (it may ask for a restart); `systemextensionsctl list` confirms.
3. Optional: `~/Library/Application Support/Daylight/` (`clients.json`, the adb copy), `defaults delete com.twelve.daylight`, `~/Documents/Daylight Camera/`.
4. Tablet: uninstall Daylight Ink (package `com.twelve.daylight.ink`), remove the home screen icon, switch USB debugging off if you want.

---

## 📋 ADHD-friendly setup checklist

🟢 = setup, ✍️ = draw, 🟡 = fail on purpose, 🟣 = confirm, 📋 = paste into LOOSE_ENDS

- [ ] 🟢 Daylight in `/Applications`, opened from there. You see: camera icon in the menu bar, "Welcome to Daylight". ⏱️ 2 minutes
- [ ] 🟢 "Allow camera access". You see: your face in the preview within a second. ⏱️ 30 seconds
- [ ] 🟢 Signed build only: "Open System Settings", switch on, "Check again". You see: "Daylight Camera is installed and connected." ⏱️ 3 minutes
- [ ] 🟢 Web: type the menu-bar address into Chrome on the tablet, "Tap to start", "Allow" on the Mac. You see: chip "Camera". ⏱️ 3 minutes
- [ ] 🟢 Daylight Ink: cable in, "Ink source" > "Daylight Ink app", "Set up over USB". You see: the app opens, chip "Camera". ⏱️ 3 minutes
- [ ] 🟢 Mirror: "Ink source" > "Mirror the tablet"; "Diagnostics..." shows `mirror.status: mirroring`. ⏱️ 1 minute
- [ ] 📶 Mirror without a cable (optional): Settings > Mirror > "Transport" > "Wi-Fi (Daylight Ink screen stream)"; on the tablet Daylight Ink > Settings > "Share screen with your Mac" > "Start now". You see: the notification "Sharing screen with your Mac" and, in Diagnostics, `mirror.wifi.tabletState` reading streaming. ⏱️ 3 minutes
- [ ] ✍️ In each source, write one word. You see: the slide, the ink, "LIVE". ⏱️ 3 minutes
- [ ] 🟣 Settings > Hotkeys: the five defaults listed, none marked "Already used". ⏱️ 30 seconds
- [ ] 🟣 Settings > Network > "Allowed tablets" lists your tablet. ⏱️ 30 seconds
- [ ] 🟣 Settings > Saving: the folder is where you want the pages. ⏱️ 30 seconds
- [ ] 🟢 Welcome window: "Launch Daylight at login" on, "Done". ⏱️ 30 seconds
- [ ] 🟡 Unplug the webcam. You see: slashed icon, "No camera found"; plug it back: picture returns. ⏱️ 1 minute
- [ ] 📋 "Diagnostics..." > "Copy diagnostics", paste into your notes for the testing session. ⏱️ 30 seconds
