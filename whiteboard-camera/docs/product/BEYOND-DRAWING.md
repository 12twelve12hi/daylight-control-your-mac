# Beyond drawing: what else the tablet plus the virtual camera can do for a call

Product research, no code. Written 2026-10-04 by the product thinker for the owner. Friction IDs (AC1, ST2 and so on) are defined in `FRICTIONS.md`; drawing ideas (D1 to D52, M1 to M10) are in `DRAWING-DEEP-DIVE.md`.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

## The idea in one paragraph

The pair has two halves that nothing else on the desk has together: a **private, calm, paper-like screen with a pen in the person's peripheral vision**, and a **camera picture the Mac fully controls**. Most non-drawing ideas use only the first half: the tablet shows the speaker something nobody else sees. A few use the second: the Mac changes what the call sees in honest, useful ways. The evidence says second devices earn their place by showing state at a glance and staying exactly in sync (Stream Deck, mutesync), and lose it when their signal can be wrong or when they need other people to change behaviour (busy lights). See `FRICTIONS.md` ST3.

Evidence quality: every quote is a search-result excerpt (page fetching was blocked in this environment). Verify before external use. **Evidence** is sourced; **Inference** is mine.

Effort: **S** under 3 days, **M** 1 to 2 weeks, **L** more than 2 weeks or across Mac, both clients and the protocol. Stance (from `DRAWING-DEEP-DIVE.md` section 2): **Fits**, **Fits if opt-in**, **Tension**, **Conflicts**.

## What the plumbing already allows (inference, from the repo)

- The Mac already pushes STATE to both tablet clients (PROTOCOL 6.14), and opcodes 0x0072 to 0x007F are reserved for new server-to-client messages. A generic **CARD** message (title, body text, optional small image, a style) would carry most ideas below with one protocol addition.
- The extension already knows how many apps are viewing Daylight Camera (SPEC C3, the viewers property). That is a reliable "am I in a call" signal that needs no meeting-app integration.
- Anything that reads or controls Zoom, Meet or Teams (mute state, raise hand) is a per-app integration through macOS Accessibility or the apps' own APIs. It is fragile, needs a permission prompt, and can be wrong. Treat it as L with high risk.

---

## 1. Private information for the speaker

| # | Idea | Friction | What the user sees | Needs | Effort | Risk | Stance |
|---|---|---|---|---|---|---|---|
| B1 | **Agenda and talking points card.** Drop a text or Markdown file on the Daylight menu bar icon (or write an off-air page); the tablet shows it in large type when the board is not on air, one item at a time, ticked off with the pen. | AF2, TT1 | your own agenda on paper-like glass, never on camera | Mac: file drop, CARD message (0x0075); both clients: a card view | M | the user glances down while speaking (PA3); this is notes, not an eye-contact fix | Fits |
| B2 | **Glance-free call clock.** Elapsed time and time left until the calendar event ends, plus "Next call in 4 min". Shown large, quiet, no animation. | AF2 | a plain clock on the tablet | Mac: EventKit calendar read (one permission), the viewer count to know a call is on; CARD | M | calendar permission scares some users; works without it as a plain elapsed timer | Fits |
| B3 | **Monologue meter.** Local voice activity on the Mac's own microphone shows how long you have been talking without a break; at 75 s a gentle bar fills. In Gong's data no winning demo had more than "76 seconds of uninterrupted pitching" ([Gong](https://www.gong.io/blog/sales-demos)); top performers sit near 46:54 talk to listen ([Prospeo](https://prospeo.io/s/discovery-call-template)). | TT2, TT1 | a thin bar at the tablet's edge | Mac: AVAudioEngine level detection on the mic only (never the far side's audio, never recorded); CARD or STATE extension | M | the Mac app touches the microphone, a new permission and a new trust question; must be opt-in and say "nothing is recorded" | Fits if opt-in |
| B4 | **Question cards.** A prepared list (interview questions, coaching prompts, discovery questions) as cards; the pen flips to the next card and writes private notes on it. Exported with the notes. Interviewers note that note taking breaks "the natural flow (and eye contact)" ([Live Recruitment](https://www.live-recruitment.co.uk/blog/should-you-take-notes-during-an-interview-as-an-interviewer)). | NC4, PA3 | one question at a time, with space for a note | B1 plus per-card off-air pages (D4) | M | the same downward glance; short cards keep it brief | Fits |
| B5 | **What the captions probably heard.** On-device speech recognition of your own microphone (Apple's speech framework) shows your last sentence on the tablet. When it shows "Shivon" for "Siobhán", you write the name on air and the DHH or ESL guest gets it right. Auto captions "struggle with non-standard words, such as names" ([Consumer Reports](https://www.consumerreports.org/disability-rights/auto-captions-often-fall-short-on-zoom-facebook-and-others-a9742392879)). | AC1, AC3 | a rolling line of your own words, with names and numbers underlined | Mac: speech recognition on the mic, on device; CARD stream at 1 to 2 Hz | M | it is our recogniser, not Zoom's; it predicts, not mirrors, their captions. Microphone permission as in B3 | Fits if opt-in |
| B6 | **Captions of the far side for a hard-of-hearing owner.** The tablet as a glare-free caption display beside the laptop. Two routes: (a) Google Live Transcribe on the DC-1 listening to the speakers (no work for us, but Google Play availability on SolOS is unverified); (b) the Mac captures call audio (ScreenCaptureKit audio) and transcribes on device. Evidence: 75 percent of employees with hearing loss rank video meetings as their hardest task ([Cochlear](https://hearandnow.cochlear.com/hearing-solutions/services/hybrid-working-hearing-loss/)). | AC1 | captions on the tablet, larger and calmer than Zoom's | (a) nothing but a device test; (b) audio capture permission, recogniser, CARD stream | (a) none; (b) L | (b) captures other people's voices: consent and local-only processing are mandatory | Fits if opt-in |
| B7 | **Live translation for the owner.** The same pipeline as B6(b) with on-device translation. | AC3 | a translated line under the caption | B6(b) plus translation | L after B6 | quality, latency, consent | Fits if opt-in |

## 2. Status at a glance

| # | Idea | Friction | What the user sees | Needs | Effort | Risk | Stance |
|---|---|---|---|---|---|---|---|
| B8 | **On-air truth.** The tablet always shows, unmistakably, one of: CAMERA (your face is on), BOARD ON AIR, NOT IN A CALL. Built from STATE and the viewer count, so it is never wrong. | ST3, ST2, TS2 | a large status line in the chip area, an amber frame when on air (D5) | STATE already carries the mode; add the viewer count | S | none | Fits |
| B9 | **Mute status and toggle.** MIC LIVE or MUTED in large type, tap to toggle. Evidence of demand is strong: "71% of Zoom users have said 'You're on mute'" ([Zoom](https://explore.zoom.us/en/zoom-user-survey/)), mutesync sells sync ([Chrome Web Store](https://chrome.google.com/webstore/detail/mutesync/bgkanlpcmdofcgadmpkeifiobdlkaceg)). | TT3, ST3 | a mute pad that matches the app | Mac: per-app integration (Zoom first) through Accessibility to read the mute button state and press it; a new client-to-server MUTE request | L | **the status can be wrong**, which is worse than no status (ST3); apps rename menu items (the Stream Deck plugin "assumes menu items are named in a certain manner ... English", [c0t0d0s0](https://c0t0d0s0.org/blog/streamdeck.html)) | Tension |
| B10 | **Raise hand by pen.** Draw a hand or tap a pad to raise the app's own virtual hand. | TT2 | the hand goes up in Zoom | as B9 | L | as B9 | Tension |
| B11 | **Connection health.** "Mac 23 ms", the camera frame rate actually delivered to the extension, and "your video may be freezing" if the extension stops being pulled. | ST2, TT1 | a quiet health line | Mac: existing perf numbers in STATE or CARD | S | we see only our side, not the network to the far side; say so | Fits |
| B12 | **Framing check instead of a mirror.** At the first frame of a call, the tablet shows a small framing thumbnail with a face box ("centred, lit, in frame"), then hides it. Self-view drives "mirror anxiety" ([Stanford VHIL](https://vhil.stanford.edu/publications/social-interaction/zoom-exhaustion-fatigue-scale)); Camo users like to check before calls ([Reincubate](https://reincubate.com/camo/continuity-camera)). | AF1, ST2 | a check for 10 s, then nothing | Mac: Vision face rectangle on one frame; D35 thumbnail transport | S after D35 | none if it hides itself | Fits |

## 3. Showing things without a camera on the tablet

The DC-1 has no camera (SPEC D11), so "show a physical object" has to come from elsewhere.

| # | Idea | Friction | What the user sees | Needs | Effort | Risk | Stance |
|---|---|---|---|---|---|---|---|
| B13 | **Phone photo to page.** AirDrop or copy a phone photo of a paper, receipt or part to the Mac, "Paste as page" (D34), then ink over it on the tablet. | SP7, AC4 | a photo on the board, marked up | D33 pipeline | S after D33 | the photo may contain more than intended; crop before it goes on air | Fits |
| B14 | **Desk View as a page source.** If the Mac has Continuity Camera Desk View, offer it as a live page background. Reviewers split between "a bit of a gimmick" and "genuinely useful for showing physical documents" ([TechRadar](https://www.techradar.com/opinion/the-iphones-new-webcam-powers-are-a-clunky-reincarnation-of-apple-isight), [Tom's Guide](https://www.tomsguide.com/reviews/belkin-iphone-mount-for-macbook)); it crashes in browsers in one report ([Apple Discussions](https://discussions.apple.com/thread/255196655)). | SP7 | the desk on the board, inkable | Mac: a second AVCaptureDevice as background | M | reliability; Apple-only; Presenter Overlay and Desk View are free already | Tension |
| B15 | **Mirror another tablet app** (exists). A PDF reader, a score, a map on the DC-1 can go on camera through mirror mode today. Make it reachable from the tablet in one tap. | SP7 | "Show this app" | Daylight Ink: a shortcut to start the screen share (A9 transport) | S | battery (COMPARE 2.1) | Fits |

## 4. Presence when the camera is off

| # | Idea | Friction | What the user sees | Needs | Effort | Risk | Stance |
|---|---|---|---|---|---|---|---|
| B16 | **Board-only presence.** With "Camera off, board on" (Hold: Whiteboard Only, SPEC 7) the call sees the page instead of a black tile or an initials badge; the person can listen without a face and still show work. 41 percent of students cited appearance for cameras off ([Cornell](https://news.cornell.edu/node/320790)). | ST1, AF1 | the page as your tile | exists as Hold; add a tablet control and a "webcam off" guarantee (stop capture so the LED goes out) | S | none if the webcam really stops | Fits |
| B17 | **An honest "camera off" card.** When the webcam is stopped and no page is shown, Daylight Camera shows a calm cream card with the person's name: "Camera off, listening". Never a still photo of the person. | ST1 | a readable card instead of black | Mac: card render (the extension already draws a cream card in another case, SPEC 4) | S | a fake "present" picture would be deception; text only | Fits |

## 5. After the call

| # | Idea | Friction | What the user sees | Needs | Effort | Risk | Stance |
|---|---|---|---|---|---|---|---|
| B18 | **One-minute wrap-up on the tablet.** When the viewer count drops to 0, the tablet shows the session's pages as thumbnails, "Decisions?" and "Actions?" boxes to fill by hand, and Send (D41). Whiteboard photos are used "as evidence of agreement" and mostly short-term ([UWSpace](https://uwspace.uwaterloo.ca/handle/10012/10546)). | NC3, NC5 | a short ritual that produces the follow-up | Mac: session end event; CARD with thumbnails; D39 PDF | M | ignored if it nags; dismiss with one tap, off after three dismissals | Fits |
| B19 | **Break nudge.** After 50 minutes of continuous viewing across calls, "Stand up for two minutes" on the tablet. Microsoft's EEG study saw stress build across back-to-back meetings and not with breaks ([Corporate Rebels](https://corporate-rebels.com/brain-research)). | AF2 | one line, once | Mac: viewer-count timer; CARD | S | nagging; opt-in | Fits if opt-in |

## 6. The pen as a controller

| # | Idea | Friction | What the user sees | Needs | Effort | Risk | Stance |
|---|---|---|---|---|---|---|---|
| B20 | **Slide clicker.** In a "Present" mode, tapping the tablet's right or left edge (or the side button) sends the arrow keys to the frontmost app on the Mac, so the presenter keeps the pen in hand between slides and sketches. | SP3 | slides advance from the tablet | Mac: CGEvent posting (Accessibility permission); a client-to-server KEY request | M | posting keys needs Accessibility; keep it to arrows only | Fits if opt-in |
| B21 | **One pen, one gesture vocabulary.** Double press = Pin, long press = Clear exists for mirror (SPEC D10). Extend the same two gestures to Daylight Ink so the habit is the same in every source. | SP3 | the pen does the same things everywhere | Android client | S | side-button capture on SolOS unverified (LOOSE_ENDS D4) | Fits |

---

## Do not build (beyond drawing)

| Idea | Why not |
|---|---|
| A quiet side channel to a co-host | Slack, Teams chat and Messages already do it, on devices both people have; we would need accounts and a relay for a solved problem |
| A teleprompter that claims to fix eye contact | the tablet sits below the camera; only optics fix gaze honestly (Elgato Prompter puts the window "directly in front of the camera lens", [Elgato](https://www.elgato.com/explorer/products/teleprompter/prompter-for-zoom-and-video-meetings/)); B1 is notes, and we should say so |
| Gaze correction, beauty filters, background effects | "creepy" ([PetaPixel](https://petapixel.com/2019/07/03/apple-can-automatically-correct-your-gaze-in-video-calls-on-ios-13)); free in every platform; ChromaCam is shutting down ([vCam](https://www.vcam.ai/post/chromacam-is-shutting-down-meet-vcam-as-an-alternative)) |
| A busy light for the household | "co-workers ignored the signal" ([Laptop Mag](https://www.laptopmag.com/reviews/accessories/luxafor-flag)); it depends on other people |
| Reactions or emoji drawn by gesture | the apps have reactions; spectacle |
| Our own AI notetaker bot | crowded market, bot backlash (NC6); our role is the visual record the bots miss (M3, M10) |
| Recording the call audio for summaries | consent, storage and legal exposure far beyond a camera utility; B5 and B6 stay on device and never store audio |
| Using the DC-1 as a Mac second display | Daylight Link already exists ([Daylight](https://support.daylightcomputer.com/download-daylight-link)); not our job |

---

> **If you only read one section**
>
> The tablet is a private, calm screen in the speaker's peripheral vision, and the Mac fully owns the camera picture. The best non-drawing uses are the ones that can never be wrong: **on-air truth** on the tablet (B8, S), **board-only presence** when the camera is off (B16, S) and an honest **camera-off card** (B17, S), all built from state the Mac already owns. Next come private helpers through one new server-to-client CARD message: an **agenda card and call clock** (B1, B2), a **wrap-up ritual** that produces the follow-up (B18), and, as an opt-in, **"what the captions probably heard"** so the speaker can write the misheard name (B5). Skip anything that depends on reading Zoom's mute state until the basics ship: a status that can be wrong is worse than none (B9, B10).
