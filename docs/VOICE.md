# Voice

Text is the default conversation channel: the Daylight app shows the coach's
words and you answer by writing or typing. The voice path is scaffolded so
that dropping in a key turns it on, but it has **not** been exercised against
the live services. Expect to adjust message shapes to the vendors' current
docs.

## How the pieces fit

```
Daylight (browser)                      Mac server                      Vendor
  Talk instead ──GET /api/voice/session──▶ VoiceProvider.sessionCredentials ─▶ mint signed URL / ephemeral token
  ◀── { provider, url, context } ─────────┘
  open WebSocket(url), stream mic PCM16 16 kHz ────────────────────────────▶ voice agent
  ◀── audio chunks, transcripts ───────────────────────────────────────────┘
  user transcript ──ink.submit { via: "voice", text }──▶ same brain as ink   (plan stays in sync)
                                            ◀── POST /api/voice/tools/* ────  agent tool webhooks
```

Server side: `packages/server/src/voice.ts` (`TextOnlyVoice`,
`ElevenLabsVoice`, `GeminiLiveVoice`). Client side:
`packages/daylight/src/voice.ts` (`startVoice`).

## ElevenLabs Conversational AI

1. Create an agent in the ElevenLabs dashboard. System prompt: the text of
   `SYSTEM_PROMPT` in `packages/server/src/brain.ts`, minus the structured
   output rules. Add dynamic variables `intention`, `priorities`, `todos`,
   `phase` (the client sends them on connect).
2. Add agent tools as webhooks pointing at the Mac (reachable via Tailscale
   Funnel or a tunnel), each with the pairing token as a bearer header:
   `POST /api/voice/tools/update_plan` `{intention?, priorities?, todos?}`,
   `confirm_plan`, `submit_checkin` `{where, happened, stuck, next}`,
   `back_to_work`, `end_session`, `get_plan`.
3. On the Mac: `ELEVENLABS_API_KEY=…` in `~/.twelve/env`; in config
   `voice.provider = "elevenlabs"`, `voice.elevenlabsAgentId = "<id>"`.
4. The server fetches a signed conversation URL per session; the client opens
   it and streams `user_audio_chunk`, plays `audio` events, forwards
   `user_transcript` into the plan.

## Gemini Live

1. `GEMINI_API_KEY=…` in `~/.twelve/env`; `voice.provider = "gemini-live"`;
   `voice.geminiModel` (default `gemini-2.5-flash-native-audio-preview`).
2. The server mints a single-use ephemeral token (`v1alpha/auth_tokens`) so the
   API key never reaches the tablet. The client opens the Live WebSocket with
   `access_token=<token>`, sends `setup` with the plan as system instruction,
   streams `realtimeInput.audio`, plays `serverContent` audio parts.
3. Tool calling from Gemini to `/api/voice/tools/*` is not wired: add
   `tools` to the `setup` message and handle `toolCall` messages by calling
   the same endpoints from the client.

## Browser note

`getUserMedia` needs a secure context. Plain `http://192.168…` counts as
insecure in Chrome, so serve the app over HTTPS for voice: `tailscale serve
--https=443 7712` on the Mac gives you a trusted `https://<mac>.<tailnet>.ts.net`
URL that works on the DC-1 with Tailscale installed.
