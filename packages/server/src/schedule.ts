import type { Config } from "@twelve/protocol";

type Schedule = Config["schedule"];

/** Local wall-clock parts of `now` in the schedule's timezone. */
function localParts(now: Date, timezone: string): { day: number; minutes: number } {
  const tz = timezone || undefined;
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  const parts = fmt.formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  const days: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  const hour = Number(get("hour")) % 24; // "24" can show up at midnight in some engines
  return { day: days[get("weekday")] ?? now.getDay(), minutes: hour * 60 + Number(get("minute")) };
}

function hm(s: string): number {
  const [h, m] = s.split(":").map(Number);
  return (h ?? 0) * 60 + (m ?? 0);
}

/** True when `now` falls inside the configured work-hours window. */
export function isWorkHours(schedule: Schedule, now = new Date()): boolean {
  const { day, minutes } = localParts(now, schedule.timezone);
  if (!schedule.days.includes(day)) return false;
  const start = hm(schedule.start);
  const end = hm(schedule.end);
  if (start <= end) return minutes >= start && minutes < end;
  // overnight window, e.g. 22:00–06:00
  return minutes >= start || minutes < end;
}

/** Milliseconds until the work-hours boolean can next change (checked at most every minute). */
export function msUntilNextBoundary(schedule: Schedule, now = new Date()): number {
  const current = isWorkHours(schedule, now);
  const step = 60_000;
  const t = new Date(now.getTime() - (now.getTime() % step) + step);
  for (let i = 0; i < 60 * 24 * 8; i++) {
    const probe = new Date(t.getTime() + i * step);
    if (isWorkHours(schedule, probe) !== current) return probe.getTime() - now.getTime();
  }
  return 24 * 3600 * 1000;
}
