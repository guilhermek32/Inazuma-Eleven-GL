# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Layout: Two Parallel Implementations

This repo contains two implementations of the same arcade 11v11 football game, side by side:

1. **Original C++/OpenGL build** — `src/`, `include/`, `Makefile`. Immediate-mode OpenGL + GLFW + miniaudio. Still buildable; treated as the reference/backup. Full architecture docs in `PROJECT_DOCUMENTATION.md`.
2. **Godot 3D port** — `scripts/` + `scenes/main_3d.tscn`. The project's main scene and where active development happens (branch `3d-version`). Plan and rationale in `GODOT_3D_PLAN.md`; realism is the priority (it is the bulk of the grade for this university project).

(The earlier Godot 2D port was removed once the 3D build superseded it.)

There is a headless gameplay-logic test suite (`tests/run_sim_tests.gd`, see Commands); no linter.

## Commands

C++ build (Linux, needs `libglfw3-dev libgl1-mesa-dev`):

```bash
make            # builds ./InazumaElevenGL
./InazumaElevenGL
make clean
```

Godot project (Godot 4.6, root `project.godot`, main scene `scenes/main_3d.tscn`). The engine is installed as the snap `godot-4`:

```bash
godot-4 --path .                                          # run interactively
godot-4 --headless --quit-after 5 --path .                # smoke-test: boots the scene, prints "Inazuma Eleven 3D environment ready"
godot-4 --headless --editor --quit-after 3 --path .       # full import + script compile; surfaces any parse/SCRIPT errors
godot-4 --headless --path . --script res://tests/run_sim_tests.gd   # gameplay-logic tests (pure MatchSimulation, no 3D); exits non-zero on failure
```

## Godot 3D Architecture (the big picture)

**Procedural scene, modular code.** `scenes/main_3d.tscn` is a single `Node3D` with `scripts/match_controller_3d.gd` attached; the entire scene — pitch, goals, stadium, crowd, lights, environment, players, ball, UI — is built procedurally at runtime, not authored in the `.tscn`. The controller is a thin **orchestrator**: `_ready()` instantiates and wires the modules below in a fixed order, and `_process()` delegates to the simulation and the view. To change visuals or gameplay, edit the relevant module script, not the scene.

Code is organized by responsibility under `scripts/`:

- `config/game_config.gd` (`GameConfig`) — field geometry constants, GLB/animation constants, the `PlayerRole` and `GameState` enums, `MATCH_LENGTHS`, and the `to_3d()` coordinate helper. Shared by every module as `GameConfig.X`.
- `data/` — plain state classes: `PlayerState`, `BallState`, `InputSnapshot`, `TeamState` (players + device/formation/kit + human selection state; `sim.teams[0]`=red, `[1]`=blue).
- `build/` — one-shot scene construction: `MaterialFactory` (materials + procedural textures, including the grass, crowd and ball-trail decal textures), `PitchBuilder` (pitch, lines, goals), `StadiumBuilder` (night environment + post-processing — ACES, glow, SSAO, SSIL, volumetric fog; broadcast camera; moon fill + four corner floodlight masts; VoxelGI bake; stands; the animated 3D MultiMesh crowd; hoardings), `PlayerFactory` (GLB load, animation library, player visuals, team tint).
- `systems/` — runtime subsystems: `AudioManager`, `SettingsStore` (load/save + input actions), `MenuManager`, `MatchSetup` (pre-match screen that assigns each device — keyboard+mouse, each pad — to RED/BLUE/AI), `MatchHud` (broadcast-style score panel), `InputReader`, `AIController`, `MatchSimulation` (gameplay state + per-frame `step`), `MatchView` (per-frame node updates: players, ball, camera, VFX, and the ball's fading grass-trail decals).

**2.5D gameplay model.** Game logic runs in normalized 2D coordinates inherited from the C++ version: `x ∈ ±0.98`, `y ∈ ±0.78` (playable boundary `±0.93 / ±0.73`), with all state in the plain `data/` classes — no physics engine, no CharacterBody/RigidBody. Visuals convert via `GameConfig.to_3d(p: Vector2)`: world = `(x * FIELD_SCALE, height, -y * FIELD_SCALE)` with `FIELD_SCALE = 24.0`. Note the sign flip: 2D `+y` is 3D `-z`.

The ball also carries a simple vertical flight model on top of the 2D plane: `ball.h` / `ball.vh` in **world units** (gravity, damped bounce, `Magnus` curve via `ball.curve`). Shots arc with charge, the crossbar (`GameConfig.GOAL_HEIGHT`) denies high balls, and players can only capture below their reach height (`CAPTURE_MAX_HEIGHT`, keeper `GK_REACH_HEIGHT`).

**Module boundaries:** `MatchSimulation` owns all gameplay state and never touches view/audio — it emits signals (`goal_scored`, `ball_kicked`, `special_fired`, `field_reset`, `restart_awarded`) that the controller connects to presentation. Cross-module public methods have no underscore prefix; `_underscore` methods are module-internal. All feel-critical tuning numbers live in the "Gameplay tuning" section of `GameConfig`.

**Conventions in the logic:**
- Red team (`teams[0]`) `side = -1`, starts on `-x`, attacks `+x`; blue (`teams[1]`) `side = +1` attacks `-x`. Defaults: red on keyboard+mouse, blue full AI (the setup screen reassigns devices).
- Ball possession is `ball.owner_team` / `ball.owner_index` (`-1` = loose ball); while owned, the ball is glued to the owner's feet and physics is skipped. After both team updates, `_resolve_ball_capture` gives the ball to the globally nearest eligible player: loose balls on contact, steals only during a live tackle window (`PlayerState.tackle_timer`; a whiffed tackle self-stuns).
- When the ball leaves play it does not bounce: `_award_restart` grants a throw-in / corner / goal kick against `ball.last_touch_team`, placing the taker at the spot behind a short freeze (`restart_timer` / `restart_type`, which also implement kickoff).
- Player roles drive formation targets, AI behavior and speed (`GameConfig.ROLE_SPEED`). Sprinting (`SPRINT_*`) drains `PlayerState.stamina`; the AI presser sprints under the same rules.
- Gameplay steps in `_physics_process` (fixed tick); `MatchView`/HUD update in `_process`. Per-tick flow (`MatchSimulation.step`): restart timer → ball physics/goal detection → team 0 update → team 1 update → capture resolution.
- AI random decisions (shoot/pass/tackle chances) must be scaled by `delta` to stay frame-rate independent. The keeper reacts to inbound shots after a difficulty-based delay (`GK_REACTION`) and then chases the predicted intercept point.

**Controls:** WASD moves the selected player, hold/release Space charges/releases a shot, mouse aims (ray-cast onto the ground plane), E passes, Q switches player, Ctrl or right-click tackles, Shift sprints. Pad: R1 shoot, A pass, L1 switch, X tackle, R2 sprint. Input actions are registered in code in `SettingsStore`, not in `project.godot`.

The C++ version mirrors this layout across `src/game_logic.cpp`, `src/player.cpp`, `src/ball.cpp` (see `PROJECT_DOCUMENTATION.md` §10 for the file map).
