# Inazuma Eleven GL

An arcade 11-v-11 football game inspired by *Inazuma Eleven*. The active project is a
**Godot 4.7 3D build** with a night-stadium broadcast presentation; the original
C++/OpenGL build remains in the repo as a legacy reference.

> For the full technical write-up — runtime flow, module map, and how each grading
> criterion is implemented — see **[`AS_BUILT.md`](AS_BUILT.md)**.

---

## The active build (Godot 3D)

- 11-v-11 match with a user team (red) and a full-AI team (blue), in a 4-3-3 formation.
- Night stadium: broadcast camera, four floodlight masts, a moon fill light, baked
  global illumination, ACES tonemapping, bloom, SSAO/SSIL and volumetric fog.
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
| Pause / back | `Esc` | `Start` |

You always control the player nearest the ball; while your team has possession, control
locks to the ball carrier (FIFA-style). Release a fully charged shot from close range to
trigger a special shot.

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
  net/                        # wire protocol, network client, snapshot interpolation
  config/game_config.gd       # constants, enums, to_3d() coordinate helper
  data/                       # plain state: PlayerState, BallState, InputSnapshot, VfxParticle
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
    match_hud.gd              #   broadcast scoreboard
    audio_manager.gd          #   music + SFX buses
```

`scenes/bootstrap.tscn` is the main scene; `scenes/main_3d.tscn` is the game,
`scenes/server.tscn` the headless match runtime.

### Tests

```bash
godot-4 --headless --path . --script res://tests/run_sim_tests.gd           # rules, config, session
godot-4 --headless --path . --script res://tests/run_net_tests.gd           # protocol, runtime WebSocket listener
godot-4 --headless --path . --script res://tests/run_runtime_tests.gd       # credentials, control API, spool, registry
godot-4 --headless --path . --script res://tests/run_online_smoke.gd        # two 3D games online against a runtime
godot-4 --headless --fixed-fps 60 --path . --script res://tests/run_scene_smoke.gd   # full offline match in the 3D scene
```

The Python services have pytest suites that run in Docker against a throwaway
PostgreSQL:

```bash
docker compose -f services/docker-compose.test.yml run --rm --build lobby-tests
docker compose -f services/docker-compose.test.yml run --rm --build results-tests
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

Online matches run on three independent business services behind one gateway,
deployed with Docker Compose:

| Service | Owns | Interfaces |
| --- | --- | --- |
| **lobby** (`services/lobby`, FastAPI) | room codes, guest player ids, reservations, provisioning records (its own PostgreSQL database) | public `/api/lobby/v1/...`; calls the runtime's control API |
| **match runtime** (headless Godot, `scripts/server`) | live authoritative matches, terminal-match registry, durable result spool (`/data` volume) | player WebSocket `/ws/game/<match_id>`; internal control API `:8911` |
| **results** (`services/results`, FastAPI) | match history and leaderboard (its own PostgreSQL database) | public `/api/stats/v1/...`; internal ingestion `POST /internal/v1/matches` |

The **gateway** (Caddy: TLS, web build, routing) and **PostgreSQL** (one instance,
separate `lobby` and `results` databases and roles) are infrastructure. Only the
gateway publishes ports; the runtime control API and results ingestion are never routed.

```bash
cp .env.example .env             # then replace every secret
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

Credentials, contracts and failure behaviour are documented at the top of
`services/lobby/app/credentials.py`, `scripts/server/runtime_control_api.gd`,
`scripts/server/result_spool.gd`, `services/lobby/app/reconcile.py` and
`services/results/app/service.py`.

Environment (`.env`, see `.env.example`): `MATCH_SECRET` (credential HMAC key, lobby +
runtime), `RUNTIME_CONTROL_TOKEN` (lobby -> runtime), `RESULTS_INGEST_TOKEN`
(runtime -> results), `POSTGRES_PASSWORD`, `LOBBY_DB_PASSWORD`, `RESULTS_DB_PASSWORD`,
optional `SITE_ADDRESS` / `GATEWAY_HTTP_PORT` / `GATEWAY_HTTPS_PORT`. The runtime also
reads `MATCH_RUNTIME_PORT`, `RUNTIME_CONTROL_PORT`, `RESULTS_URL` and
`RUNTIME_DATA_DIR`, which the compose file sets.

End-to-end checks against the running stack (Playwright container in the gateway's
network namespace, so the page is served from `localhost`):

```bash
MSYS_NO_PATHCONV=1 docker run --rm --network container:inazuma-online-gateway-1 \
  -v "$(pwd -W)/tests/e2e:/e2e" -w /e2e mcr.microsoft.com/playwright:v1.63.0-noble \
  sh -c "npm i --silent --no-save playwright@1.63.0 && node lobby_match.mjs http://localhost"
bash tests/e2e/run_failure_checks.sh   # results down at full time; runtime restart mid-match
```

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

The in-game lobby menu (create/join from the game UI) is the next milestone; until
then rooms are created through the lobby API and opened through `play_url`.

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

- **[`AS_BUILT.md`](AS_BUILT.md)** — as-built technical report and grading-criteria map (Godot 3D build).
- `CLAUDE.md` — concise module map / contributor guide.
- `GODOT_3D_PLAN.md` — the original design plan (intent and rubric rationale).
- `PROJECT_DOCUMENTATION.md` — the legacy C++ build only.

## Attribution

Developed by **Antonio Guilherme** and **Davi Santos** with contributions from **Felipe Lira**. AI-assisted development was used
for parts of the asset workflow and gameplay/physics implementation.
