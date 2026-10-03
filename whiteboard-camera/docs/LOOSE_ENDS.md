# Loose ends

Everything that is not settled by `SPEC.md`, `docs/ARCHITECTURE.md` or `docs/PROTOCOL.md`, with an owner and a concrete next step. Owners: `Mike` (the owner, needs a decision, an account action or a device), `M1` to `M7` (an implementation milestone, see ARCHITECTURE section 12), `v1.1` or `v2` (after the first notarized release). Items marked `Device` can only be answered with the DC-1 in hand and are also listed in `docs/TESTING-CHECKLIST.md`.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming.

---

## A. Owner actions (Mike)

| # | Item | Next step |
|---|---|---|
| A1 | Apple signing checklist (Developer ID Application certificate, App IDs `com.twelve.daylight` with System Extension and App Groups ticked and `com.twelve.daylight.camera` with App Groups, two Developer ID profiles named "Daylight Developer ID" and "Daylight Camera Developer ID", App Store Connect API Team Key). Nothing camera-related can be seen in Zoom before this. | Follow `docs/SIGNING.md` section "Owner checklist" (about 30 minutes, any Mac with Keychain Access, no Xcode); add the eight secrets with `gh secret set`; re-run CI; download `Daylight.dmg`. |
| A2 | Which macOS runs on the new M5 Max (15 or 26)? Decides which approval-pane wording the onboarding shows first and which runner image mirrors the owner's machine. | Tell the integrator; the default wording is the macOS 15/26 path. |
| A3 | Confirm the Android package name `com.twelve.daylight.ink` before the first APK is sideloaded (changing it later means uninstall and re-pair). | One line of approval, or a different name before M4. |
| A4 | Confirm three product defaults the designs disagreed on: eraser contact does NOT engage from camera (Settings toggle `engageOnEraser`, default off); pen side button long press (700 ms) = Clear and double press = Pin (swappable); a Wi-Fi blip never yanks the board away (disconnect leaves the governor alone). | Approve or flip each default before M3 (eraser), M5 (side button). |
| A5 | Approve the one-time `chrome://flags/#unsafely-treat-insecure-origin-as-secure` paste as an optional onboarding step for wireless web use (the alternative is to wait for Tailscale HTTPS, item C3). | Yes / no; the Mac shows the exact string either way. |
| A6 | Legal read of Google's Android SDK License sections 3.4 and 3.5 for redistributing the prebuilt `adb` inside Daylight.app (scrcpy and Homebrew do it; we ship Google's NOTICE.txt and the Apache-2.0 text). Alternatives if counsel objects: build adb from AOSP in CI, download platform-tools on first launch after the user accepts Google's terms, or reuse an installed adb. | Decide before the first public release tag. |
| A7 | Access to `makedaylight/dc1caster` (teammate's official Daylight repo) so its `ADBClient`, `H264Decoder` and `WirelessSetup` can be compared with or replace the mirror-mode code. | Request repository access; the integrator then diffs behaviour against `mac/Daylight/Mirror/`. |
| A8 | Android release signing key (the APK is debug-signed in v1; a release key means uninstall and reinstall on every tablet that has the debug build). | Decide when the first non-owner tablet is onboarded; generate the key, add it as secrets, keep the debug build as a separate applicationId suffix if both must coexist. |
| A9 | Mirror mode without USB debugging (owner's loose end): candidate v2 = the Daylight Ink APK captures the screen with MediaProjection and streams H.264 over Wi-Fi with the same 12-byte framing so the Mac demuxer is reused; engage from the APK's own touch events while foreground or from frame differencing; strategic v3 = a Daylight-signed SolOS service exposing stylus state and a screen stream over a local socket with a one-tap trust flow (replaces adb, scrcpy-server and getevent in one move). | Decide after measuring how much mirror mode is used versus the native app (COMPARE.md). The native app is the recommended consumer default. |
| A10 | Merge Twelve's gate and Daylight Camera into one Daylight Mac app; allowlist the camera app in Twelve meeting mode. | After v0.1.0; the `DaylightKit` package and the `Contracts/` protocols are the seam. |
| A11 | Presenter segmentation, Overlay mode, Granola audio-ink sync. | v2; nothing in v1 blocks them (the compositor has one pass with four quads; a fifth quad is cheap). |
| A12 | Should the APK run a permanent companion foreground service (started at boot) so the Mac can raise the pills over Wi-Fi without opening the app, at the cost of a persistent notification on the DC-1? v1: opt-in setting `pillsAtBoot`, default off. | Decide after living with v1 for a week. |
| A13 | Should the Mac flip Android's `stay_on_while_plugged_in` over USB (scrcpy-style, restored on quit) so the tablet never dims in the USB setup? v1: no; the web page uses the wake lock when available and the APK uses `FLAG_KEEP_SCREEN_ON`. | Decide after the first USB session; exact setting value is UNVERIFIED (item D7). |

---

## B. Blocked on the first CI runs (integrator, M0 to M1)

| # | Item | Next step |
|---|---|---|
| B1 | Does `CODE_SIGNING_ALLOWED=NO` build a `system-extension` product? OBS avoids the question. | `mac-build-unsigned.sh` tries it, falls back to ad-hoc `CODE_SIGN_IDENTITY=-` for the extension, then to app-without-extension, and records which path succeeded; update ARCHITECTURE 9.2 after the first green run. |
| B2 | Exact `adb` binary size, `lipo -archs` output (expect `x86_64 arm64`), and whether `platform-tools/NOTICE.txt` is at that path inside `platform-tools_r37.0.0-darwin.zip`. | `fetch-thirdparty.sh` logs `ls -l`, `lipo -archs`, `file`, `unzip -l`; `--self-test` prints them; paste into THIRD_PARTY_NOTICES.md and SPEC 17. Decide whether to move to platform-tools 37.0.1 (hash must be computed on the mac runner). |
| B3 | Is `secrets.X != ''` accepted inside a job-level `env:` expression (GitHub docs blocked here)? | First workflow run validates the YAML; if rejected, switch to a first step that writes `has_signing=true|false` to `$GITHUB_OUTPUT` from env-mapped secrets. |
| B4 | Does the preinstalled Swift 6.4 on `ubuntu-24.04` compile `swift-tools-version:5.9` packages in language mode 5 without warnings-as-errors issues? | `kit-linux` first run; plan B `swift-actions/setup-swift@v2.4.0`. |
| B5 | Does GitHub's macos-15 runner expose a Metal device for `CompositorTests` and the self-test render probes? | The first mac run prints it; if nil, compositing is first tested on the owner's Mac (tests skip with a warning). |
| B6 | Must the nested `Resources/thirdparty/adb` be re-signed for notarization, and does Xcode's expanded identity variable in a `postBuildScripts` step work? | First signed run: `codesign -dvv` on the nested binary and the notarytool log; keep the explicit `codesign` in `mac-archive-export.sh` either way. |
| B7 | `SKIP_INSTALL` default for system-extension targets, `SKIP_INSTALL YES` is set explicitly; confirm the archive exports as a macOS App Archive. | First signed run. |
| B8 | `xcodebuild -help` current `exportOptionsPlist` keys and the `provisioningProfiles` wording. | Saved into `xcodebuild-logs` on the first mac run. |
| B9 | AGP 8.13.2 / Gradle 8.14.5 / Kotlin 2.3.10 build on first try; debug keystore committed. | First android run; plan B AGP 9.0.1 / Gradle 9.1.0 / Kotlin 2.3.20 (the sibling's combination). |
| B10 | `brew install xcodegen` wall-clock on the runner. | Logged; if over two minutes, cache the bottle or use the release zip. |
| B11 | Swift `loadUnaligned(fromByteOffset:as:)` availability is irrelevant because `ByteReader` assembles bytes; confirm no `load(fromByteOffset:)` crept into the kit. | Code review item in M0. |

---

## C. Networking and security follow-ups

| # | Item | Owner | Next step |
|---|---|---|---|
| C1 | Android 11 wireless debugging pairing (`adb pair`, random connection port, mDNS `_adb-tls-connect._tcp`, toggle reset after sleep or reboot on Android 13/14) as a cable-free path. v1 uses `adb tcpip 5555` behind the "Mirror over Wi-Fi" toggle; pairing is documented in SETUP.md only. | v1.1 | Automate `adb mdns track-services` discovery only if the owner uses it; the SolOS service (A9) is the real answer. |
| C2 | Does `adb tcpip 5555` persist across reboot on SolOS, and is there a SolOS property to persist adbd TCP mode (property name UNVERIFIED)? | Device, Mike | Test once; if Daylight owns SolOS, persist it in the OS build. |
| C3 | Secure web context over Wi-Fi without the flag paste: Tailscale HTTPS (`tailscale cert <node>.<tailnet>.ts.net`), TLS on the Mac listener (`NWParameters(tls: NWProtocolTLS.Options(), tcp:)` with `sec_protocol_options_set_local_identity`), `wss://` for the socket, MagicDNS URL shown in the menu. | v1.1 | Prototype after v0.1.0; keep plain http as the degraded mode. |
| C4 | Does macOS 15 show the Local Network privacy prompt for an app that only advertises a Bonjour listener? `NSLocalNetworkUsageDescription` and `NSBonjourServices` are included regardless. | M3 (owner's Mac) | Observe on first launch; add onboarding text if a prompt appears. |
| C5 | Two adb servers (the owner's on 5037 and ours on a private port) holding TCP transports to the same DC-1; which one wins the USB interface in practice. | Device | Checklist item; failure row 24 covers the visible effect. |
| C6 | Trust model is "one click on the Mac, remembered forever by clientId"; a clientId is a bearer token on the LAN. Acceptable per the owner's priority (D12). | v2 | Revisit with TLS (C3): bind the clientId to a TLS client certificate or a Tailscale identity. |
| C7 | Protocol-level rate limiting beyond the 4096 / 1024 caps and the 1 MiB payload cap (a hostile LAN client can still send 1 MiB frames at line rate). | v1.1 | Add a per-connection byte budget if ever needed; decode cost is bounded today. |

---

## D. Device facts to collect on the DC-1 (all `Device`; owner runs `docs/TESTING-CHECKLIST.md`)

| # | Item | Why it matters | How to collect |
|---|---|---|---|
| D1 | Wacom evdev node: name, `/dev/input/eventN`, `ABS_X/Y/PRESSURE` ranges, presence of `ABS_DISTANCE` and tilt, whether `BTN_STYLUS` / `BTN_STYLUS2` are reported under SolOS. | mirror-mode engage and the pen-button Pin/Clear | `adb shell getevent -pl` once; paste into COMPARE.md; the Mac logs it too (row 28). |
| D2 | `Build.MODEL` string, `getprop ro.build.version.release` (expect 13), `wm size`, `wm density`. | device heuristics, mirror label, canvas mapping | `adb shell` commands in the checklist. |
| D3 | Stylus pressure range in Android (0..1 or raw 0..4095) and in Chrome (can it exceed 1.0?). | both quantisers clamp and normalise; confirms no wrapped u8 | first stroke logs raw values in the APK and in the web console. |
| D4 | Which button the pen's side button is on Android (`BUTTON_STYLUS_PRIMARY` or `SECONDARY`) and what Chrome reports for it (source says left button, `buttons 1`, pressure 0 while hovering). | web pressure-0 rule; APK barrel handling | APK logs `actionButton`; web console logs `button/buttons/pressure` on pointerdown. |
| D5 | Do the overlay pills appear inside the scrcpy mirror, and where exactly? | the default 96 px top crop | mirror the tablet with pills on; adjust `mirrorCropInsetsPortrait` in Settings. |
| D6 | Does "Disable adb authorization timeout" exist on SolOS, and does the 7-day revocation apply? | "never again" for mirror mode | wait 8 days after onboarding, or check Developer options. |
| D7 | Exact value for `settings put global stay_on_while_plugged_in` on SolOS and whether SolOS exposes a screen-timeout setting we should respect. | A13 | only if A13 is approved. |
| D8 | Chrome version on the DC-1, `devicePixelRatio`, CSS viewport in portrait; does Chrome resolve `<mac>.local` over Wi-Fi; does a legacy Add to Home screen shortcut honour `display: fullscreen` on a non-secure origin. | web onboarding text | the Start overlay shows these in its expanded card; owner reports them. |
| D9 | Does the DC-1's digitizer suppress finger touch while the pen is in range, and does SolOS palm rejection ever cancel the PEN pointer? | `pointercancel` handling | draw with the palm resting; watch for cancelled strokes. |
| D10 | Which app handles `android.intent.action.VIEW` for `http://` on SolOS. | USB "Open on the tablet" | the first `am start` run. |
| D11 | DC-1 Tethering module T extension version (`SdkExtensions.getExtensionVersion(TIRAMISU)`), deciding the multicast lock and the modern NSD API. | APK discovery | the APK logs it at start. |
| D12 | Measured end-to-end getevent latency over USB and over Wi-Fi debugging; does device-side getevent exit when the adb shell child is killed. | mirror engage budget; process hygiene | `-t` stamps versus arrival time in the Mac log; `adb shell ps` after quitting Daylight. |
| D13 | Does the DC-1's H.264 encoder ever emit B-frames or reorder PTS? | decode order equals display order assumption | `--perf-log` logs out-of-order PTS if any. |
| D14 | Front-buffer rendering (graphics-core 1.0.4) on the DC-1; 1.0.2 is proven by the sibling app. | wet ink latency | APK settings toggle "Front buffer"; compare. |
| D15 | Whether `adb shell am start-foreground-service` from the shell bypasses background-start restrictions and whether `appops set ... SYSTEM_ALERT_WINDOW allow` flips `Settings.canDrawOverlays` on SolOS. | USB pills onboarding | first USB onboarding run. |
| D16 | Measured Activity Monitor numbers (Passthrough, Studio Split, idle) and the engage latency probe on the M5 Max. | PERFORMANCE.md; whether to enable `frameReuse` and `deadlineIdle` | checklist items in M6. |

---

## E. Mac-side UNVERIFIED items carried with a runtime check or fallback

| # | Item | Fallback in place |
|---|---|---|
| E1 | `consumeSampleBuffer` completion semantics on an empty queue (spin risk with the recursive loop). | OBS 90 Hz timer is the default; recursion is a compile-time option. |
| E2 | Which `kCMIOStreamPropertyDirection` value identifies the sink. | both values logged; index 1 fallback as OBS and ldenoue. |
| E3 | Whether `CMIOObjectAddPropertyListenerBlock` fires for the custom viewers property. | 1 Hz poll always on. |
| E4 | macOS `AVCaptureVideoDataOutput` BGRA buffers are IOSurface-backed and 1920x1080 for the owner's webcam. | first-frame check; Metal blit or CIContext fallback; row 5. |
| E5 | How the macOS session reconciles an explicit `activeFormat` with a non-matching preset (the inputPriority preset is iOS-only); whether `kCVPixelBufferWidthKey/HeightKey` are honoured in `videoSettings`. | 1080p preset plus frame-duration pinning; width/height keys not used; letterbox whatever arrives. |
| E6 | `AVCaptureSession.synchronizationClock` equals the host clock. | restamp with the host clock. |
| E7 | AVFoundation removing a disconnected device's input itself. | removed explicitly. |
| E8 | Metal validation "IOSurface textures must use MTLStorageModeManaged" on macOS 14/15. | storage mode left at the default; `InkRasterizerTests` would crash loudly. |
| E9 | CGBitmapContext row order and the y-flip. | `InkRasterizerTests` dot test. |
| E10 | Extra CPU/GPU synchronisation for managed IOSurface textures on Intel Macs. | Intel is not a target; Apple silicon first. |
| E11 | Whether a viewer sees a frozen frame or the placeholder during the capture restart after the idle rule. | the host pushes the cached frame immediately on restart (ARCHITECTURE 3.3). |
| E12 | Frame reuse (re-enqueueing the same CVPixelBuffer with a new PTS) is accepted by CMIO and viewer apps. | flag default off. |
| E13 | System Settings URL for the Camera Extensions approval pane on macOS 15+; `isTemplate` for the status bar icon. | text path is authoritative; `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` is tried as a convenience. |
| E14 | `NSPanel` `.nonactivatingPanel` spelling and behaviour for the Allow panel in an LSUIElement app. | standard AppKit; first owner run confirms Zoom keeps focus. |
| E15 | `application/vnd.android.package-archive` as the APK MIME type Chrome needs to offer Install. | conventional; `Content-Disposition: attachment` added. |
| E16 | Hand-written RFC 6455 upgrade accepted by Chrome and OkHttp exactly. | `WebServerLoopbackTests` and `--self-test` with `URLSessionWebSocketTask`; fallback B (second listener with `NWProtocolWebSocket`) needs owner sign-off because it breaks the one-port wording. |
| E17 | 2 MiB WebSocket frame cap before fragment reassembly versus Chrome's default send chunking. | no shipping client fragments; the cap is enforced per frame and per message. |

---

## F. Protocol and product polish deferred

| # | Item | Owner |
|---|---|---|
| F1 | Ink-triggered early frame (render immediately when a chunk arrives in LIVE and the last frame left more than 16 ms ago) to cut the median engage latency by about 10 ms. | v1.1 |
| F2 | 420v two-plane VideoToolbox output with a BT.601 limited-range matrix in the shader (halves mirror decode memory traffic); needs the colour matrix the DC-1 encoder tags (UNVERIFIED). | v1.1 |
| F3 | Laser pointer rendering (LASER_POINT is accepted and counts as activity, not drawn). | v1.1 |
| F4 | Reopen the last page on launch; a strokes gallery beyond the Finder folder. | v2 |
| F5 | Draggable pills and a bottom position preset beyond the `pillsPosition` setting. | v1.1 |
| F6 | Catmull-Rom smoothing (approach B) instead of per-segment straight lines with round caps (approach A ships first). | v1.1, after the owner looks at the ink |
| F7 | Highlighter on the tablet is drawn with simple alpha locally (the Mac is the source of truth for the multiply). | v1.1 |
| F8 | Motion prediction on the tablet (`androidx.input:input-motionprediction 1.0.0`), local only, never sent. | v2 |
| F9 | Sparkle or another updater for the Mac app. | v2 |
| F10 | `host:track-devices-l` and `adb mdns` wording in current adb (not in the Android 10 tree read). | M5 verifies against the bundled 37.0.0 binary's `adb help`. |
| F11 | Spring stiffness choice (k = 1200 settles at 251 ms; k = 600 would take the full 333 ms). | Mike, after seeing the slide; it is one Settings value. |
| F12 | The DC-1 skill doc claims a USI 2.0 stylus; the hardware is a Wacom EMR passive pen. The skill doc should be corrected. | Mike |
