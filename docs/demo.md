# Demo runbook (Milestone 6)

A step-by-step script for presenting the online system from a fresh checkout. It covers
the build, a PvP match in two browsers, results and the leaderboard, a match against the
AI bot, the two service-failure recoveries, the bot's decision log, the offline game and
the test suites. Each step lists what to type, what you should see and roughly how
long it takes. The architecture behind every step is in
[`ARCHITECTURE_ONLINE.md`](../ARCHITECTURE_ONLINE.md).

Commands are for **Git Bash** on Windows or any Linux/macOS shell, run from the repository
root. Timings were measured on the development machine (Windows 11, Docker Desktop on
WSL 2, 16 logical CPUs, 16 GB).

| Step | What it shows | Time |
| --- | --- | --- |
| 0 | Prerequisites | once |
| 1 | Fresh checkout and secrets | 1 min |
| 2 | Build and start the stack | 10-15 min the first time, under 1 min after |
| 3 | PvP: two browsers create, join and play | 2-3 min |
| 4 | Result and leaderboard | 1 min |
| 5 | Versus the AI | 2 min |
| 6 | Results service down: the spool recovers | 3-4 min |
| 7 | Runtime restart: the match is `aborted` | 2 min |
| 8 | The bot's decision log | 1 min |
| 9 | The offline game still works | 2 min |
| 10 | Test suites | 5-25 min, depending on how many you run |

For a short live presentation, do steps 3-5 and 8-9 live and play the recordings or the
scripted checks (`tests/e2e/run_failure_checks.sh`) for steps 6-7.

## 0. Prerequisites

- **Docker** with the Compose v2 plugin (Docker Desktop on Windows/macOS, Docker Engine
  on Linux). Allow about 10 GB of disk: the Playwright image used by the browser
  checks alone is 3.5 GB.
- **Git**, and on Windows **Git Bash** (it ships `openssl`).
- **Two browser profiles** for the PvP demo: a normal and a private window, or two
  different browsers. Two tabs in one profile share the saved guest identity, and a
  match between one guest and itself is not recorded (section "If something goes
  wrong").
- Free host ports **8080** and **8443** (or set `GATEWAY_HTTP_PORT` / `GATEWAY_HTTPS_PORT`
  in `.env`).
- No local Godot is needed: the game and the tests run in containers.

## 1. Fresh checkout and secrets

```bash
git clone <repository-url> inazuma && cd inazuma
git checkout 3d-version
{
  echo "MATCH_SECRET=$(openssl rand -hex 32)"
  echo "RUNTIME_CONTROL_TOKEN=$(openssl rand -hex 32)"
  echo "RESULTS_INGEST_TOKEN=$(openssl rand -hex 32)"
  echo "BOT_CONTROL_TOKEN=$(openssl rand -hex 32)"
  echo "POSTGRES_PASSWORD=$(openssl rand -hex 16)"
  echo "LOBBY_DB_PASSWORD=$(openssl rand -hex 16)"
  echo "RESULTS_DB_PASSWORD=$(openssl rand -hex 16)"
} > .env
```

This writes the seven secrets that `.env.example` documents, with fresh random values.
Compose refuses to start while any of them is missing. `.env` is ignored by git and
excluded from the Docker build context. (Without `openssl`, use
`python -c "import secrets; print(secrets.token_hex(32))"` for each value.)

**Expected:** `.env` has 7 lines; `git status` shows nothing to commit.

## 2. Build and start the stack

```bash
docker compose up --build -d --wait
docker compose ps
```

The first build downloads the pinned Godot 4.7.2 binary and export templates (checked
against their SHA-512 sums), imports the project once, and runs both exports: the Web
build for the gateway and the Linux Server build for the runtime and the bot. Later
runs reuse the cache. `--wait` returns once every service is healthy. Without `-d`,
`docker compose up --build` stays in the foreground and streams every service's JSON
logs.

**Expected:** `docker compose ps` lists six containers, all `Up ... (healthy)`:
`gateway` (ports `0.0.0.0:8080->80`, `0.0.0.0:8443->443`), `lobby`, `match-runtime`,
`results`, `ai-bot` and `postgres`. Only the gateway shows ports.

Optional check of the browser -> gateway -> runtime path: open
`http://localhost:8080/?netprobe` (or run `bash tests/e2e/run.sh netprobe.mjs`).

## 3. PvP: two browsers create, join and play

1. **Window A** (normal): open `http://localhost:8080`. The stadium loads (a few seconds
   with a GPU; software-rendered browsers are much slower) and the main menu shows
   **Play Now, Play Online, How to Play, Settings, Quit**.
2. A: **Play Online**. Type a nickname (e.g. `Ana`), pick **30 s** half length and click
   **Create Room**. The waiting page shows **ROOM CODE** and a six-character code such as
   `K7QF3M`, with "Waiting for opponent...".
3. **Window B** (private window or another browser): open `http://localhost:8080`,
   **Play Online**, nickname `Bia`, type the code, **Join Room**.
4. Both windows enter the match: **KICK OFF**, then play. Window A is the red team (TIME
   A), B the blue team. Controls: WASD to move, mouse to aim, hold and
   release Space to shoot, E to pass, Q to switch, Ctrl or right-click to tackle, Shift
   to sprint.
5. Things worth pointing out while playing:
   - the score, the clock and the goal celebration (**GOAL!**) agree in both windows,
     because the runtime is the only authority;
   - a fully charged shot near goal shows a special-shot banner (e.g. **FIRE TORNADO!**)
     with a brief slow motion in both windows;
   - press `Esc` in B: A shows **OPPONENT DISCONNECTED - WAITING 30s**. Leaving for good
     ends the match after 30 s by **FORFEIT** (A wins). Skip this if you want a normal
     full-time result.
6. After two 30 s halves (about 70 s including the goal freezes and the half-time
   pause), both windows show **FULL TIME** with the score, the winner and the stats
   (possession, shots, on target, steals, fouls, offsides), plus **New Online Match**
   and **Back to Menu**.

Unhappy paths you can show on the Join screen: a wrong code gives "No room with that
code.", and joining a room that is full or already finished gives "That room is full." /
"That room is no longer open."

The same flow is automated (two headless Chromium pages that drive only the menu):

```bash
bash tests/e2e/run.sh online_menu.mjs     # about 3-4 min; ends "E2E ONLINE MENU PASSED"
```

## 4. Result and leaderboard

- In either window: **Back to Menu** -> **Play Online** -> **Recent Matches &
  Leaderboard**. The match is at the top of RECENT MATCHES (`Ana 1 - 0 Bia`, for
  example), and both guests are in the LEADERBOARD with 3 / 0 points for a win, or 1 / 1
  for a draw.
- The same data from the public API (the lobby's status is reconciled from the runtime
  on each read):

  ```bash
  curl -s http://localhost:8080/api/lobby/v1/rooms/K7QF3M      # "status":"completed"
  curl -s "http://localhost:8080/api/stats/v1/matches/recent?limit=3"
  curl -s http://localhost:8080/api/stats/v1/leaderboard
  ```

- The internal APIs are not reachable from outside: `curl -i
  http://localhost:8080/api/internal/v1/matches` answers `404 {"error":"not_found"}`.

## 5. Versus the AI

1. In one window: **Play Online**, choose **AI level: Hard** and **30 s**, then **Play
   vs AI (online)**. There is no room code and no waiting page: the lobby answers only
   once the ai-bot has joined team 1, and the match kicks off as soon as you connect
   (about 1-2 s after the click).
2. Play to full time. The bot moves, presses, tackles from the front and shoots; its
   ten team-mates are the runtime's own AI at the same level.
3. **Recent Matches & Leaderboard** lists the match against `AI (Hard)`. The bot is
   ranked like any guest, with one row per difficulty.

Automated: `bash tests/e2e/run.sh vs_ai_menu.mjs` (about 2 min).

## 6. Results service down: the spool recovers

Gameplay never waits for the results service. Each result is written to the runtime's
durable spool before the room is freed and delivered in the background.

```bash
docker compose stop results
```

1. Play a PvP match (step 3, 30 s halves) or a vs-AI match (step 5) to full time. The
   game is unaffected and shows FULL TIME. **Recent Matches & Leaderboard** now
   shows "The match server is unavailable. Try again in a moment." (the gateway
   answers 502 for the stats routes); that is expected.
2. The result is waiting on the runtime's volume:

   ```bash
   docker compose exec match-runtime ls /data/spool        # <match_id>.json  rejected
   docker compose logs match-runtime | grep -E 'result_spooled|result_delivery_failed' | tail -3
   ```

   `result_delivery_failed` lines show the retry delay doubling (1 s, 2 s, 4 s ... up to
   60 s).
3. Bring the service back:

   ```bash
   docker compose start results
   ```

   Within one retry interval (at most about 75 s), `docker compose logs match-runtime |
   grep result_delivered` shows the delivery, `ls /data/spool` shows only `rejected`,
   and the match appears exactly once in Recent Matches.

## 7. Runtime restart: the match is `aborted`

1. Start a PvP match (step 3) and note the room code.
2. During play:

   ```bash
   docker compose restart match-runtime
   ```

3. Both windows show **CONNECTION CLOSED** right away. After about 15 s the runtime is
   healthy again (`docker compose ps`).
4. The lobby notices the new `boot_id` and the unknown match:

   ```bash
   curl -s http://localhost:8080/api/lobby/v1/rooms/<CODE>    # "status":"aborted"
   ```

   While the runtime is still restarting it reports `"status":"unavailable"`. The match
   is never silently recreated: the old credential is refused (close 4404), and joining
   the room gives 409. Results already in the spool are delivered after the restart.

Steps 6 and 7 together are automated, with assertions, by
`bash tests/e2e/run_failure_checks.sh`, which ends with `FAILURE CHECKS PASSED`
(about 4 min).

## 8. The bot's decision log

The bot logs each state change and a sampled line for its decisions (at most one every
500 ms):

```bash
docker compose logs --no-color ai-bot | grep bot_decision | tail -5
```

Expected, one JSON object per line (prefixed with `ai-bot-1  | `):

```json
{"svc":"ai-bot","event":"bot_decision","match_id":"...","team":1,"difficulty":"hard","match_time":41.2,"half":1,
 "score":[0,1],"intent":"attack","action":"shoot","reason":"in range and facing goal","player":9,
 "features":{"dist_goal":0.41,"facing":0.93,"nearest_opp":0.21,"power":0.84,"aim":[-0.93,-0.07]},"unlogged":3}
```

Point out the agent loop. `features` is what the bot observed, `intent` and `action`
are what it decided, and `reason` explains why. `docker compose logs ai-bot | grep -E
'bot_state|bot_match_over'` shows the job lifecycle (`joined`, `playing`, `stopped`) and
the action counters. On PowerShell, use `| Select-String bot_decision` instead of `grep`.

Then show that the AI is optional:

```bash
bash tests/e2e/run_bot_checks.sh    # about 3 min; ends "BOT CHECKS PASSED"
```

It plays a vs-AI match from the menu, then stops `ai-bot`. vs-AI creation now fails
cleanly with `503 bot_unavailable` while a PvP room still creates, joins and kicks off.
Finally it starts `ai-bot` again, and vs-AI works again. By hand: `docker compose stop
ai-bot`, and **Play vs AI (online)** says "The AI opponent is unavailable right now. Try
again, or play a friend." while Create Room still works.

## 9. The offline game still works

The offline game runs the same `MatchSession` locally, with no services involved:

1. Stop the services (the gateway keeps serving the static web build):

   ```bash
   docker compose stop lobby match-runtime results ai-bot
   ```

2. In a browser window: **Play Now**. On the setup screen, move your chip to TIME A or
   TIME B (A / D, or a pad), and an empty side is the AI. Press Space to kick off and
   play a local match against the AI. Two devices (keyboard + a pad) give local 2P.
3. Restart the services: `docker compose start lobby match-runtime results ai-bot`.

With a local Godot 4.7 editor, `godot-4 --path .` runs the same game as a desktop app
(Forward+ renderer, full visual tier).

## 10. Test suites

Godot suites run in the pinned toolchain image (Git Bash shown; on Linux/macOS drop
`MSYS_NO_PATHCONV=1` and use `$(pwd)`):

```bash
docker build -f tools/godot/Dockerfile --target godot -t inazuma/godot:4.7.2 tools/godot
export MSYS_NO_PATHCONV=1
G() { docker run --rm -v "$(pwd -W 2>/dev/null || pwd):/project" inazuma/godot:4.7.2 --headless --path /project "$@"; }
G --import                                            # once per fresh checkout (compiles every script)
G --script res://tests/run_sim_tests.gd               # rules, config, session
G --script res://tests/run_net_tests.gd               # protocol, input queue, runtime over loopback
G --script res://tests/run_runtime_tests.gd           # credentials, control API, spool, registry
G --script res://tests/run_bot_tests.gd               # AI bot policy, job API, bot plays a match
G --script res://tests/run_online_smoke.gd            # runtime + two 3D games online
G --fixed-fps 60 --script res://tests/run_scene_smoke.gd   # a full offline match in the 3D scene
git checkout -- assets/                               # undo the LF rewrite of assets/*.import (Windows)
```

Each suite prints `PASS` / `FAIL` lines and exits non-zero on failure. `run_sim_tests`
takes a few seconds, the two smoke tests a few minutes.

Service suites (pytest against a throwaway PostgreSQL) and the credential vectors:

```bash
docker compose -f services/docker-compose.test.yml run --rm --build lobby-tests
docker compose -f services/docker-compose.test.yml run --rm --build results-tests
docker compose -f services/docker-compose.test.yml down -v
python tests/vectors/generate_token_vectors.py && git diff --exit-code tests/vectors
```

Browser and service checks against the running stack: `tests/e2e/run.sh` with
`online_menu.mjs`, `lobby_match.mjs`, `vs_ai_menu.mjs` or `netprobe.mjs`, plus
`run_failure_checks.sh` and `run_bot_checks.sh` (all described above). CI
(`.github/workflows/ci.yml`) runs all of this on every push except
`run_failure_checks.sh`.

**Clean up** after the demo:

```bash
docker compose down -v                       # stops the stack and deletes its volumes (all data)
docker volume rm inazuma-e2e-node-modules    # the Playwright scripts' node_modules
```

## If something goes wrong

| Symptom | Cause and fix |
| --- | --- |
| `docker compose up` stops with `set MATCH_SECRET in .env` | `.env` is missing or incomplete: redo step 1. |
| `lobby` or `results` never becomes healthy; their logs show `password authentication failed` | The `postgres-data` volume was created earlier with other passwords; PostgreSQL applies them only on first start. Restore the old `.env`, or drop the old data with `docker compose down -v` and start again. |
| `bind: address already in use` on 8080 / 8443 | Set `GATEWAY_HTTP_PORT` / `GATEWAY_HTTPS_PORT` in `.env`, then open that port. The e2e scripts don't depend on the host port. |
| The page stays black, or runs at a few frames per second | The browser has no GPU acceleration (software WebGL). Use a desktop browser with hardware acceleration. `?quality=web` forces the light visual tier. |
| The page doesn't start when opened by IP or host name from another machine | Godot's web build needs a secure context: use `http://localhost` locally, or set `SITE_ADDRESS` to a real domain for HTTPS. |
| "Play vs AI" says the AI opponent is unavailable | `docker compose ps ai-bot`; `docker compose start ai-bot`; check `docker compose logs ai-bot`. PvP is unaffected. |
| The match doesn't appear in Recent Matches | The results service may be down: the result waits in the spool (step 6). If `/data/spool/rejected/` holds it, results refused it: `docker compose logs match-runtime \| grep result_rejected`. The usual cause is both windows using the same browser profile, so both teams were the same guest; use a private window for B. |
| `No such container: inazuma-online-gateway-1` from an e2e script | The stack isn't running, or was started under another project name: start it, or export `COMPOSE_PROJECT_NAME=<name>` for the scripts. |
| Git Bash mangles `/project` or `/data` paths | Prefix the command with `MSYS_NO_PATHCONV=1` (the e2e scripts already do). |
| `git status` shows many modified `assets/*.import` after running Godot in Docker | Only the line endings changed: `git checkout -- assets/` (stage intentional asset edits first). |
| A browser e2e step times out on a slow machine | Software WebGL renders about one frame a second in headless Chromium; rerun, and close other heavy containers. |
