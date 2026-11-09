// Failure-recovery phases against the real stack, driven by
// tests/e2e/run_failure_checks.sh (which stops/starts/restarts containers
// between phases). Players are protocol-level WebSocket clients (lib.mjs), so
// no browser is needed: a match with idle players still runs to full time.
//
//   node service_failures.mjs <base> spool-match           results is down: play a match to full time
//   node service_failures.mjs <base> expect-result <id>    results is back: the match is recorded exactly once
//   node service_failures.mjs <base> abort-match           prints READY_FOR_RESTART once running, then
//                                                          expects the lobby to report "aborted"

import { allPassed, api, check, createAndJoin, recentEntries, roomStatus, sleep, waitFor, wsPlayer } from "./lib.mjs";

const [base, phase, arg] = process.argv.slice(2);

async function runningMatch(names) {
  const { created, joined } = await createAndJoin(base, 30, names);
  check(created.status === 201 && joined.status === 200, `room created and joined (${created.status}, ${joined.status})`);
  const matchId = created.body.match_id;
  const red = wsPlayer(base, matchId, created.body.token);
  const blue = wsPlayer(base, matchId, joined.body.token);
  check(await waitFor(() => red.welcome && blue.welcome, 20_000), "both players are welcomed");
  check(await waitFor(() => red.has("kickoff") && blue.has("kickoff"), 10_000), "the match kicks off");
  check(await waitFor(async () => (await roomStatus(base, created.body.room_code)) === "running", 10_000), "the lobby reports it running");
  return { created, joined, matchId, red, blue };
}

if (phase === "spool-match") {
  const { created, matchId, red, blue } = await runningMatch(["SpoolRed", "SpoolBlue"]);
  console.log(`MATCH_ID=${matchId}`);
  check(await waitFor(() => red.has("match_over") && blue.has("match_over"), 200_000, 1000), "the match reaches full time with results down");
  check(await waitFor(async () => (await roomStatus(base, created.body.room_code)) === "completed", 15_000), "the lobby reports it completed");
  const stats = await api(base, "GET", "/api/stats/v1/matches/recent");
  console.log(`results while down: HTTP ${stats.status}`);
} else if (phase === "expect-result") {
  const entries = await waitFor(async () => { const e = await recentEntries(base, arg); return e?.length ? e : null; }, 120_000, 2000);
  check(entries?.length === 1, `the spooled result is delivered once results is back (${entries?.length ?? 0})`);
  await sleep(5000);   // any duplicate delivery would land by now
  const again = await recentEntries(base, arg);
  check(again?.length === 1 && again[0].players.map((p) => p.nickname).join() === "SpoolRed,SpoolBlue",
    `exactly one record for the match (${again?.length ?? 0})`);
} else if (phase === "abort-match") {
  const { created, joined, matchId, red, blue } = await runningMatch(["AbortRed", "AbortBlue"]);
  console.log("READY_FOR_RESTART");
  check(await waitFor(() => red.closeCode !== null && blue.closeCode !== null, 120_000), `the restart drops both players (${red.closeCode}, ${blue.closeCode})`);
  check(await waitFor(async () => (await roomStatus(base, created.body.room_code)) === "aborted", 120_000, 1000),
    "the lobby reports the running match as aborted");
  const back = await waitFor(async () => {
    const p = wsPlayer(base, matchId, created.body.token);
    await waitFor(() => p.closeCode !== null || p.welcome, 10_000);
    return p.closeCode === 4404 ? p : null;
  }, 60_000, 2000);
  check(back, "the restarted runtime refuses the old credentials (4404 unknown match)");
  const rejoin = await api(base, "POST", `/api/lobby/v1/rooms/${created.body.room_code}/join`, { nickname: "Late", request_id: crypto.randomUUID() });
  check(rejoin.status === 409, `the aborted room accepts no players (${rejoin.status})`);
  void joined;
} else {
  console.log(`unknown phase ${phase}`);
  process.exit(2);
}

console.log(allPassed() ? `PHASE ${phase} PASSED` : `PHASE ${phase} FAILED`);
process.exit(allPassed() ? 0 : 1);
