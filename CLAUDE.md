# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Layout: Three Parallel Implementations

This repo contains three implementations of the same arcade 11v11 football game, side by side:

1. **Original C++/OpenGL build** — `src/`, `include/`, `Makefile`. Immediate-mode OpenGL + GLFW + miniaudio. Still buildable; treated as the reference/backup. Full architecture docs in `PROJECT_DOCUMENTATION.md`.
2. **Godot 2D port** — `scripts/match_controller.gd` + `scenes/main.tscn`. Kept as backup.
3. **Godot 3D port** — `scripts/match_controller_3d.gd` + `scenes/main_3d.tscn`. The project's main scene and where active development happens (branch `3d-version`). Plan and rationale in `GODOT_3D_PLAN.md`; realism is the priority (it is the bulk of the grade for this university project).

There are no tests and no linter.

## Commands

C++ build (Linux, needs `libglfw3-dev libgl1-mesa-dev`):

```bash
make            # builds ./InazumaElevenGL
./InazumaElevenGL
make clean
```

Godot project (Godot 4.6, root `project.godot`, main scene `scenes/main_3d.tscn`): open the repo root in the Godot editor and run, or headless smoke-test for script errors:

```bash
godot --headless --quit-after 300   # local binary: ~/Downloads/Godot_v4.6.3-stable_linux.x86_64
godot --headless --check-only --script scripts/match_controller_3d.gd
```

## Godot 3D Architecture (the big picture)

**Everything lives in one script.** `scenes/main_3d.tscn` is a single `Node3D` with `match_controller_3d.gd` attached; the entire scene — pitch, goals, stadium, crowd, lights, environment, players, ball, UI, input actions — is constructed procedurally in `_ready()`. The `.tscn` files and `materials/*.tres` contain almost nothing; materials used at runtime are built in `_build_materials()`. To change visuals or gameplay, edit the script, not scenes.

**2.5D gameplay model.** Game logic runs in normalized 2D coordinates inherited from the C++ version: `x ∈ ±0.98`, `y ∈ ±0.78` (playable boundary `±0.93 / ±0.73`), with all state in plain inner classes (`PlayerState`, `BallState`) — no physics engine, no CharacterBody/RigidBody. Visuals convert via `to_3d(p: Vector2)`: world = `(x * FIELD_SCALE, height, -y * FIELD_SCALE)` with `FIELD_SCALE = 18.0`. Note the sign flip: 2D `+y` is 3D `-z`.

**Conventions in the logic:**
- Red team `side = -1`, starts on `-x`, attacks `+x`; blue `side = +1` attacks `-x`. Red is the user team, blue is full AI.
- Ball possession is `ball.owner_team` / `ball.owner_index` (`-1` = loose ball); while owned, the ball is glued to the owner's feet and physics is skipped. Capture/steal happens in `_try_capture_ball` by distance check.
- The user controls the team member nearest to the ball (`_nearest_user_player`); the rest of the red team runs the same AI as blue. Player roles come from the `PlayerRole` enum and drive formation targets and AI behavior.
- Per-frame flow in `_process`: input → kickoff timer → ball physics/goal detection → red team update → blue team update → visuals/camera → VFX → scoreboard.
- AI random decisions (shoot/pass chances) must be scaled by `delta` to stay frame-rate independent.

**Controls:** WASD moves the selected player, hold/release Space charges/releases a shot, mouse aims (ray-cast onto the ground plane). Input actions are registered in code in `_setup_input_actions()`, not in `project.godot`.

The 2D port (`match_controller.gd`) shares the same logic structure and coordinate system, drawn with Godot 2D APIs; fixes to gameplay logic usually have a sibling location there. The C++ version mirrors this layout across `src/game_logic.cpp`, `src/player.cpp`, `src/ball.cpp` (see `PROJECT_DOCUMENTATION.md` §10 for the file map).
