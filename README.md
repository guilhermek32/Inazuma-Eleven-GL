# Inazuma Eleven GL

An arcade 11-v-11 football game inspired by *Inazuma Eleven*. The active project is a
**Godot 4.7 3D build** with a night-stadium broadcast presentation; the original
C++/OpenGL build remains in the repo as a legacy reference.

> For the full technical write-up — runtime flow, module map, and how each grading
> criterion is implemented — see **[`AS_BUILT.md`](AS_BUILT.md)**. The online system
> (requirements matrix, service and component diagrams, every contract, failure handling)
> is documented in **[`ARCHITECTURE_ONLINE.md`](ARCHITECTURE_ONLINE.md)**, and
> **[`docs/demo.md`](docs/demo.md)** is the step-by-step demo runbook.

---

## The active build (Godot 3D)

- 11-v-11 match with a user team (red) and a full-AI team (blue), in a 4-3-3 formation.
- Night stadium: broadcast camera, four floodlight masts, a moon fill light, baked
  global illumination, ACES tonemapping, bloom, SSAO/SSIL and volumetric fog (a lighter
  web tier on the browser's Compatibility renderer, see "Online play").
- Online two-player matches from the in-game **Play Online** menu (room codes), run on an
  authoritative match server behind a lobby and a results service.
- Animated GLB players (Mixamo-rigged) with idle / run / kick / receive / tackle clips
  and per-team kit tinting; a procedural box-figure fallback if a model fails to load.
- Ball possession, passing, tackling, charged shots, special-shot glow, goal detection,
  kickoff countdown, two halves with end-switching, and a full-time result.
- A dense 3D crowd (MultiMesh), neon hoardings, broadcast HUD, menus, and a pre-match
  screen that assigns each input device to a side.
- Procedural textures and PBR materials throughout (grass, metal goals, clearcoat ball,
  subsurface skin), plus VFX: ball spin, a fading pressed-turf trail, and goal confetti.

### Run it

The engine is Godot **4.7** (pinned to 4.7.2; `godot-4` below is any 4.7 editor binary):

```bash
godot-4 --path .                              # run interactively
godot-4 --headless --quit-after 5 --path .    # smoke test (prints "...environment ready")
```

No local Godot? The pinned, checksum-verified engine runs in Docker
(`tools/godot/Dockerfile`); see **Tests** below.

The project's main scene is `scenes/bootstrap.tscn`, which picks the process role
(3D game, `-- --server` match runtime, or `?netprobe` on the web) and then loads
`scenes/main_3d.tscn` for the game. The entire scene — pitch, stadium, lights,
players, ball and UI — is built **procedurally in code** at runtime, not authored in the
`.tscn`; the scene is just a `Node3D` with `scripts/match_controller_3d.gd` attached.

### Controls

| Action | Keyboard + mouse | Gamepad |
| --- | --- | --- |
| Move | `W` `A` `S` `D` | Left stick |
| Aim | Mouse | Right stick |
| Shoot | Hold `SPACE` to charge, release to kick | Hold `R1`/`RB`, release |
| Pass | `E` | `A` |
| Switch player | `Q` | `L1`/`LB` |
| Tackle (win the ball) | `Ctrl` or right-click | `X` |
| Sprint | `Shift` (drains stamina) | `R2`/`RT` |
| Pause / back | `Esc` | `Start` |

You always control the player nearest the ball; while your team has possession, control
locks to the ball carrier (FIFA-style). Release a fully charged shot from close range to
trigger a special shot. A tackle only wins the ball: time it from the front or side,
because a tackle from behind is a foul and gives the other team a free kick (fouls are on
by default and always online; Settings can switch them off for offline arcade play).

**Pre-match ("Play Now"):** each device (keyboard+mouse and every connected pad) gets a
chip in the middle column. Move your own chip to **RED** (left) or **BLUE** (right) with
your device; one device per side, an empty side is the AI. Press `Start`/`Space` to kick
off. This supports 1-player-vs-AI and 2-player local versus.

---

## Architecture at a glance

Gameplay runs as a **2.5D model**: all logic lives in a normalized 2D field
(`x ∈ ±0.98`, `y ∈ ±0.78`) with no physics engine, and `GameConfig.to_3d()` projects it
into the 3D world (`FIELD_SCALE = 24`). `match_controller_3d.gd` is a thin **orchestrator** and the offline adapter around
`MatchSession`, the reusable match component that the online match runtime also drives.

```
scripts/
  bootstrap.gd                # process entry: game / match runtime / bot / net probe
  match_controller_3d.gd      # offline adapter: devices -> MatchSession -> view/HUD/audio
  match/                      # the reusable match component
    match_config.gd           #   immutable gameplay rules of one match (wire-serializable)
    match_session.gd          #   clock, halves, goal freeze, slow-mo, events around the sim
  server/                     # headless match runtime: listener, rooms, remote input queue
  ai/tactics.gd               # read-only tactical queries shared by the in-sim AI and the bot
  bot/                        # ai-bot service: job API, bot sessions, BotBrain input policy
  net/                        # wire protocol, network client, snapshot interpolation,
                              #   lobby_client.gd (lobby + stats HTTP), latency_probe.gd
  config/game_config.gd       # constants, enums, to_3d() coordinate helper
  config/launch_args.gd       # -- --name=value (desktop) / ?name=value (web) options
  config/render_tier.gd       # FULL (Forward+) or WEB (Compatibility) visual tier
  data/                       # plain state: PlayerState, BallState, InputSnapshot, TeamState
  build/                      # one-shot scene construction
    material_factory.gd       #   materials + procedural textures
    pitch_builder.gd          #   pitch, field lines, goals
    stadium_builder.gd        #   environment, camera, lights, GI, stands, crowd, hoardings
    player_factory.gd         #   GLB load, animation library, team tint, fallback figure
  systems/                    # runtime subsystems
    match_simulation.gd       #   gameplay state + per-frame step()
    match_view.gd             #   mirrors state onto the 3D scene each frame
    ai_controller.gd          #   goalkeeper / owner / off-ball AI
    input_reader.gd           #   keyboard+mouse and gamepad sampling
    match_setup.gd            #   pre-match device-to-side assignment
    settings_store.gd         #   settings + input actions + persistence
    menu_manager.gd           #   menus (main / howto / settings / pause / full-time)
    online_menu.gd            #   Play Online: create / join / waiting room / stats
    match_hud.gd              #   broadcast scoreboard
    audio_manager.gd          #   music + SFX buses
```

`scenes/bootstrap.tscn` is the main scene; `scenes/main_3d.tscn` is the game,
`scenes/server.tscn` the headless match runtime and `scenes/bot.tscn` the AI bot
service (`-- --bot`, same dedicated-server export as the runtime).

### Tests

```bash
godot-4 --headless --path . --script res://tests/run_sim_tests.gd           # rules, config, session
godot-4 --headless --path . --script res://tests/run_net_tests.gd           # protocol, runtime WebSocket listener
godot-4 --headless --path . --script res://tests/run_runtime_tests.gd       # credentials, control API, spool, registry
godot-4 --headless --path . --script res://tests/run_bot_tests.gd           # AI bot: policy, job API, bot plays a match over loopback
godot-4 --headless --path . --script res://tests/run_online_smoke.gd        # two 3D games online against a runtime
godot-4 --headless --fixed-fps 60 --path . --script res://tests/run_scene_smoke.gd   # full offline match in the 3D scene
```

The Python services have pytest suites that run in Docker against a throwaway
PostgreSQL:

```bash
docker compose -f services/docker-compose.test.yml run --rm --build lobby-tests
docker compose -f services/docker-compose.test.yml run --rm --build results-tests
docker compose -f services/docker-compose.test.yml run --rm --build recommendation-tests   # no database: results is faked
docker compose -f services/docker-compose.test.yml down -v
```

The same commands run in the pinned Docker toolchain (Git Bash shown):

```bash
docker build -f tools/godot/Dockerfile --target godot -t inazuma/godot:4.7.2 tools/godot
MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W):/project" inazuma/godot:4.7.2 --headless --import --path /project
MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W):/project" inazuma/godot:4.7.2 --headless --path /project --script res://tests/run_sim_tests.gd
```

On Linux/macOS use `$(pwd)` and drop `MSYS_NO_PATHCONV=1`. On Windows the container
rewrites `assets/*.import` with LF line endings; `git checkout -- assets/` undoes that
(the content is unchanged). Stage any intentional asset edits first, or that command
discards them as well.

---

## Online play

Online matches run on independent business services behind one gateway, deployed with
Docker Compose:

| Service | Owns | Interfaces |
| --- | --- | --- |
| **lobby** (`services/lobby`, FastAPI) | room codes, guest player ids, reservations, provisioning records (its own PostgreSQL database) | public `/api/lobby/v1/...`; calls the runtime's control API |
| **match runtime** (headless Godot, `scripts/server`) | live authoritative matches, terminal-match registry, durable result spool (`/data` volume) | player WebSocket `/ws/game/<match_id>`; internal control API `:8911` |
| **results** (`services/results`, FastAPI) | match history and leaderboard (its own PostgreSQL database) | public `/api/stats/v1/...`; internal ingestion `POST /internal/v1/matches` |
| **ai-bot** (headless Godot, `scripts/bot`; optional) | live bot sessions, one per vs-AI match (no durable state) | internal job API `:8920`; plays through the runtime's player WebSocket like a browser |
| **recommendation** (`services/recommendation`, FastAPI) | nothing durable: an in-memory read model of the counted match history, copied from results' public API, and the Elo ratings computed from it | public `/api/recommendations/v1/...` (recommended AI level, rivals, Elo ranking) |

The **gateway** (Caddy: TLS, web build, routing) and **PostgreSQL** (one instance,
separate `lobby` and `results` databases and roles) are infrastructure. Only the
gateway publishes ports; the runtime control API and results ingestion are never routed.
`GET /api/status/v1/<service>` answers only up/down for each microservice (the game's
**Microservices** panel; `curl http://localhost:8080/api/status/v1/lobby`).

```bash
cp .env.example .env             # then replace every secret (docs/demo.md step 1 generates them)
docker compose up --build        # gateway on http://localhost:8080
```

Match flow:

1. `POST /api/lobby/v1/rooms {nickname, half_length_s, request_id}`: the lobby provisions
   the match on the runtime (`PUT /internal/v1/matches/{match_id}` + team-0 reservation),
   then returns `{room_code, match_id, team: 0, token, ws_url, play_url, player_id}`.
2. `POST /api/lobby/v1/rooms/{code}/join {nickname, request_id}` reserves team 1
   (exactly one concurrent joiner wins) and returns its credential.
3. Each player opens `play_url` (`/?match=<match_id>&token=<token>`); the browser sends the
   token in HELLO and the runtime verifies it locally (signature, expiry, audience,
   match, reservation).
4. At full time (or forfeit) the runtime writes the result to its spool and delivers it
   to the results service in the background, retrying until acknowledged.
5. `GET /api/lobby/v1/rooms/{code}` reports `waiting|running|paused|completed|...`;
   `GET /api/stats/v1/matches/recent` and `/api/stats/v1/leaderboard` show history and
   rankings (3/1/0 points, then goal difference, then goals for).

**Against the AI** (`POST /api/lobby/v1/rooms {..., mode: "vs_ai", difficulty:
"easy"|"normal"|"hard"}`): the lobby provisions the match with team 1's AI at that
difficulty, reserves both slots, signs the bot's credential, submits a job to the ai-bot
service (`POST /internal/v1/bots`, idempotent by match_id) with the *internal* runtime URL
`ws://match-runtime:8910/ws/game/<id>`, and answers only once the bot has joined its
slot; the human's connection then kicks off at once. If the bot service is down, refuses,
fails or misses its 10 s join deadline, the lobby stops the job, cancels the runtime
match and deletes the room: `503 bot_unavailable`, nothing left behind, PvP unaffected.
The bot is recorded in results under a stable guest id per difficulty as `AI (Easy)`,
`AI (Normal)` or `AI (Hard)` and is ranked on the leaderboard like any player. How the
bot works as an autonomous agent (goal, observations, decide/act loop, difficulty
parameters, decision log) is in [`docs/ai_bot.md`](docs/ai_bot.md).

Credentials, contracts and failure behaviour are collected in
[`ARCHITECTURE_ONLINE.md`](ARCHITECTURE_ONLINE.md) (sections 5-7), and specified at the top
of `services/lobby/app/credentials.py`, `scripts/server/runtime_control_api.gd`,
`scripts/server/result_spool.gd`, `services/lobby/app/reconcile.py` and
`services/results/app/service.py`.

Environment (`.env`, see `.env.example`): `MATCH_SECRET` (credential HMAC key, lobby +
runtime), `RUNTIME_CONTROL_TOKEN` (lobby -> runtime), `RESULTS_INGEST_TOKEN`
(runtime -> results), `BOT_CONTROL_TOKEN` (lobby -> ai-bot), `POSTGRES_PASSWORD`,
`LOBBY_DB_PASSWORD`, `RESULTS_DB_PASSWORD`, optional `SITE_ADDRESS` / `GATEWAY_HTTP_PORT` /
`GATEWAY_HTTPS_PORT` / `BOT_MAX_SESSIONS` (concurrent bot sessions, default 8). The runtime also
reads `MATCH_RUNTIME_PORT`, `RUNTIME_CONTROL_PORT`, `RESULTS_URL` and
`RUNTIME_DATA_DIR`, which the compose file sets.

End-to-end checks against the running stack. `tests/e2e/run.sh` runs a script in the
Playwright image inside the gateway's network namespace (so the page is served from
`localhost`, a secure context) and keeps `node_modules` in a Docker volume:

```bash
bash tests/e2e/run.sh online_menu.mjs   # two browsers: Play Online menu -> match -> results
bash tests/e2e/run.sh lobby_match.mjs   # lobby API grants -> play_url -> results
bash tests/e2e/run.sh netprobe.mjs      # web build boots on Compatibility, WebSocket path
bash tests/e2e/run_failure_checks.sh    # results down at full time; runtime restart mid-match
bash tests/e2e/run_bot_checks.sh        # a browser plays the AI from the menu; ai-bot down and back
```

The scripts look for the containers of the `inazuma-online` project; for a stack started
under another name (`COMPOSE_PROJECT_NAME=...`), export the same variable for them.

- `http://localhost:8080/?netprobe` checks the browser -> gateway -> runtime WebSocket
  path (`tests/e2e/netprobe.mjs` automates it).
- The development override runs a debug runtime that also accepts development tokens
  and creates rooms on first use (same `.env` needed):

  ```bash
  docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build
  ```

  Then open `http://localhost:8080/?match=test1&token=dev:0` (red) and
  `http://localhost:8080/?match=test1&token=dev:1` (blue); `tests/e2e/two_players.mjs`
  automates this. Never deploy it.

### Playing online from the game

**Play Online** in the main menu talks to the lobby through the gateway:

- **Create Room**: enter a nickname, pick the half length (30 s, 2, 5 or 10 min) and
  create. The waiting page shows the six-character room code; share it. The match starts
  as soon as the opponent joins. `Esc`/Cancel leaves the waiting room.
- **Join Room**: enter a nickname and the code, then Join. Unknown codes, full or closed
  rooms and an unavailable match server are reported on the same screen.
- **Play vs AI (online)**: pick the AI level (Easy, Normal, Hard) and the half length; the
  match starts straight away against the ai-bot service's bot (no room code to share).
  If the AI is unavailable the screen says so and PvP rooms still work.
- **Recent Matches & Leaderboard** reads `/api/stats/v1`.
- **Recommended for you** (left panel) comes from the recommendation service: your Elo
  rating and form, the AI level to play next (**Use this AI level** selects it) and rivals
  at your level. **Microservices** (right panel, and a strip on the main menu) shows each
  service live; hovering an action lights up the services it uses.
- In a match, `Esc` leaves. Keyboard+mouse or any connected pad drives your team: whichever
  device you used last. Full time offers **New Online Match** and **Back to Menu**.

The web build uses the page's own origin (`/api/lobby/v1`, `wss://<host>/ws/game/<id>`).
A desktop build reads the lobby from a launch argument:

```bash
godot-4 --path . -- --lobby=http://localhost:8080/api/lobby/v1
```

The nickname, the guest `player_id` the lobby issued (so a returning guest keeps one
leaderboard row), the last half length and AI level are saved with the other settings. The old
`/?match=<id>&token=<credential>` links (`play_url`) still work.

On the web the renderer is Compatibility (WebGL 2), so the stadium uses its **web quality
tier**: no SSAO, SSIL, volumetric fog or VoxelGI (none exist there; skipping VoxelGI also
skips its bake at load), compensated with more ambient fill, depth fog and glow, two
shadowed floodlights instead of four and a thinner crowd. The desktop Forward+ look is
unchanged. `?quality=full` / `?quality=web` (desktop: `-- --quality=...`) overrides the
choice. Text fields take physical-keyboard input in desktop browsers. Mobile browsers
aren't a target (no touch controls), so the export's virtual keyboard stays off.

Latency, bandwidth and browser frame-time numbers, and how they were measured, are in
[`docs/measurements.md`](docs/measurements.md).

### Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request, with no repository
secrets: the pinned Godot toolchain image (cached), `--import` and all six Godot suites;
the credential-vector check and both pytest suites; then, with a generated throwaway
`.env`, `docker compose build` (which runs the Web and Linux Server exports), the stack,
the `netprobe`, `online_menu` and `lobby_match` browser e2e scripts and
`run_bot_checks.sh` (vs-AI from the menu, then ai-bot stopped and started).

---

## Deploying on one VPS

The whole stack runs on a single Linux host with Docker Engine and the Compose plugin
(2 vCPU and 2 GB RAM is plenty for a handful of matches; the match runtime simulates
every room on one thread).

1. **DNS.** Create an `A` (and `AAAA` if you have IPv6) record pointing your domain,
   e.g. `game.example.com`, at the server.
2. **Firewall.** Allow inbound TCP 22 (SSH), 80 and 443 only. With `ufw`:
   `ufw allow OpenSSH && ufw allow 80/tcp && ufw allow 443/tcp && ufw enable`.
   Nothing else is published: lobby, results, runtime, ai-bot and PostgreSQL sit on an internal
   Docker network with no route out. (Docker-published ports bypass `ufw`'s INPUT rules,
   so don't publish anything else.)
3. **Configuration.** Clone the repo and `cp .env.example .env`, then set:
   - every secret to a fresh value (`openssl rand -hex 32`; database passwords
     URL-safe),
   - `SITE_ADDRESS=game.example.com`: Caddy obtains a Let's Encrypt certificate and
     redirects HTTP to HTTPS (ports 80/443 must be reachable for the ACME challenge),
   - `GATEWAY_HTTP_PORT=80` and `GATEWAY_HTTPS_PORT=443`,
   - optionally `RUNTIME_MAX_CONNECTIONS` / `RUNTIME_MAX_ROOMS` (defaults 64 / 32).
4. **Start.** `docker compose up --build -d`, then `docker compose ps` should show every
   service `healthy`. The gateway's healthcheck uses an internal listener
   (`127.0.0.1:8081/healthz`) that works in both HTTP and HTTPS modes. Open
   `https://game.example.com/?netprobe` to check the WebSocket path.
5. **Logs.** Every container writes JSON lines to Docker's `json-file` driver, rotated
   at 5 x 10 MB per container: `docker compose logs -f lobby match-runtime`
   (`docker compose logs ai-bot | grep bot_decision` shows the bot reasoning).

**State and backups.** Three named volumes hold everything worth keeping:

| Volume | Contents | Backup |
| --- | --- | --- |
| `inazuma-online_postgres-data` | lobby + results databases | `docker compose exec -T postgres pg_dumpall -U postgres \| gzip > backup-$(date +%F).sql.gz` (restore: `gunzip -c ... \| docker compose exec -T postgres psql -U postgres`) |
| `inazuma-online_runtime-data` | terminal-match registry, undelivered results (`spool/`) | `docker run --rm -v inazuma-online_runtime-data:/data -v "$PWD:/out" alpine tar czf /out/runtime-$(date +%F).tgz -C /data .` |
| `inazuma-online_caddy-data` | TLS certificates and ACME account | optional (Caddy re-issues), same `tar` pattern |

Run the dumps from cron (e.g. nightly) and copy them off the host.

**Upgrading.**

```bash
git pull
docker compose build                    # new images; the running stack is untouched
docker compose up -d                    # recreates only the changed containers
docker compose ps                       # wait for healthy
docker image prune -f
```

Recreating the match runtime ends the matches in progress: the lobby reports them
`aborted`, and results already in the spool are delivered after the restart. Upgrade
between matches if you can (`docker compose logs --since 15m match-runtime` shows live
rooms). The services create or update their database schema on start; take a
`pg_dumpall` before upgrading.

---

## Legacy C++/OpenGL build (reference only)

The original immediate-mode OpenGL + GLFW + miniaudio build is kept as a backup and is
still buildable on Linux (`libglfw3-dev`, `libgl1-mesa-dev`):

```bash
make            # builds ./InazumaElevenGL
./InazumaElevenGL
make clean
```

Its sources are under `src/` and `include/`; it is documented separately in
`PROJECT_DOCUMENTATION.md`. **This is not the graded project** — the Godot 3D build is.

---

## Documentation

The online migration's Milestones 0-6 are complete (reusable match component, protocol
and authoritative runtime, lobby/results services, Play Online menu + web tier + CI, the
online AI bot, documentation and demo).

- **[`ARCHITECTURE_ONLINE.md`](ARCHITECTURE_ONLINE.md)** — the online system: requirements matrix (nonviolent game, microservices, software components, AI agent), deployment and component diagrams, data ownership, every contract, lifecycle, failure handling, security, known limitations.
- **[`docs/demo.md`](docs/demo.md)** — demo runbook from a fresh checkout, with expected output and troubleshooting.
- **[`AS_BUILT.md`](AS_BUILT.md)** — as-built technical report and grading-criteria map (Godot 3D build).
- `CLAUDE.md` — concise module map / contributor guide.
- [`docs/ai_bot.md`](docs/ai_bot.md) — the online AI opponent as an autonomous agent (Milestone 5).
- [`docs/measurements.md`](docs/measurements.md) — latency, bandwidth, frame time and bot strength numbers.
- `GODOT_3D_PLAN.md` — the original design plan (intent and rubric rationale).
- `PROJECT_DOCUMENTATION.md` — the legacy C++ build only.

## Authors

**Antonio Guilherme da Silva** and **Erick Keven da Silva Alves**: the current project, the
online two-player game built from microservices and software components.

The game began as a Computer Graphics course project by **Antonio Guilherme**, **Davi Santos**
and **Felipe Lira** (the original C++/OpenGL build and the first Godot 3D version).
AI-assisted development was used for parts of the asset workflow and gameplay/physics
implementation.
