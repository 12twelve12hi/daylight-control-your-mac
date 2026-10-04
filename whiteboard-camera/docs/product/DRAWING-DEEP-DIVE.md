# Drawing deep dive: whiteboarding with the DC-1 beside the laptop

Product research, no code. Written 2026-10-04 by the product thinker for the owner. Companion documents: `FRICTIONS.md` (the friction IDs used below, such as SP5 or NC1), `BEYOND-DRAWING.md`, `ROADMAP-PROPOSAL.md`.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

## How to read this page

- Section 1 is the one constraint that shapes every drawing idea: what survives the far side's video stream.
- Section 2 is the stance check every idea is judged against.
- Section 3 holds 52 micro-ideas in short tables grouped by theme. Section 4 holds 10 macro-ideas, each with a paragraph.
- Each idea names the friction it addresses (IDs from `FRICTIONS.md`), what the user sees, what it needs (Mac app, tablet clients, protocol), effort, risk, and the stance verdict.
- **Evidence** means a cited source. **Inference** means my reasoning. Every quote below comes from search-result excerpts: page fetching was blocked by this environment's network policy, so no quote has been checked word for word against its page. Open the link before reusing a quote outside the company.

Effort scale: **S** is under 3 days for one engineer, **M** is 1 to 2 weeks, **L** is more than 2 weeks or spans Mac, both tablet clients and the protocol. Stance verdicts: **Fits**, **Fits if opt-in**, **Tension** (needs care), **Conflicts**.

---

## 1. The constraint: what the far side can actually read

The board travels inside the camera picture, not as a screen share. That is the product's best idea (the face stays, it works in every call app) and its biggest physical limit.

**Evidence.**
- Camera feeds get far fewer pixels than screen shares. A search summary of an article on reading whiteboards through Zoom says camera video "can be as low as 640x360", while a screen share is sent at a much higher resolution ([statusq.org](https://statusq.org/?p=9834), excerpt only).
- Zoom's default is standard definition. 720p needs "Group HD" to be turned on, and 1080p is limited to Business and Enterprise plans and the active-speaker layout ([Boise State guide](https://talk-boisestate.atlassian.net/wiki/spaces/LTS/pages/1928462337/Using+1080p+HD+Video+in+Zoom), [StreamGeeks](https://streamgeeks.us/how-to-increase-your-video-quality-in-zoom/), search summaries).
- An OBS forum thread reports text through a virtual camera looking blurrier in Zoom than the same content as a window capture ([OBS forum](https://obsproject.com/forum/threads/blurry-text-in-ndi-virtual-cam-in-zoom-%E2%80%94-zoom-window-capture-not-blurry-at-all.124824)).
- Only spotlight makes a camera large for everyone. Pin changes only the viewer's own layout ([OU IT layout guide](https://itsupport.ou.edu/TDClient/30/Unified/KB/PrintArticle?ID=3149), search summary).

**Inference, from our own geometry (SPEC 6.1, `web/src/ink.ts`).** The page is 1200x1600 canvas pixels and is drawn 810x1080 in the 1920x1080 output (scale 0.675). The default pen is 3.2 canvas pixels wide. The 10.5 inch page is about 21 cm tall, so about 75 canvas pixels per centimetre.

| What the far side receives | Page on their screen | Default pen line | 5 mm handwriting (x-height) | Readable? |
|---|---|---|---|---|
| 1080p, speaker view, full screen | 810x1080 | 2.2 px | 25 px | yes |
| 720p (Group HD on) | 540x720 | 1.4 px | 17 px | yes, if the writing is not small |
| 360p (Zoom default for many calls) | 270x360 | 0.7 px | 8 px | barely; thin colour strokes vanish |
| A gallery tile about 480x270 on a laptop | 120x160 | 0.3 px | 4 px | no |

Three conclusions shape the rest of this page:

1. **Write big and thick by default.** The pen we ship is tuned for the tablet, not for a 720p stream. The output needs a minimum line weight (D13), and users need a quiet cue about letter size (D14).
2. **Use the pixels we have.** Zooming the output to the area being written (D15, D16) and the landscape page (D17) at least double what the far side gets.
3. **Give a full-resolution route for detail.** A page link or a PDF after the call (D39, M3) and, for fine work, the "board as a window" a viewer can screen share (M6, built in commit 8caff9d as "Share the whiteboard").

The measurement that settles all of this takes 20 minutes and should come before any build: write one sentence at three sizes, join a free Zoom account and a Google Meet call from a second machine, screenshot gallery and speaker views, and read them. That test is item 1 of `ROADMAP-PROPOSAL.md`.

---

## 2. The stance check: utility over spectacle

SPEC D2 records the owner's decision: "Camo lesson: utility over spectacle". The teardown research behind that phrase is not in the repository (no Camo or mmhmm research prompt exists in `docs/`; only D2 mentions Camo), so I rebuilt it from public reviews.

**Evidence.**
- mmhmm raised a $100M Series B in 2021, renamed itself Airtime in April 2025 and split into single-job tools, with the camera sold for a one-time $20 ([Airtime blog](https://www.airtime.com/blog/mmhmm-becomes-airtime), [Entrepreneur Loop](https://entrepreneurloop.com/video-startup-mmhmm-rebrands-as-airtime-unveils-new-meeting-tools/)). It then laid off 25 of 58 staff; insiders said the product "struggled to gain traction" ([TechCrunch](https://techcrunch.com/2025/06/04/its-layoff-season-at-phil-libins-airtime)).
- mmhmm's own help center warns of "computer fan noise, or choppy or delayed video" ([mmhmm help](https://studio.help.mmhmm.app/hc/en-us/articles/18536793076375-Improve-computer-performance-when-using-mmhmm-Studio)).
- Camo, which does one job, was an Apple Design Award finalist and is called "the best one" by WIRED, with price the main complaint ([Macworld](https://www.macworld.com/article/3568492/camo-review.html), [iMore](https://www.imore.com/reincubate-camo-studio-review-turn-your-iphone-webcam-your-dreams)).
- Around closed on March 31, 2025, a year after Miro bought it, and ChromaCam shuts down on September 30, 2026 ([AlternativeTo](https://alternativeto.net/news/2025/1/the-video-call-app-around-is-shutting-down-just-over-a-year-after-its-acquisition-by-miro), [vCam](https://www.vcam.ai/post/chromacam-is-shutting-down-meet-vcam-as-an-alternative)).
- Live gaze correction reads as "pretty creepy" ([PetaPixel](https://petapixel.com/2019/07/03/apple-can-automatically-correct-your-gaze-in-video-calls-on-ios-13), [MobileSyrup](https://mobilesyrup.com/2023/01/23/nvidia-broadcast-eye-contact-creepy/)).
- Apple's Presenter Overlay ("me next to my screen") is free on every Mac and works in Zoom ([AppleInsider](https://appleinsider.com/inside/macos-sonoma/tips/how-to-use-presenter-overlay-in-macos-sonoma)).

**The test I apply to every idea (inference, distilled from the evidence above):**

1. Does it help someone **understand** something, or does it only look impressive?
2. Does it work with **zero preparation** (pick up the pen), or does it need authoring?
3. Is it **invisible until used**, and does it leave the face untouched?
4. Does it add **CPU, latency or a failure that can show in public**?
5. Is it **already free** in Zoom, Meet or macOS?

An idea that fails 1 or 3 is marked **Conflicts**. Failing 4 or 5 gives **Tension**.

---

## 3. Micro-ideas

### 3.1 Engage, return and on-air control

| # | Idea | Friction | What the user sees | Needs | Effort | Risk | Stance |
|---|---|---|---|---|---|---|---|
| D1 | **Engage latency target, measured and shown.** Pen contact to the first moved frame under 60 ms for strokes (the existing budget) and a number the user can see: the tablet "?" card shows "last engage 41 ms". | SP2, TT1 | a number, once, in the help card | Mac: the existing `--latency-probe` result sent in STATE or a new 0x0072 message; tablet: one line | S | none | Fits |
| D2 | **Ink-triggered early frame** (LOOSE_ENDS F1): render at once when ink arrives instead of on the next 30 Hz tick, about 10 ms off the median. | SP2 | nothing; it just feels quicker | Mac compositor | S | frame pacing jitter | Fits |
| D3 | **Hover keeps the board up.** While the board is LIVE, a pen hovering over the glass counts as activity, so the board does not slide away while you point and talk. Hover never engages from camera. | PA1, SP4 | the board stays while you explain without drawing | tablet: send a hover heartbeat at 2 Hz (LASER_POINT with intensity 0 already counts as `.activity` on the Mac, PROTOCOL 6.9); no Mac change | S | a pen left resting near the glass holds the board; cap hover activity at 3 min | Fits |
| D4 | **Off-air ink (private page).** One tablet toggle, "Off air", disarms auto-engage. The tablet border turns grey and reads OFF AIR; ink is still saved. This is the existing Hold: Camera (SPEC 7) made reachable from the tablet. | ST4, PA3, AF5, NC4 | a clear OFF AIR banner on the tablet; nothing changes on camera | tablet toolbar button sending a hold request; Mac: hold(camera) already exists, needs a client-to-server HOLD opcode in the 0x0016 to 0x001F range | S | user forgets it is on and wonders why nothing engages; the banner is the cure | Fits |
| D5 | **On-air border on the tablet.** When the board is on camera, a thin amber frame runs round the tablet canvas, visible in peripheral vision (the chip alone is small). | ST3, ST4 | an amber frame while on air | tablet only, from STATE | S | none | Fits |
| D6 | **Fresh page for a new call.** When Daylight Camera's viewer count goes from 0 to 1 and the page has ink older than 10 minutes, start a new page (saving the old one) so the last call's drawing never appears in the next call. Per SPEC 5.2 and 7 the canvas is cleared only by Clear; a return saves but keeps the ink. | ST4, NC1 | a blank page at the first pen-down of a new call; the old page is in the folder | Mac: the extension's viewers property (SPEC C3) plus a session rule | S | a user mid-call who briefly drops the camera gets a new page; use the 10-minute rule | Fits |
| D7 | **Return timer per use.** A one-tap preset on the tablet: "Quick" 45 s, "Normal" 90 s, "Lesson" 5 min. `idleTimeoutSeconds` already accepts 15 to 600 s. | SP4 | the board stays as long as a lesson needs | tablet setting sent to the Mac (new settings message) or Mac menu only | S | none | Fits |
| D8 | **Hold the board while the far side talks about it.** Pin exists. Add "pin until I clear" as the default in the Lesson preset so teachers never fight the timer. | SP4 | fewer surprise returns | settings preset | S | none | Fits |

### 3.2 Pointing without drawing

| # | Idea | Friction | What the user sees | Needs | Effort | Risk | Stance |
|---|---|---|---|---|---|---|---|
| D9 | **Laser pointer** (LOOSE_ENDS F3). Hold the side button (or a toolbar laser tool) and the pen leaves a red trail that fades over 1 s. LASER_POINT already carries position, intensity and decay. | PA1 | a fading trail on the board | Mac: render laser points as a fading layer in the compositor; tablet: a laser tool | M | side-button capture on SolOS is unverified (LOOSE_ENDS D4) | Fits |
| D10 | **Hover ring.** While LIVE, the hovering pen shows as a 24 px ring on the board, so "this one here" works without ink. | PA1 | a ring follows the pen above the glass | tablet: stream hover positions (LASER_POINT intensity 0.3, or a new 0x0016 HOVER); Mac: draw ring | M | jitter in the far side's eyes; make it opt-in at first | Fits if opt-in |
| D11 | **"Look here" pulse.** Double-tap with the pen tip: an amber circle grows and fades at that spot (600 ms). | PA1, AC1 | one pulse | tablet gesture; Mac animation | S after D9 | double-tap could draw a dot; detect on the tablet before sending ink | Fits |
| D12 | **Spotlight region.** Circle an area with the laser and everything else dims to 60 percent for 5 s. | PA1, PA2 | the rest of the page dims briefly | Mac shader mask | M | edges on spectacle; keep it short and plain | Tension |
| D13 | **Numbered markers.** Tap a stamp tool to drop "1", "2", "3" circles, so speech can say "point 2" and captions and notes can refer to it. | PA1, AC1, NC2 | small numbered circles | tablet tool; ink as normal strokes | S | none | Fits |

`FRICTIONS.md` PA1 has the evidence: people install "green circle" apps because cursors vanish in shares ([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/3222/mouse-pointer-not-visible-when-sharing-screen)), and Notability and GoodNotes added laser pointers for mirrored teaching ([GoodNotes](https://goodnotes-team.notion.site/The-Laser-Pointer-Tool-d1b4143a642e433c9ed820ce7b079414)).

### 3.3 Legibility through the call's compression

| # | Idea | Friction | What the user sees | Needs | Effort | Risk | Stance |
|---|---|---|---|---|---|---|---|
| D14 | **Camera line weight.** The Mac renders ink with a minimum width of 2.5 output pixels at 1080p (about 3.7 canvas pixels), so the line is still 1.7 px at 720p. The tablet keeps its own finer feel. | SP5 | ink on camera looks slightly bolder than on the tablet | Mac: one clamp in the stroke renderer and the PNG renderer (keep the JSON true) | S | page PNGs look heavier; apply only to the live output if preferred | Fits |
| D15 | **Size guide.** A faint dotted baseline pair on a fresh page shows "write at least this tall" (about 8 mm), fading after the first line. | SP5 | a light guide that disappears once you write | tablet clients only | S | some will find it patronising; a setting turns it off | Fits |
| D16 | **Follow the pen (auto-zoom).** The output crops to the area of the last 20 s of ink plus a margin, between 1x and 2x, moving with the same critically damped spring. Small writing in a corner fills the board. | SP5, PA2 | the board gently zooms to where you write | Mac: the camera math already exists in DaylightKit (`FollowRegion`, commit ee69a2c: fit, clamp, zoom in after 2.5 s, full page after 30 s idle), not yet wired into the compositor; tablet: a "zoom on air" indicator | M (wiring) | motion can disorient; slow, never more than one move per 3 s, off for Lesson preset until tested | Tension |
| D17 | **What you see is what they see.** A two-finger pinch on the tablet sets the on-air viewport and the tablet shows the same view. | SP5, PA2 | zoom the tablet and the camera follows | protocol: VIEWPORT message (0x0017); Mac crop; both clients | M | fingers never draw (D3 rule) so no conflict | Fits |
| D18 | **One-tap landscape page** for diagrams. SPEC 6.4 already lays out a landscape canvas at 1440x1080, 78 percent more area than portrait's 810x1080. | SP5 | a wide page that fills most of the frame | tablet clients: rotation sends PAGE_CHANGE 4:3 | S to M | the presenter column shrinks to 480 px | Fits |
| D19 | **"Ask them to spotlight you" tip.** The first time the board engages in a call, the tablet shows: "Tip: ask them to spotlight or pin you to read the board." A "Copy line" puts a sentence for the chat on the Mac clipboard. | SP5 | a one-time tip | tablet text; Mac clipboard | S | none | Fits |
| D20 | **Colours that survive compression.** Video codecs keep colour at half resolution (4:2:0 subsampling), so thin coloured strokes blur first. Coloured pens get 1.5x the black pen's width. | SP5 | colours stay readable | tablet width table | S | none | Fits |

### 3.4 Ink tools

| # | Idea | Friction | What the user sees | Needs | Effort | Risk | Stance |
|---|---|---|---|---|---|---|---|
| D21 | **Two emphasis colours, one tap each.** Indigo and Terracotta from the design tokens beside InkBlack and the Amber highlighter. STROKE_START already carries a colour (PROTOCOL 6.3); clients only ever send black and amber. | SP1, AC1 | three dots on the toolbar | both tablet clients; nothing on the Mac or wire | S | colour alone must not carry meaning (colour-blind viewers); pair with shape | Fits |
| D22 | **Raw ink, no shape takeover.** A principle rather than a feature: never smooth or reshape what the pen drew. FigJam's 2025 marker change drew "horrific" feedback ([Figma forum](https://forum.figma.com/share-your-feedback-26/horrific-experience-with-the-new-figjam-drawing-assistance-41071)). Catmull-Rom smoothing (LOOSE_ENDS F6) is fine because it follows the samples. | SP2 | ink looks exactly as written | nothing | none | none | Fits |
| D23 | **Shape snap on hold.** Draw a box or arrow, keep the pen still for 0.5 s, and it straightens. Without the pause, nothing changes. | SP1, SP2 | crisp boxes for architecture and interviews | tablet recogniser; replace the stroke with a clean stroke (normal STROKE messages) | M | false snaps; only with the pause | Fits if opt-in |
| D24 | **Undo you can see.** On the far side, an undone stroke fades over 250 ms instead of popping, so viewers understand that something was taken back. | SP6 | a short fade | Mac compositor | S | none | Fits |
| D25 | **Undo after erase** (LOOSE_ENDS F13): erase becomes undoable. | SP2 | the eraser is no longer scary | Mac stroke store; both clients; PROTOCOL 6.7 semantics | M | protocol change touching four codecs and the golden vectors | Fits |
| D26 | **Move to make room.** Lasso strokes and drag them aside. | SP1 | room for the next step of a derivation | protocol MOVE_STROKES (0x0018), Mac store, both clients | L | complexity; defer to v1.0 | Fits |
| D27 | **Thin-pen trap removed.** Hide the thin-pen option until the user opts in, given section 1. | SP5 | fewer unreadable boards | tablet settings | S | none | Fits |

### 3.5 Pages, structure and templates

| # | Idea | Friction | What the user sees | Needs | Effort | Risk | Stance |
|---|---|---|---|---|---|---|---|
| D28 | **Page counter on air.** "2 / 4" in small TextMuted type at the board's bottom right corner. Teachers valued Jamboard's clear page boundaries ([New Six Things](https://newsixthings.substack.com/p/six-revolutionary-teacher-web-tools)). | PA2 | viewers know where they are | Mac compositor; page index already in STATE | S | none | Fits |
| D29 | **Go back a page.** Today New page saves and starts blank. Keep the session's pages in memory, with left and right arrows on the tablet. | PA2, NC1 | earlier pages come back on air | Mac page list; PAGE_CHANGE to an existing page id (PROTOCOL 6.11 already carries an id and index); both clients redraw from the Mac | M | the clients must fetch strokes for an old page (a STROKES_SNAPSHOT message, 0x0072) | Fits |
| D30 | **Page thumbnails on the tablet.** A strip of the session's pages, tap to show one on air. | PA2 | quick navigation | builds on D29 | S after D29 | none | Fits |
| D31 | **Duplicate page**, to try a second version of a diagram. | SP1 | a copy to change | builds on D29 | S after D29 | none | Fits |
| D32 | **Templates (non-erasable backgrounds).** Grid, dot, lined, axes, number line, timeline, 2x2, the CBT "hot cross bun", genogram symbols, architecture boxes, pricing tiers, wheel of life. Coaches prefer summarising templates to freehand ([Erickson](https://erickson.edu/resources/how-to-use-coaching-wheels-in-a-coaching-session-for-client-success)); CBT formulations are drawn diagrams ([Formulate Tools](https://formulatetools.co.uk/blog/the-complete-guide-to-cbt-case-formulation)). | SP1, SP7 | a template picker on New page | a background layer on the Mac (rendered under the highlighter) and on both clients; JSON records the template id | M | template sprawl; ship six, then listen | Fits |
| D33 | **Import a PDF or image as the page** (the tutor's main workflow): drop a worksheet on the Daylight menu bar icon, it appears on the tablet, you ink over it. Tutoring whiteboard vendors call PDF upload with annotation the most used workflow ([Zutor](https://zutor.app/blog/best-whiteboard-online-tutoring), attribution uncertain). | SP7 | the worksheet under your pen and on camera | Mac: PDF rasterise per page at 1200x1600; protocol: BACKGROUND image transfer server to client (0x0073, chunked); both clients | L | image size over Wi-Fi (a page JPEG is about 200 KB, fine); mirror source not affected | Fits |
| D34 | **Paste a screenshot as a page.** Copy a chart on the Mac, "Paste as page" from the menu bar, mark it up on the tablet without screen sharing. | SP7, SP3 | annotate anything without switching share | the D33 pipeline | S after D33 | privacy: only what the user pasted | Fits |

### 3.6 Far-side awareness

| # | Idea | Friction | What the user sees | Needs | Effort | Risk | Stance |
|---|---|---|---|---|---|---|---|
| D35 | **The outgoing frame, on the tablet.** A 1 fps, 200 px wide thumbnail of exactly what the call receives, in the toolbar. Camo users open its preview first to see how they look ([Reincubate](https://reincubate.com/camo/continuity-camera)). | ST2, SP5 | "is it on, is it readable" without looking at the Mac | Mac: downscaled frame as JPEG (about 8 KB) at 1 Hz over a new 0x0074 message; both clients | M | battery and bandwidth are trivial; privacy none (it is your own output) | Fits |
| D36 | **On air in N apps.** The chip reads "On camera in 1 app" using the extension's viewer count; "No app is using Daylight Camera" warns before you draw for nobody. | TS2, ST3 | a plain status line | viewer count already exists (SPEC C3); add to STATE flags | S | none | Fits |
| D37 | **Stale-call warning.** If the board engages while no app is viewing Daylight Camera, the tablet says "Not in a call: Zoom is not using Daylight Camera". | TS2 | an honest warning | as D36 | S | none | Fits |
| D38 | **Readability check.** A "Check readability" button on the tablet renders the current page at 360p and 720p side by side, so the user sees what the far side gets. | SP5 | two small previews | Mac render at scale; D35 transport | S after D35 | none | Fits |

### 3.7 Persistence and export

| # | Idea | Friction | What the user sees | Needs | Effort | Risk | Stance |
|---|---|---|---|---|---|---|---|
| D39 | **Session handout PDF.** All pages of a session as one PDF, `session.pdf`, written next to the PNGs when the session ends (10-minute gap rule, SPEC 12). Zoom deletes meeting whiteboards at meeting end unless exported during the call ([Zoom Community](https://community.zoom.com/whiteboard-8/recover-whiteboard-65546)); Preply students cannot open the whiteboard after a lesson ([Preply](https://preply.com/en/question/how-do-i-access-the-whiteboard-notes-after-completing-a-lesson-73603)). | NC1, NC5 | one file per call, ready to send | Mac: CoreGraphics PDF from the stroke model | S | none | Fits |
| D40 | **"Copy last page"** in the menu bar and a hotkey: PNG on the clipboard for Slack, email or Notion. | NC5 | paste the diagram straight into the follow-up | Mac only | S | none | Fits |
| D41 | **"Send today's board".** Menu bar item: opens a new Mail message (or the share sheet) with `session.pdf` attached. | NC5 | two clicks from call to follow-up | Mac: NSSharingService | S | none | Fits |
| D42 | **Reopen a page in a later call** (LOOSE_ENDS F4). Pick a past page from the menu bar or the tablet; it loads as the current page and keeps growing. Zoom cannot reload a saved board ([Zoom Community](https://community.zoom.com/whiteboard-8/can-i-upload-a-saved-whiteboard-back-into-the-zoom-whiteboard-66436)). | NC1 | continuity across weekly lessons and standups | Mac: load strokes JSON into the store; D29 snapshot to clients | M | mixing old ink with D6's fresh-page rule; reopening is explicit | Fits |
| D43 | **Absolute stroke times in the JSON.** Today `tMs` is relative to each stroke's first point (SPEC 12), so the order and timing of strokes across a page are lost. Add `startedAt` per stroke (schema 2). | NC2, M5 | nothing visible; enables replay and timeline | Mac JSON writer; schema bump | S | readers of schema 1 keep working if the field is optional | Fits |
| D44 | **Decision and action boxes.** Draw a box and write "D:" or "A:" in it; the export lists them on page 1 of the PDF. Without handwriting recognition (M3) the export crops each box as an image; with it, the text is listed. | NC3, NC2 | a list of decisions at the top of the handout | tablet: box tool tag; Mac: crop export; later HWR | M | false detection; use an explicit box tool, not inference | Fits |
| D45 | **File names people can find.** `2026-10-04 Lesson with Sam, page 2.png`: if the user types a label on the tablet at the end (optional), it becomes the folder name. | NC1 | findable files | tablet text field; Mac rename | S | none | Fits |

### 3.8 Small things that remove doubt

| # | Idea | Friction | What the user sees | Needs | Effort | Risk | Stance |
|---|---|---|---|---|---|---|---|
| D46 | **Never mirrored.** Keep SPEC D1 (no mirroring in the output) and add a one-line onboarding note: "Your own Zoom preview may look mirrored; the people on the call see it the right way round." Document cameras and DIY mirrors confuse people with reversed text ([VCU](https://blogs.vcu.edu/classroomtechnology/2020/08/18/is-your-document-camera-video-feed-looking-strange/)). | TS2 | no panic about mirrored writing | onboarding text | S | none | Fits |
| D47 | **Clear asks once when the page holds many strokes.** Clear is also "end", so a mistaken Clear loses nothing (it saves), but the board vanishes mid-explanation. A second tap within 2 s confirms if the page has more than 50 strokes. | SP2 | a "tap again to clear" pill | both clients | S | slows a deliberate clear slightly | Fits |
| D48 | **Battery and connection on the chip.** Show "Mac 23 ms" (round trip) and the tablet battery when it falls under 20 percent. reMarkable and Continuity Camera users complain about silent drops ([Apple Discussions](https://discussions.apple.com/thread/255196655)). | TS1, ST2 | trust in the link | both clients (RTT already measured) | S | none | Fits |
| D49 | **Ink while disconnected is replayed** (web already has an offline ring; Daylight Ink keeps strokes on the tablet only, COMPARE 2). Give Daylight Ink the same ring. | SP2 | nothing lost after a Wi-Fi blip | Android client | M | duplicate strokes if ids clash; ids are UUIDs, so safe | Fits |
| D50 | **Eraser contact keeps the board up** (already true, SPEC D36) and **undo keeps it up** (already activity). No work; listed so nobody regresses it. | SP4 | the board stays while correcting | none | none | none | Fits |
| D51 | **Hand-off to the face.** Pressing the chip for 600 ms returns to camera (exists). Add the same on the pen: a long press on the side button in mirror mode is Clear; in stroke modes make it "Return" (no clear), so the pen alone ends a drawing moment without losing the page. | SP4 | the pen does everything | Android client side-button handling | S | side-button availability (LOOSE_ENDS D4) | Fits |
| D52 | **"Say it as you write it" nudge.** Once per session, a quiet tablet line: "Read out what you write; not everyone can see it." Guidance for accessible teaching says exactly this ([CU Boulder](https://www.colorado.edu/digital-accessibility/visual-description)). | AC5 | one line | tablet text | S | none | Fits |

---

## 4. Macro-ideas

### M1. The far side draws back (live board link)

- **Friction:** SP6. Evidence: an interview candidate found iPad drawing "very one-way, helpful for explaining concepts but not collaborative" ([TeamBlind](https://www.teamblind.com/post/best-setup-to-take-a-remotevirtual-system-design-interview-0foztcvm)); math teachers call seeing student thinking "the biggest obstacle" ([eSchool News](https://www.eschoolnews.com/steam/2020/10/16/challenges-online-math-instruction/)); Caribu shows families want to draw together ([App Store](https://apps.apple.com/us/app/caribu-family-video-calls/id763451959)).
- **What the user sees:** the presenter taps "Invite to draw" on the tablet; a short link goes to the call chat (copied on the Mac). The guest opens it in any browser, sees the page at full resolution and draws in a different colour after the presenter allows them, per person. Their ink appears in the camera picture like the presenter's. A "Can you draw that?" button on the guest page sends a request card to the tablet.
- **Requires:** a relay reachable from the internet (the Mac serves only the local network today; a guest is elsewhere), so a hosted relay or a tunnel; TLS (SPEC D12 says none in v1); guest identity and permission; Mac: per-client colour, multi-writer stroke store (the store already accepts several clients); web: a guest mode of the existing page.
- **Effort:** L. **Risk:** high. A cloud service means accounts, privacy, uptime and cost, and it breaks "works in any app with nothing to join". Guests must open something, the same objection Caribu has. **Stance:** Tension. It serves understanding, but it is the first feature that needs the other side to do something.
- **Recommendation:** v1.0 at the earliest, behind a test of a read-only version first (M2).

### M2. Read-only full-resolution page link

- **Friction:** SP5, AC4, AC5, NC5. A viewer on a 360p stream or a phone cannot read the board; a screen reader user gets nothing from pixels ([UW AccessComputing](https://accesscomputing.uw.edu/knowledge-base/are-electronic-whiteboards-accessible-to-people-with-disabilities)).
- **What the user sees:** "Share page link" on the tablet; viewers open a page that redraws strokes live at full sharpness and zoomable, with the recognised text underneath once M3 exists.
- **Requires:** the same relay as M1 but no writes, no permissions beyond an unguessable link that expires when the session ends.
- **Effort:** M to L (the relay is the cost). **Risk:** medium (hosting, privacy). **Stance:** Fits if opt-in. It is the cheapest test of whether guests will open anything at all.

### M3. Handwriting to text (ink-to-text)

- **Friction:** NC2, NC3, AC1, AC5. AI notetakers "capture what was said about it but not the visual itself" ([AFFiNE](https://affine.pro/blog/ai-note-taker-intro)); ink in a video is invisible to screen readers.
- **What the user sees:** the session PDF has a searchable text layer; the menu bar offers "Copy text of this page"; decision and action boxes (D44) become a typed list.
- **Requires:** recognition from the stroke JSON. Options: Google ML Kit Digital Ink Recognition on the tablet (on device, free, vector input, many languages; needs a check that it runs on SolOS without Google Play services), or on the Mac (Apple Vision text recognition on the rendered PNG, on device). Running it on the Mac PNG avoids any tablet dependency and works for mirror mode too.
- **Effort:** M (Mac Vision on PNG) to L (stroke-level recognition with structure). **Risk:** recognition errors on math and diagrams; present text as a helper, never replace the ink. **Stance:** Fits. Invisible during the call, useful after.

### M4. Diagram tidy-up with AI (after the call)

- **Friction:** NC5, SP1. People ask for "that diagram" after the call; a hand sketch is not always presentable.
- **What the user sees:** in the menu bar, "Tidy this page" produces a clean diagram (boxes, arrows, labels) as SVG and PNG next to the original, never replacing it, never during the call.
- **Requires:** stroke JSON plus recognised text sent to a model (the Claude API is an option) with explicit consent per page; an SVG renderer. Privacy: pages may hold client secrets, so it must be off by default and say where the page goes.
- **Effort:** M. **Risk:** wrong structure presented confidently; mitigate by showing original and tidy version side by side. **Stance:** Fits if opt-in and post-call. Doing it live during the call would be spectacle and would change what the speaker drew (D22): **do not build live tidy-up**.

### M5. Replay ("how I drew it")

- **Friction:** NC1, AC3. interviewing.io built a replayable whiteboard because drawing order explains reasoning ([interviewing.io](https://blog.interviewing.io/building-interviewing-ios-collaborative-replayable-whiteboard/)); stroke order is the lesson for Chinese and Japanese tutors ([Oxford CTCFL](https://www.ctcfl.ox.ac.uk/materials_chinese_lessons_4_charindex/)).
- **What the user sees:** "Export replay" makes a short MP4 or GIF of the page being drawn at 4x speed; a student can rewatch a derivation.
- **Requires:** absolute stroke start times (D43); a Mac renderer to frames plus AVAssetWriter.
- **Effort:** M. **Risk:** low. **Stance:** Fits. mmhmm's founders said the habit that stuck was recorded explanation they could watch at double speed ([Wikipedia](https://en.wikipedia.org/wiki/Phil_Libin)).

### M6. "Board as a window" for screen sharing

**Status: built while this research ran** (commit 8caff9d, menu bar > "Share the whiteboard", Settings > Share; unverified on device). A parallel session is working the same "too small" problem (DaylightKit `FollowRegion`, see D16). What remains from this idea is measuring it against the camera route in the v0.2 legibility test.

- **Friction:** SP5, AC4, NC2. A screen share is sent sharper and costs 50 to 75 kbps against 600 kbps for 1:1 video ([Columbia College Chicago](https://colum.teamdynamix.com/TDClient/2029/Portal/KB/Article/102394/Bandwidth-requirements-for-Zoom)); Google Meet's notes now include screenshots of shared content ([Neowin](https://www.neowin.net/news/google-meets-ai-note-taker-will-soon-start-including-presentation-screenshots/)), which probably will not see ink in a camera feed (unverified).
- **What the user sees:** a menu item "Open board window": a clean, resizable window of the current page that the user can share as a window in any app when detail matters; the camera keeps working.
- **Requires:** the existing preview window (SPEC D19) in a board-only form, rendered at the window's size from the stroke model.
- **Effort:** S to M. **Risk:** it gives up the "no screen share" story for that moment, by the user's choice. **Stance:** Fits. A tool for the hard case, not the default.

### M7. Two tablets (student and teacher, or two engineers)

- **Friction:** SP6, T3 in the segment research (seeing student work).
- **What the user sees:** two DC-1s paired to one Mac in the same room (a tutor and an in-person student, or a pair at one desk) draw on one page in two colours.
- **Requires:** the store already takes several clients but only one active ink client per source (SPEC 8); relax to N writers with colours per client.
- **Effort:** M. **Risk:** low technically; the market for two DC-1s at one Mac is small. **Stance:** Fits. Not a priority; the remote case is M1.

### M8. Ink over a live Mac window (annotation layer)

- **Friction:** SP7. People annotate slides, charts and code during screen shares, and Zoom annotation drops strokes ([Zoom Community](https://community.zoom.com/meetings-2/zoom-annotate-tool-eats-penstrokes-28600)).
- **What the user sees:** the board shows a chosen Mac window (ScreenCaptureKit) as the page background, live, and the pen inks over it.
- **Requires:** ScreenCaptureKit capture permission, a live background layer, coordinate mapping.
- **Effort:** L. **Risk:** screen recording permission prompts; privacy; overlaps what Zoom and Presenter Overlay already do. **Stance:** Tension. D34 (paste a still screenshot) covers most of the need at a fraction of the cost. **Defer.**

### M9. Interview mode

- **Friction:** SP1, PA3. Candidates say virtual system design interviews waste "20-30%" of their time on tooling ([TeamBlind](https://www.teamblind.com/post/virtual-system-design-interview-is-pathetic-mpwagqo0)); glancing at a second device now reads as possible cheating ([WeCP](https://www.wecreateproblems.com/blog/behavioral-signs-of-cheating-during-remote-interviews)).
- **What the user sees:** a preset: landscape page (D18), architecture template (D32), shape snap on (D23), pin on, and an on-air border so the candidate's writing is always visible: "show your work, visibly".
- **Requires:** the parts listed; a preset is S once they exist.
- **Effort:** S as a bundle. **Risk:** many companies require Excalidraw or CoderPad, so the market is mock interviews and interviewers who allow own tools. **Stance:** Fits.

### M10. Ink timeline in the meeting notes

- **Friction:** NC2, NC3. Granola merges the user's own sparse notes with the transcript, with no bot joining ([Zapier](https://www.zapier.com/blog/granola-ai)); 58 percent are said to be uncomfortable when a bot joins (vendor-reported Calendly figure, [Umevo](https://www.umevo.ai/blogs/ume-all-posts/the-bot-backlash-why-clients-refuse-meetings-with-ai-notetaker-bots)).
- **What the user sees:** a `timeline.json` (and a Markdown file) listing, per minute, which page was on air and what was written (with M3), so a transcript tool or a person can line up "as you can see here" with the picture.
- **Requires:** D43 times; M3 text; an export format. Integrations (Granola, Notion) are later and depend on their APIs.
- **Effort:** S for the file once D43 and M3 exist. **Risk:** low. **Stance:** Fits.

---

## 5. What I would not build in the drawing space

| Idea | Why not |
|---|---|
| Live AI tidy-up of strokes during the call | changes what the speaker drew in front of the audience; FigJam's smoothing backlash (D22); spectacle |
| Animated stickers, emoji rain, confetti on the board | fails test 1; free in Zoom and FaceTime reactions already |
| An infinite canvas | teachers valued Jamboard's page boundaries; viewers get lost on big canvases (Miro "follow me" requests, [Miro Community](https://community.miro.com/ask-the-community-45/how-to-enforce-follow-me-2401)) |
| Our own meeting app or a guest client required for basic use | Around closed; the camera works everywhere because it is only a camera |
| Gaze correction for looking down at the tablet | "creepy"; looking down to write is honest and visible as writing |
| A thin pen as default | section 1 math |

---

> **If you only read one section**
>
> The far side often receives the camera at 360p to 720p, where our default 3.2 px pen line becomes 0.7 to 1.4 pixels and normal handwriting is barely readable (section 1). So the first drawing work is not new features but **legibility**: a minimum camera line weight (D14), a size guide (D15), the landscape page (D18) and a "spotlight me" tip (D19), checked with a 20-minute real-call test. After that, the cheapest high-value items are **off-air ink** for private notes (D4), a **fresh page per call** so last call's drawing never leaks (D6), the **laser and hover pointer** (D9, D3), **emphasis colours** the wire already supports (D21), and the **session PDF** plus "Send today's board" (D39, D41). Templates and PDF import (D32, D33) are the tutor and therapist unlock. Two-way drawing (M1) is the biggest gap and the biggest risk; test a read-only page link (M2) first.
