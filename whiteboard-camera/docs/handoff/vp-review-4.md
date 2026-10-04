# Review round 4 and protocol fuzz parity (VP review, 2026-10-04)

Status: FINAL. The Review 4 team releases `mac/Daylight/Sources/{Pipeline,Camera,Ink,Server,Contracts}`, `App/Export`, `App/DiagnosticsExport.swift`, `mac/DaylightCameraExtension`, `mac/DaylightKit`, `web/src`, `web/tests` and `protocol/` (LOOSE_ENDS TS-3, TS-4 and TS-5 may proceed).

Scope: adversarial review of the phase 3 code (Presenter Overlay, Diagnostics export, `POST /api/facts`, the web facts module), and a seeded cross-language fuzz corpus run through the TypeScript, Swift (DaylightKit) and Kotlin codecs.

## How the round ran

- Three managers (Overlay; Diagnostics and facts; fuzz parity) worked in their own worktrees. Their sessions had no Agent tool, so each one did its own finder passes (three lenses) and its own refuting. To meet the two-independent-finders rule, the VP ran separate finders for each area, each with its own lens, and refuters whose default verdict was "not real":
  - Overlay: a lifetime, concurrency and Apple API lens, and a math, state machine, spec and load lens.
  - Diagnostics and facts: a security and adversarial input lens, and a format, concurrency and failure path lens.
  - Refuters: one for OV-1 to OV-5, one for OV-7 and OV-8, one for ten diagnostics candidates.
- The fuzz manager's refuter was a separate cloud session it created itself, because it had no Agent tool.
- Verdicts are CONFIRMED, CONFIRMED-UNVERIFIED (real only if an unverified Apple behaviour holds), BY-DESIGN (SPEC, PROTOCOL or a recorded decision says so) and REJECTED.
- The VP re-read every fix diff and checked every proving run's job conclusions through the API. The VP also ran `make golden-check fuzz-check` and the web unit tests (38 of 38) locally.
- Acceptance run: 37181016158 on 2c2a847. golden, web, kit-linux, android, mac and mac-26 are all green. android-emulator (another VP's non-blocking job) was cancelled.

## Findings, verdicts and fixes

### Presenter Overlay

| Id | Finding | Verdict | Fix | Test (fails before because) | Proving run |
|---|---|---|---|---|---|
| OV-1 | After the 15-failure fallback latched, `OverlayController.offer` still sent every frame to Vision and mask processing, for output nobody draws | CONFIRMED | 8240553: no offers while latched; they resume after the reset | `OverlayControllerTests.testFifteenFailuresFallBackWithExactlyOneRow48` (engine calls 20 instead of 15) | 37181016158 mac, mac-26 |
| OV-2 | A failed controller creation retried, and posted row 48, on every Settings change | CONFIRMED | abd3b40: creation-failed latch, cleared by turning Overlay off | `OverlayPipelineTests.testControllerCreationFailurePostsRow48OnceUntilToggled` (4 rows instead of 1; the throwing engine needs the new seam, so on the old code it fails to compile) | same |
| OV-3 | The mask processor never flushed its `CVMetalTextureCache`; the Compositor's flush comment cites the header's "must be made periodically" | CONFIRMED-UNVERIFIED (the code fact is proven; the consequence of not flushing is not) | 3f055d8: flush every 30 masks, before wrapping the next one, when no cached texture is in flight | `MaskProcessorTests.testTheMaskTextureCacheIsFlushedPeriodically` (counts flushes; weak, because it fails before only by not compiling) | same |
| OV-4 | The IIR blended the first mask after a pause with a history of any age: a ghost silhouette on re-engage | CONFIRMED | 3f055d8: a history older than 0.5 s (`OverlayLayout.staleMaskSeconds`) is not blended | `MaskProcessorTests.testAStaleHistoryIsNotBlended` (0.6 instead of 0) | same |
| OV-5 | `AppModel` clears `overlayFellBack` only on the enable toggle. After a quality change, the pipeline renders Overlay again, but the menu keeps row 48 and the status says Studio Split | CONFIRMED (two finders and a refuter) | not fixed: `App/AppModel.swift` belongs to the Mac UI VP | request 1 | n/a |
| OV-6 | Regression of OV-2: a creation failure at launch runs inside `FramePipeline.init`, before `AppDelegate` sets `onFailure`, so row 48 was lost and the latch stopped any re-post | CONFIRMED (two finders; the VP read the code) | e499255: the failure is held under the flags lock and delivered once by `onFailure`'s didSet | `OverlayPipelineTests.testCreationFailureAtInitIsDeliveredOnceWhenOnFailureIsSet` (0 rows instead of 1) | same |
| OV-7 | Masks are stamped with the offer time, so with segmentation slower than about 0.23 s the cutout alternates between matte and rectangle, and from 0.5 s it stays a rectangle | BY-DESIGN: SPEC 6.7 "older than 0.5 s"; the offer-time stamp is documented; the `perf overlay` line shows it | none; tuning note under E30 | n/a | n/a |
| OV-8 | While the fallback draws Studio Split under a governor layout of Overlay, the first press of D only changes `preferredLayout` | BY-DESIGN: SPEC D46 toggles on `preferredLayout`; the fallback lives at render level (D57) | none; a possible SPEC change is noted in LOOSE_ENDS R4-6 | n/a | n/a |

Rejected or by design, Overlay:
- Three rotating outputs against frames in flight: each output is published after `waitUntilCompleted`, and its slot is rewritten only three masks later.
- Spring overshoot: clamped.
- Quality change mid-flight: at most one extra count.
- Teardown mid-request: weak captures.
- Per-frame small allocations.
- NaN progress: no producer exists.
- Slow quality showing the rectangle: this is SPEC.
- Layout switch or enable toggle while LIVE: renders Studio Split.
- Int settings decode: the same pattern as every key.

### Diagnostics export, `/api/facts`, web facts

| Id | Finding | Verdict | Fix | Test | Proving run |
|---|---|---|---|---|---|
| WF-1 | A second "Send facts to Mac" tap left the first tap's "Sent to your Mac." visible while the new POST was in flight | CONFIRMED | 1c7b2f2 | facts.spec.ts "a second tap clears the previous result line..." (red locally before the fix) | 37181016158 web |
| AF-1 | No deadline before the HTTP head completes: a silent peer held its connection and descriptor forever | CONFIRMED (both lenses) | e2a5e57: `WebServer.headTimeout` 10 s | `FactsLoopbackTests.testIncompleteHeadIsClosedAtTheHeadDeadline` | 37181016158 mac, mac-26 |
| AF-2 | A Content-Length of digits that overflows `Int` answered 400; PROTOCOL 15.2 says 413 | CONFIRMED | e2a5e57 | `FactsRouteTests.testHugeContentLengthIs413` | same |
| AF-3 | The raw JSON key went into the 400 reason, which is logged, so a key containing a newline forged log lines | CONFIRMED | 6b8ad03: control characters become `?`, key cut to 64 characters | `FactsRouteTests.testReasonCarriesNoControlCharactersFromTheKey` | same |
| DX-1 | An IPv6 address right after `web:` or `ink:` (the facts store key) stayed whole | CONFIRMED | 84aa904 | `RedactorTests.testIPv6InAFactsKeyIsCut` | same |
| DX-2 | A child killed by a signal was reported as "exit status 11" | CONFIRMED | 84c3869: `CommandResult.signal`, "killed by signal N" | `testRealRunnerReportsADeathBySignal`, `testCrashedCommandIsNamedASignalInRow46AndTheManifest` | same |
| DX-3 | An IPv6 address followed by `:` ("facts from <v6>: 200", "client <v6>: ...") stayed whole | CONFIRMED | 84c3869: lookahead `(?![0-9A-Fa-f]\|:[0-9A-Fa-f:])` | `RedactorTests.testIPv6FollowedByAColonIsCut` | same |
| DX-4 | Any posted clientId of 9 to 64 hex digits joined the replace-everywhere list, so "000000000" rewrote numbers across the zip | CONFIRMED | 84c3869: only UUID-shaped posted ids | `testAPostedNonUUIDClientIdRewritesNothing` | same |
| DX-5 | A write that failed partway left a truncated zip under the final name | CONFIRMED-UNVERIFIED (whether Foundation unlinks it itself) | 84c3869: written as `.<UUID>.partial`, moved without replacing, removed on error | `testAFailedWriteLeavesNoZip` (through a write seam) | same |
| DX-6 | The self-test child's stdout is a pipe, so `print` is fully buffered and the only `fflush` comes after the last probe. A hang (SIGTERM, SIGKILL) or crash loses the lines that name the failing probe, which is exactly the case the child process exists for | CONFIRMED | not fixed: `App/SelfTest.swift` belongs to the Mac UI VP | request 2 | n/a |

Rejected or by design, diagnostics:
- Zip date clamps: the only input is `Date()`.
- Zip limits: 11 fixed ASCII names, a 16 MiB cap.
- SSIDs: no source exists.
- Grandchildren: the call still returns within its bound.
- Pipe deadlock: the pipe is drained concurrently.
- `Origin: null`, port mismatch, IPv6 host: correct.
- DNS rebinding: by design under PROTOCOL 15.2.
- The 413 drain limit of 16384: a vp-diagnostics decision.
- Eviction of the oldest of 16 senders: a vp-diagnostics decision.
- `saveDirectory` kept byte for byte: a FEEDBACK row. FEEDBACK line 39 ("home folder shows as ~") reads more broadly than this; see request 6.
- Host name in the Bonjour line: not on FEEDBACK's "never inside" list.
- Deep JSON nesting: CI shows 8000 levels answer 400 (`FactsRouteTests.testDeeplyNestedBodyIs400`).

### Protocol fuzz parity (FZ)

| Id | Divergence | Verdict | TypeScript | Swift (Kit) | Kotlin |
|---|---|---|---|---|---|
| FZ-1 | payload_len above 1 MiB not capped | CONFIRMED (PROTOCOL 3) | fixed 7a71695 | already rejected | pinned expected-failure, request 3 |
| FZ-2 | HANDSHAKE name or MIRROR_HELLO device name that is not valid UTF-8 accepted through a lossy decode | CONFIRMED; the spec was silent, now PROTOCOL 9 (8efd6a6) | n/a (decodes no client frames) | fixed baeb751 | n/a |
| FZ-3 | HANDSHAKE_ACK status above 3 decoded | CONFIRMED (PROTOCOL 6.2, 10) | already rejected | already rejected | pinned, request 3 |
| FZ-4 | STATE governor, mode or ink_source out of range accepted (TypeScript masked governor 6 into LIVE) | CONFIRMED (6.14, and 10 as amended in 8efd6a6) | fixed 7a71695 | fixed baeb751 | pinned, request 3 |
| FZ-5 | MIRROR_CONTROL command above 3 decoded | CONFIRMED (parity only: MirrorSession ignores unknown commands) | not decoded | already rejected | pinned, request 3 |

- Build:
  - `protocol/fuzz/gen_fuzz.py` is seeded, uses the standard library only, and imports the structs from `gen_golden.py`. `gen_golden.py` writes only under `__main__`, and the golden output is byte-identical.
  - The corpus is 761 cases (310 KB): 364 accept, 345 reject, 45 ignore, 7 encode_reject. It covers 12 random valid messages for each of the 17 v1 opcodes plus 0x0071 and 0x0080 to 0x0082, and the structured invalid kinds listed in `protocol/fuzz/README.md`.
  - `make fuzz-corpus` regenerates the corpus and copies it into the three test trees. `make fuzz-check` diffs all four copies against a fresh generation and runs in the golden job of both workflow files.
- Harnesses:
  - TypeScript: `web/tests/unit/fuzz.test.ts`, run by `make web-test`.
  - Swift: `DaylightKitTests/Protocol/FuzzCorpusTests.swift`, run by kit-linux and by the mac job's kit-test.
  - Kotlin: `android/app/src/test/kotlin/com/twelve/daylight/ink/FuzzCorpusTest.kt`, run by the android job. It asserts that the 13 pinned Kotlin cases still diverge, so it turns red when the Kotlin codec is fixed and the entries must be removed.
- Decisions:
  - A value outside a closed set listed in the spec is rejected (PROTOCOL 10 now says so). Unknown flag bits are kept, and reserved bytes are re-encoded as 0.
  - A 64-byte MIRROR_HELLO name with no NUL is accepted and canonicalised to 63 bytes, as scrcpy does.
  - A dirty session packet is accepted and canonicalised (tagged spec-ambiguous).
  - The 0-byte CLEAR_CANVAS canonical form is the 24-byte zero form.
  - PROTOCOL 15 (facts) is excluded, because only the Mac parses it.
- Proof: run 37181016158. golden 111373439508 (fuzz-check), web 111373439441, kit-linux 111373439349, android 111373439500, mac 111373766413 (kit-test).

### CI incident

| Id | What | State |
|---|---|---|
| CI-1 | Run 37179989574 (ee69a2c), mac-26 job 111370854099: `PipelineSmokeTests.testMirrorSourceIsComposedWhenSelected` ended in "Restarting after unexpected exit, crash, or test timeout", with no assertion line in the job log | OPEN, not called a flake. The same test passed on mac in that run, and on mac-26 and mac in runs 37180339019 and 37181016158. No commit in 26014a3..ee69a2c reaches its code path: Overlay is off in the test, and it uses a fake mirror source. c7f7280 replaces the test's force unwraps with `XCTUnwrap` and makes failed waits report the pipeline state, so a recurrence names the cause. The crash site is in `test.log` of artifact 11294917131, which this session cannot download because its proxy blocks the artifact host. Request 4 makes `mac-test.sh` print crash lines into the job log. LOOSE_ENDS R4-5. |

## Deliberately not fixed (with reasons)

- OV-5 and DX-6: in `App/`, which belongs to the Mac UI VP (requests 1 and 2).
- OV-7 and OV-8: by design (above).
- FZ-1, FZ-3, FZ-4 and FZ-5 in Kotlin: android main sources belong to the Emulator VP this phase (request 3). They are pinned, never silently green.
- No cap on concurrent listener connections: each idle connection is now bounded to 10 s (AF-1). A cap needs a product decision (LOOSE_ENDS R4-4).

## UNVERIFIED

- Reusing one `VNSequenceRequestHandler` across `qualityLevel` and frame-size changes. If it matters, the fix is a new request and handler on each change.
- Metal hazard tracking across the segmenter's and the compositor's command queues.
- The consequence of an unflushed `CVMetalTextureCache` (OV-3).
- Whether `Data.write` unlinks a partial file on error (DX-5 is fixed either way).
- Whether `JSONSerialization` has a depth limit (CI shows 400 at 8000 levels).
- The stdio buffer size on a Darwin pipe (DX-6).

## Requests for other domains

1. Mac UI VP, `App/AppModel.swift` `overlaySettingMayHaveChanged`: also clear `overlayFellBack` when `overlayQuality` changes while Overlay is enabled and a controller exists. After OV-2, a creation failure is not retried on a quality change, so do not clear it in that case. Test: `OverlayAppModelTests` sets the fallback, changes the quality, and expects `overlayFallbackLine == nil` (OV-5).
2. Mac UI VP, `App/SelfTest.swift` `SelfTest.run`: call `setvbuf(stdout, nil, _IOLBF, 0)` first thing, or `fflush(stdout)` after each print in `Report.check` and `Report.note`. Test (hosted): `ProcessCommandRunner().run(Bundle.main.executablePath!, ["--self-test"], timeout: 0.5, maxBytes: 1 << 20)` must time out with output containing "self-test: Daylight" (DX-6).
3. Emulator VP (android main). After each fix, delete the matching `knownDivergent` entries in `FuzzCorpusTest.kt`:
   - FZ-1, `protocol/Messages.kt` `Decoder.header`: after `val len = b.int`, add `if (len > 1_048_576) return null`. Entries: `oversize_unknown_op_1mib_plus_1`, `oversize_state_1mib_plus_1`, `mirror_packet_oversize`.
   - FZ-3, `Messages.kt`, HANDSHAKE_ACK branch: return null when status is outside 0..3. Entries: `ack_status_4`, `ack_status_255`, `ack_status_4294967295`. Trade-off: today an unknown status shows "Update Daylight". After the fix the frame is dropped, and `Link.kt` has no handshake timeout, so add one or keep the INCOMPATIBLE mapping before the drop.
   - FZ-4, `Messages.kt`, STATE branch: return null when governor > 3, mode > 3 or inkSource > 2. Entries: `state_governor_4`, `state_governor_ff`, `state_mode_4`, `state_ink_source_3`, `state_ink_source_ff`.
   - FZ-5, `protocol/MirrorFraming.kt` `decodeControlPayload`: return null when command is outside 0..3. Entries: `mirror_control_cmd_4`, `mirror_control_cmd_255`.
4. Scripts owner, `scripts/mac-test.sh`, the on-failure block: after the "failed test cases" grep, add `grep -E 'Fatal error|Thread [0-9]+ Crashed|Exception Type|Termination Reason|EXC_[A-Z_]+|Assertion failed|BUG IN CLIENT' build/xcodebuild-logs/test.log | head -40 >&2 || true`, so a crash names its frame in the job log (CI-1).
5. Anyone with artifact access: open `test.log` in artifact 11294917131 (run 37179989574) and grep those lines around the relaunch. If the frame is in Pipeline, it is a pipeline bug to fix (CI-1).
6. Docs owner, optional: FEEDBACK line 39 ("your home folder shows as ~") versus the kept `saveDirectory`. Word it as "except the save folder, which stays as you chose it".
7. Optional, Daylight Ink `SettingsFacts.kt`: ignore a second tap while "Sending to your Mac." is shown.

## Red CI runs caused by others

- 37180795754 (e652d9f): the android job failed on the Daylight Ink EdgeToEdge commit, so mac and mac-26 were skipped. A later run is green.
- android-emulator, another VP's non-blocking job, was cancelled or failed in several runs.
- 37179989574: mac-26 (CI-1 above).

## Process notes

- The managers had no Agent tool, so the two-finder and refuter structure ran from the VP level (above).
- The fuzz manager created one cloud session (`session_01Rg6SFhLdHgLv4RaeSAPoTu`) as its refuter.
- Every commit of this round carries this session's own attribution trailers rather than the charter's pair, which names another session. Published history is not rewritten.
- Pushes from three VPs kept cancelling the Linux jobs, and the mac jobs depend on them and were then skipped. A docs push is held while a run's Linux jobs are in flight.
