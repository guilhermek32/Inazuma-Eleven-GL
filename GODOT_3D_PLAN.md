# Godot 3D Port Plan

## Goal

Create a separate 3D Godot version of the football game while keeping the current 2D scene as backup.

Target scene:

```text
scenes/main_3d.tscn
```

Backup scene:

```text
scenes/main.tscn
```

Camera style:

```text
Broadcast angled camera
```

The 3D version should satisfy the project criteria:

- Use lighting and texture techniques.
- Create model lighting with different light sources.
- Explore geometric aspects and lighting models.
- Apply texture mapping to objects.
- Refine previous modeling work.
- Prioritize realism because realism is 60% of the grade.

## Main Strategy

Use a 2.5D gameplay model with full 3D presentation.

Gameplay stays on a flat football field plane. Existing 2D logic can still drive movement, AI, possession, passing, shooting, goals, and score.

3D visuals convert old 2D coordinates into 3D coordinates:

```gdscript
const FIELD_SCALE := 18.0

func to_3d(p: Vector2) -> Vector3:
	return Vector3(p.x * FIELD_SCALE, 0.0, -p.y * FIELD_SCALE)
```

This keeps the game playable while allowing realistic 3D lighting, shadows, materials, stadium, camera, and VFX.

## Target Scene Tree

```text
Main3D (Node3D)
CameraRig (Node3D)
Camera3D
WorldEnvironment
SunLight (DirectionalLight3D)
FloodLights (Node3D)
Pitch (Node3D)
FieldLines (Node3D)
Goals (Node3D)
Stadium (Node3D)
Players (Node3D)
Ball (Node3D)
VFX (Node3D)
CanvasLayer
ScoreboardUI
```

## Files To Create

Scenes:

```text
scenes/main_3d.tscn
```

Scripts:

```text
scripts/match_controller_3d.gd
scripts/player_3d.gd
scripts/ball_3d.gd
scripts/stadium_3d.gd
scripts/camera_broadcast.gd
```

Materials:

```text
materials/grass_material.tres
materials/player_red_material.tres
materials/player_blue_material.tres
materials/player_goalkeeper_material.tres
materials/ball_material.tres
materials/goal_metal_material.tres
materials/net_material.tres
materials/concrete_material.tres
materials/scoreboard_emission_material.tres
materials/crowd_card_material.tres
```

Optional texture folder:

```text
textures/3d/
```

## Renderer Plan

Current project uses Compatibility renderer for 2D/OpenGL-style safety.

For realistic 3D, use Forward+.

Recommended later change in `project.godot` after 3D scene works:

```ini
[rendering]

renderer/rendering_method="forward_plus"
renderer/rendering_method.mobile="mobile"
```

Why Forward+:

- Better 3D lighting.
- Better shadows.
- Supports more advanced light behavior.
- Better for bloom/glow and realistic material response.

Risk:

- More GPU cost than Compatibility.

Mitigation:

- Keep light count controlled.
- Use shadows only on important lights.
- Start with one sun and four floodlights.

## Camera Plan

Use fixed broadcast angled camera first.

Recommended initial values:

```text
Position: Vector3(0, 18, 24)
Look at: Vector3(0, 0, 0)
FOV: 45 to 55
```

Phase 1:

- Fixed camera sees full pitch.

Phase 2:

- Smoothly pan camera toward ball.
- Keep field readable.
- Avoid fast camera movement.

Phase 3:

- Add subtle zoom during special shots.
- Add goal celebration camera shake or cut.

## Lighting Plan

### DirectionalLight3D: Sun

Purpose:

- Main natural light.
- Long shadows.
- Outdoor stadium realism.

Settings:

```text
Type: DirectionalLight3D
Color: warm white
Energy: 0.8 to 1.2
Shadows: enabled
Angular distance: 0.5 to 1.0
Rotation: diagonal across field
```

Grade value:

- Shows model lighting.
- Shows geometric shadows.
- Gives depth to players, ball, goals, and stands.

### SpotLight3D: Stadium Floodlights

Purpose:

- Artificial light sources.
- Strong realism signal.
- Different light source type from sun.

Use:

```text
4 corner towers minimum
6 lights better
Aim at field center
Cool white color
Shadows enabled on 2 or 4 lights
```

Settings:

```text
Type: SpotLight3D
Range: large enough to cover pitch
Spot angle: 35 to 55 degrees
Energy: 3 to 8
Light size: 0.5 to 2.0 for softer shadows
```

Grade value:

- Demonstrates different light sources.
- Demonstrates directed light cones.
- Creates stadium realism.

### OmniLight3D: Special Shot Glow

Purpose:

- Temporary local light on ball.
- Special shot effect.
- Shows dynamic lighting.

Use:

```text
Attach to ball during charged/special shot
Color changes by power
Short range
Fast fade out after kick
```

Colors:

```text
Low power: blue/cyan
Medium power: orange
High power: gold/white
```

Grade value:

- Shows dynamic light source.
- Supports Inazuma-style special shot fantasy.

### WorldEnvironment

Purpose:

- Ambient light.
- Sky color.
- Tonemapping.
- Bloom/glow.

Settings:

```text
Ambient light: low-medium
Sky: outdoor stadium color
Glow: enabled for special shots and scoreboard
Tonemap: filmic or ACES if available
```

Grade value:

- Improves realism.
- Makes scene less flat.
- Supports emissive scoreboard and VFX.

## Texture Mapping Plan

Use `StandardMaterial3D` for all important objects.

Godot 4.6 material maps to use:

```text
albedo_texture
normal_map
roughness_texture
metallic_texture
ao_texture
emission_texture
uv1_scale
```

Minimum required textured objects:

- Grass pitch.
- Ball.
- Player uniforms.
- Goal net.
- Concrete/stadium stands.
- Scoreboard.
- Crowd cards.

## Object Modeling Plan

### Pitch

Geometry:

- Large flat plane.
- Slightly raised border.
- Field lines as thin white meshes.
- Center circle.
- Penalty boxes.
- Goal boxes.

Material:

- Grass albedo texture.
- Grass normal map.
- Roughness map or roughness value around 0.7.
- UV tiling so grass repeats naturally.

Missing now:

- 3D grass material.
- Normal map.
- Field-line meshes.

Need add:

- `PlaneMesh` or `BoxMesh` pitch.
- Grass texture.
- White field line meshes.

### Goals

Geometry:

- Cylinders for posts.
- Cylinder for crossbar.
- Thin net plane or mesh grid.
- Goal depth behind line.

Material:

- White painted metal material.
- Transparent net material.
- Optional alpha texture for net pattern.

Missing now:

- 3D posts.
- 3D net.
- Transparent net texture.

Need add:

- Goal model built from primitives.
- Net material with alpha.

### Ball

Geometry:

- `SphereMesh`.
- Rotates based on velocity.
- Small Y offset above ground.
- Optional bounce/arc during pass and shot.

Material:

- Football albedo texture.
- Roughness around 0.35 to 0.55.
- Optional normal map.

Missing now:

- Football sphere texture.
- Ball normal map.
- Shot trail in 3D.

Need add:

- `Ball3D` node.
- `SphereMesh`.
- Ball texture or procedural black/white material.
- Trail particles.

### Players

First version should use procedural low-poly players.

Geometry per player:

- Capsule or cylinder torso.
- Sphere head.
- Cylinder arms.
- Cylinder legs.
- Feet as small boxes.

Materials:

- Red uniform.
- Blue uniform.
- Goalkeeper material.
- Skin material.
- Hair material.

Animation:

- Rotate body toward facing direction.
- Swing arms/legs while moving.
- Idle stance while stopped.
- Kick pose on shot.

Missing now:

- True 3D humanoid models.
- Rigged skeletons.
- Running animation clips.
- Uniform texture maps.

Need add:

- Procedural body script first.
- Better models later if time.

### Stadium

Geometry:

- Stands around field.
- Tiered seating blocks.
- Barriers/fences.
- Floodlight towers.
- Scoreboard.

Materials:

- Concrete texture.
- Seat colors.
- Emissive scoreboard.
- Crowd card material.

Crowd:

- Use existing fan sprites on billboard planes.
- Spread across stands.
- Vary red/blue cards.
- Animate small vertical bounce during goals.

Missing now:

- 3D stands.
- Real crowd placement.
- Floodlight towers.
- Concrete texture.

Need add:

- Stadium primitive geometry.
- Crowd billboard cards.
- Scoreboard mesh with emission.

## Gameplay Plan

Keep current behavior:

- 11v11 teams.
- User controls nearest eligible teammate.
- AI chases, marks, passes, dribbles, shoots.
- Ball possession.
- Goal detection.
- Kickoff timer.
- Scoreboard.

3D-specific input:

- WASD moves controlled player on X/Z plane.
- Mouse ray projects onto field plane for aiming.
- Space charges shot.
- Release Space kicks toward aim or facing direction, depending chosen behavior.

Mouse-to-field projection:

```gdscript
var camera := get_viewport().get_camera_3d()
var mouse := get_viewport().get_mouse_position()
var ray_origin := camera.project_ray_origin(mouse)
var ray_dir := camera.project_ray_normal(mouse)
var plane := Plane(Vector3.UP, 0.0)
var hit := plane.intersects_ray(ray_origin, ray_dir)
```

## VFX Plan

Special shot:

- Ball emission material.
- 3D particles behind ball.
- Temporary `OmniLight3D`.
- Glow/bloom.
- Camera shake or slight zoom.

Goal celebration:

- Crowd bounce.
- Confetti particles.
- Scoreboard flash.
- Floodlight pulse.

Power charge:

- Ring around player feet.
- Colored light growing with power.
- Particle swirl near ball.

## UI Plan

Use `CanvasLayer` for score and timer.

UI elements:

- Score label.
- Kickoff timer.
- Optional power meter.
- Optional selected-player indicator.

3D indicators:

- Ring under controlled player.
- Power ring around ball/player.
- Arrow or line for shot direction.

## Implementation Phases

### Phase 1: 3D Shell

Deliverable:

- `main_3d.tscn` opens with camera, light, environment, and basic pitch.

Tasks:

- Create `Main3D` scene.
- Add `Camera3D` at broadcast angle.
- Add `WorldEnvironment`.
- Add `DirectionalLight3D`.
- Add basic pitch plane.
- Add simple grass material.

Acceptance:

- Scene runs.
- Field visible.
- Shadows visible.

### Phase 2: Field And Goals

Deliverable:

- Football field looks like 3D pitch.

Tasks:

- Add field lines.
- Add center circle.
- Add penalty boxes.
- Add goals.
- Add net.

Acceptance:

- Field is recognizable.
- Goal geometry has depth.
- Texture mapping visible.

### Phase 3: 3D Ball

Deliverable:

- Ball moves in 3D scene.

Tasks:

- Add sphere mesh.
- Add ball material.
- Convert 2D ball state to 3D transform.
- Add rotation by velocity.
- Add shadow.

Acceptance:

- Ball follows gameplay state.
- Ball rotates while moving.

### Phase 4: 3D Players

Deliverable:

- 22 players visible and moving.

Tasks:

- Add procedural player model.
- Add team materials.
- Add facing rotation.
- Add simple run animation.
- Add selected-player ring.

Acceptance:

- Red and blue teams visible.
- Players face movement/kick direction.
- Motion is readable.

### Phase 5: Playable 3D Match

Deliverable:

- Game playable in 3D.

Tasks:

- Reuse or port match state from 2D controller.
- Add WASD movement.
- Add mouse aim via raycast to field plane.
- Add Space charge/release.
- Add AI movement.
- Add score/kickoff.

Acceptance:

- Match can be played.
- Passing/shooting works.
- Goals update score.

### Phase 6: Lighting Polish

Deliverable:

- Lighting criteria clearly visible.

Tasks:

- Add sun shadows.
- Add floodlight towers.
- Add 4 to 6 spotlights.
- Add dynamic ball light for special shot.
- Tune environment and ambient light.
- Enable glow/bloom.

Acceptance:

- Multiple light types visible.
- Shadows visible.
- Special shot lights scene.

### Phase 7: Texture Polish

Deliverable:

- Major objects have mapped textures.

Tasks:

- Add grass albedo/normal/roughness.
- Add ball texture.
- Add uniform materials/textures.
- Add concrete texture to stands.
- Add net alpha texture.
- Add scoreboard emission texture/material.

Acceptance:

- Texture mapping is obvious.
- Surfaces are not flat colors only.
- UV tiling is clean.

### Phase 8: Realism Polish

Deliverable:

- Higher-grade presentation.

Tasks:

- Add better crowd layout.
- Add confetti.
- Add camera smoothing.
- Add player shadows.
- Add ball shadow and bounce.
- Add stadium details.
- Add sky/fog/tonemapping.

Acceptance:

- Scene feels like stadium match.
- Lighting/texturing/modeling improvements are visible.

## What Will Be Missing After First 3D Version

Likely missing:

- True rigged humanoid players.
- Professional running/kicking animations.
- Real football UV texture.
- Full PBR texture set for all materials.
- Real crowd models.
- Referee model.
- Benches.
- Stadium seats as individual geometry.
- Advanced grass shader.
- Net physics.
- Replay/cinematic camera.
- Menus.

These are not required for first playable 3D version, but improve realism and grade.

## What You Need To Add For Higher Grade

Highest impact additions:

1. Grass albedo + normal + roughness textures.
2. Ball texture mapped on sphere.
3. Goal net transparent texture.
4. Floodlight towers with `SpotLight3D` shadows.
5. Sun `DirectionalLight3D` with soft shadows.
6. Concrete/stadium texture.
7. Player uniform materials or textures.
8. Emissive scoreboard.
9. Bloom/glow for special shots.
10. Crowd billboard cards using existing fan assets.
11. Smooth broadcast camera.
12. Confetti/celebration particles.

Optional external assets:

- Free PBR grass texture.
- Free PBR concrete texture.
- Free football texture.
- Free low-poly player model.
- Free stadium/seat texture.
- Free net alpha texture.

## Risks And Mitigation

| Risk | Mitigation |
| --- | --- |
| 3D port becomes too large | Keep gameplay 2D, only convert visuals to 3D |
| Player models take too long | Use procedural primitive players first |
| Too many lights hurt performance | Start with 1 sun + 4 floodlights |
| Texture UVs look bad | Use simple planes/boxes and UV scale first |
| Scene loses playability | Port gameplay after field/ball/player basics are visible |
| Compatibility renderer limits visuals | Move 3D scene to Forward+ after it opens |

## Main Scene Switch

Keep 2D backup:

```ini
run/main_scene="res://scenes/main.tscn"
```

After 3D is playable, switch to:

```ini
run/main_scene="res://scenes/main_3d.tscn"
```

Do not switch before 3D scene is playable.

## Minimum Definition Of Done

- `scenes/main_3d.tscn` exists.
- Broadcast `Camera3D` works.
- 3D pitch visible.
- 3D goals visible.
- 22 players visible.
- Ball visible and moving.
- Match playable.
- Score and kickoff work.
- Sun + floodlights + special shot light exist.
- Grass, ball, uniforms, goals, stadium have materials/textures.
- Shadows visible.

## Good Grade Definition Of Done

- Multiple light sources are clear and intentional.
- Textures use UV mapping and repeat correctly.
- Shadows add depth to players/ball/goals.
- Materials react differently to light.
- Stadium has geometry and crowd detail.
- Special shots use glow, particles, and dynamic light.
- Camera gives realistic broadcast feel.
- Scene looks more realistic than the original 2D/OpenGL version.
