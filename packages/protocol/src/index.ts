/**
 * @twelve/protocol — the contract between the server (brain), the Daylight
 * PWA, the Mac gate app, and any voice agent webhook.
 *
 * Everything is JSON. Zod schemas are the source of truth; the TypeScript
 * types are inferred from them. Swift and Kotlin mirror the subsets they need
 * (see apps/mac and apps/android).
 */
import { z } from "zod";

export const PROTOCOL_VERSION = 1;
export const DEFAULT_PORT = 7712;

// ---------------------------------------------------------------------------
// Domain model
// ---------------------------------------------------------------------------

export const TodoSchema = z.object({
  id: z.string(),
  text: z.string(),
  done: z.boolean().default(false),
});
export type Todo = z.infer<typeof TodoSchema>;

export const PlanSchema = z.object({
  intention: z.string().default(""),
  priorities: z.array(z.string()).default([]),
  todos: z.array(TodoSchema).default([]),
  notes: z.string().optional(),
});
export type Plan = z.infer<typeof PlanSchema>;

export const CheckinSchema = z.object({
  at: z.string(),
  where: z.string().default(""),
  happened: z.string().default(""),
  stuck: z.string().optional(),
  next: z.string().default(""),
  aiReply: z.string().default(""),
  inkFile: z.string().optional(),
});
export type Checkin = z.infer<typeof CheckinSchema>;

export const WrapupSchema = z.object({
  done: z.string().default(""),
  next: z.string().default(""),
  summary: z.string().default(""),
  inkFile: z.string().optional(),
});
export type Wrapup = z.infer<typeof WrapupSchema>;

export const TurnSchema = z.object({
  at: z.string(),
  role: z.enum(["user", "assistant"]),
  text: z.string(),
  /** How the user turn arrived. */
  via: z.enum(["ink", "text", "voice"]).optional(),
  inkFile: z.string().optional(),
  questions: z.array(z.string()).optional(),
});
export type Turn = z.infer<typeof TurnSchema>;

export const EventKindSchema = z.enum([
  "emergency_unlock",
  "meeting_pass",
  "calendar_meeting_start",
  "calendar_meeting_end",
  "snooze",
  "auto_end",
  "arm",
  "disarm",
  "checkin_warn",
  "checkin_lock",
  "mac_foreground",
]);
export type EventKind = z.infer<typeof EventKindSchema>;

export const EventSchema = z.object({
  at: z.string(),
  kind: EventKindSchema,
  detail: z.string().optional(),
});
export type Event = z.infer<typeof EventSchema>;

export const SessionSchema = z.object({
  id: z.string(),
  startedAt: z.string(),
  endedAt: z.string().optional(),
  plan: PlanSchema,
  transcript: z.array(TurnSchema).default([]),
  checkins: z.array(CheckinSchema).default([]),
  events: z.array(EventSchema).default([]),
  wrapup: WrapupSchema.optional(),
  questionsAsked: z.number().int().default(0),
  snoozeUsedForCurrentCheckin: z.boolean().default(false),
});
export type Session = z.infer<typeof SessionSchema>;

// ---------------------------------------------------------------------------
// Config (subset that is safe to send to clients is derived below)
// ---------------------------------------------------------------------------

export const ScheduleSchema = z.object({
  /** 0 = Sunday … 6 = Saturday */
  days: z.array(z.number().int().min(0).max(6)).default([1, 2, 3, 4, 5]),
  /** "HH:MM" local time */
  start: z.string().regex(/^\d{2}:\d{2}$/).default("08:00"),
  end: z.string().regex(/^\d{2}:\d{2}$/).default("18:00"),
  /** IANA zone; empty = server's local zone */
  timezone: z.string().default(""),
});

export const ConfigSchema = z.object({
  schedule: ScheduleSchema.default({}),
  checkin: z
    .object({
      intervalMinutes: z.number().int().min(5).default(60),
      warningSeconds: z.number().int().min(10).default(120),
      snoozeMinutes: z.number().int().min(1).default(15),
    })
    .default({}),
  gate: z
    .object({
      maxQuestions: z.number().int().min(0).default(2),
    })
    .default({}),
  allowlist: z
    .object({
      /** macOS bundle identifiers usable in allowlist mode (meetings). */
      bundleIds: z
        .array(z.string())
        .default(["us.zoom.xos", "com.apple.iCal", "com.apple.finder", "com.apple.FaceTime"]),
    })
    .default({}),
  calendar: z
    .object({
      icsUrls: z.array(z.string()).default([]),
      pollMinutes: z.number().int().min(1).default(5),
      preRollMinutes: z.number().int().min(0).default(2),
      postRollMinutes: z.number().int().min(0).default(2),
      /** Only events with at least one other attendee count as meetings. */
      requireAttendees: z.boolean().default(true),
      /** Your own e-mail addresses, so "attendees other than you" can be computed. */
      selfEmails: z.array(z.string()).default([]),
    })
    .default({}),
  meetingPass: z
    .object({
      manualMinutes: z.number().int().min(5).default(60),
      manualPerDay: z.number().int().min(0).default(1),
    })
    .default({}),
  emergency: z
    .object({
      holdSeconds: z.number().int().min(1).default(30),
      unlockMinutes: z.number().int().min(1).default(30),
      minReasonChars: z.number().int().min(0).default(10),
    })
    .default({}),
  session: z
    .object({
      maxHours: z.number().min(0.5).default(8),
    })
    .default({}),
  brain: z
    .object({
      provider: z.enum(["anthropic", "mock"]).default("anthropic"),
      model: z.string().default("claude-opus-5"),
    })
    .default({}),
  voice: z
    .object({
      provider: z.enum(["text", "elevenlabs", "gemini-live"]).default("text"),
      elevenlabsAgentId: z.string().default(""),
      geminiModel: z.string().default("gemini-2.5-flash-native-audio-preview"),
    })
    .default({}),
  pairing: z
    .object({
      token: z.string().default(""),
    })
    .default({}),
});
export type Config = z.infer<typeof ConfigSchema>;

/** The part of config clients may see and (for the Daylight) edit. */
export const PublicConfigSchema = ConfigSchema.omit({ pairing: true });
export type PublicConfig = z.infer<typeof PublicConfigSchema>;

// ---------------------------------------------------------------------------
// Live state
// ---------------------------------------------------------------------------

export const PhaseSchema = z.enum([
  "idle",
  "planning",
  "reviewing",
  "working",
  "checkin_warn",
  "checkin",
  "wrapup",
]);
export type Phase = z.infer<typeof PhaseSchema>;

export const LockModeSchema = z.enum(["shield", "allowlist", "free"]);
export type LockMode = z.infer<typeof LockModeSchema>;

export const MeetingSchema = z.object({
  title: z.string(),
  start: z.string(),
  end: z.string(),
  source: z.enum(["calendar", "manual"]),
});
export type Meeting = z.infer<typeof MeetingSchema>;

export const ShieldSchema = z.object({
  title: z.string(),
  body: z.string(),
});

export const BannerSchema = z.object({
  text: z.string(),
  /** Unix ms when the countdown ends. Clients compute the remaining time locally. */
  endsAt: z.number(),
  canSnooze: z.boolean(),
});

export const StateSnapshotSchema = z.object({
  protocolVersion: z.literal(PROTOCOL_VERSION),
  now: z.number(),
  /** true when the schedule says work hours, or the gate was armed manually. */
  gateActive: z.boolean(),
  armedManually: z.boolean(),
  phase: PhaseSchema,
  lockMode: LockModeSchema,
  shield: ShieldSchema.nullable(),
  banner: BannerSchema.nullable(),
  allowlist: z.array(z.string()),
  meeting: MeetingSchema.nullable(),
  emergencyUntil: z.number().nullable(),
  /** Unix ms of the next check-in warning while working, else null. */
  nextCheckinAt: z.number().nullable(),
  /** Unix ms at which the current check-in warning locks the Mac. */
  checkinLocksAt: z.number().nullable(),
  session: SessionSchema.nullable(),
  aiBusy: z.boolean(),
  clients: z.object({ mac: z.boolean(), daylight: z.boolean() }),
  config: PublicConfigSchema,
  /** Latest assistant turn to show on the Daylight (mirrors transcript tail). */
  lastAssistant: TurnSchema.nullable(),
  manualPassesLeftToday: z.number().int(),
});
export type StateSnapshot = z.infer<typeof StateSnapshotSchema>;

// ---------------------------------------------------------------------------
// Ink
// ---------------------------------------------------------------------------

export const StrokePointSchema = z.object({
  x: z.number(),
  y: z.number(),
  p: z.number().min(0).max(1).default(0.5),
  t: z.number().default(0),
});
export const StrokeSchema = z.object({
  points: z.array(StrokePointSchema),
  width: z.number().default(2.5),
  color: z.string().default("#111111"),
  eraser: z.boolean().default(false),
});
export type Stroke = z.infer<typeof StrokeSchema>;

export const InkPurposeSchema = z.enum(["plan", "reply", "checkin", "wrapup"]);
export type InkPurpose = z.infer<typeof InkPurposeSchema>;

// ---------------------------------------------------------------------------
// Messages: client → server
// ---------------------------------------------------------------------------

export const ClientRoleSchema = z.enum(["mac", "daylight", "voice"]);
export type ClientRole = z.infer<typeof ClientRoleSchema>;

export const ClientMessageSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("hello"),
    role: ClientRoleSchema,
    deviceId: z.string(),
    version: z.string().default("0"),
  }),
  z.object({ type: z.literal("plan.start") }),
  z.object({
    type: z.literal("ink.submit"),
    purpose: InkPurposeSchema,
    /** base64 PNG (no data: prefix) */
    png: z.string().optional(),
    strokes: z.array(StrokeSchema).optional(),
    /** Keyboard fallback, or a voice transcript. */
    text: z.string().optional(),
    via: z.enum(["ink", "text", "voice"]).optional(),
  }),
  z.object({ type: z.literal("plan.confirm"), plan: PlanSchema.optional() }),
  z.object({ type: z.literal("plan.edit"), plan: PlanSchema }),
  z.object({ type: z.literal("todo.toggle"), id: z.string(), done: z.boolean() }),
  z.object({ type: z.literal("checkin.now") }),
  z.object({ type: z.literal("checkin.snooze") }),
  z.object({ type: z.literal("checkin.back") }),
  z.object({ type: z.literal("session.end") }),
  z.object({ type: z.literal("wrapup.close") }),
  z.object({ type: z.literal("gate.arm") }),
  z.object({ type: z.literal("gate.disarm") }),
  z.object({ type: z.literal("meeting.pass"), minutes: z.number().int().min(5).max(240).optional() }),
  z.object({ type: z.literal("emergency.unlock"), reason: z.string() }),
  z.object({ type: z.literal("mac.foreground"), bundleId: z.string(), name: z.string().optional() }),
  z.object({ type: z.literal("config.update"), config: PublicConfigSchema.deepPartial() }),
  z.object({ type: z.literal("ping") }),
]);
export type ClientMessage = z.infer<typeof ClientMessageSchema>;

// ---------------------------------------------------------------------------
// Messages: server → client
// ---------------------------------------------------------------------------

export const ServerMessageSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("state"), state: StateSnapshotSchema }),
  z.object({
    type: z.literal("ai.message"),
    text: z.string(),
    questions: z.array(z.string()).default([]),
    purpose: InkPurposeSchema.optional(),
  }),
  z.object({
    type: z.literal("ai.busy"),
    busy: z.boolean(),
    what: z.enum(["reading", "thinking"]).optional(),
  }),
  z.object({ type: z.literal("error"), code: z.string(), message: z.string() }),
  z.object({ type: z.literal("pong"), now: z.number() }),
]);
export type ServerMessage = z.infer<typeof ServerMessageSchema>;

// ---------------------------------------------------------------------------
// Brain (AI) I/O — what the model must return for every read/coach call
// ---------------------------------------------------------------------------

export const BrainCheckinSchema = z.object({
  where: z.string(),
  happened: z.string(),
  stuck: z.string(),
  next: z.string(),
});

export const BrainOutputSchema = z.object({
  /** Verbatim-as-possible transcription of the handwriting (or the typed text). */
  transcript: z.string(),
  /** Present when the input describes a plan or edits one. */
  plan: z
    .object({
      intention: z.string(),
      priorities: z.array(z.string()),
      todos: z.array(z.string()),
    })
    .nullable(),
  checkin: BrainCheckinSchema.nullable(),
  wrapup: z.object({ done: z.string(), next: z.string() }).nullable(),
  /** Short clarifying questions. Empty when nothing is needed. */
  questions: z.array(z.string()),
  /** What the coach says back. 1–3 sentences. */
  message: z.string(),
  /** For plan purposes: intention + ≥1 priority are present. */
  complete: z.boolean(),
  /** 0–1: how legible the ink was. */
  confidence: z.number(),
});
export type BrainOutput = z.infer<typeof BrainOutputSchema>;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

export function parseClientMessage(raw: unknown): ClientMessage | null {
  const r = ClientMessageSchema.safeParse(raw);
  return r.success ? r.data : null;
}

export function parseServerMessage(raw: unknown): ServerMessage | null {
  const r = ServerMessageSchema.safeParse(raw);
  return r.success ? r.data : null;
}

export function defaultConfig(): Config {
  return ConfigSchema.parse({});
}
