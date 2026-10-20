// Milestone 5 exit check: one headless browser plays an online match against
// the AI bot, driven only through the in-game Play Online menu:
//   main menu -> Play Online -> nickname, 30 s halves, AI level Hard ->
//   Play vs AI (online) -> straight into the match (no waiting page) -> kickoff
//   -> full time -> the result is in /api/stats/v1/matches/recent with the
//   bot as "AI (Hard)", and the bot has a row on the leaderboard.
// Prints MATCH_ID=<id> so tests/e2e/run_bot_checks.sh can find the bot's
// decision log lines for this match.
//
//   docker compose up --build -d
//   bash tests/e2e/run.sh vs_ai_menu.mjs
//
// Software WebGL renders about one frame per second or two, so every step
// waits generously. Exits 0 on success.

import { chromium } from "playwright";
import { allPassed, api, check, recentEntries, waitFor } from "./lib.mjs";

const base = process.argv[2] ?? "http://localhost";
const NICK = "VsAiE2E";
const browser = await chromium.launch({ args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"] });
const context = await browser.newContext({ viewport: { width: 960, height: 540 } });
const page = await context.newPage();
const lines = [];
page.on("console", (m) => lines.push(m.text()));
page.on("pageerror", (e) => lines.push(`pageerror: ${e.message}`));
await page.goto(base + "/");

const mark = () => lines.length;
const next = (re, from = 0, ms = 120_000) => waitFor(() => lines.slice(from).find((l) => re.test(l)) ?? null, ms, 250);
const seen = (text) => lines.some((l) => l.includes(text));

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

const main = await layout("main", 0);
let from = mark();
await click(main, "play_online");
const home = await layout("online_home", from);
check(home.vs_ai && home.ai_easy && home.ai_normal && home.ai_hard, "the Play Online screen offers Play vs AI with an AI level picker");
await click(home, "nickname");
await page.waitForTimeout(1500);
await page.keyboard.press("Control+A");
await page.keyboard.type(NICK, { delay: 80 });
await page.waitForTimeout(1500);
await click(home, "half_30");
await page.waitForTimeout(800);
await click(home, "ai_hard");
await page.waitForTimeout(800);
from = mark();
await click(home, "vs_ai");
const created = await next(/^\[online\] vs AI room created/, from, 60_000);
const [, code, matchId, level] = created?.match(/room created (\w+) \(match ([\w-]+), (\w+)\)/) ?? [];
check(code && matchId && level === "hard", `the menu creates a vs-AI room (${code}, ${matchId}, ${level})`);
console.log(`MATCH_ID=${matchId}`);
check(await waitFor(() => seen("as team 0"), 120_000), "the browser enters the match on team 0");
check(!lines.slice(from).some((l) => /^\[ui\] online_waiting /.test(l)), "no waiting page: the bot is already seated");
check(await waitFor(() => seen("[online] kickoff"), 120_000), "the match kicks off against the bot");
const status = await api(base, "GET", `/api/lobby/v1/rooms/${code}`);
check(status.body?.mode === "vs_ai" && status.body?.difficulty === "hard"
  && status.body?.players?.map((p) => p.nickname).join() === `${NICK},AI (Hard)`, `the lobby lists both players (${JSON.stringify(status.body?.players)})`);
await page.keyboard.down("KeyD");
await page.waitForTimeout(4000);
await page.keyboard.up("KeyD");

check(await waitFor(() => seen("[online] match over"), 300_000), "the browser reaches full time");
const over = lines.find((l) => l.includes("[online] match over")) ?? "";
console.log(over);
const ft = await layout("fulltime", 0).catch(() => ({}));
check(ft.new_online && !ft.rematch, "the full-time screen offers New Online Match");
console.log("--- browser:\n" + lines.filter((l) => /^\[(online|ui)\]/.test(l)).join("\n"));
const errors = lines.filter((l) => /pageerror|SCRIPT ERROR/.test(l));
check(errors.length === 0, `no script errors in the page (${errors.length})`);
if (errors.length) console.log(errors.slice(0, 5).join("\n"));
await browser.close();

const entries = matchId ? await waitFor(async () => { const e = await recentEntries(base, matchId); return e?.length ? e : null; }, 60_000, 1000) : null;
check(entries?.length === 1, `the result appears once in /api/stats/v1/matches/recent (${entries?.length ?? 0})`);
const m = entries?.[0];
if (m) {
  console.log(JSON.stringify({ reason: m.reason, score: m.score, players: m.players.map((p) => p.nickname) }));
  const score = over.match(/(\d+)-(\d+)/);
  check(m.reason === "full_time" && m.players.map((p) => p.nickname).join() === `${NICK},AI (Hard)`, "the result names the player and AI (Hard)");
  check(score && m.score[0] === +score[1] && m.score[1] === +score[2], "the recorded score matches the browser");
}
const board = await api(base, "GET", "/api/stats/v1/leaderboard?limit=100");
check(board.body?.items?.some((r) => r.nickname === "AI (Hard)"), "the bot has a leaderboard row as AI (Hard)");
console.log(allPassed() ? "E2E VS AI MENU PASSED" : "E2E VS AI MENU FAILED");
process.exit(allPassed() ? 0 : 1);
