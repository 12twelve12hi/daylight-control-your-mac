# Handoff files

One file per component, written by that component's agent and read by the integrator. Nobody else edits these files, and the components never edit the documents the integrator folds them into.

## The rule

| Component | File |
|---|---|
| A, DaylightKit | `docs/handoff/A-daylightkit.md` |
| B, Daylight app core | `docs/handoff/B-app.md` |
| C, camera extension and host sink | `docs/handoff/C-camera.md` |
| D, web whiteboard | `docs/handoff/D-web.md` |
| E, Android app and overlay | `docs/handoff/E-android.md` |
| F, mirror mode | `docs/handoff/F-mirror.md` |

Each component owns exactly one file here. It holds, under these headings:

1. **Owner-facing text** the integrator folds into `docs/SETUP.md`, `docs/SIGNING.md`, `docs/COMPARE.md`, `docs/TESTING-CHECKLIST.md` and `docs/PERFORMANCE.md` at M6. Every user-facing document ends with the ADHD-friendly checklist (atomic steps, time estimates, emoji anchors), so write the checklist rows for your component here.
2. **Device facts and CI facts** the component logs or learned (the exact log line or the CI run id), for `docs/LOOSE_ENDS.md` sections B to E and ARCHITECTURE section 18.
3. **UNVERIFIED items** the component shipped behind a runtime fallback (IMPLEMENTATION-PLAN section 2 rule 8), one line each: the fact, the fallback, how the owner confirms it.
4. **Requests for the integrator**: anything outside the component's own paths (a plist key, an entitlement, a make target, a CI step, a contract member, a golden vector, a `Package.swift` resource). State the exact change; keep working with a local stub until it lands.
5. **Red CI runs caused by someone else's files**: the run id and the job, nothing more (IMPLEMENTATION-PLAN section 2 rule 5).

Writing rules apply here too: no em-dashes; LivePaper is a transflective LCD (never "MIP"); the backlight is DC dimming (never "PWM"); VRR is 45 to 90 Hz (never 120 Hz); model names never appear in the repository except in commit trailers.

The integrator reads these files at every merge (IMPLEMENTATION-PLAN section 12) and deletes nothing from them; resolved requests are marked "Applied in <commit>" by the integrator.
