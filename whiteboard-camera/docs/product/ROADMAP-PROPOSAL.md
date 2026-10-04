# Roadmap proposal: v0.2, v0.3, v1.0

Product research, no code. Written 2026-10-04 by the product thinker for the owner. It turns `FRICTIONS.md` (friction IDs), `DRAWING-DEEP-DIVE.md` (D and M ideas) and `BEYOND-DRAWING.md` (B ideas) into three releases. The current version is 0.1.0 (`VERSION`); nothing in it has yet run on the owner's DC-1, so every release below assumes the device checklist (`docs/TESTING-CHECKLIST.md`) passes first.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

Evidence caveat: every quote behind these items is a search-result excerpt (page fetching was blocked in this environment). The roadmap's ranking rests on patterns across many sources, not on any single quote, but verify a quote before using it in public.

## The reasoning in five lines

1. **Fix what can make a call worse before adding anything.** Three risks surfaced: thin ink the far side cannot read (SP5), private ink and last call's page going on air (ST4), and ink that screen readers and notetakers cannot see (AC5, NC2). v0.2 is mostly the first two.
2. **Then make pointing and pages work**, because "can you see my cursor" and "which page are we on" are daily frictions (PA1, PA2) and the protocol already half supports them (LASER_POINT, PAGE_CHANGE). That is v0.3.
3. **Then own the follow-up and the tutor workflow**: the drawing as a sendable, searchable record (NC1 to NC5, AC5) and inking over worksheets (SP7). That is v1.0.
4. **Stay a camera.** Every item works with nothing installed on the far side. Two-way drawing (M1) waits for evidence from a read-only link experiment (M2).
5. **Measure locally, decide with numbers** (section 6), starting with a 20-minute legibility test before writing code.

---

## v0.2 "Readable and safe" (about 3 weeks, mostly S items)

Goal: every pen-down is readable on the far side, nothing private goes on air by accident, and the result is one file away from the follow-up.

| # | Item | Idea | Friction | Evidence (one link each; more in FRICTIONS) | Effort |
|---|---|---|---|---|---|
| 0 | **Legibility test before code.** Write one sentence at three sizes; view it from a second machine in free Zoom (gallery and speaker view) and in Google Meet, once through Daylight Camera and once through the new "Share the whiteboard" window (8caff9d); screenshot; record which sizes read. Sets the numbers for items 1 and 2. | section 1 | SP5 | camera video "can be as low as 640x360" ([statusq.org](https://statusq.org/?p=9834)) | 20 min |
| 1 | Camera line weight: a minimum of 2.5 output pixels at 1080p for the live output | D14 | SP5, AC4 | blurry text through a virtual camera ([OBS forum](https://obsproject.com/forum/threads/blurry-text-in-ndi-virtual-cam-in-zoom-%E2%80%94-zoom-window-capture-not-blurry-at-all.124824)) | S |
| 2 | Size guide on a fresh page; thin pen hidden by default; coloured pens 1.5x wider | D15, D27, D20 | SP5 | as above | S |
| 3 | "Make it big" prompt on the tablet that opens the built share window; then the **second camera device** for "share camera as content" scoped in `TOO-SMALL.md` section 6 (lever L2, patch in `docs/handoff/vp-too-small.md`) once the owner's Zoom test passes | D19, TOO-SMALL L1 and L2 | SP5, AC6 | a 5 x 5 Zoom gallery feeds each camera tile a 180p stream (`TOO-SMALL.md` section 1, sources there) | S, then M |
| 4 | **Off-air ink** on the tablet (Hold: Camera from the tablet, OFF AIR banner); new client-to-server HOLD opcode in 0x0016 to 0x001F, golden vectors in all four copies | D4 | ST4, AF5, NC4, PA3 | a therapist's screen share exposed session notes ([Newsweek](https://www.newsweek.com/therapist-accidentally-shares-screen-during-telehealth-session-patient-floored-what-they-see-2075935)) | S |
| 5 | **Fresh page for a new call** (viewer count 0 to 1 and ink older than 10 min) | D6 | ST4, NC1 | inference from SPEC 5.2 and 7: only Clear clears the canvas | S |
| 6 | **On-air truth**: amber frame on the tablet while on air; "On camera in N apps" and "Not in a call" from the viewer count | D5, D36, D37, B8 | ST3, ST2, TS2 | "stays in sync" is what people buy ([mutesync](https://chrome.google.com/webstore/detail/mutesync/bgkanlpcmdofcgadmpkeifiobdlkaceg)) | S |
| 7 | Two emphasis colours (Indigo, Terracotta); the wire already carries colour | D21 | SP1, AC1 | Microsoft Whiteboard users complained about taps to change colour ([Windows Central](https://windowscentral.com/following-fan-backlash-microsoft-will-roll-back-previous-version-whiteboard-windows)) | S |
| 8 | Hover keeps the board up (LASER_POINT intensity 0 as a heartbeat; no Mac change) | D3 | SP4, PA1 | inference; the 90 s return was designed for drawing, not pointing | S |
| 9 | **Session PDF**, "Copy last page", "Send today's board" | D39, D40, D41 | NC1, NC5 | Zoom deletes meeting whiteboards at the end ([Zoom Community](https://community.zoom.com/whiteboard-8/recover-whiteboard-65546)) | S each |
| 10 | "Say it as you write it" nudge; Clear asks again on a full page | D52, D47 | AC5, SP2 | "read out as much of what you are writing as feasible" ([CU Boulder](https://www.colorado.edu/digital-accessibility/visual-description)) | S |
| 11 | Measure the added video delay of Studio Split over passthrough (lip sync) and record it in `docs/PERFORMANCE.md` | AC2 check | AC2, TT1 | fusion holds within "about 200-300 ms" ([PMC](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5193434/)) | S |
| 12 | macOS 26 and 27 approval check: confirm whether the camera extension appears under "Media Extension" in Privacy & Security on the owner's Mac; add a macOS 27 row to the checklist | TS1 | TS1 | macOS 26 "Media Extension" approval moved ([OBS forum](https://obsproject.com/forum/threads/virtual-camera-mac-os-tahoe-26-3-1.194658/)) | S |
| 13 | Local usage counters for the metrics in section 6, in the perf log and the diagnostics export only | metrics | all | none needed | S |

Why this order: items 0 to 3 decide whether the product works at all for the far side; items 4 and 5 remove the only ways it can embarrass the user; item 9 turns the existing saved pages into the follow-up people already ask for. All are small because the plumbing exists (Hold, colour, LASER_POINT, viewer count, the stroke model).

## v0.3 "Point, page, prepare" (about 5 weeks)

Goal: you can point without drawing, move between pages like slides, start from a template, and see what the far side sees.

| # | Item | Idea | Friction | Evidence | Effort |
|---|---|---|---|---|---|
| 1 | **Laser pointer** (render LASER_POINT with its decay; LOOSE_ENDS F3), "look here" pulse, numbered markers | D9, D11, D13 | PA1, AC1 | "a solid green circle which follows the mouse" ([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/3222/mouse-pointer-not-visible-when-sharing-screen)) | M |
| 2 | Hover ring, opt-in | D10 | PA1 | GoodNotes laser for mirrored teaching ([GoodNotes](https://goodnotes-team.notion.site/The-Laser-Pointer-Tool-d1b4143a642e433c9ed820ce7b079414)) | M |
| 3 | **Pages you can go back to**: session page list, thumbnails, duplicate, page counter on air; STROKES_SNAPSHOT server-to-client message | D28 to D31 | PA2, NC1 | Jamboard's "clear page boundaries" missed ([New Six Things](https://newsixthings.substack.com/p/six-revolutionary-teacher-web-tools)) | M |
| 4 | One-tap landscape page | D18 | SP5 | inference: 78 percent more board area (SPEC 6.4) | S to M |
| 5 | **Six templates**: grid, axes, timeline, 2x2, architecture boxes, CBT hot cross bun | D32 | SP1, SP7 | coaches prefer summarising templates ([Erickson](https://erickson.edu/resources/how-to-use-coaching-wheels-in-a-coaching-session-for-client-success)) | M |
| 6 | **Outgoing frame on the tablet** (1 fps thumbnail), framing check at call start, readability check | D35, B12, D38 | ST2, AF1, SP5 | Camo users check their look first ([Reincubate](https://reincubate.com/camo/continuity-camera)) | M |
| 7 | Generic server-to-client **CARD** message; agenda card and call clock on it | B1, B2 | AF2, TT1 | Stream Deck valued for status "regardless of what they're doing" ([Mac Power Users](https://talk.macpowerusers.com/t/elgato-stream-deck-xl/13687/50)) | M |
| 8 | Board-only presence and an honest camera-off card | B16, B17 | ST1 | 41 percent cite appearance for cameras off ([Cornell](https://news.cornell.edu/node/320790)) | S |
| 9 | Reopen a saved page in a later call | D42 | NC1 | saved Zoom boards cannot be reloaded ([Zoom Community](https://community.zoom.com/whiteboard-8/can-i-upload-a-saved-whiteboard-back-into-the-zoom-whiteboard-66436)) | M |
| 10 | Absolute stroke times in the JSON (schema 2, optional field) | D43 | enables M5, M10 | replayable boards exist for a reason ([interviewing.io](https://blog.interviewing.io/building-interviewing-ios-collaborative-replayable-whiteboard/)) | S |
| 11 | Daylight Ink offline ring (like the web page's) | D49 | SP2 | strokes lost when writing fast are the tutors' top Zoom complaint ([Zoom Community](https://community.zoom.com/meetings-2/zoom-annotate-tool-eats-penstrokes-28600)) | M |
| 12 | Return presets (Quick, Normal, Lesson) | D7, D8 | SP4 | decided by the "returns cancelled by ink" metric | S |

Why: v0.3 serves the two segments with the strongest evidence, math tutors (SP2, SP4, SP8) and engineers or consultants explaining structure (SP1, PA1), and it adds the first non-drawing helpers on one new message type.

## v1.0 "The follow-up and the hard cases" (about 8 weeks)

Goal: a drawing becomes a searchable, sendable record; tutors can ink over their worksheets; detailed work has a sharp route.

| # | Item | Idea | Friction | Evidence | Effort |
|---|---|---|---|---|---|
| 1 | **Import a PDF or image as a page**, paste a screenshot, phone photo to page | D33, D34, B13 | SP7 | PDF upload with annotation is the main tutoring workflow ([Zutor](https://zutor.app/blog/best-whiteboard-online-tutoring), attribution uncertain) | L |
| 2 | **Ink to text** on the Mac (Vision on the page PNG): searchable session PDF, "Copy text" | M3 | AC5, NC2 | whiteboards "not accessible to users of screen readers" ([UW](https://accesscomputing.uw.edu/knowledge-base/are-electronic-whiteboards-accessible-to-people-with-disabilities)) | M |
| 3 | Decision and action boxes, listed at the top of the PDF; the wrap-up card after a call | D44, B18 | NC3, NC5 | whiteboard photos used "as evidence of agreement" ([UWSpace](https://uwspace.uwaterloo.ca/handle/10012/10546)) | M |
| 4 | **Board as a window**: already built (8caff9d, "Share the whiteboard"); v1.0 adds only what the v0.2 test shows is missing (for example recognised text under the page) | M6 | SP5, AC4, NC2 | screen share needs 50 to 75 kbps against 600 kbps for video ([Columbia College Chicago](https://colum.teamdynamix.com/TDClient/2029/Portal/KB/Article/102394/Bandwidth-requirements-for-Zoom)) | S |
| 5 | Replay export (MP4 at 4x) and the ink timeline file | M5, M10 | NC1, NC2 | recorded explanation is the habit that lasted at mmhmm ([Wikipedia](https://en.wikipedia.org/wiki/Phil_Libin)) | M |
| 6 | What-you-see viewport (pinch on the tablet sets the on-air view); follow-the-pen zoom, whose camera math already landed in DaylightKit (`FollowRegion`, ee69a2c, not wired), shipped by default only if a v0.3 test shows viewers like it. If the v0.2 legibility test shows small writing is unreadable, pull the wiring forward into v0.3 behind a setting | D17, D16 | SP5, PA2 | inference from the legibility math | M |
| 7 | Shape snap on pause, and the Interview preset | D23, M9 | SP1, PA3 | system design candidates "waste 20-30% of their time" on tooling ([TeamBlind](https://www.teamblind.com/post/virtual-system-design-interview-is-pathetic-mpwagqo0)) | M |
| 8 | Undo after erase (protocol change) | D25 | SP2 | LOOSE_ENDS F13 | M |
| 9 | "What the captions probably heard", opt-in, on-device, mic only | B5 | AC1, AC3 | captions "struggle with non-standard words, such as names" ([Consumer Reports](https://www.consumerreports.org/disability-rights/auto-captions-often-fall-short-on-zoom-facebook-and-others-a9742392879)) | M |
| 10 | **Experiment, not a feature:** a read-only full-resolution page link to answer "will guests open anything?" before any two-way drawing | M2 | SP6, SP5, AC5 | iPad drawing is "very one-way" ([TeamBlind](https://www.teamblind.com/post/best-setup-to-take-a-remotevirtual-system-design-interview-0foztcvm)) | M to L |

Why: v1.0 is what makes the product worth paying for to people other than the owner: the record (NC), the worksheet (SP7), the accessible export (AC5), and an answer for detail (M6). It is also where the first hosted service could appear (item 10), which is why it is framed as an experiment with an owner decision (question 2 below).

---

## Do not build (and why)

| Do not build | Reason | Evidence |
|---|---|---|
| Live AI tidy-up or smoothing that changes what was drawn | changes the speaker's words on air; reshaping drew "horrific" feedback | [Figma forum](https://forum.figma.com/share-your-feedback-26/horrific-experience-with-the-new-figjam-drawing-assistance-41071) |
| Gaze correction, beauty filters, background effects | read as "creepy"; free in every platform; effect cameras are closing | [PetaPixel](https://petapixel.com/2019/07/03/apple-can-automatically-correct-your-gaze-in-video-calls-on-ios-13), [vCam](https://www.vcam.ai/post/chromacam-is-shutting-down-meet-vcam-as-an-alternative) |
| Our own meeting app, or anything that requires guests to install software for basic use | Around closed a year after acquisition; a camera works everywhere | [AlternativeTo](https://alternativeto.net/news/2025/1/the-video-call-app-around-is-shutting-down-just-over-a-year-after-its-acquisition-by-miro) |
| An infinite canvas | viewers get lost; pages were valued | [Miro Community](https://community.miro.com/ask-the-community-45/how-to-enforce-follow-me-2401) |
| Stickers, emoji, confetti, animated reactions | fails "helps understanding"; apps have reactions | inference |
| Mute and raise-hand control through meeting apps, before v1.0 | a status that can be wrong is worse than none; per-app and per-language fragility | [c0t0d0s0](https://c0t0d0s0.org/blog/streamdeck.html), [MSU](https://msu.teamdynamix.com/TDClient/1815/Portal/KB/ArticleDet?ID=94084) |
| A busy light, a co-host side channel, a notetaker bot, call audio recording | depend on others; solved elsewhere; consent and legal exposure | [Laptop Mag](https://www.laptopmag.com/reviews/accessories/luxafor-flag), [Umevo](https://www.umevo.ai/blogs/ume-all-posts/the-bot-backlash-why-clients-refuse-meetings-with-ai-notetaker-bots) |
| Ink over a live Mac window (M8) | screen recording permission and privacy for a need a pasted screenshot covers | inference |
| Making Overlay the default layout | shrinks the face to a 302 px square, which hurts lip readers; segmentation can fail in public | [RNID](https://developer.rnid.org.uk/wp-content/uploads/2022/04/A201039_VideocallsandmeetingsPDF-tips-APRIL2022_01.pdf), [Zoftware Hub](https://zoftwarehub.com/products/xsplit-vcam/reviews) |

---

## Three open questions for the owner

The owner is asleep and the CEO session instructed (2026-10-04) that work proceeds on these defaults. Each stays open: one sentence from the owner overrides it.

### Q1. Who is the first customer after the owner?

- **Default (proceeding on it): math and science tutors**, with the owner's own calls as the daily test bed. v0.2 and v0.3 serve tutors and engineers alike; the choice mainly moves v1.0's PDF import (tutors) ahead of shape snap and the interview preset (engineers).
- **Evidence for tutors:** Zoom annotation stops after about 20 minutes, hit "almost daily" ([Zoom Community](https://community.zoom.com/meetings-2/unable-to-annotate-on-shared-screen-41600)); a tutor was "seriously debating abandoning Zoom whiteboards" ([Zoom Community](https://community.zoom.com/whiteboard-8/laggy-response-in-whiteboard-66761)); a tablet with stylus is a "must have for math tutoring" ([Piqosity](https://www.piqosity.com/2017/12/06/skype-tutoring-apps-and-tips/)); universities publish two-device workarounds with echo warnings ([CMU](https://www.cmu.edu/canvas/teachingonline/zoom/documents/lecture-with-handwriting---two-devices.pdf)). These users already own a pen habit and are angry with the software.
- **Evidence for the alternative (engineers, consultants, sales):** system design candidates "waste 20-30%" of their time on tooling ([TeamBlind](https://www.teamblind.com/post/virtual-system-design-interview-is-pathetic-mpwagqo0)), but companies mandate Excalidraw ([TeamBlind](https://www.teamblind.com/post/tools-for-virtual-system-design-interview-ao2anmpi)); hand-drawn visuals beat slides in vendor-sponsored research ([Corporate Visions](https://corporatevisions.com/blog/whiteboarding/)).
- **Why the default:** the tutor evidence is the most frequent and the most specific, and tutors judge the product on the exact things v0.2 fixes (legibility, lost strokes, the follow-up PDF).

### Q2. Is a hosted service acceptable before v1.0?

- **Default (proceeding on it): no.** Nothing in v0.2 or v0.3 needs one. The read-only page link (M2) stays a v1.0 experiment that starts only on the owner's yes; two-way drawing (M1) waits for its result.
- **Evidence:** SPEC D12 sets "No TLS in v1" and a local-network product; standalone call products that need their own client die (Around closed on March 31, 2025, [AlternativeTo](https://alternativeto.net/news/2025/1/the-video-call-app-around-is-shutting-down-just-over-a-year-after-its-acquisition-by-miro)); Caribu's two-way drawing requires its app on both sides ([App Store](https://apps.apple.com/us/app/caribu-family-video-calls/id763451959)); guests already lose access to hosted boards across organisations ([Microsoft Learn](https://learn.microsoft.com/en-us/answers/questions/1803142/using-whiteboard-while-working-with-guests-in-a-te)). The content-track route (`TOO-SMALL.md`) delivers a big, sharp board to every viewer without any service.
- **What would change it:** the v0.2 legibility test showing that even the share window fails for a common case, or tutors asking for student write-back (SP6) more than for import.

### Q3. May the Mac app listen to the owner's own microphone (opt-in)?

- **Default (proceeding on it): not before v1.0, and then only opt-in, on device, the owner's microphone only, nothing recorded.** It gates the monologue meter (B3) and "what the captions probably heard" (B5); nothing in v0.2 or v0.3 depends on it.
- **Evidence for the value:** auto captions get "about 1 in 10 words wrong" in some products and struggle with names ([Consumer Reports](https://www.consumerreports.org/disability-rights/auto-captions-often-fall-short-on-zoom-facebook-and-others-a9742392879)); no winning demo had more than "76 seconds of uninterrupted pitching" ([Gong](https://www.gong.io/blog/sales-demos)).
- **Evidence for caution:** a vendor-reported 58 percent are uncomfortable when an AI bot joins ([Umevo](https://www.umevo.ai/blogs/ume-all-posts/the-bot-backlash-why-clients-refuse-meetings-with-ai-notetaker-bots)); a camera utility that also listens changes its trust story, and the utility-over-spectacle evidence (mmhmm's performance complaints, [mmhmm help](https://studio.help.mmhmm.app/hc/en-us/articles/18536793076375-Improve-computer-performance-when-using-mmhmm-Studio)) favours doing one job.
- **What would change it:** a hard-of-hearing owner or customer for whom captions on the tablet (B6) are the main reason to buy.

---

## Metrics to watch

All counted locally from governor events and menu actions (item v0.2-13), written to the perf log and included only in "Export diagnostics...". Nothing leaves the Mac unless the owner sends the zip. The governor already emits every event these need (SPEC 5.1 effects).

| Metric | Definition | Why it matters | First decision it drives |
|---|---|---|---|
| **Pin adoption** | share of calls (viewer-count sessions) with at least one Pin | shows whether the 90 s auto-return fits real use | over 40 percent: the timer is too short for most use; make Lesson the default for that user |
| **Average engaged time** | total LIVE plus ENGAGING time per call, and engagements per call | how much of a call the board carries | under 1 minute per call for two weeks: the board is a novelty; look at legibility and pointing first |
| **Returns cancelled by ink** | RETURNING to ENGAGING caused by pen contact, divided by all returns; also pre-warnings cancelled by ink | each one is a return the user did not want | over 20 percent: raise the default return to 120 s (`idleTimeoutSeconds` already allows it) |
| **Exports sent** | uses of Copy last page, Send today's board, and session PDFs opened, per call with ink | whether the drawing becomes the follow-up (NC5) | under 1 in 10 calls with ink: the follow-up is not the hook; deprioritise ink to text |
| Accidental engages | snap-backs (SPEC 5.2) plus Clears within 10 s of a stroke-caused engage | private or stray ink going on air (ST4) | rising: make off-air the default when no app views Daylight Camera |
| Off-air use | minutes of off-air ink per week | whether private notes is a real job (therapists, interviewers) | high: invest in question cards (B4) |
| Pages per call and page back-navigation | pages created and revisited | whether pages (D29) earn their v0.3 cost | low revisits: drop thumbnails, keep the counter |
| Time to first engage | seconds from a viewer appearing to the first pen-down | whether the pen is reached for naturally | trend only |

---

> **If you only read one section**
>
> **v0.2 "Readable and safe"** (about 3 weeks of small items): a 20-minute legibility test, then a bolder camera line weight, a size guide and a one-tap "make it big" prompt to the built share window (then the second camera device from `TOO-SMALL.md`); **off-air ink** and a **fresh page per call** so nothing private reaches the camera; an unmistakable on-air indicator; two emphasis colours; and a **session PDF with "Send today's board"**. **v0.3 "Point, page, prepare"**: laser and hover pointer, pages you can go back to, six templates, the outgoing frame on the tablet, an agenda and clock card. **v1.0 "The follow-up and the hard cases"**: PDF and image import, ink to text, decision boxes, replay (the board window for sharp detail is already built and only needs the v0.2 test), and a read-only page link as an experiment. Do not build effects, gaze correction, an infinite canvas, mute control or our own meeting app. Three decisions stay open with defaults already in force: tutors first, no hosted service before v1.0, no microphone before v1.0. Watch pin adoption, engaged time, returns cancelled by ink and exports sent.
