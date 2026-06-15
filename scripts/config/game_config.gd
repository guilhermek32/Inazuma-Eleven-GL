class_name GameConfig
extends RefCounted

## Shared constants, enums and coordinate helpers for the 3D match.
##
## Everything here is engine-agnostic configuration referenced across the
## builders, simulation and view as `GameConfig.<name>`. Field geometry uses the
## normalized 2.5D coordinate space inherited from the C++ build (x in ±0.98,
## y in ±0.78); `to_3d()` projects those onto the Godot world.

enum PlayerRole { GOALKEEPER, DEFENDER, MIDFIELDER, ATTACKER }
enum GameState { MENU, HOWTO, SETTINGS, PLAYING, PAUSED, FULLTIME }

const FIELD_HALF_WIDTH := 0.98
const FIELD_HALF_HEIGHT := 0.78
const FIELD_BOUNDARY_X := 0.93
const FIELD_BOUNDARY_Y := 0.73
const PENALTY_AREA_WIDTH := 0.22
const PENALTY_AREA_HEIGHT := 0.32
const GOAL_AREA_WIDTH := 0.10
const GOAL_AREA_HEIGHT := 0.20
const PENALTY_SPOT_DIST := 0.15
const CENTER_CIRCLE_RADIUS := 0.16
const CORNER_ARC_RADIUS := 0.035
const FIELD_SCALE := 24.0
# Goal is pinned to a fixed world size so it doesn't balloon with the larger field.
const GOAL_WORLD_HALF_WIDTH := 3.24   # 0.18 * 18 — real goal half-width in world units
const GOAL_WORLD_DEPTH := 0.9          # 0.05 * 18 — real goal depth in world units
const GOAL_HALF_WIDTH := GOAL_WORLD_HALF_WIDTH / FIELD_SCALE
const GOAL_DEPTH := GOAL_WORLD_DEPTH / FIELD_SCALE
const PITCH_Y := 0.0
const PLAYER_GLB_SCALE := 1.14
const PLAYER_GLB_Y_OFFSET := 0.0
const PLAYER_GLB_YAW_OFFSET := 0.0
const PLAYER_ASSET_DIR := "res://assets/obj_3d_player/"
const PLAYER_MESH_FILE := "Ch38_nonPBR.glb"
const PLAYER_GLTF_ANIM := "Armature|mixamo.com|Layer0"
# Friendly state name -> [animation scene, should loop]. All share the Ch38 mixamorig5 rig,
# so their clips retarget onto the character mesh skeleton directly.
const PLAYER_ANIM_FILES := {
	"idle": ["offensive idle.glb", true],
	"run": ["anim/playe_run.tscn", true],
	"gk_idle": ["goalkeeper idle.glb", true],
	"kick": ["kick soccerball.glb", false],
	"receive": ["receive soccerball.glb", false],
	"tackle": ["soccer tackle.glb", false],
}

const MATCH_LENGTHS := [120.0, 300.0, 600.0]
const SETTINGS_PATH := "user://settings.cfg"

## Projects a normalized 2D field point onto the 3D world. Note the sign flip:
## 2D +y maps to 3D -z.
static func to_3d(p: Vector2, height := 0.0) -> Vector3:
	return Vector3(p.x * FIELD_SCALE, height, -p.y * FIELD_SCALE)
