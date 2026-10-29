# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Layout: Two Parallel Implementations

This repo contains two implementations of the same arcade 11v11 football game, side by side:

1. **Original C++/OpenGL build** — `src/`, `include/`, `Makefile`. Immediate-mode OpenGL + GLFW + miniaudio. Still buildable; treated as the reference/backup. Full architecture docs in `PROJECT_DOCUMENTATION.md`.
2. **Godot 3D port** — `scripts/` + `scenes/`. Where active development happens (branch `3d-version`). Plan and rationale in `GODOT_3D_PLAN.md`; realism is the priority (it is the bulk of the grade for this university project).

(The earlier Godot 2D port was removed once the 3D build superseded it.)

There are headless Godot test suites (`tests/run_sim_tests.gd`, `run_net_tests.gd`, `run_runtime_tests.gd`, `run_bot_tests.gd`, `run_online_smoke.gd`, `run_scene_smoke.gd`), pytest suites for the Python services, Playwright/Node e2e scripts in `tests/e2e/` (see Commands) and GitHub Actions CI (`.github/workflows/ci.yml`: all of the above, both exports, every image, the browser e2e flows; no secrets needed); no linter.

The game is an online two-player system: lobby, match runtime, results and recommendation services (plus the optional ai-bot) behind a Caddy gateway, deployed with Docker Compose. Milestones 0–6 are complete: the reusable `MatchSession` component, the bootstrap/export spike, the online vertical slice, the mandatory microservices (see "Online services" below), browser deployment (web tier, Play Online menu, CI, `docs/measurements.md`), the online AI bot (`docs/ai_bot.md`), and the documentation/demo. **`ARCHITECTURE_ONLINE.md`** is the reference (requirements matrix, diagrams, every contract, failure handling, security, limitations); keep it in step when a contract changes. **`docs/demo.md`** is the presentation runbook. Review notes: `MICROSERVICES_PLAN_REVIEW.md` (the user's untracked file: read it, don't edit or commit it).

## Commands

C++ build (Linux, needs `libglfw3-dev libgl1-mesa-dev`):

```bash
make            # builds ./InazumaElevenGL
./InazumaElevenGL
make clean
```

Godot project (Godot 4.7, pinned to 4.7.2; root `project.godot`, main scene `scenes/bootstrap.tscn`). On Linux the engine may be the snap `godot-4`; on this Windows machine there is no local Godot, so use the Docker toolchain below.

```bash
godot-4 --path .                                          # run interactively
godot-4 --headless --quit-after 5 --path .                # smoke-test: boots the scene, prints "Inazuma Eleven 3D environment ready"
godot-4 --headless --import --path .                      # full import + script compile (run after adding a class_name script)
godot-4 --headless --path . --script res://tests/run_sim_tests.gd   # rules/config/session tests (no 3D); exits non-zero on failure
godot-4 --headless --path . --script res://tests/run_net_tests.gd   # protocol, input queue, interpolation, runtime/rooms over loopback
godot-4 --headless --path . --script res://tests/run_runtime_tests.gd   # token vectors, control API, signed HELLO, terminal registry, result spool
godot-4 --headless --path . --script res://tests/run_bot_tests.gd   # BotBrain policy, bot job API, a bot plays a credentialed match over loopback
godot-4 --headless --path . --script res://tests/measure_bot_strength.gd   # seeded bot-vs-bot / bot-vs-AI strength per difficulty (docs/measurements.md)
godot-4 --headless --path . --script res://tests/run_online_smoke.gd   # runtime + two 3D games playing online in one process
godot-4 --headless --fixed-fps 60 --path . --script res://tests/run_scene_smoke.gd   # full offline AI match through the 3D controller
godot-4 --headless --path . -- --server                   # run the headless match runtime (8910 players, 8911 control API)
godot-4 --headless --path . -- --bot                      # run the ai-bot service (8920 job API; BOT_CONTROL_TOKEN)
```

Docker toolchain (`tools/godot/Dockerfile`, official binaries verified by SHA-512). From Git Bash:

```bash
docker build -f tools/godot/Dockerfile --target godot -t inazuma/godot:4.7.2 tools/godot
MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W):/project" inazuma/godot:4.7.2 --headless --path /project --script res://tests/run_sim_tests.gd
cp .env.example .env                                      # once: compose refuses to start without the secrets
docker compose up --build                                 # full stack; http://localhost:8080 (?netprobe checks the WebSocket path)
docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build   # debug runtime also accepting dev tokens: /?match=x&token=dev:0 and dev:1
docker compose -f services/docker-compose.test.yml run --rm --build lobby-tests     # pytest, throwaway PostgreSQL
docker compose -f services/docker-compose.test.yml run --rm --build results-tests
docker compose -f services/docker-compose.test.yml run --rm --build recommendation-tests   # no database (results faked)
docker compose -f services/docker-compose.test.yml down -v
python tests/vectors/generate_token_vectors.py            # regenerate the shared credential vectors (then rerun both suites)
bash tests/e2e/run.sh online_menu.mjs                     # stack running: two browsers drive the Play Online menu to full time + results
bash tests/e2e/run.sh measure.mjs label 20 [web|full]     # browser frame time, startup, snapshot traffic (docs/measurements.md)
bash tests/e2e/run_failure_checks.sh                      # stack running: results down at full time, runtime restart mid-match
bash tests/e2e/run_bot_checks.sh                          # stack running: a browser plays the AI from the menu; ai-bot stopped (vs-AI 503, PvP works) and restarted
bash tests/e2e/run.sh report_screens.mjs out              # stack running: the report's screenshots into tests/e2e/out/ (docs/relatorio/img/)
```

Desktop online play through the lobby: `godot-4 --path . -- --lobby=http://localhost:8080/api/lobby/v1`, then Play Online. Without the lobby: `-- --connect=ws://127.0.0.1:8910/ws/game/<id> --token=dev:<team>` against a runtime started with `DEV_NO_AUTH=1` (debug builds only; the release server never accepts dev tokens). Launch options are read by `LaunchArgs` (`-- --name=value` on desktop, `?name=value` on the web): `lobby`, `connect`/`token` (web: `match`/`token`), `quality=web|full`, `latency`. Browser e2e scripts in `tests/e2e/` (`netprobe.mjs`; `two_players.mjs` for the dev stack; `lobby_match.mjs` and `online_menu.mjs` for the full lobby → match → results flow; `vs_ai_menu.mjs` (+ `bot_checks.mjs` phases driven by `run_bot_checks.sh`) for vs-AI; `measure.mjs`) run through `tests/e2e/run.sh`, which uses the Playwright image inside the gateway's network namespace and keeps `node_modules` in a Docker volume (`inazuma-e2e-node-modules`). The scripts assume the project name `inazuma-online`; export `COMPOSE_PROJECT_NAME` for a stack under another name (e.g. a second checkout, so its `down -v` can't touch the main volumes). They click controls at the positions the game logs as `[ui] <page> <id>=x,y ...` (controls tagged with a `ui_id` meta, `MenuManager.log_layout`) and watch `[online] ...` lines. `tests/measure_latency.gd` measures input-to-visible delay with a headless desktop client through the gateway (see `docs/measurements.md` for the `tc netem` setup).

Running Godot in the Linux container rewrites `assets/*.import` with LF endings (content unchanged); `git checkout -- assets/` restores them from the index — **stage intentional asset edits first**, or that command discards them too. The built-in browser pane only advances Godot web frames while visible, so verify the web build with `tests/e2e/netprobe.mjs` (headless Chromium in the Playwright image).

## Online services (Milestones 3 and 5)

Three business services plus the optional ai-bot, each with its own entry point, image, tests and health interface; gateway (Caddy, `services/gateway/Caddyfile`) and PostgreSQL (`services/postgres/init/` creates separate `lobby`/`results` databases and roles) are infrastructure. Only the gateway publishes ports.

- **lobby** (`services/lobby`, FastAPI + psycopg 3): room codes, guest player ids, reservations, provisioning records. Public via `/api/lobby/v1/...` (prefix stripped): `POST /rooms`, `POST /rooms/{code}/join`, `GET /rooms/{code}`. Provisions the runtime *before* issuing a credential; idempotent by `request_id`; status reconciled from the runtime (`service.py`, `reconcile.py` document the rules).
- **match runtime** (Godot, `scripts/server/`): verifies credentials locally on HELLO, owns live matches, the terminal registry and the result spool (`/data` volume). Unchanged by the bot: a bot is just a remote player.
- **ai-bot** (Godot, `scripts/bot/`, same Linux Server export started with `--bot`; Dockerfile target `ai-bot`): internal job API on 8920 (bearer `BOT_CONTROL_TOKEN`): `POST /internal/v1/bots {match_id, token, ws_url, difficulty}` idempotent by match_id, `GET`/`DELETE /internal/v1/bots/{match_id}` (`accepted → joined → playing → stopped | failed`), `GET /health`; at most `BOT_MAX_SESSIONS` (8) live sessions, 10 s join deadline. Not a dependency of anything: stopped, only vs-AI creation fails.
- **vs-AI rooms**: lobby `POST /rooms {mode: "vs_ai", difficulty: easy|normal|hard}` provisions with `team_difficulty[1]` at that level, reserves team 1 for the bot (stable guest id per difficulty, nickname `AI (Hard)` etc., `bot_client.bot_player`), signs its credential, submits the job with the internal `BOT_RUNTIME_WS_URL` (`ws://match-runtime:8910`) and answers only once the job is `joined`; any bot failure stops the job, cancels the runtime match, deletes the room and answers 503 `bot_unavailable`. Reconciliation cancels a waiting vs-AI room whose job is gone. The bot is ranked on the leaderboard like a guest.
- **recommendation** (`services/recommendation`, FastAPI, no database): football-Elo ratings over the counted history it reads from results' public `GET /v1/matches/recent` (in-memory read model: incremental every 10 s, full every 5 min, stale model served while results is down); public `/api/recommendations/v1/recommendations?player_id=` (recommended AI level = expected score closest to 0.6, up to 3 rivals) and `/ratings`. `engine.py` is pure (algorithm), `model.py` the sync policy; bot ids duplicate the lobby's uuid5 derivation (`bots.py`, pinned by a test). Optional: down, the game hides the panel.
- **Gateway status**: `GET /api/status/v1/<gateway|lobby|match-runtime|ai-bot|results|recommendation>` probes that service's `/health` and answers only up (200) / down (503); `ServiceStatusPanel` (`scripts/systems/`) shows it on the main menu (compact strip) and beside the Play Online pages (highlighting the services each action uses).
- **results** (`services/results`, FastAPI + psycopg 3): `POST /internal/v1/matches` (bearer `RESULTS_INGEST_TOKEN`, idempotent by match_id: identical → 200, conflicting → 409); public `/api/stats/v1/matches/recent` and `/api/stats/v1/leaderboard` (3/1/0, then goal difference, then goals for; keyset cursors).

Credentials: claims `{v, match_id, reservation_id, team, player_id, aud: "match-ws", exp}` in a fixed little-endian byte layout, HMAC-SHA256 with `MATCH_SECRET`, `base64url(payload).base64url(sig)` (see `credentials.py`). Secrets come from `.env` (`.env.example` documents them); `DEV_NO_AUTH` is only ever set by `docker-compose.dev.yml`. Runtime capacity: `RUNTIME_MAX_CONNECTIONS`, `RUNTIME_MAX_ROOMS`. The gateway healthcheck hits an internal `127.0.0.1:8081/healthz` listener (works when `SITE_ADDRESS` is a domain and :80 only redirects); every container's json-file log is rotated (5 x 10 MB). Single-VPS deployment, backups and upgrades: README "Deploying on one VPS". Python logs are one JSON object per line, like the runtime's `MatchRuntime.log_event`.

## Godot 3D Architecture (the big picture)

**Process roles.** `scenes/bootstrap.tscn` (`scripts/bootstrap.gd`) is the main scene and dispatches by role:
- `-- --bot` loads `scenes/bot.tscn`: the ai-bot service (`scripts/bot/bot_main.gd` → `BotService`). Checked first, since it shares the dedicated-server export with the runtime.
- `-- --server`, or a `dedicated_server` export, loads `scenes/server.tscn`: the headless match runtime in `scripts/server/`.
- `?netprobe` on the web loads `scenes/net_probe.tscn`.
- Otherwise it loads `scenes/main_3d.tscn`, the game.

Export presets: `Web` (single-threaded, Compatibility) and `Linux Server` (dedicated server, visuals stripped, `assets/` removed).

**Procedural scene, modular code.** `scenes/main_3d.tscn` is a single `Node3D` with `scripts/match_controller_3d.gd` attached; the entire scene — pitch, goals, stadium, crowd, lights, environment, players, ball, UI — is built procedurally at runtime, not authored in the `.tscn`. The controller is a thin **orchestrator** and the *offline adapter* around `MatchSession`. `_physics_process` reads local input, calls `session.step()`, then dispatches `session.drain_events()` to the view, HUD and audio. `_process()` drives the view. To change visuals or gameplay, edit the relevant module script, not the scene.

Code is organized by responsibility under `scripts/`:

- `match/` — the reusable match component, shared by the offline controller and the online runtime:
  - `MatchConfig` holds the immutable gameplay rules of one match: half length, formations, kit palette indices, per-team AI difficulty profile, fouls/offside and weather. `to_dict`/`from_dict` give a validated wire form.
  - `MatchSession` owns `MatchSimulation` + `AIController`. API: `initialize(config, seed)`, `submit_input`, `step(real_dt)`, `read_state`, `drain_events`. It owns the match clock, halves, goal freeze, half-time pause and the per-session slow-motion `time_scale`.
- `net/` — client side of the wire protocol:
  - `NetProtocol` defines protocol v1: binary, little-endian and quantized, with HELLO/WELCOME/INPUT/SNAPSHOT/EVENT/PING/PONG/ERROR messages. Its decoders reject anything malformed.
  - `NetClient` connects and sends HELLO, then turns local `InputSnapshot` edges into numbered actions. Counts traffic per message type (`rx_stats`/`tx_stats`).
  - `LobbyClient` (a Node with one `HTTPRequest`) calls the lobby's public API, the stats reads and the recommendation read (`OnlineMenu` keeps a second instance, `reads`, for background reads so Create/Join never get "busy"); coroutines returning `{ok, status, error, message, body}`; same-origin on the web, `--lobby=` on desktop; derives the `ws(s)://` match URL from the lobby origin; reuses `request_id` after retryable failures.
  - `LatencyProbe` (enabled by `latency`) logs `[latency] input_to_visible_ms=...`.
  - `SnapshotBuffer` renders about 100 ms behind the server. It interpolates continuous fields, snaps across state epochs, releases events at their tick, and `apply_to()` writes into a never-stepped mirror `MatchSimulation`.
- `ai/tactics.gd` (`Tactics`) — static, pure, read-only tactical queries (pass target, dribble lane, shot target, run target, marking, presser, offside line) shared by `AIController` (which wraps them, binding the live ball and `sim.rng` for aim noise) and `BotBrain`. Never draws random numbers.
- `bot/` — the ai-bot service:
  - `BotService` (Node) hosts the jobs: `submit` / `stop_job`, capacity, retention of finished jobs; polls the job API and sessions in `_process`, ticks sessions in `_physics_process`. `BotJobApi` holds the routes on a `ControlServer`.
  - `BotSession` is one bot in one match: a `NetClient` with the bot's credential, a never-stepped mirror `MatchSession` rebuilt from `latest_snapshot` (`observe()` also switches ends when the half changes and copies stun/tackle flags), the job state machine, reconnect with backoff inside the runtime's grace, and the sampled `bot_decision` JSON log.
  - `BotBrain` is the input-level policy (an autonomous agent: goal, observation, decide/act loop, documented in `docs/ai_bot.md`): per think interval it picks shoot / pass / dribble, close down / tackle / switch, or chase, and returns an `InputSnapshot` every tick. `PROFILES` holds the difficulty parameters; randomness only from its own seeded `rng`.
- `server/` — the authoritative runtime:
  - `MatchRuntime` is the WebSocket listener. It enforces handshake/HELLO deadlines, size and connection limits and backpressure, authenticates HELLO, and ticks rooms in `_physics_process`.
  - `MatchRoom` runs one match. Its states are WAITING → RUNNING ⇄ PAUSED (per absent team: 30 s reconnect grace per absence, 60 s total per match, then forfeit) → FINISHED. It sends snapshots every 2 ticks, and resets bump `state_epoch` and are flagged as discontinuities.
  - `RemoteInputQueue` sets the server-side input semantics: one action per kind per tick, strict id order, the shot charge measured by the server, neutral input after 250 ms of silence, and a reset on reconnect.
  - `RuntimeControlApi` (routes) on `ControlServer` (bounded nonblocking HTTP/1.1: 8 KB, 2 s deadline, 16 connections) is the internal control API the lobby uses: idempotent `PUT /internal/v1/matches/{id}` (MatchConfig + credential expiry) and `.../reservations/{team}`, `GET` status with `boot_id`, `DELETE` cancel, `GET /health`. Polled in `_process`, never in the physics tick.
  - `TerminalRegistry` persists finished/cancelled match ids under `RUNTIME_DATA_DIR` until their credentials expire; `ResultSpool` writes each finished result atomically before the room is freed and POSTs it to the results service with capped backoff (409/400/422 → `spool/rejected/`).
  - `MatchToken` (`net/`) verifies the lobby's signed credentials; `services/lobby/app/credentials.py` is the Python twin, kept byte-identical by `tests/vectors/token_vectors.json`.
- The controller's *online adapter* (`start_online`, `--connect=`/`--token=` launch args or web `?match=&token=`) mirrors the runtime's match: it sends input, applies interpolated snapshots to `session.sim`, and dispatches runtime events through the same `_dispatch_event` as offline.
- `config/game_config.gd` (`GameConfig`) — field geometry constants, GLB/animation constants, the `PlayerRole` and `GameState` enums (`ONLINE` = the Play Online screens), `MATCH_LENGTHS`, and the `to_3d()` coordinate helper. Shared by every module as `GameConfig.X`. `config/launch_args.gd` (`LaunchArgs`) reads launch options; `config/render_tier.gd` (`RenderTier`) picks FULL (Forward+) or WEB (Compatibility) once at start-up.
- `data/` — plain state classes: `PlayerState`, `BallState`, `InputSnapshot`, `TeamState` (players + device/formation/kit + human selection state; `sim.teams[0]`=red, `[1]`=blue).
- `build/` — one-shot scene construction: `MaterialFactory` (materials + procedural textures, including the grass, crowd and ball-trail decal textures), `PitchBuilder` (pitch, lines, goals), `StadiumBuilder` (night environment + post-processing — ACES, glow, SSAO, SSIL, volumetric fog; broadcast camera; moon fill + four corner floodlight masts; VoxelGI bake; stands; the animated 3D MultiMesh crowd; hoardings), `PlayerFactory` (GLB load, animation library, player visuals, team tint). `StadiumBuilder.web_tier` (set from `RenderTier`) skips SSAO/SSIL/volumetric fog/VoxelGI on Compatibility and compensates with ambient, depth fog and glow, two shadowed floodlights and a thinner crowd; the FULL path must stay unchanged (realism is graded).
- `systems/` — runtime subsystems: `AudioManager`, `SettingsStore` (local preferences — camera/audio/window, plus the rule preferences that seed an *offline* `MatchConfig` — load/save + input actions), `MenuManager` (also owns `OnlineMenu`: Play Online home with create / join / Play vs AI (online) + AI level / waiting room with the code / recent matches + leaderboard), `MatchSetup` (pre-match screen that assigns each device — keyboard+mouse, each pad — to RED/BLUE/AI), `MatchHud` (broadcast-style score panel), `InputReader`, `AIController`, `MatchSimulation` (gameplay state + per-frame `step`), `MatchView` (per-frame node updates: players, ball, camera, VFX, and the ball's fading grass-trail decals).

**2.5D gameplay model.** Game logic runs in normalized 2D coordinates inherited from the C++ version: `x ∈ ±0.98`, `y ∈ ±0.78` (playable boundary `±0.93 / ±0.73`), with all state in the plain `data/` classes — no physics engine, no CharacterBody/RigidBody. Visuals convert via `GameConfig.to_3d(p: Vector2)`: world = `(x * FIELD_SCALE, height, -y * FIELD_SCALE)` with `FIELD_SCALE = 24.0`. Note the sign flip: 2D `+y` is 3D `-z`.

The ball also carries a simple vertical flight model on top of the 2D plane: `ball.h` / `ball.vh` in **world units** (gravity, damped bounce, `Magnus` curve via `ball.curve`). Shots arc with charge, the crossbar (`GameConfig.GOAL_HEIGHT`) denies high balls, and players can only capture below their reach height (`CAPTURE_MAX_HEIGHT`, keeper `GK_REACH_HEIGHT`).

**Module boundaries:**
- `MatchSimulation` owns all gameplay state and never touches view, audio or scene nodes. It emits signals (`goal_scored`, `ball_kicked`, `special_fired`, `field_reset`, `restart_awarded`, `foul_committed`, `offside_called`, `player_action`) that `MatchSession` turns into queued events.
- Animation cues are `player_action` events. The controller calls `PlayerState.play_action`, and rebuilds player visuals (`_rebuild_player_visuals`) after each `session.initialize`.
- Rules read `sim.config` (a `MatchConfig`), never `SettingsStore`.
- All gameplay randomness uses `sim.rng` (seeded by `MatchSession.initialize`), never the global `randf`/`randi`.
- `Engine.time_scale` stays 1. Slow motion is `session.time_scale`, and the view scales its own delta and animation speed by it. Cross-module public methods have no underscore prefix; `_underscore` methods are module-internal. All feel-critical tuning numbers live in the "Gameplay tuning" section of `GameConfig`.

**Conventions in the logic:**
- Red team (`teams[0]`) `side = -1`, starts on `-x`, attacks `+x`; blue (`teams[1]`) `side = +1` attacks `-x`. Defaults: red on keyboard+mouse, blue full AI (the setup screen reassigns devices).
- Ball possession is `ball.owner_team` / `ball.owner_index` (`-1` = loose ball); while owned, the ball is glued to the owner's feet and physics is skipped. After both team updates, `_resolve_ball_capture` gives the ball to the globally nearest eligible player: loose balls on contact, steals only during a live tackle window (`PlayerState.tackle_timer`; a whiffed tackle self-stuns).
- When the ball leaves play it does not bounce: `_award_restart` grants a throw-in / corner / goal kick against `ball.last_touch_team`, placing the taker at the spot behind a short freeze (`restart_timer` / `restart_type`, which also implement kickoff).
- Player roles drive formation targets, AI behavior and speed (`GameConfig.ROLE_SPEED`). Sprinting (`SPRINT_*`) drains `PlayerState.stamina`; the AI presser sprints under the same rules.
- Gameplay steps in `_physics_process` (fixed tick); `MatchView`/HUD update in `_process`. Per-tick flow (`MatchSession.step`): slow-mo countdown (real time) → phase (half-time pause / goal freeze / playing) → `MatchSimulation.step(dt * time_scale)`, which runs restart timer → ball physics/goal detection → team 0 update → team 1 update → capture resolution → then the match clock.
- AI random decisions (shoot/pass/tackle chances) must be scaled by `delta` to stay frame-rate independent, and drawn from `sim.rng`. Each team's AI intelligence comes from `sim.config.ai_profile(team)` (a human-led team's AI teammates play at Normal). The keeper reacts to inbound shots after a difficulty-based delay (`GK_REACTION`) and then chases the predicted intercept point.

**Controls:** WASD moves the selected player, hold/release Space charges/releases a shot, mouse aims (ray-cast onto the ground plane), E passes, Q switches player, Ctrl or right-click tackles, Shift sprints. Pad: R1 shoot, A pass, L1 switch, X tackle, R2 sprint. Online, the last-used local device (keyboard+mouse or any pad) drives our team (`_note_input_device` in the controller); Esc leaves an online match. Input actions are registered in code in `SettingsStore`, not in `project.godot`.

The C++ version mirrors this layout across `src/game_logic.cpp`, `src/player.cpp`, `src/ball.cpp` (see `PROJECT_DOCUMENTATION.md` §10 for the file map).
