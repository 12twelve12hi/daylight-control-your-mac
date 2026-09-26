// Starts the Twelve server with the mock brain, a fixed pairing token, a 24/7
// schedule and a short check-in interval, serving the built Daylight app.
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const port = process.argv[2] ?? "7799";
const home = fs.mkdtempSync(path.join(os.tmpdir(), "twelve-e2e-"));
fs.writeFileSync(
  path.join(home, "config.json"),
  JSON.stringify({
    pairing: { token: "e2e-token" },
    schedule: { days: [0, 1, 2, 3, 4, 5, 6], start: "00:00", end: "23:59", timezone: "UTC" },
    checkin: { intervalMinutes: 5, warningSeconds: 10, snoozeMinutes: 1 },
    brain: { provider: "mock" },
  }),
);
const child = spawn("node", ["--import", "tsx", path.join(here, "../../server/src/cli.ts"), "--mock", "--port", port], {
  cwd: path.join(here, "../../server"),
  env: { ...process.env, TWELVE_HOME: home, TWELVE_HOST: "127.0.0.1", TWELVE_STATIC_DIR: path.join(here, "../dist") },
  stdio: "inherit",
});
child.on("exit", (code) => process.exit(code ?? 0));
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => child.kill("SIGTERM"));
