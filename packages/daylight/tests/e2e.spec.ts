import { test, expect, type Page } from "@playwright/test";
import { WebSocket } from "ws";

const TOKEN = "e2e-token";

/** A stand-in for the Mac app: records lock modes it is told to apply. */
function fakeMac(port: number) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=${TOKEN}`);
  const modes: string[] = [];
  let latest: Record<string, unknown> | null = null;
  ws.on("message", (d) => {
    const m = JSON.parse(d.toString());
    if (m.type === "state") {
      latest = m.state;
      if (modes[modes.length - 1] !== m.state.lockMode) modes.push(m.state.lockMode);
    }
  });
  const opened = new Promise<void>((r) => ws.once("open", () => r()));
  return {
    modes,
    ready: opened.then(() => ws.send(JSON.stringify({ type: "hello", role: "mac", deviceId: "fake-mac", version: "e2e" }))),
    send: (m: unknown) => ws.send(JSON.stringify(m)),
    latest: () => latest,
    waitFor: async (mode: string, ms = 5000) => {
      const t0 = Date.now();
      while (Date.now() - t0 < ms) {
        if (latest && (latest as { lockMode: string }).lockMode === mode) return;
        await new Promise((r) => setTimeout(r, 50));
      }
      throw new Error(`Mac never saw lockMode=${mode}; saw ${modes.join(" → ")}`);
    },
    close: () => ws.close(),
  };
}

async function draw(page: Page, lines: number) {
  const canvas = page.locator("canvas.ink");
  const box = (await canvas.boundingBox())!;
  for (let i = 0; i < lines; i++) {
    const y = box.y + 60 + i * 50;
    await page.mouse.move(box.x + 40, y);
    await page.mouse.down();
    for (let x = 40; x < 400; x += 20) await page.mouse.move(box.x + x, y + Math.sin(x / 30) * 6);
    await page.mouse.up();
  }
}

test("the whole ritual: pair, plan by hand, unlock, check in, wrap up", async ({ page, baseURL }) => {
  const port = Number(new URL(baseURL!).port);
  const mac = fakeMac(port);
  await mac.ready;

  // Pairing via the QR link adopts the token and strips it from the URL.
  await page.goto(`/?token=${TOKEN}`);
  await expect(page.getByRole("heading", { name: "Your Mac is waiting." })).toBeVisible();
  expect(page.url()).not.toContain("token=");
  await mac.waitFor("shield");

  // Plan by hand.
  await page.getByRole("button", { name: "Plan & unlock the Mac" }).click();
  await expect(page.getByRole("heading", { name: "Plan by hand" })).toBeVisible();
  await expect(page.locator("canvas.ink")).toBeVisible();
  const done = page.getByRole("button", { name: "I'm done" });
  await expect(done).toBeDisabled();
  await draw(page, 3);
  await expect(done).toBeEnabled();
  await done.click();

  // Review: the mock brain "read" the ink.
  await expect(page.getByRole("heading", { name: "Here's what I read" })).toBeVisible();
  await expect(page.locator(".transcript")).toContainText("mock ink transcript");
  const intention = page.locator("input[placeholder='What is this session for?']");
  await expect(intention).toHaveValue(/handwritten intention/);
  await intention.fill("Ship the gate");
  await page.getByRole("button", { name: "Looks right, unlock my Mac" }).click();

  // Dashboard + Mac free.
  await expect(page.locator(".intention")).toHaveText("Ship the gate");
  await mac.waitFor("free");
  await expect(page.getByText(/next check-in/)).toBeVisible();

  // Check in now, typed (the keyboard fallback).
  await page.getByRole("button", { name: "Check in now" }).click();
  await mac.waitFor("shield");
  await expect(page.getByRole("heading", { name: "Where are you?" })).toBeVisible();
  await page.getByRole("button", { name: "Type instead" }).click();
  await page.locator("textarea").fill("where: half way\nhappened: engine works\nstuck: naming things\nnext: write the hub");
  await page.getByRole("button", { name: "I'm done" }).click();
  await expect(page.getByRole("heading", { name: "Noted." })).toBeVisible();
  await expect(page.locator(".coach")).toContainText("stuck on naming things");
  await page.getByRole("button", { name: "Back to work" }).click();
  await mac.waitFor("free");
  await expect(page.locator(".intention")).toHaveText("Ship the gate");
  await expect(page.getByText("stuck on: naming things")).toBeVisible();

  // Emergency unlock from the Mac shows up on the Daylight and in the session log.
  await page.getByRole("button", { name: "Done for now" }).click();
  await page.getByRole("button", { name: "Tap again to wrap up" }).click();
  await mac.waitFor("shield");
  await expect(page.getByRole("heading", { name: "Wrap up" })).toBeVisible();
  mac.send({ type: "emergency.unlock", reason: "Have to take an unplanned call now" });
  await mac.waitFor("free");

  // Wrap up by hand, then close.
  await draw(page, 2);
  await page.getByRole("button", { name: "I'm done" }).click();
  await expect(page.getByRole("heading", { name: "Session closed." })).toBeVisible();
  await expect(page.locator(".coach")).toContainText("Ship the gate");
  await page.getByRole("button", { name: "Close the day" }).click();
  await expect(page.getByRole("heading", { name: "Your Mac is waiting." })).toBeVisible();
  await expect(page.getByText(/Emergency unlock/)).toBeVisible();

  // History has the session with its ink pages.
  await page.getByRole("link", { name: "History" }).click();
  await expect(page.locator("details.hist summary")).toContainText("Ship the gate");
  await page.locator("details.hist summary").first().click();
  await expect(page.locator(".thumbs img").first()).toBeVisible();
  await expect
    .poll(() => page.locator(".thumbs img").first().evaluate((img: HTMLImageElement) => (img.complete ? img.naturalWidth : 0)), { timeout: 5000 })
    .toBeGreaterThan(100);

  // Settings round-trip.
  await page.getByRole("link", { name: "Settings" }).click();
  const interval = page.locator("input[type=number]").first();
  await interval.fill("45");
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.locator(".toast")).toHaveText("Saved.");
  await page.reload();
  await page.getByRole("link", { name: "Settings" }).click();
  await expect(page.locator("input[type=number]").first()).toHaveValue("45");

  // The emergency unlock is still running, so the Mac stays free after the day is closed.
  expect(mac.modes.join(" → ")).toBe("shield → free → shield → free → shield → free");
  mac.close();
});

test("planning with typed text asks a question when the intention is missing, then unlocks", async ({ page, baseURL }) => {
  const port = Number(new URL(baseURL!).port);
  const mac = fakeMac(port);
  await mac.ready;
  await page.goto(`/?token=${TOKEN}`);
  await page.getByRole("button", { name: "Plan & unlock the Mac" }).click();
  await page.getByRole("button", { name: "Type instead" }).click();
  await expect(page.getByRole("button", { name: "I'm done" })).toBeDisabled();
  await page.locator("textarea").fill("   ");
  await expect(page.getByRole("button", { name: "I'm done" })).toBeDisabled();

  // A page with only a priority: the coach asks what the session is for.
  await page.locator("textarea").fill("1. only a priority");
  await page.getByRole("button", { name: "I'm done" }).click();
  await expect(page.getByRole("heading", { name: "Here's what I read" })).toBeVisible();
  await expect(page.locator(".coach .q")).toHaveText("What is this session for?");
  await expect(page.getByRole("button", { name: "Answer by writing" })).toBeVisible();

  // Rewriting the page is allowed while reviewing, and Back returns to the review.
  await page.getByRole("button", { name: "Rewrite the page" }).click();
  await expect(page.getByRole("heading", { name: "Plan by hand" })).toBeVisible();
  await page.goBack();
  await expect(page.getByRole("heading", { name: "Here's what I read" })).toBeVisible();

  // Answer by typing.
  await page.locator("input[placeholder='…or type a short answer']").fill("make the demo work");
  await page.getByRole("button", { name: "Send", exact: true }).click();
  await expect(page.locator("input[placeholder='What is this session for?']")).toHaveValue("make the demo work");
  await expect(page.locator(".coach")).toContainText("make the demo work");
  await page.getByRole("button", { name: "Looks right, unlock my Mac" }).click();
  await mac.waitFor("free");

  // Clean up: end the session so the Mac is gated again.
  await page.getByRole("button", { name: "Done for now" }).click();
  await page.getByRole("button", { name: "Tap again to wrap up" }).click();
  await page.getByRole("button", { name: "Skip wrap-up" }).click();
  await expect(page.getByRole("heading", { name: "Your Mac is waiting." })).toBeVisible();
  mac.close();
});
