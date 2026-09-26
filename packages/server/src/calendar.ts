import { sync as icalSync, type CalendarResponse, type VEvent } from "node-ical";
import type { Config, Meeting } from "@twelve/protocol";

type CalConfig = Config["calendar"];

export interface CalendarProvider {
  /** Refresh from the source. Never throws; logs and keeps the last good data. */
  refresh(): Promise<void>;
  /** The meeting that is in progress at `now`, honouring pre/post roll. */
  currentMeeting(now?: Date): Meeting | null;
  /** The next meeting starting after `now`, for the dashboard. */
  nextMeeting(now?: Date): Meeting | null;
}

export interface CalEvent {
  title: string;
  start: Date;
  end: Date;
  attendees: string[];
  status: string;
  allDay: boolean;
}

function valOf(v: unknown): string {
  if (v == null) return "";
  if (typeof v === "string") return v;
  if (typeof v === "object" && "val" in (v as Record<string, unknown>)) return String((v as { val: unknown }).val ?? "");
  return String(v);
}

function attendeeList(a: unknown): string[] {
  if (!a) return [];
  const arr = Array.isArray(a) ? a : [a];
  return arr.map((x) => valOf(x).replace(/^mailto:/i, "").toLowerCase()).filter(Boolean);
}

/**
 * Expand a parsed ICS into concrete event instances that overlap [from, to].
 * Handles RRULE, EXDATE and RECURRENCE-ID overrides the way Google/Outlook emit them.
 */
export function expandEvents(data: CalendarResponse, from: Date, to: Date): CalEvent[] {
  const out: CalEvent[] = [];
  for (const comp of Object.values(data)) {
    if (!comp || (comp as { type?: string }).type !== "VEVENT") continue;
    const ev = comp as VEvent;
    const status = String(ev.status ?? "CONFIRMED").toUpperCase();
    if (status === "CANCELLED") continue;
    const title = valOf(ev.summary) || "(untitled)";
    const attendees = attendeeList(ev.attendee);
    const allDay = ev.datetype === "date" || Boolean((ev.start as { dateOnly?: boolean } | undefined)?.dateOnly);
    const start = ev.start instanceof Date ? ev.start : new Date(String(ev.start));
    const end = ev.end instanceof Date ? ev.end : new Date(start.getTime() + 30 * 60_000);
    const duration = Math.max(0, end.getTime() - start.getTime());

    if (!ev.rrule) {
      if (start <= to && end >= from) out.push({ title, start, end, attendees, status, allDay });
      continue;
    }

    // Recurring: expand instances inside the window (widen by the duration so
    // an instance that started before `from` but is still running is included).
    const exdates = new Set(
      Object.values(ev.exdate ?? {}).map((d) => (d instanceof Date ? d.getTime() : new Date(String(d)).getTime())),
    );
    const overrides = ev.recurrences ?? {};
    const overriddenKeys = new Set(Object.keys(overrides));
    let instances: Date[] = [];
    try {
      instances = ev.rrule.between(new Date(from.getTime() - duration), to, true);
    } catch (err) {
      console.warn("[calendar] rrule expansion failed for", title, err);
    }
    for (const inst of instances) {
      if (exdates.has(inst.getTime())) continue;
      const isoKey = inst.toISOString();
      const dayKey = isoKey.slice(0, 10);
      if (overriddenKeys.has(isoKey) || overriddenKeys.has(dayKey)) continue; // handled below
      out.push({ title, start: inst, end: new Date(inst.getTime() + duration), attendees, status, allDay });
    }
    for (const ov of Object.values(overrides)) {
      const o = ov as VEvent;
      if (String(o.status ?? "").toUpperCase() === "CANCELLED") continue;
      const os = o.start instanceof Date ? o.start : new Date(String(o.start));
      const oe = o.end instanceof Date ? o.end : new Date(os.getTime() + duration);
      if (os <= to && oe >= from) {
        out.push({
          title: valOf(o.summary) || title,
          start: os,
          end: oe,
          attendees: attendeeList(o.attendee).length ? attendeeList(o.attendee) : attendees,
          status: String(o.status ?? status),
          allDay,
        });
      }
    }
  }
  out.sort((a, b) => a.start.getTime() - b.start.getTime());
  return out;
}

export function isMeeting(ev: CalEvent, cfg: CalConfig): boolean {
  if (ev.allDay) return false;
  if (!cfg.requireAttendees) return true;
  const self = new Set(cfg.selfEmails.map((e) => e.toLowerCase()));
  return ev.attendees.some((a) => !self.has(a));
}

/** Pure selection logic, shared by the ICS provider and the tests. */
export function pickCurrent(events: CalEvent[], cfg: CalConfig, now: Date): Meeting | null {
  const pre = cfg.preRollMinutes * 60_000;
  const post = cfg.postRollMinutes * 60_000;
  const t = now.getTime();
  const live = events
    .filter((e) => isMeeting(e, cfg))
    .filter((e) => e.start.getTime() - pre <= t && e.end.getTime() + post > t)
    .sort((a, b) => b.end.getTime() - a.end.getTime()); // longest-running wins
  const m = live[0];
  return m
    ? { title: m.title, start: m.start.toISOString(), end: new Date(m.end.getTime() + post).toISOString(), source: "calendar" }
    : null;
}

export function pickNext(events: CalEvent[], cfg: CalConfig, now: Date): Meeting | null {
  const t = now.getTime();
  const m = events.filter((e) => isMeeting(e, cfg)).find((e) => e.start.getTime() > t);
  return m ? { title: m.title, start: m.start.toISOString(), end: m.end.toISOString(), source: "calendar" } : null;
}

export class IcsCalendar implements CalendarProvider {
  private events: CalEvent[] = [];
  private lastGood = 0;

  constructor(
    private readonly getConfig: () => CalConfig,
    private readonly fetchText: (url: string) => Promise<string> = defaultFetch,
    private readonly nowFn: () => Date = () => new Date(),
  ) {}

  async refresh(): Promise<void> {
    const cfg = this.getConfig();
    if (cfg.icsUrls.length === 0) {
      this.events = [];
      return;
    }
    const now = this.nowFn();
    const from = new Date(now.getTime() - 24 * 3600_000);
    const to = new Date(now.getTime() + 7 * 24 * 3600_000);
    const all: CalEvent[] = [];
    let ok = 0;
    for (const url of cfg.icsUrls) {
      try {
        const text = await this.fetchText(url);
        const data = icalSync.parseICS(text);
        all.push(...expandEvents(data, from, to));
        ok++;
      } catch (err) {
        console.warn("[calendar] failed to fetch", url.slice(0, 60) + "…", (err as Error).message);
      }
    }
    if (ok > 0) {
      this.events = all.sort((a, b) => a.start.getTime() - b.start.getTime());
      this.lastGood = Date.now();
    }
  }

  currentMeeting(now = new Date()): Meeting | null {
    return pickCurrent(this.events, this.getConfig(), now);
  }

  nextMeeting(now = new Date()): Meeting | null {
    return pickNext(this.events, this.getConfig(), now);
  }

  get lastRefreshedAt(): number {
    return this.lastGood;
  }
}

/** For tests and for a life without a calendar. */
export class StaticCalendar implements CalendarProvider {
  constructor(public events: CalEvent[] = [], private readonly cfg: () => CalConfig) {}
  async refresh() {}
  currentMeeting(now = new Date()) {
    return pickCurrent(this.events, this.cfg(), now);
  }
  nextMeeting(now = new Date()) {
    return pickNext(this.events, this.cfg(), now);
  }
}

async function defaultFetch(url: string): Promise<string> {
  const res = await fetch(url, { headers: { "user-agent": "twelve/0.1 (+calendar)" }, redirect: "follow" });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return await res.text();
}
