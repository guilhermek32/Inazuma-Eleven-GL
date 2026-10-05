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
  server/                     # headless match runtime (WebSocket listener)
  net/                        # network client side (connectivity probe so far)
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
godot-4 --headless --path . --script res://tests/run_net_tests.gd           # runtime WebSocket listener
godot-4 --headless --fixed-fps 60 --path . --script res://tests/run_scene_smoke.gd   # full offline match in the 3D scene
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

## Online play (in progress)

The online version runs the match on an authoritative headless Godot **match runtime**
and serves the web build through a **Caddy gateway**, deployed with Docker Compose. The
full plan (lobby, results service, netcode) is being built in milestones.

```bash
docker compose up --build        # gateway on http://localhost:8080
```

- `http://localhost:8080/` loads the game in the browser (Compatibility renderer).
- `http://localhost:8080/?netprobe` checks the browser -> gateway -> runtime WebSocket path.
- `tests/e2e/netprobe.mjs` runs that check in headless Chromium (see the file header).

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
