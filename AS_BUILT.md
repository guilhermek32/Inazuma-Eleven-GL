# Inazuma Eleven GL — As-Built Technical Report (Godot 3D)

This document describes the **shipped Godot 4.7 3D build** as it actually exists in the
code, and maps each grading criterion to where it is implemented. It is the authoritative
reference for the rendering and gameplay of the graded project. (The separate
`PROJECT_DOCUMENTATION.md` covers only the legacy C++/OpenGL build.)

> **Online system.** The game also runs online: two browsers play an authoritative match
> through lobby, match-runtime and results microservices (plus an optional AI-bot
> service). That architecture — requirements matrix, diagrams, contracts, failure
> handling, security and limitations — is in **[`ARCHITECTURE_ONLINE.md`](ARCHITECTURE_ONLINE.md)**;
> the demo runbook is [`docs/demo.md`](docs/demo.md). This report covers the game itself.

---

## 1. Overview

An arcade 11-v-11 football match rendered as a night-stadium broadcast. Offline, the
pre-match setup screen assigns each input device to the red or blue team (1P vs AI or
local 2P; an empty side is the AI); online, each browser drives one team. Gameplay is
computed in a normalized 2D field and presented in full 3D — a **2.5D model** — so all the
rendering, lighting and material work can target realism (the bulk of the grade) without
a physics engine fighting the gameplay.

- Engine: **Godot 4.7** (pinned to 4.7.2), Forward+ renderer on desktop (required by
  VoxelGI, SSAO/SSIL, volumetric fog); the web build uses Compatibility with a lighter
  visual tier (`config/render_tier.gd`, `StadiumBuilder.web_tier`).
- Main scene: `scenes/bootstrap.tscn`, which picks the process role and then loads the
  game, `scenes/main_3d.tscn` — a single `Node3D` with `scripts/match_controller_3d.gd`
  attached. Everything visible is built in code at runtime.
- Tests: six headless Godot suites (rules and session, protocol and runtime, credentials
  and control API, AI bot, online smoke, offline scene smoke), pytest suites for the
  Python services and browser e2e scripts, all run by CI (`.github/workflows/ci.yml`).
  No linter.

### How to run

```bash
godot-4 --path .                                      # interactive
godot-4 --headless --quit-after 5 --path .            # boot smoke test
godot-4 --headless --import --path .                  # import + compile check (surfaces script errors)
godot-4 --headless --fixed-fps 60 --path . --script res://tests/run_scene_smoke.gd   # a full offline match
```

Without a local Godot, the same commands run in the pinned Docker image (README "Tests").

---

## 2. Runtime flow

### 2.1 Boot — `match_controller_3d.gd : _ready()`

The controller is a thin **orchestrator**. `_ready()` instantiates and wires the modules in
a fixed order, because later steps depend on earlier ones:

1. `MaterialFactory._build_materials()` — build the shared material palette and procedural
   textures first (everything else references them).
2. Create the scene roots (`Pitch`, `FieldLines`, `Goals`, `Stadium`, `Players`, `Ball`, `VFX`).
3. `StadiumBuilder` — environment (sky + post-processing) → broadcast camera → lights.
4. `PitchBuilder` — pitch surface, field lines, goals.
5. `StadiumBuilder` — stands, crowd, hoardings, then **bake VoxelGI**. The bake happens here,
   *before* players are created, so the GI probe captures only static geometry and the neon
   hoardings bounce coloured light onto the turf (dynamic players stay out of the bake).
6. HUD, settings (registers input actions), `PlayerFactory`, the `MatchSession` (which
   owns `MatchSimulation` + `AIController`) and `MatchView` — created and cross-wired.
7. `MatchView` creates the ball, its sphere trail, the grass-mark decal pool and the
   confetti.
8. Audio, menus (including the Play Online screens) and the pre-match setup screen are
   built, then the weather.
9. `_initialize_session()` builds a `MatchConfig` from the settings and calls
   `session.initialize(config, seed)`, which builds the 22 players; then the `MENU` state.
   Prints `Inazuma Eleven 3D environment ready`.

### 2.2 State machine — `_set_game_state()`

`GameConfig.GameState`: `MENU → MATCH_SETUP → PLAYING ⇄ PAUSED → FULLTIME`, with
`HOWTO`, `SETTINGS` and `ONLINE` (the Play Online screens) as overlays. `_set_game_state()`
is the single transition point: it shows/hides the right menu panel, pauses GLB animations
when not playing, and enters/exits the setup screen. `_input()` handles `Esc`/`Start` for
pause and back navigation.

### 2.3 Per-frame — `_physics_process` and `_process`

- **`_physics_process(delta)`** (fixed 60 Hz tick, PLAYING only): `InputReader.read()` →
  `session.step(delta)` → each event from `session.drain_events()` goes to
  `_dispatch_event()` (view, HUD and audio cues). Online, the tick only sends our team's
  input (`NetClient.send_input`); the runtime simulates.
- **`_process(delta)`**: online, the newest interpolated snapshot is written into the
  mirror `session.sim` and due events are dispatched; then `MatchView.update_visuals()`
  with the delta scaled by the session's slow-motion `time_scale`, the setup screen,
  confetti and the HUD.

The split is deliberate and strict: **`MatchSimulation` owns gameplay state; `MatchView`
only reads it and updates nodes** — the view never mutates gameplay.

### 2.4 Simulation step — `match_simulation.gd : step()`

```
restart timer → ball physics + goal detection
             → team 0 update → team 1 update → capture resolution
```

Per team: choose the controlled player, run user input *or* `AIController` for each
player. After both teams, `_resolve_ball_capture()` gives a loose ball to the globally
nearest eligible player, and a carried ball only to an opponent with a live tackle
window. Possession glue, friction, restarts (throw-in, corner, goal kick, free kick) and
goal resolution all live here.

### 2.5 Match clock — `MatchSession.step()`

`MatchSession` owns the clock: each half runs for `MatchConfig.half_length_s` (offline
Settings: 2 / 5 / 10 minutes; online: 30 s to 10 minutes). At the end of the first half
the ends are switched and the game resets; at the end of the second half the match ends
and the full-time panel shows the result and the match stats. The goal-celebration freeze
and the half-time pause are session phases.

---

## 3. The 2.5D model and coordinate system

- Gameplay state is plain data (`data/PlayerState`, `data/BallState`) in a normalized 2D
  field: `x ∈ ±0.98`, `y ∈ ±0.78`, with the playable boundary at `±0.93 / ±0.73`.
- There is **no physics engine and no CharacterBody/RigidBody** — positions are integrated
  by hand, friction is `pow(friction, delta·60)` (frame-rate independent), and AI random
  rolls are scaled by `delta`.
- `GameConfig.to_3d(p, height)` projects to the world:
  `world = (x·FIELD_SCALE, height, -y·FIELD_SCALE)`, with `FIELD_SCALE = 24`.
  **Note the sign flip:** 2D `+y` maps to 3D `-z`.
- Conventions: red `side = -1` (starts on `-x`, attacks `+x`), blue `side = +1`. Ball
  possession is `owner_team`/`owner_index` (`-1` = loose); while owned, the ball is glued to
  the carrier's feet and physics is skipped.

---

## 4. Module map

| File | Responsibility |
| --- | --- |
| `bootstrap.gd` | Process entry: game, match runtime (`--server`), AI bot (`--bot`) or web net probe |
| `match_controller_3d.gd` | Orchestrator: boot wiring, game-state machine; offline and online adapter around `MatchSession` |
| `match/match_config.gd` | Immutable gameplay rules of one match (validated wire form) |
| `match/match_session.gd` | The reusable match component: clock, halves, goal freeze, slow motion, events |
| `config/game_config.gd` | Field geometry constants, enums, `MATCH_LENGTHS`, `to_3d()` |
| `config/launch_args.gd`, `config/render_tier.gd` | Launch options; FULL (Forward+) or WEB (Compatibility) visual tier |
| `data/player_state.gd` | Per-player gameplay state + GLB animation hooks |
| `data/ball_state.gd` | Ball position/velocity/owner/spin/height + node/light refs |
| `data/input_snapshot.gd` | One frame of per-team input (human, remote or bot) |
| `data/team_state.gd` | A team's players, device, formation, kit and selection state |
| `build/material_factory.gd` | Material palette, procedural textures, shared mesh/AABB helpers |
| `build/pitch_builder.gd` | Pitch surface, all field-line markings, both goals + nets |
| `build/stadium_builder.gd` | Environment, post-processing, camera, lights, GI, stands, crowd, hoardings |
| `build/player_factory.gd` | GLB load + retargeted animation library, team tint, fallback figure |
| `systems/match_simulation.gd` | Gameplay state and per-frame `step()` |
| `systems/match_view.gd` | Mirrors state onto the 3D scene (players, ball, camera, VFX) |
| `systems/ai_controller.gd` | Goalkeeper / ball-carrier / off-ball AI decisions |
| `systems/input_reader.gd` | Keyboard+mouse and gamepad sampling; mouse→ground ray-cast |
| `systems/match_setup.gd` | Pre-match device-to-side assignment screen |
| `systems/settings_store.gd` | Local preferences (camera, video, audio, the rules that seed an offline `MatchConfig`), input actions, persistence |
| `systems/menu_manager.gd` | All menu panels and navigation |
| `systems/online_menu.gd` | Play Online: create / join / vs AI, waiting room, recent matches + leaderboard |
| `systems/match_hud.gd` | Broadcast scoreboard (score, goal flash, clock/kickoff, banners, stamina) |
| `systems/audio_manager.gd` | Music + SFX buses and play hooks |
| `ai/tactics.gd` | Pure tactical queries shared by the in-sim AI and the online bot |
| `net/*`, `server/*`, `bot/*` | Protocol, network client and interpolation; the match runtime; the AI bot — see [`ARCHITECTURE_ONLINE.md`](ARCHITECTURE_ONLINE.md) |

---

## 5. Grading-criteria map

The criteria are from `GODOT_3D_PLAN.md`. Each row points at the concrete implementation.

### 5.1 Lighting techniques and different light sources

| Element | Where |
| --- | --- |
| Environment / IBL ambient from a night `ProceduralSkyMaterial` | `stadium_builder.gd : _build_environment()` |
| **Directional** moon key/fill light | `stadium_builder.gd : _build_lighting()` (`MoonLight`) |
| Four **SpotLight3D** floodlights (shadow-casting) on corner masts, aimed at pitch centre | `stadium_builder.gd : _add_floodlight()` / `_build_lamp_bank()` |
| Per-mast **OmniLight3D** warm accent + emissive lamp cells | `_add_floodlight()`, `materials.floodlamp` |
| Dynamic **OmniLight3D** on the ball for charge / special-shot glow | `match_view.gd : _create_ball()` + `_update_ball_visual()` |
| **VoxelGI** indirect bounce (neon hoardings → turf), baked over static geometry | `stadium_builder.gd : _build_gi()` / `_bake_gi()` |
| Tuned shadow atlas so four floodlights resolve crisp player shadows | `_build_lighting()` (positional shadow atlas size/quadrants) |

Three distinct light *types* (directional, spot, omni) plus baked GI — a clear demonstration
of multiple, intentional light sources.

### 5.2 Lighting models / material response

| Element | Where |
| --- | --- |
| ACES HDR tonemapping, glow/bloom, SSAO, SSIL, volumetric fog | `_build_environment()` |
| PBR `StandardMaterial3D` with per-surface BRDF tuning | `material_factory.gd : _build_materials()` |
| Grass **anisotropy** (directional sheen along mow stripes) | `materials.grass` |
| Metallic aluminium goals (sky reflections) | `materials.goal` |
| **Clearcoat** lacquered-leather ball | `materials.ball` |
| **Subsurface-scattering** skin; **rim** light on kits | `materials.skin`, `materials.player_*` |
| Lambert (matte concrete) vs Burley diffuse elsewhere | `materials.concrete`, `materials.asphalt` |

### 5.3 Texture mapping

All textures are **procedural** (generated in code), then UV-tiled with `uv1_scale`:

| Texture | Where |
| --- | --- |
| Layered grass albedo (patch tone + per-blade speckle + mow banding) | `material_factory.gd : _grass_texture()` |
| Tangent-space **normal maps** from blurred height fields | `_normal_texture()` |
| Goal-net alpha pattern | `_net_texture()` |
| Ball checker (fallback) | `_checker_texture()` |
| Pressed-turf trail decal albedo + radial dimple normal map | `_decal_albedo_texture()` / `_decal_normal_texture()` |
| Crowd MultiMesh albedo via per-instance colour shader | `_crowd_material()` |

### 5.4 Geometry / modeling

| Element | Where |
| --- | --- |
| Pitch, mow stripes, every field line, circle, arcs, penalty/goal boxes, corner flags | `pitch_builder.gd` |
| Goals: posts, crossbar, depth bars, transparent net panels | `pitch_builder.gd : _add_goal()` |
| Stadium: tiered stands + seat bands, perimeter walls, ground apron, floodlight masts, neon hoardings | `stadium_builder.gd` |
| **Players:** Mixamo GLB (`Ch38` mesh) with a retargeted animation library (idle / run / gk_idle / kick / receive / tackle), team tint, and a procedural box-figure fallback | `player_factory.gd` |
| **Ball:** Trionda World Cup 2026 GLB, auto-scaled/centred from its AABB, with a sphere fallback | `match_view.gd : _add_ball_glb()`, `GameConfig.BALL_GLB` |
| Dense **3D crowd** via two MultiMeshes (capsule bodies + sphere heads), per-instance colour/scale/jitter + GPU idle bob | `stadium_builder.gd : _add_crowd()` / `_build_crowd_multimesh()` |

"Refine previous modeling work": the flat 2D sprites of the legacy build become real 3D
geometry and rigged GLB characters here.

### 5.5 Realism / presentation (the 60%)

| Element | Where |
| --- | --- |
| Broadcast camera on a rig that smoothly follows the ball (lerped position + look-at) | `stadium_builder.gd : _build_camera()`, `match_view.gd : _update_camera()` |
| Ball spin, height-by-speed, and a fading sphere trail | `match_view.gd : _update_ball_visual()` / `_update_ball_trail()` |
| Ball leaves a fading **pressed-turf decal trail** on the grass | `match_view.gd : _update_grass_marks()` |
| Goal celebration: confetti, whistle, score flash | `match_view.gd : _trigger_goal()` / `_spawn_confetti()`, `match_hud.gd` |
| Charge **power ring**, **special-shot** glow and selection rings | `player_factory.gd`, `match_view.gd` |
| Broadcast-style HUD scoreboard with team chips and clock | `match_hud.gd` |
| Night atmosphere: fog light-shafts, bloomed floodlights and neon, GI spill | `stadium_builder.gd : _build_environment()` |

---

## 6. Controls

| Action | Keyboard + mouse | Gamepad |
| --- | --- | --- |
| Move | `W A S D` | Left stick |
| Aim | Mouse (ray-cast to the ground plane) | Right stick |
| Shoot | Hold `SPACE` to charge, release to kick | Hold `R1`/`RB`, release |
| Pass | `E` | `A` |
| Switch player | `Q` | `L1`/`LB` |
| Tackle (win the ball) | `Ctrl` or right-click | `X` |
| Sprint (drains stamina) | `Shift` | `R2`/`RT` |
| Pause / back | `Esc` | `Start` |

Input actions are registered in code (`settings_store.gd : setup_input_actions()`), not in
`project.godot`. The controlled player is the one nearest the ball; in possession, control
locks to the carrier.

---

## 7. Gameplay rules

- **Formation:** 4-3-3, 11 per side (GK + 4 DEF + 3 MID + 3 ATT), classic jersey numbering.
- **Possession:** by proximity (`_resolve_ball_capture`); a well-timed tackle wins the ball
  from an opponent, who is slowed for a moment (no damage or injury — the tackle is ball
  recovery). A tackle from behind is a foul and gives the other team a free kick (fouls and
  offside can be switched off in Settings). After kicking, the kicker is briefly slowed so
  it can't instantly re-grab its own pass/shot.
- **Shooting:** hold to charge `0…1`; a fully charged close-range shot becomes a named
  special shot (extra glow and curve, harder for the keeper to hold). Shots arc with charge
  and the crossbar denies balls that are too high.
- **Goals:** detected when the ball crosses an end line within the goal width; the conceding
  team kicks off. Scores are attributed by team index, so they stay correct after ends switch.
- **Restarts:** a ball out of play gives a throw-in, corner or goal kick after a short freeze.
- **Match:** two halves of 2 / 5 / 10 minutes (Settings; 30 s to 10 minutes online); ends
  switch at halftime; a result screen with the match stats shows at full time.
- **Difficulty** is intelligence, not speed: each team's AI reads its profile from
  `MatchConfig.ai_profile(team)` (think rate, decision rate, aim error, keeper reaction).

---

## 8. Design choices and known limitations

- **2.5D, not full 3D physics.** Chosen so gameplay stays predictable and frame-rate
  independent while all effort goes into rendering/realism. The ball has a simple vertical
  flight model (gravity, damped bounce, Magnus curve) on top of the 2D plane.
- **Procedural everything.** The scene is built in code, and textures are generated at
  runtime — no large binary texture assets to ship, and parameters are easy to tune. The only
  external art is the player and ball GLBs and the three sound files.
- **AI is heuristic** (distance, role, probabilistic pass/shoot rolls), not learned.
- **Tested headlessly, no linter.** The Godot suites (`tests/run_*.gd`) cover the rules,
  the session, the protocol, the runtime, the bot and full offline and online matches; CI
  runs them with the service and browser checks. The rendering itself is verified by eye
  (and by the web-tier screenshots in `docs/measurements.md`).
- **Online play** has its own limitations (no client-side prediction, guest identities,
  one runtime instance): see `ARCHITECTURE_ONLINE.md` section 11.
- The legacy `materials/*.tres` files were unused (materials are procedural) and have been
  removed; the C++ build under `src/`/`include/` is kept only as a reference.

---

## 9. Attribution

Developed by **Antonio Guilherme** and **Davi Santos**. AI-assisted development was used for
parts of the asset workflow and gameplay/physics implementation.
