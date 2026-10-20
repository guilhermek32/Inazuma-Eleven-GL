// Milestone 4 exit check: two headless browsers play an online match driven
// only through the in-game Play Online menu, through one gateway:
//   red   main menu -> Play Online -> nickname, 30 s halves -> Create Room,
//         Esc on the waiting page (leaves), Create Room again -> waiting page
//   blue  main menu -> Play Online -> nickname -> a wrong code (room not
//         found) -> the real code read from red's console -> Join Room
// then both play to full time, the full-time screen offers New Online Match
// (not Rematch), and the result is in /api/stats/v1/matches/recent.
//
// The page reports its UI through console lines: "[ui] <page> id=x,y ..."
// (centres of clickable controls in window pixels) and "[online] ..." events.
//
//   docker compose up --build -d
//   bash tests/e2e/run.sh online_menu.mjs
//
// Software WebGL renders about one frame per second or two, so every step
// waits generously. Exits 0 on success.

import { chromium } from "playwright";
import { allPassed, check, recentEntries, waitFor } from "./lib.mjs";

const base = process.argv[2] ?? "http://localhost";
const browser = await chromium.launch({ args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"] });

async function player(name) {
  const context = await browser.newContext({ viewport: { width: 960, height: 540 } });
  const page = await context.newPage();
  const lines = [];
  page.on("console", (m) => lines.push(m.text()));
  page.on("pageerror", (e) => lines.push(`pageerror: ${e.message}`));
  await page.goto(base + "/");
  const p = { name, page, lines };
  p.mark = () => lines.length;
  // The first line matching `re` logged at or after index `from`.
  p.next = (re, from = 0, ms = 120_000) => waitFor(() => lines.slice(from).find((l) => re.test(l)) ?? null, ms, 250);
  p.seen = (text) => lines.some((l) => l.includes(text));
  return p;
}

const parseLayout = (line) => Object.fromEntries(line.split(" ").slice(2).map((kv) => {
  const [id, xy] = kv.split("=");
  return [id, xy.split(",").map(Number)];
}));

/** Waits for page `ui` to be logged (after `from`) and returns its control centres. */
async function layout(p, ui, from) {
  const line = await p.next(new RegExp(`^\\[ui\\] ${ui} `), from, 180_000);
  if (!line) throw new Error(`${p.name}: page ${ui} never shown`);
  const dpr = await p.page.evaluate(() => window.devicePixelRatio);
  const pos = parseLayout(line);
  for (const k in pos) pos[k] = [pos[k][0] / dpr, pos[k][1] / dpr];
  return pos;
}
const click = (p, pos, id) => p.page.mouse.click(pos[id][0], pos[id][1]);
async function typeInto(p, pos, id, text) {
  await click(p, pos, id);
  await p.page.waitForTimeout(1500);
  await p.page.keyboard.press("Control+A");
  await p.page.keyboard.type(text, { delay: 80 });
  await p.page.waitForTimeout(1500);
}
async function openOnline(p) {
  const main = await layout(p, "main", 0);
  const from = p.mark();
  await click(p, main, "play_online");
  return layout(p, "online_home", from);
}

// --- red creates a room, leaves it with Esc, then creates the real one --------------
const red = await player("red");
let home = await openOnline(red);
await typeInto(red, home, "nickname", "MenuRed");
await click(red, home, "half_30");
await red.page.waitForTimeout(1000);
let from = red.mark();
await click(red, home, "create");
check(await red.next(/^\[online\] room created/, from), "red creates a room from the menu");
check(await red.next(/^\[ui\] online_waiting /, from), "red sees the waiting page");
from = red.mark();
await red.page.keyboard.press("Escape");
check(await red.next(/^\[online\] left the waiting room/, from), "Esc on the waiting page leaves the room");
home = await layout(red, "online_home", from);
from = red.mark();
await click(red, home, "create");
const created = await red.next(/^\[online\] room created/, from);
const [, code, matchId] = created?.match(/room created (\w+) \(match ([\w-]+)\)/) ?? [];
check(code && matchId, `red creates the match room (${code}, ${matchId})`);
await layout(red, "online_waiting", from);

// --- blue joins: a wrong code first, then red's code ----------------------------------
const blue = await player("blue");
home = await openOnline(blue);
await typeInto(blue, home, "nickname", "MenuBlue");
await typeInto(blue, home, "code", "ZZZZZZ");
from = blue.mark();
await click(blue, home, "join");
check(await blue.next(/^\[online\] lobby error room_not_found/, from), "a wrong code is reported as room not found");
await typeInto(blue, home, "code", code.toLowerCase());
from = blue.mark();
await click(blue, home, "join");
check(await blue.next(new RegExp(`^\\[online\\] joined room ${code} `), from), "blue joins with the code (typed lower-case)");

check(await waitFor(() => red.seen("as team 0") && blue.seen("as team 1"), 180_000), "both browsers are in the match on their own teams");
check(await waitFor(() => red.seen("[online] kickoff") && blue.seen("[online] kickoff"), 120_000), "the waiting page gives way to the kickoff");
await red.page.keyboard.down("KeyD");
await red.page.waitForTimeout(3000);
await red.page.keyboard.up("KeyD");

check(await waitFor(() => red.seen("[online] match over") && blue.seen("[online] match over"), 300_000), "both browsers reach full time");
const over = red.lines.find((l) => l.includes("[online] match over")) ?? "";
console.log(over);
const ft = await layout(red, "fulltime", 0).catch(() => ({}));
check(ft.new_online && !ft.rematch, "the online full-time screen offers New Online Match, not Rematch");
if (ft.new_online) {
  from = red.mark();
  await click(red, ft, "new_online");
  check(await red.next(/^\[ui\] online_home /, from), "New Online Match returns to the Play Online screen");
}
for (const p of [red, blue]) {
  console.log(`--- ${p.name}:\n` + p.lines.filter((l) => /^\[(online|ui)\]/.test(l)).join("\n"));
}
const errors = [...red.lines, ...blue.lines].filter((l) => /pageerror|SCRIPT ERROR/.test(l));
check(errors.length === 0, `no script errors in either page (${errors.length})`);
if (errors.length) console.log(errors.slice(0, 5).join("\n"));
await browser.close();

const entries = matchId ? await waitFor(async () => { const e = await recentEntries(base, matchId); return e?.length ? e : null; }, 60_000, 1000) : null;
check(entries?.length === 1, `the result appears once in /api/stats/v1/matches/recent (${entries?.length ?? 0})`);
const m = entries?.[0];
if (m) {
  console.log(JSON.stringify({ reason: m.reason, score: m.score, players: m.players.map((p) => p.nickname) }));
  const score = over.match(/(\d+)-(\d+)/);
  check(m.reason === "full_time" && m.players.map((p) => p.nickname).join() === "MenuRed,MenuBlue", "the result names both menu players");
  check(score && m.score[0] === +score[1] && m.score[1] === +score[2], "the recorded score matches the browsers");
}
console.log(allPassed() ? "E2E ONLINE MENU PASSED" : "E2E ONLINE MENU FAILED");
process.exit(allPassed() ? 0 : 1);
