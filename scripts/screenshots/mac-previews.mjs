// Renders previews of the Mac app's windows (shield, check-in banner, meeting
// HUD, menu bar) from the same layout values used in apps/mac/TwelveGate.
// These are HTML renderings, not captures of the running AppKit app, which
// cannot run in the Linux build container. Output: docs/screenshots/mac-*.png
//
//   node scripts/screenshots/mac-previews.mjs
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "@playwright/test";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(here, "../../docs/screenshots");
fs.mkdirSync(out, { recursive: true });

const font = `-apple-system, "SF Pro Text", "Helvetica Neue", "Inter", "Segoe UI", Roboto, system-ui, sans-serif`;
const dark = "rgb(18,18,23)";

const shield = (opts) => `<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;width:1440px;height:900px;background:${dark};font-family:${font};color:#fff;overflow:hidden}
.stack{position:absolute;left:50%;top:50%;transform:translate(-50%,calc(-50% - 40px));width:760px;display:flex;flex-direction:column;align-items:center;gap:18px;text-align:center}
.title{font-size:40px;font-weight:600;line-height:1.15}
.body{font-size:20px;font-weight:300;color:rgba(255,255,255,.85);line-height:1.4}
.meeting{font-size:16px;color:rgba(255,255,255,.75)}
.clock{font-size:16px;color:rgba(255,255,255,.6);font-variant-numeric:tabular-nums}
.status{font-size:14px;color:rgba(255,255,255,.5)}
.em{position:absolute;left:50%;bottom:48px;transform:translateX(-50%);width:420px;display:flex;flex-direction:column;align-items:center;gap:10px}
.hold{width:420px;height:44px;border-radius:10px;background:${opts.pressed ? "rgb(158,56,51)" : "rgb(51,51,51)"};border:1px solid rgb(97,97,97);color:#fff;font-size:14px;font-weight:500;display:flex;align-items:center;justify-content:center}
.bar{width:420px;height:6px;border-radius:3px;background:rgba(255,255,255,.12);overflow:hidden}
.bar i{display:block;height:100%;width:${opts.progress ?? 0}%;background:rgb(73,124,220)}
.hint{font-size:13px;color:rgba(255,255,255,.7)}
.field{width:420px;height:26px;border-radius:5px;background:#fff;color:#111;font-size:14px;padding:0 8px;box-sizing:border-box;display:flex;align-items:center}
.field.empty{color:rgba(0,0,0,.35)}
.btn{height:24px;padding:0 14px;border-radius:6px;background:${opts.enabled ? "rgb(52,120,246)" : "rgb(70,70,74)"};color:${opts.enabled ? "#fff" : "rgba(255,255,255,.4)"};font-size:13px;display:flex;align-items:center}
</style></head><body>
<div class="stack">
  <div class="title">${opts.title}</div>
  <div class="body">${opts.body}</div>
  ${opts.meeting ? `<div class="meeting">Meeting: ${opts.meeting}</div>` : ""}
  <div class="clock">Monday, September 28, 2026 at 10:02</div>
  <div class="status">Connected to Twelve</div>
</div>
<div class="em">
  <div class="hold">Hold for 30 s to unlock in an emergency</div>
  <div class="bar"><i></i></div>
  ${opts.reason ? `<div class="hint">Why? (at least 10 characters)</div><div class="field ${opts.reasonText ? "" : "empty"}">${opts.reasonText || "What is the emergency?"}</div><div class="btn">Unlock for 30 minutes</div>` : ""}
</div>
</body></html>`;

const banner = `<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;width:520px;height:140px;background:#e9e9ee;font-family:${font};overflow:hidden}
.bar{height:24px;background:rgba(255,255,255,.7);border-bottom:1px solid rgba(0,0,0,.08);display:flex;align-items:center;justify-content:flex-end;padding:0 12px;font-size:13px;color:#111;gap:14px}
.panel{position:absolute;left:50px;top:36px;width:420px;height:80px;border-radius:14px;background:rgba(26,26,31,.96);box-shadow:0 8px 24px rgba(0,0,0,.35);color:#fff}
.text{position:absolute;left:18px;top:50%;transform:translateY(-50%);font-size:15px;font-weight:500;max-width:250px;line-height:1.3}
.count{position:absolute;right:18px;top:10px;font-size:28px;font-weight:600;font-variant-numeric:tabular-nums}
.snooze{position:absolute;right:14px;bottom:8px;font-size:11px;padding:2px 9px;border-radius:5px;background:rgb(70,70,74);color:#fff}
</style></head><body>
<div class="bar"><span>12</span><span>Mon 10:58</span></div>
<div class="panel"><div class="text">Check-in on your Daylight</div><div class="count">1:47</div><div class="snooze">Snooze 15 min</div></div>
</body></html>`;

const hud = `<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;width:420px;height:150px;background:#e9e9ee;font-family:${font};overflow:hidden}
.bar{height:24px;background:rgba(255,255,255,.7);border-bottom:1px solid rgba(0,0,0,.08);display:flex;align-items:center;justify-content:flex-end;padding:0 12px;font-size:13px;color:#111;gap:14px}
.panel{position:absolute;right:12px;top:36px;width:340px;border-radius:12px;background:rgba(26,26,31,.94);box-shadow:0 8px 24px rgba(0,0,0,.35);color:#fff;padding:12px 14px;box-sizing:border-box;display:flex;flex-direction:column;gap:4px}
.t{font-size:13px;font-weight:600}.m{font-size:12px;color:rgba(255,255,255,.8)}.f{font-size:12px;font-weight:500;color:rgb(255,191,102)}
</style></head><body>
<div class="bar"><span>12</span><span>Mon 14:31</span></div>
<div class="panel"><div class="t">Meeting mode — only allowlisted apps</div><div class="m">Weekly 1:1 with Priya</div><div class="f">Safari is not on the meeting allowlist</div></div>
</body></html>`;

const menu = `<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;width:420px;height:290px;background:#e9e9ee;font-family:${font};overflow:hidden}
.bar{height:24px;background:rgba(255,255,255,.7);border-bottom:1px solid rgba(0,0,0,.08);display:flex;align-items:center;justify-content:flex-end;padding:0 12px;font-size:13px;color:#111;gap:14px}
.bar .on{background:rgba(0,0,0,.12);padding:2px 7px;border-radius:5px}
.menu{position:absolute;right:56px;top:28px;width:270px;background:rgba(246,246,248,.97);border-radius:10px;box-shadow:0 10px 30px rgba(0,0,0,.25);padding:6px;font-size:13px;color:#111}
.i{padding:5px 10px;border-radius:6px}.d{color:rgba(0,0,0,.4)}.sep{height:1px;background:rgba(0,0,0,.1);margin:5px 10px}
.i.h{background:rgb(52,120,246);color:#fff}
</style></head><body>
<div class="bar"><span class="on">12</span><span>Mon 09:14</span></div>
<div class="menu">
  <div class="i d">Connected · working · free</div>
  <div class="i d">Next check-in: 10:14</div>
  <div class="sep"></div>
  <div class="i h">Open Daylight pairing page</div>
  <div class="i">Open dashboard</div>
  <div class="i">Reconnect</div>
  <div class="sep"></div>
  <div class="i d">Quit TwelveGate</div>
</div>
</body></html>`;

const browser = await chromium.launch(process.env.PLAYWRIGHT_CHROMIUM ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM } : {});
const render = async (name, html, w, hgt, scale = 2) => {
  const page = await browser.newPage({ viewport: { width: w, height: hgt }, deviceScaleFactor: scale });
  await page.setContent(html);
  await page.waitForTimeout(100);
  await page.screenshot({ path: path.join(out, `${name}.png`) });
  await page.close();
};

await render("mac-01-shield-gated", shield({ title: "Your Mac is waiting for your Daylight", body: "Write your intention and priorities on the Daylight to unlock." }), 1440, 900, 1);
await render("mac-02-shield-checkin", shield({ title: "Check-in time", body: "Write where you are on the Daylight. Two minutes, no grades." }), 1440, 900, 1);
await render(
  "mac-03-shield-emergency",
  shield({ title: "Your Mac is waiting for your Daylight", body: "Write your intention and priorities on the Daylight to unlock.", pressed: false, progress: 100, reason: true, reasonText: "Printer driver install needs the screen", enabled: true }),
  1440,
  900,
  1,
);
await render("mac-04-checkin-banner", banner, 520, 140);
await render("mac-05-meeting-hud", hud, 420, 150);
await render("mac-06-menu-bar", menu, 420, 290);
await browser.close();
console.log("wrote Mac previews to", out);
