// Two-browser online smoke test through the real gateway and match runtime.
// Needs the development stack (dev tokens):
//   docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build -d
//   docker run --rm --network container:inazuma-online-gateway-1 -v "$PWD/tests/e2e:/e2e" -w /e2e \
//     mcr.microsoft.com/playwright:v1.63.0-noble \
//     sh -c "npm i --silent --no-save playwright@1.63.0 && node two_players.mjs http://localhost"
//
// Two isolated browser contexts join the same match as red and blue, both must
// see the kickoff, red plays for a few seconds with the keyboard, then blue
// leaves and red must see the match pause. Exits 0 on success, 1 on failure.

import { chromium } from "playwright";

const base = process.argv[2] ?? "http://localhost:8080";
const matchId = `e2e-${Date.now()}`;
const timeoutMs = 180_000;

const browser = await chromium.launch({ args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"] });

async function player(team) {
  const context = await browser.newContext({ viewport: { width: 960, height: 540 } });
  const page = await context.newPage();
  const lines = [];
  page.on("console", (m) => lines.push(m.text()));
  page.on("pageerror", (e) => lines.push(`pageerror: ${e.message}`));
  await page.goto(`${base}/?match=${matchId}&token=dev:${team}`);
  return { context, page, lines };
}

function waitFor(p, text, ms = timeoutMs) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    const timer = setInterval(() => {
      if (p.lines.some((l) => l.includes(text))) { clearInterval(timer); resolve(true); }
      else if (Date.now() - t0 > ms) { clearInterval(timer); resolve(false); }
    }, 250);
  });
}

const checks = [];
const check = (ok, name) => { checks.push(ok); console.log(`${ok ? "PASS" : "FAIL"}  ${name}`); };

const red = await player(0);
const blue = await player(1);
check(await waitFor(red, "[online] joined match"), "red joins as team 0");
check(red.lines.some((l) => l.includes("as team 0")) && (await waitFor(blue, "as team 1")), "blue joins as team 1");
check((await waitFor(red, "[online] kickoff")) && (await waitFor(blue, "[online] kickoff")), "both browsers see the kickoff");

// Red runs right and sprints for a moment (real keyboard input into the canvas).
await red.page.mouse.click(480, 270);
await red.page.keyboard.down("KeyD");
await red.page.keyboard.down("ShiftLeft");
await red.page.waitForTimeout(2000);
await red.page.keyboard.up("ShiftLeft");
await red.page.keyboard.up("KeyD");

await blue.context.close();
check(await waitFor(red, "[online] paused", 30_000), "red sees the match pause when blue leaves");

const errors = red.lines.filter((l) => /pageerror|SCRIPT ERROR/.test(l));
check(errors.length === 0, `no script errors in the red page (${errors.length})`);
if (errors.length) console.log(errors.slice(0, 5).join("\n"));
console.log(red.lines.filter((l) => l.startsWith("[online]")).join("\n"));
if (!checks.every(Boolean)) console.log("--- red page tail:\n" + red.lines.slice(-12).join("\n"));

await browser.close();
const ok = checks.every(Boolean);
console.log(ok ? "E2E TWO PLAYERS PASSED" : "E2E TWO PLAYERS FAILED");
process.exit(ok ? 0 : 1);
