// AI bot availability phases against the real stack, driven by
// tests/e2e/run_bot_checks.sh (which stops/starts the ai-bot container
// between phases). Players are protocol-level WebSocket clients (lib.mjs).
//
//   node bot_checks.mjs <base> down   ai-bot stopped: vs-AI creation fails
//                                     cleanly (503 bot_unavailable), a PvP
//                                     room still creates, joins and kicks off
//   node bot_checks.mjs <base> back   ai-bot running again: a vs-AI room is
//                                     ready at once and kicks off as soon as
//                                     the human connects

import { allPassed, api, check, createAndJoin, requestId, roomStatus, waitFor, wsPlayer } from "./lib.mjs";

const [base, phase] = process.argv.slice(2);

const createVsAi = (difficulty) => api(base, "POST", "/api/lobby/v1/rooms",
  { nickname: "BotCheck", half_length_s: 30, request_id: requestId(), mode: "vs_ai", difficulty });

if (phase === "down") {
  const t0 = Date.now();
  const vsAi = await createVsAi("normal");
  check(vsAi.status === 503 && vsAi.body?.error === "bot_unavailable",
    `vs-AI creation fails cleanly with ai-bot stopped (${vsAi.status} ${vsAi.body?.error}, ${Date.now() - t0} ms)`);
  check(!vsAi.body?.room_code && !vsAi.body?.token, "no room code or credential is handed out");
  const { created, joined } = await createAndJoin(base, 30, ["PvpRed", "PvpBlue"]);
  check(created.status === 201 && joined.status === 200, `a PvP room still creates and joins (${created.status}, ${joined.status})`);
  if (created.status === 201) {
    const red = wsPlayer(base, created.body.match_id, created.body.token);
    const blue = wsPlayer(base, created.body.match_id, joined.body.token);
    check(await waitFor(() => red.has("kickoff") && blue.has("kickoff"), 20_000), "the PvP match kicks off");
    check(await waitFor(async () => (await roomStatus(base, created.body.room_code)) === "running", 10_000), "the lobby reports it running");
    red.close();
    blue.close();
  }
} else if (phase === "back") {
  const t0 = Date.now();
  const vsAi = await createVsAi("easy");
  check(vsAi.status === 201 && vsAi.body?.team === 0, `with ai-bot back, a vs-AI room is created (${vsAi.status}, ${Date.now() - t0} ms)`);
  if (vsAi.status === 201) {
    const status = await api(base, "GET", `/api/lobby/v1/rooms/${vsAi.body.room_code}`);
    check(status.body?.status === "waiting" && status.body?.players?.[1]?.nickname === "AI (Easy)", "the bot already holds team 1");
    const human = wsPlayer(base, vsAi.body.match_id, vsAi.body.token);
    check(await waitFor(() => human.has("kickoff"), 20_000), "the human's connection kicks the match off at once");
    human.close();
  }
} else {
  console.log(`unknown phase ${phase}`);
  process.exit(2);
}
console.log(allPassed() ? `BOT CHECKS (${phase}) PASSED` : `BOT CHECKS (${phase}) FAILED`);
process.exit(allPassed() ? 0 : 1);
