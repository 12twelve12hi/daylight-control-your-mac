# Performance: what is measured, what was measured, what to measure

The budgets come from SPEC section 15; the runner numbers from the CI runs recorded in `docs/STATUS.md`; the owner's numbers are blank until the M5 Max and the DC-1 fill them (LOOSE_ENDS D16). Nothing in CI asserts a wall time: shared runners are too noisy. The tools below measure; the owner judges.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

## 1. Budgets (SPEC 15)

| Mode | Budget |
|---|---|
| Idle (no viewer, preview closed, extension connected) | under 1 percent of one core; capture stopped 60 s after the last viewer; camera LED off |
| Passthrough (a viewer, no board) | our code under 0.1 ms per frame; Activity Monitor under 3 percent (AVFoundation's own delivery dominates); zero pixel work when the webcam hands out IOSurface-backed 1920x1080 BGRA buffers |
| Studio Split LIVE | CPU under 0.2 ms per frame for encode, GPU under 1 ms, Activity Monitor under 8 percent; resident set under 120 MB |
| Mirror LIVE | Studio Split plus hardware decode; resident set under 180 MB |
| Engage | pen contact to the first moved frame leaving the Mac: under 60 ms (web, native), under 90 ms (mirror) |
| Slide | 8 distinct frames (0.321, 0.671, 0.860, 0.945, 0.979, 0.992, 0.997, 1) in 0.251 s, no dropped frame during the slide |

## 2. What the self-test measures (`Daylight --self-test`)

`make mac-smoke` runs the Release binary with `--self-test --perf-log` under a 120 s alarm on every push; the log is `xcodebuild-logs/self-test.log`. On the owner's Mac: quit Daylight, then `/Applications/Daylight.app/Contents/MacOS/Daylight --self-test --perf-log`. One line per probe, `self-test: PASS` at the end, exit 0 only when every probe passed. It never touches the camera or the local network (the listener binds 127.0.0.1 only).

Probes, in order:

1. Render probes at s = 0, 0.5 and 1 for Studio Split portrait, plus Whiteboard Only, landscape Studio Split and the mirror crop fit: cream margin, divider, paper and presenter pixels at the SPEC 6 coordinates; skipped with `WARNING no Metal device on this machine; render probes skipped` when there is no GPU. The first probe also reports the Metal device name and the first command buffer's completion time (cold GPU).
2. The WebSocket round trip against the real listener: the golden handshake, STROKE_START, STROKE_CHUNK, COMMIT; ACK 0 bytes 16 to 31; STATE with bit2 set then governor state 1 (ENGAGING); the subprotocol echo; the 2 MiB oversize frame closing with 1009.
3. Ink alpha along the stroke in the ink IOSurface; UNDO returns the alpha to zero; REDO brings it back.
4. The ink-source switch to Daylight Ink, mirror and back: STATE carries the `ink_source` byte and bit3; a stand-in tablet frame is composed while the source is mirror ("sink: frames pushed while engaged", waited for up to 2 s because the first composed frame can take about 70 ms cold).
5. Vendor facts: `lipo -archs` and the size of the bundled `adb`, the sha256 of `scrcpy-server-v4.1`, the embedded APK size; extension facts: the three UUIDs identical in both Info.plists, `CMIOExtensionMachServiceName`.

## 3. What the perf log measures (`--perf-log`)

One line per second on stdout while running from Terminal, or kept in Diagnostics' last 200 lines when Settings > Advanced > "Perf log (one line per second in the unified log)" is on:

`perf mode=<passthrough|engaging|split|whiteboard|returning> fps=<pushed per second> dropped=<n> cpu_ms=<encode time per frame> gpu_ms=<GPU time per frame> inflight=<pool buffers busy> zerocopy=<true|false> capture=<running|idle> viewers=<n>`

| Field | Meaning | Healthy |
|---|---|---|
| `mode` | the governor state and layout | `passthrough` in a call with no ink |
| `fps` | frames pushed to the extension per second | 30 (camera-paced in passthrough, the 30 Hz clock otherwise) |
| `dropped` | frames the pool or the sink refused (the sink queue has capacity 1) | 0 after the first second; a steady count means the extension is not consuming |
| `cpu_ms` | CPU time per frame to encode the command buffer | under 0.2 |
| `gpu_ms` | GPU time per frame | under 1 |
| `inflight` | output pool buffers not yet consumed (max 3) | 0 to 2 |
| `zerocopy` | passthrough forwards the camera buffer untouched | `true` with a 1080p BGRA IOSurface webcam; `false` means one composed pass per frame (row 5 names the format) |
| `capture` | `running`, or `idle` when the idle rule stopped the webcam | `idle` 60 s after the last viewer with the preview closed |
| `viewers` | apps streaming Daylight Camera, read from the extension once a second | 1 in a call, 0 after |

`--latency-probe` adds, once per session on the first engage, `engage probe: STROKE_START to first moved frame <ms>` (web, native); mirror logs `engage probe: pen contact at <t> (mirror)` and `first decoded frame at <t>`. The `OSSignposter` intervals `capture`, `composite`, `sink.push` (and `decode` in mirror mode) are visible in Instruments under subsystem `com.twelve.daylight`, category `perf`.

Diagnostics' "pipeline:" line shows the same numbers at the moment you open it.

## 4. Numbers recorded on the CI runner (macos-15, Xcode 16.4, no camera, unsigned build)

From the self-test and the hosted tests of runs 37121036066 and 37132513946 (`docs/STATUS.md` section 6):

| Fact | Value |
|---|---|
| Metal device | "Apple Paravirtual device" |
| First command buffer (cold) | 71 ms; then 13.5 ms and 1.2 ms |
| `CompositorTests` pixel probes | 0.5 to 1.1 s each including setup; cream, paper, divider and presenter colours asserted |
| `PipelineSmokeTests` | 25 or more zero-copy pushes per second with `FakeCapture`; at most two skipped ticks tolerated during the first second while the GPU warms, zero drops once frames flow |
| `H264DecoderTests` | six 320x240 BGRA IOSurface-backed frames decoded in PTS order through VideoToolbox; a 160x120 format change followed by two frames |
| Vendor `adb` | 19,993,936 bytes, `lipo -archs` prints `x86_64 arm64`, version 1.0.41 (37.0.0) |
| `scrcpy-server-v4.1` | 733,706 bytes, sha256 pinned in `scripts/fetch-tools.sh` |
| Embedded `DaylightInk.apk` | 7,841,168 bytes as logged by the self-test |

These say the pipeline runs and the budgets are plausible; they say nothing about real-camera passthrough, the LED, or Zoom, which only the owner's Mac can show.

## 5. Owner's Mac (fill in)

| Measurement | How | Value |
|---|---|---|
| Metal device and cold command buffer | first lines of `--self-test` | |
| Passthrough, Activity Monitor CPU, Daylight process, in a FaceTime call with no ink | 1 minute, read the average | |
| Passthrough `zerocopy` | the `perf` line, or Diagnostics "first frame:" | |
| Studio Split LIVE, Activity Monitor CPU and Memory while writing for a minute | | |
| Studio Split `cpu_ms`, `gpu_ms` | the `perf` line | |
| Idle, CPU after 60 s with no viewer and the preview closed; LED | Activity Monitor; look at the camera | |
| Mirror LIVE, Activity Monitor CPU and Memory; after 30 minutes (G14) | | |
| Engage, web | `--latency-probe`, `engage probe: STROKE_START to first moved frame <ms>` | |
| Engage, Daylight Ink | same | |
| Engage, mirror | `engage probe: pen contact at <t> (mirror)` to the next `perf` mode change; `first decoded frame at <t>` | |
| Slide | count distinct frames in a screen recording of the preview at 60 fps (expect 8) | |
| `dropped` during a 10-minute call | the `perf` line | |
| Webcam facts | Diagnostics "first frame: <w>x<h> <fourcc> iosurface=<bool> zeroCopy=<bool>" | |

Decisions these numbers drive: whether to switch on "Frame reuse (measure first)" (saves GPU in Whiteboard Only when nothing changes; LOOSE_ENDS E12) and "Deadline idling (measure first)" (sleeps the render clock between governor deadlines); both stay off until the numbers show a win (ARCHITECTURE 16). The spring stiffness (F11) is a feel decision, not a performance one.

## 📋 ADHD-friendly measurement checklist (⏱️ about 20 minutes, plus a 30-minute mirror soak)

- [ ] 🟢 Quit Daylight; Terminal: `/Applications/Daylight.app/Contents/MacOS/Daylight --self-test --perf-log`. You see: probe lines, the Metal device name, `self-test: PASS`. Write the device and the cold command buffer time. ⏱️ 1 minute
- [ ] 🟢 Terminal: `/Applications/Daylight.app/Contents/MacOS/Daylight --latency-probe --perf-log`; open FaceTime > Daylight Camera. You see: `perf mode=passthrough fps=30 ... zerocopy=true capture=running viewers=1`. Write `zerocopy`. ⏱️ 2 minutes
- [ ] 🟣 Activity Monitor > CPU, Daylight, one minute, no ink. Write the percent. ⏱️ 1 minute
- [ ] ✍️ Draw for one minute. You see: `mode=split`, `cpu_ms`, `gpu_ms`, `dropped`. Write them and the Activity Monitor CPU and Memory. ⏱️ 2 minutes
- [ ] 🟣 The first stroke's `engage probe: STROKE_START to first moved frame <ms>` line. Write it, per ink source. ⏱️ 3 minutes
- [ ] ⏱️ Close FaceTime and the preview; wait 60 s. You see: `capture=idle viewers=0`, the LED off; Activity Monitor CPU under 1 percent. ⏱️ 2 minutes
- [ ] 🟣 Screen-record the preview at 60 fps during one slide; step through: 8 distinct frames. ⏱️ 3 minutes
- [ ] ⏱️ Mirror for 30 minutes; Memory before and after. Write both. ⏱️ 30 minutes
- [ ] 📋 Copy every number into section 5 above; tick or untick "Frame reuse" and "Deadline idling" only if a number says so. ⏱️ 3 minutes
