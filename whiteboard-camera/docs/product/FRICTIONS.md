# Frictions: what goes wrong in video calls, and where the DC-1 beside the laptop fits

Product research, no code. Written 2026-10-04 by the product thinker for the owner. Every other page in `docs/product/` points back to the IDs here (TT1, SP5 and so on).

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

## Read this first: how strong is the evidence?

- Five researchers ran about 200 web searches across calls, teaching, therapy, interviews, families, sales, accessibility and camera tools (2026-10-04).
- **Page fetching was blocked** by this environment's network policy for every site tried (Reddit, Zoom, Stanford, arXiv, W3C and more). Every quote below is a **search-result excerpt** for a URL that appeared in results. Most are near-verbatim, some may be the search engine's paraphrase. **Open the link before quoting anything outside the company.**
- Direct Reddit and Hacker News threads did not surface. Community voice comes from Zoom Community, Miro and Figma forums, TeamBlind, Microsoft Q&A, Apple and OBS forums.
- Vendor statistics (note-taking companies, Corporate Visions, mmhmm's own survey) are marked as such. Treat them as direction, not proof.
- **Evidence** lines are sourced. **Inference** lines are mine.

## The catalogue at a glance

Frequency: **Daily** (most calls for the people who feel it), **Weekly**, **Occasional**. Severity: **High** (content lost, trust damaged, people excluded), **Medium** (friction people work around), **Low**. DC-1 fit: **Strong**, **Partial**, **None**, **Risk** (the product can make it worse).

| ID | Friction | Frequency | Severity | DC-1 fit |
|---|---|---|---|---|
| TT1 | Latency causes talk-overs and dead air | Daily | Medium | Partial |
| TT2 | Remote people cannot get the floor | Weekly | Medium | Partial |
| TT3 | "You're on mute" and mute doubt | Daily | Medium | Partial |
| SP1 | Drawing with a mouse or trackpad is too slow and imprecise | Weekly | High for teachers, engineers | Strong |
| SP2 | Pen input inside meeting and canvas apps is unreliable | Daily for tutors | High | Strong |
| SP3 | Second-device joins, AirPlay and share switching | Daily for tutors | Medium | Strong |
| SP4 | Sharing hides faces in both directions | Daily | Medium | Strong |
| SP5 | The far side cannot read it (compression, small tiles) | Daily | High | Partial, and a Risk |
| SP6 | One-way: the far side cannot draw back | Weekly | Medium | None today |
| SP7 | Annotating existing material (worksheets, screenshots) | Daily for tutors | Medium | None today |
| SP8 | Keyboards cannot express math | Daily for math | Medium | Strong |
| PA1 | "Can you see my cursor?" Pointing gets lost | Daily | Medium | Strong |
| PA2 | Viewers get lost on big canvases | Weekly | Medium | Strong |
| PA3 | Looking down reads as disengaged, or as cheating | Daily | Medium | Risk |
| NC1 | Drawings vanish when the meeting ends | Weekly | High | Strong (already) |
| NC2 | AI notetakers capture speech, not drawings | Daily | Medium | Partial |
| NC3 | Decisions and owners evaporate or are misassigned | Weekly | High | Partial |
| NC4 | Typing notes is noisy and looks rude | Daily | Low | Partial |
| NC5 | "Can you send me that diagram?" | Weekly | Medium | Strong |
| NC6 | Clients dislike notetaker bots | Weekly | Medium | Partial |
| AF1 | Hyper-gaze and self-view drive fatigue | Daily | Medium | Partial |
| AF2 | Back-to-back calls build stress | Daily | Medium | Partial |
| AF3 | Multitasking during calls | Daily | Low | None |
| AF4 | Video narrows creative thinking | Weekly | Medium | Partial (untested) |
| AF5 | ADHD: staying focused needs an outlet | Daily | Medium | Partial |
| AC1 | Captions fail on names, numbers, jargon | Daily for DHH, ESL | High | Strong |
| AC2 | Lip readers need a large face and tight sync | Daily for DHH | High | Risk |
| AC3 | Non-native listeners need text support | Daily for ESL | Medium | Strong |
| AC4 | Low bandwidth: video and fine detail die first | Weekly | High | Risk |
| AC5 | Blind and screen reader users get nothing from pixels | Occasional | High | Risk |
| AC6 | Sign language interpreters must stay large | Occasional | High | Risk |
| AC7 | Older adults and setup burden | Weekly | Medium | Partial |
| TS1 | macOS virtual cameras break on OS updates | Occasional | High | Risk for us |
| TS2 | Wrong camera, camera hijacked, camera not listed | Weekly | Medium | Partial |
| TS3 | Heavy camera apps heat the laptop and add lag | Daily for effect users | Medium | Strong (we are light) |
| ST1 | Camera-off ambiguity and appearance anxiety | Daily | Medium | Partial |
| ST2 | "Did I freeze? Can you see it?" | Daily | Medium | Strong |
| ST3 | Status signals drift out of sync | Daily for button users | Medium | Strong |
| ST4 | Private content leaks into the call | Occasional | High | Strong, and a Risk |

---

## 1. Turn-taking and interruption

### TT1. Latency causes talk-overs and dead air
- **Who:** everyone; worst between strangers (sales, interviews, first meetings).
- **Evidence:** latency makes people "perceive silence at points where talk should occur" and "talk in overlap" (Seuren et al., Journal of Pragmatics 2021, [ScienceDirect](https://www.sciencedirect.com/science/article/pii/S0378216620302782)). Lags of 30 to 70 ms already slow turn starts ([University of Michigan](https://news.umich.edu/zoom-disrupts-the-rhythm-of-conversation)). With delays up to 1.2 s, people rated their partner "less attentive, friendly and self-disciplined" ([The Conversation](https://theconversation.com/awkward-pauses-in-online-calls-make-us-see-people-differently-26073)). ITU-T G.114 treats under 150 ms as "essentially transparent" ([G.114 PDF](https://www.cs.columbia.edu/%7Eandreaf/new/documents/other/T-REC-G.114-200305.pdf)).
- **Today:** "sorry, go ahead", over-signalling ("over to you").
- **DC-1, inference:** cannot fix network latency. Two partial helps: our own pipeline must add nothing noticeable (the passthrough is zero-copy by SPEC D2; Studio Split adds one Metal pass, measure it), and a visible drawing gives the listener something to watch during dead air, which may make silence read as "thinking" rather than "rude". Untested.

### TT2. Remote people cannot get the floor
- **Who:** remote and hybrid attendees, juniors, quieter people.
- **Evidence:** in a Microsoft survey the top suggestion for inclusiveness was improving remote participants' "ability to interrupt and acquire the floor" ([arXiv 2304.00658](https://arxiv.org/abs/2304.00658v1)). Meeting features "push meeting leaders to exercise control", amplifying bias (Houtti et al., CSCW 2023, [arXiv](https://arxiv.org/pdf/2212.00849)). A search result claims virtual raise hand is used in "less than 1% of all meetings" (source page not confirmed; verify).
- **Today:** raise hand, chat, talking louder.
- **DC-1, inference:** picking up the pen is a visible bid: the picture changes, people look. A physical "raise hand" on the tablet that triggers the app's own raise hand needs meeting-app control (see `BEYOND-DRAWING.md` B6). Partial.

### TT3. "You're on mute" and mute doubt
- **Who:** everyone.
- **Evidence:** "71% of Zoom users have said 'You're on mute'" ([Zoom survey](https://explore.zoom.us/en/zoom-user-survey/)); 51 percent find being told embarrassing ([mmhmm survey](https://mmhmm.app/blog/we-surveyed-1000-people-in-the-us-to-find-out-what), vendor). 16 percent of Australian workers forgot to mute and said something insulting or awkward ([B&T](https://www.bandt.com.au/research-23-of-aussies-have-made-or-seen-embarrassing-behaviours-in-work-video-meetings/)). Headset and app mute drift apart ([Microsoft Tech Community](https://techcommunity.microsoft.com/discussions/microsoftteams/jabra-evolve-75-uc-muteunmute-sync-issue-with-teams-1-5-00-22362-82622/3620038)); mutesync sells a button that "stays in sync" ([Chrome Web Store](https://chrome.google.com/webstore/detail/mutesync/bgkanlpcmdofcgadmpkeifiobdlkaceg)).
- **Today:** hardware mute buttons, Stream Deck, constant icon checking.
- **DC-1, inference:** a large, glanceable mute state on the tablet is plausible, but it must never be wrong (ST3). Reading mute state from Zoom, Meet and Teams is per-app work and fragile (`BEYOND-DRAWING.md` B5). Partial.

## 2. Explaining spatial or structural ideas

### SP1. Drawing with a mouse or trackpad is too slow and imprecise
- **Who:** teachers, tutors, engineers in system design interviews, consultants.
- **Evidence:** "writing with the Draw tool using a mouse is imprecise" ([UChicago](https://academictech.uchicago.edu/2022/07/19/using-zooms-new-whiteboards-in-your-online-teaching)); "the mouse simply cannot give the same level of dexterity that you get with a marker pen" ([Quora](https://www.quora.com/It-is-hard-to-draw-or-annotate-like-for-example-teaching-a-class-using-the-whiteboard-on-zoom-on-a-computer-with-a-mouse-Is-there-a-better-way-for-10)); TeamBlind title: "It's very hard to draw diagrams quickly using mac mousepad" ([TeamBlind](https://www.teamblind.com/post/using-excalidraw-for-system-design-jxwgvoaj)); interviewing.io: drawing arrays "with a mouse is slow, which defeats the purpose" ([interviewing.io](https://blog.interviewing.io/building-interviewing-ios-collaborative-replayable-whiteboard/)). Consultants find in-room whiteboard energy "not easy over Zoom" ([Quartz](https://qz.com/1914282/digital-whiteboards-are-helping-consultants-brainstorm-online)).
- **Today:** Wacom and iPad purchases, Excalidraw shortcuts, typing instead of drawing, not drawing at all.
- **DC-1, inference:** this is the product's home ground. The DC-1 also shows ink under the pen, which removes the screenless-tablet "write here, look there" problem ([XP-Pen](https://www.xp-pen.com/blog/best-digital-writing-drawing-pad-tablet.html)). Strong.

### SP2. Pen input inside meeting and canvas apps is unreliable
- **Who:** math tutors, teachers, facilitators with a stylus.
- **Evidence:** Zoom Whiteboard turns "the second stroke of an 'x'" into a drag ([Zoom Community](https://community.zoom.com/t5/Zoom-Whiteboard/Problems-drawing-on-whiteboard-with-stylus/m-p/75198)); annotation loses strokes "when writing quickly" ([Zoom Community](https://community.zoom.com/meetings-2/zoom-annotate-tool-eats-penstrokes-28600)); annotation stops after about 20 minutes, hit "almost daily" ([Zoom Community](https://community.zoom.com/meetings-2/unable-to-annotate-on-shared-screen-41600)); a tutor was "seriously debating abandoning Zoom whiteboards" ([Zoom Community](https://community.zoom.com/whiteboard-8/laggy-response-in-whiteboard-66761)). Microsoft Whiteboard ink took "two seconds to appear" and Microsoft rolled back ([Windows Central](https://windowscentral.com/following-fan-backlash-microsoft-will-roll-back-previous-version-whiteboard-windows)). Miro pens lag with others connected ([Miro Community](https://community.miro.com/ask-the-community-45/slow-performance-with-pen-tool-on-huion-tablet-1399)). Tutors: "lag kills the teaching flow" ([Zutor](https://zutor.app/blog/best-whiteboard-online-tutoring), attribution uncertain).
- **Today:** write slowly, downgrade Zoom, Microsoft Paint on a share.
- **DC-1, inference:** our ink never touches Zoom's annotation layer, so this whole bug class goes away in every app. Our own latency must be measured and published (`DRAWING-DEEP-DIVE.md` D1). Strong.

### SP3. Second-device joins, AirPlay and share switching
- **Who:** lecturers and tutors with an iPad.
- **Evidence:** Carnegie Mellon publishes a two-device guide: join again from the tablet, and "only one device has audio active will prevent echo problems" ([CMU PDF](https://www.cmu.edu/canvas/teachingonline/zoom/documents/lecture-with-handwriting---two-devices.pdf)); AirPlay guides recommend paid AirServer for "more responsive" mirroring ([MSU Moorhead](https://web.mnstate.edu/cabanela/iPad_on_Zoom/)); a UW engineering guide notes limits "from the ability to switch between screens" ([UW PDF](https://www.aa.washington.edu/sites/aa/files/OnlineCourseDelivery_Shumlak.pdf)).
- **Today:** double joins, muting the iPad, switching shares mid-lesson.
- **DC-1, inference:** a virtual camera removes the second participant, the echo and the share switch. Our own one-time setup (signing, extension approval, pairing) is the cost we impose instead. Strong.

### SP4. Sharing hides faces in both directions
- **Who:** teachers (lose the students' faces), students (lose the teacher's), presenters.
- **Evidence:** "When you share your screen ... your view of the students ... disappears"; students "could not see both the teacher and the board at the same time" ([Fora Soft](https://www.forasoft.com/learn/elearning-video/articles-elearning/screen-sharing-for-teaching)). In a share, "video tiles will become smaller, movable thumbnails" ([Zoom Community](https://community.zoom.com/meetings-2/how-hide-presenter-s-thumbnail-for-all-participants-during-sharing-31309)). Zoom (2024) and Webex added presenter views so students keep "eye contact" and "body language" ([VCU](https://blogs.vcu.edu/zoom/2024/01/24/new-screen-sharing-presenter-view/)). Prezi Video "solves the awkward screen-sharing experience where your audience sees your slides but not your face" ([Dupple](https://dupple.com/reviews/prezi)).
- **Today:** dual monitors, presenter views, Prezi.
- **DC-1, inference:** the split view is exactly this, in every app, with no share; the teacher keeps the gallery. Strong. Caveat: Presenter Overlay is now free on every Mac ([AppleInsider](https://appleinsider.com/inside/macos-sonoma/tips/how-to-use-presenter-overlay-in-macos-sonoma)), so "face next to content" alone is not a moat; the pen is.

### SP5. The far side cannot read it
- **Who:** every viewer; worst on phones, in gallery view and on weak links.
- **Evidence:** camera video "can be as low as 640x360" while screen shares are sent sharper ([statusq.org](https://statusq.org/?p=9834), search summary); Zoom 1080p is limited to Business plans and active-speaker layout ([Boise State](https://talk-boisestate.atlassian.net/wiki/spaces/LTS/pages/1928462337/Using+1080p+HD+Video+in+Zoom), search summary); virtual-camera text looked blurrier than window capture ([OBS forum](https://obsproject.com/forum/threads/blurry-text-in-ndi-virtual-cam-in-zoom-%E2%80%94-zoom-window-capture-not-blurry-at-all.124824)); "it's tough to make out what's written on the whiteboard" ([Vani](https://www.vanihq.com/blog/online-whiteboarding.html)); students' pencil "too light to see" on webcams ([The Sassy Math Teacher](https://www.thesassymathteacher.com/zoom-classroom-math-activities-for-students-with-a-document-camera/)).
- **Today:** spotlight or pin, screen share instead, physical boards with Logitech Scribe ($1,199) or ShareTheBoard ([ShareTheBoard](https://sharetheboard.com/whiteboard-capture)).
- **DC-1, inference:** by our own geometry the default 3.2 px pen becomes 0.7 px at 360p (`DRAWING-DEEP-DIVE.md` section 1). This is the product's biggest physical risk. Partial fit until legibility work lands.

### SP6. One-way: the far side cannot draw back
- **Who:** tutors (want to see student work), interviewers, families, workshop facilitators.
- **Evidence:** iPad drawing in interviews was "very one-way, helpful for explaining concepts but not collaborative" ([TeamBlind](https://www.teamblind.com/post/best-setup-to-take-a-remotevirtual-system-design-interview-0foztcvm)); "the biggest obstacle to online math instruction is checking in on the students' thinking" ([eSchool News](https://www.eschoolnews.com/steam/2020/10/16/challenges-online-math-instruction/)); Caribu lets families "draw in coloring books" together but needs its app on both sides ([App Store](https://apps.apple.com/us/app/caribu-family-video-calls/id763451959)); Teams guests lose the whiteboard after the meeting ([Microsoft Learn](https://learn.microsoft.com/en-us/answers/questions/1803142/using-whiteboard-while-working-with-guests-in-a-te)).
- **Today:** shared boards (Bitpaper, Miro, Excalidraw), photos of paper.
- **DC-1, inference:** none today; a guest link is the macro-idea with the most risk (`DRAWING-DEEP-DIVE.md` M1). Position v1 as "the presenter explains", not as a shared board.

### SP7. Annotating existing material
- **Who:** tutors (worksheets, past papers), sales (pricing pages), engineers (screenshots).
- **Evidence:** tutors mostly "mark up a worksheet, a textbook page, or a screenshot", and PDF upload with annotation is called the most used tutoring workflow ([Ziteboard](https://ziteboard.com/math-tutoring-whiteboard-collaboration/), [Zutor](https://zutor.app/blog/best-whiteboard-online-tutoring), attribution uncertain between them); Zoom annotation strokes "vanish immediately and need to be retraced 3-4 times" ([Zoom Community](https://community.zoom.com/meetings-2/annotations-drawn-from-ipad-on-windows-screen-share-vanish-immediately-v7-1-5-anyone-else-81592/index4.html)).
- **Today:** shared boards with PDF upload, Zoom annotation over a share.
- **DC-1, inference:** none today; import a PDF or paste a screenshot as a page (D33, D34). Mirror mode already shows any tablet app (for example a PDF reader with ink), at video quality.

### SP8. Keyboards cannot express math
- **Who:** math and science teachers and students.
- **Evidence:** it is "difficult to achieve sufficient interaction ... through use of a keyboard" ([Teaching Mathematics and its Applications](https://academic.oup.com/teamat/article/40/4/392/6380163)); "Hand writing solutions onto a small screen is challenging", so lecturers pre-prepare ([Western Sydney University](https://westernsydney.edu.au/mesh/mesh/resources_for_staff/effective_use_of_zoom_for_teaching_mathematics/presenting_worked_solutions)); a tablet with stylus is a "must have for math tutoring" ([Piqosity](https://www.piqosity.com/2017/12/06/skype-tutoring-apps-and-tips/)).
- **Today:** LaTeX, equation editors, document cameras.
- **DC-1, inference:** strong; live derivation with the face visible.

## 3. Shared attention and pointing

### PA1. "Can you see my cursor?"
- **Who:** anyone pointing during a share.
- **Evidence:** people install "a solid green circle which follows the mouse" ([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/3222/mouse-pointer-not-visible-when-sharing-screen)); Zoom ships a spotlight tool "for highlighting the location of your cursor" ([SCU](https://spark.scu.edu.au/kb/tl/teach/technology-integration/teaching-online-classes-with-zoom/zoom-annotation-tools)); Notability and GoodNotes added laser pointers to "point to content on screen without leaving any lasting markings" ([Notability](https://support.gingerlabs.com/hc/en-us/articles/360040604772-Tips-for-Online-Learning-with-Notability)). Research: a pointing gesture "might be useless if not seen and acknowledged" ([JEMR](https://bop.unibe.ch/JEMR/article/download/2308/3504/8532)).
- **Today:** pointer apps, "the box on the left, no, the other left".
- **DC-1, inference:** EMR pens hover; a hover ring and a laser drawn into the pixels cannot go missing (D9, D10). Strong.

### PA2. Viewers get lost on big canvases
- **Who:** workshop participants, students.
- **Evidence:** "As soon as a participant clicks on the board they will stop following the presenter and will get lost" ([Miro Community](https://community.miro.com/ask-the-community-45/how-to-enforce-follow-me-2401)); FigJam's open canvas "lacked the clear page boundaries that made Jamboard effective" ([New Six Things](https://newsixthings.substack.com/p/six-revolutionary-teacher-web-tools)).
- **Today:** forced follow modes, screen share of the canvas.
- **DC-1, inference:** a camera picture is one shared viewport by construction. Pages plus a page counter (D28) keep that strength. Strong.

### PA3. Looking down reads as disengaged, or as cheating
- **Who:** candidates, therapists, lip readers on the far side.
- **Evidence:** eye contact is "the number one issue professionals face in telehealth" ([SecureVideo](https://securevideo.com/?p=18823)); glancing at notes "pulls your gaze away from the camera, making you seem disengaged" ([Airtime](https://www.airtime.com/blog/maintain-eye-contact)); interview proctoring flags "eyes repeatedly moving to a fixed point off screen" ([WeCP](https://www.wecreateproblems.com/blog/behavioral-signs-of-cheating-during-remote-interviews)); deaf participants want a preset "Please look at me" message (Jod, ASSETS 2023, [NSF PAR](https://par.nsf.gov/biblio/10474592-jod-examining-design-implementation-videoconferencing-platform-mixed-hearing-groups)).
- **Today:** notes near the camera, announcing "I'm taking notes".
- **DC-1, inference:** a Risk. When the pen draws on air, the split view explains the downward look ("show your work, visibly"). Private writing does not. Placement guidance (tablet below the camera axis, not to the side) and the on-air border (D5) help. Never fix it with gaze correction (`DRAWING-DEEP-DIVE.md` section 5).

## 4. Note capture and follow-up

### NC1. Drawings vanish when the meeting ends
- **Who:** teachers, facilitators, anyone who forgot to export.
- **Evidence:** "all whiteboarding information is deleted when the meeting ends" ([Zoom Community](https://community.zoom.com/whiteboard-8/recover-whiteboard-65546)); saved boards cannot be loaded back ([Zoom Community](https://community.zoom.com/whiteboard-8/can-i-upload-a-saved-whiteboard-back-into-the-zoom-whiteboard-66436)); Teams whiteboard content is "unavailable to all external users once the meeting is over" ([Microsoft Learn](https://learn.microsoft.com/microsoft-365/whiteboard/manage-sharing-organizations?view=o365-worldwide)); Jamboard shut down on December 31, 2024 ([Google](https://support.google.com/jamboard/answer/14084927?hl=en)).
- **Today:** screenshots, mid-call exports.
- **DC-1, inference:** already strong: every page is saved as PNG plus strokes JSON (SPEC 12). Missing: one file per call, reopening, and a fresh page per call so pages do not run into each other (D6, D39, D42).

### NC2. AI notetakers capture speech, not drawings
- **Who:** anyone relying on Otter, Zoom AI Companion, Granola, Meet notes.
- **Evidence:** "if someone ... drew on a whiteboard ... the transcript captures what was said about it but not the visual itself" ([AFFiNE](https://affine.pro/blog/ai-note-taker-intro)); Google Meet notes are adding "screenshots of shared slides, diagrams" ([Neowin](https://www.neowin.net/news/google-meets-ai-note-taker-will-soon-start-including-presentation-screenshots/)).
- **Today:** "as you can see here" in a transcript that shows nothing.
- **DC-1, inference:** those screenshot features read screen shares; ink in a camera feed is probably missed (unverified). Our own export, with recognised text and a timeline, fills the gap (M3, M10). Partial.

### NC3. Decisions and owners evaporate or are misassigned
- **Who:** teams, clients, managers.
- **Evidence:** vendor-reported: "54% of workers frequently leave meetings without a clear idea of next steps" (attributed to Atlassian, via [SpeakWise](https://speakwiseapp.com/blog/meeting-recall-statistics); primary not seen). Zoom AI Companion summaries were said to miss "critical decisions" and assign an action "to someone who was never even in the meeting" ([Jamie](https://www.meetjamie.ai/blog/zoom-ai-companion-review), competitor review). Whiteboard photos are "sometimes used as evidence of agreement" (Waterloo thesis, [UWSpace](https://uwspace.uwaterloo.ca/handle/10012/10546)).
- **Today:** follow-up emails, AI summaries, photos of boards.
- **DC-1, inference:** a decision written by hand on air is seen and agreed by everyone at the moment it is made; decision and action boxes (D44) carry it to the follow-up. Partial.

### NC4. Typing notes is noisy and looks rude
- **Who:** interviewers, therapists, salespeople, students.
- **Evidence:** typing "signals to others that you're not paying attention" ([Becker's](https://www.beckershospitalreview.com/hospital-management-administration/mind-your-manners-10-courtesies-for-videoconferencing.html)); therapists "while busily typing ... were missing all sorts of client cues" ([Psychotherapy Networker](https://www.psychotherapynetworker.org/article/take-notes-or-not-take-notes/)); tools exist to mute the mic while typing ([Softpedia, Unclack](https://mac.softpedia.com/get/System-Utilities/Unclack.shtml)).
- **Today:** paper, quiet keyboards, no notes.
- **DC-1, inference:** a pen on glass is near silent and reads as note taking. It still pulls the eyes down (PA3), and private notes must never go on air (ST4). Partial.

### NC5. "Can you send me that diagram?"
- **Who:** clients, students, colleagues.
- **Evidence:** users ask Zoom to send whiteboards to participants automatically after a meeting ([Zoom Community](https://community.zoom.com/whiteboard-8/sending-whiteboard-and-screenshots-automatically-to-participants-once-the-meeting-ends-65309)); Preply students "cannot access the whiteboard after the lesson" ([Preply](https://preply.com/en/question/how-do-i-access-the-whiteboard-notes-after-completing-a-lesson-73603)).
- **Today:** screenshots pasted into email.
- **DC-1, inference:** the pages already exist on disk; one action to send them (D39 to D41). Strong.

### NC6. Clients dislike notetaker bots
- **Who:** client-facing work (sales, therapy, legal, consulting).
- **Evidence:** vendor-reported Calendly figure: "58% of professionals feel uncomfortable when an AI meeting bot joins unexpectedly" ([Umevo](https://www.umevo.ai/blogs/ume-all-posts/the-bot-backlash-why-clients-refuse-meetings-with-ai-notetaker-bots)); Granola sells capture "without joining as a bot" ([Zapier](https://www.zapier.com/blog/granola-ai)).
- **DC-1, inference:** visible handwriting is consensual capture: the client sees what is noted. Partial; a positioning point, not a feature.

## 5. Attention and fatigue

### AF1. Hyper-gaze and self-view drive fatigue
- **Who:** heavy call users; more for women and newcomers.
- **Evidence:** Bailenson's four causes include "excessive amounts of close-up eye gaze" and "staring at video of oneself" ([APA Open](https://tmb.apaopen.org/pub/nonverbal-overload/release/1)); n of about 10,500 on the ZEF scale, women report about 13.8 percent more fatigue ([National Geographic](https://www.nationalgeographic.com/science/article/zoom-fatigue-may-be-with-us-for-years-heres-how-well-cope)); camera-on days caused more fatigue, and cameras off did not reduce engagement (Shockley 2021, [Newswise](https://www.newswise.com/articles/cameras-not-meetings-cause-zoom-fatigue)).
- **Today:** hide self-view, cameras off.
- **DC-1, inference:** a board gives viewers something other than faces to look at and gives the presenter a legitimate reason to look down. Plausible relief, unproven; measurable with the ZEF scale.

### AF2. Back-to-back calls build stress
- **Evidence:** Microsoft's EEG study saw beta-wave activity climb across four back-to-back meetings and not with breaks ([Corporate Rebels](https://corporate-rebels.com/brain-research)); weekly meeting time rose 252 percent from 2020 to 2022 ([Microsoft](https://news.microsoft.com/2022/03/16/microsoft-announces-new-research-and-technology-to-make-hybrid-work-work/)).
- **DC-1, inference:** a calm, low-glare timer and "next call in 4 minutes, stand up" on the tablet (`BEYOND-DRAWING.md` B2). Partial.

### AF3. Multitasking during calls
- **Evidence:** email multitasking in "about 30% of remote meetings" (Cao, Iqbal et al., CHI 2021, [arXiv](https://arxiv.org/pdf/2101.11865)); 76 percent of UK office workers turned the camera off to hide what they were doing ([HR Grapevine](https://www.hrgrapevine.com/content/article/2022-10-04-office-workers-admit-turning-off-webcam-at-work-to-hide-this)).
- **DC-1, inference:** not ours to fix.

### AF4. Video narrows creative thinking
- **Evidence:** "videoconferencing hampers idea generation because it focuses communicators on a screen" (Brucks and Levav, Nature 2022, n=1,490, [RePEc](https://ideas.repec.org/a/nat/nature/v605y2022i7908d10.1038_s41586-022-04643-y.html)); "Employees miss whiteboards in video meetings" (Forrester via Logitech, [Logitech](https://origin2.logitech.com/en-in/business/resource-center/article/better-approach-virtual-whiteboarding.html), vendor framing).
- **DC-1, inference:** a physical sketching surface off the screen might widen focus. Speculative; worth a small test, never a marketing claim.

### AF5. ADHD: staying focused needs an outlet
- **Evidence:** "The act of writing helps keep people focused ... Some people find that doodling helps them focus" ([Medical News Today](https://www.medicalnewstoday.com/articles/adhd-zoom-meetings)); Zoom Community request for in-app focus tools for ADHD ([Zoom Community](https://community.zoom.com/meetings-2/feature-recommendation-integrated-focus-tools-for-better-meeting-engagement-in-app-adhd-games-18218)).
- **DC-1, inference:** a pen on a calm surface is a sanctioned fidget that produces notes, but only with off-air ink (D4); today a doodle engages the board on camera. Partial, with a Risk.

## 6. Accessibility

### AC1. Captions fail on names, numbers, jargon
- **Who:** deaf and hard of hearing (DHH) people, ESL listeners, anyone reading captions.
- **Evidence:** auto captions get "about 1 in 10 words wrong" in some products, worse for non-native speakers ([Consumer Reports](https://www.consumerreports.org/disability-rights/auto-captions-often-fall-short-on-zoom-facebook-and-others-a9742392879)); they "really struggle with non-standard words, such as names" (same); 75 percent of employees with hearing loss rank video meetings as their hardest task ([Cochlear](https://hearandnow.cochlear.com/hearing-solutions/services/hybrid-working-hearing-loss/)); guidance asks hearing participants to turn captions on to catch errors ([University of Leeds](https://equality.leeds.ac.uk/support-and-resources/disability-2/deaf-awareness/support-for-deaf-and-hard-of-hearing-colleagues/communication-tips-online-meetings/)).
- **Today:** typing corrections in chat, repeating, spelling aloud.
- **DC-1, inference:** writing the name, number or term in two seconds puts it in the picture DHH and ESL guests are already watching. Strong, cheap, and a good onboarding example.

### AC2. Lip readers need a large face and tight sync
- **Evidence:** audio-visual fusion holds only within "about 200-300 ms" ([PMC](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5193434/)); lip reading tiny tiles with delayed audio is described as "exponentially worse" than ordinary fatigue ([Hearing Health Matters](https://hearinghealthmatters.org/better-hearing-consumer/2020/how-to-zoom-like-a-hoh-with-hearing-loss/)); "make sure your entire face is visible" ([RNID PDF](https://developer.rnid.org.uk/wp-content/uploads/2022/04/A201039_VideocallsandmeetingsPDF-tips-APRIL2022_01.pdf)).
- **DC-1, inference:** a Risk with two parts. (1) Studio Split crops the presenter rather than scaling (SPEC 6.1), so the face keeps its pixel size: good. Overlay shrinks the face to a 302 px square (SPEC 6.7): keep it off by default, as it is. (2) The composed modes must add no audible lag: measure added video delay against passthrough. Also coach "look up when you speak, write while you listen".

### AC3. Non-native listeners need text support
- **Evidence:** real-time transcription significantly improved non-native comprehension in audio and audio-video meetings (IBM, 48 participants, [IBM Research](https://research.ibm.com/publications/effects-of-real-time-transcription-on-non-native-speakers-comprehension-in-computer-mediated-communications)); TEFL trainers call a whiteboard "an absolute must" ([The TEFL Academy](https://www.theteflacademy.com/blog/5-must-have-classroom-props-for-teaching-english-online)).
- **DC-1, inference:** handwritten key words are curated text support; strong.

### AC4. Low bandwidth: video and fine detail die first
- **Evidence:** under constrained bandwidth, "frozen presentation slides and very poor video quality" while audio is protected ([UCT](https://pubs.cs.uct.ac.za/id/eprint/810/)); Zoom 1:1 video needs 600 kbps, screen share only 50 to 75 kbps ([Columbia College Chicago](https://colum.teamdynamix.com/TDClient/2029/Portal/KB/Article/102394/Bandwidth-requirements-for-Zoom)); 22 percent of students cited weak internet for keeping cameras off ([Times Higher Education](https://www.timeshighereducation.com/campus/see-or-not-see-managing-complex-issue-zoom-cameras)).
- **DC-1, inference:** a Risk: fine ink in a compressed camera feed is the first thing to blur. Mitigations: bolder ink (D14), the board-window screen-share route (M6), and the post-call PDF, which always survives.

### AC5. Blind and screen reader users get nothing from pixels
- **Evidence:** "Exclusively graphical workspaces in whiteboards are not accessible to users of screen readers"; avoid them for "essential" content ([UW AccessComputing](https://accesscomputing.uw.edu/knowledge-base/are-electronic-whiteboards-accessible-to-people-with-disabilities)); "If writing on a whiteboard, read out as much of what you are writing as feasible" ([CU Boulder](https://www.colorado.edu/digital-accessibility/visual-description)).
- **DC-1, inference:** a Risk: ink burned into video is the least accessible form of content there is. Mitigations: "say it as you write it" nudge (D52), recognised text in the export (M3), a text page link (M2).

### AC6. Sign language interpreters must stay large
- **Evidence:** "incredibly difficult to understand a sign language interpreter when they are two inches on screen" ([GCcollab PDF](https://wiki.gccollab.ca/images/a/a8/MS_Teams_and_Zoom_features_for_sign_language_interpretation.pdf)); signing stays intelligible down to 15 fps and drops sharply at 5 (MobileASL, [UW](https://dada.cs.washington.edu/research/mobileasl/downloads/assets090-cherniavsky.pdf)).
- **DC-1, inference:** a Risk only if our feed tempts hosts to spotlight it over the interpreter; our tip (D19) should say "spotlight me when I draw", not "pin me". Never drop camera frame rate to save CPU (we hold 30 fps).

### AC7. Older adults and setup burden
- **Evidence:** 38 percent of older Americans were not ready for video visits, with "not knowing how to connect to the platform (24%)" and "difficulty hearing (15.2%)" ([MobiHealthNews](https://www.mobihealthnews.com/news/jama-study-warns-telemedicine-not-suitable-38-patients-over-65)); grandparent guides say "Make sure the camera is pointed at Grandma's face (and not the ceiling fan)" ([The Senior](https://www.thesenior.com.au/story/6844105/how-to-make-video-calls-with-the-grandkids-childs-play/)).
- **DC-1, inference:** the far side needs nothing new, which is good for older guests. Older owners face our setup, which is long today (OWNER-NEXT-STEPS is about 3 hours including signing; customers would skip signing but not the extension approval and pairing). Partial.

## 7. Technical setup friction

### TS1. macOS virtual cameras break on OS updates
- **Evidence:** macOS 14.1 turned off legacy virtual cameras by default ([Zoom Community](https://community.zoom.com/meetings-2/camtwist-and-streamlabs-virtual-cameras-not-showing-up-in-zoom-on-macos-45542)); on macOS 26 the approval moved to "Media Extension" and can wait with no prompt ([OBS forum](https://obsproject.com/forum/threads/virtual-camera-mac-os-tahoe-26-3-1.194658/)); a macOS 27.0 thread: "Camera extension is activated enabled but never launched" ([OBS forum](https://obsproject.com/forum/threads/macos-27-0-%E2%80%93-could-not-find-the-virtual-camera-system-process-%E2%80%93-camera-extension-is-activated-enabled-but-never-launched.196433/)); after a CMIO extension upgrade on 14.5 "daemon is not running" until reboot ([Apple Developer Forums](https://developer.apple.com/forums/thread/756234)).
- **DC-1, inference:** a risk to us, not a feature. SPEC D51 already names "Login Items & Extensions > Camera Extensions" on macOS 26; the OBS thread suggests a "Media Extension" entry in Privacy & Security too. Verify on the owner's Mac and add a macOS 27 row to the testing checklist before any customer ships.

### TS2. Wrong camera, camera hijacked, camera not listed
- **Evidence:** Zoom switches to the iPhone "unprompted" ([Zoom Community](https://community.zoom.com/meetings-2/camera-switching-to-phone-unprompted-8446)); Zoom not seeing OBS until the user toggled background blur ([OBS forum](https://obsproject.com/forum/threads/virtual-camera-not-recognized-in-zoom.170826/)).
- **DC-1, inference:** the tablet can say whether any app is actually viewing Daylight Camera (D36, D37). Partial.

### TS3. Heavy camera apps heat the laptop and add lag
- **Evidence:** mmhmm's help center: "computer fan noise, or choppy or delayed video" ([mmhmm help](https://studio.help.mmhmm.app/hc/en-us/articles/18536793076375-Improve-computer-performance-when-using-mmhmm-Studio)); reviewers report lip-sync delay and "an artificial cut-off" ([G2](https://www.g2.com/survey_responses/airtime-review-9333490)); Camo advertises "keeping your computer cool" ([Reincubate](https://reincubate.com/camo/continuity-camera)).
- **DC-1, inference:** our budgets (SPEC 15: passthrough under 3 percent, Studio Split under 8 percent) are a selling point once measured. Strong.

## 8. Status and presence

### ST1. Camera-off ambiguity and appearance anxiety
- **Evidence:** 90 percent of students turned cameras off at some point; 41 percent cited appearance ([Cornell](https://news.cornell.edu/node/320790)); bookcase and plant backgrounds rated most trustworthy ([TechRepublic](https://techrepublic.com/article/your-zoom-background-may-not-make-you-look-as-professional-as-you-think)).
- **DC-1, inference:** a board is a way to be present without a face (Whiteboard Only when the camera is off). Partial; do not build appearance effects (free elsewhere, spectacle).

### ST2. "Did I freeze? Can you see it?"
- **Evidence:** freezing and lag were the top technical frustration for 53 percent in a UK survey (source page unconfirmed, [Debrett's](https://debretts.com/the-10-most-awkward-things-about-video-calls/)); Camo users open its preview first to see how they look ([Reincubate](https://reincubate.com/camo/continuity-camera)).
- **DC-1, inference:** an outgoing-frame thumbnail on the tablet answers "can you see it" without asking (D35). Strong.

### ST3. Status signals drift out of sync
- **Evidence:** Stream Deck users value checking mute "regardless of what they're doing" ([Mac Power Users](https://talk.macpowerusers.com/t/elgato-stream-deck-xl/13687/50)); busy lights fail because "co-workers ignored the signal" ([Laptop Mag](https://www.laptopmag.com/reviews/accessories/luxafor-flag)); Blynclight "fails to connect to Teams or Outlook calendars" ([MSU](https://msu.teamdynamix.com/TDClient/1815/Portal/KB/ArticleDet?ID=94084)).
- **DC-1, inference:** we own one status perfectly: whether the board is on air (STATE is the Mac's truth). Show it unmistakably (D5). Be careful with status we do not own (mute).

### ST4. Private content leaks into the call
- **Evidence:** a therapist's accidental screen share showed a patient "ChatGPT ... to input and summarize what the patient said" ([Newsweek](https://www.newsweek.com/therapist-accidentally-shares-screen-during-telehealth-session-patient-floored-what-they-see-2075935)); clients "may wonder what their therapist is writing about ... or feel more judged" ([Psychology Today](https://www.psychologytoday.com/us/blog/in-therapy/201412/why-do-some-therapists-take-notes-in-session)); Safari can only share the entire screen ([TherapyNotes](https://support.therapynotes.com/hc/en-us/articles/30661213867291-Share-Your-Screen-in-a-Telehealth-Session)).
- **DC-1, inference:** both. Strong: the camera shows only the board, never the desktop. Risk: pen-down engages automatically, so any note is broadcast, and per SPEC 5.2 and 7 a page survives a return, so last call's page can reappear in the next call. Off-air ink (D4) and a fresh page per call (D6) close it.

---

## Who feels it most (segment view)

| Segment | Strongest frictions | Fit | Biggest risk |
|---|---|---|---|
| Math and science tutors | SP2, SP3, SP4, SP8, NC5 | High | SP6 one-way, SP7 no worksheet import |
| Language tutors | AC3, NC5 | Medium to high | a $10 physical mini whiteboard |
| Therapists (CBT, family) | NC4, ST4, PA3 | Medium | auto-engage broadcasts private notes (ST4) |
| Engineers and consultants | SP1, PA1, NC5 | High | SP5 on fine diagrams |
| Interview candidates | SP1, PA3 | Low to medium | companies mandate Excalidraw |
| Sales and sales engineers | SP4, NC3 | Medium to high | proof it moves deals; hand-drawn beats slides per vendor research ([Corporate Visions](https://corporatevisions.com/blog/whiteboarding/)) |
| Families, travelling parents | SP6 | Medium | one-way vs Caribu; grandparents on phones |
| DHH and ESL guests (far side) | AC1, AC3 | Strong as beneficiaries | AC2 face and sync |

---

> **If you only read one section**
>
> The frictions that matter most for a pen beside the laptop are: pen input in meeting apps is broken (SP2: Zoom drops strokes "almost daily" for tutors), screen sharing hides faces (SP4), drawings are lost after the call (NC1), and pointing gets lost (PA1). The DC-1 fits all four, because ink lives in the camera, never in Zoom's annotation layer. Three things can make calls worse: the far side may not be able to read thin ink at 360p to 720p (SP5), pen-down broadcasts private notes and last call's page can reappear (ST4), and ink in video is invisible to screen readers and notetakers (AC5, NC2). Fix those three first. The strongest non-drawing win is cheap: writing the names and numbers that captions get wrong (AC1). All quotes are search excerpts; verify before external use.
