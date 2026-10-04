# The "too small" problem: making the whiteboard big in a group call

Date: 2026-10-04. Owner question, condensed: with several people on a Zoom or Meet call each camera tile is small, so a detailed drawing in the Daylight Camera picture is hard to read. A screen share becomes big for everyone automatically. Can we use or hijack that so the whiteboard becomes big without anyone having to do anything?

Short answer: nobody can make a camera tile big for other people (only hosts can spotlight, and a spotlighted tile is still a low-resolution camera stream). Everything that is big for everyone travels on the **content track** (screen share, window share, or "share a camera as content"). No app can start a share inside another app's call for you, so "nothing to do" is not reachable; **one or two clicks per call** is. Tonight's build makes those clicks short and the result sharp: a dedicated **"Daylight Whiteboard" share window**. The next build should add a **second camera device** that Zoom, Meet and Teams can each share as content, and then **follow the pen** inside the camera tile for the cases where nobody shares.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming. Citations are the bracketed numbers; section 11 lists them. "UNVERIFIED" marks anything no source confirmed. Several vendor help sites were blocked from this research environment, so some claims rest on the vendor text quoted by a search engine; they carry "(quoted)".

## 1. The problem in numbers

| Call size | Where your camera tile ends up (MacBook Pro 14 full screen, 1512 x 982 pt) | Stream the viewer receives | The Studio Split page inside that tile |
|---|---|---|---|
| 2 people | about 744 x 418 pt (estimate) | up to 720p | about 314 pt wide: readable |
| 4 people | about 744 x 418 pt (estimate) | 360p (Webex 2 to 4 tiles [20]) | readable with care |
| 9 people (3 x 3) | about 493 x 277 pt (estimate) | 360p (Zoom 3 x 3 [4][5]) | about 208 pt wide on a 640 px wide stream |
| 25 people (5 x 5) | about 292 x 164 pt (estimate) | 180p (Zoom 5 x 5 [4][5]; Webex more than 4 tiles [20]) | about 123 pt wide on a 320 px wide stream: not readable |

The estimates fit 16:9 tiles into the documented grids (Zoom 25 or 49 per page [1][2]; Meet Auto 9 and Tiled 16 by default [7]; Teams 4, 9, 16 or 49 [11]; Webex 25 by default [19]; FaceTime grid from 4 people [18]) with 8 pt gaps and a 110 pt toolbar. No vendor publishes tile pixel sizes. The resolution column is sourced.

Two things make the tile unreadable, and only one of them is size: in a 5 x 5 Zoom gallery the tile is fed a **180p** stream [4][5]. Sharper strokes from Daylight cannot survive a 320 x 180 stream. Our own Studio Split puts an 810 x 1080 page into the 1920 x 1080 frame, so the page is 42 % of the frame width before the call app shrinks it.

A shared screen in Zoom full screen on the same MacBook gets roughly 1185 x 740 pt (estimate), about **16 times the area of a 5 x 5 tile**, at up to 1080p when "Optimize for video clip" is off [24].

## 2. First principles: two tracks

Every call app sends two kinds of video:

- **Camera track.** One per person, shrunk into a tile, simulcast at a layer chosen by tile size (180p to 1080p), cropped to 16:9 or to faces (Zoom crops to 16:9 unless "Original ratio" is ticked, dynamic gallery crops to faces; Meet crops portrait tiles unless "Show my full video to others" is on; macOS research, section 6). Daylight Camera lives here.
- **Content track.** One (sometimes two) per call, promoted to the main stage for every viewer: Meet's Spotlight and Sidebar put the shared screen as the main image [7], Webex shifts focus to shared content [19], Teams has "Focus on content" [21], Zoom shows the share full window with optional Side-by-side [22]. It is encoded for text (Zoom about 1920 x 1080 at a lower frame rate with "Optimize for video clip" off [24]; Webex "Best for text and images" [26]; Teams 15 fps for content [13]). The presenter's camera tile stays visible as a thumbnail [22][23].

So the whiteboard must get onto the content track. The content track has three doors on every major platform today:

1. **Share the whole screen** (shows everything, including notifications; worst privacy).
2. **Share one window** (shows only that window, even when it is covered; it pauses when minimised [62][63]).
3. **Share a camera as content**: Zoom "Share Screen > Advanced > Second camera" (formerly "Content from 2nd Camera") [30][31]; Google Meet "Present content from camera", June 2025, up to 1080p 30 fps on most Workspace plans [49]; Teams "Share > Content from camera" on Windows and Mac desktop [58].

Door 3 is the one the owner's "hijack" intuition points at: a camera that the call app treats as a screen share. It needs no window and no screen-recording permission, and it shows exactly what Daylight renders.

## 3. What each platform lets a participant do (verified where marked)

| Platform | Make me big for everyone without a share | Share a window | Share a camera as content | Can an app start a share? |
|---|---|---|---|---|
| Zoom | Spotlight is host or co-host only, needs 3+ people with video [41][42]; Pin is local [44]; nobody can force others to pin them (no such feature found) | yes, picker thumbnail [38]; Command-Shift-S opens the share window [36][37] | Share Screen > Advanced > Second camera; virtual cameras are listed (OBS forum [34]); about 720p per one community reply (quoted); 4 clicks plus "Switch Camera" until Daylight comes up | a Zoom App can `shareApp()` its own web view without the picker; `addParticipantSpotlight` is host only; pins and `setMeetingView` change only the caller's view [46] |
| Google Meet | host "Pin for everyone", up to 3 tiles [51] | Present, "A window" [27] | "Present content from camera" (Settings > General toggle, then Present > Camera) [49]; free Gmail and virtual cameras UNVERIFIED | add-ons can open on the main stage for people who accept the invitation; no pin, layout, camera or share APIs [52][53] |
| Microsoft Teams | organizers and presenters can spotlight up to 7 [56]; "Pin for me" is local [57] | Share, Window; Command-Shift-E (partly verified) | Share > Content from camera (Whiteboard, Document, Video) [58]; virtual camera as the source UNVERIFIED; use "Video" (the "Whiteboard" mode crops and enhances a physical board) | `shareAppContentToStage` puts a URL on the stage for everyone, presenter role and a manifest permission required [59][60] |
| Slack huddles | none | yes; viewers click the thumbnail to enlarge [15][16] | none found | none found |
| FaceTime | none (automatic prominence for the speaker) [17] | via the macOS system picker | none found | none |
| Webex | none for participants | yes [19] | UNVERIFIED | none checked |

## 4. What a Mac app can and cannot drive (macOS 15 and 26)

- **No app can pick content for another app's share.** `SCContentSharingPicker` (macOS 14+) serves only the calling app's own streams; there is no API to choose a window inside Zoom's, Chrome's or Teams' share session, and `NSWindow.sharingType` has no "preferred for sharing" value (macOS research [12][14][15][34]). The share window therefore keeps the default `readOnly` so pickers list it.
- **The system picker helps the owner, not us.** Apps that adopt the system picker let the user start sharing "directly from a window" (WWDC23 10136, macOS research [16]): hover the window's green button and share it. Zoom has "Use Mac System Picker for screen sharing", Teams "Use macOS content sharing" (preview), Webex supports it on macOS 15 (all quoted). Whether the green-button share appears for those apps and not only FaceTime is UNVERIFIED; it is a two-click path to test on the owner's Mac. Our share window keeps a normal title bar by default so this green button exists.
- **Keyboard automation is possible but buys little.** Posting a key event to Zoom needs only the PostEvent grant (shown under Privacy and Security > Accessibility, checked with `CGPreflightPostEventAccess`, requested with `CGRequestPostEventAccess`), no entitlement under the hardened runtime (macOS research [36][37][38][41]). But Command-Shift-S only opens Zoom's share window; a human click on "Daylight Whiteboard" is still needed. Meet has no reliable global shortcut (Ctrl-Command-T appears in one quoted snippet only, UNVERIFIED) and runs in a browser tab. Verdict: not worth a permission prompt and a fragile feature.
- **Two camera devices from one extension are allowed.** `CMIOExtensionProvider` has `devices`, `addDevice` and `removeDevice`; WWDC22 10022 says the provider "lets you add and remove devices as needed" and that "AVFoundation ignores all but the first input stream", so the second camera must be a second device with its own UUID and name (macOS research [1][2][3]). No public sample ships two devices that each have a sink stream: UNVERIFIED in combination.
- **Presenter Overlay** puts the camera onto a shared screen; it never enlarges a camera tile (macOS research [16]).

## 5. Every lever, scored

Effort: S is under a day, M a few days, L a week or more. "Once" is setup; "per call" is what the owner does in every call.

| # | Lever | Feasibility | What viewers see | Owner: once / per call | Platforms | Risk | Effort |
|---|---|---|---|---|---|---|---|
| L1 | **Share window** "Daylight Whiteboard" (the page only, canvas aspect, full canvas resolution) | verified APIs; built tonight | the page on the main stage, sharp, plus your camera tile | none / 2 to 3 clicks (Share, pick the window, Share) | Zoom, Meet, Teams, Slack, Webex, FaceTime | low; a minimised window pauses the share; the call app needs screen-recording permission (monthly re-prompt on macOS 15 [20 in section 11b]) | S (done) |
| L2 | **Second camera device** "Daylight Whiteboard (share)" for "share a camera as content" | APIs verified; two devices with sinks UNVERIFIED in combination; virtual cameras listed in Zoom (forum), Meet and Teams UNVERIFIED | the page on the main stage at up to 720p (Zoom) or 1080p (Meet), no window involved | approve the updated extension once / Zoom 4 clicks plus Switch Camera, Meet Present > Camera, Teams Share > Content from camera | Zoom, Meet (Workspace), Teams | medium: extension change, owned by the Review 4 team tonight; Zoom may offer the wrong camera first | M |
| L3 | **Follow the pen** inside the camera tile: magnify the region being written, with hysteresis | math built and tested tonight (Kit FollowRegion); compositor wiring scoped | the camera tile shows the current writing up to 2.5 times larger; returns to the page after 30 s idle | toggle once / nothing | every app, including when nobody shares | low; motion can distract; does not beat the 180p stream at 25 people | S for the math (done), M for the wiring |
| L4 | Whiteboard Only, presenter smaller | exists (Whiteboard Only); a smaller presenter in Studio Split is a layout change | slightly larger page in the tile | none / a hotkey | all | low | S |
| L5 | "Fill the frame" crop: a portrait page cropped to 16:9 around the written region | a special case of L3 (zoom fixed at fill width) | 2.4 times the page width in Whiteboard Only | none / none | all | low | S once L3 is wired |
| L6 | Stroke width and contrast tuned for 320 px tiles (minimum rendered width in the camera picture) | feasible in the rasterizer; changes how the page looks to the owner too | thicker lines survive 180p better | none / none | all | medium: alters the drawing's look; belongs to the drawing team | S |
| L7 | "Pin me" prompt drawn in the picture for 3 s on engage | feasible (a compositor overlay) | a small "Pin Mike to see the board" label | none / none | all | medium: viewers must act; a pinned tile is still a 360p to 720p camera stream; it reads as noise in 2-person calls | S |
| L8 | Zoom share shortcut via PostEvent (Command-Shift-S) | feasible, PostEvent grant | nothing new; opens Zoom's picker | grant once / still one click in the picker | Zoom (Teams Command-Shift-E partly verified) | fragile; permission prompt for one saved click | S |
| L9 | Zoom App (`shareApp`) showing the page in a Zoom web view | verified SDK call [46] | a share of the app's web view, started from inside Zoom | install a Marketplace app once / open the app, press Share | Zoom only | high: Zoom Marketplace review, a hosted web app, sign-in; the page must stream to the web view | L |
| L10 | Teams stage app (`shareAppContentToStage`) | verified SDK call [59] | a web page on everyone's stage | tenant admin approval / open the app | Teams only, presenter role | high: Teams app review, hosting | L |
| L11 | Meet add-on main stage | verified SDK [52][53] | the add-on on the stage for those who accept | install once / start the activity; each viewer joins | Meet only | high: Workspace Marketplace, viewers must accept | L |
| L12 | Spotlight or Pin for everyone | host only [41][51][56] | big tile, still a camera stream | ask the host / host clicks | all, host role | not ours to automate | none |
| L13 | Presenter Overlay (macOS) | verified [16] | your camera over a shared screen | nothing new | apps on the system picker | adds nothing for the board | none |

## 6. Recommendation

| | Nothing for the owner per call | Big for every viewer | Sharp (text-optimised) | Works in Zoom, Meet, Teams | No new permission | Built tonight |
|---|---|---|---|---|---|---|
| L1 share window | no (2 to 3 clicks) | yes | yes (screen-share encoding, full canvas resolution) | yes, plus Slack, Webex, FaceTime | yes for Daylight (the call app needs screen recording, which it has for any share) | **yes** |
| L2 second camera | no (Zoom 4 clicks, Meet and Teams 2 to 3) | yes | Zoom about 720p, Meet up to 1080p | yes (virtual camera listing UNVERIFIED for Meet and Teams) | yes | scoped, patch in the handoff |
| L3 follow the pen | **yes** | no (still a tile) | no (camera simulcast) | yes | yes | math yes, wiring scoped |
| L7 pin prompt | yes for the owner | only for viewers who pin | no | yes | yes | no |
| L9 to L11 platform apps | no | yes | yes | one platform each | marketplace review | no |

Ranked proposal:

1. **L1, the share window (built).** It works in every call app today, needs no new permission for Daylight, and the shared page is sharper than any camera path because it skips the camera simulcast and arrives at the canvas's full 1200 x 1600. It costs the owner two or three clicks per call. Turn on Settings > Share > "Open the share window when the whiteboard slides in" and the window is already there when he reaches for the share button.
2. **L2, the second camera device (next).** It removes the window and the screen-recording permission from the path and works through each app's "share camera as content" button. It needs a change to the camera extension, which the Review 4 team owns tonight; the exact patch is in `docs/handoff/vp-too-small.md`. Owner test before building more: in Zoom, Share Screen > Advanced > Second camera > Switch Camera until "Daylight Camera" appears. If Zoom lists our existing camera there, the second device will appear too.
3. **L3, follow the pen (after L2).** This is the only lever that needs nothing per call and helps when nobody shares (2 to 9 people, where the tile is 360p or better). The Kit math with its hysteresis rules is built and tested (section 7); the compositor needs a canvas uv crop, scoped in the handoff.
4. Not recommended now: L8 (a permission for one saved click), L7 (asks viewers to act, still a camera stream), L9 to L11 (marketplace apps, one platform each, weeks of work and hosting).

## 7. Follow the pen: the numbers (built in DaylightKit, not yet wired)

`mac/DaylightKit/Sources/DaylightKit/Layout/FollowRegion.swift`, tests `FollowRegionTests` (kit-linux and mac). A camera over the ink canvas: the canvas point at the centre of the zone and a zoom in output pixels per canvas pixel. At rest it reproduces today's layouts exactly (full page, Studio Split paper 810 x 1080 at x 235).

| Id | Rule | Value |
|---|---|---|
| FP1 | maximum magnification over the full page | 2.5 |
| FP2 | margin around the active ink, fraction of the canvas width | 0.06 |
| FP3 | ink older than this no longer counts | 20 s |
| FP4 | move at once when active ink comes within this fraction of the visible width of an edge the camera can move past | 0.05 |
| FP5 | zoom in only when the region fits at this factor of the current zoom or more | 1.25 |
| FP6 | ...continuously for | 2.5 s |
| FP7 | no ink for this long returns to the full page | 30 s |
| FP8 | spring stiffness of the camera move (critically damped, settles in under a second) | 60 |
| FP9 | an ink box narrower than this fraction of the canvas width is widened to it | 0.10 |

Clear and a new page snap back to the full page; a layout change (Studio Split to Whiteboard Only) refits without animation. At the FP1 cap a 320 px tile shows the page detail at 337.5 px per page width instead of 135 px.

## 8. The share window: what was built

`mac/Daylight/Sources/Share/`: `ShareWindowController.swift`, `ShareCanvasRenderer.swift`, `ShareSettings.swift`, `ShareSettingsView.swift`, `ShareMenu.swift`, `ShareSelfTest.swift`; tests `mac/DaylightTests/Share/ShareTests.swift`.

- The window "Daylight Whiteboard" shows only the page: for the web whiteboard and Daylight Ink the two canvas layers composed exactly like the compositor's `daylight_canvas` shader (paper, highlighter multiplied under the ink, ink on top), for Mirror the cropped mirror picture. It reads the canvas directly, so it shows the page at 1200 x 1600 even when the camera pipeline is idle.
- SH1: it redraws at most 30 times a second and only when the canvas changed (the canvas seed or the mirror frame seed).
- SH2: it opens at 85 % of the screen's visible height at the canvas aspect (602 x 802 pt on a 1512 x 944 visible area), keeps the aspect when resized, and refits when a mirror session turns landscape.
- It never takes focus when it opens with the board, keeps `sharingType` `readOnly` so pickers list it, and keeps updating while covered (ScreenCaptureKit captures covered windows; minimising pauses the share [62]).
- Menu bar > "Share the whiteboard" > "Show share window" / "How to share it in a call..." / "Share settings...". Settings > Share: "Open the share window when the whiteboard slides in", "Keep the share window above other windows", "Hide the share window's title bar" (all off by default; a borderless window in every call app's picker is UNVERIFIED, so the title bar stays by default).
- `--self-test` prints `share:` and `follow:` probes (page size and aspect, ink, paper and highlighter pixels, the SH2 size, the follow full page).

## 9. The second camera device: scoped

Plan in `docs/handoff/vp-too-small.md` ("Patch proposal: second camera device"): three new UUIDs and Info.plist keys, a second `DeviceSource` in `ProviderSource`, a second `CMIOSinkClient` in `AppDelegate`, a whiteboard-only render in `FramePipeline` only while the share device has viewers, and the webcam exclusion of the share device. Blocked tonight only by ownership: the Review 4 team owns the extension and `Sources/Camera` until `docs/handoff/vp-review-4.md` says final.

## 10. What was not built, and why

- PostEvent automation of Command-Shift-S (L8): it saves one click, costs a permission prompt and breaks when Zoom changes a shortcut. Recorded in LOOSE_ENDS for a later decision.
- A "pin me" overlay (L7): asks every viewer to act and still delivers a camera stream.
- Platform apps (L9 to L11): marketplace review and hosting for one platform each.
- A global hotkey for the share window: needs a new `HotkeyAction` in the Kit settings schema (another team's file); requested in the handoff.

## 11. Citations

### 11a. Platforms

1. IONOS, How to see everyone on Zoom: https://www.ionos.com/digitalguide/online-marketing/online-sales/how-to-see-everyone-on-zoom/
2. Aurora University, Displaying 49 participants in Gallery View: https://itshelp.aurora.edu/hc/en-us/articles/34556695132567-Displaying-49-participants-in-Gallery-View
4. Zoom Developer blog, Video resolution with the Video SDK: https://developers.zoom.us/blog/video-resolution-with-the-video-sdk
5. Zoom Community, Group HD Video: https://community.zoom.com/t5/Meetings/Group-HD-Video/m-p/168380
7. Google Meet Help, Learn how to view people in Google Meet: https://support.google.com/meet/answer/9292748?hl=en
11. UNH, Teams Meetings: Changing your view: https://td.usnh.edu/TDClient/60/Portal/KB/ArticleDet?ID=5321
13. Microsoft Learn, Prepare your network for Teams: https://learn.microsoft.com/hi-in/microsoftteams/prepare-network
15. Slack Help, Use huddles in Slack: https://slack.com/help/articles/4402059015315
16. Slack Help, huddle window views and screen share: https://slack.com/help/articles/216771908
17. Macworld, How to make group FaceTime calls: https://www.macworld.com/article/234026/how-to-make-group-facetime-calls-on-the-iphone-ipad-or-mac.html
18. Apple FaceTime User Guide for Mac, View participants in a grid: https://support.apple.com/en-asia/guide/facetime/fctmb00128c4/5.0/mac
19. Webex Help, Change your video layout during a meeting: https://help.webex.com/en-us/article/n4f1ptt/Webex-App-%7C-Change-your-video-layout-during-a-meeting
20. Cisco, Understand Webex Meetings video resolution: https://www.cisco.com/c/en/us/support/docs/conferencing/webex-meetings/220244-understand-webex-meetings-video-resoluti.html
21. UIW, Change your view in Teams meetings: https://uiw.freshservice.com/support/solutions/articles/17000157266-change-your-view-in-microsoft-teams-meetings
22. LSU Health, Side-by-Side Mode for Screen Sharing: https://www.lsuhsc.edu/admin/it/helpdesk/zoom/tutorial-side-by-side.aspx
23. University of Miami, Zoom screen share presenter layouts: https://it.miami.edu/about-umit/it-news/collaboration/zoom-screen-share-presenter/index.html
24. Mitchell Hamline, Optimize screen share for video clip: https://mitchellhamline.edu/technology/knowledge-base/stream-a-video-clip-in-zoom
26. Webex Help, Optimize the resolution and frame rate of shared content: https://help.webex.com/en-us/article/nw9cjxab
27. Google Workspace Learning Center, Present high-quality video and audio in Meet: https://support.google.com/a/users/answer/12813816?hl=en
30. University of Missouri, Sharing content and a second camera in Zoom: https://tdx.umsystem.edu/TDClient/66/MOOnline/KB/ArticleDet?ID=224
31. Tufts, Share from a second camera in Zoom: https://tuftsedtech.screenstepslive.com/s/19028/m/94934/l/1219907-how-do-i-share-from-a-second-camera-or-mobile-device-in-zoom
34. OBS Forum, OBS to Zoom/Teams/Webex screen share for meetings: https://obsproject.com/forum/threads/obs-to-zoom-teams-webex-screen-share-for-meetings-not-streams.159997/
36. GVSU, Hot keys and keyboard shortcuts for Zoom: https://services.gvsu.edu/TDClient/60/Portal/KB/ArticleDet?ID=28136
37. NVCC, Zoom tech tip, a shortcut to share your screen: https://blogs.nvcc.edu/dailyflyer/2021/08/10/zoom-tech-tip-theres-a-shortcut-to-share-your-screen/index.html
38. ETSU, Zoom share portion of screen (PDF): https://www.etsu.edu/helpdesk/documents/zoom-share-portion-of-screen.pdf
41. UCL, Spotlight video: https://www.ucl.ac.uk/isd/how-to/spotlight-video
42. CCRI, Utilize Spotlight in Zoom: https://ccri.teamdynamix.com/TDClient/2073/Portal/KB/ArticleDet?ID=136242
44. Princeton Theological Seminary, Pinning participants: https://ptsem.teamdynamix.com/TDClient/72/Portal/KB/Article/1081/Pinning-Participants
46. npm, @zoom/appssdk 0.16.41 type definitions (read directly): https://www.npmjs.com/package/@zoom/appssdk
49. Google Workspace Updates, Present content from camera in Google Meet (June 2025): https://workspaceupdates.googleblog.com/2025/06/present-content-from-camera-in-google-meet.html
51. Google Workspace Updates, Pin multiple tiles for meeting participants (Feb 2024): https://workspaceupdates.googleblog.com/2024/02/pin-multiple-tiles-for-meeting-participants-google-meet.html
52. npm, @googleworkspace/meet-addons 1.2.0 type definitions (read directly): https://www.npmjs.com/package/@googleworkspace/meet-addons
53. Google Developers, Meet add-on activity starting state: https://developers.google.com/workspace/meet/add-ons/guides/activity-starting-state
56. Microsoft Support, Spotlight someone's video in Teams meetings: https://support.microsoft.com/en-gb/teams/meetings/spotlight-someone-s-video-in-microsoft-teams-meetings
57. M365 Admin, Pin your own video in Teams meetings: https://m365admin.handsontek.net/microsoft-teams-pin-your-own-video-in-teams-meetings/
58. Microsoft Support, Share whiteboards and documents using your camera in Teams meetings: https://support.microsoft.com/en-US/teams/meetings/share-whiteboards-and-documents-using-your-camera-in-microsoft-teams-meetings
59. npm, @microsoft/teams-js 2.57.0 type definitions (read directly): https://www.npmjs.com/package/@microsoft/teams-js
60. Microsoft Support, Roles in Teams meetings: https://support.microsoft.com/nl-nl/teams/meetings/roles-in-microsoft-teams-meetings
62. Apple WWDC22 10155, Take ScreenCaptureKit to the next level: https://developer.apple.com/videos/play/wwdc2022/10155/
63. Apple, SCContentFilter: https://developer.apple.com/documentation/screencapturekit/sccontentfilter

### 11b. macOS ("macOS research [n]" above)

1. CMIOExtensionProvider: https://developer.apple.com/documentation/coremediaio/cmioextensionprovider
2. WWDC22 10022, Create camera extensions with Core Media IO: https://developer.apple.com/videos/play/wwdc2022/10022/
3. CMIOExtensionDevice: https://developer.apple.com/documentation/coremediaio/cmioextensiondevice
12. SCContentSharingPicker: https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker
14. SCContentSharingPickerConfiguration: https://developer.apple.com/documentation/screencapturekit/sccontentsharingpickerconfiguration-swift.struct
15. SCContentSharingPickerObserver: https://developer.apple.com/documentation/screencapturekit/sccontentsharingpickerobserver
16. WWDC23 10136, What's new in ScreenCaptureKit: https://developer.apple.com/videos/play/wwdc2023/10136/
20. Apple Developer Forums, the macOS 15 "bypass the system private window picker" alert: https://developer.apple.com/forums/thread/765103
34. NSWindow.SharingType: https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum
36. Apple Developer Forums, Accessibility, PostEvent and ListenEvent: https://developer.apple.com/forums/thread/789896
37. CGRequestPostEventAccess: https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()
38. Apple Developer Forums, posting events and the sandbox: https://developer.apple.com/forums/thread/708652
41. Hardened Runtime: https://developer.apple.com/documentation/security/hardened-runtime
