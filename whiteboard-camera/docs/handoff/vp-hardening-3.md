# VP handoff: hardening round 3 (2026-10-03)

Scope: the code phase 2 added in the mirror area (adb sources, the scrcpy USB path after the transport switch, the Wi-Fi mirror transport on both ends, frame-difference engage, the Android screen stream service, PROTOCOL 14 parity), plus LOOSE_ENDS J2, J3, J5, I8 and I9. Starting point c396ab0.

## 1. How the round ran

- Twelve finders, two per sub-area with different lenses (correctness and reproduction plus the first-day owner; concurrency, lifetime, process handling and the Apple or Android API contract), read a frozen snapshot of c396ab0. Sub-areas: adb sources, USB path regressions, Wi-Fi demux and decode, frame-diff engage, Android stream service, PROTOCOL 14 parity.
- Six independent refuters, one per sub-area, judged every finding with the default verdict "not real", merged duplicates across lenses and files, and named the fix and the test. Two refuters fetched platform sources to settle a verdict (AOSP android13 `MediaProjectionManagerService` for the second-grant case; the MediaCodec reference for `createInputSurface` release).
- Six managers fixed what was confirmed, each owning a disjoint file set at a time, each fix with a test that fails before it. The frame-diff redesign was prototyped in Python against synthetic H.264-like frames before the Swift port (`FrameDiffEngageTests` mirrors the prototype's cases).
- The VP read every report, spot-checked the high-severity diffs (W1, J2, J3, J5, ADB-B3) against the code, and pushed in batches.

Counts: 62 findings from the finders; after merging duplicates within each sub-area 46 distinct items: 35 confirmed (2 high: W1 and DIFF-A1; the rest medium or low), 6 plausible but unverified (each got the cheap guard), 3 rejected, 2 duplicates of known loose ends (J2, J3). Three items appear in two sub-areas (W1 with AND-A1 as the two ends of one deadlock, P14-B5 = AND-A2, P14-B3 = AND-A3). Every confirmed item is fixed in code with a test, except ADB-A1w (an App request, section 4) and P14-B4 (section 5).

## 2. Loose ends named in the charter

| Item | Commit | What changed | Test (fails before) |
|---|---|---|---|
| J2 adb source applies only after relaunch | 7b3e53b, 6be6412 | `MirrorController.adbSourceChanged`: on an `adbSource` or `adbTermsAcceptedVersion` change the tracker, session and pen watcher stop, the located adb, policy decision and `adbUnavailable` are dropped, tracking restarts when mirror is active. A policy decision in flight for the old source is discarded. Download on first use polls the install folder every 2 s (file check only) so a download that finishes after the terms were saved applies without a settings change. Never `adb kill-server`, also not for a server the old adb started (reason in the code comment). Settings footnote and SETUP 2.3 say "applies at once". | `testANewAdbSourceAppliesWithoutARelaunch`, `testAFinishedDownloadAppliesWithoutASettingsChange` |
| J3 RELEASE on quit may not flush | 7977cbb | `WifiMirrorSource.release(timeout:)` closes each capable connection right behind its RELEASE (1001) and waits at most 0.3 s until the server reports each closed (`forget`), never on ink.queue. No Server/ or App/ change. | `testReleaseOnQuitWaitsUntilTheServerClosedTheConnection`, `testReleaseOnQuitIsBounded` |
| J5 strict enum decoding resets settings on downgrade | 2b1d419 | Every enum key (`inkSource`, `preferredLayout`, `mirrorPinClearMode`, `mirrorPillsPosition`, `adbServerMode`, `adbSource`, `mirrorTransport`) decodes leniently to its own default; `hotkeys` drops unknown actions and keeps the rest. | `SettingsLenientDecodingTests` (3 tests, kit-linux) |
| I9 cold-GPU skipped ticks on macos-26 | 50d3c64 | `PipelineSmokeTests.testEngageReachesLiveAndComposedFramesFlow` warms the GPU with three `renderSync` passes before engaging; the cold phase ends on a condition (LIVE and composed frames reach the sink), must end within 2.5 s, and its skips are bounded by the 30 Hz ticks it lasted; after it, zero drops, `feeder.droppedFrames == 0`, `inFlight <= 3` exactly as before. | flake removal (proof: mac-26 green) |
| I8 fixed windows and the StylusWatcher race | 952d0d6, 7580bda | `StylusWatcher` reports `.watching` only after the getevent child started (USB-B1, a real ordering bug the tests raced on); DeviceTracker, ScrcpySession and MirrorController tests wait on conditions. The two "nothing happens" checks keep a bounded window after draining the queues, so they can only under-count. | `testWatchingIsReportedOnlyOnceTheGeteventChildRuns` |

## 3. Findings, verdicts and fixes

Ids: the finder id; merged duplicates are listed together. Severity is the refuter's.

### adb sources

| Id | Verdict | Fix | Test |
|---|---|---|---|
| ADB-1 (A2+B1) medium: before the terms are accepted (a `DAYLIGHT_BUNDLE_ADB=0` build, or a pin bump) Settings hid every button leading to the terms prompt | CONFIRMED | 9c72120: `AdbSourceModel.refresh` treats terms-not-accepted like not-downloaded, so "Download adb" (which opens the terms) stays | `testSettingsKeepsThePathToTheTermsBeforeTheyAreAccepted` |
| ADB-2 (A3) medium: "not downloaded yet" raised row 40 "Could not download adb ... check the internet connection", log line with a literal `<error>` | CONFIRMED | 7bb9dc6: no banner, its own status sentence and log line | `testNotDownloadedYetIsNotADownloadFailure` |
| ADB-3 (A4+B4) low: row 41 says the tampered copy "was deleted" but only the manifest was | CONFIRMED | 3eb4c68: binary, NOTICE and manifest removed | `testTamperedCopyFailsTheChecksumBeforeUse` |
| ADB-B5 low: a second download could run alongside the first | CONFIRMED | e978bc0: single-flight `AdbDownloader.ensure` | `testASecondEnsureJoinsTheDownloadInFlight` |
| ADB-A5 low: two MirrorController tests went red on a `DAYLIGHT_BUNDLE_ADB=0` build | CONFIRMED | 30f1ade: injectable `bundledAvailable` | `testABuildWithoutBundledAdbResolvesBundledAsDownload` |
| ADB-B3: fixed 50 ms after exit could lose the scrcpy server's last stderr line | PLAUSIBLE, guarded | 0e9ad98: `onExit` after both pipe EOFs and the exit, capped at 1 s | `testTheLastStderrChunkArrivesBeforeTheExit` |
| ADB-A1w low: "Try Wi-Fi mirror now" with no adb ends on row 32 over the real source row | CONFIRMED | request to App (section 4) | |
| ADB-A1 (USB part) | REJECTED | the button needs a listed USB device, which needs a working adb | |
| ADB-B2 | DUPLICATE of J2 | | |

### USB path after the transport switch

| Id | Verdict | Fix | Test |
|---|---|---|---|
| USB-A1/B2 low to medium: adb failure replaced by a permanent "no device" after a transport switch | CONFIRMED | c1459d3: no tracker means keep the status and run `startTracking()` again | `testATransportSwitchWithoutAdbKeepsTheCause` |
| USB-A2/B3 low: after a switch the board and Save show the other transport's old frame | CONFIRMED | c1459d3 clears the USB slot, cc9b516 the Wi-Fi slot; save order is a request to App | `testATransportSwitchDropsTheUSBFrame`, `testASwitchToUSBDropsTheWifiFrame` |
| USB-A3/B5 low: a stale `.watching` from a stopped watcher left `penWatching` true, silencing frame-diff | CONFIRMED (scenario 2 rejected) | 08c3927: callbacks from a watcher that is not `self.stylus` are ignored | `testAStaleWatchingFromAStoppedPenWatcherIsIgnored` |
| USB-B4: a TCP-listed Daylight could hide the USB one from the pen watcher in Wi-Fi mode | PLAUSIBLE, guarded | 08c3927: Wi-Fi mode picks only USB devices | `testWifiTransportWatchesTheUSBPenWhenATCPDaylightIsListedFirst` |
| USB-B6 low: row 28 raised next to row 37 in the Wi-Fi transport | CONFIRMED | 08c3927: row 28 only in USB | `testWifiTransportWithoutAPenNodeRaisesRow37NotRow28` |
| USB-B1 medium (test race) | CONFIRMED | 952d0d6 (section 2) | |
| USB-B7 (:134-138) low | CONFIRMED | 7580bda | |
| USB-B7 (:151-157) | REJECTED | one serial FakeAdb queue, no realistic interleaving | |

### Wi-Fi mirror (Mac) and PROTOCOL 14

| Id | Verdict | Fix | Test |
|---|---|---|---|
| W1 (WIFI-A1, WIFI-B1, P14-B1) high: Cancel or notification Stop, then Share again: tablet PAUSED, Mac idle, nothing ever STARTs | CONFIRMED | aa6f452 (Mac: PAUSED from the start target gets START again, streamerID guard against ping-pong) and fd3f452 (tablet: `macWantsStream`, AND-A1); PROTOCOL 14.3 and 14.5 in 3047982 | `testPausedAfterADenialAndShareGetsStartAgain`, `testPausedAfterAProjectionEndedGetsStartAgain`, guards `testPausedAfterNewestHelloWinsGetsNoStart`, `testPausedAfterReleaseSendsNothing`; Android `aShareAfterCancellingTheMacsRequestStreamsAtOnce` |
| W2 (WIFI-A2, P14-B2) medium: row 34 pointed at a notification already cancelled | CONFIRMED | ae7f2d3: "On the tablet open Daylight Ink > Settings > Share screen with your Mac and choose Start now." in FailureText, SPEC 13.3, SETUP, TESTING-CHECKLIST, OWNER-NEXT-STEPS | `FailureTextTests` |
| W3 low: a newer UNSUPPORTED connection took over the status | CONFIRMED | 7a61f89 | `testUnsupportedNewerConnectionDoesNotHideTheStartedOnesState` |
| W4 (WIFI-A4, WIFI-B2) medium: no row 27 recovery on Wi-Fi; `.noFormat` never armed the 12 s wait (USB too) | CONFIRMED | a26d968 (decoder arms the wait on `.noFormat`, injectable clock), 89060f5 (REQUEST_KEY_FRAME on a decode error at most 1/s; STOP then START on rejected parameter sets or 12 s without a key frame) | `testDecodeWithoutAFormatArmsTheRow27Wait`, `testRejectedParameterSetsRestartTheStream`, `testNoDecodableFrameForTwelveSecondsRestartsTheStream` |
| W5 (WIFI-A5): deltas decoded after a demuxer reset | PLAUSIBLE, guarded | a26d968: `.discontinuity` and `awaitKeyFrame()` | `testAwaitKeyFrameDropsDeltaFramesUntilTheNextKeyFrame` |
| W6 (WIFI-A6, WIFI-B4, P14-A1, P14-B6b) low: a rejected HELLO still took over the stream | CONFIRMED | a26d968: `.streamStarted` only after acceptance, `.helloRejected` maps to row 35 | `testHelloWithACodecErrorIsRejected`, `testRejectedHelloDoesNotTakeOverTheStream` |
| W7 (WIFI-A7, WIFI-B3) low: a late old-stream frame pinned the old size | CONFIRMED | 89060f5: stream generation | `testAFrameOfThePreviousStreamDoesNotSetTheNewStreamsSize` |
| P14-A2(b) low: decode errors logged every frame | CONFIRMED | a26d968 | `testMalformedStatusIsLoggedOncePerReceiver` |
| P14-A3 low: reserved opcodes swallowed silently; client 0x0071 logged every frame | CONFIRMED | 28fa96d | `testReservedMirrorOpcodesGoToTheRouter`, `testControlFromAClientIsLoggedOnce` |
| P14-B4 low: a pre-mirror Daylight Ink gets row 38 "Open Daylight Ink" while open | CONFIRMED | not fixed: needs a new FailureText row (section 5) | |
| P14-B5 low: leaving Settings while sharing redials the socket | CONFIRMED | = AND-A2 | |
| P14-B3 | PLAUSIBLE | = AND-A3 guard | |
| P14-A2(a), P14-B6(a): unknown STATUS state dropped | REJECTED | no sender produces it; spec gap recorded (section 5) | |

Byte parity holds: `gen_golden.py` reproduces the checked-in vectors (md5 b886991691fe4ad7f8ed7bcf475c555d in all four copies) and the Kit, Android and web decoders agree on every case; no vector both sides could pass while disagreeing.

### Frame-difference engage

| Id | Verdict | Fix | Test |
|---|---|---|---|
| DIFF-A1 high: one pixel per cell, compared only with the previous frame: real writing (2 to 4 px, 100 to 600 px/s) changed at most 1 or 2 samples per frame against a floor of 7, so it never engaged; the hosted test used a 120x12 block per frame (about 3600 px/s) | CONFIRMED (two independent simulations) | 3c4767e: 144x192 pooled cells (about 8x8 px, mean of a 2x2-strided sub-sample), a run of active frames summed against the baseline before the run; engage at 2 or more active frames and `ceil(threshold x 3072)` moved cells. Python prototype: 216 of 216 strokes engaged (2 to 4 px, 100 to 600 px/s, 10 to 30 fps), worst latency 0.53 s, median 0.07 to 0.5 s; cursor blink, clock digit, lossy repeat and IDR noise: 0 engages. SPEC F10, SPEC 8 and the settings row rewritten (8351748). | `testAThinDiagonalStrokeAtWritingSpeedEngagesWithin0_4sAndReleasesAfterItStops`, `testASlowThinStroke`, `testThinInkAnywhereInsideACellMovesIt`, hosted `testAThinStrokeAtWritingSpeedEngagesAndQuietReleasesAfterOneSecond` |
| DIFF-A2/B3 low: a crop change compared grids of different crops | CONFIRMED | 3c4767e `reprime()`, 7d86a49 wiring | `testACropChangeReprimesInsteadOfEngaging`, `testACropChangeKeepsAHeldContact` |
| DIFF-A3/B2 low: the gap rule ran on decode time, so a Wi-Fi burst joined changes 0.6 s apart | CONFIRMED | 3c4767e `mediaTime`, 7d86a49 passes the PTS | `testTheRunGapUsesTheFramePtsNotTheDecodeTime`, `testTheRunGapUsesMediaTime` |
| DIFF-A5/B5 low: a dead or restarting getevent kept `penWatching` true | CONFIRMED | 08c3927: `.restarting` status; the flag follows it | `testADeadGeteventNoLongerSuppressesFrameDifference`, `testEOFReportsRestartingUntilTheNextChildRuns` |
| DIFF-A6 low: the two lowest threshold steps were the same 4 cells | CONFIRMED | 3c4767e: 2, 4, 7 (default, unchanged), up to 154 cells; label "Change threshold: N canvas cells" (7d86a49) | `testEveryThresholdStepIsADistinctCellCount` |
| DIFF-B4 low: row 37 raised on a startup race with USB attached, never withdrawn | CONFIRMED | 08c3927: held until the pen probe settles, `onResolve` when the pen watcher starts; App wiring is a request | `testRow37WaitsForThePenProbeAndIsResolvedWhenThePenWatcherStarts` |
| DIFF-B6 low: another source clearing the shared pen-contact slot left frame-diff silent | CONFIRMED | 7d86a49: re-asserts down at most every 0.5 s while writing continues | `testContinuedWritingReassertsTheContactTwicePerSecondAtMost` |
| DIFF-A4 (rotation animation), DIFF-B1 (lossy repeat completes a run) | PLAUSIBLE, guarded | 3c4767e: 0.5 s settle after a session start; strict 0.2 s gap | `testTheSettleWindowAfterASessionStartIgnoresAnAnimation`, `testTheRunGapIsStrict`, `testALossyFrameFollowedByItsCleanRepeatNeverEngages` |

### Android stream service

| Id | Verdict | Fix | Test |
|---|---|---|---|
| AND-A1 medium: Share after Cancel or Stop lands in PAUSED | CONFIRMED | fd3f452 `macWantsStream` (cleared only by STOP, RELEASE, a lost connection) | `aShareAfterCancellingTheMacsRequestStreamsAtOnce`, `aShareAfterTheMacsStopOrALostConnectionWaitsPaused` |
| AND-A2 low: leaving Settings while sharing flipped the role and redialed | CONFIRMED | 3eeb0f9 (the refuter's narrow fix: only ink to overlay is deferred, only while LIVE, the screen holder present and the pills holder absent) | `HolderRolesTest.leavingSettingsWhileSharingKeepsTheLiveSocket` |
| AND-A3/B-1 medium-low: two consent dialogs, granting both ends in PROJECTION_ENDED (AOSP android13 stops the first projection; the shared callback then releases the second) | CONFIRMED | 0b59714: a grant while a projection is held is not used; asking again stays possible | `aSecondGrantWhileAProjectionIsHeldIsNotUsedButAskingAgainStaysPossible` |
| AND-A4/B-3 medium: deltas sent after a dropped one corrupt the picture up to 10 s | CONFIRMED | 321b536 `dropUntilKey`; PROTOCOL 14.2 sentence c01475f | `afterADropEveryDeltaIsDroppedUntilAKeyFrame`, `anOversizeGapDropsDeltasUntilAKeyFrame` |
| AND-A6/B-2 low: stale encoder results (HELLO after PAUSED, a stale failure killing a restart) | CONFIRMED | bb24cce: start generation checked under one lock before HELLO and in the callbacks | `anOlderStartsEncoderResultsAreIgnored` |
| AND-B-4 low: input Surface leaked when codec start throws | CONFIRMED | 8363e94 | `SourceRulesTest.aFailedCodecStartReleasesItsInputSurface` |
| AND-A5: a disconnected PAUSED holds the projection with redials | DUPLICATE of J3 (design) | aspects added to LOOSE_ENDS R3-6 | |

The Android manager compiled the main source set against Robolectric's Android 14 framework jar in a scratch Gradle project and ran the touched JVM test classes there (MirrorSessionTest 38, MirrorBackpressureTest 10, LinkTest 15, HolderRolesTest 6, SourceRulesTest 14, ManifestTest 7); the CI android job is the proof of record.

## 4. Requests for other owners (not done here)

1. App (`AppDelegate.applySettings`, about :538): on a `mirrorTransport` change call `saveMirrorSessionIfNeeded()` before `mirrorController?.updateSettings(settings)`; `usesWifi` flips inside it, so a later save reads the wrong slot (USB-A2/B3).
2. App (where `mirror.onFailure` is wired, about :267): `mirror.onResolve = { cases in DispatchQueue.main.async { model.resolve(cases) } }`; without it row 37 is held correctly but never withdrawn (DIFF-B4).
3. App (about :523): drop the `noteFailure` row 32 in "Try Wi-Fi mirror now" when adb itself failed; it replaces the adb source row (ADB-A1w).
4. Settings (optional): `.disabled(model.downloading)` on the adb source picker; the download is single-flight already (ADB-B5).

## 5. Deliberately not fixed

- ADB-1's menu half: the menu still raises row 39 ("you declined the terms") when the terms were never shown (a pin bump, a no-adb build). Settings now offers the way forward; the row's trigger needs a SPEC 13.3 wording decision (a "not reviewed yet" variant, or row 25 only).
- P14-B4: a pre-mirror Daylight Ink gets row 38; the right sentence ("Update Daylight Ink") needs a new FailureText row and SPEC row. Not added while another VP is adding rows 44 to 47.
- Unknown MIRROR_STATUS state values (P14-A2(a)): PROTOCOL 10 does not list new states as a compatible addition; a future state 9 needs a version bump or a lenient-decode rule written first.
- Frame-diff trade-offs (UNVERIFIED until the device): below 6 fps (Max fps can be set to 1) frames are 0.2 s or more apart and frame-diff cannot engage (the old rule worked down to 4 fps); full-frame codec noise of sigma 8 with heavy ringing would engage (sigma 3 does not), which is D21; the sampler's cost (about 450,000 reads per frame) is estimated at 1 ms and unmeasured.
- An installed adb added with Homebrew while Daylight runs is not re-probed until a source change or relaunch.
- J3: that `.contentProcessed` on the final send means the bytes reached the kernel socket buffer is our reading of Network.framework, UNVERIFIED.

## 6. Commit attribution

The commits of this round end with the session attribution the harness supplies (`Co-Authored-By` and `Claude-Session` lines of this session), not the trailer pair written in the charter; every manager hit the same two instructions and followed the harness. The trailers are the only place a model name appears.

## 7. CI

Run https://github.com/12twelve12hi/daylight-control-your-mac/actions/runs/37158885096 on 7bb9dc6 (J2, J3, J5, I8, I9, ADB-2): every job green including mac and mac-26. Run https://github.com/12twelve12hi/daylight-control-your-mac/actions/runs/37160970105 on c32357b (every fix of the round): all six jobs green; 364 of 364 Kit tests; every new hosted test of this round passed by name; `self-test: PASS`. Reds on the way: `LumaGridTests` type-check time on kit-linux (run 37160015702, ours, fixed in 28b61d1); `OverlaySettingsTests` (run 37159402591) and `App/Export/ZipArchive.swift:44` (runs 37159468412, 37160202127), other VPs' files, fixed by their owners. The final docs commit's runs are in STATUS "Review round 3".
