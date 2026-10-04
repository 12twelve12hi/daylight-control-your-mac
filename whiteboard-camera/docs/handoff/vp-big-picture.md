# Phase 4: the big picture across the VPs

One section per VP; each VP keeps its own section current and leaves the others alone. Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

## Too small (making the whiteboard big in a group call)

- Question: in a call with many people the camera tile is small (and fed as little as 180p), so the drawing is unreadable; can the screen-share size be used instead?
- Answer: only the content track (screen, window, or "share a camera as content") is big for everyone; no app can start a share inside another app's call, so one or two clicks per call is the floor. `docs/product/TOO-SMALL.md` has the research, the 13 levers and the ranking.
- Built: the "Daylight Whiteboard" share window (menu bar > "Share the whiteboard", Settings > Share; works in Zoom, Meet, Teams, Slack, Webex, on the unsigned build too) and the follow-the-pen camera math in DaylightKit (`FollowRegion`, not wired).
- Next, in order: a second camera device "Daylight Whiteboard (share)" for Zoom "Second camera", Meet "Present content from camera" and Teams "Content from camera" (patch proposal in `vp-too-small.md`, waiting on the camera owner); then follow the pen in the camera tile.
- Owner: `docs/OWNER-NEXT-STEPS.md` step 8c. Open items: `docs/LOOSE_ENDS.md` TS-1 to TS-7.
