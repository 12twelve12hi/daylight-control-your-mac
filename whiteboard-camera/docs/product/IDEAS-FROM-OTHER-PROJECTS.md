# Ideas from other projects

What 45 other projects and products do that Daylight Whiteboard Camera could take, from the research swarm run on 2026-10-04. Research agents each filled one fixed template per target (cloning public repositories for code-level findings); verification agents then re-opened every cited source, dropped what it did not support, removed ideas Daylight already has (checked by searching `SPEC.md`, `docs/` and the source tree), deduplicated and rated. Companion pages: `REUSABLE-CODE.md` (code we could adopt, with licenses) and `ANTI-PATTERNS.md` (lessons other products paid for).

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

## How to read this page

- **Evidence tags.** [verified] means a verifier opened the source (a cloned repository file, Apple or Android developer documentation, a specification, or a fetched page) and it supports the claim. [snippet] means only search-result text supports it. This environment's network policy blocked most vendor websites (Apple Support, Microsoft Learn, Zoom, Reincubate, Loom, Ecamm, Astropad and many more), so product-UX claims about closed products are often snippet level; code, specification and developer-documentation claims are verified. Treat snippet claims as leads to confirm before building.
- **Numbers.** 774 claims checked; 437 kept as verified, 126 kept as snippet, 184 dropped as unsupported, wrong, or already in Daylight (plus 27 mirror items found already built). 83 candidate ideas survived verification across the eight groups; they deduplicate into the 25 ranked below plus the 15 in "Next in line".
- **Where it lands.** Mac app, tablet app (Daylight Ink), web page (the web whiteboard), protocol (SolStream-v1, the strokes JSON), or extension (the camera extension).
- **Effort.** S is a day or two inside one component; M is up to a week or crosses components; L is a new subsystem.
- **Scope.** This page lists ideas from outside. Product priorities, frictions and the roadmap belong to the Product Thinker's pages in this folder (`FRICTIONS.md`, `ROADMAP-PROPOSAL.md`); the "friction" column here uses plain words, not their numbering.

## Top 25 ideas, ranked

Ranked by impact on the owner's first real calls over effort, with evidence strength as the tie-breaker.

| # | Idea | Source | Friction it addresses | What it needs (Mac app, tablet app, web page, protocol) | Effort | Evidence |
|---|---|---|---|---|---|---|
| 1 | **Local Network privacy as a first-class state.** One onboarding line before the first Bonjour registration; detect a denial (`kDNSServiceErr_PolicyDenied`, -65570, on the listener's service, and `localNetworkDenied` on `adb connect` for Wi-Fi mirror); a new failure row "Local Network access is off for Daylight. The tablet can still use http://<ip>:7788 or USB" with an Open System Settings button. Also settles LOOSE_ENDS C4: registering Bonjour needs the permission, accepting incoming TCP does not | Apple TN3179; Ecamm's Sequoia support load | pairing silently fails on macOS 15 and later | Mac app: onboarding step, `FailureText`, listener error handling | S | [verified](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) |
| 2 | **Ink width floor for calls and a "far end" preview.** Keep composited strokes at least about 3 px at 1080p (the 3.2 px web pen lands near 2.2 px in Studio Split and about 1.4 px after a 720p send), and let the preview window show the picture downscaled to 720p | Teams Rooms content camera (1 to 2 mm of board per pixel, best 1.5); Meet and Zoom send rates | handwriting unreadable after call compression | Mac app compositor; width mapping shared with the web page and tablet app | S | [verified](https://learn.microsoft.com/en-us/microsoftteams/rooms/content-camera) |
| 3 | **"Wrong camera" nudge.** When the pen engages and Daylight Camera has 0 viewers, the menu and the tablet chip say "No app is using Daylight Camera"; when Daylight's capture is idle while the physical webcam runs somewhere, say "A call app is using your FaceTime HD Camera directly. Pick Daylight Camera." | Krisp (the pain), OverSight (the public listener) | forgot to pick the virtual camera; the far end sees the plain webcam | Mac app: `kCMIODevicePropertyDeviceIsRunningSomewhere` listener plus the existing viewers property; tablet chip text over STATE | M | [verified](https://developer.apple.com/documentation/coremediaio/kcmiodevicepropertydeviceisrunningsomewhere) |
| 4 | **Finish the laser pointer (LOOSE_ENDS F3).** A tablet tool (Dot and Trail) and a fading trail the Mac draws into the board only, never into the saved page or the undo stack; in USB Mirror, feed the pen's hover position from `getevent` into the same path so a slow mirror still shows where you point | tldraw, Excalidraw, GoodNotes; rmview and goMarkableStream for hover | pointing at a diagram without cluttering the board; mirror lag | web page, tablet app, Mac app (`LASER_POINT` 0x0030 is already on the wire) | M | [verified](https://github.com/tldraw/tldraw/blob/main/packages/tldraw/src/lib/tools/LaserTool/LaserTool.ts), [verified](https://github.com/bordaigorl/rmview/blob/vnc/src/rmview/pentracker.py) |
| 5 | **Strokes JSON inside the saved PNG.** Write the plain, versioned strokes JSON into a PNG text chunk (keep the sidecar), and reopen a dropped PNG as strokes. `PNGExporter.write` adds no metadata today | Excalidraw; Windows "fortified GIF" (ISF) | sharing the board after the call; the sidecar gets lost | Mac app: save and import | S | [verified](https://github.com/excalidraw/excalidraw/blob/master/packages/excalidraw/data/image.ts) |
| 6 | **Call setup card at onboarding Finish.** Zoom "Enable HD" (and its plan limits on 1080p); "your own preview may look mirrored, everyone else sees the board correctly"; Meet Present > Camera > Daylight Camera on supported editions; Studio look and Studio lighting off while the board is up | Zoom, Meet, Ecamm, reStream (`--mirror` exists because call apps mirror the self view) | far-end readability; the presenter thinks the board is backwards | Mac app copy; `docs/SETUP.md` | S | [verified](https://github.com/rien/reStream/blob/main/reStream.sh), [snippet](https://support.ecamm.com/en/articles/4320083-zoom-video-quality-when-using-virtual-camera) |
| 7 | **`daylight://` URL scheme** for keep, clear, whiteboard, studiosplit, overlay, camera (CFBundleURLTypes), so Stream Deck, Shortcuts, Raycast and scripts can drive Daylight mid-call | Stream Deck deep links | control without the tablet or a hotkey chord | Mac app | S | [verified](https://github.com/elgatosf/streamdeck/blob/main/packages/plugin/src/plugin/system.ts) |
| 8 | **Low-latency encoder keys on Daylight Ink's Wi-Fi mirror.** `KEY_PRIORITY 0`, `KEY_LATENCY 1` and limited color range in `ScreenEncoder.configure`, API-guarded, retried without them if the encoder refuses | scrcpy | Wi-Fi mirror latency | tablet app | S | [verified](https://github.com/Genymobile/scrcpy/blob/master/server/src/main/java/com/genymobile/scrcpy/video/SurfaceEncoder.java) |
| 9 | **Predicted ink tail on the web page.** Draw `getPredictedEvents()` points on the wet canvas, cleared on the next event, never sent or saved | W3C Pointer Events | perceived ink latency on the tablet | web page | S | [verified](https://w3c.github.io/pointerevents/#predicted-events) |
| 10 | **Webcam stall watchdog.** With a viewer present and no camera frame for 2 s, restart the capture session, hold the last frame meanwhile, and name the cause in a new failure row (including Presenter Overlay or another app grabbing the camera) | Camo Studio 2.8.2; Apple Presenter Overlay | frozen presenter mid-call | Mac app (`WebcamCapture.swift`, `FailureText`) | S | [snippet](https://tidbits.com/watchlist/camo-studio-2-8-2/), [verified](https://developer.apple.com/documentation/avfoundation/avcapturedevice/reactioneffectgesturesenabled) |
| 11 | **Extension build handshake.** The extension publishes its CFBundleVersion; the app compares it with its own after connecting, shows a mismatch in Diagnostics and offers "Reinstall camera" | OBS (does it only for its old DAL plugin) | stale extension after an update; "Zoom shows black" | extension, Mac app | S | [verified](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm) |
| 12 | **Name the app that is watching.** Record `CMIOExtensionClient.signingID` when a stream starts and publish it through the existing custom property, so the menu says "Zoom is using Daylight Camera" | Apple CMIO, akvirtualcamera | "is my call on the right camera?"; support | extension, Mac app | M | [verified](https://developer.apple.com/documentation/coremediaio/cmioextensionclient) |
| 13 | **Keep the tablet awake on USB mirror, and restore it.** Pass `stay_awake=true cleanup=true` to the bundled scrcpy-server behind "Keep tablet awake while plugged in"; scrcpy restores the old value even if the cable is pulled (closes LOOSE_ENDS A13) | scrcpy | the tablet sleeps mid-call | Mac app (`ScrcpyLaunch.swift`) | S | [verified](https://github.com/Genymobile/scrcpy/blob/master/server/src/main/java/com/genymobile/scrcpy/CleanUp.java) |
| 14 | **Board on the clipboard.** On Clear or on a return-save, put the page PNG on the pasteboard and post one quiet "Board saved" notification with Show in Finder, so it pastes straight into the meeting chat | Loom (link copied on stop) | sharing the board during and after the call | Mac app (`SessionSaver`, `PNGExporter`) | S | [snippet](https://support.atlassian.com/loom/docs/enable-video-links-to-copy-into-your-clipboard/) |
| 15 | **Real-time decode on the Mac.** Set `kVTDecompressionPropertyKey_RealTime` on the mirror's VTDecompressionSession | scrcpy (its low-delay decoder flag) | mirror latency | Mac app (`H264Decoder.swift`) | S | [verified](https://developer.apple.com/documentation/videotoolbox/kvtdecompressionpropertykey_realtime) |
| 16 | **Firewall failure row.** When Bonjour is registered but no tablet connects, a row naming the macOS firewall with an "Open Firewall Settings" button | LocalSend | same Wi-Fi, the tablet still finds nothing | Mac app (`FailureText`) | S | [verified](https://github.com/localsend/localsend/blob/main/app/macos/Runner/Utilities.swift) |
| 17 | **Restart discovery on network change.** Android `NetworkCallback` restarts NSD and resets backoff; the Mac's `NWPathMonitor` refreshes the menu URL when Wi-Fi or the Tailscale address changes | KDE Connect | reconnect after a Wi-Fi roam or VPN toggle | tablet app, Mac app | S | [verified](https://github.com/KDE/kdeconnect-kde/blob/master/core/backends/lan/lanlinkprovider.cpp) |
| 18 | **Throughput-driven Wi-Fi mirror bitrate.** Lower `PARAMETER_KEY_VIDEO_BITRATE` live when frames grow or the send queue backs up, raise it when they shrink | goMarkableStream, Astropad | stalls and drops on office Wi-Fi | tablet app | S | [verified](https://github.com/owulveryck/goMarkableStream/blob/main/internal/stream/handler.go) |
| 19 | **"Test pen" card.** Live pressure, tilt, buttons, pointer type and cancel events on the tablet, feeding "Send facts to Mac" | Weylus | first-run doubt; collecting LOOSE_ENDS D3, D4, D9 | web page, tablet app | S | [verified](https://github.com/H-M-H/Weylus/blob/master/ts/lib.ts) |
| 20 | **Pen eraser button on the web page.** `buttons & 32` turns the contact into an eraser, as Daylight Ink already does with `TOOL_TYPE_ERASER` | W3C Pointer Events | tool switching mid-call | web page | S | [verified](https://w3c.github.io/pointerevents/#the-buttons-property) |
| 21 | **Pen outlines with perfect-freehand.** Port the MIT outline code to Swift and fill one path per stroke for the live board and the PNG, with the same parameters on the web wet canvas and shared golden fixtures; light streamline smoothing on the composited board only, raw points kept in the JSON | perfect-freehand (used by Excalidraw and tldraw) | join artifacts and jitter that compression makes worse | Mac app (`InkRasterizer.swift`, `PNGExporter.swift`), web page | M | [verified](https://github.com/steveruizok/perfect-freehand/blob/main/packages/perfect-freehand/src/getStrokeOutlinePoints.ts) |
| 22 | **Short confirmation code on both screens.** Show the same short code on the Allow panel and on the tablet chip (first derived from the client id; later from an ECDH exchange with commitment when TLS lands, LOOSE_ENDS C3 and C6). A confirmation, never a secret | KDE Connect, Quick Share (NearDrop), UKEY2 | "which tablet is this?"; a stranger's device on shared Wi-Fi | Mac app, tablet app, web page, protocol | S, then M | [verified](https://github.com/KDE/kdeconnect-kde/blob/master/core/backends/pairinghandler.cpp) |
| 23 | **Staged discovery.** After about 1 s of Bonjour silence, probe `/healthz` across the netmask-derived subnet (capped, remembered host first, 50 at a time, 500 ms timeout) | LocalSend | multicast filtered (but not isolated) Wi-Fi | tablet app (`Candidates.kt`, `Discovery.kt`) | M | [verified](https://github.com/localsend/localsend/blob/main/packages/core/src/discovery/mod.rs) |
| 24 | **Rehearse.** Show Studio Split in the preview window while the camera keeps sending the plain webcam, to check framing and readability before a call without surprising anyone | OBS Studio Mode (Preview versus Program) | first-call nerves; checking without the audience seeing | Mac app | M | [verified](https://github.com/obsproject/obs-studio/blob/master/frontend/data/locale/en-US.ini) |
| 25 | **Quiet updater (LOOSE_ENDS F9).** Sparkle 2 with EdDSA and gentle reminders: a menu item "Update Available...", never a window or a relaunch while Daylight Camera has a viewer | Rectangle with Sparkle | updates interrupting calls | Mac app, CI signing | M | [verified](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AppDelegate.swift) |

### Next in line (survived verification, ranked lower)

| Idea | Source | Lands in | Effort | Evidence |
|---|---|---|---|---|
| Wireless-debugging pairing wizard (`_adb-tls-pairing._tcp`, type 6 digits, then a connect ladder), so Wi-Fi mirror over adb survives reboots | Escrcpy | Mac app | M | [verified](https://github.com/viarotel-org/escrcpy/blob/main/desktop/electron/middleware/adb/helpers/scanner/index.js) |
| App Intents and an AppShortcutsProvider for Keep, Clear, Show whiteboard | Apple App Intents | Mac app | M | [verified](https://developer.apple.com/documentation/appintents/appshortcutsprovider) |
| A loopback control API (versioned request and event envelope) and a small MIT Stream Deck plugin with a two-state Keep key and a "Returning in N" title | OBS WebSocket v5, Stream Deck SDK | Mac app, separate plugin | M | [verified](https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md) |
| Advertise 1280x720 beside 1920x1080 in the extension and scale to the active format | akvirtualcamera, Apple WWDC22 10022 | extension | M | [verified](https://developer.apple.com/videos/play/wwdc2022/10022/) |
| Webcam framing guide in the preview (distance, head inside the right third) | Teams Rooms content camera placement | Mac app | S | [verified](https://learn.microsoft.com/en-us/microsoftteams/rooms/content-camera) |
| Read-only hints for system video effects on the presenter webcam (Reactions gestures on, Center Stage reframing under the crop) | Apple Continuity Camera | Mac app | S | [verified](https://developer.apple.com/documentation/avfoundation/avcapturedevice/reactioneffectgesturesenabled) |
| Short page-turn transition on New page instead of a hard cut | GoodNotes presentation mode | Mac app | S | [snippet](https://support.goodnotes.com/hc/en-us/articles/7353727934223-Present-Goodnotes-on-an-external-screen) |
| "Presenter on the left" toggle for Studio Split | Tella | Mac app (DaylightKit layout) | S | [snippet](https://www.tella.com/help/editing/custom-layouts) |
| Pressure curve presets (Soft, Normal, Firm) shared by all three sources | Astropad | Mac app, tablet app | S | [snippet](https://astropad.com/blog/change-apple-pencil-pressure-curve/) |
| Two-finger tap Undo as the only finger gesture | Astropad | tablet app, web page | S | [snippet](https://help.astropad.com/article/205-magic-gestures) |
| Modern NSD path on newer Android (`registerServiceInfoCallback`, all host addresses, IPv4 preferred) | Android NsdManager | tablet app | M | [verified](https://developer.android.com/reference/android/net/nsd/NsdManager) |
| Time-lapse replay export of a page from the per-point times | PencilKit, Descript | Mac app | M | [verified](https://developer.apple.com/videos/play/wwdc2020/10148/) |
| Optional delegated ink trail (`navigator.ink`), feature-detected and reported in tablet facts | WICG Ink API | web page | S | [verified](https://wicg.github.io/ink-enhancement/) |
| Ink stall metric in Diagnostics (max and p99 gap between `STROKE_CHUNK` arrivals) before any UDP work | Moonlight (motivation) | Mac app | S | [verified](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/InputStream.c) |
| "Copy details for your IT admin" on the system-extension policy failure (team id and extension bundle id) | OBS (error 10 dead end) | Mac app | S | [snippet](https://obsproject.com/forum/threads/cant-start-virtual-camera-ossystemextensionerrordomain-error-10.185847) |

Considered and deliberately left out: a UDP or WebRTC channel for live points (no measured stall yet), WebTransport and WebCodecs in the web page (both need a secure context the LAN page lacks), Quick Share export (reverse engineered and BLE dependent), a Zoom App or Meet add-on front end (per-platform, licensed, heavy; kept as options for Macs where MDM blocks the extension), zstd delta frames instead of H.264, and a second "Daylight Board" camera device (L effort, low impact). Each is argued in its target's section below or in `REUSABLE-CODE.md` section 4.

## Patterns: what the good ones share

1. **They name the cause and the fix in the message.** OBS, LocalSend, Ecamm and scrcpy's best front ends turn OS and adb errors into one sentence plus one action (a pane path, a button, a command), branched per macOS version, with the raw code kept out of the headline ([LocalSend](https://github.com/localsend/localsend/blob/main/app/macos/Runner/Utilities.swift), [OBS locale](https://github.com/obsproject/obs-studio/blob/master/frontend/data/locale/en-US.ini)). Daylight's failure matrix already works this way; the gaps are the new OS gates (Local Network privacy, firewall, MDM) and the "wrong camera" case.
2. **They show state, not just accept commands.** Stream Deck keys change state and title, OBS emits events, Ecamm outlines the live scene, Hand Mirror shows the picture in one click ([Stream Deck SDK](https://github.com/elgatosf/streamdeck/blob/main/packages/plugin/src/plugin/system.ts), [OBS WebSocket](https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md)). Daylight's STATE message already carries state, pin and time to return; exposing it off the tablet (URL scheme, then a loopback API) and naming the viewing app are cheap wins.
3. **The newest frame wins, and recovery is by key frame.** scrcpy, reStream and Weylus keep one pending frame, count drops, and ask for a sync frame after a gap instead of restarting ([scrcpy frame_buffer.h](https://github.com/Genymobile/scrcpy/blob/master/app/src/frame_buffer.h)). Daylight already does both; the remaining tricks are encoder and decoder flags and adapting the bitrate to the link.
4. **Ephemeral pointing is separate from ink.** Excalidraw, tldraw and GoodNotes all ship a laser whose trail fades in 0.5 to 1 s and never enters the document or the undo stack; reMarkable tools use pen hover the same way ([tldraw LaserTool](https://github.com/tldraw/tldraw/blob/main/packages/tldraw/src/lib/tools/LaserTool/LaserTool.ts), [rmview](https://github.com/bordaigorl/rmview/blob/vnc/src/rmview/pentracker.py)).
5. **Raw input is the source of truth; every picture is derived.** PencilKit, Wacom's Universal Ink Model and Excalidraw keep vector data and render images from it, and the best embed or attach that data to the image ([Excalidraw image.ts](https://github.com/excalidraw/excalidraw/blob/master/packages/excalidraw/data/image.ts)). Pen dynamics are shaped for display (perfect-freehand style), never in the stored points.
6. **Content is treated differently from faces.** Meet's present-from-camera, Teams' content camera and Zoom's screen-share tuning all give content sharpness and faces motion; the best state readability as a number (Teams: 1 to 2 mm of board per pixel at 1080p) ([Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/rooms/content-camera)). Daylight sends content through the face path, so ink must be made robust to video compression.
7. **Discovery is layered, cheapest first, and reacts to change.** LocalSend escalates from multicast to a subnet probe, KDE Connect restarts on network change, and trust is confirmed by a short code shown on both screens ([LocalSend discovery](https://github.com/localsend/localsend/blob/main/packages/core/src/discovery/mod.rs), [KDE pairing](https://github.com/KDE/kdeconnect-kde/blob/master/core/backends/pairinghandler.cpp)).
8. **Background apps stay quiet during the moment that matters.** Rectangle's updater uses gentle reminders; nothing opens a window on a login launch ([Rectangle AppDelegate](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AppDelegate.swift), [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern/blob/main/Sources/LaunchAtLogin/LaunchAtLogin.swift)). For a camera, "never during a call" is enforceable with Daylight's viewers property.
9. **They stay inside the apps people already use.** Around (far end had to switch) shut down; FigJam and Miro need far-end add-ons; Jamboard deleted its users' boards ([Jamboard](https://support.google.com/jamboard/answer/14084927)). A camera that works in every call app with local files is the durable shape.

## The targets

One section per target, grouped by theme. Each section keeps only verified or snippet-tagged claims; the per-target verification logs (claims checked, kept, dropped, and why) are in the swarm's working notes and are summarised in the numbers above.

### Group A. Screen mirroring and pen tablets
### scrcpy

**What it is.** scrcpy (Genymobile) mirrors and controls an Android device from a desktop over adb, USB or TCP/IP. It pushes a small Java server to the device that captures the screen (or camera, or a virtual display) and encodes it with MediaCodec, while a C client decodes and optionally records ([verified](https://github.com/Genymobile/scrcpy)). Daylight already bundles scrcpy-server 4.1 for USB mirror.

**What it does well that we lack.**
- Stay-awake only while plugged in, restored by a detached cleanup process. `--stay-awake` keeps the device on "when the device is plugged in"; the server's `stay_awake=true` only takes effect through CleanUp (when `cleanup=true`), which sets `stay_on_while_plugged_in`, remembers the old value and restores it "even on device disconnection". Daylight launches the server with `cleanup=false` (`ScrcpyLaunch.swift`); passing `stay_awake=true cleanup=true` behind a Mac app Settings toggle answers LOOSE_ENDS A13 with no new tablet code ([verified: scrcpy `server/src/main/java/com/genymobile/scrcpy/CleanUp.java`](https://github.com/Genymobile/scrcpy/blob/master/server/src/main/java/com/genymobile/scrcpy/CleanUp.java)).
- Verified TCP/IP handoff. After `adb tcpip 5555`, scrcpy polls the adb TCP port (`wait_tcpip_mode_enabled`, 40 attempts at 250 ms) and skips the restart when TCP/IP mode is already on. Daylight's `WifiMirror.rememberAfterUSBSession` trusts the exit status only; the Mac app should confirm adbd listens before saying Wi-Fi mirror is ready ([verified: scrcpy `app/src/server.c`](https://github.com/Genymobile/scrcpy/blob/master/app/src/server.c)).
- Device-side timestamps for recording, so "packet delay variation does not impact the recorded file". Applies only if the Mac app ever records the mirror; Daylight already carries device PTS in its 12-byte framing ([verified](https://github.com/Genymobile/scrcpy/blob/master/doc/recording.md)).
- Virtual display source (`--new-display=1920x1080`). Idea only: a virtual display sized to the board pane would decouple the mirror from tablet orientation, but it needs shell privileges, so scrcpy-server path only ([verified](https://github.com/Genymobile/scrcpy/blob/master/doc/virtual-display.md)).

**What it does badly, or what to avoid.**
- First run is documentation-driven: the FAQ tells users to check adb debugging and try another cable, and errors are console lines such as "Could not restart adbd in TCP/IP mode" with no recovery action. Every Daylight failure needs a cause and a button, as SPEC rows 21 to 39 already do ([verified](https://github.com/Genymobile/scrcpy/blob/master/FAQ.md)).
- OTG mode simulates keyboard and mouse only, so it is useless for pen ink ([verified](https://github.com/Genymobile/scrcpy/blob/master/doc/otg.md)).

**Code or protocol level.**
- `server/src/main/java/com/genymobile/scrcpy/CleanUp.java`: restores only values actually changed, in a separate process so a USB pull still restores ([verified](https://github.com/Genymobile/scrcpy/blob/master/server/src/main/java/com/genymobile/scrcpy/CleanUp.java)).
- `app/src/server.c` `wait_tcpip_mode_enabled`: poll loop for the adb tcpip handoff ([verified](https://github.com/Genymobile/scrcpy/blob/master/app/src/server.c)).
- `app/src/adb/adb.c`: exact wording for multiple, missing and unauthorized devices; reference only ([verified](https://github.com/Genymobile/scrcpy/blob/master/app/src/adb/adb.c)).

**License and reuse.** Apache-2.0 ([LICENSE](https://github.com/Genymobile/scrcpy/blob/master/LICENSE)): reusable with attribution and NOTICE, and the bundled server's license text must stay. The C client links FFmpeg and SDL, so port patterns rather than linking it.

**Relevance: high.** Daylight bundles scrcpy-server, so its unused options (stay_awake with cleanup) and handoff checks apply directly.

Already in Daylight: device selection and per-state adb errors, USB to Wi-Fi handoff with remembered IP, encoder retry and size ladder, mirror quality params, audio off, connect poll with dummy byte, forward port retries, private adb server, adb stdout check.

### scrcpy latency internals (and sndcpy)

**What it is.** scrcpy's Java server encodes the screen with MediaCodec and sends packets over an adb tunnel to a C client that decodes with FFmpeg and renders with SDL ([verified: scrcpy `server/src/main/java/com/genymobile/scrcpy/video/SurfaceEncoder.java`](https://github.com/Genymobile/scrcpy/blob/master/server/src/main/java/com/genymobile/scrcpy/video/SurfaceEncoder.java)). sndcpy is rom1v's earlier MIT audio forwarder, superseded by scrcpy audio ([verified](https://github.com/rom1v/sndcpy/blob/master/app/src/main/java/com/rom1v/sndcpy/RecordService.java)).

**What it does well that we lack.**
- Real-time encoder keys. `SurfaceEncoder.createFormat` sets `KEY_PRIORITY 0` (real-time), `KEY_LATENCY 1` ("output 1 frame as soon as 1 frame is queued") and `KEY_COLOR_RANGE COLOR_RANGE_LIMITED`. Daylight Ink's `ScreenEncoder.configure` sets none of the three. Adding them in the tablet app (API-guarded, retry without them on configure failure) is a two-line change aimed at Wi-Fi mirror latency, and explicit limited range avoids a range mismatch with the Mac decoder ([verified: scrcpy `SurfaceEncoder.java`](https://github.com/Genymobile/scrcpy/blob/master/server/src/main/java/com/genymobile/scrcpy/video/SurfaceEncoder.java); [verified](https://developer.android.com/reference/android/media/MediaFormat)).
- Low-delay decoder flag: `demuxer.c` sets `AV_CODEC_FLAG_LOW_DELAY`. The VideoToolbox analogue is `kVTDecompressionPropertyKey_RealTime`, which the Mac app's `H264Decoder.createSession` does not set ([verified: scrcpy `app/src/demuxer.c`](https://github.com/Genymobile/scrcpy/blob/master/app/src/demuxer.c); [verified](https://developer.apple.com/documentation/videotoolbox/kvtdecompressionpropertykey_realtime)).
- Skipped-frame statistic: a one-frame buffer where an unconsumed frame "is lost", counted and printed as "%u fps (+%u frames skipped)". Daylight has the one-deep slot but does not count overwritten frames; adding that to Mac app diagnostics separates "decoder too slow" from "compositor clock too slow" ([verified: scrcpy `app/src/frame_buffer.h`](https://github.com/Genymobile/scrcpy/blob/master/app/src/frame_buffer.h); [verified: `app/src/fps_counter.c`](https://github.com/Genymobile/scrcpy/blob/master/app/src/fps_counter.c)).
- Codec options passthrough: `key[:type]=value` strings fed into MediaFormat. For Daylight, a hidden MIRROR_CONTROL or Settings string lets support try vendor keys on the DC-1 without a new APK ([verified: scrcpy `SurfaceEncoder.java`](https://github.com/Genymobile/scrcpy/blob/master/server/src/main/java/com/genymobile/scrcpy/video/SurfaceEncoder.java)).

**What it does badly, or what to avoid.**
- The protocol "must be considered _internal_: it may (and will) change at any time". Keep pinning the bundled server version, as Daylight does with 4.1 ([verified](https://github.com/Genymobile/scrcpy/blob/master/doc/develop.md)).
- The encoder loop lets TCP backpressure block (blocking dequeue then blocking write): fine over USB, poor over Wi-Fi. Daylight Ink already drops instead ([verified: scrcpy `SurfaceEncoder.java`](https://github.com/Genymobile/scrcpy/blob/master/server/src/main/java/com/genymobile/scrcpy/video/SurfaceEncoder.java)).

**Code or protocol level.**
- `SurfaceEncoder.java` lines 191 to 250: retry, then constraints, then step max size down, but only before the first frame because "downsizing later could be surprising" ([verified](https://github.com/Genymobile/scrcpy/blob/master/server/src/main/java/com/genymobile/scrcpy/video/SurfaceEncoder.java)).
- sndcpy `RecordService.java`: AudioPlaybackCapture with 15 ms reads; not needed for a whiteboard ([verified](https://github.com/rom1v/sndcpy/blob/master/app/src/main/java/com/rom1v/sndcpy/RecordService.java)).

**License and reuse.** scrcpy is Apache-2.0 ([LICENSE](https://github.com/Genymobile/scrcpy/blob/master/LICENSE)) and sndcpy is MIT ([LICENSE](https://github.com/rom1v/sndcpy/blob/master/LICENSE)); the ideas are format keys and flags, so no code copy is needed.

**Relevance: high.** The two encoder keys and the decoder RealTime flag are the cheapest remaining latency levers on the Wi-Fi mirror path.

Already in Daylight: REPEAT_PREVIOUS_FRAME_AFTER and KEY_MAX_FPS_TO_ENCODER, one-deep latest-frame slot, drop-until-key decoding, scrcpy-style 12-byte framing, key frame request, drop-until-IDR on stall, TCP_NODELAY, packet size cap, encoder size ladder, zero buffering, dummy byte handshake.

### Vysor

**What it is.** Vysor (ClockworkMod) shows an Android or iOS screen in a desktop window or browser tab with mouse and keyboard control; since v3.0 it is a progressive web app "available in any browser that supports WebUSB". The client is closed source ([verified](https://github.com/koush/vysor.io/blob/master/README.md)).

**What it does well that we lack.**
- Honest latency guidance: higher bitrates and resolutions "can often result in a video higher latency/lag", and "Counterintuitively, USB 2.0 often has lower latency than USB 3.0 ports". Daylight's Mac app diagnostics can suggest another port or cable and a lower mirror size when USB latency is high ([verified](https://github.com/koush/vysor.io/wiki/Video-Quality-Guide)).
- Preset video qualities that users then tweak. Named Mac app presets ("Low latency", "Sharp text") would map onto the existing MIRROR_CONTROL max size and bitrate ([verified](https://github.com/koush/vysor.io/wiki/Video-Quality-Guide)).
- In-app self-diagnosis: a WebAssembly decoder that "May resolve black screen issues" and detection of the h264 main profile with "an automatic fix". Lesson for the Mac app: detect a known cause and offer the fix in place ([verified](https://github.com/koush/vysor.io/blob/master/README.md)).
- Link-based sharing page that tries a custom protocol, then falls back to the web app, with Launch, Open in Browser and Download buttons. Pattern for any future Daylight share link ([verified](https://github.com/koush/vysor.io/blob/master/server/index.html)).
- Frameless device window (pin the title bar, remove navigation keys). Relevant only if the Mac app adds a mirror preview window ([verified](https://github.com/koush/vysor.io/wiki/Customize-Vysor)).

**What it does badly, or what to avoid.**
- Gates quality behind payment: "High Quality Mirroring", "Fullscreen Mode", "Go Wireless" are Pro features ([verified](https://github.com/koush/vysor.io/blob/master/index.html)); reviews describe a USB-only free tier with capped bitrate and ads ([snippet](https://www.airdroid.com/screen-mirror/vysor-review)). Never gate board sharpness.
- Recurring black screens needed two separate fixes; "connected but no picture" must stay its own named state ([verified](https://github.com/koush/vysor.io/blob/master/README.md)).
- Mac users fixed "adb server version doesn't match this client" by removing Vysor and running `adb kill-server` ([snippet](https://www.janbasktraining.com/community/qa-testing/how-can-i-resolve-the-error-adb-server-version-doesnt-match-this-client)). Daylight's private adb port already avoids this.
- Platform risk: the Chrome apps "were killed" and everything was rewritten ([verified](https://github.com/koush/vysor.io/blob/master/README.md)).

**Code or protocol level.**
- Custom URL scheme with web fallback after a timeout (`server/index.html`, `protocolcheck.js`) ([verified](https://github.com/koush/vysor.io/blob/master/server/index.html)).
- Key-map JSON with per-device overrides keyed by serial; low relevance ([verified](https://github.com/koush/vysor.io/wiki/Customize-Vysor)).
- An FLV/H.264 "Web Video Stream" for OBS; low relevance to a virtual camera ([verified](https://github.com/koush/vysor.io/wiki/Vysor-and-Video-Broadcasting-(Open-Broadcast-Studio))).

**License and reuse.** Proprietary; the site repo ships [VysorLicense.pdf](https://github.com/koush/vysor.io/blob/master/VysorLicense.pdf) and the client is closed. Ideas only.

**Relevance: medium.** Mostly confirms choices Daylight already made; the USB port latency hint and quality presets are new.

Already in Daylight: Wi-Fi mirror after a USB session, isolated bundled adb on a private port, named no-picture states.

### Escrcpy and QtScrcpy (scrcpy GUI front ends)

**What it is.** Escrcpy (Electron and Vue) and QtScrcpy (Qt and C++) are open-source desktop GUIs around scrcpy and adb. Escrcpy adds wireless pairing with mDNS discovery and auto-connect; QtScrcpy exposes a thin `adb connect` box and a log ([verified](https://github.com/viarotel-org/escrcpy); [verified](https://github.com/barry-ran/QtScrcpy)). Genymotion was not researched.

**What it does well that we lack.**
- Pairing-code flow driven by mDNS, no IP:port typing. Escrcpy browses `adb-tls-pairing` (60 s timeout), pairs with the code, then connects, with typed states (`pairing`, `connecting`, `connecting-fallback`, `connected`, `error`) and typed errors (`TIMEOUT`, `PAIRING_FAILED`, `CONNECTION_FAILED`). Daylight's `adb tcpip 5555` interim fails after every tablet reboot (SPEC row 32). A Mac app wizard using NWBrowser for `_adb-tls-pairing._tcp`, where the user types 6 digits from Developer options > Wireless debugging, would remove that cable step and close LOOSE_ENDS C1 ([verified: Escrcpy `desktop/electron/middleware/adb/helpers/scanner/index.js`](https://github.com/viarotel-org/escrcpy/blob/main/desktop/electron/middleware/adb/helpers/scanner/index.js)).
- Connect ladder: remembered port first, then the mDNS `adb-tls-connect` port, then 5555 as "Last attempt". Daylight's WifiMirror tries only `<ip>:5555` ([verified: same file](https://github.com/viarotel-org/escrcpy/blob/main/desktop/electron/middleware/adb/helpers/scanner/index.js)).
- Discovery fallback by TCP probe (1 s probe, concurrency 20, port 5555) when mDNS finds nothing; useful on office Wi-Fi that blocks Bonjour ([verified: same file](https://github.com/viarotel-org/escrcpy/blob/main/desktop/electron/middleware/adb/helpers/scanner/index.js)).
- Android confirms "You only need to pair your device to your workstation once", and `adb mdns track-services` exists ([verified](https://developer.android.com/tools/adb)).

**What it does badly, or what to avoid.**
- QR pairing needs a camera, which the DC-1 lacks, so pairing code only ([verified: Escrcpy `desktop/src/utils/device/qr/index.js`](https://github.com/viarotel-org/escrcpy)).
- The scanner takes the first mDNS hit, possibly another device on a busy LAN, and surfaces raw stderr. Show the device name, confirm, and translate adb errors ([verified](https://github.com/viarotel-org/escrcpy/blob/main/desktop/electron/middleware/adb/helpers/scanner/index.js)).
- QtScrcpy writes raw log text such as "ip not find, connect to wifi?" and defaults the adb path to empty. Never use raw adb output as UI ([verified: QtScrcpy `QtScrcpy/ui/dialog.cpp`](https://github.com/barry-ran/QtScrcpy/blob/master/QtScrcpy/ui/dialog.cpp); [verified: `util/config.cpp`](https://github.com/barry-ran/QtScrcpy/blob/master/QtScrcpy/util/config.cpp)).
- "Static builds of scrcpy for macOS are still experimental" ([verified](https://github.com/viarotel-org/escrcpy/blob/main/docs/en/reference/scrcpy/macos.md)).

**Code or protocol level.**
- mDNS service types: `_adb-tls-pairing._tcp` (pairing), `_adb-tls-connect._tcp` (post-pair connect port), legacy `_adb._tcp` ([verified](https://developer.android.com/tools/adb)).
- `adb connect` exits 0 on failure, so Escrcpy checks stdout for "cannot" or "failed" (`middleware/adb/index.js`); Daylight already does the equivalent ([verified](https://github.com/viarotel-org/escrcpy/blob/main/desktop/electron/middleware/adb/index.js)).

**License and reuse.** Both Apache-2.0 ([Escrcpy](https://github.com/viarotel-org/escrcpy/blob/main/LICENSE), [QtScrcpy](https://github.com/barry-ran/QtScrcpy/blob/master/LICENSE)); compatible, though only the logic transfers from JS or C++ to Swift.

**Relevance: medium.** Escrcpy's pairing state machine and connect ladder are the missing pieces of Daylight's deferred cable-free mirror that survives a reboot.

Already in Daylight: bundled adb before PATH, auto-connect on launch, adb stdout parsing, typed failure wording.

### Apple Sidecar (plus Weylus and Deskreen)

**What it is.** Sidecar turns an iPad into an extended or mirrored Mac display with Apple Pencil input ([snippet](https://support.apple.com/102597)). Weylus streams the desktop as H.264 to a tablet browser and injects pen, touch and mouse back via Pointer Events ([verified](https://github.com/H-M-H/Weylus/blob/master/ts/lib.ts)); Deskreen CE is "an `electron.js` based application that uses `WebRTC`" ([verified](https://raw.githubusercontent.com/pavlobu/deskreen/master/README.md)).

**What it does well that we lack.**
- Live debug overlay listing PointerEvent properties (altitudeAngle, tiltX, twist) behind a toggle. A "Test pen" card on the web page or tablet app would speed up collecting LOOSE_ENDS D3, D4 and D9 facts ([verified: Weylus `ts/lib.ts`](https://github.com/H-M-H/Weylus/blob/master/ts/lib.ts)).
- Pen settings such as "Enable double tap on Apple Pencil". Once the DC-1 side button values are known (D4), it could map to Pin or Undo ([snippet](https://support.apple.com/102597)).
- Local visual feedback while video catches up: a WebGL painter draws the pen trail over the video. For Daylight, a Mac-side provisional trail from USB getevent coordinates over the mirrored video until the frame arrives (our extrapolation, unproven) ([verified: Weylus `ts/lib.ts`](https://github.com/H-M-H/Weylus/blob/master/ts/lib.ts)).
- Pointer events carry tilt and twist with microsecond timestamps; Daylight's protocol has no tilt, a candidate for v2 ([verified: Weylus `ts/lib.ts`](https://github.com/H-M-H/Weylus/blob/master/ts/lib.ts)).
- A persisted minimum-pressure slider (`Math.max(event.pressure, range_min_pressure)`) ([verified: Weylus `ts/lib.ts`](https://github.com/H-M-H/Weylus/blob/master/ts/lib.ts)).

**What it does badly, or what to avoid.**
- Sidecar failures are cause-agnostic ("The device timed out"), with user fixes ranging from Apple ID re-sign-in to turning off Internet Sharing ([snippet](https://iboysoft.com/tips/sidecar-not-working.html)); a developer was redirected to consumer support ([snippet](https://developer.apple.com/forums/thread/773859)). Keep Daylight's layer-specific failure matrix.
- Weylus has no encryption by default and self-signed certificates are painful ([verified](https://raw.githubusercontent.com/H-M-H/Weylus/master/Readme.md)).
- Weylus needs two ports opened in the firewall; Daylight's single port 7788 is better ([verified](https://raw.githubusercontent.com/H-M-H/Weylus/master/Readme.md)).

**Code or protocol level.**
- `lib/encode_video.c`: `max_b_frames = 0`, x264 `zerolatency`, NVENC `ull`, a `h264_videotoolbox` path, a fragment per frame ([verified](https://github.com/H-M-H/Weylus/blob/master/lib/encode_video.c)). Android's `KEY_MAX_B_FRAMES` defaults to 0 ([verified](https://developer.android.com/reference/android/media/MediaFormat)).
- `src/websocket.rs`: pacing skips ahead and logs dropped frames instead of queueing ([verified](https://github.com/H-M-H/Weylus)).
- `ts/lib.ts`: seeks the video to the live edge when more than 3 s behind; relevant only for a browser mirror ([verified](https://github.com/H-M-H/Weylus/blob/master/ts/lib.ts)).
- Deskreen `src/main/helpers/ipcMainHandlers.ts`: host can deny a partner, the same model as Daylight's one-click allow ([verified](https://github.com/pavlobu/deskreen)).

**License and reuse.** Weylus is AGPL-3.0-or-later ([LICENSE](https://raw.githubusercontent.com/H-M-H/Weylus/master/LICENSE)) and Deskreen CE is AGPL-3.0 ([LICENSE](https://raw.githubusercontent.com/pavlobu/deskreen/master/LICENSE)): reimplement ideas, do not copy into Apache-2.0. Sidecar is proprietary.

**Relevance: medium.** Weylus gives concrete pen-event and latency tricks; Sidecar is the pairing bar and a warning about vague errors.

Already in Daylight: coalesced events, capability check, access gate, USB or Tailscale suggestion, layer-specific errors and diagnostics, drop-never-queue, single port, no B-frames.

### Astropad (Studio, Luna Display)

**What it is.** Astropad Studio turns an iPad into a drawing tablet for a computer using its proprietary LIQUID video engine over Wi-Fi, Peer-to-Peer or USB ([snippet](https://astropad.com/astropad-3-0)). Luna Display is "Second Display Hardware", a dongle ([snippet](https://shop.astropad.com/products/luna-display)). No source is public.

**What it does well that we lack.**
- Pressure curve with Hard, Soft and Custom presets, edited by tapping to add points on a line ([snippet](https://astropad.com/blog/change-apple-pencil-pressure-curve/); [snippet](https://help.astropad.com/article/303-pressure-curve-and-smoothing)). Daylight could offer Soft, Normal and Firm presets applied at width mapping, identical for all three ink sources (Mac app render plus tablet app wet ink).
- Tap gestures with useful defaults: two-finger tap for Undo, three-finger tap for Redo ([snippet](https://help.astropad.com/article/205-magic-gestures)). Daylight swallows all finger input (SPEC D3); a deliberate two-finger Undo in the tablet app or web page is a contained exception that needs palm testing.
- Peer-to-Peer connection "lets your devices talk directly to each other, without needing a router" ([snippet](https://help.astropad.com/article/459-using-a-peer-to-peer-connection)). A direct link fallback would address client-isolated office Wi-Fi, which Daylight now solves with USB or Tailscale.
- Shortcut sets that adapt to the frontmost Mac app ([snippet](https://help.astropad.com/article/435-studio-sidebar)). Weak analogue for Daylight, which has one app on the tablet.

**What it does badly, or what to avoid.**
- The best path needs a paid dongle ([snippet](https://shop.astropad.com/products/luna-display)). Keep Daylight zero-hardware on the Mac.
- Latency figures are hard to compare: "11.32ms of average latency" in one place ([snippet](https://astropad.com/blog/comparing-latency-luna-display/)), 1 to 4 ms wired and 7 to 25 ms Wi-Fi in another ([snippet](https://support.astropad.com/en/articles/11835410-latency-and-expected-speeds-wifi-vs-wired-connections-explained)). Publish how Daylight measures.
- Smoothness is promised "especially over USB and strong WiFi connections" ([snippet](https://astropad.com/astropad-3-0)). Say plainly that Wi-Fi mirror is the slower path.

**Code or protocol level.** None found (LIQUID is proprietary). Conceptually, a pressure curve is a piecewise-linear point list applied before width mapping ([snippet](https://help.astropad.com/article/303-pressure-curve-and-smoothing)).

**License and reuse.** Proprietary ([snippet](https://astropad.com/astropad-3-0)); ideas only.

**Relevance: low.** Astropad solves full-desktop pen mirroring; only pressure curves, tap gestures and peer-to-peer transfer carry over.

Already in Daylight: measured latency in Diagnostics, partly planned customizable pill row.

### Duet Display (and the Android pen APIs)

**What it is.** Duet Display turns an iPad or Android tablet into an external display for Windows or macOS; Duet Studio adds "pen, pressure sensitivity and touch gestures" ([snippet](https://www.parkablogs.com/content/artist-review-duet-display-wireless-display-app)). On Android, tilt and pressure are supported and hover preview "will depend on the Android tablet you use" ([snippet](https://www.duetdisplay.com/blog/turn-your-ipad-or-android-into-a-lightning-fast-drawing-tablet)).

**What it does well that we lack.**
- Market signal: pen on an Android tablet driving a computer is a paid tier ([snippet](https://www.parkablogs.com/content/artist-review-duet-display-wireless-display-app)). It validates Daylight's premise; Daylight keeps pen features free and local.
- Motion prediction with `MotionEventPredictor` (`record()`, `predict()`), which "reduces perceived latency by estimating the user's stroke path". For the tablet app this stays wet-ink only, never sending predicted points, as already planned in LOOSE_ENDS F8 ([verified](https://developer.android.com/develop/ui/views/touch-and-input/stylus-input/advanced-stylus-features); [verified](https://developer.android.com/reference/androidx/input/motionprediction/MotionEventPredictor)).
- The official docs confirm the path Daylight Ink uses: `requestUnbufferedDispatch()`, front-buffered rendering on DOWN and MOVE with `commit()` on UP, and palm rejection via ACTION_CANCEL with `FLAG_CANCELED` ([verified](https://developer.android.com/develop/ui/views/touch-and-input/stylus-input/advanced-stylus-features); [verified](https://developer.android.com/reference/android/view/MotionEvent)).
- Pressure is nominally 0 to 1 "but higher values can be returned depending on the screen calibration", so clamping matters ([verified](https://developer.android.com/develop/ui/views/touch-and-input/stylus-input/advanced-stylus-features)).

**What it does badly, or what to avoid.**
- macOS 10.13.4 broke Duet and the developer advised users not to update ([snippet](https://www.iphoneincanada.ca/2018/03/30/duet-display-macos-10-13-4-support/)), because display extenders "relied on unsupported workarounds" ([snippet](https://tidbits.com/2018/04/08/macos-10-13-4-breaks-third-party-dual-display-systems/)). Daylight's CMIOExtension is the supported API; still test each macOS beta and keep "Export diagnostics...".
- Pen features behind a subscription tier ([snippet](https://www.parkablogs.com/content/artist-review-duet-display-wireless-display-app)). Keep pen features free.

**Code or protocol level.**
- `MotionEvent` batching: consume `getHistorySize()` samples with `getHistoricalEventTime(h)`; Daylight Ink already does this in `ink/MotionSamples.kt` ([verified](https://developer.android.com/reference/android/view/MotionEvent)).
- `GLFrontBufferedRenderer` and `CanvasFrontBufferedRenderer` for low-latency layers; Daylight Ink uses the latter in `ink/WetInkSurface.kt` ([verified](https://developer.android.com/reference/androidx/graphics/lowlatency/GLFrontBufferedRenderer); [verified](https://developer.android.com/reference/androidx/graphics/lowlatency/CanvasFrontBufferedRenderer)).
- LivePaper, a transflective LCD, refreshes at 45 to 90 Hz, so front-buffer wet ink still waits up to one refresh, about 11 to 22 ms (our arithmetic, not sourced; [context](https://developer.android.com/develop/ui/views/touch-and-input/stylus-input/advanced-stylus-features)).

**License and reuse.** Duet is proprietary ([snippet](https://www.parkablogs.com/content/artist-review-duet-display-wireless-display-app)); the androidx libraries are Apache-2.0 (not opened here) and compatible ([reference](https://developer.android.com/reference/androidx/graphics/lowlatency/CanvasFrontBufferedRenderer)).

**Relevance: low.** The Android docs confirm Daylight Ink's input path is already the recommended one; Duet adds a market signal and an OS-update lesson.

Already in Daylight: historical samples with per-sample time, ACTION_CANCEL retraction, stylus and eraser tool filtering, CanvasFrontBufferedRenderer wet ink, unbuffered dispatch, pressure clamp, planned motion prediction.

### reMarkable Screen Share (plus rmview, reStream, goMarkableStream)

**What it is.** Official Screen Share shows a reMarkable e-paper tablet live in the desktop app ([snippet](https://support.remarkable.com/articles/Knowledge/Screen-Share)). Community tools stream the same screen: rmview (Python VNC client), reStream (raw framebuffer, lz4, over SSH into ffplay) and goMarkableStream (on-tablet Go HTTP server, browser client, delta frames) ([verified](https://github.com/bordaigorl/rmview); [verified](https://github.com/rien/reStream); [verified](https://github.com/owulveryck/goMarkableStream/blob/main/README.md)).

**What it does well that we lack.**
- Pen hover drawn as a laser pointer on the viewer side: rmview tails the pen input device and emits move, press, lift, near and far signals, with `pen_trail` 200 ms and `hide_pen_on_press`; goMarkableStream has a togglable "Red laser pointer that follows pen hover position". In USB Mirror, `getevent` already reports hover, so the Mac app can feed it into the existing LASER_POINT path (render planned in LOOSE_ENDS F3) ([verified: rmview `src/rmview/pentracker.py`](https://github.com/bordaigorl/rmview/blob/vnc/src/rmview/pentracker.py)).
- Adaptive frame interval from encoded size (halve under 50 KB, double above 200 KB). Daylight's Wi-Fi mirror has no throughput feedback; Android supports live `PARAMETER_KEY_VIDEO_BITRATE` changes, so the tablet app could drive bitrate from throughput ([verified: goMarkableStream `internal/stream/handler.go`](https://github.com/owulveryck/goMarkableStream/blob/main/internal/stream/handler.go); [verified](https://developer.android.com/reference/android/media/MediaCodec)).
- Webcam output padded to exactly 1280x720, with a `--mirror` flag because "Zoom and Discord mirror by default the webcam video". Daylight pads already; a Mac app onboarding note that the presenter's own preview may look reversed is new ([verified: reStream `reStream.sh`](https://github.com/rien/reStream/blob/main/reStream.sh)).
- Delta frames: changed pixels only, full frame above 30% change or for a new client, zstd fastest ([verified: goMarkableStream `internal/delta/delta.go`](https://github.com/owulveryck/goMarkableStream/blob/main/internal/delta/delta.go)). A protocol idea for Wi-Fi mirror bandwidth.
- Capture reads ahead at 2x the consumer rate so it never steals bandwidth from the drawing app ([verified: goMarkableStream `internal/stream/asyncreader.go`](https://github.com/owulveryck/goMarkableStream/blob/main/internal/stream/asyncreader.go)).
- Official help names guest networks, secure gateways and firewalls as causes ([snippet](https://support.remarkable.com/articles/Knowledge/Screen-Share)).

**What it does badly, or what to avoid.**
- Setup needs SSH and legacy RSA keys; keep Daylight's adb step guided ([verified](https://github.com/rien/reStream)).
- Unauthenticated streams: rmview's VNC server "doesn't expose any authentication mechanism or uses encryption"; goMarkableStream defaults to `admin` / `password` ([verified](https://github.com/bordaigorl/rmview); [verified](https://github.com/owulveryck/goMarkableStream/blob/main/README.md)).
- Firmware coupling: rmview backends split by firmware version and goMarkableStream may need re-downloading after updates. Stay on public Android APIs ([verified](https://github.com/bordaigorl/rmview)).
- Slow 200 ms default cadence and README drift (gzip documented, zstd shipped) ([verified](https://github.com/owulveryck/goMarkableStream/blob/main/internal/stream/handler.go)).

**Code or protocol level.**
- `reStream/src/main.rs`: `draw_pen_position` burns the cursor into the frame on device ([verified](https://github.com/rien/reStream)).
- `rmview/src/rmview/screenstream/common.py`: incremental update request after each frame, pull-based backpressure ([verified](https://github.com/bordaigorl/rmview)).
- `goMarkableStream/client/worker_stream_processing.js`: full and delta frame types decoded in a Web Worker ([verified](https://github.com/owulveryck/goMarkableStream)).

**License and reuse.** rmview is GPL-3.0, ideas only ([LICENSE](https://raw.githubusercontent.com/bordaigorl/rmview/vnc/LICENSE)); reStream ([LICENSE](https://raw.githubusercontent.com/rien/reStream/main/LICENSE)) and goMarkableStream ([LICENSE](https://raw.githubusercontent.com/owulveryck/goMarkableStream/main/LICENSE)) are MIT, reusable with notice.

**Relevance: high.** Closest analogs to Mirror mode, with verified code for hover laser, adaptive pacing and delta encoding.

Already in Daylight: newest-frame-wins stamping, padded portrait board, landscape canvas, LASER_POINT opcode, wet ink separate from capture.

### Ratta Supernote

**What it is.** Supernote is a family of Ratta e-ink notebooks whose Screen Mirroring shows a URL that any browser on the same Wi-Fi can open ([snippet](https://ratta.helpjuice.com/1791924-screen-mirroring)). A third-party client shows the stream is plain HTTP MJPEG at `/screencast.mjpeg` ([verified](https://github.com/philips/supernote-typescript/blob/main/src/mirror.ts)), and the `.note` file stores per-layer rasters plus a vector stroke block ([verified](https://github.com/jya-dev/supernote-tool)).

**What it does well that we lack.**
- Per-stroke tilt and bounding box: strokes keep digitizer units, pressure, tilt pairs and a per-stroke box. Daylight's Point has only x, y, pressure and delta_ms; adding tilt and a bounding box to the strokes JSON (and reserving fields in SolStream v2) cuts redraw cost on erase ([verified: supernote-typescript `plans/vector-format-spec.md`](https://github.com/philips/supernote-typescript/blob/main/plans/vector-format-spec.md)).
- Zero-install receive side over MJPEG. For Daylight, a Diagnostics-only MJPEG debug viewer in the Mac app would let support check the Wi-Fi mirror without the camera pipeline ([verified: supernote-typescript `src/mirror.ts`](https://github.com/philips/supernote-typescript/blob/main/src/mirror.ts); [snippet](https://ratta.helpjuice.com/1791924-screen-mirroring)).
- The pen works as a laser pointer while mirroring, confirming the category expects a pointer in mirror mode ([snippet](https://support.supernote.com/en_US/how-to-share-your-supernote-screen-in-google-meet-with-screen-mirroring)). See the reMarkable hover-laser idea.
- Length-prefixed skippable records, so readers skip unknown fields ([verified](https://github.com/philips/supernote-typescript/blob/main/plans/vector-format-spec.md)).
- Record classes that name the record (ink, two-point geometry, eraser and lasso gestures) ([verified](https://github.com/philips/supernote-typescript/blob/main/plans/vector-format-spec.md)).

**What it does badly, or what to avoid.**
- "Do not use a proxy server or VPN for Screen Mirroring" ([snippet](https://ratta.helpjuice.com/1791924-screen-mirroring)). Daylight's Tailscale-first approach with a USB fallback is better than a blanket ban.
- Undocumented, unauthenticated HTTP mirror endpoint, known only by reverse engineering ([verified](https://github.com/philips/supernote-typescript/blob/main/src/mirror.ts)). Daylight's "Allow this Daylight?" step is better.
- Format churn per generation, with three separate decoders and a quirky RLE length marker. Keep Daylight's saved formats boring, PNG and JSON ([verified: supernote-tool `supernotelib/decoder.py`](https://github.com/jya-dev/supernote-tool)).

**Code or protocol level.**
- `src/mirror.ts`: GET, require multipart, split on the boundary, take the first JPEG part by Content-Length, abort ([verified](https://github.com/philips/supernote-typescript/blob/main/src/mirror.ts)).
- `src/strokes.ts`: skip the rest of a record via `strokeStart + strokeLen` ([verified](https://github.com/philips/supernote-typescript)).
- `supernotelib/parser.py`: per-page addresses in a footer ([verified](https://github.com/jya-dev/supernote-tool)).
- Walnut356/snlib has no license file; do not copy ([verified](https://github.com/Walnut356/snlib)).

**License and reuse.** supernote-tool ([LICENSE](https://raw.githubusercontent.com/jya-dev/supernote-tool/master/LICENSE)) and supernote-typescript ([LICENSE](https://github.com/philips/supernote-typescript/blob/main/LICENSE)) are Apache-2.0 and compatible, though Daylight reads no .note files, so they are references only.

**Relevance: low.** Mostly confirms choices Daylight already made, plus tilt and bounding-box fields and a pointer-in-mirror expectation.

Already in Daylight: length-prefixed versioned frames, explicit tool kind, PNG plus strokes JSON, PTS in mirror frames, friendlier VPN and isolation message.

### Onyx Boox pen SDK

**What it is.** Onyx's `onyxsdk-pen` lets an Android app on a Boox e-paper tablet hand pen input and ink rendering for a SurfaceView region to the system ("raw drawing"), while the app receives points through `RawInputCallback` ([verified](https://github.com/onyx-intl/OnyxAndroidDemo/blob/master/doc/Onyx-Pen-SDK.md)). The open-source Notable app uses it as its ink path ([verified](https://github.com/olup/notable/blob/main/app/src/main/java/com/olup/notable/classes/DrawCanvas.kt)).

**What it does well that we lack.**
- Re-arm discipline: Notable's `refreshUi()` toggles raw drawing off and on, and `updateActiveSurface()` reopens with a new limit rect. One tested "re-arm wet ink" function in the tablet app, run on layout change, resume, rotation and shade close, would prevent frozen or stale wet ink ([verified: Notable `DrawCanvas.kt`](https://github.com/olup/notable/blob/main/app/src/main/java/com/olup/notable/classes/DrawCanvas.kt)).
- Lifecycle handling: enable on resume, disable on pause, close on destroy, disabled while the notification panel is open and re-rendered on screen-on. Check that Daylight's `CanvasFrontBufferedRenderer` surface survives the same transitions ([verified: OnyxAndroidDemo `ScribbleTouchHelperDemoActivity.java`](https://github.com/onyx-intl/OnyxAndroidDemo/blob/master/app/OnyxPenDemo/src/main/java/com/onyx/android/eink/pen/demo/scribble/ui/ScribbleTouchHelperDemoActivity.java)).
- An explicit ink-region contract (limit rect plus exclude rects) with begin, move, list and end callbacks and a separate set for the eraser. A model for a SolOS fast-ink service API that Daylight Ink could call on LivePaper ([verified](https://github.com/onyx-intl/OnyxAndroidDemo/blob/master/doc/Onyx-Pen-SDK.md)).
- Vendor-owned refresh policy: `applyTransientUpdate(UpdateMode.ANIMATION_X)` app-wide and region-based finger disable, something SolOS could expose ([verified](https://github.com/onyx-intl/OnyxAndroidDemo)).

**What it does badly, or what to avoid.**
- Vendor-hosted dependency over plain HTTP, and Notable needs a hidden-API bypass "required by onyx sdk". Keep any vendor fast-ink behind Daylight's own interface ([verified](https://github.com/onyx-intl/OnyxAndroidDemo); [verified](https://github.com/olup/notable)).
- Raw mode freezes the region, so every UI change needs disable and enable choreography ([verified](https://github.com/olup/notable/blob/main/app/src/main/java/com/olup/notable/classes/DrawCanvas.kt)).
- Docs lag the API: the TouchHelper doc describes `setup(view)` while the demo uses `create(view, callback)` ([verified](https://github.com/onyx-intl/OnyxAndroidDemo)).
- BooxDrop "only supports Wi-Fi in the same local area network" ([snippet](https://shop.boox.com/blogs/news/v3-2-firmware-changelog)); Daylight's Tailscale and USB paths avoid this.

**Code or protocol level.**
- `ScribbleTouchHelperDemoActivity.java` L116 to 139: create, limit and exclude rects, open, re-run on layout change ([verified](https://github.com/onyx-intl/OnyxAndroidDemo/blob/master/app/OnyxPenDemo/src/main/java/com/onyx/android/eink/pen/demo/scribble/ui/ScribbleTouchHelperDemoActivity.java)).
- `request/ResumeRawDrawingRequest.java`: ordered resume, reader enable before render enable ([verified](https://github.com/onyx-intl/OnyxAndroidDemo)).
- `shape/BrushScribbleShape.java`: pressure divided by `MAX_TOUCH_PRESSURE` ([verified](https://github.com/onyx-intl/OnyxAndroidDemo)).

**License and reuse.** OnyxAndroidDemo is Apache-2.0 ([LICENSE](https://raw.githubusercontent.com/onyx-intl/OnyxAndroidDemo/master/LICENSE)), but the SDK binaries have no verified license and only run on Onyx firmware; Notable is GPL-3.0 ([LICENSE](https://raw.githubusercontent.com/olup/notable/main/LICENSE)), ideas only.

**Relevance: low.** Daylight Ink already uses the public Android low-latency path; Boox adds lifecycle re-arming and the case for a SolOS fast-ink service.

Already in Daylight: pen-only input with palms swallowed, pressure normalised by device range, pills in a separate overlay window.

### Wacom (pen displays, libwacom, Universal Ink Library)

**What it is.** Wacom pen displays are used by teachers as a second screen shared into Zoom ([snippet](https://www.bu.edu/engit/teaching-remotely/using-a-wacom-tablet-with-zoom/)). libwacom is a database of tablet and stylus capabilities ([verified](https://github.com/linuxwacom/libwacom)), and the Universal Ink Library is Wacom's Apache-2.0 Python implementation of the Universal Ink Model, a RIFF container with sensor, brush and ink chunks ([verified](https://github.com/Wacom-Developer/universal-ink-library)).

**What it does well that we lack.**
- Named sensor channels with units: URIs such as `will://input/3.0/channel/X`, plus Pressure, Azimuth and Altitude, with SI units in a `DEFAULT_UNITS` table. Apply to the protocol: document Daylight's strokes JSON channels and units and add optional azimuth and altitude for forward-compatible saved boards ([verified: universal-ink-library `uim/model/inkinput/inputdata.py`](https://github.com/Wacom-Developer/universal-ink-library/blob/main/uim/model/inkinput/inputdata.py)).
- Raw sensor input kept separate from rendered ink and brushes. Daylight already stores raw points with tool and color; keep doing so ([verified: universal-ink-library `uim/codec/base.py`](https://github.com/Wacom-Developer/universal-ink-library)).
- Pen variability on record: a generic pen has 2 buttons with tilt, pressure and distance axes, the Pro Pen 3 has 3 buttons; Wacom One 13 has touch while Cintiq 16 does not. Do not assume one button layout ([verified: libwacom `data/wacom.stylus`](https://github.com/linuxwacom/libwacom)).
- Sample `.uim` fixtures in `ink/uim_3.1.0/`, useful only if a UIM export is ever built ([verified](https://github.com/Wacom-Developer/universal-ink-library)).

**What it does badly, or what to avoid.**
- The incumbent teaching flow is screen sharing a whiteboard app, so the audience sees the board or the teacher. Daylight's split keeps both; a Mac app positioning line such as "your face stays on screen, no screen share" says so ([snippet](https://www.bu.edu/engit/teaching-remotely/using-a-wacom-tablet-with-zoom/)).
- libwacom describes hardware, not what buttons should do; ship defaults and a visible setting ([verified](https://github.com/linuxwacom/libwacom)).

**Code or protocol level.**
- UIM strokes reference raw samples by id and offset plus splines and per-point properties (worker reading, not re-read: `uim/model/inkdata/strokes.py`) ([source](https://github.com/Wacom-Developer/universal-ink-library)).
- The repo has no `.proto` files, only generated `_pb2.py`, so a Swift UIM writer would need to reconstruct the schema ([verified](https://github.com/Wacom-Developer/universal-ink-library)).

**License and reuse.** universal-ink-library is Apache-2.0 ([LICENSE](https://github.com/Wacom-Developer/universal-ink-library/blob/main/LICENSE)), Python only; libwacom is X11/MIT-style with a notice required ([COPYING](https://github.com/linuxwacom/libwacom/blob/master/COPYING)).

**Relevance: low.** UIM gives a naming and units model for the strokes file; little UX evidence could be opened.

Already in Daylight: configurable pen side button gestures, eraser end routing, on-screen Pin and Clear pills.

### Group B. Virtual cameras and macOS conventions
### OBS Studio macOS camera extension

**What it is.** OBS Studio ships its macOS virtual camera as a CMIO camera system extension (deployment target 13.0) with one device that has a source stream apps read and a sink stream the OBS process feeds, and keeps a legacy DAL plug-in path for macOS 12 and earlier ([verified](https://github.com/obsproject/obs-studio/tree/master/plugins/mac-virtualcam)). Daylight's extension descends from this design.

**What it does well that we lack.**
- Build handshake between host and installed component: `check_dal_plugin()` compares the installed plug-in's `CFBundleVersion` with the app's and returns `OBSDalPluginNeedsUpdate` on mismatch (OBS does this only for DAL). Daylight's extension publishes `deviceModel = "Daylight Camera"` with no build number, and SPEC 13.3 row 15 only papers over the symptom ("quit and reopen Zoom"). For the Mac app and extension: publish the extension's `CFBundleVersion` (in `deviceModel` or a second custom property beside `4cc_dlvw_glob_0000`), compare it in `CMIOSinkClient` after connect, log it, show it in Diagnostics and offer "Reinstall camera" ([verified: OBS `plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm` lines 141 to 163](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm)).
- Placeholder timer that sleeps while a sink is live: OBS keeps its 60 Hz placeholder timer ticking and returns early while `sinkStarted`; Daylight's `startStreaming()` has the same shape at 30 Hz. Small extension win: suspend the timer in `startStreamingSink` and resume it in `stopStreamingSink` ([verified: OBS `src/camera-extension/OBSCameraDeviceSource.swift` lines 139 to 150](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift)).

**What it does badly, or what to avoid.**
- No deactivation path: the plugin only submits `activationRequestForExtension` ([verified](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm)), and users resort to `systemextensionsctl` or recovery-mode steps ([snippet](https://obsproject.com/forum/threads/how-to-completely-remove-obs-virtual-camera.175824/)). Keep Daylight's "Uninstall camera" reachable from the menu, not only Settings.
- Approval and policy failures are dead ends: raw "OSSystemExtensionErrorDomain error 10" text, usually caused by an MDM allowlist ([snippet](https://obsproject.com/forum/threads/cant-start-virtual-camera-ossystemextensionerrordomain-error-10.185847)). Add a "Copy details for your IT admin" button to Daylight row 11 that copies the team identifier and the bundle id `com.twelve.daylight.camera` ([verified: OBS `en-US.ini`](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/obs-plugin/data/locale/en-US.ini)).
- The legacy DAL update runs `rm -rf '/Library/CoreMediaIO/Plug-Ins/DAL'`, which would remove other vendors' plug-ins; never delete outside your own bundle ([verified](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm)).

**Code or protocol level.**
- Sink pattern: source stream added first, sink second; host matches `kCMIODevicePropertyDeviceUID`, takes the second stream id, then `CMIOStreamCopyBufferQueue`, `CMIODeviceStartStream`, `CMSimpleQueueEnqueue`; consume timer at 3x frame rate with zero leeway ([verified: `plugin-main.mm` lines 385 to 541](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm)).
- `NSSystemExtensionUsageDescription` is set in CMake; check that Daylight's project.yml sets its own one-sentence description ([verified: `src/camera-extension/CMakeLists.txt` line 63](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/CMakeLists.txt)).
- Extension entitlements are only app sandbox plus one application group ([verified: `cmake/macos/entitlements.plist`](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/cmake/macos/entitlements.plist)).

**License and reuse.** GPL-2.0 ([verified](https://github.com/obsproject/obs-studio/blob/master/COPYING)), so nothing is copyable into Apache-2.0 Daylight; reimplement from the idea using Apple's public CMIOExtension API.

**Relevance: high.** Daylight's extension descends from this code, and the remaining gaps (build handshake, idle placeholder timer, MDM wording) are cheap.

Already in Daylight: sink/source order and UID lookup with direction check, 3x consume timer, placeholder rendered once, per-error text table, macOS 14 vs 15 approval path, "Uninstall camera", separate sink and viewer counters, no `fatalError`, stable UUIDs, fixed 1920x1080 BGRA 30 fps.

### OBS Studio virtual camera UX

**What it is.** OBS Studio's "Start Virtual Camera" publishes a system camera on macOS through a CMIOExtension that emits a bundled placeholder image while no sink is attached ([verified](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift)). Its frontend lets the user choose what the camera outputs and offers a Studio Mode with separate Preview and Program ([verified](https://github.com/obsproject/obs-studio/blob/master/frontend/utility/VCamConfig.hpp)).

**What it does well that we lack.**
- Labeled default: the output type defaults to `ProgramView` and the label reads "Program (Default)". For the Mac app, name the default mode ("Automatic (default)") wherever it is shown ([verified: OBS `frontend/utility/VCamConfig.hpp`](https://github.com/obsproject/obs-studio/blob/master/frontend/utility/VCamConfig.hpp)).
- Rehearse before you send: Studio Mode stages in Preview while the audience sees only Program. A Mac app "Rehearse" toggle could render Studio Split in the preview window while the camera keeps sending the webcam, so a presenter checks framing and board readability before a call ([verified: OBS `frontend/data/locale/en-US.ini`](https://github.com/obsproject/obs-studio/blob/master/frontend/data/locale/en-US.ini)).
- Restart warning: "The virtual camera will be restarted to apply this change". Daylight's Reinstall and Uninstall camera actions should warn "Apps using Daylight Camera will blink or go black for a moment." ([verified](https://github.com/obsproject/obs-studio/blob/master/frontend/data/locale/en-US.ini)).
- Instant option beside animated transitions: OBS ships Cut alongside a cubic-eased Slide. Daylight's critically damped spring is better for interruptible motion, but an "Instant switch" setting helps low-bandwidth calls where a 250 ms slide becomes a smear of compressed frames ([verified: OBS `plugins/obs-transitions/transition-slide.c` lines 88 to 124](https://github.com/obsproject/obs-studio/blob/master/plugins/obs-transitions/transition-slide.c)).
- Stinger transitions note that a 5 second 1080p60 video takes about 1 GB of RAM; any future Daylight flourish should be procedural, never video ([verified: `plugins/obs-transitions/data/locale/en-US.ini`](https://github.com/obsproject/obs-studio/tree/master/plugins/obs-transitions)).

**What it does badly, or what to avoid.**
- Install failures surface as raw error 10 text with MDM allowlisting as the usual cause ([snippet](https://obsproject.com/forum/threads/cant-start-virtual-camera-ossystemextensionerrordomain-error-10.185847)); Daylight already maps code 10 to plain text and should add the IT-admin details.
- Self-view mirroring: call apps mirror the presenter's own preview but send the un-mirrored frame, so text looks backwards only to the presenter ([snippet](https://dev.to/keyboard-testerclick/your-camera-isnt-broken-why-every-video-app-mirrors-you-and-how-to-prove-it-36k3), [snippet](https://c7solutions.com/2020/04/why-is-the-text-in-my-teams-background-back-to-front)). Daylight's docs never mention it. Add one line to onboarding Finish and SETUP.md ("Zoom may show the board mirrored in YOUR preview; everyone else sees it correctly. Turn off Settings > Video > Mirror my video to check.") and never mirror in the pipeline.

**Code or protocol level.**
- Placeholder: strict timer at frame rate, `CGContext` with `noneSkipFirst | byteOrder32Little`, PTS from `CMClockGetHostTimeClock()` ([verified: `OBSCameraDeviceSource.swift`](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift)); Daylight already matches.

**License and reuse.** GPL-2.0 ([verified](https://github.com/obsproject/obs-studio/blob/master/COPYING)); read for ideas only and write strings and assets fresh.

**Relevance: medium.** Little new code, but the self-view mirroring note and a rehearse mode are cheap UX wins.

Already in Daylight: placeholder card instead of black, per-macOS approval wording, live "what they see" preview window, output modes (Whiteboard Only, Studio Split, hold camera).

### Open-source virtual cameras (pyvirtualcam, akvirtualcamera, Apple WWDC22 sample, ldenoue/cameraextension)

**What it is.** pyvirtualcam pushes frames into OBS's camera sink on macOS ([verified](https://github.com/letmaik/pyvirtualcam/blob/main/pyvirtualcam/native_macos_obs_cmioextension/virtual_output.hpp)); akvirtualcamera (Webcamoid) is a GPL-3.0 virtual camera with a CMIOExtension and configurable devices and formats ([verified](https://github.com/webcamoid/akvirtualcamera)); Apple's WWDC22 session 10022 defines the provider, device, stream, sink model ([verified](https://developer.apple.com/videos/play/wwdc2022/10022/)); ldenoue/cameraextension is a small MIT Swift sample ([verified](https://github.com/ldenoue/cameraextension)).

**What it does well that we lack.**
- Viewer identity, not just a count: the extension receives a `CMIOExtensionClient` (pid, signingID, clientID) in `authorizedToStartStream(for:)` and provider `connect(to:)`. Daylight's source stream returns `true` without recording it. Record signing ids and publish them in the existing custom property (for example `sc=1;us.zoom.xos`) so the Mac app menu says "Zoom is using Daylight Camera". Caveat: `startStream()` has no client argument, so the mapping is approximate ([verified](https://developer.apple.com/documentation/coremediaio/cmioextensionclient)).
- Several formats with conversion: akvirtualcamera converts frames to the active format, and Apple says formats "become AVCaptureDeviceFormats" whose active index clients can change. Advertise 1280x720 beside 1920x1080 in the extension and scale; ldenoue's sample ships 1280x720 ([verified: akvirtualcamera `cmio/Extension/src/extensiondevicesource.mm` lines 88, 145, 412](https://github.com/webcamoid/akvirtualcamera/blob/master/cmio/Extension/src/extensiondevicesource.mm), [verified](https://developer.apple.com/videos/play/wwdc2022/10022/)).
- A second view must be a second device: "AVFoundation ignores all but the first input stream." An optional "Daylight Board" device (board only, own UUID triple, own sink) suits second-camera slots and recording; akvirtualcamera derives stream UUIDs from the device UUID ([verified: `cmio/Extension/src/extensionprovidersource.mm`](https://github.com/webcamoid/akvirtualcamera/blob/master/cmio/Extension/src/extensionprovidersource.mm)).
- Stable identifiers: the `deviceID` becomes the `AVCaptureDevice.uniqueIdentifier` unless a `legacyDeviceID` is given. Keep a test that pins Daylight's UUIDs so apps never forget the camera choice ([verified](https://developer.apple.com/videos/play/wwdc2022/10022/)).

**What it does badly, or what to avoid.**
- pyvirtualcam finds the sink by position ("pray it's always at position 2") and supports one instance only; if a second Daylight host ever opens the sink, say "Another copy of Daylight is already feeding the camera" ([verified: pyvirtualcam `virtual_output.hpp` lines 66, 156](https://github.com/letmaik/pyvirtualcam/blob/main/pyvirtualcam/native_macos_obs_cmioextension/virtual_output.hpp)).
- akvirtualcamera falls back to random pixel noise when there is no source; Daylight's cream card is right ([verified: `extensiondevicesource.mm` line 388](https://github.com/webcamoid/akvirtualcamera/blob/master/cmio/Extension/src/extensiondevicesource.mm)).

**Code or protocol level.**
- `CMIOExtensionMachServiceName` is required, and the app group must be prefixed by the Mach service name to pass validation (Daylight row 10 covers this) ([verified](https://developer.apple.com/videos/play/wwdc2022/10022/)).
- Custom string property pattern `4cc_just_glob_0000` ([verified: ldenoue `cameraextension/cameraextensionProvider.swift`](https://github.com/ldenoue/cameraextension/blob/main/cameraextension/cameraextensionProvider.swift)).
- akvirtualcamera install delegate uses `deactivationRequestForExtension` and replace-on-update ([verified: `cmio/ExtensionDelegate/src/appdelegate.mm` lines 182, 204](https://github.com/webcamoid/akvirtualcamera/blob/master/cmio/ExtensionDelegate/src/appdelegate.mm)).

**License and reuse.** pyvirtualcam is GPL-2.0 and akvirtualcamera GPL-3.0 (do not copy); ldenoue/cameraextension is MIT and reusable with attribution ([verified](https://github.com/ldenoue/cameraextension)).

**Relevance: medium.** Daylight already matches the best OSS patterns; the gains are viewer identity, a 720p format and an optional second device.

Already in Daylight: sink lookup by direction, custom viewers property with `notifyPropertiesChanged`, signing-id gate on the sink, replace-on-update and deactivation, fixed UUIDs with `legacyDeviceID: nil`.

### Reincubate Camo

**What it is.** Camo turns a phone into a webcam for Mac and PC: Camo Camera on the phone and Camo Studio on the computer, linked "using a USB cable or a supported wireless connection" ([verified](https://sourceforge.net/app/camo/mac/)). It is closed source, and most of its UX claims could not be confirmed.

**What it does well that we lack.**
- Screen curtain: after a few seconds without device movement while the rear camera is in use, Camo dims or turns off the phone screen to avoid distraction, heat and battery drain. Transfer to the DC-1 is limited because the owner writes on the tablet; the only fit is dimming the tablet app's screen while idle in passthrough with no pen activity, a battery and heat question for LOOSE_ENDS D23, not a v1 candidate ([snippet](https://camo.com/blog/camo-screen-curtain-translations-release)).

**What it does badly, or what to avoid.**
- To work in Microsoft Teams, Camo removed the host app's code signature after an admin password prompt, because Teams' library validation refused its DAL plug-in. Daylight's signed CMIOExtension design avoids this; never patch a meeting app ([snippet](https://mjtsai.com/blog/2020/08/03/camo-1-0/)).

**Code or protocol level.** None found.

**License and reuse.** Proprietary ([verified](https://sourceforge.net/app/camo/mac/)); ideas only.

**Relevance: low.** The useful Camo material is in its pairing and recovery behavior (next section); this product's other UX claims did not survive verification.

Already in Daylight: force passthrough (Hold: Camera, Esc), restart-call-app guidance (rows 13, 15), signed CMIOExtension instead of a DAL plug-in.

### Reincubate Camo: onboarding and pairing

**What it is.** Camo setup is install both apps, connect by USB or wireless, then pick Camo as the camera in the video app ([verified](https://sourceforge.net/app/camo/mac/)). Wireless pairing uses a QR code shown by Camo Studio that the phone scans, and needs macOS 12.3 and iOS 15 ([snippet](https://camo.com/support/camo/camo-getting-started/)).

**What it does well that we lack.**
- Self-healing capture: Camo Studio 2.8.2 notices when a camera has stopped sending video and restarts it automatically. Daylight recovers the mirror decoder (row 27), the Wi-Fi mirror stream (row 36) and the sink (row 13), but `WebcamCapture.swift` has no stall, runtime-error or interruption handling. For the Mac app: if a viewer is present and no webcam frame has arrived for 2 s, restart the `AVCaptureSession`, keep showing the last frame, and log a failure row "Your camera stopped sending video. Restarting it..." ([snippet](https://tidbits.com/watchlist/camo-studio-2-8-2/)).

**What it does badly, or what to avoid.**
- QR pairing depends on a phone camera. The DC-1 has none, so Daylight's Bonjour, numeric URL and one-click Allow (SPEC 9) is the right choice ([snippet](https://camo.com/support/camo/camo-getting-started/)).
- Network isolation ("some Public networks do not allow devices to communicate with each other") is explained only in a help article; Daylight already says it in-product after 60 s and offers USB and Tailscale ([snippet](https://camo.com/support/camo/troubleshooting-camo)).

**Code or protocol level.** None found.

**License and reuse.** Proprietary ([verified](https://sourceforge.net/app/camo/mac/)); ideas only.

**Relevance: medium.** Daylight's pairing already exceeds Camo's for a camera-less tablet; the webcam stall watchdog is the one new item.

Already in Daylight: network-isolation message with USB and Tailscale fallbacks, allowed-tablets list with Forget, USB auto-detect with "Set up over USB", remembered pairing.

### Apple Continuity Camera, Desk View and system video effects

**What it is.** Continuity Camera lets a Mac use an iPhone as an ordinary `AVCaptureDevice`; Desk View is a separate device with a 1920 by 1440 format up to 30 fps ([verified](https://developer.apple.com/videos/play/wwdc2022/10018/)). System effects (Center Stage, Portrait, Studio Light, Reactions) are rendered by the OS in the camera pipeline and their state is readable by apps ([verified](https://developer.apple.com/videos/play/wwdc2023/10105/)).

**What it does well that we lack.**
- Reactions are visible to apps: `reactionEffectGesturesEnabled` reflects the Control Center Gestures toggle and is KVO observable, and `reactionEffectsInProgress` lists running effects. Daylight's host opens the physical webcam itself, so a reaction would likely be baked into the frames it republishes (inference, test on hardware). For the Mac app: a one-time hint when Gestures is on ("A thumbs-up shows fireworks to everyone in the call; turn off Reactions in the menu bar camera menu") and a Diagnostics line ([verified](https://developer.apple.com/documentation/avfoundation/avcapturedevice/reactioneffectgesturesenabled), [verified](https://developer.apple.com/documentation/avfoundation/avcapturedevice/reactioneffectsinprogress)).
- Center Stage state is readable and observable but can only be set under app or cooperative control. Read it on the presenter webcam and show "Center Stage is on: it reframes you inside the right-third crop. Turn it off in Control Center > Video Effects if the framing jumps." Never try to set it ([verified](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscenterstageenabled)).
- Derived views ship as separate devices: Desk View is its own camera, which supports the "Daylight Board" second-device idea ([verified](https://developer.apple.com/videos/play/wwdc2022/10018/)).

**What it does badly, or what to avoid.**
- Implicit gesture triggers surprise audiences: Reactions are on by default and common gestures set them off ([snippet](https://actsofvolition.com/2024/03/is-your-mac-making-mystery-thumbs-up-bubbles-on-video-calls/), [snippet](https://ithelp.brown.edu/kb/articles/turn-off-video-call-reactions-in-macos-sonoma)); "the system enables reaction effects for all apps by default" ([verified](https://developer.apple.com/documentation/avfoundation/avcapturedevice/reactioneffectsenabled)). Pen-touch engage is also an implicit trigger, so keep its countdown, Pin and hold-camera escape visible.
- Presenter Overlay stops the normal stream: "the AVCaptureSession will not send the typical live camera stream". If Daylight's webcam input stalls, say "The camera stopped sending frames. If Presenter Overlay is on in Video Effects, turn it off." Whether it affects Daylight's own session is untested ([verified](https://developer.apple.com/videos/play/wwdc2023/10136/)).

**Code or protocol level.**
- `canPerformReactionEffects` requires `reactionEffectsEnabled` and the active format's `reactionEffectsSupported` ([verified](https://developer.apple.com/documentation/avfoundation/avcapturedevice/canperformreactioneffects)).
- `AVCaptureDevice.isContinuityCamera` tags the presenter camera in Diagnostics ([verified](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscontinuitycamera)).
- `videoFrameRateRangeForReactionEffectsInProgress`: the frame rate can drop during an effect, so the compositor must tolerate a lower input rate ([verified](https://developer.apple.com/videos/play/wwdc2023/10105/)).

**License and reuse.** Apple documentation and public SDK APIs; no code to copy ([verified](https://developer.apple.com/videos/play/wwdc2023/10105/)).

**Relevance: medium.** OS effects end up in the frames Daylight republishes, so cheap read-only warnings prevent confusing moments.

Already in Daylight: `systemPreferredCamera` with Continuity fallback in webcam choice, one-click stop of auto-engage (hold camera), Overlay mode (SPEC 6.7).

### Krisp

**What it is.** Krisp installs a virtual microphone and speaker that the user picks in each call app's audio settings, while the Krisp app selects the physical devices behind them ([snippet](https://krispai.notion.site/Choosing-Krisp-audio-devices-in-a-communication-app-6ce8eabeec74489789e427d8a606fbec)). It is the audio twin of "choose Daylight Camera in each call app".

**What it does well that we lack.**
- Detect "the call app is on the wrong camera": CMIO devices expose `kCMIODevicePropertyDeviceIsRunningSomewhere` ([verified](https://developer.apple.com/documentation/coremediaio/kcmiodevicepropertydeviceisrunningsomewhere)), and OverSight listens for it on every camera with `CMIOObjectAddPropertyListenerBlock` ([verified: OverSight `Application/Application/AVMonitor.m` lines 921, 1299](https://github.com/objective-see/OverSight/blob/master/Application/Application/AVMonitor.m)). For the Mac app: when Daylight Camera has 0 viewers, Daylight's own capture is idle (D32), and the physical webcam is running somewhere, say "A call app is using your FaceTime HD Camera directly. Pick Daylight Camera in its video settings." The check is meaningful only while Daylight's capture is idle.
- Name the viewing app: `CMIOExtensionClient` carries `clientID`, `pid` and `signingID`, available via `connect(to:)` and `authorizedToStartStream(for:)` ([verified](https://developer.apple.com/documentation/coremediaio/cmioextensionclient), [verified](https://developer.apple.com/documentation/coremediaio/cmioextensionstreamsource/authorizedtostartstream(for:))). Same idea as viewer identity above.
- One central per-app setup guide ([snippet](https://krispai.notion.site/Choosing-Krisp-audio-devices-in-a-communication-app-6ce8eabeec74489789e427d8a606fbec)). Daylight has the paths in docs/SETUP.md, but onboarding Finish only says "Open Zoom and pick Daylight Camera." Add a "How do I pick the camera in..." disclosure in the menu.

**What it does badly, or what to avoid.**
- Manual per-app selection with no feedback: the far end gets the raw device and nothing tells the user ([snippet](https://krispai.notion.site/Choosing-Krisp-audio-devices-in-a-communication-app-6ce8eabeec74489789e427d8a606fbec)). Daylight should detect it (above) and also say so when the pen engages with 0 viewers.

**Code or protocol level.**
- Track `CMIOExtensionClient` per authorized viewer and publish signing ids through the existing `sc=<count>` custom string property, so no new channel is needed ([verified](https://developer.apple.com/documentation/coremediaio/cmioextensionprovidersource/connect(to:))).
- OverSight's PID attribution for physical cameras scrapes the unified log through private API; do not use it for core behavior ([verified: `AVMonitor.m`](https://github.com/objective-see/OverSight/blob/master/Application/Application/AVMonitor.m)).

**License and reuse.** OverSight is GPL-3.0 ([verified](https://github.com/objective-see/OverSight/blob/master/LICENSE.md)), so reimplement from public Apple APIs; Krisp is closed source.

**Relevance: medium.** Krisp confirms the manual-selection pain, and public Apple APIs let Daylight detect and name it.

Already in Daylight: "Uninstall camera", launch-time extension activation, render only while a client streams (D32), per-app camera paths in docs/SETUP.md.

### Hand Mirror and OverSight

**What it is.** Hand Mirror is a menu-bar Mac app for a one-click camera check, free with a one-time "Plus" purchase ([snippet](https://apps.apple.com/app/hand-mirror/id1502839586)). OverSight (Objective-See) is an open-source menu-bar monitor that alerts when the mic or camera turns on and names the responsible process ([verified](https://github.com/objective-see/OverSight)).

**What it does well that we lack.**
- Popover preview from the menu bar icon, besides a draggable "Smart Window" ([snippet](https://setapp.com/apps/hand-mirror)). Daylight has a preview window (D19); a transient popover for a two-second "what do they see" check is the new part for the Mac app.
- Snaps: save a still from the preview ([snippet](https://apps.apple.com/app/hand-mirror/id1502839586)). Daylight saves boards on Clear; "Save this frame" (the composed camera picture, into the session folder) is new and cheap.
- Allow once, Allow always, Block as notification actions ([verified: OverSight `Application/Application/AVMonitor.m` lines 78 to 84](https://github.com/objective-see/OverSight/blob/master/Application/Application/AVMonitor.m)). Daylight's Allow panel is remembered forever; recorded as a pattern, no change needed.

**What it does badly, or what to avoid.**
- Attribution by log scraping is fragile: private `LoggingSupport.framework` and `OSLogEventLiveStream`, undocumented log text that changes per macOS release, and a fixed 0.5 s wait for the log line ([verified: `Application/Application/LogMonitor.m` lines 54, 90](https://github.com/objective-see/OverSight/blob/master/Application/Application/LogMonitor.m), [verified: `AVMonitor.m` lines 223 to 379](https://github.com/objective-see/OverSight/blob/master/Application/Application/AVMonitor.m)). Daylight owns its extension, so use `CMIOExtensionClient` and never scrape logs.
- Core preview features behind a paywall (Smart Window, Snaps) ([snippet](https://setapp.com/apps/hand-mirror)). Daylight's preview must stay free; it builds trust in a virtual camera.

**Code or protocol level.**
- Camera running state via `CMIOObjectAddPropertyListenerBlock` on `DeviceIsRunningSomewhere` and a re-read with `CMIOObjectGetPropertyData` ([verified: `AVMonitor.m` lines 905 to 1035, 1285 to 1320](https://github.com/objective-see/OverSight/blob/master/Application/Application/AVMonitor.m)); useful for physical cameras only (see Krisp).
- Every private call guarded with `respondsToSelector` ([verified: `LogMonitor.m` lines 107, 118](https://github.com/objective-see/OverSight/blob/master/Application/Application/LogMonitor.m)).

**License and reuse.** OverSight is GPL-3.0 ([verified](https://github.com/objective-see/OverSight/blob/master/LICENSE.md)), read only; Hand Mirror is proprietary.

**Relevance: low.** Daylight already has the preview window and owns its extension; only the popover check and "Save this frame" are new.

Already in Daylight: preview window of the composed output with float toggle, pre-call status checklist (onboarding and Diagnostics), heavy work only while a viewer exists (D32).

### Rectangle and menu-bar app conventions

**What it is.** Rectangle is an MIT-licensed menu-bar window manager with a permission window, SwiftUI Settings, launch at login via `SMAppService`, a hideable status item, Sparkle 2 updates and JSON config import/export ([verified](https://github.com/rxhanson/Rectangle)). KeyboardShortcuts and LaunchAtLogin-Modern are MIT packages by Sindre Sorhus, and Sparkle is the standard EdDSA-signed macOS updater ([verified](https://github.com/sparkle-project/Sparkle/blob/2.x/README.markdown)).

**What it does well that we lack.**
- Gentle update reminders: for scheduled checks Rectangle skips the update window and retitles a menu item "Update Available…" via `supportsGentleScheduledUpdateReminders` ([verified: Rectangle `Rectangle/AppDelegate.swift` lines 678 to 688](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AppDelegate.swift)). For Daylight's updater (loose end F9): never show an update window or relaunch while Daylight Camera has a viewer, only a menu item.
- `wasLaunchedAtLogin` detects a login launch from the open-application Apple Event; on a login launch Daylight should open no window, for example skip the preview window `previewOnLaunch` opens ([verified: LaunchAtLogin-Modern `Sources/LaunchAtLogin/LaunchAtLogin.swift` line 39](https://github.com/sindresorhus/LaunchAtLogin-Modern/blob/main/Sources/LaunchAtLogin/LaunchAtLogin.swift)).
- Hotkey hygiene: KeyboardShortcuts disables hotkeys while any menu is tracking, rejects Option-only chords, and offers block, warn and allow conflict policies ([verified: KeyboardShortcuts `Sources/KeyboardShortcuts/HotKey.swift` line 180](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/HotKey.swift), [verified](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/ConflictPolicy.swift)). Pause Daylight's hotkeys while its menu is open and validate against system shortcuts.
- Versioned, size-capped settings export with `bundleId`, `version` and a 1 MiB cap; low priority for moving settings, hotkeys and paired tablets (without secrets) to a new Mac ([verified: `Rectangle/SettingsWindow/Config.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/SettingsWindow/Config.swift)).
- A hidden menu bar icon ships with its recovery path ("relaunch Rectangle from Finder to open") ([verified: `Rectangle/RectangleStatusItem.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/RectangleStatusItem.swift)).

**What it does badly, or what to avoid.**
- Closing the permission window quits the app (`exit(1)`), and the 0.3 s poll has no timeout or hint ([verified: `AccessibilityAuthorization.swift` lines 44, 92](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityAuthorization/AccessibilityAuthorization.swift)). Daylight's Welcome only hides; keep it so.
- System Settings pane names change per OS (a `#available(macOS 27, *)` branch) ([verified: `AccessibilityView.swift` lines 57 to 60](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityAuthorization/AccessibilityView.swift)). Add a release-checklist item to re-check Daylight's pane names and `x-apple.systempreferences` URLs.
- "Remove keyboard shortcut restrictions" is on for fresh installs, hiding conflicts ([verified: `AppDelegate.swift` line 114](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AppDelegate.swift)); prefer per-conflict warnings.

**Code or protocol level.**
- `Rectangle/AppDelegate.swift` lines 676 to 695: `SPUStandardUserDriverDelegate` gentle reminders; Info.plist sets `SUPublicEDKey` and a 172800 s check interval ([verified](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/Info.plist)).
- `HotKey.swift` line 271: Carbon `RegisterEventHotKey`, as Daylight uses ([verified](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/HotKey.swift)).

**License and reuse.** Rectangle, KeyboardShortcuts and LaunchAtLogin-Modern are MIT ([verified](https://github.com/rxhanson/Rectangle/blob/main/LICENSE)) and Sparkle is MIT-style ([link](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE)); all compatible with Apache-2.0 Daylight with notices kept in THIRD_PARTY_NOTICES.md.

**Relevance: medium.** Daylight already follows most of these conventions; the no-update-during-call rule and a few hotkey and login-launch details remain.

Already in Daylight: approval step with deep link and "Check again", Welcome only hides on close, `SMAppService.mainApp` with live status and `.requiresApproval`, Carbon hotkeys with conflict and duplicate detection.

### Stream Deck SDK, OBS WebSocket and App Intents

**What it is.** Three ways a Mac app exposes actions to outside controllers: Stream Deck plugins connect to `ws://127.0.0.1:<port>` and register with `{event, uuid}` ([verified](https://github.com/elgatosf/streamdeck)); OBS WebSocket v5 is a versioned RPC protocol with optional SHA256 challenge auth ([verified](https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md)); App Intents make app actions "discoverable by Apple Intelligence and Siri, the Shortcuts app, and other system experiences" ([verified](https://developer.apple.com/documentation/appintents/appintent)).

**What it does well that we lack.**
- Deep links: `streamdeck://plugins/message/<PLUGIN_UUID>/{MESSAGE}` (Stream Deck 6.5+). Mirror it in the Mac app with a `daylight://` URL scheme (keep, clear, whiteboard, studiosplit, camera) in CFBundleURLTypes; Daylight has none. It works from Shortcuts, Raycast, a shell `open` or any launcher ([verified: streamdeck `packages/plugin/src/plugin/system.ts` lines 36 to 43](https://github.com/elgatosf/streamdeck/blob/main/packages/plugin/src/plugin/system.ts)).
- App Intents and `AppShortcutsProvider`: ship "Keep whiteboard", "Clear whiteboard", "Show whiteboard" as preconfigured Shortcuts actions that Stream Deck and launchers can run; Daylight has no AppIntent ([verified](https://developer.apple.com/documentation/appintents/appshortcutsprovider)).
- Two-state keys that show truth: manifest `States`, `DisableAutomaticStates`, and `setState`, `setTitle`, `showAlert`. A Daylight plugin could light the Whiteboard key while LIVE, title "Returning in N" from `ms_to_return`, and alert when no tablet is connected, which requires Daylight to publish state ([verified: streamdeck `packages/plugin/src/api/command.ts` lines 128 to 202](https://github.com/elgatosf/streamdeck/blob/main/packages/plugin/src/api/command.ts)).
- Event subscriptions: high-volume events are opt-in. A Daylight control API should send low-rate state events (engaged, pinned, layout, pre-warning) by default and ink only on request ([verified: obs-websocket `docs/generated/protocol.md` lines 1301 to 1341](https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md)).
- Request envelope: client `requestId` echoed in responses, RequestBatch modes, rpcVersion negotiation and explicit close codes; version any Daylight control API from day one ([verified: `protocol.md` lines 57 to 80, 307 to 341](https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md)).

**What it does badly, or what to avoid.**
- OBS itself says hotkey requests are worse than semantic requests "in 9/10 usages"; expose named actions, never "press the Carbon chord" ([verified: `protocol.md` line 2927](https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md)).
- Deep links are one-way and cannot confirm that Clear worked: use the URL scheme for fire-and-forget and a stateful channel for lit keys ([verified](https://github.com/elgatosf/streamdeck/blob/main/packages/plugin/src/plugin/system.ts)).
- Any message before `Identified` closes the socket, unfriendly to hand-written scripts; also accept a plain loopback `POST /api/keep` ([verified: `protocol.md` line 80](https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md)).

**Code or protocol level.**
- obs-websocket envelope `{"op": n, "d": {...}}`, auth = base64(sha256(base64(sha256(password + salt)) + challenge)), JSON and msgpack subprotocols; design reference only ([verified](https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md)).
- A loopback-only control route fits beside Daylight's existing WebSocket on 7788 and HTTP `/api/info` (PROTOCOL.md) without an Allow prompt; anything LAN-facing keeps the Allow model (SPEC 9.5) ([verified: streamdeck `packages/plugin/src/plugin/connection.ts` lines 63 to 75](https://github.com/elgatosf/streamdeck/blob/main/packages/plugin/src/plugin/connection.ts)).
- `packages/schemas` and `elgatosf/cli` can scaffold a small Daylight plugin ([verified](https://github.com/elgatosf/cli)).

**License and reuse.** The Stream Deck SDK and CLI are MIT ([verified](https://github.com/elgatosf/streamdeck/blob/main/LICENSE)) and reusable with notices; obs-websocket is GPL-2.0 ([verified](https://github.com/obsproject/obs-websocket/blob/master/LICENSE)), so reimplement the protocol idea only.

**Relevance: high.** A URL scheme plus App Intents, and later a small loopback control API, put Keep, Clear and Whiteboard on Stream Deck, Shortcuts and scripts with little code.

Already in Daylight: global Carbon hotkeys and menu items for every action, and an Allow model for LAN clients.

### Group C. Call platforms and presenter tools
### Zoom

**What it is.** The Zoom Apps SDK is a JavaScript library that lets a web app embedded in the Zoom client call Zoom APIs ([verified](https://github.com/zoom/appssdk/blob/main/README.md)). Its Layers API runs a rendering context either as `"immersive"` (fill the meeting canvas) or `"camera"` (affect only the user's video stream) ([verified: zoom/appssdk `dist/sdk.d.ts`](https://github.com/zoom/appssdk/blob/main/dist/sdk.d.ts)). Zoom screen share also offers "Portion of Screen" and an "Optimize for video clip" checkbox ([snippet](https://it.cornell.edu/zoom/advanced-features-zoom-when-sharing-your-screen)).

**What it does well that we lack.**
- Composited camera output as a first-class API: Camera Mode layers `drawParticipant` (with cutouts such as `person`, `circle`, `square`), `drawImage` and `drawWebView` (the app's own off-screen web view) with position, size, `zIndex`, `resolutionMode` 720p or 1080p and a frame rate. This is structurally Studio Split and Overlay, and a possible Zoom-only Mac path for managed Macs where system extension approval is blocked. Caveat: nothing shows a remote `http://<mac>:7788` page can be drawn, and a Zoom App needs Zoom's app setup ([verified: zoom/appssdk `dist/sdk.d.ts` lines 1428 to 1540, 4754 to 4880](https://github.com/zoom/appssdk/blob/main/dist/sdk.d.ts)).
- Text is protected from mirroring: only the participant layer can be mirrored in camera mode, and `cameraModeMirroring` defaults to false. Daylight lesson for the Mac compositor: the board is never mirrored ([verified: `dist/sdk.d.ts` line 4756](https://github.com/zoom/appssdk/blob/main/dist/sdk.d.ts)).
- Ready-made `circle` and rounded `square` cutouts for the presenter. A rounded or circle mask for the Mac app's Overlay corner is cheap and makes crop errors look intentional ([verified: `dist/sdk.d.ts` lines 1428 to 1445](https://github.com/zoom/appssdk/blob/main/dist/sdk.d.ts)).
- Virtual camera setup advice: select the virtual camera, turn on "Enable HD", turn off "Mirror my video". Daylight's onboarding Step 8 says nothing about Enable HD ([snippet](https://help.manycam.com/knowledge-base/zoom/)).
- Screen share is tuned for still content ("Optimize for video clip" only for full-screen video, otherwise the share may be blurry), and screen share uses about 50 to 75 kbps versus 1.2 Mbps for 720p video. Idea: a documented "share the board window" fallback in the Mac app, using the preview window or a board-only variant ([snippet](https://it.cornell.edu/zoom/advanced-features-zoom-when-sharing-your-screen), [snippet](https://learn.winona.edu/wiki/Zoom_bandwidth_requirements)).

**What it does badly, or what to avoid.**
- Zoom Whiteboard stylus bug: a stroke starting where an earlier one starts selects and drags it instead of drawing. Keep Daylight's pen-only drawing free of any select gesture ([snippet](https://community.zoom.com/t5/Zoom-Whiteboard/Problems-drawing-on-whiteboard-with-stylus/m-p/75198)).
- "Mirror my video" only changes local self-view; others and recordings get the unmirrored feed. Onboarding should say the far end sees the board correctly so users do not "fix" it ([snippet](https://community.zoom.com/t5/Zoom-Meetings/Mirror-Video-Recording-Question/m-p/136120)).

**Code or protocol level.**
- `runRenderingContext({view: 'camera', defaultCutout, resolutionMode, frameRate})`, `drawParticipant`, `drawImage`, `drawWebView`, `clearWebView`, `closeRenderingContext`; immersive mode is host-only, one app instance at a time ([verified: zoom/appssdk `dist/sdk.d.ts` lines 4712 to 4730](https://github.com/zoom/appssdk/blob/main/dist/sdk.d.ts)). A Daylight Zoom App would render the board in its own web view fed over the network.
- Readability arithmetic: Daylight's `PEN_WIDTH = 3.2` (`web/src/ink.ts` line 15) lands at about 2.2 px at 1080p and 1.4 px at 720p in Studio Split, which is why Enable HD matters ([verified, Daylight repo; context](https://help.manycam.com/knowledge-base/zoom/)).

**License and reuse.** `zoom/appssdk` is MIT licensed, so the wrapper could be used in Apache-2.0 Daylight, but a Zoom App is also bound by Zoom developer terms ([verified](https://github.com/zoom/appssdk/blob/main/LICENSE.md)).

**Relevance: medium.** The Layers API is a closely parallel compositing model and a possible extension-free path, and Zoom guidance informs far-end readability.

Already in Daylight: pen-only drawing and palm rejection (SPEC D3), picking Daylight Camera in Zoom (OWNER-NEXT-STEPS Step 8), preview window (SPEC D19).

### Microsoft Teams

**What it is.** Teams Rooms supports a "content camera" that works with image processing so a presenter can draw on an analog whiteboard and share it ([verified](https://learn.microsoft.com/en-us/microsoftteams/rooms/content-camera)). The new Teams desktop app for Windows and macOS brings "Content from camera" to personal meetings: it detects, crops and frames the board and makes the presenter somewhat transparent ([snippet](https://support.microsoft.com/en-US/teams/meetings/share-whiteboards-and-documents-using-your-camera-in-microsoft-teams-meetings), [snippet](https://mc.merill.net/message/MC710415)).

**What it does well that we lack.**
- A numeric legibility target: 1 to 2 mm of whiteboard per pixel, best 1.5 mm, on 1920x1080 or better cameras. Daylight's pen lands at about 2.2 px at 1080p and 1.4 px after a 720p send, so a "readable after compression" floor (for example 3 px at 1080p, or a "Thicker ink for calls" setting) in the Mac compositor, web page and tablet app is justified (the marker-to-pixel conversion is inference) ([verified: `Teams/rooms/content-camera.md` line 58](https://learn.microsoft.com/en-us/microsoftteams/rooms/content-camera)).
- Concrete setup geometry: recommended board widths, a distance table per field of view, at least 6 in. (152 mm) margin, checked in a camera preview. Daylight onboarding should give webcam framing guidance for the right-third crop, checked in the preview window ([verified: `content-camera.md` lines 43 to 70](https://learn.microsoft.com/en-us/microsoftteams/rooms/content-camera)).
- PowerPoint Live annotations: laser pointer that vanishes on release, pen, highlighter, eraser, none saved to the file. Daylight's `LASER_POINT` (0x0030) is accepted but not drawn (LOOSE_ENDS F3); render it in the Mac app as a fading, never-saved dot ([snippet](https://m365admin.handsontek.net/announcing-annotations-in-powerpoint-live-in-teams/)).
- Named layout presets by outcome: Standout, Side-by-side, Reporter (content over the shoulder). A Reporter-style preset is a possible fourth Mac app layout ([snippet](https://support.microsoft.com/en-us/teams/meetings/presenter-modes-in-microsoft-teams)).
- Presenter ghosted over the board so the board is never hidden; Daylight already has Overlay opacity, so only a full-frame ghost preset remains, low priority ([snippet](https://mc.merill.net/message/MC710415)).

**What it does badly, or what to avoid.**
- Presenter modes are desktop-only, and PowerPoint Live annotations are invisible to mobile users. Daylight composites one video stream, so every client sees the same layout: keep that and say it ([snippet](https://support.microsoft.com/en-us/teams/meetings/presenter-modes-in-microsoft-teams), [snippet](https://m365admin.handsontek.net/announcing-annotations-in-powerpoint-live-in-teams/)).
- The Rooms content camera needs certified cameras and a Teams Rooms Pro license; Daylight needs neither ([verified](https://learn.microsoft.com/en-us/microsoftteams/rooms/content-camera)).
- New Teams on Mac has forum reports of still or black frames from the OBS virtual camera, and of a CMIOExtension "activated enabled" that never launches. Add New Teams to the real-hardware test list ([snippet](https://obsproject.com/forum/threads/new-teams-cant-capture-the-virtual-camera.171102/), [verified: OBS `plugins/mac-virtualcam/src/obs-plugin/data/locale/en-US.ini` line 4](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/obs-plugin/data/locale/en-US.ini)).

**Code or protocol level.**
- Translate the 1 to 2 mm per pixel heuristic into a minimum composited stroke width in the Mac compositor, or a width floor in `web/src/ink.ts` and the Android `StrokeSession` ([verified: `Teams/rooms/content-camera.md` line 58](https://github.com/MicrosoftDocs/OfficeDocs-SkypeForBusiness.de-DE)).

**License and reuse.** Proprietary service; the docs are Microsoft documentation, ideas only ([verified](https://github.com/MicrosoftDocs/OfficeDocs-SkypeForBusiness.de-DE)).

**Relevance: medium.** Content from camera is the closest first-party analogue and gives a verified legibility target, and Teams is a key far-end client.

Already in Daylight: Overlay opacity slider, `LASER_POINT` counted as activity, diagnostics row 13 with restart wording, preview window.

### Google Meet

**What it is.** Meet add-ons embed a third-party web app in a meeting through `createAddonSession`, a side panel and a shared main stage ([verified: googleworkspace/meet `addons-web-sdk/samples/hello-world/src/main.js` lines 26 to 45](https://github.com/googleworkspace/meet/blob/main/addons-web-sdk/samples/hello-world/src/main.js)). Since June 2025 Meet can "Present" a camera feed as content at up to 1080p/30 fps on paid Workspace editions ([snippet](https://workspaceupdates.googleblog.com/2025/06/present-content-from-camera-in-google-meet.html)).

**What it does well that we lack.**
- Present from a camera as content, not as a face tile, on Business Standard and Plus, Enterprise, Education Plus, Workspace Individual and others. Picking Daylight Camera under Present should give the board a content-sized tile: the cheapest experiment, an onboarding tip for the Mac app, to be tested on real hardware ([snippet](https://workspaceupdates.googleblog.com/2025/06/present-content-from-camera-in-google-meet.html), [snippet](https://www.neowin.net/news/you-can-now-present-content-from-your-camera-feed-in-google-meet/)).
- Bandwidth guidance: 720p up to 1.7 Mbps, 1080p up to 3.6 Mbps. Design and test board ink (Mac app and web page) for 720p legibility ([snippet](https://support.google.com/a/answer/1279090)).
- Studio look and Studio lighting are user toggles that need Chrome or Edge 114+ and hardware acceleration; since they act on whatever camera is selected, onboarding should suggest turning them off when the board is in frame (inference) ([snippet](https://support.google.com/meet/answer/14441737)).
- Screen-share promotion: `exposeToMeetWhenScreensharing` lets a shared tab prompt Meet to open the add-on, so a tab share of the web whiteboard could later upgrade into a live add-on board ([verified: `addons-web-sdk/samples/animation-next-js/src/app/page.tsx` lines 1 to 25](https://github.com/googleworkspace/meet/blob/main/addons-web-sdk/README.md)).
- Private publishing: an add-on limited to one organization is not reviewed by Google, a plausible single-company pilot ([snippet](https://developers.google.com/workspace/meet/add-ons/guides/publish)).
- The June 2025 screen sharing update handles "scrolling text" better, which supports a documented window or tab share fallback ([snippet](https://9to5google.com/2025/06/04/google-meet-screen-sharing-update/)).

**What it does badly, or what to avoid.**
- Present from camera is edition-gated and hidden in the Present menu; onboarding should show the exact click path and fall back gracefully ([snippet](https://workspaceupdates.googleblog.com/2025/06/present-content-from-camera-in-google-meet.html)).
- Jamboard went view-only on October 1, 2024 and shut down after December 31, 2024, deleting remaining files. Keep Daylight boards local and exportable ([snippet](https://support.google.com/jamboard/answer/14084927), [snippet](https://kb.wisc.edu/news.php?id=13651)).

**Code or protocol level.**
- `@googleworkspace/meet-addons` 1.2.0: `createAddonSession`, `createSidePanelClient`, `startActivity({mainStageUrl, sidePanelUrl})`, `createMainStageClient`, `loadSidePanel`/`unloadSidePanel`, and `exposeToMeetWhenScreensharing` ([verified: `meet.addons.d.ts` lines 470 to 484](https://registry.npmjs.org/@googleworkspace/meet-addons/-/meet-addons-1.2.0.tgz)). A main stage page would host the board fed by SolStream-v1, likely needing TLS (inference).
- The SDK itself is not open source because of Google proprietary dependencies ([verified: `addons-web-sdk/README.md`](https://github.com/googleworkspace/meet/blob/main/addons-web-sdk/README.md)).

**License and reuse.** Repo and npm package are governed by the Google User Terms of Service, not an open-source license: Daylight may call the SDK from its own page but must not copy it into the Apache-2.0 repo ([verified](https://github.com/googleworkspace/meet)).

**Relevance: medium.** A no-code Present test plus 720p guidance; the add-on route is verified at API level but heavy.

Already in Daylight: picking Daylight Camera in Meet (OWNER-NEXT-STEPS Step 8), local PNG plus strokes JSON saves (SPEC section 12).

### Prezi Video

**What it is.** Prezi Video puts presentation content next to or around the presenter in one video feed, selectable as a "Prezi Video" camera in Zoom and other call apps, with layouts from Side-by-Side to a full overlay ([snippet](https://support.prezi.com/hc/en-us/articles/5246934494999), [snippet](https://prezi.com/video/)). It is closed source; all claims rest on search snippets.

**What it does well that we lack.**
- Layouts named by purpose: Floating (focus on you), Full (for "a graph or anything with detail"), Transparent (content built around you), plus a "Flip content horizontally" toggle. For the Mac app: name layouts by purpose in Settings and add a "board on the other side" (presenter left) option for Studio Split ([snippet](https://support.prezi.com/hc/en-us/articles/5246934494999)).
- Plain-language mirroring disclosure: Prezi Video for Zoom explains its mirroring and warns that other text in the feed may look mirrored. Daylight onboarding in the Mac app should state that the far end never sees the board mirrored ([snippet](https://support.prezi.com/hc/en-us/articles/7543851436311-Prezi-Video-for-Zoom-App-FAQ)).
- Presenter-only notes shown above the video, with the main preview hideable. Daylight already does the equivalent privately on the tablet chip ("LIVE", "Returning in N"), so this only confirms the design ([snippet](https://support.prezi.com/hc/en-us/articles/360003478634-How-to-use-the-Prezi-presenter-view)).

**What it does badly, or what to avoid.**
- After macOS Sonoma 14.1.1 the Prezi Video camera vanished from Zoom, attributed in the thread to macOS 14.1 listing only cameras built on modern system extensions, until a Prezi update. Daylight's CMIOExtension avoids this class of break; keep testing each macOS release ([snippet](https://community.zoom.com/t5/Zoom-App-Marketplace/Prezi-Video-Camera-option-now-not-available/td-p/154986)).
- Mirroring that depends on a host-app setting can flip unrelated text. Compose correctly in Daylight's own output and never require changing host mirroring ([snippet](https://support.prezi.com/hc/en-us/articles/7543851436311-Prezi-Video-for-Zoom-App-FAQ)).

**Code or protocol level.** None found.

**License and reuse.** Proprietary commercial product; no code reuse ([snippet](https://prezi.com/video/)).

**Relevance: medium.** The closest product analogue for content beside the presenter in a virtual camera, but with no pen-driven engage and no verifiable source.

Already in Daylight: presenter-only countdown on the tablet chip (SPEC line 356), layout hotkeys W, D, O and Esc (SPEC D46), diagnostics row 13 for "installed but not found".

### mmhmm

**What it is.** mmhmm is a virtual-camera presentation app launched in 2020 by Evernote co-founder Phil Libin; it was renamed Airtime in April 2025 and cut 25 of 58 staff in June 2025 ([snippet](https://techcrunch.com/2025/04/24/evernote-founders-video-startup-mmhmm-becomes-airtime-launches-new-products), [snippet](https://techcrunch.com/2025/06/04/its-layoff-season-at-phil-libins-airtime)).

**What it does well that we lack.**
- A Stream Deck plugin from the Elgato Marketplace with ready actions: Big Hands, zoom, fade, camera frame shape, next and previous slide, camera, mic, mirror video, record. Daylight has global hotkeys but no automation surface: expose engage, pin, clear, layout and page actions from the Mac app to Stream Deck and Shortcuts through a URL scheme or App Intents ([snippet](https://www.mmhmm.app/stream-deck), [snippet](https://airtimetools.com/stream-deck)).
- Camera frame shape choice (silhouette, circle, rectangle) for the presenter. This supports a rounded or circle option for the Overlay corner in the Mac app ([snippet](https://www.mmhmm.app/stream-deck)).

**What it does badly, or what to avoid.**
- Commercial strain: a rebrand and a layoff of 25 of 58 staff in 2025. A presenter-plus-slides virtual camera alone has struggled as a business; Daylight's hook is the pen-driven board ([snippet](https://techcrunch.com/2025/06/04/its-layoff-season-at-phil-libins-airtime)).

**Code or protocol level.** None found.

**License and reuse.** Proprietary; no reusable code ([snippet](https://www.mmhmm.app/stream-deck)).

**Relevance: low.** A slides product; the useful leads are an automation surface and presenter frame shapes.

Already in Daylight: high-contrast ink defaults, no account or login, PNG save after the call (SPEC section 12), global hotkeys (SPEC D46).

### Around

**What it is.** Around was a video-call app showing participants as small floating circles with AI face framing, meant to stay open over other apps. Miro acquired it in 2022 and shut it down on March 31, 2025, moving floating mode and EchoPrevention into Miro Video Calls ([snippet](https://alternativeto.net/news/2025/1/the-video-call-app-around-is-shutting-down-just-over-a-year-after-its-acquisition-by-miro), [snippet](https://gappsy.com/tools/around/)).

**What it does well that we lack.**
- Face-framed crop: each feed is automatically cropped to a face-centred circle. Daylight's Studio Split presenter column is a fixed centre crop (webcam source x 640 to 1280, SPEC section 6.1), so an off-centre presenter is cut. Idea for the Mac app: a smoothed, damped face-following crop for the right third using Apple Vision face rectangles, so it never jitters ([snippet](https://css-tricks.com/see-you-around/)).
- A minimal floating UI that stays out of the way while the user works elsewhere. Daylight is already a menu-bar app with small tablet pills, so this only confirms the direction ([snippet](https://alternativeto.net/news/2025/1/the-video-call-app-around-is-shutting-down-just-over-a-year-after-its-acquisition-by-miro)).

**What it does badly, or what to avoid.**
- Everyone had to join on Around, and the product was folded into Miro and shut down. Daylight's virtual camera works inside Zoom, Meet and Teams so the far end installs nothing; keep it that way ([snippet](https://alternativeto.net/news/2025/1/the-video-call-app-around-is-shutting-down-just-over-a-year-after-its-acquisition-by-miro)).

**Code or protocol level.** None found.

**License and reuse.** Proprietary and discontinued; no reusable code ([snippet](https://gappsy.com/tools/around/)).

**Relevance: low.** Only the face-framed crop transfers.

Already in Daylight: menu-bar UI and small tablet pills, Overlay mode with person segmentation (SPEC 6.7).

### Loom

**What it is.** Loom (Atlassian) is an async screen, camera and mic recorder with a Mac desktop app that needs camera, microphone and screen recording access ([snippet](https://support.atlassian.com/loom/kb/mac-app-installation-reset-accessibility-permission/)). All claims rest on search snippets of Loom's own support pages.

**What it does well that we lack.**
- When a recording finishes, the link is copied to the clipboard automatically. Daylight saves `page-NN.png` silently with no notification. Idea for the Mac app: on Clear or return-save, put the PNG on the pasteboard and post one quiet "Board saved: page 2. Copied, paste it into the chat." notification with "Show in Finder"; consider keeping it off during a call if notifications could appear on a shared screen ([snippet](https://support.atlassian.com/loom/docs/enable-video-links-to-copy-into-your-clipboard/)).
- Drawings disappear after 5 seconds "to keep your screen clear". Daylight defines `LASER_POINT` with intensity and decay (PROTOCOL 6.9) but does not draw it (LOOSE_ENDS F3); this supports shipping F3 in the Mac app and tablet app as a fading pointer that never enters the saved page ([snippet](https://support.atlassian.com/loom/docs/use-the-drawing-tool/)).
- Permission recovery via `tccutil reset All com.loom.desktop` (or per service), then restart and redo onboarding. Daylight needs only Camera, so a "Reset camera permission" button beside failure row 3 that runs `tccutil reset Camera <bundle id>` and re-requests would replace a Terminal step ([snippet](https://support.atlassian.com/loom/kb/mac-app-installation-reset-accessibility-permission/)).

**What it does badly, or what to avoid.**
- The drawing tool is gated to Education, Business and Enterprise plans and the desktop app. Do not gate the pointer or other annotation basics ([snippet](https://support.atlassian.com/loom/docs/use-the-drawing-tool/)).
- Permission failures are handed to users as Terminal commands plus a restart. Wrap the reset in a button ([snippet](https://support.atlassian.com/loom/kb/mac-app-installation-reset-accessibility-permission/)).

**Code or protocol level.** None found.

**License and reuse.** Proprietary; ideas only ([snippet](https://support.atlassian.com/loom/docs/use-the-drawing-tool/)).

**Relevance: low.** A recorder, not a live camera, but copy-on-save and the fading pointer transfer directly.

Already in Daylight: visible "Keep whiteboard" hold state (SPEC 10), permission polling with Open System Settings and Check again (SPEC 13.1), laser in the protocol (PROTOCOL 6.9) with rendering pending.

### Tella

**What it is.** Tella is a closed-source screen plus camera recorder (Mac and Windows apps, Chrome extension) with a post-recording editor for layouts and zooms ([snippet](https://www.tella.com/help/editing/use-layouts), [snippet](https://www.tella.com/help/editing/add-a-zoom)). All claims rest on search snippets of Tella's help pages.

**What it does well that we lack.**
- A 50/50 side-by-side layout with a Left/Right control for the camera side. Daylight's Studio Split is fixed (board left 1280 px, presenter right 640 px, SPEC 6.1) with no side or ratio setting. A "Presenter on the left" toggle in the Mac app is a mirrored copy of the SPEC 6 geometry; a 50/50 ratio would need a new slot (the 3:4 board would be 720 px wide) ([snippet](https://www.tella.com/help/editing/custom-layouts)).
- Auto Zoom from recorded cursor data, with Adaptive, Subtle, Moderate and Intense styles. Daylight knows exactly where the pen is, so an opt-in live "follow the ink" zoom of the board slot (for example 1.5x on recent strokes, eased with the existing spring) would aid readability after compression. It must be gentle, since a moving board can surprise the audience ([snippet](https://www.tella.com/help/editing/add-a-zoom)).
- "Camera shrinking" during zooms so the bubble does not cover detail. Mac app analogue for Overlay: shrink or move the cutout when fresh ink lands under it (weak evidence) ([snippet](https://www.tella.com/screen-effects)).

**What it does badly, or what to avoid.**
- Layout is a post-production decision in Tella, while Daylight decides live with no undo in front of an audience: keep any auto-zoom or layout change predictable and overrideable by one key (reasoning, not a source claim; context [snippet](https://www.tella.com/help/editing/custom-layouts)).

**Code or protocol level.** None found.

**License and reuse.** Proprietary SaaS; terms not opened, ideas only ([snippet](https://www.tella.com/help/editing/custom-layouts)).

**Relevance: medium.** Two concrete layout ideas (presenter side, ink-following zoom) map onto Studio Split, though evidence is snippet-only.

Already in Daylight: live layout hotkeys (SPEC 14), Overlay corner and scale settings (SPEC 11), Preview window and onboarding Finish thumbnail (SPEC 13.1).

### Descript

**What it is.** Descript is a commercial text-based audio and video editor whose "Rooms" feature is a browser-based remote studio that records a separate file on each participant's device and uploads it progressively ([snippet](https://help.descript.com/record/record-in-a-descript-room), [snippet](https://help.descript.com/record/rooms-faq)).

**What it does well that we lack.**
- Local-first capture with progressive upload: backup tracks appear first, primary files replace them later. Daylight lesson for the Mac app: the instant artifact (PNG) is available at once and anything heavier is rendered afterwards, never blocking; the 60 s autosave (SPEC 12) already covers most crash safety ([snippet](https://help.descript.com/record/record-in-a-descript-room)).
- Editing video by editing its transcript. Daylight's strokes JSON stores per-point `tMs` only relative to stroke start (SPEC 12); an absolute stroke start time would let a viewer align the board with a call transcript or recording (later, L effort) ([snippet](https://www.descript.com/)).
- Time-lapse replay of the board: a Mac app export that redraws strokes in order as MP4 or an animated page, pages as chapters, using the same absolute timestamps. This is our own design idea with no direct source, only inspired by Descript ([design idea, context](https://www.descript.com/)).

**What it does badly, or what to avoid.**
- Eye Contact silently degrades or fails with variable frame rate, several people, a small or poorly lit face, or glasses glare, with troubleshooting buried in a help article. Any presenter effect needs in-product reasons, as Daylight already does for Overlay (failure rows 48 and 49) ([snippet](https://help.descript.com/hc/en-us/articles/32871717953293)).

**Code or protocol level.**
- Implied Daylight change: add `startedAt` (absolute ms since session start) per stroke to `daylight-whiteboard-strokes/1`, or a /2 schema, so replay and transcript alignment become possible (design idea; context [snippet](https://www.descript.com/)).

**License and reuse.** Proprietary; terms not opened, ideas only ([snippet](https://www.descript.com/)).

**Relevance: low.** No live-camera overlap; useful only for the post-call replay and export story.

Already in Daylight: plain-language "why the effect is off" for the cutout (failure rows 48, 49), 60 s autosave of the dirty page (SPEC 12), zero-install web whiteboard (SPEC 9.2).

### Ecamm Live

**What it is.** Ecamm Live is a Mac-only live streaming and recording app whose Pro tier exposes a virtual camera to Zoom and other apps through a system extension ([snippet](https://support.ecamm.com/en/articles/3824881-virtual-camera-doesn-t-show-up-in-apps)). Claims rest on search snippets of Ecamm's support pages, plus one Apple technote.

**What it does well that we lack.**
- An honest Zoom quality article: the virtual camera presents as 1080p, but Zoom usually does not send camera sources at 1080p; "Meeting-HD Video Quality" must be enabled in Zoom web settings, and true 1080p needs specific plans or add-ons. Daylight has no such guidance; add a "Make the board sharp for viewers" card to the Mac app's onboarding Finish and SETUP.md ([snippet](https://support.ecamm.com/en/articles/4320083-zoom-video-quality-when-using-virtual-camera), [snippet](https://support.ecamm.com/en/articles/9179741-ecamm-for-zoom-participant-video-resolution)).
- System-extension approval fork: some users see "Details" instead of "Allow" in Privacy & Security and must tick the extension inside it, and a "recovery mode" message refers to an unrelated kernel extension. Daylight's row 12 text covers neither ([snippet](https://support.ecamm.com/en/articles/3824881-virtual-camera-doesn-t-show-up-in-apps)).
- The Outputs menu shows Virtual Cam "Ready", "In Use" or "Install Virtual Cam...", so the status line doubles as the fix. Daylight's menu `statusLine()` already reports status; make it clickable when it reports a problem ([snippet](https://learn.ecamm.com/ecamm-live-manual/016-virtual-webcam-and-outputs)).
- Stream Deck: Ecamm detects the Stream Deck software, offers its plugin (31 actions) and highlights the current scene key, a model for state feedback on any Daylight automation surface ([snippet](https://support.ecamm.com/en/articles/3370127-using-elgato-stream-deck-with-ecamm-live)).

**What it does badly, or what to avoid.**
- The quality ceiling is pushed onto the user's Zoom plan with no in-app detection. Say it in-product at onboarding Finish, not only in a help center ([snippet](https://support.ecamm.com/en/articles/9179741-ecamm-for-zoom-participant-video-resolution)).
- After Sequoia, Ecamm needed articles on the local-network prompt and on Stream Deck breaking (titles only) ([snippet](https://support.ecamm.com/en/articles/9977370-why-am-i-being-asked-to-allow-ecamm-to-find-devices-on-local-networks)). Apple's TN3179 confirms that registering a Bonjour service on macOS 15 needs local network access while accepting incoming TCP does not, which answers LOOSE_ENDS C4: Daylight's `_daylight-camera._tcp` registration will trigger the prompt, and a Deny breaks Bonjour discovery but not the numeric URL. Add a "Local Network denied" failure row and pre-prompt copy ([verified](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)).

**Code or protocol level.**
- TN3179 table (macOS 15): "Registering a service with Bonjour: yes; Listening for and accepting incoming TCP connections: no" ([verified](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)).

**License and reuse.** Proprietary; ideas only ([snippet](https://support.ecamm.com/en/articles/3824881-virtual-camera-doesn-t-show-up-in-apps)).

**Relevance: medium.** Zoom HD guidance and the Local Network lesson map directly onto far-end readability and first-run reliability.

Already in Daylight: layout menu equivalents of Ecamm's Interview buttons (MenuBar.swift), "restart the call app" guidance (rows 13, 15), extension status in the menu (`sinkStatusText`), hotkeys listed in onboarding and Settings.

### Streamlabs Desktop

**What it is.** Streamlabs Desktop is an Electron, React and TypeScript streaming and recording app built on obs-studio-node, open source under GPLv3, with multi-step onboarding, a macOS virtual camera system extension and a Performance Mode ([verified](https://github.com/streamlabs/desktop/blob/master/LICENSE)).

**What it does well that we lack.**
- Declarative onboarding steps `{component, hideButton, isPreboarding, cond, isSkippable}`, with steps hidden when their condition is already met. For the Mac app's Welcome window: on "Setup again", skip steps already satisfied (camera granted, extension active) ([verified: streamlabs/desktop `app/services/onboarding.ts` lines 38 to 104](https://github.com/streamlabs/desktop/blob/master/app/services/onboarding.ts)).
- Optimizer pattern: one Start, plain sub-step labels, and on any error `StartSetDefaultSettings()` plus "Only default settings are applied". Template for any future Daylight auto-tune (for example Wi-Fi mirror bitrate): every probe ends in safe defaults ([verified: `app/components-react/pages/onboarding/Optimize.tsx` lines 34 to 105](https://github.com/streamlabs/desktop/blob/master/app/components-react/pages/onboarding/Optimize.tsx)).

**What it does badly, or what to avoid.**
- macOS version bug: `os.release().split('.')[0]` is the Darwin major (macOS 15 is Darwin 24) compared with `>= 15`, so macOS 13 and 14 users get the wrong approval directions. Daylight uses `ProcessInfo.operatingSystemVersion.majorVersion >= 15` (ExtensionInstaller.swift line 126); pin it with a unit test ([verified: `app/services/virtual-webcam.ts` lines 117 to 125, 159 to 167](https://github.com/streamlabs/desktop/blob/master/app/services/virtual-webcam.ts)).
- The auto-optimizer is disabled ("temporarily disable auto config until migrate to new api") and its step is commented out, and it assumed a one-minute run. Own the probe, keep it to seconds and skippable ([verified: `app/services/auto-config/index.ts` lines 35 to 37](https://github.com/streamlabs/desktop/blob/master/app/services/auto-config/index.ts)).
- Selective recording silently ignores the toggle while streaming (`if (this.isStreaming) return;`). Disable a control with a stated reason instead ([verified: `app/services/streaming/streaming.ts` lines 1906 to 1915](https://github.com/streamlabs/desktop/blob/master/app/services/streaming/streaming.ts)).
- The 2021 naming dispute with the OBS Project led to the "Streamlabs OBS" rename. Credit OBS in THIRD_PARTY_NOTICES and never use "OBS" in a product name ([snippet](https://www.theregister.com/2021/11/18/streamlabs_drops_obs/), [snippet](https://invenglobal.com/articles/15737/obs-project-accuses-streamlabs-of-stealing-their-name-and-trademark)).

**Code or protocol level.**
- `InstallationErrorCodes` adds RebootRequired (100), UserApprovalRequired (101), MacOS13Unavailable (102), with an Installed / NotPresent / Outdated status enum; Daylight already has the equivalent ([verified: `app/services/virtual-webcam.ts`](https://github.com/streamlabs/desktop/blob/master/app/services/virtual-webcam.ts)).
- Performance Mode hides the editor preview (`StudioEditor.tsx` line 43) and is recommended by the Troubleshooter; Daylight already avoids this cost ([verified: `app/components-react/root/StudioEditor.tsx`](https://github.com/streamlabs/desktop/blob/master/app/components-react/root/StudioEditor.tsx)).

**License and reuse.** GPLv3 plus a BASEAGREEMENT file: not copyable into Apache-2.0 Daylight, so reimplement ideas and reword strings ([verified](https://github.com/streamlabs/desktop/blob/master/LICENSE)).

**Relevance: medium.** Daylight already matches its camera-extension UX; the value is in its failures (disabled optimizer, Darwin version bug, silent no-ops).

Already in Daylight: live permission checklist, OS-aware extension wording (row 12), not-in-Applications check, default webcam, extension status enum and replacement, low-power preview.

### Group D. Whiteboards
### Excalidraw

**What it is.** Excalidraw is an open-source (MIT) browser whiteboard whose scene is a JSON-serializable list of elements shared between peers ([verified](https://github.com/excalidraw/excalidraw/blob/master/packages/element/src/types.ts)). It was read at code level from a shallow clone at commit ed10ac7.

**What it does well that we lack.**
- PNG that reopens as editable: `encodePngMetadata` splices a tEXt chunk (keyword is the Excalidraw MIME type, text is the zlib-compressed scene) in before IEND, and `decodePngMetadata` reads it back; SVG export puts the same payload in a `<metadata>` element. Daylight writes `page-NN.png` plus `page-NN.json` side by side, and `PNGExporter.swift` adds no metadata. Embedding the strokes JSON in the Mac app's PNG (keeping the sidecar) lets an emailed or dragged-out PNG reload as strokes ([verified: Excalidraw `packages/excalidraw/data/image.ts`](https://github.com/excalidraw/excalidraw/blob/master/packages/excalidraw/data/image.ts), [verified: `scene/export.ts`](https://github.com/excalidraw/excalidraw/blob/master/packages/excalidraw/scene/export.ts)).
- Laser pointer as an ephemeral tool: trails use the MIT `@excalidraw/laser-pointer` package with streamline 0.4 and a size that fades by time (DECAY_TIME 1000 ms) and by trail length (DECAY_LENGTH 50); trails are never scene elements. Daylight already reserves LASER_POINT in SolStream-v1 but does not render it (LOOSE_ENDS F3), so these constants are a starting point for the web page, tablet app and Mac app ([verified: `laserTrails.ts`](https://github.com/excalidraw/excalidraw/blob/master/packages/excalidraw/laserTrails.ts)).
- Library of reusable items (`LibraryItem` with elements, persisted as a versioned file). Daylight analog: one-tap "stamps" (axes, grid, arrow) on the web page; low priority for a single presenter ([verified: `data/library.ts`](https://github.com/excalidraw/excalidraw/blob/master/packages/excalidraw/data/library.ts)).

**What it does badly, or what to avoid.**
- The embedded scene is a compressed blob only Excalidraw can read. If Daylight embeds strokes, embed the plain versioned `daylight-whiteboard-strokes/1` JSON and keep the sidecar ([verified](https://github.com/excalidraw/excalidraw/blob/master/packages/excalidraw/data/image.ts)).
- Reconciliation is last-writer-wins by `version` then `versionNonce`, silently dropping one side of concurrent edits. Daylight has one writer per page; do not import multi-writer sync ([verified: `data/reconcile.ts`](https://github.com/excalidraw/excalidraw/blob/master/packages/excalidraw/data/reconcile.ts)).

**Code or protocol level.**
- Freedraw element stores `points` and `pressures` relative to the element, with no timestamps; Daylight's points already carry `tMs` ([verified: `packages/element/src/types.ts`](https://github.com/excalidraw/excalidraw/blob/master/packages/element/src/types.ts)).
- Variable-width rendering calls perfect-freehand with size = strokeWidth * 4.25, thinning 0.6, smoothing 0.5, streamline 0.5 (0.2 for "precise"), easeOutSine, `last: true`; constant-width strokes use factor 1.4. Starting constants for a Daylight port ([verified: `packages/element/src/shape.ts`](https://github.com/excalidraw/excalidraw/blob/master/packages/element/src/shape.ts), [verified: `packages/common/src/constants.ts`](https://github.com/excalidraw/excalidraw/blob/master/packages/common/src/constants.ts)).
- Collab uses volatile cursor broadcasts (33 ms), durable scene broadcasts, a full resync every 20 s, and a room link with a 128-bit key in the URL fragment; the link idea needs a relay Daylight does not have ([verified: `excalidraw-app/app_constants.ts`](https://github.com/excalidraw/excalidraw/blob/master/excalidraw-app/app_constants.ts)).

**License and reuse.** MIT, including `packages/laser-pointer`; reusable in Apache-2.0 Daylight with the notice kept in THIRD_PARTY_NOTICES.md ([verified](https://github.com/excalidraw/excalidraw/blob/master/LICENSE)).

**Relevance: high.** The PNG-with-embedded-strokes save and the laser trail constants map directly onto open Daylight items (SPEC 12 save format, LOOSE_ENDS F3).

Already in Daylight: pen-only input with palm and finger rejection; split between "meaningful now or never" control messages and the ink ring; LASER_POINT on the wire (not yet rendered).

### tldraw

**What it is.** tldraw is a TypeScript infinite-canvas whiteboard SDK (React) from tldraw, Inc., with a sync stack and freehand draw, highlight and laser tools; it is source-available under a restrictive license, not open source ([verified](https://github.com/tldraw/tldraw/blob/main/LICENSE.md)). Read from a shallow clone at commit db1c86e.

**What it does well that we lack.**
- Laser as a scribble session, never a shape: `LaserTool` runs sessions in `ScribbleManager` with `fadeMode: 'grouped'`, `fadeEasing: 'ease-in'`, and a default `laserFadeoutMs` of 500, so nothing is saved or undoable. Daylight's LASER_POINT golden vector already uses decay_s 0.5, matching tldraw, but the Mac does not draw it (LOOSE_ENDS F3); this applies to the web page, tablet app and Mac app ([verified: tldraw `LaserTool.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tldraw/src/lib/tools/LaserTool/LaserTool.ts), [verified: `options.ts`](https://github.com/tldraw/tldraw/blob/main/packages/editor/src/lib/options.ts)).
- Stylus-reporting-as-mouse heuristic: `isPenOrStylus` is true when `isPen && z !== 0` or the pressure is fractional ("If the pressure is weird, then it's probably a stylus reporting as a mouse"). Daylight's web page drops any non-"pen" pointer, so if Chrome on SolOS reports the Wacom pen as mouse nothing draws. A fallback that treats fractional pressure as pen, and logs it in the facts report, is cheap insurance until hardware tests confirm ([verified: `Drawing.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tldraw/src/lib/shapes/draw/toolStates/Drawing.ts)).
- Highlighter as underlay plus overlay (`underlayOpacity: 0.82`, `overlayOpacity: 0.35`); an alternative to Daylight's multiply to test against video compression; low priority ([verified: `HighlightShapeUtil.tsx`](https://github.com/tldraw/tldraw/blob/main/packages/tldraw/src/lib/shapes/highlight/HighlightShapeUtil.tsx)).
- Distance-based point recording: a point is kept only when at least `1 / zoomOnEnter` page units from the last. Daylight thins only under socket backpressure; a constant gate is an option if bandwidth matters ([verified: `Drawing.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tldraw/src/lib/shapes/draw/toolStates/Drawing.ts)).

**What it does badly, or what to avoid.**
- License key and watermark: production use needs a trial or commercial key, the software ensures "proper watermark display" and may transmit usage data. A watermark in a camera feed is unacceptable; borrow ideas only ([verified](https://github.com/tldraw/tldraw/blob/main/LICENSE.md)).
- Coalesced events are disabled on iOS ("Sometimes getCoalescedEvents isn't present on iOS, ugh"); keep feature detection ([verified: `useCanvasEvents.ts`](https://github.com/tldraw/tldraw/blob/main/packages/editor/src/lib/hooks/useCanvasEvents.ts)).

**Code or protocol level.**
- Draw segments store a base64 path: first point Float32, later points Float16 deltas ([verified: `tlschema/src/misc/b64Vecs.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/misc/b64Vecs.ts)).
- Pen mode returns early for non-pen pointers and auto-enables for direct-display pens ([verified: `editor/src/lib/utils/pointer.ts`](https://github.com/tldraw/tldraw/blob/main/packages/editor/src/lib/utils/pointer.ts)).
- Sync: `TLSYNC_PROTOCOL_VERSION = 8`, `hydrationType`, an `incompatibility_error` message, client ticks at 30 fps collaborative and 1 fps solo ([verified: `sync-core/src/lib/protocol.ts`](https://github.com/tldraw/tldraw/blob/main/packages/sync-core/src/lib/protocol.ts), [verified: `TLSyncClient.ts`](https://github.com/tldraw/tldraw/blob/main/packages/sync-core/src/lib/TLSyncClient.ts)).

**License and reuse.** The tldraw license requires a key for production, forbids interfering with key enforcement and relicensing; it is not usable in Apache-2.0 Daylight, so reimplement from ideas and copy no files, including the b64 encoder ([verified](https://github.com/tldraw/tldraw/blob/main/LICENSE.md)).

**Relevance: medium.** The laser and pressure-heuristic ideas apply to the web whiteboard, but no code can be reused under Apache-2.0.

Already in Daylight: getCoalescedEvents with feature detection plus `pointerrawupdate`; protocol version handshake with an "Update Daylight on your Mac" message; pen-only input; LASER_POINT on the wire (not rendered).

### perfect-freehand

**What it is.** perfect-freehand is a small MIT TypeScript library (v1.2.3) that turns `[x, y, pressure]` samples into the closed outline polygon of a variable-width stroke, which the caller fills ([verified](https://github.com/steveruizok/perfect-freehand)). Related: androidx.ink went stable at 1.0.0 on 2025-12-17 and wraps Google's Apache-2.0 C++ ink engine ([verified](https://developer.android.com/jetpack/androidx/releases/ink)). Daylight today draws per-segment round-cap lines with width `base * (0.55 + 0.9 * pressure)` and no smoothing anywhere in the ink path.

**What it does well that we lack.**
- One filled polygon per stroke: no overlap darkening at segment joins for translucent ink, and sharp corners get a rounded cap instead of a self-intersecting bow-tie. Fits the Mac rasterizer and PNG exporter ([verified: perfect-freehand `src/getStrokeOutlinePoints.ts`](https://github.com/steveruizok/perfect-freehand/blob/main/packages/perfect-freehand/src/getStrokeOutlinePoints.ts)).
- Streamline smoothing as an exponential lerp (`t = 0.15 + (1 - streamline) * 0.85`), with the last point snapping to the real input; hides digitizer jitter on the far-end video ([verified: `src/getStrokePoints.ts`](https://github.com/steveruizok/perfect-freehand/blob/main/packages/perfect-freehand/src/getStrokePoints.ts)).
- Start and end noise gates: skip points until running length reaches `size`, skip outline points within 3 px of the end, first pressure 0.25, initial pressure averaged over 10 points. Removes the fat start blob on the Mac app and web page ([verified: `src/constants.ts`](https://github.com/steveruizok/perfect-freehand/blob/main/packages/perfect-freehand/src/constants.ts)).
- Pressure to radius with one thinning knob: `size * easing(0.5 - thinning * (0.5 - pressure))`; thinning 0 gives constant width ([verified: `src/getStrokeRadius.ts`](https://github.com/steveruizok/perfect-freehand/blob/main/packages/perfect-freehand/src/getStrokeRadius.ts)).
- Optional start and end taper by path length; low priority, a brush-pen option ([verified: `src/getStrokeOutlinePoints.ts`](https://github.com/steveruizok/perfect-freehand/blob/main/packages/perfect-freehand/src/getStrokeOutlinePoints.ts)).

**What it does badly, or what to avoid.**
- Fixed cap segment counts (13 and 29) and `FIXED_PI = PI + 0.0001` "to fix browser rendering artifacts"; test the Swift port at Studio Split scale and after Zoom compression ([verified: `src/constants.ts`](https://github.com/steveruizok/perfect-freehand/blob/main/packages/perfect-freehand/src/constants.ts)).
- Streamline trails the pen by design, with a TODO to backfill missing points; keep raw points for the tablet's wet ink and smooth only the composited board, or use a low streamline ([verified: `src/getStrokePoints.ts`](https://github.com/steveruizok/perfect-freehand/blob/main/packages/perfect-freehand/src/getStrokePoints.ts)).
- Stateless and time-blind, recomputing the outline from all points each call; cache finished strokes as CGPath and recompute only the active stroke ([verified](https://github.com/steveruizok/perfect-freehand/blob/main/packages/perfect-freehand/src/getStroke.ts)).

**Code or protocol level.**
- `getStroke = getStrokeOutlinePoints(getStrokePoints(points, opts), opts)`: port about 600 lines to Swift for the Mac, and use the TS original on the web wet canvas so tablet and camera match ([verified: `src/getStroke.ts`](https://github.com/steveruizok/perfect-freehand/blob/main/packages/perfect-freehand/src/getStroke.ts)).
- Extend Daylight's existing cross-language golden vector pattern with outline fixtures so TS, Swift and Kotlin renderers agree ([verified: perfect-freehand `src/`](https://github.com/steveruizok/perfect-freehand/tree/main/packages/perfect-freehand/src)).
- 1 Euro filter: speed-adaptive low-pass with two parameters, applied on the Mac using `tMs` ([snippet](https://github.com/casiez/OneEuroFilter)).
- androidx.ink is Android only, usable only inside Daylight Ink ([verified](https://developer.android.com/jetpack/androidx/releases/ink)).

**License and reuse.** perfect-freehand is MIT, so a Swift port is fine in Apache-2.0 with the notice in THIRD_PARTY_NOTICES.md and file headers ([verified](https://github.com/steveruizok/perfect-freehand/blob/main/LICENSE)); google/ink is Apache-2.0 ([verified](https://github.com/google/ink/blob/main/LICENSE)); reimplement the 1 Euro filter from the paper.

**Relevance: medium.** A small MIT port gives better stroke shape and jitter hiding on the far-end video; polish, not a setup or latency fix.

Already in Daylight: cross-language golden vectors for the wire protocol; a linear pressure-to-width mapping with round caps.

### Apple Freeform

**What it is.** Freeform is Apple's infinite-canvas collaborative board app for iPhone, iPad and Mac, where boards can be organised into scenes (saved views) that are navigated and presented section by section ([snippet](https://support.apple.com/en-ae/guide/freeform/frfm7cc55b64/mac)). Apple's pages could not be fetched, so all claims rest on re-confirmed search snippets.

**What it does well that we lack.**
- Scenes, named saved views of a board: frame part of the board, add a scene (Shift-Command-S), rename, reorder, present section by section. Daylight analog: named regions of the 1200x1600 page that the Mac compositor zooms into inside the board slot, eased by the existing spring animator. Today the page is shown whole at 3:4 and 1080 px height in two thirds of the frame, so small handwriting is hard to read after compression ([snippet](https://support.apple.com/en-ae/guide/freeform/frfm7cc55b64/mac)).
- Non-linear presenting: jump to any scene from a list. Daylight analog: next and previous region hotkeys plus a menu bar jump list in the Mac app ([snippet](https://macmost.com/using-freeform-as-a-presentation-tool.html)).
- Follow Along shows exactly where a collaborator is on the board. Daylight analog, low feasibility: a read-only live viewer web page, but attendees on other networks cannot reach the Mac's :7788 without a relay ([snippet](https://education.apple.com/resource/250014931)).

**What it does badly, or what to avoid.**
- Sharing and live collaboration run through Apple accounts and iCloud. Lesson, an inference of low weight: keep Daylight's output as plain video plus PNG and JSON files that work in any call app ([snippet](https://support.apple.com/en-ae/guide/freeform/frfm7cc55b64/mac)).

**Code or protocol level.**
- A region is just (name, x, y, zoom, order); it could be an optional `regions` array in the strokes JSON, which would need a minor version of `daylight-whiteboard-strokes/1`. This is a design inference ([snippet](https://support.apple.com/en-ae/guide/freeform/frfm7cc55b64/mac)).

**License and reuse.** Proprietary Apple software; ideas only ([snippet](https://support.apple.com/en-ae/guide/freeform/frfm7cc55b64/mac)).

**Relevance: medium.** Region zoom addresses far-end readability of a portrait page in a landscape slot, though the evidence is secondary.

### Miro

**What it is.** Miro is an online collaborative whiteboard with a Presentation mode and Talktrack recorded walkthroughs ([snippet](https://help.miro.com/hc/articles/34307373858450-Presentation-mode)), and a REST API v2 with official MIT-licensed SDKs ([verified](https://github.com/miroapp/api-clients/blob/main/LICENSE)). For Daylight it matters as a destination for saved pages, not as a competitor.

**What it does well that we lack.**
- Image upload API: `createImageItemUsingLocalFile` posts multipart to `/v2/boards/{board_id}/images` with a `resource` file ("Maximum file size is 6 MB") and optional `data` JSON, scope boards:write. A 1200x1600 page PNG is far under 6 MB, so a "Send page to Miro" item in the Mac app is about 40 lines of URLSession ([verified: miro api-clients `packages/miro-api/api/apis.ts`](https://github.com/miroapp/api-clients/blob/main/packages/miro-api/api/apis.ts)).
- `createBoard` exists in the same client, so one click can create a "Daylight <date>" board ([verified: `packages/miro-api/highlevel/index.ts`](https://github.com/miroapp/api-clients/blob/main/packages/miro-api/highlevel/index.ts)).
- Talktrack records the board viewport, cursor, the presenter's camera (or avatar) and audio. Daylight analog: an optional "record this board session" clip of the Studio Split output from the Mac app ([snippet](https://help.miro.com/hc/en-us/articles/11148211487378-Talktrack-Admin-security)).

**What it does badly, or what to avoid.**
- Free plan allows 3 editable boards per team; older boards become view-only and users report being blocked from a fourth. If Daylight pushes to Miro, use one board with a frame per session and turn the API refusal into a plain sentence ([snippet](https://community.miro.com/ask-the-community-45/free-plan-won-t-let-me-create-a-4th-board-i-thought-boards-were-unlimited-28959)).
- Presentation mode interrupts everyone: "a modal appears for all participants on the board to join or decline." Daylight's gentle slide and amber warning already avoid surprising the audience ([snippet](https://help.miro.com/hc/articles/34307373858450-Presentation-mode)).

**Code or protocol level.**
- Auth is an OAuth2 token with boards:write; a pasted personal token stored in Keychain is the small path ([verified: `packages/miro-api/api/apis.ts`](https://github.com/miroapp/api-clients/blob/main/packages/miro-api/api/apis.ts)).
- app-examples has Vite and TypeScript Web SDK samples (selfie-with-custom-action, html-preview, drag-and-drop) showing in-board image insertion ([verified: `miroapp/app-examples/examples`](https://github.com/miroapp/app-examples/tree/main/examples)).

**License and reuse.** api-clients and app-examples are MIT ("Copyright (c) 2022 Miro"); the Miro API terms were not opened ([verified](https://github.com/miroapp/app-examples/blob/main/LICENSE)).

**Relevance: low.** A well-documented export target for after-call sharing; nothing about the live camera.

Already in Daylight: numbered page files per session (`page-01.png`, `page-02.png`, SPEC 12).

### FigJam

**What it is.** FigJam is Figma's online whiteboard with marker, highlighter and eraser tools plus facilitation features such as spotlight, cursor chat and timer ([snippet](https://help.figma.com/hc/en-us/articles/8538436879767)). It has an MIT-licensed Plugin API typings package and REST API spec ([verified](https://github.com/figma/plugin-typings/blob/master/LICENSE)).

**What it does well that we lack.**
- SVG and PNG import paths: `figma.createNodeFromSvg(svg)` returns a FrameNode, `createImage(Uint8Array)` takes PNG, JPEG or GIF up to 4096 px per side, and `createVector()` takes SVG path data. A Daylight page also saved by the Mac app as SVG (one filled path per stroke) imports cleanly into Figma, FigJam and other vector tools ([verified: figma plugin-typings `plugin-api.d.ts`](https://github.com/figma/plugin-typings/blob/master/plugin-api.d.ts), [verified: plugin-samples `vector-path/code.ts`](https://github.com/figma/plugin-samples/blob/master/vector-path/code.ts)).
- Spotlight asks rather than forces: viewers "have a few seconds to ignore your request" before following. The far end cannot opt out of Daylight's camera, so engage must stay gentle, which is already the design ([snippet](https://figma-signup.helpjuice.com/facilitate-meetings-with-spotlight)).
- Sparse marker defaults ("a thin, gray stroke", thin or thick) and a highlighter palette of 8 named pastel colors; a reference for the web page if colors are added ([snippet](https://help.figma.com/hc/en-us/articles/1500004414442)).
- Timer API with remaining and total time and start, pause, resume and stop. Daylight analog, low priority: an on-board countdown ([verified: `plugin-api.d.ts`](https://github.com/figma/plugin-typings/blob/master/plugin-api.d.ts)).

**What it does badly, or what to avoid.**
- It is an in-call app model (Figma for Zoom, Meet add-on), so participants need the add-on. A virtual camera needs no far-end setup; keep that ([snippet](https://figma-signup.helpjuice.com/meetings/figma-and-zoom)).
- The REST spec only exposes image render reads (`/v1/images/{file_key}`, `/v1/files/{file_key}/images`) and no node-creation endpoint was found, so a headless "push to FigJam" from the Mac is not possible ([verified: figma rest-api-spec `openapi/openapi.yaml`](https://github.com/figma/rest-api-spec/blob/main/openapi/openapi.yaml)).

**Code or protocol level.**
- `figma.editorType` is 'figma' | 'figjam' | 'dev' | 'slides' | 'buzz' ([verified: `plugin-api.d.ts`](https://github.com/figma/plugin-typings/blob/master/plugin-api.d.ts)).
- Practical share route: write `page-NN.svg` next to the PNG and let users drag it in; drag-in of SVG was not verified ([verified: `plugin-api.d.ts`](https://github.com/figma/plugin-typings/blob/master/plugin-api.d.ts)).

**License and reuse.** plugin-typings, plugin-samples and rest-api-spec are MIT; FigJam itself is proprietary ([verified](https://github.com/figma/rest-api-spec/blob/main/LICENSE)).

**Relevance: low.** Mainly an SVG export target and a reminder that opt-in following matters.

Already in Daylight: a minimal tool set (pen, highlighter, eraser); Pin and Hold to keep the board up.

### GoodNotes and Notability

**What it is.** GoodNotes and Notability are iPad handwriting apps widely used by teachers as a live whiteboard. GoodNotes Presentation Mode, over AirPlay or a cable, hides the interface from the audience and offers Mirror Presenter Page (with zoom and page-switching animations) or Mirror Full Page, on iPad and iPhone only ([snippet](https://support.goodnotes.com/hc/en-us/articles/7353727934223-Present-Goodnotes-on-an-external-screen)). The iOS mechanism is a non-interactive window scene on the connected display ([verified](https://developer.apple.com/documentation/uikit/presenting-content-on-a-connected-display)).

**What it does well that we lack.**
- Laser pointer in two styles: "Dot" (a red dot following the pen) and "Trail" (a temporary trail that disappears shortly after). Daylight has the LASER_POINT opcode but no tool and no rendering (LOOSE_ENDS F3); shipping both styles on the web page and tablet app, drawn into the Mac's camera board and never into the saved page, matches what teachers expect ([snippet](https://support.goodnotes.com/hc/en-us/articles/7353727934223-Present-Goodnotes-on-an-external-screen), [snippet](https://goodnotes-team.notion.site/The-Laser-Pointer-Tool-d1b4143a642e433c9ed820ce7b079414)).
- Page-turn animation is part of the audience view. Daylight's New page swaps the board instantly (`InkRouter.newPage` in `mac/Daylight/Sources/Ink/InkRouter.swift`); a short slide or crossfade in the Mac compositor orients the far end and avoids a hard cut in compressed video ([snippet](https://support.goodnotes.com/hc/en-us/articles/7353727934223-Present-Goodnotes-on-an-external-screen)).

**What it does badly, or what to avoid.**
- Users asked GoodNotes to bring back presentation mode after GoodNotes 5 shipped without it. Once presenters rely on a clean view, removing it breaks trust; keep the clean board identical across all three ink sources ([snippet](https://feedback.goodnotes.com/forums/191274-customer-suggestions-for-goodnotes/suggestions/36551317-bring-back-presentation-mode-in-goodnotes-5)).
- Users request a "reveal tool for presentation mode" (cover and uncover); Daylight's Hold Camera and Pin already cover the "hide board, show presenter" need ([snippet](https://feedback.goodnotes.com/forums/191274-customer-suggestions-for-goodnotes/suggestions/45511228-reveal-tool-for-presentation-mode)).

**Code or protocol level.**
- iOS mirrors the primary display or presents non-interactive role scenes full screen; beginning in iOS 27 the app receives that scene only after registering a scene accessory (`UISceneAccessory.externalNonInteractive(sceneConfiguration:)`). Relevant only to a future iPad companion, not the DC-1 ([verified](https://developer.apple.com/documentation/uikit/presenting-content-on-a-connected-display)).
- `UIScreen.didConnectNotification` is not sent for screens already present at launch. General lesson: enumerate already-connected devices at startup rather than relying on connect events only ([verified](https://developer.apple.com/documentation/uikit/uiscreen/didconnectnotification)).

**License and reuse.** Both apps are closed source; ideas only ([snippet](https://support.goodnotes.com/hc/en-us/articles/7353727934223-Present-Goodnotes-on-an-external-screen)).

**Relevance: medium.** Sets the audience expectations (laser, page transitions, clean page) that Daylight must meet.

Already in Daylight: a clean audience view (board rendered from the stroke model, mirror crop removes the pill strip); a board curtain (Hold Camera and Pin); auto-engage on pen contact with no manual "start presenting" step.

### Group E. Ink formats, web input, networking and pairing
### Apple PencilKit stroke model

**What it is.** PencilKit is Apple's drawing framework; its data model `PKDrawing` is an array of `PKStroke` values, each with an ink, transform, optional mask and a `PKStrokePath` that WWDC20 describes as "a uniform cubic B-spline" of stroke points ([verified](https://developer.apple.com/videos/play/wwdc2020/10148/)). `PKDrawing` "is the one piece of PencilKit that is available on macOS" (macOS 10.15+), and `PKStroke`, `PKStrokePath` and `PKStrokePoint` are macOS 11.0+ ([verified](https://developer.apple.com/videos/play/wwdc2019/221/)).

**What it does well that we lack.**
- Time-lapse replay: `PKStrokePath` exposes `interpolatedPoints(by:)` and `parametricValue(_:offsetBy:)`, and WWDC20 shows animating "with the same velocity as when the user drew it". Daylight's strokes JSON already stores per-point `tMs`, so a Mac app time-lapse export (video or GIF) of a saved page needs no new data ([verified](https://developer.apple.com/videos/play/wwdc2020/10148/)).
- Apple-quality renderer on the Mac: `PKDrawing` has a macOS `image(from:scale:)` returning `NSImage`, and drawings are value types so rendering can run off the main thread. The Mac app could offer it as an optional "nicer ink" renderer for the saved PNG, pen to `.monoline` or `.pen`, highlighter to `.marker` ([verified](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkdrawing-swift.struct.json)).
- Point model is a superset of ours: `PKStrokePoint(location:timeOffset:size:opacity:force:azimuth:altitude:...)`; `timeOffset` maps to `tMs / 1000`, but `force` treats 1.0 as "the force of an average touch", so our 0..1 pressure needs a chosen rescale ([verified](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkstrokepoint-swift.struct.json)).
- Optional tilt: PencilKit points carry altitude and azimuth; adding optional tilt to the protocol and JSON (the web page already logs `tiltX/tiltY` on first contact, but SolStream-v1 points carry only x, y, pressure, delta_ms) would let any future renderer use it ([verified](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkstrokepoint-swift.struct.json)).
- Official import recipe: "Importing external drawing data into PencilKit" suggests "reasonable values" for missing orientation (example `altitude: .pi / 4`) and warns "the conversion is an approximation" ([verified](https://developer.apple.com/tutorials/data/documentation/pencilkit/importing-external-drawing-data-into-pencilkit.json)).
- Highlighter compositing: `renderGroupID` makes marker strokes look "as if they were drawn while the previous stroke with the same ink was still wet" ([verified](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkstroke-swift.struct.json)).

**What it does badly, or what to avoid.**
- No eraser ink type; erasing is the destructive `erasingPath(_:mask:transform:)`, so keep Daylight's JSON as the source of truth and `PKDrawing` only as a derived render ([verified](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkinkingtool-swift.struct/inktype-swift.enum.json)).
- Points are "stored in a lossily compressed format": never round-trip a `.drawing` back into our JSON ([verified](https://developer.apple.com/videos/play/wwdc2020/10148/)).
- `PKCanvasView` lists iOS, Mac Catalyst and visionOS but no native macOS, so PencilKit cannot be a live inking surface in the Mac app ([verified](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkcanvasview.json)).

**Code or protocol level.**
- Conversion sketch: per stroke `PKStrokePath(controlPoints:creationDate:)` with `PKStrokePoint(timeOffset: tMs/1000, force: pressure * k, azimuth: 0, altitude: .pi/4 ...)`, eraser applied via `erasingPath` in replay order ([verified](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkstrokepath-swift.struct.json)).
- `requiredContentVersion` / `PKContentVersion.version2` flags drawings needing a newer OS; relevant only if we export `dataRepresentation()` ([verified](https://developer.apple.com/tutorials/data/documentation/pencilkit/supporting-backward-compatibility-for-ink-types.json)).
- PaperKit (WWDC25), the markup model "used in apps like Notes, Screenshots, QuickLook, and the Journal app", is offered on macOS: a possible future route to Apple-native board files ([verified](https://developer.apple.com/videos/play/wwdc2025/285/)).

**License and reuse.** Apple system framework with no open-source license; linking it from an Apache-2.0 app is fine, but write our own conversion code rather than pasting sample code ([verified](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkdrawing-swift.struct.json)).

**Relevance: medium.** A free Apple renderer and replay model for the strokes JSON Daylight already saves, but not a live inking surface on macOS.

Already in Daylight: PNG rendered from the stroke model at 1200x1600 with highlighter multiply, and per-point `tMs` in the JSON (SPEC.md section 12).

### Microsoft ISF and W3C InkML

**What it is.** Ink Serialized Format (ISF) is Microsoft's binary ink container, "the most compact persistent representation of ink", embeddable in a GIF ([verified](https://github.com/MicrosoftDocs/windows-uwp/blob/docs/uwp/ui-input/save-and-load-ink.md)). dotnet/wpf (MIT) holds a full ISF reader and writer of about 9,200 lines ([verified](https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/PresentationCore/MS/internal/Ink/InkSerializedFormat/Codec.cs)). InkML is the W3C XML ink format, parsed by Wacom's Apache-2.0 universal-ink-library ([verified](https://github.com/Wacom-Developer/universal-ink-library/blob/main/uim/codec/parser/inkml.py)).

**What it does well that we lack.**
- Image with ink inside: `InkPersistenceFormat` includes GIF and base64 "fortified GIF", so non-ink apps show a picture and ink apps get strokes. Daylight analogue for the Mac app: embed the strokes JSON in a PNG text chunk so one saved file is both a shareable image and a re-editable board ([verified, analogy](https://github.com/MicrosoftDocs/windows-uwp/blob/docs/uwp/ui-input/save-and-load-ink.md)).
- Varint with sign in the low bit: 7 bits per byte with a 0x80 continuation, `SignEncode` stores `(-v<<1)|1` or `v<<1` (zigzag-like). Useful if the saved strokes ever need a binary form; gzip of the JSON is the cheap first step ([verified: dotnet/wpf `MultiByteCodec.cs`](https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/PresentationCore/MS/internal/Ink/InkSerializedFormat/MultiByteCodec.cs)).
- Delta-delta transform: `DeltaDelta.Transform` computes `data + d_{i-2} - 2*d_{i-1}` with a long intermediate and an "extra" word on Int32 overflow; pairs with the varint for compact on-disk points ([verified: dotnet/wpf `Codec.cs` lines 74-96](https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/PresentationCore/MS/internal/Ink/InkSerializedFormat/Codec.cs)).
- InkML export: `traceFormat` channels and `<trace>` elements with single-difference (`'`) and second-difference (`"`) prefixes give a Mac app "Export strokes as InkML" (X, Y, F, T channels) for interoperability ([verified: universal-ink-library `inkml.py`](https://github.com/Wacom-Developer/universal-ink-library/blob/main/uim/codec/parser/inkml.py)).
- Codec byte with fallback: Huffman or Gorilla bit-packing, recompressing with Gorilla when Huffman output is larger ([verified: dotnet/wpf `AlgoModule.cs` lines 77-130](https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/PresentationCore/MS/internal/Ink/InkSerializedFormat/AlgoModule.cs)).

**What it does badly, or what to avoid.**
- Legacy complexity: Huffman, LZ, Gorilla, transform and metric tables in about 9,200 lines; if compressing, copy only varint plus delta-delta ([verified](https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/PresentationCore/MS/internal/Ink/InkSerializedFormat/AlgoModule.cs)).
- Asymmetric formats: "GIF is the only file format supported for saving ink data" while loading reads more ([verified](https://github.com/MicrosoftDocs/windows-uwp/blob/docs/uwp/ui-input/save-and-load-ink.md)).
- Decoder sharp edge: `MultiByteCodec.Decode` computes its bound from `inputIndex` but indexes from 0; any Daylight varint decoder must be bounds-checked and covered by golden vectors ([verified](https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/PresentationCore/MS/internal/Ink/InkSerializedFormat/MultiByteCodec.cs)).
- Wire compression buys nothing: at roughly 240 points/s, 11-byte SolStream points are about 2.6 KB/s on a LAN, so compress only on disk ([verified](https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/PresentationCore/MS/internal/Ink/InkSerializedFormat/Codec.cs)).

**Code or protocol level.**
- ISF tags: GuidTable=1, DrawingAttributesTable=2, StrokeDescriptorTable=4, Stroke=10, CompressionHeader=14, TransformTable=15, MetricTable=24, plus GUID-keyed custom data ([verified: `ISFTagAndGuidCache.cs` lines 215-238](https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/PresentationCore/MS/internal/Ink/InkSerializedFormat/ISFTagAndGuidCache.cs)).
- OneNote Graph (beta, 2017) reads page ink with `?includeInkML=true` and accepts an `application/inkml+xml` part named `presentation-onenote-inkml`; cloud plus OAuth makes it heavy for Daylight ([snippet](https://devblogs.microsoft.com/microsoft365dev/onenote-ink-beta-apis/)).

**License and reuse.** dotnet/wpf is MIT ([verified](https://github.com/dotnet/wpf/blob/main/LICENSE.TXT)) and universal-ink-library is Apache-2.0 ([verified](https://github.com/Wacom-Developer/universal-ink-library/blob/main/LICENSE)); both are compatible, but the 40-line algorithms are simpler to reimplement.

**Relevance: low.** Compression does not help the LAN wire; the value is a few file-format ideas for the saved board.

Already in Daylight: golden vectors (docs/PROTOCOL.md section 12), versioning rules for compatible additions (section 10), and the `daylight-whiteboard-strokes/1` schema field (SPEC.md section 12).

### Pointer Events, Delegated Ink Trail and WebCodecs

**What it is.** The w3c/pointerevents Level 4 editor's draft defines coalesced and predicted samples, `pointerrawupdate` and pen attributes ([verified](https://github.com/w3c/pointerevents/blob/main/index.html)). The WICG Ink API (a CG draft) lets a page hand the compositor its last rendered point for a "delegated ink trail" ([verified](https://github.com/WICG/ink-enhancement/blob/main/index.bs)), and WebCodecs gives scripts `VideoDecoder`/`VideoEncoder` with latency hints ([verified](https://github.com/w3c/webcodecs/blob/main/index.src.html)).

**What it does well that we lack.**
- Predicted tail for local wet ink: `getPredictedEvents()` (no `[SecureContext]` in the IDL) returns points valid "until the next pointer event is dispatched"; example_13 draws coalesced points as committed ink and predicted points as a temporary tail. Daylight's web page detects `predictedEvents` (web/src/caps.ts) but never draws them: draw the tail on the `wet` canvas, clear it each event, never send it over SolStream ([verified](https://w3c.github.io/pointerevents/#predicted-events)).
- Delegated ink trail: `navigator.ink.requestPresenter({presentationArea})`, then `updateInkTrailStartPoint(event, {color, diameter})` per move; the trail lasts "for the duration of the next animation frame", needs a trusted event and `diameter` > 0. Not in web/src today; feature-detect, try/catch and measure on the DC-1 ([verified](https://wicg.github.io/ink-enhancement/)). Support is Chrome 94+, Edge 93+, not Safari ([snippet](https://caniuse.com/mdn-api_delegatedinktrailpresenter)).
- Pen eraser button: the buttons table lists "Pen eraser button" = 32. The web page routes erasing only by toolbar tool (web/src/ink.ts) while Android already routes `TOOL_TYPE_ERASER`; `(e.buttons & 32)` would switch the contact to the eraser ([verified](https://w3c.github.io/pointerevents/#the-buttons-property)).
- Pen attributes: `twist` [0,359], `altitudeAngle` [0, pi/2], `azimuthAngle` [0, 2pi], and example_6 converts tilt to altitude/azimuth; SolStream-v1 points carry no tilt, so this fits a future compatible protocol addition ([verified](https://w3c.github.io/pointerevents/#pointerevent-interface)).
- WebCodecs low-latency decode: `optimizeForLatency`, annexb H.264, `latencyMode: "realtime"`; relevant only to a hypothetical browser viewer, since the Mac decodes mirror H.264 natively ([verified](https://github.com/w3c/webcodecs/blob/main/index.src.html)).

**What it does badly, or what to avoid.**
- Hints are hints: `desynchronized` "may" bypass and "might introduce visible tearing artifacts", and hardware overlays cannot alpha-blend on Windows. Daylight's page stacks three canvases (highlight, ink, wet), so measure on the DC-1 rather than promise a number ([verified](https://html.spec.whatwg.org/multipage/canvas.html#concept-canvas-desynchronized)).
- `pointerrawupdate` listeners "might negatively impact the performance" ([verified](https://w3c.github.io/pointerevents/)).
- Predicted points are guesses; sending them would corrupt saved strokes ([verified](https://w3c.github.io/pointerevents/#predicted-events)).
- Delegated ink is a CG draft, not a standard ([verified](https://github.com/WICG/ink-enhancement/blob/main/index.bs)).

**Code or protocol level.**
- example_13 in [`pointerevents/index.html`](https://github.com/w3c/pointerevents/blob/main/index.html) (line 1934): predicted tail on a wet layer; example_6 (line 621): tilt to altitude/azimuth ([verified](https://github.com/w3c/pointerevents/blob/main/index.html)).
- [`ink-enhancement/index.bs`](https://github.com/WICG/ink-enhancement/blob/main/index.bs) lines 134-150: `requestPresenter` then `updateInkTrailStartPoint(event, {color, diameter: event.pressure * 4})` after the coalesced render loop ([verified](https://github.com/WICG/ink-enhancement/blob/main/index.bs)).

**License and reuse.** The W3C and WICG repos use the W3C Software and Document License (permissive, examples reusable with notice); whatwg/html is CC BY 4.0 with code portions under BSD 3-Clause ([verified](https://github.com/whatwg/html/blob/main/LICENSE)).

**Relevance: medium.** Daylight already uses the core latency APIs; what remains is the predicted tail, delegated trail, eraser button and tilt.

Already in Daylight: one point per coalesced event, feature-detected `pointerrawupdate`, `desynchronized: true` contexts (web/src/ink.ts), a secure origin via `adb reverse` to `http://localhost:7788`, an insecure-origin diagnostics hint and an `isSecureContext` capability report.

### WebRTC data channels, WebTransport and UDP input

**What it is.** Three transport families for live pen points: unordered, partially reliable WebRTC data channels (`RTCDataChannelInit { ordered; maxPacketLifeTime; maxRetransmits }`) ([verified](https://github.com/w3c/webrtc-pc/blob/main/index.html)), WebTransport datagrams over QUIC with a `sendOrder` attribute ([verified](https://github.com/w3c/webtransport/blob/main/index.bs)), and native UDP input as in Moonlight/Sunshine (ENet). The reference point is Daylight's SolStream-v1 WebSocket over TCP.

**What it does well that we lack.**
- Measure first: a per-connection stall metric in the Mac app Diagnostics (largest and p99 gap between STROKE_CHUNK arrivals within a stroke) would show whether TCP head-of-line stalls happen on the DC-1 at all; today there is only the one-shot `--latency-probe` (docs/PERFORMANCE.md) ([verified, as motivation](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/InputStream.c)).
- Per-message reliability on one connection: Moonlight's `LiSendPenEvent` sends pen MOVE and HOVER unreliable and down, up, cancel or button changes with `ENET_PACKET_FLAG_RELIABLE`. A Daylight analogue matters only if a datagram path is added: live points droppable, STROKE_START and COMMIT reliable ([verified: moonlight-common-c `src/InputStream.c` line 1401](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/InputStream.c)).
- Drop-older coalescing: a queued batchable pen motion packet is replaced by a newer one (`TOUCH_EVENT_IS_BATCHABLE`) ([verified: `InputStream.c` lines 47, 469](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/InputStream.c)).
- No dependency needed on macOS: Network.framework offers `NWProtocolUDP` (macOS 10.14+) and `NWProtocolQUIC` (macOS 12+), so a native UDP live-point path for Daylight Ink needs no third-party library on macOS 14 ([verified](https://developer.apple.com/documentation/network/nwprotocoludp)).
- Unsequenced side messages: control messages sent with `ENET_PACKET_FLAG_UNSEQUENCED` ([verified: `src/ControlStream.c` line 1412](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/ControlStream.c)).

**What it does badly, or what to avoid.**
- Moonlight's pen packet is "a protocol extension only supported with Sunshine" on hand-built ENet plumbing: a custom UDP protocol is a two-ended maintenance burden ([verified](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/InputStream.c)).
- Weylus, a shipping browser-tablet-to-desktop pen product, uses WebSocket (`fastwebsockets`) with no `nodelay` setting: TCP is acceptable, so measure before replacing it ([verified](https://github.com/H-M-H/Weylus/blob/master/src/websocket.rs)).
- WebTransport is a poor fit for the web page: `serverCertificateHashes` allows self-signed servers, but the interfaces are `[SecureContext]` and `http://<mac-ip>:7788` is not a secure context ([verified](https://github.com/w3c/webtransport/blob/main/index.bs)).

**Code or protocol level.**
- Optional UDP channel for Daylight Ink only: `NWListener` with `NWProtocolUDP` on the Mac, `DatagramSocket` on Android, each packet carrying stroke id, sequence and the last 2 to 3 points again so one loss costs nothing; commits stay on the WebSocket. Build only if the stall metric justifies it ([verified basis](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/InputStream.c)).
- WebRTC `ordered` and `maxRetransmits` (webrtc-pc index.html lines 15161-15168) would need a WebRTC stack in the Swift app; not recommended for v1 ([verified](https://github.com/w3c/webrtc-pc/blob/main/index.html)).

**License and reuse.** moonlight-common-c and Sunshine are GPL-3.0 ([verified](https://github.com/moonlight-stream/moonlight-common-c/blob/master/LICENSE.txt)) and Weylus is AGPL-3.0-or-later ([verified](https://github.com/H-M-H/Weylus/blob/master/LICENSE)); none may be copied into Apache-2.0 Daylight, so reimplement from the idea.

**Relevance: low.** Daylight already has the cheap wins, so what remains is a measurement and an optional UDP path that should wait for data from the real DC-1.

Already in Daylight: TCP noDelay on the Mac (WebServer.swift) and Android (NoDelaySocketFactory.kt, SPEC D49), one flush per display frame (requestAnimationFrame on the web page, Choreographer on Android), and `getCoalescedEvents`.

### mDNS and zero-config discovery (LocalSend, Syncthing, KDE Connect)

**What it is.** Consumer zero-config discovery is a ladder: multicast announce (LocalSend 224.0.0.167, Syncthing port 21027, KDE Connect UDP 1716 plus `_kdeconnect._udp`), then an HTTP subnet probe, then typed addresses or non-LAN layers ([verified](https://github.com/localsend/protocol/blob/main/README.md)). Apple gates local network traffic behind a user permission on macOS 15+ ([verified](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)), and Android apps targeting API 37 "generally require" `ACCESS_LOCAL_NETWORK` ([verified](https://developer.android.com/reference/android/net/nsd/NsdManager)).

**What it does well that we lack.**
- Local Network privacy handling in the Mac app: every Bonjour register, browse and resolve needs access, but "Listening for and accepting incoming TCP connections" does not. If the owner denies it, `:7788` still serves the web page and Tailscale clients; only Bonjour (and Daylight Ink auto-discovery) stops, which answers LOOSE_ENDS C4. Explain before the first registration, detect `kDNSServiceErr_PolicyDenied` (-65570) and `localNetworkDenied` on the bundled `adb connect` (charged to Daylight as "responsible code"), and add a failure row saying the URL and USB still work ([verified](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)).
- Firewall failure row: LocalSend says "This is most likely a firewall issue..." with an "Open Firewall" button that opens `x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall` on macOS 13+; Daylight's SPEC 13.3 has no firewall case ([verified](https://github.com/localsend/localsend/blob/main/app/macos/Runner/Utilities.swift)).
- Re-discover on network change: KDE Connect re-broadcasts and restarts mDNS in `onNetworkChange()`. Daylight Ink registers no `NetworkCallback` and the Mac has no `NWPathMonitor` to refresh the menu URL ([verified](https://github.com/KDE/kdeconnect-kde/blob/master/core/backends/lan/lanlinkprovider.cpp)).
- Staged discovery: `discover_staged` announces and probes favorites, waits a grace period (1 s in the app) and scans the subnet only if nothing confirmed. For the tablet app on multicast-filtered Wi-Fi: probe `/healthz` across a netmask-derived, capped range, remembered host first ([verified](https://github.com/localsend/localsend/blob/main/packages/core/src/discovery/mod.rs)).
- Modern NSD: `registerServiceInfoCallback` (T extensions 22, all Android 14+) "combines discovery and resolution" and returns all host addresses, fixing the fe80:: skip in LOOSE_ENDS D11 ([verified](https://developer.android.com/reference/android/net/nsd/NsdManager)).
- Short verification code: KDE Connect shows the first 8 hex chars of SHA-256 over both sorted public keys plus the pairing timestamp ([verified](https://github.com/KDE/kdeconnect-kde/blob/master/core/backends/pairinghandler.cpp)).

**What it does badly, or what to avoid.**
- Multicast failure looks like "nobody there"; LocalSend falls back to legacy HTTP scanning ([verified](https://github.com/localsend/protocol/blob/main/README.md)), and its scan is /24-only (`0..=255`), so derive ranges from the real netmask ([verified](https://github.com/localsend/localsend/blob/main/packages/core/src/discovery/mod.rs)).
- No scan helps on client-isolated Wi-Fi, which "prevents devices from communicating"; after one scan, point to USB or Tailscale ([snippet](https://support.google.com/chromecast/answer/3294846)).
- Syncthing global discovery depends on a throttling server (429, `Retry-After`): no cloud rendezvous for Daylight ([verified](https://github.com/syncthing/syncthing/blob/main/lib/discover/doc.go)).

**Code or protocol level.**
- TN3179: no API reports the permission; macOS may deny "before the user has responded to the alert"; identity is by code signature (ad hoc builds unreliable); no reset on macOS, so test in a VM or new account ([verified](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)).
- API 37 adds `FLAG_SHOW_PICKER` and `FAILURE_PERMISSION_DENIED`; Daylight Ink targets SDK 33, so this waits for a target bump ([verified](https://developer.android.com/reference/android/net/nsd/NsdManager)).

**License and reuse.** LocalSend is Apache-2.0 ([verified](https://github.com/localsend/localsend/blob/main/LICENSE)); Syncthing is MPL-2.0 ([verified](https://github.com/syncthing/syncthing/blob/main/LICENSE)) and KDE Connect is GPL ([verified](https://github.com/KDE/kdeconnect-kde/blob/master/core/backends/pairinghandler.cpp)), so reimplement their ideas.

**Relevance: high.** Local Network privacy on macOS 15+ and multicast-filtered office Wi-Fi are Daylight's top pairing risks, and TN3179 gives exact, testable rules.

Already in Daylight: remembered host and loopback candidates, typed address field, `adb reverse` for ink, Tailscale first, the "Office networks often block this" row, serialized resolves, MulticastLock handling, `NSLocalNetworkUsageDescription` and `NSBonjourServices`, and a busy-port walk 7788 to 7799.

### Quick Share (NearDrop), UKEY2, Handoff and adb pair

**What it is.** Quick Share is Google's peer-to-peer transfer protocol; on a LAN the receiver advertises `_FC9F5ED42C8A._tcp.`, the sender connects over TCP, runs a UKEY2 handshake and both screens show a 4-digit PIN ([verified](https://github.com/grishka/NearDrop/blob/master/PROTOCOL.md)). NearDrop is an Unlicense macOS client and google/ukey2 is the Apache-2.0 reference handshake ([verified](https://github.com/google/ukey2/blob/master/README.md)).

**What it does well that we lack.**
- Short code bound to the key exchange: `pinCodeFromAuthKey` folds the 32-byte UKEY2 auth string into 4 digits (multiplier 31, mod 9973, `%04d`), so a LAN attacker in the middle gets mismatched codes. Daylight analogue: a code on the Mac app Allow panel and the tablet chip so the click approves a specific tablet; a cheap first step derives it from the tablet's clientId ([verified: NearDrop `NearbyShare/NearbyConnection.swift` lines 307-321](https://github.com/grishka/NearDrop/blob/master/NearbyShare/NearbyConnection.swift)).
- Separate secrets: the auth string and session secret are distinct HKDF outputs ("UKEY2 v1 auth", "UKEY2 v1 next"), and knowing one does not reveal the other. Never display a bearer token such as Daylight's clientId directly (LOOSE_ENDS C6) ([verified](https://github.com/google/ukey2/blob/master/README.md)).
- Commit-then-reveal: the client commits to a hash of its ClientFinished and the server checks `cipherCommitment==Data(sha.finalize())`, which is what makes a short code safe against key grinding ([verified: `InboundNearbyConnection.swift` line 224](https://github.com/grishka/NearDrop/blob/master/NearbyShare/InboundNearbyConnection.swift)).
- The UKEY2 spec says the auth string "can be short (e.g., a 6 digit visual confirmation code)" ([verified](https://github.com/google/ukey2/blob/master/README.md)).
- Android wireless debugging shows a pairing code on the device and later "will automatically connect to the workstation" on a trusted network ([verified](https://developer.android.com/tools/adb)).
- Handoff trust is account based (same Team ID) ([verified](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/Handoff/HandoffFundamentals/HandoffFundamentals.html)); Daylight has no shared account, so its analogue stays "one Allow, remembered".

**What it does badly, or what to avoid.**
- Android advertises its mDNS service only after a BLE advertisement that "can't be sent from macOS": never depend on a hidden radio side channel ([verified](https://github.com/grishka/NearDrop/blob/master/PROTOCOL.md)).
- The protocol is reverse engineered and carries "TODO: figure out why this sometimes fails" ([verified](https://github.com/grishka/NearDrop/blob/master/PROTOCOL.md)).
- The 4-digit PIN is about 13 bits and safe only because of the commitment: a short code without commit-reveal is guessable ([verified](https://github.com/grishka/NearDrop/blob/master/NearbyShare/NearbyConnection.swift)).
- Handoff's zero-prompt model needs the same Apple ID plus Bluetooth; Daylight cannot copy it ([snippet](https://support.apple.com/en-gw/guide/mac-help/hand-off-between-devices-mchl732d3c0a/13.0/mac)).

**Code or protocol level.**
- NearDrop implements UKEY2 in CryptoKit (P-256 ECDH, HKDF-SHA256). A Daylight version over the WebSocket would exchange P-256 keys with a commitment and derive a 4 to 6 digit code over the transcript; without TLS (LOOSE_ENDS C3) the key must also authenticate later frames, or the code proves identity only at pairing time ([verified](https://github.com/grishka/NearDrop/blob/master/NearbyShare/NearbyConnection.swift)).
- NearDrop reads TXT key `n` for peer name via `NWBrowser(for: .bonjourWithTXTRecord(...))`; Daylight's TXT already carries `v`, `ws`, `port`, so a pairing-state flag is optional polish ([verified](https://github.com/grishka/NearDrop/blob/master/NearbyShare/NearbyConnectionManager.swift)).

**License and reuse.** NearDrop is Unlicense, reusable after checking generated protobuf headers ([verified](https://github.com/grishka/NearDrop/blob/master/UNLICENSE)); google/ukey2 is Apache-2.0, compatible with NOTICE kept ([verified](https://github.com/google/ukey2/blob/master/LICENSE)).

**Relevance: medium.** A short, derived confirmation code beside the one-click Allow is the one new idea; Quick Share interop is fragile and the rest Daylight already has.

Already in Daylight: "Forget this tablet" list, remembered per-tablet trust (clients.json), typed-URL fallback, `adb tcpip` behind a toggle instead of adb pair, and the device name in the Bonjour instance name.

## Method and limits

- **Targets (45 reports).** scrcpy (product), scrcpy and sndcpy latency internals, Vysor, Genymotion with scrcpy GUIs (QtScrcpy, Escrcpy), Apple Sidecar with Weylus and Deskreen, Astropad and Luna Display, Duet Display, reMarkable with rmview, reStream and goMarkableStream, Supernote, Boox, Wacom; OBS camera extension, OBS virtual camera UX, open-source virtual cameras (pyvirtualcam, akvirtualcamera, Apple's CMIO sample), Reincubate Camo, Camo onboarding and pairing, Continuity Camera and Desk View, Krisp, Hand Mirror with OverSight, Rectangle and menu-bar conventions, Elgato Stream Deck; Zoom, Microsoft Teams, Google Meet, Prezi Video, mmhmm, Around, Loom, Tella, Descript, Ecamm Live, Streamlabs; Excalidraw, tldraw, perfect-freehand, Freeform, Miro, FigJam, GoodNotes and Notability; PencilKit, Microsoft ISF and InkML, W3C Pointer Events and WebCodecs, WebRTC data channels, mDNS zero-config (LocalSend, Syncthing, KDE Connect), Google Nearby and Apple Handoff pairing.
- **Process.** One research agent per target with a fixed template; eight verification agents, each owning a group, re-opened the sources, dropped what did not hold, and checked every idea against the Daylight tree; writer agents condensed the verified reports into the sections above; the coordinator ranked and wrote the tables.
- **Network limits.** The environment allowed `git clone` of public GitHub repositories, raw.githubusercontent.com, developer.apple.com, developer.android.com, gitlab.com, npm and PyPI, and blocked most other sites. Closed products (Camo, Ecamm, Loom, Astropad, Duet, Zoom's and Microsoft's support pages) are therefore mostly snippet level here. Before building a snippet-level idea, open its source on a normal network.
- **Nothing was run.** No product was installed or measured; latency and quality numbers quoted from other products are their claims, not ours. Daylight's own numbers wait for the owner's measurement plan in `docs/COMPARE.md`.
