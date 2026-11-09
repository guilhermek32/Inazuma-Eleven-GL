// Measurements for docs/measurements.md: browser frame times, snapshot sizes
// and bandwidth, and input-to-visible delay, in one online match through the
// gateway (main compose stack, two headless Chromium pages).
//
//   node measure.mjs http://localhost [label] [window_s] [quality]
//
// quality (optional) is passed to both pages as &quality=<web|full> to force a
// render tier (see RenderTier); omitted, the build picks its own.
//
// Run it like the other e2e scripts (Playwright image inside the gateway's
// network namespace). Extra latency is added outside this script, e.g. with
// tc netem on the gateway namespace's loopback (see docs/measurements.md).
//
// Method
//   frame time   requestAnimationFrame intervals in each page for window_s
//                (Godot's web main loop runs once per animation frame, so this
//                is the engine's frame time).
//   snapshots    every WebSocket frame the red page receives, grouped by
//                protocol message type (byte 1), counted over the same window.
//   input delay  the red page is opened with &latency=1: the game then logs
//                "[latency] input_to_visible_ms=..." each time a move key
//                press (from standstill) first shows up as movement of the
//                selected player in the interpolated mirror. The script
//                presses D for 400 ms every 1.6 s during the window.
// Prints one JSON summary line prefixed with MEASURE.

import { chromium } from "playwright";
import { createAndJoin, waitFor } from "./lib.mjs";

const base = process.argv[2] ?? "http://localhost";
const label = process.argv[3] ?? "run";
const windowS = Number(process.argv[4] ?? 20);
const quality = process.argv[5] ? `&quality=${process.argv[5]}` : "";
const TYPES = { 2: "welcome", 4: "snapshot", 5: "event", 7: "pong", 8: "error", 3: "input", 6: "ping", 1: "hello" };

const { created, joined } = await createAndJoin(base, 300, ["MeasureRed", "MeasureBlue"]);
if (created.status !== 201 || joined.status !== 200) {
  console.log(`lobby failed: ${created.status} ${joined.status}`);
  process.exit(1);
}
const browser = await chromium.launch({ args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"] });

async function player(grant, extra) {
  const context = await browser.newContext({ viewport: { width: 960, height: 540 } });
  const page = await context.newPage();
  const lines = [];
  const frames = { recv: {}, sent: {}, counting: false };
  const t0 = Date.now();
  const timing = { ready_ms: null };
  page.on("console", (m) => {
    lines.push(m.text());
    if (timing.ready_ms === null && m.text().includes("environment ready")) timing.ready_ms = Date.now() - t0;
  });
  page.on("websocket", (ws) => {
    const add = (dir, payload) => {
      if (!frames.counting || typeof payload === "string") return;
      const type = TYPES[payload[1]] ?? `t${payload[1]}`;
      const slot = (frames[dir][type] ??= { count: 0, bytes: 0, min: Infinity, max: 0 });
      slot.count += 1;
      slot.bytes += payload.length;
      slot.min = Math.min(slot.min, payload.length);
      slot.max = Math.max(slot.max, payload.length);
    };
    ws.on("framereceived", (f) => add("recv", f.payload));
    ws.on("framesent", (f) => add("sent", f.payload));
  });
  await page.goto(base + grant.play_url + extra + quality);
  return { page, lines, frames, timing, seen: (t) => lines.some((l) => l.includes(t)) };
}

const red = await player(created.body, "&latency=1");
const blue = await player(joined.body, "");
const kicked = await waitFor(() => red.seen("[online] kickoff") && blue.seen("[online] kickoff"), 240_000);
if (!kicked) {
  console.log("no kickoff\n" + red.lines.slice(-10).join("\n"));
  process.exit(1);
}
await red.page.waitForTimeout(6000);   // kickoff freeze + shader warm-up
await red.page.mouse.click(480, 270);

const rafIntervals = (page, ms) => page.evaluate((ms) => new Promise((resolve) => {
  const out = [];
  let last = performance.now();
  const start = last;
  const step = (now) => {
    out.push(now - last);
    last = now;
    if (now - start < ms) requestAnimationFrame(step); else resolve(out.slice(1));
  };
  requestAnimationFrame(step);
}), ms);

red.frames.counting = true;
const t0 = Date.now();
const framesRed = rafIntervals(red.page, windowS * 1000);
const framesBlue = rafIntervals(blue.page, windowS * 1000);
while (Date.now() - t0 < windowS * 1000 - 2000) {
  await red.page.keyboard.down("KeyD");
  await red.page.waitForTimeout(400);
  await red.page.keyboard.up("KeyD");
  await red.page.waitForTimeout(1200);
}
const [fr, fb] = await Promise.all([framesRed, framesBlue]);
const elapsed = (Date.now() - t0) / 1000;
red.frames.counting = false;
await browser.close();

const stats = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const q = (p) => s[Math.min(s.length - 1, Math.floor(p * s.length))];
  const mean = xs.reduce((a, b) => a + b, 0) / xs.length;
  return { n: xs.length, mean: +mean.toFixed(1), p50: +q(0.5).toFixed(1), p95: +q(0.95).toFixed(1), max: +s[s.length - 1].toFixed(1) };
};
const per = (dir) => Object.fromEntries(Object.entries(red.frames[dir]).map(([k, v]) => [k, {
  count: v.count, avg_bytes: +(v.bytes / v.count).toFixed(1), min: v.min, max: v.max,
  per_s: +(v.count / elapsed).toFixed(1), bytes_per_s: Math.round(v.bytes / elapsed),
}]));
const latency = red.lines.filter((l) => l.startsWith("[latency]"))
  .map((l) => Number((l.match(/input_to_visible_ms=([\d.]+)/) ?? [])[1])).filter((v) => !Number.isNaN(v));
const rtts = red.lines.filter((l) => l.startsWith("[latency]"))
  .map((l) => Number((l.match(/rtt_ms=([\d.]+)/) ?? [])[1])).filter((v) => !Number.isNaN(v) && v >= 0);
const summary = {
  label, window_s: +elapsed.toFixed(1),
  ready_ms: { red: red.timing.ready_ms, blue: blue.timing.ready_ms },
  frame_ms: { red: stats(fr), blue: stats(fb) },
  fps: { red: +(fr.length / elapsed).toFixed(1), blue: +(fb.length / elapsed).toFixed(1) },
  recv: per("recv"), sent: per("sent"),
  input_to_visible_ms: stats(latency), rtt_ms: stats(rtts),
  renderer: red.lines.find((l) => l.includes("OpenGL API")) ?? null,
  tier: red.lines.find((l) => l.startsWith("[render]")) ?? null,
};
console.log("MEASURE " + JSON.stringify(summary));
process.exit(0);
