import { defineConfig } from "@playwright/test";

// Portrait DC-1 viewport, touch enabled so finger input is distinguishable from the pen (CDP pen events
// in tests). The web server is the fake Mac (tests/fake-mac.mjs): static dist, /api/info, /healthz and
// a SolStream WebSocket on /ink with a scripted Allow handshake and STATE pushes.
export default defineConfig({
  testDir: "./tests",
  testMatch: /.*\.spec\.ts/,
  timeout: 60_000,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : [["list"]],
  use: {
    headless: true,
    browserName: "chromium",
    viewport: { width: 1200, height: 1600 },
    hasTouch: true,
    isMobile: true,
    deviceScaleFactor: 1,
    baseURL: "http://127.0.0.1:4173/",
  },
  webServer: {
    command: "node tests/fake-mac.mjs 4173",
    url: "http://127.0.0.1:4173/healthz",
    reuseExistingServer: false,
    timeout: 60_000,
  },
});
