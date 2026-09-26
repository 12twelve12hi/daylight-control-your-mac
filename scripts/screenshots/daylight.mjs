// Captures every state of the Daylight app at DC-1 resolution (1600×1200)
// against a real server running the mock brain. Output: docs/screenshots/.
//
//   npm run build && node scripts/screenshots/daylight.mjs
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "@playwright/test";
import { WebSocket } from "ws";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const out = path.join(root, "docs/screenshots");
fs.mkdirSync(out, { recursive: true });

const { startServer, ConfigStore, Store, MockBrain, StaticCalendar } = await import(path.join(root, "packages/server/dist/index.js"));

const home = fs.mkdtempSync(path.join(os.tmpdir(), "twelve-shots-"));
const configStore = new ConfigStore(path.join(home, "config.json"));
configStore.update({
  schedule: { days: [0, 1, 2, 3, 4, 5, 6], start: "00:00", end: "23:59", timezone: "UTC" },
  calendar: { icsUrls: [], selfEmails: ["me@example.com"] },
});
const TOKEN = configStore.get().pairing.token;
const calendar = new StaticCalendar([], () => configStore.get().calendar);
const server = await startServer({
  port: 0,
  host: "127.0.0.1",
  configStore,
  store: new Store(home),
  brain: new MockBrain(),
  calendar,
  staticDir: path.join(root, "packages/daylight/dist"),
  quiet: true,
});
const base = `http://127.0.0.1:${server.port}`;
const engine = server.engine;

// A stand-in Mac so the top bar does not say "Mac app not connected".
const mac = new WebSocket(`${base.replace("http", "ws")}/ws?token=${TOKEN}`);
await new Promise((r) => mac.once("open", r));
mac.send(JSON.stringify({ type: "hello", role: "mac", deviceId: "shots", version: "0" }));

const browser = await chromium.launch(process.env.PLAYWRIGHT_CHROMIUM ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM } : {});
const page = await browser.newPage({ viewport: { width: 1600, height: 1200 }, deviceScaleFactor: 1 });
const shot = (name) => page.screenshot({ path: path.join(out, `${name}.png`) });
const failShot = async (err) => {
  const fail = path.join(os.tmpdir(), "twelve-shots-failure.png");
  try { await page.screenshot({ path: fail }); } catch {}
  console.error("capture failed:", err?.message ?? err, "\nlast page state saved to", fail);
  await browser.close();
  mac.close();
  await server.close();
  process.exit(1);
};
try {
const settle = (ms = 300) => page.waitForTimeout(ms);

async function scribble(y, len, amp = 9) {
  const box = await page.locator("canvas.ink").boundingBox();
  await page.mouse.move(box.x + 40, box.y + y);
  await page.mouse.down();
  for (let x = 40; x < len; x += 8) await page.mouse.move(box.x + x, box.y + y + Math.sin(x / 14) * amp);
  await page.mouse.up();
}

// 01 pairing page (served on the Mac itself)
await page.goto(`${base}/pair`);
await settle();
await shot("01-pairing-page");

// 02 home, gated
await page.goto(`${base}/?token=${TOKEN}`);
await page.getByRole("heading", { name: "Your Mac is waiting." }).waitFor();
await shot("02-home-gated");

// 03 plan by hand
await page.getByRole("button", { name: "Plan & unlock the Mac" }).click();
await page.locator("canvas.ink").waitFor();
const h = (await page.locator("canvas.ink").boundingBox()).height;
await scribble(h * 0.06 + 70, 720);
await scribble(h * 0.36 + 70, 520);
await scribble(h * 0.36 + 128, 440);
await scribble(h * 0.36 + 186, 380);
await scribble(h * 0.68 + 70, 400);
await scribble(h * 0.68 + 128, 300);
await shot("03-plan-by-hand");

// 04 review after the coach read the page
await page.getByRole("button", { name: "I'm done" }).click();
await page.getByRole("heading", { name: "Here's what I read" }).waitFor();
await page.locator("input[placeholder='What is this session for?']").fill("Get the grant draft to a state I can send to Priya");
await page.locator("input[placeholder='Priority 1']").fill("Write the two missing sections");
await page.locator("input[placeholder='Priority 2']").fill("Reconcile the budget table");
await page.locator("input[placeholder='Priority 3']").fill("Reply to the three review comments");
await page.getByRole("button", { name: "+ Add a to-do" }).click();
await page.locator("input[placeholder='To-do']").last().fill("Book dentist");
await page.getByRole("button", { name: "+ Add a to-do" }).click();
await page.locator("input[placeholder='To-do']").last().fill("Send Sam the calendar link");
await settle();
await shot("04-review");

// 05 the coach asks a question (a fresh session, typed plan with no intention)
await page.getByRole("button", { name: "Rewrite the page" }).click();
await page.getByRole("button", { name: "Cancel" }).click();
await page.getByRole("button", { name: "Tap again to cancel" }).click();
await page.getByRole("heading", { name: "Your Mac is waiting." }).waitFor();
await page.getByRole("button", { name: "Plan & unlock the Mac" }).click();
await page.getByRole("button", { name: "Type instead" }).click();
await page.locator("textarea").fill("1. finish the grant sections\n2. budget table\n- book dentist");
await page.getByRole("button", { name: "I'm done" }).click();
await page.locator(".coach .q").waitFor();
await settle();
await shot("05-review-question");
await page.locator("input[placeholder='…or type a short answer']").fill("Get the grant draft to a state I can send to Priya");
await page.getByRole("button", { name: "Send", exact: true }).click();
await page.locator("input[placeholder='What is this session for?']").waitFor();
await page.waitForFunction(() => document.querySelector("input[placeholder='What is this session for?']")?.value.includes("Priya"));
await page.locator("input[placeholder='Priority 3']").fill("Reply to the three review comments");

// 06 dashboard
await page.getByRole("button", { name: "Looks right, unlock my Mac" }).click();
await page.locator(".intention").waitFor();
await page.locator("label.todo input").first().check();
await settle();
await shot("06-dashboard-working");

// 07 check-in warning (two-minute countdown before the shield)
engine.startCheckinWarning();
await page.locator(".banner").waitFor();
await settle(600);
await shot("07-checkin-warning");
engine.snooze();
await page.locator(".banner").waitFor({ state: "detached" });

// 08 check-in page
await page.getByRole("button", { name: "Check in now" }).click();
await page.getByRole("heading", { name: "Where are you?" }).waitFor();
await scribble(h * 0.06 + 70, 560);
await scribble(h * 0.3 + 70, 640);
await scribble(h * 0.54 + 70, 300);
await scribble(h * 0.78 + 70, 420);
await shot("08-checkin-write");

// 09 check-in reply
await page.getByRole("button", { name: "Type instead" }).click();
await page.locator("textarea").fill("where: section 2 is drafted, section 3 half\nhappened: the budget table has a mismatch I can't explain\nstuck: the mismatch\nnext: find the row that changed");
await page.getByRole("button", { name: "I'm done" }).click();
await page.getByRole("heading", { name: "Noted." }).waitFor();
await settle();
await shot("09-checkin-reply");
await page.getByRole("button", { name: "Back to work" }).click();
await page.locator(".intention").waitFor();

// 10 meeting mode (manual pass; a calendar meeting looks the same, labelled "Calendar")
await page.getByRole("button", { name: /Meeting pass/ }).click();
await page.getByText("Meeting pass", { exact: true }).waitFor();
await settle();
await shot("10-meeting-mode");

// 11 wrap-up summary
await page.getByRole("button", { name: "Done for now" }).click();
await page.getByRole("button", { name: "Tap again to wrap up" }).click();
await page.getByRole("heading", { name: "Wrap up" }).waitFor();
await page.getByRole("button", { name: "Type instead" }).click();
await page.locator("textarea").fill("done: sections 2 and 3 drafted, budget mismatch found (row 14)\nnext: fix row 14, then send to Priya before lunch");
await page.getByRole("button", { name: "I'm done" }).click();
await page.getByRole("heading", { name: "Session closed." }).waitFor();
await settle();
await shot("11-wrapup-summary");
await page.getByRole("button", { name: "Close the day" }).click();
await page.getByRole("heading", { name: "Your Mac is waiting." }).waitFor();

// 12 emergency unlock notice on the Daylight
mac.send(JSON.stringify({ type: "emergency.unlock", reason: "Printer driver install needs the screen" }));
await page.getByText(/Emergency unlock/).waitFor();
await settle();
await shot("12-emergency-unlock");

// 13 history with ink pages
await page.getByRole("link", { name: "History" }).click();
await page.locator("details.hist summary").first().click();
await page.locator(".thumbs img").first().waitFor();
await page.locator(".thumbs img").last().scrollIntoViewIfNeeded();
await page.waitForFunction(() => [...document.querySelectorAll("details[open] .thumbs img")].every((i) => i.complete && i.naturalWidth > 0));
await page.locator("details.hist").first().scrollIntoViewIfNeeded();
await settle();
await shot("13-history");

// 14 settings
await page.getByRole("link", { name: "Settings" }).click();
await page.getByRole("heading", { name: "Settings" }).waitFor();
await shot("14-settings");

// 15 outside work hours
configStore.update({ schedule: { days: [] } });
engine.configChanged();
await page.getByRole("link", { name: "Today" }).click();
await page.getByRole("heading", { name: "Outside work hours." }).waitFor();
await settle();
await shot("15-home-free");

} catch (err) {
  await failShot(err);
}
await browser.close();
mac.close();
await server.close();
console.log(`wrote ${fs.readdirSync(out).filter((f) => f.endsWith(".png")).length} screenshots to ${out}`);
