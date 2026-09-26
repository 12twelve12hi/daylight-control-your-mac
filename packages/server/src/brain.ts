import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import * as z4 from "zod/v4";
import { BrainOutputSchema, type BrainOutput, type InkPurpose, type Plan, type Turn } from "@twelve/protocol";

/**
 * The SDK's structured-output helper wants a zod v4 schema, while the shared
 * protocol package is written against zod v3 (it needs `.deepPartial()`).
 * This mirrors `BrainOutputSchema`; the result is re-validated with the
 * protocol schema before it leaves the brain, so the two cannot drift silently.
 */
const BrainOutputV4 = z4.object({
  transcript: z4.string().describe("Faithful transcription of the handwriting or typed text"),
  plan: z4
    .object({
      intention: z4.string(),
      priorities: z4.array(z4.string()),
      todos: z4.array(z4.string()),
    })
    .nullable()
    .describe("Present for plan/reply purposes, else null"),
  checkin: z4
    .object({ where: z4.string(), happened: z4.string(), stuck: z4.string(), next: z4.string() })
    .nullable()
    .describe("Present for checkin purpose, else null"),
  wrapup: z4.object({ done: z4.string(), next: z4.string() }).nullable().describe("Present for wrapup purpose, else null"),
  questions: z4.array(z4.string()).describe("Short clarifying questions, at most the allowed number"),
  message: z4.string().describe("What the coach says back, 1-3 sentences"),
  complete: z4.boolean().describe("plan/reply: intention and at least one priority were read"),
  confidence: z4.number().describe("0-1 legibility estimate"),
});

export interface BrainInput {
  purpose: InkPurpose;
  /** base64 PNG of the handwritten page */
  png?: string;
  /** typed text or a voice transcript, used instead of (or in addition to) the ink */
  text?: string;
  plan: Plan | null;
  /** Recent turns of this session, oldest first. */
  history: Turn[];
  /** How many clarifying questions the gate still allows. 0 = do not ask. */
  questionsLeft: number;
  now: Date;
}

export interface Brain {
  readonly name: string;
  read(input: BrainInput): Promise<BrainOutput>;
}

// ---------------------------------------------------------------------------
// System prompt (stable text so it caches; everything volatile goes in the user turn)
// ---------------------------------------------------------------------------

export const SYSTEM_PROMPT = `You are the quiet coach inside Twelve, a tool that gates a person's Mac behind a handwritten plan on their Daylight tablet. You read photos of handwriting and help the person keep their real goal in view. Many users have ADHD. Your job is to make the pen-and-paper step feel light and useful, never like a test.

You receive a page of handwriting (a PNG) and/or typed text, plus the current plan and recent conversation. Return the structured object exactly as specified.

Rules:
- Transcribe the handwriting as faithfully as you can, keeping the person's own words, line breaks as newlines. Do not "improve" it. If a word is unreadable write [?] in its place.
- For purpose "plan": extract ONE intention (what this session is for, in the person's words), up to three priorities, and any to-dos. Headings on the page (Intention / Priorities / To-do) are a template; the person may ignore them. If the page has a list but no clear intention, the first priority is NOT automatically the intention. "complete" is true only when you can read an intention and at least one priority.
- For purpose "reply": the person is answering your earlier question(s). Merge the answer into the plan you were given and return the whole updated plan. Set "complete" by the same rule.
- For purpose "checkin": fill where / happened / stuck / next from the page. Missing parts stay empty strings. Then in "message" (2–3 sentences): name where they are relative to the intention, and if they are stuck, offer exactly one concrete first step that takes under ten minutes. Never scold, never mention time lost, never say "you should have".
- For purpose "wrapup": fill done / next. In "message" write a three-line summary of the session for tomorrow-morning-them: what moved, what is next, one thing to remember.
- Questions: ask only when something needed is missing or unreadable, and only as many as "questions allowed" permits (it may be zero, then ask none). Each question is one short sentence a person can answer with one handwritten line. Prefer "What is today for?" over "Can you clarify your intention?".
- Tone: warm, plain, brief, specific. No exclamation marks. No praise about the person; comment on the work if anything. One suggestion at most. Never use the words "productivity", "should", or "focus" as a noun.
- "confidence" is your 0–1 estimate of how legible the page was.
- Do not invent content that is not on the page or in the text. Empty page = empty transcript, complete=false, and a single gentle question if allowed.`;

// ---------------------------------------------------------------------------
// Anthropic (Claude) brain — vision + structured output
// ---------------------------------------------------------------------------

export class AnthropicBrain implements Brain {
  readonly name = "anthropic";
  private client: Anthropic;

  constructor(private readonly model = "claude-opus-5", client?: Anthropic) {
    // The SDK resolves ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN / `ant auth login` profiles itself.
    this.client = client ?? new Anthropic({ maxRetries: 2, timeout: 120_000 });
  }

  async read(input: BrainInput): Promise<BrainOutput> {
    const content: Anthropic.ContentBlockParam[] = [];
    if (input.png) {
      content.push({ type: "image", source: { type: "base64", media_type: "image/png", data: input.png } });
    }
    content.push({ type: "text", text: buildUserText(input) });

    const response = await this.client.messages.parse({
      model: this.model,
      max_tokens: 4096,
      system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
      output_config: { effort: "medium", format: zodOutputFormat(BrainOutputV4) },
      messages: [{ role: "user", content }],
    });

    if (response.stop_reason === "refusal") {
      const why = response.stop_details?.explanation ?? "the model declined";
      return fallbackOutput(`I could not read this page (${why}). Try again, or type it instead.`);
    }
    if (!response.parsed_output) {
      return fallbackOutput("I could not make sense of that page. Try again, or type it instead.");
    }
    const checked = BrainOutputSchema.safeParse(response.parsed_output);
    if (!checked.success) {
      console.warn("[brain] model output failed validation:", checked.error.issues);
      return fallbackOutput("I could not make sense of that page. Try again, or type it instead.");
    }
    const out = checked.data;
    // The server enforces the question budget regardless of what the model did.
    out.questions = out.questions.slice(0, Math.max(0, input.questionsLeft));
    return out;
  }
}

export function buildUserText(input: BrainInput): string {
  const lines: string[] = [];
  lines.push(`purpose: ${input.purpose}`);
  lines.push(`questions allowed: ${input.questionsLeft}`);
  lines.push(`local time: ${input.now.toLocaleString("en-US", { hour: "2-digit", minute: "2-digit", weekday: "short" })}`);
  if (input.plan) {
    lines.push("current plan:");
    lines.push(JSON.stringify(
      {
        intention: input.plan.intention,
        priorities: input.plan.priorities,
        todos: input.plan.todos.map((t) => (t.done ? "[x] " : "[ ] ") + t.text),
      },
      null,
      1,
    ));
  } else {
    lines.push("current plan: none yet");
  }
  const recent = input.history.slice(-6);
  if (recent.length) {
    lines.push("recent conversation:");
    for (const t of recent) {
      lines.push(`${t.role === "user" ? "person" : "coach"}: ${t.text}${t.questions?.length ? " | questions: " + t.questions.join(" / ") : ""}`);
    }
  }
  if (input.png) lines.push("The image above is the handwritten page.");
  if (input.text) lines.push(`typed or spoken text from the person:\n${input.text}`);
  if (!input.png && !input.text) lines.push("(nothing was written)");
  return lines.join("\n");
}

function fallbackOutput(message: string): BrainOutput {
  return {
    transcript: "",
    plan: null,
    checkin: null,
    wrapup: null,
    questions: [],
    message,
    complete: false,
    confidence: 0,
  };
}

// ---------------------------------------------------------------------------
// Mock brain — deterministic, offline. Parses typed text with simple rules;
// treats a bare ink page as a readable plan so the whole flow can be exercised.
// ---------------------------------------------------------------------------

export class MockBrain implements Brain {
  readonly name = "mock";

  async read(input: BrainInput): Promise<BrainOutput> {
    const text = (input.text ?? "").trim();
    if (!text && !input.png) {
      return {
        ...fallbackOutput("The page is empty. What is this session for?"),
        questions: input.questionsLeft > 0 ? ["What is this session for?"] : [],
      };
    }
    if (input.purpose === "checkin") return mockCheckin(text, input);
    if (input.purpose === "wrapup") return mockWrapup(text, input);
    return mockPlan(text, input);
  }
}

function mockPlan(text: string, input: BrainInput): BrainOutput {
  const base: Plan = input.plan ?? { intention: "", priorities: [], todos: [] };
  let intention = base.intention;
  const priorities = [...base.priorities];
  const todos = base.todos.map((t) => t.text);

  if (!text && input.png) {
    // Ink-only in mock mode: pretend we read a small, valid plan.
    const kb = Math.round((input.png.length * 3) / 4 / 1024);
    intention = intention || `(mock) handwritten intention, ${kb} KB of ink`;
    if (priorities.length === 0) priorities.push("(mock) first handwritten priority");
  } else {
    for (const raw of text.split(/\r?\n/)) {
      const line = raw.trim();
      if (!line) continue;
      const m = /^(intention|intent|i)\s*[:\-–]\s*(.+)$/i.exec(line);
      if (m) {
        intention = m[2]!.trim();
        continue;
      }
      const p = /^(priority|priorities|p|\d+[.)])\s*[:\-–]?\s*(.+)$/i.exec(line);
      if (p) {
        priorities.push(p[2]!.trim());
        continue;
      }
      const t = /^(todo|to-do|-|\*|•)\s*[:\-–]?\s*(.+)$/i.exec(line);
      if (t) {
        todos.push(t[2]!.trim());
        continue;
      }
      // A reply to "what is this for?" with a bare line becomes the intention.
      if (input.purpose === "reply" && !intention) {
        intention = line;
        continue;
      }
      if (!intention) intention = line;
      else priorities.push(line);
    }
  }

  const complete = Boolean(intention) && priorities.length > 0;
  const questions: string[] = [];
  if (!complete && input.questionsLeft > 0) {
    questions.push(!intention ? "What is this session for?" : "What is the one thing that matters most today?");
  }
  const message = complete
    ? `Got it. Today is for "${intention}". First up: ${priorities[0]}.`
    : questions[0] ?? "I could not find both an intention and a priority, but let's go.";
  return {
    transcript: text || "(mock ink transcript)",
    plan: { intention, priorities: priorities.slice(0, 3), todos },
    checkin: null,
    wrapup: null,
    questions,
    message,
    complete,
    confidence: text ? 1 : 0.6,
  };
}

function mockCheckin(text: string, input: BrainInput): BrainOutput {
  const fields = { where: "", happened: "", stuck: "", next: "" };
  const order: (keyof typeof fields)[] = ["where", "happened", "stuck", "next"];
  let i = 0;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    const m = /^(where|happened|stuck|next)\s*[:\-–]\s*(.*)$/i.exec(line);
    if (m) {
      fields[m[1]!.toLowerCase() as keyof typeof fields] = m[2]!.trim();
    } else if (i < order.length) {
      fields[order[i]!] = line;
      i++;
    }
  }
  if (!text && input.png) {
    fields.where = "(mock) somewhere in priority one";
    fields.next = "(mock) the next small step";
  }
  const intention = input.plan?.intention || "your intention";
  const message = fields.stuck
    ? `You're at "${fields.where || "…"}" on the way to "${intention}". Since you're stuck on ${fields.stuck}: open the file and write one sentence about what "done" looks like, then stop.`
    : `You're at "${fields.where || "…"}" on the way to "${intention}". Next: ${fields.next || "pick the smallest next step"}.`;
  return {
    transcript: text || "(mock ink transcript)",
    plan: null,
    checkin: fields,
    wrapup: null,
    questions: [],
    message,
    complete: true,
    confidence: text ? 1 : 0.6,
  };
}

function mockWrapup(text: string, input: BrainInput): BrainOutput {
  let done = "";
  let next = "";
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    const m = /^(done|next)\s*[:\-–]\s*(.*)$/i.exec(line);
    if (m) {
      if (m[1]!.toLowerCase() === "done") done = m[2]!.trim();
      else next = m[2]!.trim();
    } else if (!done) done = line;
    else if (!next) next = line;
  }
  if (!text && input.png) {
    done = "(mock) moved priority one forward";
    next = "(mock) continue tomorrow";
  }
  const intention = input.plan?.intention || "the intention";
  return {
    transcript: text || "(mock ink transcript)",
    plan: null,
    checkin: null,
    wrapup: { done, next },
    questions: [],
    message: `Moved: ${done || "—"}.\nNext: ${next || "—"}.\nRemember: the session was for "${intention}".`,
    complete: true,
    confidence: text ? 1 : 0.6,
  };
}

export function createBrain(provider: "anthropic" | "mock", model: string): Brain {
  if (provider === "mock") return new MockBrain();
  return new AnthropicBrain(model);
}
