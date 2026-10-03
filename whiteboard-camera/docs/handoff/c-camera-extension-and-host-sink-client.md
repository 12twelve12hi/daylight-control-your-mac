# Component C handoff: camera extension and host-side sink client

Owner paths: `mac/DaylightCameraExtension/Sources/`, `mac/Daylight/Sources/Camera/`, `mac/DaylightTests/Camera/`, this file. The handoff README names the C file `C-camera.md`; the orchestrator's task named `c-camera-extension-and-host-sink-client.md`. This is the only copy; `C-camera.md` is a pointer to it.

Writing rules apply: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

---

## 1. What was built

Everything in IMPLEMENTATION-PLAN section 6 against the frozen `VirtualCameraSink` and `SinkStatus` contract and the `FailureText.Case` names of plan section 3.4. Nothing here imports anything of B or F; the extension imports no DaylightKit.

### 1.1 Extension (`mac/DaylightCameraExtension/Sources/`, target `DaylightCameraExtension`)

| File | What it does |
|---|---|
| `ExtensionRules.swift` | Foundation only. `ConsumeStrategy` (`.timer90Hz` default, `.recursive` kept) and `DaylightExtensionRules`: frame rate 30, 1920x1080, consume multiplier 3 (90 Hz), `hostSigningID = "com.twelve.daylight"`, the viewers property name `4cc_dlvw_glob_0000`, the SPEC 4 placeholder sentence, the design tokens, and the three rules as pure functions: `authorizesSink(signingID:)` (nil passes, anything else must equal the host id), `drawsPlaceholder(sinkStarted:streamingCounter:)` (`!sinkStarted && streamingCounter > 0`), `forwardsSinkFrames(streamingCounter:)`. The file compiles alone so the integrator can add it to `DaylightTests` (request 1). |
| `DeviceSource.swift` | OBS shape. Source lifecycle keeps `streamingCounter`, one placeholder timer at 30 Hz that returns early unless `drawsPlaceholder` is true. Sink lifecycle: `startStreamingSink` switches on `consumeStrategy`; the timer path schedules a strict `DispatchSourceTimer` every `1/90 s` calling `consumeBuffer` only while `sinkStarted`; the recursive path re-arms in the completion. Every consumed buffer is forwarded with `send(_:discontinuity:hostTimeInNanoseconds:)` only when `streamingCounter > 0` and always followed by `notifyScheduledOutputChanged`. `#if DEBUG` logs `consume rate: buffers= empty= viewers=` once per second (unified log, subsystem `com.twelve.daylight`, category `extension`). `publishViewerCount` is called on every viewer start and stop. |
| `SourceStream.swift` | Formats and frame duration as before, plus the custom property `CMIOExtensionProperty(rawValue: "4cc_dlvw_glob_0000")` in `availableProperties`; `streamProperties(forProperties:)` answers it with `CMIOExtensionPropertyState(value: "sc=<streamingCounter>" as NSString)` (the ldenoue transport that a shipping host reads back as a CFString); writes to it are ignored; `publishViewerCount` calls `stream.notifyPropertiesChanged([property: state])` so a host listener block has an event to fire on (LOOSE_ENDS E3). |
| `SinkStream.swift` | `authorizedToStartStream(for:)` returns `DaylightExtensionRules.authorizesSink(signingID: client.signingID)` and remembers the client only when it passes; a refusal is logged with the pid and the signing id. Queue size 1, one buffer to start, as OBS. |
| `Placeholder.swift` | The cream card (SurfaceCream background, PaperBg card with a 1.5 px BorderSubtle edge, the sentence split at the period, InkBlack then TextMuted, CoreText `CTLineDraw`) rendered once into a BGRA byte array (`byteOrder32Little | noneSkipFirst`) and copied into each placeholder buffer, so the 30 Hz timer does no drawing. A buffer of another size gets a plain cream fill. |
| `ProviderSource.swift`, `main.swift` | Unchanged shape; `main.swift` logs the build number and device UUID at start. |

### 1.2 Host (`mac/Daylight/Sources/Camera/`)

| Type | Initialiser B calls | What it does |
|---|---|---|
| `CMIOProperties` | none (internal) | The C property API wrappers: `fourCC`, `address`, `objectIDs` (devices, streams), `string` (device UID), `uint32` (stream direction), `customValue` (the viewers property: 4-byte UInt32, CFString or CFNumber reference). |
| `CMIODeviceLocator` | `CMIODeviceLocator(deviceUUID:)` | The OBS walk: `kCMIOHardwarePropertyDevices`, `kCMIODevicePropertyDeviceUID == uuidString`, `kCMIODevicePropertyStreams`, `kCMIOStreamPropertyDirection` per stream logged once. `locate()` returns `(device, streams, directions)` or nil. Pure rules: `sinkStreamIndex` is 1 whenever there are two streams (nil otherwise, row 14), `sourceStreamIndex` is 0, `directionsLookUnexpected` flags anything but `[1, 0]` for the log, `layoutDescription` formats the row 14 log line. `deviceUIDs()` fills the row 13 log line. |
| `CMIOSinkClient` | `CMIOSinkClient(deviceUUID:sinkUUID:queue:)` | `VirtualCameraSink`. `start()` locates the device, `CMIOStreamCopyBufferQueue` on streams[1] with a queue-altered C callback (refcon = unretained self) that counts and calls `onQueueAltered`, `CMIODeviceStartStream`; status `.connected`. Retries every 2 s until connected and at once on `.AVCaptureDeviceWasConnected`. `push` enqueues with `CMSimpleQueueEnqueue` only when `count < capacity`, else returns false; never blocks; counts `enqueuedFrames` and `droppedFrames`; `queueCountAndCapacity` for Diagnostics. `stop()` stops the stream, unregisters the callback (NULL proc), resets the viewer watcher. Owns a `ViewerWatcher` and forwards `onViewerCount`. `noteExtensionStatus(_ s: ExtensionInstaller.Status)` (additive, optional) makes the status right before the device appears: `.needsApproval` -> `.awaitingApproval`; `.needsReboot` -> `.error(.extensionNeedsReboot, ...)`; `.notInApplications`, `.unsignedBuild`, `.failed(code, msg)` -> the matching `.error`; `.installed` with no device -> `.error(.sinkDeviceNotFound, <uuid>)`, whose detail becomes the row 13 follow-up sentence after 30 s (`CMIOSinkClient.sentence(for:)` builds the owner text). Without installer information the status stays `.notInstalled` while searching. |
| `ViewerWatcher` | `ViewerWatcher(locator:queue:)` | Reads `4cc_dlvw_glob_0000` on the source stream with `CMIOObjectGetPropertyData` once a second (always on), parses `sc=<n>`, a bare number or a UInt32, reports changes only through `onViewerCount`; registers `CMIOObjectAddPropertyListenerBlock` once per stream and logs the OSStatus (whether it fires is UNVERIFIED, E3). `setSourceStream` lets the sink client hand it the stream it already found. |
| `SinkFeeder` | `SinkFeeder(sink:)` | `push(_ pb: CVPixelBuffer, hostTimeNs: UInt64?) -> Bool`: `CMVideoFormatDescriptionCreateForImageBuffer` cached per (w, h, fmt) (`formatDescriptionsCreated` counts), host-clock PTS in nanoseconds strictly increasing (`nextPTS(after:hostTimeNs:)` bumps an equal or earlier stamp by one tick), duration 1/30, `CMSampleBufferCreateReadyWithImageBuffer`; `pushedFrames`, `droppedFrames`. Callable from the capture queue and the Metal completion thread (one NSLock around the description and the PTS). B's `FrameFeeder` can be swapped for it behind the same `sink.push`. |
| `PreviewOnlySink` | `PreviewOnlySink()` | Status `.installed` (so the idle rule keeps the webcam running for the preview), `start()` reports the status once, `push` returns true and counts, `viewerCount` 0. |
| `ExtensionInstaller` | `ExtensionInstaller(extensionBundleIdentifier: = "com.twelve.daylight.camera")` plus optional `signed:` and `bundlePath:` for tests | `OSSystemExtensionRequestDelegate` on the main queue. `activate()` submits `OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:queue:)` unless the build is unsigned (`DaylightBuildSigned` false -> `.unsignedBuild`, nothing submitted, row 2 logged). `deactivate()` submits the deactivation request. Delegate: `.replace` always (versions logged); `requestNeedsUserApproval` -> `.needsApproval` (row 12 log line); `.completed` -> `.installed`; `.willCompleteAfterReboot` -> `.needsReboot` (row 12b); `didFailWithError` -> code 3 `.notInApplications`, code 12 stays `.activating`, everything else `.failed(code, localizedDescription)` with the row 6 to 11 log line (row 8 includes `ls -R Contents/Library/SystemExtensions`). Pure mappings for B: `failureCase(for: OSSystemExtensionError.Code) -> FailureText.Case?` (2 -> 6, 3 -> 7, 4/5/6/7 -> 8, 8 -> 9, 9 -> 10, 10 -> 11, 13 and 11 -> 12, 1 -> 8, 12 -> nil), `failure(for: Status) -> (FailureText.Case, [String])?`, `status(forErrorCode:message:)`. `openApprovalPane()` tries `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` first on macOS 15 and later, the Privacy & Security URL first below, returns false when neither opened (show `approvalPathText`, which is `FailureText.approvalPathModern` or `approvalPathLegacy` by `ProcessInfo.operatingSystemVersion.majorVersion >= 15`). |

### 1.3 Tests (`mac/DaylightTests/Camera/`, hosted by Daylight.app, run by `make mac-test`)

| File | Proves |
|---|---|
| `CameraTestSupport.swift` | `CameraTestBuffers.make` (IOSurface-backed BGRA of any size) and `QueueSink`, a `VirtualCameraSink` over a real `CMSimpleQueueCreate` queue with the same `count < capacity` enqueue rule as `CMIOSinkClient.push` (plan section 10). |
| `SinkFeederTests.swift` | SPEC C4: capacity 1, two pushes give one enqueue and one drop, the dequeued sample wraps the same pixel buffer (no copy), a third push fits after the consumer drained; PTS strictly increasing over 100 buffers with a frozen host time; host-clock PTS with nanosecond timescale when no time is given; the pure `nextPTS` rule; one format description across 100 same-size buffers (64x36 BGRA) and a new one after a size change; a 1080p sample is ready with the right description and duration 1/30. |
| `PreviewOnlySinkTests.swift` | status `.installed`, start reports once, 10 pushes accepted and counted, stop leaves the status, the Info.plist carries `DaylightBuildSigned`. |
| `ExtensionBundleTests.swift` | SPEC C1 and C2 as far as a hosted test can see: exactly one `com.twelve.daylight.camera.systemextension` under `Contents/Library/SystemExtensions` with its executable; the three UUID keys equal between both Info.plists and distinct; `CFBundleIdentifier`, `CFBundlePackageType SYSX`, `CMIOExtensionMachServiceName` ending in `com.twelve.daylight` (unexpanded, `TEAMID.` prefixed or bare, printed), `NSSystemExtensionUsageDescription`, equal `CFBundleVersion`; the extension's `entitlements:` block in `project.yml` (read through `#filePath`) holds exactly `com.apple.security.app-sandbox` and `com.apple.security.application-groups` and no `cs.*` exception; the extension sources import no DaylightKit and spell the SPEC C3 constants (timer default, multiplier 3, frame rate 30, signing id, property name, placeholder sentence, queue size 1, `notifyScheduledOutputChanged`, the placeholder rule). |
| `ExtensionInstallerTests.swift` | every `OSSystemExtensionError.Code` maps to its row (13 codes), the raw values 2, 3, 8, 9, 10, 13, the exact SPEC 13.3 sentences and log lines of rows 6 to 12b, `status(forErrorCode:)`, `failure(for:)` for every status, an unsigned installer never submits and reports `.unsignedBuild` once, defaults from the host bundle, approval URLs and path text per macOS version, the row 8 listing contains the embedded extension. |
| `CMIOLocatorTests.swift` | `fourCC` against the SDK selectors (`sdir`, `dev#`, `uid `, `stm#`), the property address fields, sink index 1 and source index 0 regardless of directions, nil below two streams, `directionsLookUnexpected`, the row 14 and row 13 log lines, a real device walk on the runner (prints every CMIO device UID; Daylight Camera absent without the signed extension), the viewers parser (`sc=1`, `12`, numbers, rejects), the 1 Hz constant, a watcher without the device reports nothing and stops cleanly. |
| `CMIOSinkClientTests.swift` | constants 2 s and 30 s; 50 pushes before start return false at once; start without the device keeps `.notInstalled`, retries, stops cleanly with no status churn; every installer status drives the searching status (8 distinct reports, exact `SinkStatus` values); row 13 gains "Open Zoom or FaceTime once, or restart your Mac." after the follow-up delay (shortened to 0.3 s); the owner sentences for every status. |

Acceptance mapping: C1 and C2 are checked by `mac-debug` (`ls -R Daylight.app` in `xcodebuild-logs/app-contents.txt`, `extension-info-plist.txt`) and `ExtensionBundleTests`; C3 by the extension sources (pinned by `ExtensionBundleTests.testExtensionSourcesStayFreeOfDaylightKitAndPinTheRules` until request 1 compiles the rules into the test bundle); C4 by `SinkFeederTests`; C5 waits for the owner's signed build (section 2).

---

## 2. How to test on the real device (atomic steps)

Unsigned build (what CI produces today): the extension cannot load (research-cmio-signing 0.4), so the camera path is exercised only by `make mac-test`. The owner's steps start once the eight signing secrets exist (LOOSE_ENDS A1) and CI has produced `Daylight.dmg` or `Daylight-signed.zip`.

1. Open the DMG, drag Daylight to Applications, open it from Applications (a copy in Downloads fails with row 1 or row 7, by design). Expected: the menu bar icon, the Welcome window at step 2 "Install Daylight Camera".
2. macOS shows "System Extension Blocked" (or nothing on macOS 15 and later). The Welcome step reads "Approve 'Daylight Camera' in System Settings > General > Login Items & Extensions > Camera Extensions, then click Check again." Click "Open System Settings": the pane opens (or the text path is shown), switch Daylight Camera on, enter your password.
3. Back in Daylight click "Check again". Expected within 2 s: the step turns green (status `.connected`), `log stream --predicate 'subsystem == "com.twelve.daylight"' --level info` prints `sink connected: device=<id> sink=<id> capacity=1 directions=[a, b]`. Paste the `directions=` values into LOOSE_ENDS E2.
4. Terminal: `systemextensionsctl list` lists `com.twelve.daylight.camera` as `[activated enabled]` (SPEC C5).
5. Quit Daylight (menu > Quit). Open FaceTime, choose Video > Daylight Camera. Expected: the cream card "Daylight is not running. Open Daylight from the menu bar." within a second (the placeholder path, drawn only while a viewer streams and no host is connected).
6. Open Daylight again while FaceTime still shows the card. Expected: the webcam picture replaces the card within 2 s (the retry loop and `.AVCaptureDeviceWasConnected` both lead here). The log prints `viewers=1`.
7. Close FaceTime. Expected: `viewers=0` in the log within 1 s (the poll) and the webcam LED off 60 s later (SPEC D32, B's idle rule). Open FaceTime again: the picture is back within a second.
8. Open Zoom and pick Daylight Camera as well: the log prints `viewers=2`; both apps show the same picture.
9. Diagnostics (menu > Diagnostics): "sink queue 0 of 1" (or 1 of 1 while a frame is in flight), the two direction values, the viewer count.
10. Row 13 on purpose: with the extension approved, run `systemextensionsctl uninstall <TEAMID> com.twelve.daylight.camera` (UNVERIFIED subcommand; otherwise delete Daylight.app and reinstall it) and relaunch Daylight: "Daylight Camera is installed but not found yet. Retrying..." then after 30 s "Open Zoom or FaceTime once, or restart your Mac."; approving the extension again connects without a relaunch.
11. Row 15: if Zoom shows black after an update, quit and reopen Zoom (the extension was replaced under it).

Rows of SPEC 13.3 this component owns: 6 to 12b (activation), 13 (device not found), 14 (stream layout), 15 (black viewer, SETUP text only).

---

## 3. Device facts and CI facts

- Which `kCMIOStreamPropertyDirection` value marks the sink (LOOSE_ENDS E2): logged on the owner's first signed run as `Daylight Camera device <id> streams=[a, b] directions=[x, y]`; the code uses the stream order (sink = streams[1]) and only logs a notice when the directions differ from the expected `[1, 0]`.
- Whether `CMIOObjectAddPropertyListenerBlock` fires for the custom property (E3): the log line `CMIOObjectAddPropertyListenerBlock(dlvw) on stream <id> -> <status>` says whether it registered; if `viewers=` changes appear in the log faster than one second after FaceTime starts, the listener fired. The 1 Hz poll runs either way.
- CI facts are added below after the first green mac run of this component.

---

## 4. UNVERIFIED items shipped behind a fallback

| Fact | Fallback | How the owner confirms |
|---|---|---|
| `consumeSampleBuffer` completion semantics on an empty queue (E1) | `.timer90Hz` is the compile-time default; `.recursive` is one constant away | extension CPU in Activity Monitor stays near zero with Daylight running and no ink; the debug log prints `consume rate: buffers=30 empty=60` per second |
| Which direction value identifies the sink (E2) | index 1 (the order both shipping extensions add their streams); directions logged | step 3 of section 2 |
| Listener block for a custom property (E3) | 1 Hz poll always on | section 3 |
| The host-side data type of a custom extension property: the verified read is a CFString (ldenoue); the extension therefore publishes `sc=<n>` as `NSString` instead of a UInt32 `NSNumber`; the host also accepts a 4-byte UInt32 or a CFNumber reference | `ViewerWatcher.parseCount` handles all three; an unreadable property logs once and leaves the idle rule on "capture runs while the sink is connected" | `viewers=1` appears in the log when FaceTime starts |
| `CMIOStreamCopyBufferQueue` ownership of the returned `CMSimpleQueue` (Copy convention says +1; ldenoue takes it unretained and ships) | taken unretained: at worst one queue object is over-retained per connect, never over-released | none needed |
| CoreText (`CTFontCreateWithName`, `CTLineCreateWithAttributedString`, `CTLineDraw`) inside the sandboxed extension for the placeholder sentence; a system framework not named in ARCHITECTURE 1 | the card is rendered once at start-up; if CoreText ever failed the buffer still carries the cream card without text | step 5 of section 2 shows the sentence |
| `OSSystemExtensionError.Code.requestCanceled` (11) treated as "needs approval" and `requestSuperseded` (12) as "still activating"; neither has a SPEC 13.3 row | the matrix has no row; the closest remedy is shown; the code and message are logged | none |
| `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` opens the Camera Extensions pane on macOS 15 and later (E13) | the legacy Privacy & Security URL is tried next, then the text path is shown | step 2 of section 2 |
| `systemextensionsctl uninstall` subcommand (research 1.6) | the SETUP text says to delete and reinstall the app instead when the subcommand is missing | step 10 of section 2 |
| `CMSimpleQueueEnqueue` never blocks (documented as a simple array queue) | `count < capacity` is checked first, so a full queue is never offered a frame | `SinkFeederTests` with a real queue |

---

## 5. Requests for the integrator

1. Compile the extension's pure rules into the test bundle so SPEC C3 is a unit test instead of a source-text check: in `project.yml` under `DaylightTests.sources` add `- path: DaylightCameraExtension/Sources/ExtensionRules.swift`. The file imports Foundation only. After that lands I (or the integrator) replace `ExtensionBundleTests.testExtensionSourcesStayFreeOfDaylightKitAndPinTheRules` with direct assertions on `DaylightExtensionRules`.
2. Wire the sink in B's `AppDelegate.makeSink()` (B's handoff request 2, ARCHITECTURE section 18 "B's AppDelegate wiring"): `signed ? CMIOSinkClient(deviceUUID: deviceUUID, sinkUUID: sinkUUID, queue: cameraQueue) : PreviewOnlySink()` with the UUIDs from `Bundle.main.object(forInfoDictionaryKey:)` (`DaylightCameraDeviceUUID`, `DaylightCameraSinkUUID`) and a serial `DispatchQueue(label: "com.twelve.daylight.camera", qos: .userInitiated)`; construct `ExtensionInstaller()` at launch, call `activate()` as early as possible, forward `installer.onChange` to `(sink as? CMIOSinkClient)?.noteExtensionStatus($0)` and to the onboarding `ExtensionState` (`.needsApproval -> .awaitingApproval`, `.activating -> .activating`, `.installed -> .installed`, `.needsReboot -> .needsReboot`, `.failed(code, msg) -> .failed(ExtensionInstaller.failureCase(for: code) ?? .extensionDamaged, msg)`, `.notInApplications -> .failed(.notInApplications, path)`, `.unsignedBuild -> .unsignedBuild`); wire the Welcome step's "Open System Settings" to `installer.openApprovalPane()`; "Check again" can simply call `installer.activate()` again (a second activation request of an approved extension completes at once). `sink.onViewerCount` already reaches `PipelineControl.setViewerCount` in B's wiring; `CMIOSinkClient` owns the `ViewerWatcher`, so no separate watcher is needed (the standalone `ViewerWatcher(locator:queue:)` initialiser of plan 3.2 exists for anyone who wants one). Delete `UnwiredSink.swift`. B said it would do this itself if C landed while B was active; otherwise this is the integrator's pass.
3. Diagnostics (SPEC 13.2): B's `Diagnostics` can read `(sink as? CMIOSinkClient)?.queueCountAndCapacity`, `enqueuedFrames`, `droppedFrames`, `queueAlteredCount` and the locator's directions from the log; no contract change is needed because these are additive members on C's class.
4. No plist, entitlement or `project.yml` change is needed for the extension itself: the three UUID keys, `CMIOExtensionMachServiceName`, `NSSystemExtensionUsageDescription`, `CFBundlePackageType SYSX` and the two entitlements are already right; `ExtensionBundleTests` guards them.
5. `docs/SIGNING.md` owner checklist and the FaceTime first-light procedure: section 7 below.

---

## 6. Red CI runs caused by someone else's files

- Filled in after the first runs of this component.

---

## 7. Text for the owner-facing documents

### SIGNING.md: owner checklist (about 30 minutes, no Xcode needed)

Prerequisites: a paid Apple Developer Program membership where you hold the Account Holder role; any Mac with Keychain Access; the `gh` CLI logged in to the build repository.

1. Team ID: developer.apple.com/account > Membership details > copy the 10-character Team ID.
2. Certificate signing request: Keychain Access > menu Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority. Your email, Common Name "Daylight Developer ID", CA Email empty, "Saved to disk", Continue, save the `.certSigningRequest` file.
3. Developer ID certificate: Certificates, Identifiers & Profiles > Certificates > + > under Software choose Developer ID > Continue > pick the Application type (not Installer) > Choose File (your CSR) > Continue > Download the `.cer` > double-click it so it lands in Keychain Access under My Certificates.
4. Export the `.p12`: Keychain Access > login > My Certificates > "Developer ID Application: <you> (<TEAMID>)" (open the triangle: a private key must hang under it) > right-click > Export > format `.p12` > choose a strong password.
5. App IDs: Identifiers > + > App IDs > App > Description "Daylight" > Explicit Bundle ID `com.twelve.daylight` > tick System Extension and App Groups > Continue > Register. Repeat for `com.twelve.daylight.camera` with App Groups ticked. Do not register a `group.` app group; the Team ID form needs none.
6. Profiles: Profiles > + > Distribution: Developer ID > Continue > App ID `com.twelve.daylight` > Continue > select the Developer ID Application certificate > Continue > Name "Daylight Developer ID" > Generate > Download. Repeat for `com.twelve.daylight.camera` with the name "Daylight Camera Developer ID". If you ever edit an App ID's capabilities, regenerate its profile.
7. App Store Connect API key: appstoreconnect.apple.com > Users and Access > Integrations > App Store Connect API > Team Keys > + > name "Daylight CI notarization", role Developer (Admin if Developer is refused) > Generate > Download `AuthKey_<KEYID>.p8` (one chance) > note the Key ID and the Issuer ID.
8. Secrets, from the folder with the files: `gh secret set DAYLIGHT_TEAM_ID --body <TEAMID>`; `gh secret set DAYLIGHT_DEVELOPER_ID_P12_BASE64 < <(base64 -i developerID.p12)`; `gh secret set DAYLIGHT_DEVELOPER_ID_P12_PASSWORD --body '<password>'`; `gh secret set DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64 < <(base64 -i Daylight_Developer_ID.provisionprofile)`; `gh secret set DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64 < <(base64 -i Daylight_Camera_Developer_ID.provisionprofile)`; `gh secret set ASC_API_KEY_ID --body <KEYID>`; `gh secret set ASC_API_ISSUER_ID --body <ISSUER>`; `gh secret set ASC_API_PRIVATE_KEY_BASE64 < <(base64 -i AuthKey_<KEYID>.p8)`.
9. Re-run the workflow (Actions > whiteboard-camera > Run workflow with "notarize" ticked, or push a `v*` tag). Download `Daylight.dmg`.
10. Keep the `.p12`, both profiles and the `.p8` in your password manager. Profiles last 18 years.

What macOS does with it: a Developer ID signed system extension loads only when notarized (research-cmio-signing 0.4). The unsigned CI build is for compile checks and the preview window; it can never show "Daylight Camera" in Zoom.

### SETUP.md: first light in FaceTime (signed build)

Drag Daylight to Applications and open it from there. The Welcome window asks you to approve the camera extension: click "Open System Settings", switch on Daylight Camera under General > Login Items & Extensions > Camera Extensions (on macOS 13 and 14: Privacy & Security > Security), enter your password, return to Daylight and click "Check again". Open FaceTime and choose Video > Daylight Camera: your webcam appears. If FaceTime shows a cream card reading "Daylight is not running. Open Daylight from the menu bar.", Daylight is not running or not yet connected; open it from the menu bar. If Zoom shows a black picture after an update, quit and reopen Zoom.

### TESTING-CHECKLIST.md rows (about 8 minutes, signed build only)

- 🟢 Open from Downloads first: "Move Daylight to your Applications folder" (30 s)
- 🟢 Open from Applications: the approval prompt; "Open System Settings" lands on Camera Extensions; "Check again" turns the step green within 2 s (2 min)
- 📋 `systemextensionsctl list` shows `com.twelve.daylight.camera [activated enabled]` (30 s)
- 📋 Paste the `directions=[a, b]` log line into LOOSE_ENDS E2 (30 s)
- 🎥 Quit Daylight, pick Daylight Camera in FaceTime: the cream card with the sentence (30 s)
- 🎥 Reopen Daylight: the webcam replaces the card within 2 s; the log says `viewers=1` (30 s)
- ⏱️ Close FaceTime: `viewers=0` within 1 s; LED off after 60 s; reopen: picture back within a second (2 min)
- 🎥 Zoom and FaceTime together: `viewers=2`, both show the picture (1 min)
- 🟡 Row 13 on purpose: uninstall the extension, relaunch, read both sentences 30 s apart, approve again, connected without a relaunch (2 min)

### COMPARE.md (nothing to measure in this component)

The extension forwards the host's sample buffer unchanged; its contribution to glass-to-camera latency is one consume interval (at most 11 ms at 90 Hz) plus the viewer's own capture pipeline. `Daylight --perf-log` (B) prints the pushed and dropped counts that include this sink.
