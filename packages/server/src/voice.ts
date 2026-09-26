/**
 * Voice scaffold.
 *
 * Text is the default conversation channel. When a key is present, the
 * Daylight app can open a live voice conversation with the coach instead.
 * The server's only job is to hand the client short-lived credentials and to
 * expose tool webhooks the voice agent can call to change the session
 * (see server.ts → /api/voice/tools/*).
 *
 * Nothing here is exercised by tests; treat each provider as a documented
 * starting point and check the vendor docs for the current endpoint shapes.
 */
import type { Config, Plan } from "@twelve/protocol";

export type VoiceKind = Config["voice"]["provider"];

export interface VoiceSessionInfo {
  provider: VoiceKind;
  /** ElevenLabs: signed WebSocket URL. Gemini Live: WebSocket URL with an ephemeral token. */
  url?: string;
  /** Extra data the client should send in its first message (e.g. dynamic variables). */
  context: {
    intention: string;
    priorities: string[];
    todos: string[];
    phase: string;
  };
  /** Human-readable hint shown in the Daylight UI when not configured. */
  note?: string;
}

export interface VoiceProvider {
  readonly kind: VoiceKind;
  configured(): boolean;
  sessionCredentials(ctx: { plan: Plan | null; phase: string }): Promise<VoiceSessionInfo>;
}

function contextOf(plan: Plan | null, phase: string): VoiceSessionInfo["context"] {
  return {
    intention: plan?.intention ?? "",
    priorities: plan?.priorities ?? [],
    todos: plan?.todos.map((t) => t.text) ?? [],
    phase,
  };
}

/** Default: no audio. The Daylight app uses its typed reply box. */
export class TextOnlyVoice implements VoiceProvider {
  readonly kind = "text" as const;
  configured() {
    return true;
  }
  async sessionCredentials(ctx: { plan: Plan | null; phase: string }): Promise<VoiceSessionInfo> {
    return { provider: "text", context: contextOf(ctx.plan, ctx.phase), note: "Voice is off. Set ELEVENLABS_API_KEY or GEMINI_API_KEY to enable it." };
  }
}

/**
 * ElevenLabs Conversational AI.
 * Needs: ELEVENLABS_API_KEY (env) and config.voice.elevenlabsAgentId (an agent
 * you create in the ElevenLabs dashboard, with the Twelve system prompt and the
 * tool webhooks pointed at this server).
 * Flow: server → GET /v1/convai/conversation/get-signed-url → client opens the
 * returned wss:// URL and streams microphone PCM per the ElevenLabs protocol.
 */
export class ElevenLabsVoice implements VoiceProvider {
  readonly kind = "elevenlabs" as const;
  constructor(private readonly agentId: () => string, private readonly apiKey = () => process.env.ELEVENLABS_API_KEY ?? "") {}
  configured() {
    return Boolean(this.apiKey() && this.agentId());
  }
  async sessionCredentials(ctx: { plan: Plan | null; phase: string }): Promise<VoiceSessionInfo> {
    const context = contextOf(ctx.plan, ctx.phase);
    if (!this.configured()) return { provider: "elevenlabs", context, note: "Set ELEVENLABS_API_KEY and voice.elevenlabsAgentId." };
    const url = `https://api.elevenlabs.io/v1/convai/conversation/get-signed-url?agent_id=${encodeURIComponent(this.agentId())}`;
    const res = await fetch(url, { headers: { "xi-api-key": this.apiKey() } });
    if (!res.ok) throw new Error(`ElevenLabs signed URL failed: HTTP ${res.status}`);
    const body = (await res.json()) as { signed_url?: string };
    if (!body.signed_url) throw new Error("ElevenLabs response had no signed_url");
    return { provider: "elevenlabs", url: body.signed_url, context };
  }
}

/**
 * Gemini Live (bidirectional audio over WebSocket).
 * Needs: GEMINI_API_KEY (env). The server mints a single-use ephemeral token so
 * the API key never reaches the tablet; the client connects to the Live
 * endpoint with `access_token=<token>`.
 */
export class GeminiLiveVoice implements VoiceProvider {
  readonly kind = "gemini-live" as const;
  constructor(private readonly model: () => string, private readonly apiKey = () => process.env.GEMINI_API_KEY ?? "") {}
  configured() {
    return Boolean(this.apiKey());
  }
  async sessionCredentials(ctx: { plan: Plan | null; phase: string }): Promise<VoiceSessionInfo> {
    const context = contextOf(ctx.plan, ctx.phase);
    if (!this.configured()) return { provider: "gemini-live", context, note: "Set GEMINI_API_KEY." };
    const expire = new Date(Date.now() + 30 * 60_000).toISOString();
    const newSessionExpire = new Date(Date.now() + 2 * 60_000).toISOString();
    const res = await fetch(`https://generativelanguage.googleapis.com/v1alpha/auth_tokens?key=${encodeURIComponent(this.apiKey())}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        uses: 1,
        expireTime: expire,
        newSessionExpireTime: newSessionExpire,
        bidiGenerateContentSetup: {
          model: `models/${this.model()}`,
          generationConfig: { responseModalities: ["AUDIO"] },
        },
      }),
    });
    if (!res.ok) throw new Error(`Gemini ephemeral token failed: HTTP ${res.status}`);
    const body = (await res.json()) as { name?: string };
    if (!body.name) throw new Error("Gemini token response had no name");
    const url = `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?access_token=${encodeURIComponent(body.name)}`;
    return { provider: "gemini-live", url, context };
  }
}

export function createVoice(getConfig: () => Config): VoiceProvider {
  const kind = getConfig().voice.provider;
  if (kind === "elevenlabs") return new ElevenLabsVoice(() => getConfig().voice.elevenlabsAgentId);
  if (kind === "gemini-live") return new GeminiLiveVoice(() => getConfig().voice.geminiModel);
  return new TextOnlyVoice();
}
