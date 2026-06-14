# Godot Port Plan

## Goal

Port the current working OpenGL/GLFW C++ game to Godot 4 while preserving gameplay behavior first, then improving scene structure, assets, effects, and editor workflow.

Current game is small enough to port incrementally. Best path is not a direct OpenGL wrapper. Keep gameplay math and rules in C++, but replace windowing, input, rendering, audio, and asset loading with Godot systems.

## Context7 Findings

Context7 has official Godot GDExtension material under `/godotengine/godot-cpp` and `/godotengine/godot-docs`.

Relevant best practices from current docs:

- Use `godot-cpp` for C++ GDExtension bindings.
- Register custom classes at `MODULE_INITIALIZATION_LEVEL_SCENE`.
- Expose methods/properties through `ClassDB::bind_method()` and `ADD_PROPERTY()`.
- Prefer Godot nodes/resources for scene integration instead of custom platform code.
- Use Godot 2D rendering, imported textures, input actions, and audio nodes instead of GLFW/OpenGL/miniaudio.

## Current Game Shape

Entrypoint is `src/main.cpp` -> `runGame()` in `src/game.cpp`.

Current runtime owns everything manually:

- GLFW window and game loop.
- GLAD/OpenGL immediate-mode rendering.
- Manual PNG loading through `stb_image`.
- Manual input through GLFW.
- Manual audio through miniaudio.
- Gameplay state in plain C++ classes and structs.

Important gameplay modules:

| Current File | Responsibility | Port Target |
| --- | --- | --- |
| `game_logic.cpp` | Match rules, possession, scoring, AI team update | Keep C++ core, call from Godot match controller |
| `player.cpp` | Player state, AI movement, sprite selection | Split state/AI from rendering, expose as Godot node/resource |
| `ball.cpp` | Ball physics, spin, animation, shot VFX | Split physics from visuals, use Sprite2D/CPUParticles2D/Line2D |
| `field.cpp` | Pitch geometry rendering | Godot scene or custom `_draw()` node |
| `stadium.cpp` | Crowd animation and scoreboard | Godot scene/UI nodes |
| `input.cpp` | GLFW keyboard/mouse mapping | Godot InputMap and viewport mouse conversion |
| `audio.cpp` | miniaudio wrapper | Godot `AudioStreamPlayer` nodes |
| `utils.cpp` | Texture loading and asset paths | Godot resource paths and importer |

## Target Architecture

Use Godot as engine owner. C++ becomes gameplay extension, not app executable.

Recommended structure:

| Godot Class | Type | Responsibility |
| --- | --- | --- |
| `MatchController` | `Node2D` GDExtension | Owns teams, score, kickoff, update order, signals |
| `PlayerNode` | `Node2D` or `AnimatedSprite2D` wrapper | Displays one player, exposes role/side/start position |
| `BallNode` | `Node2D` | Displays ball, spin, trail, charge effects |
| `FieldNode` | `Node2D` | Draws field using `_draw()` or static scene sprites |
| `StadiumNode` | `Node2D` | Crowd bands and celebration visuals |
| `ScoreboardUI` | `Control` | Score and kickoff timer UI |
| `AudioController` | `Node` | Background music and SFX via Godot audio nodes |

Data-only C++ structs should remain small and engine-independent where possible:

| Model | Keep In C++ | Godot Coupling |
| --- | --- | --- |
| `PlayerState` | Position, facing, role, side, stun, kick power | None or minimal |
| `BallState` | Position, velocity, owner id, spin, charge | None or minimal |
| `MatchState` | Score, kickoff timer, possession | None or minimal |
| `InputState` | Axis, shoot state, aim point | Filled from Godot input |

## Coordinate Plan

Current game uses normalized coordinates around `[-1, 1]`.

Godot uses pixels by default.

Use a single conversion layer during phase 1:

```cpp
constexpr float WORLD_TO_PIXELS = 500.0f;

Vector2 to_godot(float x, float y) {
    return Vector2(x * WORLD_TO_PIXELS, -y * WORLD_TO_PIXELS);
}

Vector2 from_godot(Vector2 p) {
    return Vector2(p.x / WORLD_TO_PIXELS, -p.y / WORLD_TO_PIXELS);
}
```

Keep gameplay constants unchanged until parity is reached. Tune scale after game feels same.

## Phase 1: Create Godot Shell

Deliverable: Empty Godot project starts and loads a C++ GDExtension.

Tasks:

- Create `godot/` project folder with `project.godot`.
- Add `extension/` folder for `godot-cpp` and game extension sources.
- Add `.gdextension` file pointing to Linux debug/release shared libraries.
- Add SCons build for extension.
- Register one `MatchController` class using `GDREGISTER_CLASS(MatchController)`.
- Add a test scene with `MatchController` node.

Acceptance:

- Godot editor opens project.
- `MatchController` appears in Create Node dialog.
- Scene runs and prints a startup message from C++.

## Phase 2: Move Core Gameplay Into Extension

Deliverable: Match state updates in Godot without OpenGL/GLFW/miniaudio.

Tasks:

- Extract logic from `game_logic.cpp` into engine-independent model classes.
- Replace `Player* owner` with stable ids or indices to avoid pointer ownership problems across nodes.
- Keep `resetGame`, `updateBall`, and `updateTeam` behavior unchanged first.
- Add `_process(double delta)` in `MatchController` to call update functions.
- Fill `InputState` from Godot input actions.
- Convert mouse position from viewport to current world coordinates.

Acceptance:

- Players and ball positions update in logs or debug draw.
- Kickoff timer, possession, score, and AI decisions behave like current game.
- No dependency on GLFW, GLAD, OpenGL, stb_image, or miniaudio in extension core.

## Phase 3: Rebuild Rendering In Godot 2D

Deliverable: Current game visible in Godot with approximate visual parity.

Tasks:

- Import `assets/` into Godot project using `res://assets/...` paths.
- Use `Sprite2D` or `AnimatedSprite2D` for players and ball.
- Use `Node2D::_draw()` for field lines, power bars, debug shapes, and fallback visuals.
- Use `Line2D`, `Sprite2D` fade copies, or particles for ball motion blur.
- Recreate Hissatsu charge effect with `CPUParticles2D`, `GPUParticles2D`, or custom `_draw()` rings.
- Recreate stadium crowd as Godot sprites or shader/material animation.
- Recreate scoreboard as `Control` UI instead of OpenGL digit drawing.

Acceptance:

- Field, 22 players, ball, score, crowd, and charge bar render in correct order.
- Sprite orientation and running frames match current behavior.
- Special shot charge and ball trail are visible.

## Phase 4: Replace Audio And Input Properly

Deliverable: Controls and audio are native Godot systems.

Tasks:

- Define InputMap actions: `move_left`, `move_right`, `move_up`, `move_down`, `shoot`.
- Preserve WASD and Space bindings.
- Use `Input::get_singleton()` in C++ or a small GDScript bridge if faster.
- Use `AudioStreamPlayer` for music.
- Use pooled `AudioStreamPlayer` nodes for kick and whistle SFX.
- Remove miniaudio from Godot build.

Acceptance:

- Movement, aiming, charge, release, kick, and kickoff lockout work.
- Background music loops.
- Kick and referee sounds play without leaks.

## Phase 5: Scene Authoring And Editor Workflow

Deliverable: Game is editable in Godot, not hardcoded only.

Tasks:

- Move formations into exported properties or `.tres` resources.
- Expose field constants as editable properties on `MatchController`.
- Expose player speed, role, side, and sprite sets.
- Group player textures into SpriteFrames resources.
- Add scene files for `PlayerNode`, `BallNode`, `FieldNode`, `StadiumNode`, and `MatchScene`.
- Add signals from C++: `goal_scored`, `kick_started`, `special_shot_started`, `kickoff_started`.

Acceptance:

- Team formation can be adjusted in editor.
- Assets can be swapped without recompiling C++.
- UI/audio/VFX react through signals instead of direct coupling.

## Phase 6: Polish And Godot-Specific Improvements

Deliverable: Godot version is better than direct port.

Tasks:

- Use import settings for pixel art/sprites as needed.
- Add camera and resolution handling.
- Add pause/restart scene flow.
- Add controller/gamepad actions if desired.
- Add export presets after Linux build works.
- Add deterministic test scenes for ball physics and AI behavior.

Acceptance:

- Game runs from Godot editor and exported Linux build.
- Match feel is close to original.
- Code no longer relies on OpenGL immediate mode.

## Migration Order

Best order:

1. Godot shell + empty GDExtension.
2. C++ match state runs inside `MatchController`.
3. Debug draw positions with Godot `_draw()`.
4. Real sprites and field rendering.
5. Native Godot input.
6. Native Godot audio.
7. Signals and editable resources.
8. Remove obsolete OpenGL/GLFW/miniaudio code from active build.

Avoid starting with full visual rewrite. Gameplay parity first prevents losing working behavior.

## Code Refactor Needed Before Port

Small refactors will make port safer:

- Separate update logic from render functions in `Player`, `Ball`, `Field`, and `Stadium`.
- Replace OpenGL texture ids with Godot resource references or visual-node ownership.
- Replace `Player* ball.owner` with `int owner_team` and `int owner_index`, or one stable `PlayerId`.
- Replace `std::rand()` with a contained RNG so Godot and tests can seed behavior.
- Move hardcoded formation creation out of `runGame()` into a reusable factory.
- Make `deltaTime` consistently affect ball movement. Current `updateBall()` applies velocity per frame, while player movement uses `deltaTime`.

## Files To Keep Versus Retire

Keep and adapt:

- `src/game_logic.cpp`
- `src/player.cpp` AI/state parts
- `src/ball.cpp` physics/state parts
- `include/constants.hpp`
- `include/input.hpp` as data model only

Retire from Godot build:

- `src/main.cpp`
- `src/game.cpp` current GLFW loop
- `src/glad.c`
- `src/stb_image_impl.cpp`
- OpenGL render helpers from `utils.cpp`
- `src/audio.cpp` miniaudio wrapper

Rebuild as Godot nodes:

- `field.cpp` rendering
- `stadium.cpp` rendering/scoreboard
- `particle.cpp` rendering

## Risks

| Risk | Mitigation |
| --- | --- |
| Pointer ownership through `Ball::owner` breaks after node split | Use ids, not raw pointers |
| Current physics partly frame-rate dependent | Preserve first, then fix with tests |
| Rendering rewrite changes feel | Start with debug draw before sprites |
| Asset paths differ | Move assets under Godot `res://assets` and use resource loading |
| Too much C++ tied to Godot APIs | Keep model layer plain C++, wrap with thin nodes |

## First Implementation Slice

    Recommended first slice is small:

1. Add `godot/` project.
2. Add `godot/extension/` GDExtension skeleton.
3. Register `MatchController : Node2D`.
4. Copy only constants and simple `MatchState` into extension.
5. Draw field rectangle and one moving debug ball with `_draw()`.

After that slice works, port `game_logic.cpp` behavior piece by piece.
