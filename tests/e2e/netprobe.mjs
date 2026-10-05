// Browser smoke test for the deployment: loads the web build through the
// gateway in headless Chromium and checks that
//   1. the engine starts on the Compatibility (WebGL 2) renderer, and
//   2. the ?netprobe scene completes a WebSocket round trip to the match
//      runtime through the gateway's /ws/game proxy.
//
// Run against a running stack (docker compose up) from the repo root. The
// container joins the gateway's network namespace so the page is served from
// http://localhost: Godot's web build refuses to start outside a secure
// context (HTTPS or localhost), and real deployments use HTTPS.
//   docker run --rm --network container:inazuma-online-gateway-1 -v "$PWD/tests/e2e:/e2e" -w /e2e \
//     mcr.microsoft.com/playwright:v1.63.0-noble \
//     sh -c "npm i --silent --no-save playwright@1.63.0 && node netprobe.mjs http://localhost"
//
// Exits 0 on success, 1 on failure.

import { chromium } from "playwright";

const base = process.argv[2] ?? "http://localhost:8080";
const timeoutMs = 120_000;

const browser = await chromium.launch({ args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"] });
const page = await browser.newPage();
const lines = [];
const done = new Promise((resolve) => {
  page.on("console", (msg) => {
    const text = msg.text();
    lines.push(text);
    if (text.startsWith("NET PROBE OK")) resolve(true);
    if (text.startsWith("NET PROBE FAILED")) resolve(false);
  });
});
const timer = new Promise((resolve) => setTimeout(() => resolve(false), timeoutMs));

page.on("pageerror", (err) => lines.push(`pageerror: ${err.message}`));

await page.goto(`${base}/?netprobe`);
const ok = await Promise.race([done, timer]);
if (!ok) {
  // Godot reports startup problems (e.g. no WebGL 2) in its status overlay, not the console.
  const notice = await page.locator("#status-notice").textContent().catch(() => null);
  const webgl2 = await page.evaluate(() => !!document.createElement("canvas").getContext("webgl2"));
  console.log(`status notice: ${notice ?? "(none)"}`);
  console.log(`webgl2 available: ${webgl2}`);
  console.log(lines.slice(-15).join("\n"));
}
await browser.close();

const renderer = lines.find((l) => l.includes("OpenGL API")) ?? "(no renderer line)";
const compatibility = renderer.includes("Compatibility");
console.log(`renderer: ${renderer}`);
console.log(lines.filter((l) => /probe|PROBE/.test(l)).join("\n"));
console.log(ok && compatibility ? "E2E NETPROBE PASSED" : "E2E NETPROBE FAILED");
process.exit(ok && compatibility ? 0 : 1);
