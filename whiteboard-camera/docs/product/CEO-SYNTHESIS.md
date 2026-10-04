# CEO synthesis: tonight's product research

Date: 2026-10-04. For Mike. Three streams: Product Thinker (FRICTIONS, DRAWING-DEEP-DIVE, BEYOND-DRAWING, ROADMAP-PROPOSAL), Research Swarm (IDEAS-FROM-OTHER-PROJECTS, REUSABLE-CODE, ANTI-PATTERNS) and Big Picture (TOO-SMALL, `docs/handoff/vp-too-small.md`). Effort: S under 3 days, M 1 to 2 weeks.

## 1. The five ideas that matter most

**1. Readable at the far end: bolder camera ink, then follow the pen.** All three streams, independently.
Our 3.2 px pen lands at 0.7 px on a 360p stream and a 5 x 5 Zoom gallery tile gets 180p (FRICTIONS SP5; DRAWING-DEEP-DIVE section 1; TOO-SMALL section 1). The Swarm adds a verified target, Teams Rooms' 1 to 2 mm of board per pixel (IDEAS-FROM-OTHER-PROJECTS, Top 25 #2).
Exists: follow-the-pen math (`FollowRegion`, ee69a2c), not wired. New: a camera-only minimum line weight (D14), then the wiring. **S, then M.**

**2. A fresh page for every call.** Product Thinker only, but it is a defect in our own spec.
A return saves the page but keeps the ink; only Clear blanks it (SPEC 5.2 and 7), so the next call's first pen-down can show last call's drawing (FRICTIONS ST4, severity High). Private notes share the exposure, since pen-down always engages.
Exists: viewer count (SPEC C3), Hold: Camera. New: a new call with ink older than 10 minutes starts a blank page (D6); an Off-air toggle on the tablet (D4). **S.**

**3. The board is the follow-up.** Product Thinker and Swarm, independently.
Meeting whiteboards vanish and people ask "can you send me that?" (FRICTIONS NC1, NC5). The Swarm adds Loom's copy-on-save and Excalidraw's strokes-inside-the-PNG, verified (IDEAS-FROM-OTHER-PROJECTS, Top 25 #14 and #5).
Exists: PNG plus strokes JSON per page (SPEC 12). New: `session.pdf`, "Copy last page", "Send today's board" (D39 to D41), plain JSON in the PNG. **S each.**

**4. Say what is silently wrong: wrong camera, Local Network denied.** Wrong camera in both streams; Local Network is the Swarm's top idea.
Call apps switch cameras unprompted and nobody is told (FRICTIONS TS2; IDEAS-FROM-OTHER-PROJECTS, Top 25 #3, verified API). On macOS 15 a denied Local Network prompt silently breaks Bonjour pairing (Top 25 #1, Apple TN3179, verified; closes LOOSE_ENDS C4).
Exists: viewer count, failure matrix (SPEC 13). New: "No app is using Daylight Camera" on the tablet (D36, D37), a physical-webcam-in-use hint, a Local Network failure row. **S; M for the webcam listener.**

**5. Laser pointer.** Product Thinker and Swarm, independently.
"Can you see my cursor?" is daily (FRICTIONS PA1). Excalidraw, tldraw, GoodNotes and Teams ship a fading pointer that never enters the page (IDEAS-FROM-OTHER-PROJECTS, Top 25 #4; MIT trail code in REUSABLE-CODE section 1).
Exists: LASER_POINT on the wire, not drawn (LOOSE_ENDS F3). New: a tablet tool and a trail in the camera board only, never saved. **M.**

## 2. Three to refuse, and why

- **Anything that alters the truth on air** (gaze correction, effects, live AI tidy-up of strokes): "creepy", free elsewhere, and FigJam's reshaping drew "horrific" feedback (DRAWING-DEEP-DIVE section 2, D22). The DC-1 sits below the camera, so no eye-contact claim can be honest.
- **Anything the far side must install or join** (our own call app, a two-way guest board, Zoom, Meet or Teams platform apps): Around shut down, FigJam needs add-ons (ANTI-PATTERNS section 5), platform apps need review and hosting (TOO-SMALL L9 to L11), and SPEC D12 keeps us local.
- **Mute and raise-hand control through call apps:** a status that can be wrong is worse than none (BEYOND-DRAWING B9, FRICTIONS ST3).

## 3. The too-small problem

Tonight shipped the "Daylight Whiteboard" share window (menu bar > "Share the whiteboard", 8caff9d): the full page on the content track every app shows big, for 2 to 3 clicks per call. Next, double-click on the second camera device for each app's "share camera as content" (patch in the handoff), then wire follow-the-pen for calls where nobody shares. Mike must test, on the signed build, Zoom > Share Screen > Advanced > Second camera > Switch Camera until "Daylight Camera" appears (checklist row 7.7), then the 20-minute legibility test across all routes.

The one risk: the second device is a full camera, so a call app could switch Mike's face to the whiteboard (handoff R3). Fallback: remove one line, keep the share window.

## 4. Three questions for the owner

Work proceeds on the defaults; one sentence from Mike overrides any.

| Question | Default in force | If Mike picks otherwise |
|---|---|---|
| 1. First customer? | Math and science tutors | Engineers: shape snap and the interview preset move ahead of PDF import |
| 2. Hosted service before v1.0? | No, local only | The read-only page link (M2) starts in v0.3, with TLS, a relay and privacy work |
| 3. Microphone access? | Not before v1.0; then opt-in, on device, nothing recorded | Monologue meter (B3) and "what the captions probably heard" (B5) move up, with a new permission prompt |
| 4. Are 2 to 3 clicks per call acceptable for a big board? (added) | Yes | Follow-the-pen goes first but cannot beat a 180p tile; zero-click needs platform apps, so question 2 becomes yes |

## 5. Caveats

- Page fetches were blocked: the Product Thinker's quotes are search excerpts, and no Reddit or Hacker News thread was fetched. The Swarm verified code and developer docs; closed-product UX claims are mostly snippets. Verify before quoting outside.
- mmhmm was renamed Airtime in 2025: a rebrand, not a merger.
- The Swarm ranked a second camera device "low impact"; Big Picture ranks it next. The Zoom test decides.
- Nothing has run on hardware: not on Mike's Mac, not on the DC-1.
