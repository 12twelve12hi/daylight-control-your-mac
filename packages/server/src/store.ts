import fs from "node:fs";
import path from "node:path";
import { SessionSchema, type Session, type Event } from "@twelve/protocol";
import { dataDir } from "./config.js";

/**
 * JSON-file store. One file per session, one PNG per ink page, one day log
 * for events that happen outside a session (e.g. an emergency unlock at 8am).
 * Deliberately boring: you can read your own journal with `cat`.
 */
export class Store {
  readonly root: string;

  constructor(root = dataDir()) {
    this.root = root;
    for (const d of ["sessions", "ink", "daylog"]) fs.mkdirSync(path.join(root, d), { recursive: true });
  }

  // -- sessions -------------------------------------------------------------

  private sessionFile(id: string) {
    return path.join(this.root, "sessions", `${id}.json`);
  }

  saveSession(s: Session) {
    const f = this.sessionFile(s.id);
    const tmp = f + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(s, null, 2));
    fs.renameSync(tmp, f);
  }

  loadSession(id: string): Session | null {
    const f = this.sessionFile(id);
    if (!fs.existsSync(f)) return null;
    const r = SessionSchema.safeParse(JSON.parse(fs.readFileSync(f, "utf8")));
    return r.success ? r.data : null;
  }

  listSessions(limit = 30): Session[] {
    const dir = path.join(this.root, "sessions");
    const files = fs
      .readdirSync(dir)
      .filter((f) => f.endsWith(".json"))
      .sort()
      .reverse()
      .slice(0, limit);
    const out: Session[] = [];
    for (const f of files) {
      try {
        const r = SessionSchema.safeParse(JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")));
        if (r.success) out.push(r.data);
      } catch {
        /* skip corrupt file */
      }
    }
    return out;
  }

  /** The most recent session that has not ended (used to resume after a restart). */
  findOpenSession(): Session | null {
    return this.listSessions(5).find((s) => !s.endedAt) ?? null;
  }

  // -- ink ------------------------------------------------------------------

  saveInk(sessionId: string, pngBase64: string): string {
    const dir = path.join(this.root, "ink", sessionId);
    fs.mkdirSync(dir, { recursive: true });
    const n = fs.readdirSync(dir).filter((f) => f.endsWith(".png")).length + 1;
    const rel = path.join(sessionId, `${String(n).padStart(3, "0")}.png`);
    fs.writeFileSync(path.join(this.root, "ink", rel), Buffer.from(pngBase64, "base64"));
    return rel;
  }

  inkPath(rel: string): string | null {
    const p = path.normalize(path.join(this.root, "ink", rel));
    if (!p.startsWith(path.join(this.root, "ink"))) return null;
    return fs.existsSync(p) ? p : null;
  }

  // -- day log --------------------------------------------------------------

  private dayFile(date = new Date()) {
    return path.join(this.root, "daylog", `${date.toISOString().slice(0, 10)}.json`);
  }

  appendDayEvent(ev: Event) {
    const f = this.dayFile(new Date(ev.at));
    let arr: Event[] = [];
    if (fs.existsSync(f)) {
      try {
        arr = JSON.parse(fs.readFileSync(f, "utf8"));
      } catch {
        arr = [];
      }
    }
    arr.push(ev);
    fs.writeFileSync(f, JSON.stringify(arr, null, 2));
  }

  dayEvents(date = new Date()): Event[] {
    const f = this.dayFile(date);
    if (!fs.existsSync(f)) return [];
    try {
      return JSON.parse(fs.readFileSync(f, "utf8"));
    } catch {
      return [];
    }
  }
}
