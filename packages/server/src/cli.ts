#!/usr/bin/env node
import { startServer } from "./server.js";

const args = new Set(process.argv.slice(2));
if (args.has("--help") || args.has("-h")) {
  console.log(`twelve-server — the brain behind the gate

Usage: twelve-server [--mock] [--port N]

Environment:
  ANTHROPIC_API_KEY     Claude key for handwriting reading and coaching (or run \`ant auth login\`)
  TWELVE_BRAIN          "anthropic" (default) or "mock" (offline, for trying the flow)
  TWELVE_HOME           data dir, default ~/.twelve
  TWELVE_PORT           default 7712
  TWELVE_HOST           default 0.0.0.0 (all interfaces, so the Daylight can reach it)
  ELEVENLABS_API_KEY    enables the ElevenLabs voice scaffold (with config.voice.elevenlabsAgentId)
  GEMINI_API_KEY        enables the Gemini Live voice scaffold
`);
  process.exit(0);
}
if (args.has("--mock")) process.env.TWELVE_BRAIN = "mock";
const portArg = process.argv.indexOf("--port");
if (portArg > -1 && process.argv[portArg + 1]) process.env.TWELVE_PORT = process.argv[portArg + 1];

const server = await startServer();
const shutdown = async () => {
  await server.close();
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
