import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { ConfigSchema, type Config, type PublicConfig } from "@twelve/protocol";

export function dataDir(): string {
  return process.env.TWELVE_HOME || path.join(os.homedir(), ".twelve");
}

export function configPath(): string {
  return path.join(dataDir(), "config.json");
}

function deepMerge<T extends Record<string, unknown>>(base: T, patch: Record<string, unknown>): T {
  const out: Record<string, unknown> = { ...base };
  for (const [k, v] of Object.entries(patch)) {
    if (v === undefined) continue;
    const cur = out[k];
    if (v && typeof v === "object" && !Array.isArray(v) && cur && typeof cur === "object" && !Array.isArray(cur)) {
      out[k] = deepMerge(cur as Record<string, unknown>, v as Record<string, unknown>);
    } else {
      out[k] = v;
    }
  }
  return out as T;
}

export class ConfigStore {
  private cfg: Config;

  constructor(private readonly file = configPath()) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    let raw: unknown = {};
    if (fs.existsSync(file)) {
      try {
        raw = JSON.parse(fs.readFileSync(file, "utf8"));
      } catch (err) {
        console.warn(`[config] ${file} is not valid JSON, starting from defaults:`, err);
      }
    }
    const parsed = ConfigSchema.safeParse(raw);
    this.cfg = parsed.success ? parsed.data : ConfigSchema.parse({});
    if (!parsed.success) console.warn("[config] invalid config, using defaults:", parsed.error.issues);
    if (!this.cfg.pairing.token) {
      this.cfg.pairing.token = crypto.randomBytes(16).toString("hex");
    }
    // Environment overrides (never persisted): handy for tests and for the launchd plist.
    if (process.env.TWELVE_BRAIN === "mock" || process.env.TWELVE_BRAIN === "anthropic") {
      this.cfg.brain.provider = process.env.TWELVE_BRAIN;
    }
    this.save();
  }

  get(): Config {
    return this.cfg;
  }

  public(): PublicConfig {
    const { pairing: _p, ...rest } = this.cfg;
    return rest;
  }

  update(patch: Record<string, unknown>): Config {
    const merged = deepMerge(this.cfg as unknown as Record<string, unknown>, patch);
    const parsed = ConfigSchema.safeParse(merged);
    if (!parsed.success) {
      throw new Error("invalid config: " + parsed.error.issues.map((i) => i.path.join(".") + " " + i.message).join("; "));
    }
    // pairing token is never client-editable
    parsed.data.pairing.token = this.cfg.pairing.token;
    this.cfg = parsed.data;
    this.save();
    return this.cfg;
  }

  private save() {
    const tmp = this.file + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(this.cfg, null, 2));
    fs.renameSync(tmp, this.file);
  }
}
