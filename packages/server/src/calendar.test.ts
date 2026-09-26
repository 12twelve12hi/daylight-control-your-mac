import { test } from "node:test";
import assert from "node:assert/strict";
import { sync as icalSync } from "node-ical";
import { ConfigSchema } from "@twelve/protocol";
import { expandEvents, pickCurrent, pickNext, IcsCalendar } from "./calendar.js";

const ICS = `BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Google Inc//Google Calendar 70.9054//EN
BEGIN:VEVENT
DTSTART:20260928T140000Z
DTEND:20260928T143000Z
UID:standup@example.com
SUMMARY:Daily standup
STATUS:CONFIRMED
ORGANIZER;CN=Me:mailto:me@example.com
ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;CN=Me:mailto:me@example.com
ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;CN=Bob:mailto:bob@example.com
RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR
EXDATE:20260930T140000Z
END:VEVENT
BEGIN:VEVENT
DTSTART:20260929T160000Z
DTEND:20260929T170000Z
UID:solo@example.com
SUMMARY:Deep work block
STATUS:CONFIRMED
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20260929
DTEND;VALUE=DATE:20260930
UID:allday@example.com
SUMMARY:Conference
ATTENDEE:mailto:someone@example.com
END:VEVENT
BEGIN:VEVENT
DTSTART:20260929T100000Z
DTEND:20260929T103000Z
UID:cancelled@example.com
SUMMARY:Cancelled thing
STATUS:CANCELLED
ATTENDEE:mailto:x@example.com
END:VEVENT
END:VCALENDAR
`;

const cfg = ConfigSchema.parse({ calendar: { selfEmails: ["me@example.com"] } }).calendar;

test("expands weekly recurrence, honours EXDATE, skips cancelled", () => {
  const data = icalSync.parseICS(ICS);
  const from = new Date("2026-09-28T00:00:00Z");
  const to = new Date("2026-10-03T00:00:00Z");
  const events = expandEvents(data, from, to);
  const standups = events.filter((e) => e.title === "Daily standup").map((e) => e.start.toISOString().slice(0, 10));
  assert.deepEqual(standups, ["2026-09-28", "2026-09-29", "2026-10-01", "2026-10-02"]); // 09-30 excluded
  assert.ok(!events.some((e) => e.title === "Cancelled thing"));
  assert.ok(events.some((e) => e.title === "Conference" && e.allDay));
});

test("pickCurrent applies pre/post roll, attendee rule and all-day exclusion", () => {
  const data = icalSync.parseICS(ICS);
  const events = expandEvents(data, new Date("2026-09-28T00:00:00Z"), new Date("2026-10-03T00:00:00Z"));

  assert.equal(pickCurrent(events, cfg, new Date("2026-09-28T13:57:00Z")), null, "before pre-roll");
  assert.equal(pickCurrent(events, cfg, new Date("2026-09-28T13:58:30Z"))?.title, "Daily standup", "inside pre-roll");
  assert.equal(pickCurrent(events, cfg, new Date("2026-09-28T14:31:00Z"))?.title, "Daily standup", "inside post-roll");
  assert.equal(pickCurrent(events, cfg, new Date("2026-09-28T14:33:00Z")), null, "after post-roll");

  // Solo block has no attendees → not a meeting when requireAttendees is on…
  assert.equal(pickCurrent(events, cfg, new Date("2026-09-29T16:10:00Z")), null);
  // …but counts when it is off.
  assert.equal(pickCurrent(events, { ...cfg, requireAttendees: false }, new Date("2026-09-29T16:10:00Z"))?.title, "Deep work block");
  // All-day never counts.
  assert.equal(pickCurrent(events, { ...cfg, requireAttendees: false }, new Date("2026-09-29T03:00:00Z")), null);

  assert.equal(pickNext(events, cfg, new Date("2026-09-28T15:00:00Z"))?.start, "2026-09-29T14:00:00.000Z");
});

test("IcsCalendar keeps the last good data when a fetch fails", async () => {
  let fail = false;
  const cal = new IcsCalendar(
    () => ({ ...cfg, icsUrls: ["https://example.invalid/cal.ics"] }),
    async () => {
      if (fail) throw new Error("boom");
      return ICS;
    },
    () => new Date("2026-09-28T13:00:00Z"),
  );
  await cal.refresh();
  assert.equal(cal.currentMeeting(new Date("2026-09-28T14:05:00Z"))?.title, "Daily standup");
  fail = true;
  await cal.refresh();
  assert.equal(cal.currentMeeting(new Date("2026-09-28T14:05:00Z"))?.title, "Daily standup");
});
