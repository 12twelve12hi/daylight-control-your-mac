# Calendar → meeting mode

While the Mac is shielded and your calendar says a meeting is in progress,
the shield lifts into **meeting mode**: only the apps in
`allowlist.bundleIds` stay usable (every other app is hidden as soon as it
comes to the front), a small HUD in the corner shows the meeting title, and
check-ins are paused until the meeting ends plus a five-minute landing.

No OAuth is needed. Twelve polls ICS feeds, which both Google Calendar and
Outlook publish.

## Google Calendar

1. calendar.google.com → Settings → the calendar → **Integrate calendar**.
2. Copy **Secret address in iCal format** (`https://calendar.google.com/calendar/ical/…/private-…/basic.ics`).
3. Daylight → Settings → Meetings → paste into *Calendar ICS links*.
4. Add your Google address under *Your e-mail addresses*. Save.

## Outlook / Microsoft 365

1. outlook.office.com → Settings → Calendar → **Shared calendars** → *Publish a calendar*.
2. Choose the calendar, permission *Can view all details*, click Publish, copy the **ICS** link.
3. Paste and save as above.

## What counts as a meeting

An event is a meeting when all of these hold:

- it is not an all-day event;
- it is not cancelled;
- it overlaps now, with `preRollMinutes` before the start and `postRollMinutes` after the end (2 and 2 by default);
- unless `requireAttendees` is false, at least one attendee is not you (`selfEmails`).

Recurring events (RRULE), exceptions (EXDATE) and moved instances
(RECURRENCE-ID) are expanded the way Google and Outlook emit them. Feeds are
polled every `pollMinutes` (5); a failed fetch keeps the last good data.

## Bundle identifiers for the allowlist

```sh
osascript -e 'id of app "zoom.us"'      # us.zoom.xos
osascript -e 'id of app "Calendar"'     # com.apple.iCal
osascript -e 'id of app "Slack"'        # com.tinyspeck.slackmacgap
osascript -e 'id of app "Google Chrome"' # com.google.Chrome  (allows all of Chrome, not just Meet)
```

## Manual meeting pass

For a meeting that is not on the calendar, the Daylight home screen has
**Meeting pass** (60 minutes, once a day by default, logged). Prefer the
calendar; the pass is the fallback.
