# Compare: the three ink sources

Three ways for the pen on the Daylight DC-1 to reach Daylight Camera. All three are built so the owner can switch between them in one click (menu bar > "Ink source") and judge them on the same call. This page is the honest comparison before any measurement, the recommendation per use case, and the measurement plan; the "Measured" rows are blank until the owner's hardware fills them.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

## 1. Strokes versus video, the owner's question

The web page and Daylight Ink send strokes: every pen sample becomes a few bytes (position, pressure, time since the stroke began) in a binary message, and the Mac draws the ink itself into the camera picture. Mirror mode sends video: the tablet encodes its whole screen as H.264, the Mac decodes it and crops it into the board slot, and the pen is only watched to know when to slide.

Sending "delta operations" between frames is what an H.264 encoder already does; a stroke protocol is the same idea in its smallest, lowest-latency, exportable form. The consequences:

| | Strokes (web, Daylight Ink) | Video (mirror) |
|---|---|---|
| Bytes per second while writing | tens of bytes per sample, a few KB/s at the digitizer rate | about 1 MB/s at the standard quality (8 Mbit/s), half that on "Low bandwidth" |
| Glass to the Mac's canvas | roughly 20 to 40 ms (one Wi-Fi hop, no encoding) | 100 to 200 ms (encoder, adb, VideoToolbox) |
| Pen contact to the slide starting | under 60 ms budget | under 90 ms budget (the `getevent` text stream, not the video, triggers the slide) |
| Fidelity | the Mac renders at 1200x1600 with pressure widths, round caps, the highlighter multiplied under the ink; crisp at any zoom | the tablet's own rendering, compressed, scaled from the screen size to the board slot; readable, not crisp |
| What you draw in | our whiteboard (pen, highlighter, eraser, undo, redo, pages) | any app on the tablet, including the SolOS note app |
| Record | `page-NN.png` plus `page-NN.json` with every stroke (vector) | `mirror-<HH-mm-ss>.png`, the last frame, no vectors |
| Tablet battery | low (a web page or a small app, screen on) | higher (the encoder runs continuously) |
| Tablet setup | none (web) or one install (Daylight Ink) | USB debugging, a cable, the RSA prompt |

## 2. Side by side

| | Web whiteboard | Daylight Ink | Mirror |
|---|---|---|---|
| Install on the tablet | nothing; Chrome opens a page the Mac serves | one APK (over the cable in one click, or downloaded from the web page's "?" card) | the Daylight Ink APK for the pills (installed over the cable automatically) plus USB debugging |
| Pairing | type the address once, "Allow" once, add to the home screen | "Set up over USB" once, or open the app and "Allow" once; it reconnects by itself every day | plug in once, "Always allow from this computer"; every later day plugging in is enough |
| Needs USB debugging | no | no | yes |
| Pen input path | Chrome pointer events; one sample per display frame on a plain `http://` origin, the full digitizer rate on `localhost` or with the one-time Chrome flag | `MotionEvent` with unbuffered dispatch, the full digitizer rate, one chunk per frame or per sample (Settings A/B) | the Wacom evdev node read over `adb shell getevent` |
| Wet ink on the tablet | drawn by the page at the frame rate | front-buffer rendering (lowest latency wet ink; toggle in Settings for A/B) | the note app's own |
| Pin and Clear | the chip (tap pins, hold returns), the toolbar | the chip, the toolbar, the pills | the pills, the pen side button (double press pins, hold clears), or both |
| Expected engage latency | 35 to 60 ms pen to camera | the same, slightly lower | 60 to 90 ms engage, 100 to 200 ms picture |
| Bandwidth | KB/s | KB/s | about 1 MB/s |
| Works over Tailscale or an isolated office network | yes with the numeric address; USB as the fallback | yes with the address typed once; USB as the fallback | USB only (Wi-Fi mirror after a USB session is an interim, `adb tcpip 5555`) |
| What breaks it | a non-secure origin dims the screen and halves the sample rate (flag or USB cures it); Chrome tab discards lose the local strokes (the Mac keeps its own) | Bonjour blocked (type the address); a Bonjour answer with a link-local IPv6 address only (type the address) | a second adb on the Mac (row 24); SolOS hiding the Wacom node (row 28) or the side button (row 28b); a SolOS update changing scrcpy's hidden APIs (row 25); a 7-day adb authorisation expiry without the developer toggle |
| Reconnect after a Wi-Fi blip | automatic; the strokes drawn during the gap are replayed from an offline ring | automatic; strokes during the gap stay on the tablet only | automatic replug detection; Wi-Fi mirror reconnects when enabled |
| Measured engage (ms) | | | |
| Measured RTT (ms) | | | |
| Measured picture delay (ms) | n/a | n/a | |
| Measured Mac CPU, Activity Monitor (percent) | | | |
| Measured tablet battery drop over 30 min (percent) | | | |

## 3. Recommendation per use case

| Use case | Pick | Why |
|---|---|---|
| Daily meetings, your own tablet | Daylight Ink | lowest latency wet ink, reconnects by itself, no debugging, vector record |
| A borrowed or second tablet, no time to install anything | Web whiteboard | nothing to install; one address, one Allow |
| Office or school Wi-Fi that isolates clients | Web or Daylight Ink over USB, or over Tailscale | the cable is a network; Bonjour and `.local` do not cross isolation |
| You want the SolOS note app (or any app) on camera | Mirror | the only source that shows another app |
| Teaching with pages you keep | Web or Daylight Ink | the strokes JSON and the 1200x1600 PNG per page |
| Judging whether to ship adb and scrcpy to customers (SPEC 17) | measure mirror against Daylight Ink for a week | the consumer default is the native app; mirror's end state is a SolOS service (LOOSE_ENDS A9) |

The engage detector, the slide, the 90 s return, the 85 s warning and the pin rules are the same value type for all three sources, so any difference you feel is transport latency and rendering, not governor behaviour.

## 4. Measurement plan (one evening, about 45 minutes)

Do each block for each source. Write the numbers into the "Measured" rows above and into `docs/PERFORMANCE.md`.

### 4.1 Round trip (2 min per source)

- Web: tap "?" on the page; the card's `rtt <n> ms` line is the WebSocket ping time.
- Daylight Ink: `adb logcat -s DaylightInk.net` shows `pong N rtt=<n>ms` lines every 10 s.
- Mirror: no round trip; skip.

### 4.2 Engage latency, pen contact to the first moved frame (5 min per source)

Quit Daylight, then in Terminal run `/Applications/Daylight.app/Contents/MacOS/Daylight --latency-probe --perf-log`. Draw one stroke from the camera state per session. For web and Daylight Ink the Mac logs `engage probe: STROKE_START to first moved frame <ms>` (the first engage of each session; the Wi-Fi hop from glass to STROKE_START is not inside this number, add the RTT/2). For mirror the Mac logs `engage probe: pen contact at <t> (mirror)` followed by `first decoded frame at <t>`; the difference is the picture delay after engage, and the next `perf` line shows the mode change. Budgets: under 60 ms (web, native), under 90 ms (mirror).

### 4.3 Picture delay, mirror only (5 min)

Open a stopwatch app on the tablet showing hundredths. Photograph the tablet and the Mac preview in one frame (phone camera). The difference between the two readings is the glass-to-preview delay (expect 100 to 200 ms). Repeat three times; take the median. Diagnostics also shows `mirror.decoder.hardware` (whether VideoToolbox used the hardware decoder) and `mirror.session.size`.

### 4.4 Mac cost (5 min per source)

Activity Monitor > CPU, the Daylight process, during one minute of continuous writing in Studio Split, and one minute idle in the camera state. Also the Memory column (resident set). Budgets (SPEC 15): idle under 1 percent with the LED off, passthrough under 3 percent, Studio Split under 8 percent and under 120 MB, mirror under 180 MB. `--perf-log` adds `cpu_ms` and `gpu_ms` per frame.

### 4.5 Bandwidth (2 min per source)

Activity Monitor > Network while writing: the Daylight process's "Rcvd Bytes" rate. Strokes should read KB/s; mirror about 1 MB/s at the standard quality, about half on "Low bandwidth" (Settings > Mirror > "Quality").

### 4.6 Tablet battery (30 min, run once per source on a different evening)

Note the tablet's battery percentage, write for 30 minutes in the chosen source with the screen on, note it again. Mirror keeps the encoder running the whole time; the stroke sources do not.

### 4.7 Fidelity (3 min)

Write the same sentence in each source. Open the saved `page-01.png` (web, Daylight Ink) and `mirror-<HH-mm-ss>.png` (mirror) at 200 percent and compare the stroke edges and the highlighter. Also compare the live Studio Split picture in a Zoom test meeting at the far end.

### 4.8 Facts to paste into `docs/LOOSE_ENDS.md`

The web "?" card and the Daylight Ink "This tablet" screen give the pressure range (D3), the side button (D4), the Chrome caps (D8) and the front buffer (D14); Diagnostics in mirror mode gives the Wacom node (D1) and the device model (D2). The D section says which line goes where.

## 5. Verdict so far (before measurements)

Daylight Ink is the recommended default: strokes, native input, self-reconnecting, no debugging. The web whiteboard is the same product with zero install and is the right first try. Mirror mode is the only way to put the SolOS note app on camera and the right tool when the drawing app matters more than the latency; its cost is USB debugging and a video pipeline, and its long-term answer is a SolOS service rather than adb (SPEC 17, LOOSE_ENDS A9). Measure for a week and let the numbers above decide.

## 📋 ADHD-friendly measurement checklist (⏱️ about 45 minutes plus one 30-minute battery run per source)

- [ ] 🟢 Quit Daylight; Terminal: `/Applications/Daylight.app/Contents/MacOS/Daylight --latency-probe --perf-log`. You see: `perf` lines scrolling once a second. ⏱️ 1 minute
- [ ] ✍️ Web: draw one stroke from the camera state. You see: `engage probe: STROKE_START to first moved frame <ms>`. Write the number into the web column. ⏱️ 2 minutes
- [ ] 🟣 Web: tap "?", read `rtt <n> ms`. Write it down. ⏱️ 1 minute
- [ ] ✍️ "Ink source" > "Daylight Ink app"; draw one stroke. Write the probe number. ⏱️ 2 minutes
- [ ] 🟣 `adb logcat -s DaylightInk.net`, read `pong N rtt=<n>ms`. Write it down. ⏱️ 1 minute
- [ ] ✍️ "Ink source" > "Mirror the tablet"; write in the note app. You see: `engage probe: pen contact at <t> (mirror)` and `first decoded frame at <t>`. Write the difference. ⏱️ 2 minutes
- [ ] 🟣 Stopwatch on the tablet, photograph tablet and preview together, three times, median. Write it down. ⏱️ 5 minutes
- [ ] 🟣 Activity Monitor CPU and Memory for Daylight: one minute writing, one minute idle, per source. Write six numbers. ⏱️ 10 minutes
- [ ] 🟣 Activity Monitor Network, Daylight "Rcvd Bytes" rate, per source. Write three numbers. ⏱️ 5 minutes
- [ ] 🟣 Open `page-01.png` and `mirror-<HH-mm-ss>.png` at 200 percent. Which is crisper? Write one sentence. ⏱️ 3 minutes
- [ ] ⏱️ Battery: 30 minutes of writing per source on separate evenings; percentage before and after. ⏱️ 30 minutes each
- [ ] 📋 Copy the numbers into section 2 above and into `docs/PERFORMANCE.md`; one sentence in section 5 if the verdict changed. ⏱️ 5 minutes
