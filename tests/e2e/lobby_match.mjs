// Full online flow through the real stack (main compose, release runtime):
// create a room and join it through the lobby API, open the two returned
// play URLs in two headless browsers, play a 30 s-half match to full time,
// then find the result in the results service's history and leaderboard.
// Also checks that a tampered credential is refused through the gateway and
// that internal routes are not exposed.
//
//   cp .env.example .env && docker compose up --build -d
//   docker run --rm --network container:inazuma-online-gateway-1 -v "$PWD/tests/e2e:/e2e" -w /e2e \
//     mcr.microsoft.com/playwright:v1.63.0-noble \
//     sh -c "npm i --silent --no-save playwright@1.63.0 && node lobby_match.mjs http://localhost"
//
// A match takes ~70 s of real time plus browser start-up. Exits 0 on success.

import { chromium } from "playwright";
import { allPassed, api, check, createAndJoin, recentEntries, roomStatus, waitFor, wsPlayer } from "./lib.mjs";

const base = process.argv[2] ?? "http://localhost";

const { created, joined } = await createAndJoin(base, 30);
check(created.status === 201 && created.body.team === 0 && created.body.token, `lobby creates a room (${created.status})`);
check(joined.status === 200 && joined.body.team === 1 && joined.body.match_id === created.body.match_id, `lobby joins it as team 1 (${joined.status})`);
const { room_code: code, match_id: matchId } = created.body;
console.log(`room ${code}, match ${matchId}`);
check((await roomStatus(base, code)) === "waiting", "the room is waiting for its players");
const third = await api(base, "POST", `/api/lobby/v1/rooms/${code}/join`, { nickname: "Third", request_id: crypto.randomUUID() });
check(third.status === 409, `a third player is refused (${third.status})`);

// A credential with one flipped character never reaches the match.
const t = joined.body.token;
const tampered = t.slice(0, 10) + (t[10] === "A" ? "B" : "A") + t.slice(11);
const intruder = wsPlayer(base, matchId, tampered);
await waitFor(() => intruder.closeCode !== null, 10000);
check(intruder.closeCode === 4401, `a tampered credential is refused with 4401 (${intruder.closeCode})`);
const internal = await api(base, "GET", "/api/stats/internal/v1/matches");
const ingest = await api(base, "POST", "/api/stats/v1/../internal/v1/matches", {});
check(internal.status === 404 && ingest.status !== 201 && ingest.status !== 200, `internal routes are not exposed (${internal.status}, ${ingest.status})`);

const browser = await chromium.launch({ args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"] });
async function player(grant) {
  const context = await browser.newContext({ viewport: { width: 960, height: 540 } });
  const page = await context.newPage();
  const lines = [];
  page.on("console", (m) => lines.push(m.text()));
  page.on("pageerror", (e) => lines.push(`pageerror: ${e.message}`));
  await page.goto(base + grant.play_url);
  return { context, page, lines, seen: (text) => lines.some((l) => l.includes(text)) };
}
const red = await player(created.body);
const blue = await player(joined.body);
check(await waitFor(() => red.seen("as team 0") && blue.seen("as team 1"), 180_000), "both browsers join with their lobby credentials");
check(await waitFor(() => red.seen("[online] kickoff") && blue.seen("[online] kickoff"), 60_000), "both browsers see the kickoff");
check(await waitFor(async () => (await roomStatus(base, code)) === "running", 10_000), "the lobby reports the room running");

await red.page.mouse.click(480, 270);
await red.page.keyboard.down("KeyD");
await red.page.waitForTimeout(3000);
await red.page.keyboard.up("KeyD");

check(await waitFor(() => red.seen("[online] match over") && blue.seen("[online] match over"), 180_000), "both browsers reach full time");
const over = red.lines.find((l) => l.includes("[online] match over")) ?? "";
console.log(over);
for (const [name, p] of [["red", red], ["blue", blue]]) {
  console.log(`--- ${name} [online] log:\n` + p.lines.filter((l) => l.startsWith("[online]")).join("\n"));
}
const errors = [...red.lines, ...blue.lines].filter((l) => /pageerror|SCRIPT ERROR/.test(l));
check(errors.length === 0, `no script errors in either page (${errors.length})`);
if (errors.length) console.log(errors.slice(0, 5).join("\n"));
await browser.close();

check(await waitFor(async () => (await roomStatus(base, code)) === "completed", 15_000), "the lobby reports the room completed");
const entries = await waitFor(async () => { const e = await recentEntries(base, matchId); return e?.length ? e : null; }, 60_000, 1000);
check(entries?.length === 1, `the result appears exactly once in /api/stats/v1/matches/recent (${entries?.length ?? 0})`);
const m = entries?.[0];
if (m) {
  console.log(JSON.stringify({ reason: m.reason, score: m.score, winner: m.winner, players: m.players.map((p) => p.nickname) }));
  const score = over.match(/(\d+)-(\d+)/);
  check(m.reason === "full_time" && m.players.map((p) => p.nickname).join() === "RedE2E,BlueE2E"
    && m.players[0].player_id === created.body.player_id && m.players[1].player_id === joined.body.player_id,
    "the recorded result names both lobby players");
  check(score && m.score[0] === +score[1] && m.score[1] === +score[2], "the recorded score matches what the browsers showed");
}
const board = await api(base, "GET", "/api/stats/v1/leaderboard?limit=100");
const ids = (board.body?.items ?? []).map((r) => r.player_id);
check(ids.includes(created.body.player_id) && ids.includes(joined.body.player_id), "both players are on the leaderboard");

console.log(allPassed() ? "E2E LOBBY MATCH PASSED" : "E2E LOBBY MATCH FAILED");
process.exit(allPassed() ? 0 : 1);
