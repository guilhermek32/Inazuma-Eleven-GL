# Godot Port

This repo now contains a Godot 4 project at the repository root.

The default scene is now the 3D build:

- `scenes/main_3d.tscn`

The previous 2D port remains available as backup:

- `scenes/main.tscn`

## Run

Open this folder in Godot 4.6+ and run the main scene.

Main files:

- `project.godot`
- `scenes/main_3d.tscn`
- `scenes/main.tscn`
- `scripts/match_controller.gd`
- `scripts/match_controller_3d.gd`
- `assets/`

## What Was Ported

- 11v11 formations.
- User control with WASD.
- Space hold/release shot charging.
- Mouse aiming.
- Ball possession, wall bounce, goals, score reset, kickoff countdown.
- AI chasing, marking, passing, dribbling, shooting.
- Player sprites and running frames.
- Ball sprites, spin, trail, charge effects.
- Crowd bands and simple celebration motion.
- Music, kick SFX, referee SFX through Godot audio nodes.

## Design Choice

This first port is Godot-native and runnable-oriented. It removes GLFW, OpenGL, GLAD, stb_image, and miniaudio from the Godot runtime path by using Godot scene, draw, input, resource, and audio APIs.

The original C++ OpenGL build is still intact. `make` still builds the old version.

## 3D Build

The 3D build includes:

- Broadcast angled `Camera3D`.
- 3D pitch with modeled field lines.
- 3D goals with posts, crossbars, depth, and transparent net material.
- Imported GLB players for both teams, with per-team uniform tinting and procedural fallback safety.
- 3D ball with mapped checker material, spin, height, glow, and trail.
- Stadium stands with concrete/seat materials.
- Crowd billboard cards using existing fan assets.
- `DirectionalLight3D` moon key light.
- Four `SpotLight3D` stadium floodlights.
- `OmniLight3D` special-shot glow attached to the ball.
- World environment with sky, ambient light, tonemapping, and glow.
- Scoreboard UI and stadium scoreboard shell.
- Goal celebration confetti.

## Blue Team GLB Players

Blue team players load animated `.glb` assets from:

- `assets/obj_3d_player/`

Runtime behavior:

- Goalkeeper uses goalkeeper idle animation when available.
- Outfield players use offensive idle, jog, kick, receive, and tackle animations when available.
- Both teams use the same character mesh/animation pipeline for visual consistency.
- If a GLB is not imported or fails to load, the player falls back to the procedural mesh.

If the imported model faces the wrong way or has wrong scale, tune these constants in `scripts/match_controller_3d.gd`:

- `PLAYER_GLB_SCALE`
- `PLAYER_GLB_Y_OFFSET`
- `PLAYER_GLB_YAW_OFFSET`

## Next C++ GDExtension Step

After gameplay parity is confirmed in Godot, move the pure model parts from `scripts/match_controller.gd` into a `godot-cpp` GDExtension:

- `PlayerState`
- `BallState`
- `reset_game`
- `update_ball`
- `update_team`
- AI helpers

Keep rendering, input actions, audio nodes, and imported assets in Godot. This follows Godot best practice: C++ for hot gameplay/model code, Godot nodes/resources for engine integration.
