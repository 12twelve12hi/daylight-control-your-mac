# Component F handoff: mirror mode

Owner paths: `mac/Daylight/Sources/Mirror/`, `mac/DaylightKit/Sources/DaylightKit/Mirror/`, `mac/DaylightKit/Tests/DaylightKitTests/Mirror/`, `mac/DaylightTests/Mirror/` (with `Fixtures/`), this file. The handoff README names the F file `F-mirror.md`; the orchestrator's task named `f-mirror-mode.md`. This is the only copy; `F-mirror.md` is a one-paragraph pointer.

Writing rules apply: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

---

## 1. What was built

Everything in IMPLEMENTATION-PLAN section 9 and ARCHITECTURE section 6, against the frozen `MirrorFrameSource`, `MirrorControl` and `PipelineControl` contracts and A's `Settings`, `FailureText.Case`, `CropInsets`, `GovernorEvent`.

### 1.1 DaylightKit `Mirror/` (Foundation only, one file per type; tested on Linux and macOS)

| File | What it does |
|---|---|
| `ScrcpyDemuxer.swift` | `ScrcpyPacket`, `ScrcpyError`, `ScrcpyDemuxer`: the scrcpy 4.1 video socket (dummy byte optional, 64-byte `Build.MODEL`, codec id with 0 and 1 as errors and anything but `0x68323634` as `unknownCodec`, 12-byte session packets re-emitted on rotation, 12-byte frame headers with bit 62 config, bit 61 key frame, 61-bit PTS in microseconds, big-endian throughout), any chunking, buffer compaction. `ScrcpyStreamBuilder` writes the same bytes for tests and fakes. |
| `AnnexB.swift` | 3- and 4-byte start codes, trailing-zero trim, `parameterSets` (types 7 and 8 with emulation prevention bytes intact), `toAVCC` (4-byte big-endian lengths), `containsIDR` (type 5), `containsParameterSets`. |
| `EvdevParser.swift` | `EvdevEvent` (with `numericValue` for `DOWN`/`UP`/hex) and the incremental `getevent -lt` line parser: `/dev/input/eventX: ` prefix, `[sec.usec]` stamps, partial lines, `\r\n`, raw hex lines, device-scan noise ignored. |
| `EvdevCapabilities.swift` | `getevent -pl` listing parser (getevent.c `print_possible_events` shape: `KEY (0001):` labels in columns of four with `*` for held keys, `ABS (0003):` one axis per line with `min`/`max`, `input props:`) and `penNode` (BTN_TOOL_PEN plus ABS_PRESSURE, no ABS_MT_SLOT; a Wacom or pen name wins among several). |
| `StylusContactMachine.swift` | `StylusSample`, `StylusTransition`, the machine: pending state between reports, edges only on `SYN_REPORT`, `penContact = touching && inRange`, `eraserContact = touching && eraserInRange && !inRange`, side buttons as separate edges, `reset(tsUs:)` opens every switch. |
| `SideButtonGestures.swift` | double press (two downs within 400 ms), long press (700 ms, from `timerFired` at `pendingDeadline()` or from `up`), a long press never starts a double and the second press of a double is never a long press; `SideButtonAction` and `action(for:swap:)`; `Settings.sideButtonGestures`. |
| `AdbDevicesParser.swift` | `AdbDevice` (`isUSB`, `isReady`, `looksLikeDaylight`), `devices -l` and `track-devices` parsing by walking back from `transport_id:` over `key:value` fields, serials with spaces, `*` and `adb server` noise, every state scrcpy knows plus `no permissions`; `parseHostVersion` for `adb version` text, `OKAY00040029` and `0029`. |
| `CropInsets.swift` | insets in native tablet pixels (portrait 1200x1600, landscape 1600x1200) to UV fractions of the current session size, `pixelRect`, `croppedAspect`, clamping (at least 100 px remain), `effective(pillsEnabled:)` (top 0 without pills), `nativeSize(for:)`. |
| `ScrcpyLaunch.swift` | the exact SPEC F2 argument lists (push, forward, forward --remove, the shell line with `4.1` and the fourteen options in order), the constants (27183...27199, 100 x 100 ms, `[server] ERROR:`), the option-value hygiene rule of `server.c:193-206`. |
| `AdbHostProtocol.swift` | smart-socket framing (`000chost:version`, `0012host:track-devices`) and the incremental `OKAY`/`FAIL`/framed-payload reply parser. |

Tests (`Tests/DaylightKitTests/Mirror/`, ten files, 60 tests): `ScrcpyDemuxerTests` (the synthetic stream at chunk sizes 1, 7 and 1460, rotation, codec 0 and 1, zero size, the header bits against `Streamer.java`, device meta truncation, no buffer growth), `AnnexBTests` (the fixture's SPS and PPS as literals), `EvdevParserTests`, `EvdevCapabilitiesTests`, `StylusContactMachineTests`, `SideButtonGesturesTests` (double at 0 and 0.3 s, none at 0 and 0.5 s, long press at 0.7 s, swap), `AdbDevicesParserTests` (the official example, serials with spaces, noise lines, all states, host version), `CropInsetsTests` (SPEC F4 with 1200x1600 versus 960x1280, landscape, clamping, the pills rule, 810x1015.2 fit), `ScrcpyLaunchTests` (SPEC F2 string equality), `AdbHostProtocolTests`.

### 1.2 Mac `Sources/Mirror/`

| File | What it does |
|---|---|
| `AdbClient.swift` | `AdbRunning` (F-internal protocol so `FakeAdb` replays transcripts), `AdbProcessHandle` (`Process` conforms), `AdbCommandResult`, `AdbError`, `LineSplitter`. `AdbClient`: Foundation `Process` plus `Pipe`, both pipes drained on global queues so a chatty child never deadlocks, a watchdog `terminate()` at the timeout, `ADB_SERVER_SOCKET` in the child environment in private-port mode, `readabilityHandler` streaming for the long-running children. `locateExecutable` returns the bundled `Vendor/adb`, or copies it once into `~/Library/Application Support/Daylight/` and makes it executable when the bundle copy lost its mode (chmod inside the bundle would break the signature). |
| `AdbServerPolicy.swift` | ARCHITECTURE 6 item 1 and SPEC F5: an `NWConnection` probe of `127.0.0.1:5037` with `000chost:version` (1 s), nobody answers -> shared default socket, same protocol version as `adb version` of the bundled client -> shared, different -> `.conflict` with `tcp:localhost:27180` and row 24. `Settings.adbServerMode` `.shared` and `.privatePort` force a mode. Never `kill-server`. |
| `DeviceTracker.swift` | `devices -l` once (also spawns the server), then `host:track-devices` on a raw socket to the chosen server, `AdbDevicesParser` on each framed list, publish on change only; polling every 2 s when the socket fails. `chooseDaylight`: `mirrorDeviceSerial` first, then a DC-1-looking device preferring state `device`, then any ready device, then any device so `unauthorized` and `offline` are visible. |
| `ScrcpySession.swift` | push, forward (27183 then 27184...27199), the `ScrcpyLaunch` shell line through `spawnStreaming`, `[server]` lines to `onServerLog` and the first `[server] ERROR:` remembered, the dummy byte over `NWConnection` with 100 x 100 ms retries (adb accepts the local socket before the server listens and closes it, which is the retry signal), `forward --remove` once connected, the demuxer on the receive loop, `terminate()` of the child and the forward removal on stop or failure. `ScrcpySessionError.detail` is the row 25 text. |
| `H264Decoder.swift` | SPEC F3: `CMVideoFormatDescriptionCreateFromH264ParameterSets` with NAL length 4; `VTDecompressionSessionCreate` with `kCVPixelFormatType_32BGRA`, `kCVPixelBufferIOSurfacePropertiesKey: [:]`, `kCVPixelBufferMetalCompatibilityKey: true`; `VTDecompressionSessionCanAcceptFormatDescription` else `WaitForAsynchronousFrames`, `Invalidate`, recreate; one `CMBlockBufferCreateWithMemoryBlock` (CM-owned memory, `AssureMemoryNow`) plus `CMBlockBufferReplaceDataBytes` per access unit, never reused (D41); `CMSampleBufferCreateReady` with the PTS in microseconds; synchronous `VTDecompressionSessionDecodeFrame` with the output handler; drop until a key frame after an error; `shouldRestartServer` after 12 s without one (row 27); PTS order watched for LOOSE_ENDS D13; `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder` read for diagnostics. |
| `MirrorSource.swift` | the `MirrorFrameSource`: a lock-protected one-deep slot, `frameSeed`, the session size from the session packet, orientation from the session size, the matching insets (portrait or landscape, top 0 without pills) as fractions of the CURRENT session size, `latestForSave` for `SessionSaver.saveMirror`; `geometry(...)` is the pure rule `CropInsetsRuntimeTests` checks. |
| `StylusWatcher.swift` | ARCHITECTURE 6 item 7: `getevent -pl` once (full listing logged, row 28 when no pen node), `getevent -lt /dev/input/eventN` streamed through `EvdevParser`, `StylusContactMachine` and `SideButtonGestures`; the long-press one-shot timer armed from the device stamps; restart with backoff 0.5 s doubling to 8 s on EOF after releasing every switch (so the governor sees the lift); 30 s of inking without a side-button event -> `sideButtonSilent` (row 28b). |
| `UsbOnboarding.swift` | SPEC 9.2 step 1, 9.3 step 1 and 9.4 step 2 as command lists plus a sequential runner that stops at the first non-zero exit: `reverse` and `am start -a android.intent.action.VIEW -d http://localhost:<port>`; `install -r`, `appops set ... SYSTEM_ALERT_WINDOW allow`, `pm grant ... POST_NOTIFICATIONS`, `reverse`, `am start -n com.twelve.daylight.ink/.ui.MainActivity [--es host H]`, `am start-foreground-service -n com.twelve.daylight.ink/.overlay.OverlayService --es pills top|bottom`. Component names are the manifest's (E handoff), not SPEC's `.MainActivity`. |
| `WifiMirror.swift` | D42: `shell ip route` -> the `src` of the `wlan` route, remembered in `UserDefaults`; `tcpip 5555`; `connect <ip>:5555` judged by `connected to` or `already connected` in stdout (`adb connect` exits 0 on failure); row 32 otherwise. |
| `MirrorController.swift` | the `MirrorControl` facade and the only F type B constructs: `MirrorController(settings:vendorDirectory:pipeline:queue:)` (plus a defaulted `adb:` for tests). Owns `mirror.queue`, `stylus.queue`, `adb.queue`; `start()` locates adb, decides the policy, tracks devices; a ready DC-1 starts the session, the decoder, the stylus watcher and (with pills on and the APK embedded, once per serial) the pills over USB; `unauthorized` is row 22, `offline` row 23, nothing listed is `.noDevice` plus the Wi-Fi interim when `mirrorOverWiFi` is on; session packets set the size and `.mirroring`; config packets feed the decoder; decode errors are row 27 with the 12 s restart; `[server] ERROR:` is row 25, codec 0 or 1 row 26; a failed session retries while the device stays listed (3 s doubling to 24 s). Pen transitions become `penContact`, `eraserContact`; gestures become `.pin(-1)` and `.clear` through `SideButtonGestures.action(for:swap:)`, gated by `mirrorPinClearMode.includesPenButton`; every event goes through `source.onGovernorEvent` when B set it, else `pipeline.post`. `setUpOverUSB` works without `start()`. `diagnostics` carries the adb mode and version, the devices, the session size, port and bytes, the device model, codec, decoder counters and hardware flag, the pen node and counters, the Wi-Fi address, the crop and the pin/clear mode. `status` and `devices` are lock-protected for B's 2 Hz reads; `diagnostics` hops to the control queue unless already there. |

### 1.3 Tests `mac/DaylightTests/Mirror/` (macOS, hosted bundle)

| File | Proves |
|---|---|
| `FakeAdb.swift` | `FakeAdb: AdbRunning` (responders, recorded calls, scripted children), `FakePipelineControl`, `StylusFixtures` (a `getevent -pl` listing in the getevent.c shape and `-lt` report builders) |
| `H264DecoderTests.swift` | the fixture's shape (7846 bytes, NAL types 7 8 6 5 1 1 7 8 5 1 1), six BGRA 320x240 IOSurface-backed frames in PTS order, the 160x120 SPS as a format change followed by two decoded frames, the key-frame gate and the 12 s rule, `noFormat`, the block buffer owning a copy. Skipped with the status printed when `VTDecompressionSessionCreate` fails on the runner. |
| `CropInsetsRuntimeTests.swift` | SPEC F4 through `MirrorSource.latest()`: 1200x1600 and 960x1280 give the same UV, 1600x1200 uses the landscape insets, top 0 without pills, custom insets, the seed |
| `AdbServerPolicyTests.swift` | SPEC F5 with a fake `version` and a fake adb server on loopback answering `OKAY00040029`; a closed port answers nil |
| `DeviceTrackerTests.swift` | polling publishes changes only, stop ends it, `chooseDaylight` |
| `ScrcpySessionTests.swift` | SPEC F2 end to end against a loopback server speaking the 4.1 byte layout: the four adb calls in order with the exact shell line, nine packets, `forward --remove` after connect, `terminate()` on stop, the dummy-byte retry with a late server, the timeout path, the `[server] ERROR:` path as row 25, forward port fallback, push failure |
| `StylusWatcherTests.swift` | the transcript to transitions and gestures (split writes, double press), the long press from the timer about 700 ms after the press and the silent release, row 28, EOF releases the contact and restarts without a second probe, row 28b after 36 s of device-clock inking |
| `UsbOnboardingTests.swift` | the three command lists verbatim, the stop-at-first-failure rule, `WifiMirrorTests` (ip route parsing, the connect verdict, remember then connect then refused then forgotten) |
| `MirrorControllerTests.swift` | rows 22, 23 and `.noDevice`; a ready device launches the server and the pen watcher and the pen path posts `penContact`, `pin(-1)`, `eraserContact`; swap and pills-only gating; row 25 with row 28 for a tablet without a pen node; USB onboarding for web (bound port 7789) and native (no APK fails, with an APK installs and passes `--es host`); row 21 without a USB device; a missing bundled adb is a row 25 status, not a crash; the contract reads from another thread |

---

## 2. How to test it on the real device (atomic steps)

Needs: the DC-1 with USB debugging on, a USB-C cable, the unsigned or signed `Daylight.app`, the Daylight Ink APK embedded in the build (the mac job embeds it).

1. Tablet: Settings > About > tap Build number seven times; Developer options > USB debugging on. If SolOS lists "Disable adb authorization timeout", turn it on (LOOSE_ENDS D6). Plug the cable into the Mac. Tap Allow on "Allow USB debugging?" with "Always allow from this computer" ticked.
2. Mac: menu bar > Ink source > Mirror the tablet. Within about two seconds the Diagnostics window shows `mirror.status: mirroring <serial> 1200x1600` and `mirror.session.deviceModel: <Build.MODEL>`. Copy `deviceModel` into LOOSE_ENDS D2.
3. Open the SolOS note app on the tablet. Touch the pen to the glass: the preview slides to Studio Split with the tablet picture in the board slot (top strip cropped); the engage probe line `engage probe: pen contact at <t> (mirror)` and `first decoded frame at <t>` are in the Diagnostics log.
4. Lift the pen and wait 90 s: the picture slides back; `~/Documents/Daylight Camera/<date>/<HH-mm-ss>/mirror-<HH-mm-ss>.png` appears (B's saver, cropped with the same insets).
5. Double press the pen side button: the menu shows "Keep whiteboard" ticked. Hold the side button for a second: the board saves and returns to the camera (unless pinned). Settings > Mirror > swap exchanges the two.
6. Settings > Mirror > Pin and Clear: with "Floating pills" or "Both", the pills appear at the top of the tablet and never in the camera picture (the top 96 px are cropped); with "Pen side button" the top inset is 0 and the whole screen is mirrored.
7. Rotate the tablet: Diagnostics shows `mirror.session.size: 1600x1200`; the picture keeps the same region cropped (landscape top inset 72).
8. Diagnostics > `mirror.pen.status` reads `watching /dev/input/eventN "<name>" pressureMax=<n>`. Copy the line and the `getevent -pl devices:` log line into LOOSE_ENDS D1. `mirror.decoder.hardware` says whether VideoToolbox used the hardware decoder.
9. Unplug the cable while mirroring: the status goes to `no device` within two seconds, the board lifts the pen and the idle timer runs; plug it back: mirroring resumes without any tap (the RSA key is remembered).
10. Settings > Mirror > "Mirror over Wi-Fi after a USB session" on, then unplug: the Mac runs `adb connect <ip>:5555`; the mirror continues over Wi-Fi or the menu shows "Plug in once to re-enable Wi-Fi mirroring." (row 32). Reboot the tablet and try again to answer LOOSE_ENDS C2.
11. Start Android Studio (or any other adb) before Daylight: the menu shows the row 24 text and `mirror.adb.mode` reads `private tcp:localhost:27180 (...)`. Whether the USB tablet is still visible to our server answers LOOSE_ENDS C5.
12. Welcome window > "Set up over USB" with the web source selected: the tablet opens `http://localhost:7788` (or the bound port); with the Daylight Ink source: the APK installs, the app opens with the Mac's address, and the pills service starts.

Rows of SPEC 13.3 the owner triggers on purpose with this component: 21 (no device: unplug), 22 (decline the RSA prompt once), 23 (adbd offline: toggle USB debugging off and on while plugged), 24 (another adb), 25 (rename `Vendor/scrcpy-server-v4.1` in a test copy of the app), 27 (pull the cable mid-frame and replug; the status reads "Recovering video..." until the next key frame), 28 (a tablet without a Wacom node), 28b (hold the side button on a SolOS build that swallows it), 29 (deny "display over other apps"), 32 (Wi-Fi connect after a reboot).

---

## 3. Device facts and CI facts

- Run 37115400048 (commit 68cb965): `kit-linux` green with the Kit Mirror tests on Swift 6.4; the mac job's `make kit-test` step green on Xcode 16.4, so the Kit Mirror sources compile on both toolchains. The red `make mac-test` of that run is B19 (ClientRegistryTests, OnboardingStepsTests, OutputPoolTests), not this component.
- Run for commit 62fb359 (the Mac sources and tests): see the "CI facts" lines appended below once the run finishes.
- The two fixtures were generated here with the plan's command on ffmpeg 6.1.1 (libx264): `testsrc-320x240-6f.h264` is 7846 bytes, sha256 `f4985e08df42ccc4b9093e3679cf99bed6b1572fbe7ce865c3e7fd71e347eb33`, NAL types 7 8 6 5 1 1 7 8 5 1 1, SPS `6742c00dd90141fb0110000003001000000303c0f142a480`, PPS `68cb83cb20`; `testsrc-160x120-2f.h264` (`-frames:v 2`, `size=160x120`) is 2452 bytes, NAL types 7 8 6 5 1, SPS `6742c00bd902847e5c0440000003004000000f03c50a92`.
- XcodeGen puts a file with an unknown extension under a target's `sources` into the resources build phase (`SourceGenerator.swift:306-331`, `default: return .resources`), so `DaylightTests/Mirror/Fixtures/*.h264` land flat in the test bundle and `Bundle(for:).url(forResource:withExtension:)` finds them without a `project.yml` change. `H264DecoderTests.fixture` skips with a clear message if that ever stops being true.
- Lines the Mac logs for the owner (category `mirror`, `scrcpy`, `stylus`, `decode`, `adb` under subsystem `com.twelve.daylight`, all mirrored into Diagnostics): `adb server: <mode>`; `device model: <Build.MODEL>` (D2); `getevent -pl devices: [...]` and `pen node /dev/input/eventN "<name>" pressureMax=<n> keys=[...] abs=[...]` (D1); `pen node reports no BTN_STYLUS or BTN_STYLUS2` (D1, 28b); `decoder session <n>: <w>x<h> BGRA hardware=<bool>`; `out-of-order PTS from the encoder` (D13); `engage probe: pen contact at <t> (mirror)` and `first decoded frame at <t>` (D12 and the SPEC 15 mirror engage budget); `remembered <ip> for Wi-Fi mirroring; adbd now listens on 5555` (C2); `host:track-devices unavailable (...)` (F10).

---

## 4. UNVERIFIED items shipped behind a fallback

| Fact | Fallback | How the owner confirms |
|---|---|---|
| The DC-1's Wacom node name, number, axes and pressure max; whether SolOS reports `BTN_STYLUS` (LOOSE_ENDS D1) | runtime `getevent -pl`, the pen-node rule, rows 28 and 28b, the pills stay | step 8 |
| `Build.MODEL` of the DC-1 (D2) | the demuxer's device meta is only a label; the DC-1 choice rule also accepts a `JP`/`DC1` serial or any single device | step 2 |
| Whether `adb tcpip 5555` survives a reboot on SolOS (C2) | `WifiMirror.rememberAfterUSBSession` re-runs `tcpip` after every USB session; row 32 | step 10 |
| Two adb servers and one USB tablet (C5) | private-port mode plus row 24 | step 11 |
| `host:track-devices` on adb 37 (F10) | a FAIL or a closed socket falls back to `devices -l` every 2 s, logged | Diagnostics log line |
| getevent latency over USB and whether the device-side `getevent` exits when the shell child is killed (D12) | timestamps logged; `terminate()` on stop; a leftover `getevent` is harmless (read-only evdev) | `adb shell ps -A \| grep getevent` after quitting Daylight |
| B-frames or PTS reordering from the DC-1 encoder (D13) | decode order is published; out-of-order PTS counted and logged once | `mirror.decoder.outOfOrder` stays 0 |
| Which app handles `http://` VIEW intents on SolOS (D10) | the `am start` result is logged; the menu URL remains | step 12 |
| `appops set ... SYSTEM_ALERT_WINDOW allow` flips `canDrawOverlays`, `am start-foreground-service` from the shell starts the pills (D15) | the APK shows row 29 and stops; `onFailure(.pillsInvisible)` when the command sequence fails | step 6 |
| The macos-15 runner creates a `VTDecompressionSession` for the baseline fixture | `H264DecoderTests` skip with the status printed; the owner's Mac is the first real decode | the `h264-decoder:` lines in `test.log` |
| `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder` through `VTSessionCopyProperty` bridges to a `NSNumber` | `usingHardware` stays nil and Diagnostics says `unknown` | `mirror.decoder.hardware` |
| The folder-reference copy of `Vendor/adb` keeps its executable bit through signing and notarization (B6 family) | `AdbClient.locateExecutable` copies it to Application Support and chmods there | `mirror.adb.executable` path in Diagnostics |
| `NWConnection` reports a refused loopback connection as `.waiting` (used as "no adb server on 5037" and as the dummy-byte retry signal) | both `.waiting` and `.failed` are handled, plus the 1 s probe timeout and the 100 x 100 ms budget | `mirror.session.dummyByteAttempts` |
| The encoder's `max_size=1600` yields 1200x1600 on the DC-1 (the plan's 960x1280 fallback size) | insets are fractions of the session size either way | `mirror.session.size` |
| A `Settings` change of the encoder options while mirroring | applies to the next session (rotation or replug restarts one) | Settings > Mirror > Quality then replug |

---

## 5. Requests for the integrator

1. **Wire the facade in B's `AppDelegate` (B handoff request 3, ARCHITECTURE 18 row "B's `AppDelegate` wiring")**: in `applicationDidFinishLaunching`, after `wirePipeline()`:
   ```swift
   let mirror = MirrorController(settings: settingsStore.settings, vendorDirectory: Bundle.main.resourceURL!.appendingPathComponent("Vendor"), pipeline: pipeline, queue: DispatchQueue(label: "com.twelve.daylight.mirror.control", qos: .userInitiated))
   mirror.onLog = { [weak self] line in self?.telemetry.note("mirror", line) }
   mirror.onFailure = { [weak self] failure, args in DispatchQueue.main.async { self?.model.noteFailure(failure, args) } }
   mirror.onStatusChange = { [weak self] status in DispatchQueue.main.async { self?.model.mirrorStatusText = MirrorController.describe(status); self?.settingsContext.mirrorAvailable = { if case .mirroring = status { return true } else { return false } }() } }
   mirror.source.onGovernorEvent = { [weak pipeline] event in pipeline?.post(event) }
   pipeline.setMirrorSource(mirror.source)
   self.mirror = mirror
   model.mirror = mirror
   if settingsStore.settings.inkSource == .mirror { mirror.start() }
   ```
   In `applySettings`: `mirror?.updateSettings(settings)` (crop insets, pills rule, gesture windows apply live). In `server.onReady`: `mirror?.serverPort = bound` so `adb reverse` uses the bound port. `onStatusChange`, `onDevicesChange` and `onFailure` are called on the control queue: hop to main as above. `MirrorStatus.error(case, detail)` reads as `FailureText.sentence(case, [detail])` (`MirrorController.describe` does that).
2. **`docs/handoff/F-mirror.md`** is a pointer to this file, as D and E did; update the README table row for F to `f-mirror-mode.md` or keep both.
3. **ARCHITECTURE section 18**: the Kit Mirror block gained `ScrcpyStreamBuilder`, `ScrcpyLaunch`, `AdbHostProtocol`, `SideButtonAction`, `Settings.sideButtonGestures`, `CropInsets.effective(pillsEnabled:)`, `CropInsets.nativeSize(for:)` and `EvdevCapabilities.AxisRange` (ARCHITECTURE 2.1 wrote `abs: [String: (min: Int, max: Int)]`, a tuple cannot be `Equatable`); the mac Mirror block gained `AdbRunning`, `AdbProcessHandle`, `AdbCommandResult`, `AdbError`, `LineSplitter`, `ScrcpySessionError`, `H264DecoderError`, `StylusWatcher.Status.sideButtonSilent`; `H264Decoder` allocates the block buffer through CoreMedia (`memoryBlock: nil` plus `CMBlockBufferReplaceDataBytes`) instead of a custom block allocator: one copy per access unit, still owned by the block buffer and never reused (D41). Component names in `UsbOnboarding` are the manifest's `.ui.MainActivity` and `.overlay.OverlayService` (SPEC 9.3 wrote `.MainActivity`).
4. **No `project.yml`, `Package.swift`, plist or workflow change** is needed: the fixtures ride the default resources phase (section 3), the Kit tests keep their fixtures as string literals, and the mac sources import only Foundation, Network, CoreMedia, CoreVideo, VideoToolbox, QuartzCore and os.
5. **SETUP.md, COMPARE.md and TESTING-CHECKLIST.md text** is in section 7 for the M6 fold.
6. **LOOSE_ENDS**: the UNVERIFIED rows of section 4 that are not yet listed (the executable bit of `Vendor/adb` after signing; `.waiting` as the refused-connection signal; `VTSessionCopyProperty` bridging; the runner's VideoToolbox decoder result) are candidates for section E.

---

## 6. Red CI runs caused by someone else's files

- 37115400048 (commit 68cb965), job `mac`, step `make mac-test`: B19 (ClientRegistryTests, OnboardingStepsTests, OutputPoolTests). Not this component.

---

## 7. Text for the owner-facing documents

### SETUP.md (mirror mode, SPEC 9.4)

Mirror mode shows whatever is on your Daylight's screen inside the whiteboard slot, so you can write in the SolOS note app and the camera follows your pen. It needs USB debugging once:

1. On the tablet: Settings > About > tap Build number seven times. Back in Settings > Developer options, switch on USB debugging. If you see "Disable adb authorization timeout", switch it on too so the permission never expires.
2. Plug the tablet into the Mac. The tablet asks "Allow USB debugging?": tick "Always allow from this computer" and tap Allow.
3. On the Mac: menu bar > Ink source > Mirror the tablet. About two seconds later the preview shows your tablet screen when you touch the pen to the glass. That is the whole setup; from now on plugging in is enough.

Pin and Clear in mirror mode: the two floating pills at the top of the tablet (Daylight installs its small Daylight Ink app over the cable to show them), or the pen's side button (double press keeps the whiteboard, hold for a second clears and returns to the camera), or both; choose in Settings > Mirror. The top strip where the pills live is cropped out of the camera picture; drag the four edges in Settings > Mirror if the crop needs adjusting.

Cable free (optional): Settings > Mirror > "Mirror over Wi-Fi after a USB session". After one USB session Daylight remembers the tablet's Wi-Fi address and reconnects over Wi-Fi when you unplug. If the tablet was restarted, plug in once more. Android 11 wireless debugging pairing (Developer options > Wireless debugging > Pair device with pairing code, then `adb pair` and `adb connect` in Terminal with Daylight's own adb at `Daylight.app/Contents/Resources/Vendor/adb`) also works and is not automated in v1.

If the menu says "Another adb is running (Android Studio?)", Daylight uses its own copy on a private port; a tablet already claimed by the other adb will not be visible until you quit it.

### COMPARE.md (mirror column)

What crosses the wire: H.264 video of the whole screen (about 1 MB/s at 1600 max size, 8 Mbit/s) plus the `getevent` text stream of the pen. Engage detector: `BTN_TOUCH DOWN` while `BTN_TOOL_PEN` is down on the Wacom evdev node. Expected engage latency 60 to 90 ms (pen contact to the first moved frame; read `engage probe: pen contact at <t>` and the next `perf` line), picture latency 100 to 200 ms (encoder, adb, VideoToolbox; compare the tablet and the preview side by side with a stopwatch app on the tablet). Numbers to fill in: `mirror.decoder.hardware`, `mirror.session.size`, the engage probe delta, the stopwatch delta, Activity Monitor for Daylight while mirroring (budget: Studio Split plus hardware decode, resident set under 180 MB). No vector export in mirror mode: the session ends with `mirror-<HH-mm-ss>.png`.

### TESTING-CHECKLIST.md rows (about 15 minutes)

- 🟢 USB debugging on, cable in, "Always allow" ticked (2 min)
- 🟢 Ink source > Mirror the tablet: Diagnostics shows `mirror.status: mirroring <serial> 1200x1600` within 2 s (1 min)
- ✍️ Pen touches the note app: the preview slides to Studio Split with the tablet picture; the top strip is cropped (1 min)
- ⏱️ Lift the pen, wait 90 s: the picture slides back; `mirror-<HH-mm-ss>.png` is in today's session folder (2 min)
- 📋 Double press the side button: "Keep whiteboard" ticked; hold it one second: Clear and return (1 min)
- 📋 Settings > Mirror > Pen side button only: the whole screen is mirrored (top inset 0); back to Both: the strip is cropped again (1 min)
- 🟣 Rotate the tablet: `mirror.session.size: 1600x1200`, the same region stays cropped (1 min)
- 📋 Copy `mirror.pen.status`, the `getevent -pl devices:` line and `mirror.session.deviceModel` into LOOSE_ENDS D1 and D2 (1 min)
- 🟡 Unplug while mirroring: status `no device` within 2 s, the board returns after the idle time; replug: mirroring resumes with no tap (2 min)
- 🟡 "Mirror over Wi-Fi" on, unplug: Wi-Fi mirror or "Plug in once to re-enable Wi-Fi mirroring." (2 min)
- 🟡 Start another adb first: row 24 text in the menu; is the tablet still visible? (LOOSE_ENDS C5) (1 min)
