import { defineConfig } from "@playwright/test";

// Portrait DC-1 viewport, touch enabled so finger input is distinguishable from the pen (CDP pen events in tests).
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
    command: "npm run preview",
    url: "http://127.0.0.1:4173/",
    reuseExistingServer: false,
    timeout: 60_000,
  },
});
