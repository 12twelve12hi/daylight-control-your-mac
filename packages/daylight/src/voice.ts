/**
 * Voice scaffold (client side).
 *
 * The server tells us which provider is configured and hands over short-lived
 * credentials. Each provider class below knows how to open the audio session.
 * Text stays the default; nothing here runs unless a key is configured.
 *
 * To finish a provider:
 *  - ElevenLabs Conversational AI: open the signed URL, send
 *    `conversation_initiation_client_data` with dynamic variables (the plan),
 *    stream 16 kHz PCM16 base64 chunks as `user_audio_chunk`, play back
 *    `audio` events, forward `user_transcript` to the server as
 *    `ink.submit { via: "voice", text }` so the plan stays in sync.
 *  - Gemini Live: open the WebSocket, send `setup` with the system prompt and
 *    tool declarations that mirror /api/voice/tools/*, stream
 *    `realtimeInput.audio` (PCM16 16 kHz), play `serverContent` audio parts.
 */
import type { Client } from "./ws.js";

export interface VoiceSessionInfo {
  provider: "text" | "elevenlabs" | "gemini-live";
  configured: boolean;
  url?: string;
  note?: string;
  context: { intention: string; priorities: string[]; todos: string[]; phase: string };
}

export interface VoiceSession {
  stop(): void;
}

export interface VoiceHandlers {
  onStatus(text: string): void;
  /** A final transcript of what the user said, to be merged into the plan. */
  onUserText(text: string): void;
  onAssistantText(text: string): void;
}

export async function startVoice(client: Client, h: VoiceHandlers): Promise<VoiceSession | null> {
  const info = await client.api<VoiceSessionInfo>("/api/voice/session");
  if (!info.configured || !info.url) {
    h.onStatus(info.note ?? "Voice is not configured.");
    return null;
  }
  const mic = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, sampleRate: 16000, echoCancellation: true } });
  const audioCtx = new AudioContext({ sampleRate: 16000 });
  const source = audioCtx.createMediaStreamSource(mic);
  const processor = audioCtx.createScriptProcessor(4096, 1, 1);
  const ws = new WebSocket(info.url);
  const playQueue: Float32Array<ArrayBuffer>[] = [];
  let playing = false;

  const playNext = () => {
    const chunk = playQueue.shift();
    if (!chunk) {
      playing = false;
      return;
    }
    playing = true;
    const buf = audioCtx.createBuffer(1, chunk.length, 16000);
    buf.copyToChannel(chunk, 0);
    const src = audioCtx.createBufferSource();
    src.buffer = buf;
    src.connect(audioCtx.destination);
    src.onended = playNext;
    src.start();
  };
  const enqueuePCM16 = (b64: string) => {
    const bin = atob(b64);
    const f = new Float32Array(bin.length / 2);
    for (let i = 0; i < f.length; i++) {
      const lo = bin.charCodeAt(i * 2);
      const hi = bin.charCodeAt(i * 2 + 1);
      const v = (hi << 8) | lo;
      f[i] = (v >= 0x8000 ? v - 0x10000 : v) / 0x8000;
    }
    playQueue.push(f);
    if (!playing) playNext();
  };

  const toPCM16B64 = (f: Float32Array<ArrayBufferLike>) => {
    const out = new Uint8Array(f.length * 2);
    for (let i = 0; i < f.length; i++) {
      const v = Math.max(-1, Math.min(1, f[i]!));
      const s = v < 0 ? v * 0x8000 : v * 0x7fff;
      out[i * 2] = s & 0xff;
      out[i * 2 + 1] = (s >> 8) & 0xff;
    }
    let bin = "";
    for (let i = 0; i < out.length; i += 0x8000) bin += String.fromCharCode(...out.subarray(i, i + 0x8000));
    return btoa(bin);
  };

  ws.onopen = () => {
    h.onStatus("Listening…");
    if (info.provider === "elevenlabs") {
      ws.send(
        JSON.stringify({
          type: "conversation_initiation_client_data",
          dynamic_variables: {
            intention: info.context.intention,
            priorities: info.context.priorities.join("; "),
            todos: info.context.todos.join("; "),
            phase: info.context.phase,
          },
        }),
      );
    } else if (info.provider === "gemini-live") {
      ws.send(
        JSON.stringify({
          setup: {
            model: "models/gemini-2.5-flash-native-audio-preview",
            generationConfig: { responseModalities: ["AUDIO"] },
            systemInstruction: {
              parts: [{ text: `You are the quiet coach inside Twelve. Current plan: ${JSON.stringify(info.context)}. Be brief and warm.` }],
            },
          },
        }),
      );
    }
    source.connect(processor);
    processor.connect(audioCtx.destination);
  };

  processor.onaudioprocess = (e) => {
    if (ws.readyState !== WebSocket.OPEN) return;
    const b64 = toPCM16B64(e.inputBuffer.getChannelData(0));
    if (info.provider === "elevenlabs") ws.send(JSON.stringify({ user_audio_chunk: b64 }));
    else if (info.provider === "gemini-live") ws.send(JSON.stringify({ realtimeInput: { audio: { data: b64, mimeType: "audio/pcm;rate=16000" } } }));
  };

  ws.onmessage = (ev) => {
    let m: Record<string, unknown>;
    try {
      m = JSON.parse(String(ev.data));
    } catch {
      return;
    }
    if (info.provider === "elevenlabs") {
      const type = m.type as string;
      if (type === "audio") {
        const ev2 = m.audio_event as { audio_base_64: string } | undefined;
        if (ev2?.audio_base_64) enqueuePCM16(ev2.audio_base_64);
      } else if (type === "user_transcript") {
        const t = (m.user_transcription_event as { user_transcript: string } | undefined)?.user_transcript;
        if (t) h.onUserText(t);
      } else if (type === "agent_response") {
        const t = (m.agent_response_event as { agent_response: string } | undefined)?.agent_response;
        if (t) h.onAssistantText(t);
      } else if (type === "ping") {
        const id = (m.ping_event as { event_id: number } | undefined)?.event_id;
        ws.send(JSON.stringify({ type: "pong", event_id: id }));
      }
    } else if (info.provider === "gemini-live") {
      const sc = m.serverContent as { modelTurn?: { parts?: { inlineData?: { data: string }; text?: string }[] } } | undefined;
      for (const part of sc?.modelTurn?.parts ?? []) {
        if (part.inlineData?.data) enqueuePCM16(part.inlineData.data);
        if (part.text) h.onAssistantText(part.text);
      }
    }
  };

  ws.onclose = () => h.onStatus("Voice ended.");
  ws.onerror = () => h.onStatus("Voice connection failed.");

  return {
    stop() {
      try {
        processor.disconnect();
        source.disconnect();
        mic.getTracks().forEach((t) => t.stop());
        void audioCtx.close();
        ws.close();
      } catch {
        /* ignore */
      }
    },
  };
}
