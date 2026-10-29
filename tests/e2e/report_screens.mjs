// Screenshots of the system's screens for the project report
// (docs/relatorio/), taken from the real web build through the gateway:
//   01 main menu (with the live microservices strip)
//   02 match setup (offline), 03 an offline match
//   04 Play Online home (recommendation + microservices panels)
//   05 the same, hovering Play vs AI (the services it uses light up)
//   06 the recommended AI level applied, 07 the online match against the AI bot
//   08 full time, 09 Play Online again (the updated recommendation)
//   10 recent matches & leaderboard, 11 a room's waiting page
// Every step also checks what it shows, like the other e2e scripts.
//
//   docker compose up --build -d
//   bash tests/e2e/run.sh report_screens.mjs [out dir, default out/] [nickname]
//
// Software WebGL renders about one frame per second or two, so every step
// waits generously. Exits 0 on success.

import { mkdirSync } from "node:fs";
import { chromium } from "playwright";
import { allPassed, check, waitFor } from "./lib.mjs";

const base = process.argv[2] ?? "http://localhost";
const outDir = (process.argv[3] ?? "out").replace(/\/$/, "");
const NICK = process.argv[4] ?? "Erick";
mkdirSync(outDir, { recursive: true });
const browser = await chromium.launch({ args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"] });
const context = await browser.newContext({ viewport: { width: 1280, height: 720 } });
const page = await context.newPage();
const lines = [];
page.on("console", (m) => lines.push(m.text()));
page.on("pageerror", (e) => lines.push(`pageerror: ${e.message}`));

const mark = () => lines.length;
const next = (re, from = 0, ms = 120_000) => waitFor(() => lines.slice(from).find((l) => re.test(l)) ?? null, ms, 250);
const seen = (text, from = 0) => lines.slice(from).some((l) => l.includes(text));
async function shot(name, settleMs = 3000) {
  await page.waitForTimeout(settleMs);
  await page.screenshot({ path: `${outDir}/${name}.png`, timeout: 180_000 });
  console.log(`saved ${outDir}/${name}.png`);
}

/** Waits for page `ui` to be logged (after `from`) and returns its control centres in CSS pixels. */
async function layout(ui, from) {
  const line = await next(new RegExp(`^\\[ui\\] ${ui} `), from, 180_000);
  if (!line) throw new Error(`page ${ui} never shown`);
  const dpr = await page.evaluate(() => window.devicePixelRatio);
  return Object.fromEntries(line.split(" ").slice(2).map((kv) => {
    const [id, xy] = kv.split("=");
    const [x, y] = xy.split(",").map(Number);
    return [id, [x / dpr, y / dpr]];
  }));
}
const click = (pos, id) => page.mouse.click(pos[id][0], pos[id][1]);
async function loadMain() {
  const from = mark();
  await page.goto(base + "/");
  return layout("main", from);
}

// 01: main menu, once the services strip has probed every service.
let from = mark();
let main = await loadMain();
check(await next(/^\[services\] /, from, 60_000), "the main menu probes the microservices");
// Software WebGL runs at about one frame per second, so an early probe round can time out:
// wait for a round with every service up (the panel shows the latest round).
check(await next(/^\[services\] (?!.*=(down|checking))/, from, 120_000), "every microservice is up");
await shot("01_main_menu", 5000);

// 02-03: offline play (Play Now -> Choose Sides: keyboard to the left team ->
// Space -> Times & Uniformes -> "Começar" -> match). The setup pages don't log a
// layout: "Começar" sits at the centre, 472 px down in a 1280x720 window.
await click(main, "play_now");
await shot("02_match_setup", 5000);
await page.keyboard.press("KeyA");
await page.waitForTimeout(1500);
await page.keyboard.press("Space");
await page.waitForTimeout(5000);
await page.mouse.click(640, 472);
await page.waitForTimeout(12000);
await page.keyboard.down("KeyD");
await page.waitForTimeout(3000);
await page.keyboard.up("KeyD");
await shot("03_offline_match", 2000);

// 04: Play Online home, with the recommendation for this browser's (new) player.
main = await loadMain();
from = mark();
await click(main, "play_online");
let home = await layout("online_home", from);
const rec = await next(/^\[online\] recommendation /, from, 60_000);
check(rec, `the Play Online screen shows a recommendation (${rec})`);
// The recommendation panel grows when it loads; the page logs its layout again.
home = await layout("online_home", lines.indexOf(rec));
check(home.use_level, "the recommendation offers 'Use this AI level'");
await click(home, "nickname");
await page.waitForTimeout(1500);
await page.keyboard.press("Control+A");
await page.keyboard.type(NICK, { delay: 80 });
await page.waitForTimeout(1000);
await click(home, "half_30");
await page.mouse.move(640, 700);
await shot("04_online_home", 4000);

// 05: hovering Play vs AI lights up gateway, lobby, match runtime and ai-bot.
await page.mouse.move(home.vs_ai[0], home.vs_ai[1]);
await shot("05_hover_vs_ai", 4000);

// 06-07: apply the recommended level and play the AI bot online.
const level = rec?.match(/level=(\w+)/)?.[1] ?? "easy";
await click(home, "use_level");
await page.waitForTimeout(1500);
await page.mouse.move(home.use_level[0], home.use_level[1]);
await shot("06_use_recommended_level", 4000);
from = mark();
await click(home, "vs_ai");
const created = await next(/^\[online\] vs AI room created/, from, 60_000);
check(created?.endsWith(`, ${level})`), `the vs-AI room uses the recommended level (${created})`);
check(await waitFor(() => seen("[online] kickoff", from), 120_000), "the online match kicks off against the bot");
await page.keyboard.down("KeyD");
await page.waitForTimeout(5000);
await page.keyboard.up("KeyD");
await shot("07_online_match_vs_ai", 1000);

// 08: full time.
check(await waitFor(() => seen("[online] match over", from), 300_000), "the match reaches full time");
let ft = await layout("fulltime", from);
await shot("08_fulltime", 4000);

// 09: back to Play Online: the recommendation now counts this match.
from = mark();
await click(ft, "new_online");
home = await layout("online_home", from);
const after = await waitFor(async () => {
  const l = lines.slice(from).filter((x) => x.startsWith("[online] recommendation ")).pop();
  return l && !/rating=1000 /.test(l) ? l : null;
}, 60_000, 1000);
check(after, `the recommendation reflects the finished match (${after})`);
await page.mouse.move(640, 700);
await shot("09_online_home_after_match", 4000);

// 10: recent matches & leaderboard (results service).
from = mark();
await click(home, "stats");
// Once both lists load the page grows and logs its layout again: use that one.
const firstStats = await next(/^\[ui\] online_stats /, from, 180_000);
const stats = await layout("online_stats", lines.indexOf(firstStats) + 1);
await shot("10_stats", 3000);

// 11: a PvP room's waiting page (then cancel, which frees the room).
from = mark();
await click(stats, "back");
home = await layout("online_home", from);
from = mark();
await click(home, "create");
const room = await next(/^\[online\] room created/, from, 60_000);
check(room, `a PvP room is created (${room})`);
const waiting = await layout("online_waiting", from);
await shot("11_waiting_room", 4000);
await click(waiting, "cancel");
await page.waitForTimeout(2000);

const errors = lines.filter((l) => /pageerror|SCRIPT ERROR/.test(l));
check(errors.length === 0, `no script errors in the page (${errors.length})`);
if (errors.length) console.log(errors.slice(0, 5).join("\n"));
console.log("--- browser:\n" + lines.filter((l) => /^\[(online|services)\]/.test(l)).join("\n"));
await browser.close();
console.log(allPassed() ? "REPORT SCREENS PASSED" : "REPORT SCREENS FAILED");
process.exit(allPassed() ? 0 : 1);
