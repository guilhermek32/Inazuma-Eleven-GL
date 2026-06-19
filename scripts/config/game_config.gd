class_name GameConfig
extends RefCounted

## Shared constants, enums and coordinate helpers for the 3D match.
##
## Everything here is engine-agnostic configuration referenced across the
## builders, simulation and view as `GameConfig.<name>`. Field geometry uses the
## normalized 2.5D coordinate space inherited from the C++ build (x in ±0.98,
## y in ±0.78); `to_3d()` projects those onto the Godot world.

enum PlayerRole { GOALKEEPER, DEFENDER, MIDFIELDER, ATTACKER }
enum GameState { MENU, HOWTO, SETTINGS, PLAYING, PAUSED, FULLTIME, MATCH_SETUP }

# Device codes for per-team input assignment (see MatchSetup / InputReader).
# A pad device id (>= 0, as returned by Input.get_connected_joypads) means that
# gamepad drives the team; these two negatives are the special cases.
const DEVICE_AI := -2    # no human assigned — the team runs on the AI
const DEVICE_KBM := -1   # keyboard + mouse drives the team

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
const FIELD_SCALE := 30.0
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
const BALL_GLB := "res://assets/ball_trionda/fifa_trionda_ball_world_cup_2026.glb"
const BALL_RADIUS := 0.20
const PLAYER_MESH_FILE := "Ch38_nonPBR.glb"
const PLAYER_GLTF_ANIM := "Armature|mixamo.com|Layer0"
# Friendly state name -> [animation scene, should loop]. All share the Ch38 mixamorig5 rig,
# so their clips retarget onto the character mesh skeleton directly.
const PLAYER_ANIM_FILES := {
	"idle": ["offensive idle.glb", true],
	"run": ["anim/playe_run.tscn", true],
	"gk_idle": ["goalkeeper idle.glb", true],
	# Forward-facing sideways strafe shuffles for the keeper (move left / right along the line).
	"gk_left": ["gk_anim/gk left.glb", true],
	"gk_right": ["gk_anim/gk right.glb", true],
	"kick": ["kick soccerball.glb", false],
	"receive": ["receive soccerball.glb", false],
	"tackle": ["soccer tackle.glb", false],
}

const MATCH_LENGTHS := [120.0, 300.0, 600.0]
const SETTINGS_PATH := "user://settings.cfg"
const BALL_FRICTION := 0.98   # velocity multiplier applied per-second (frame-rate independent via pow)

# Inazuma-style named special shots ("hissatsu"). A fully-charged user shot (or an
# occasional powerful AI shot) "evolves" into one of these: the ball gains an elemental
# aura/light in this colour, a brief slow-mo plays and the name flashes on the HUD.
const SPECIAL_SHOT_CHARGE := 0.85   # charge fraction a user shot needs to evolve
const SPECIAL_SHOTS := [
	{"name": "FIRE TORNADO", "color": Color(1.0, 0.45, 0.08)},
	{"name": "ETERNAL BLIZZARD", "color": Color(0.45, 0.85, 1.0)},
	{"name": "THE EARTHQUAKE", "color": Color(0.62, 0.85, 0.28)},
	{"name": "LIGHTNING ACCEL", "color": Color(1.0, 0.95, 0.25)},
	{"name": "TIDAL WAVE", "color": Color(0.20, 0.55, 1.0)},
	{"name": "DARK PHOENIX", "color": Color(0.85, 0.25, 0.95)},
]

## Projects a normalized 2D field point onto the 3D world. Note the sign flip:
## 2D +y maps to 3D -z.
static func to_3d(p: Vector2, height := 0.0) -> Vector3:
	return Vector3(p.x * FIELD_SCALE, height, -p.y * FIELD_SCALE)

# --- Team customization -------------------------------------------------------
# Selectable formations grouped offensive / balanced / defensive. Each lists its
# 11 players as [role, x, y] in the RED-side normalized field space (x negative);
# the blue team mirrors x. Index 0 is always the goalkeeper. Picked on the
# Choose Sides screen; consumed by MatchSimulation._create_teams().
const FORMATIONS := [
	{"name": "4-4-2", "players": [
		[PlayerRole.GOALKEEPER, -0.93, 0.0],
		[PlayerRole.DEFENDER, -0.65, 0.27], [PlayerRole.DEFENDER, -0.65, -0.27],
		[PlayerRole.DEFENDER, -0.62, 0.55], [PlayerRole.DEFENDER, -0.62, -0.55],
		[PlayerRole.MIDFIELDER, -0.34, 0.16], [PlayerRole.MIDFIELDER, -0.34, -0.16],
		[PlayerRole.MIDFIELDER, -0.36, 0.52], [PlayerRole.MIDFIELDER, -0.36, -0.52],
		[PlayerRole.ATTACKER, -0.10, 0.22], [PlayerRole.ATTACKER, -0.10, -0.22],
	]},
	{"name": "4-3-3", "players": [
		[PlayerRole.GOALKEEPER, -0.93, 0.0],
		[PlayerRole.DEFENDER, -0.65, 0.25], [PlayerRole.DEFENDER, -0.65, -0.25],
		[PlayerRole.DEFENDER, -0.60, 0.50], [PlayerRole.DEFENDER, -0.60, -0.50],
		[PlayerRole.MIDFIELDER, -0.35, 0.0], [PlayerRole.MIDFIELDER, -0.35, 0.30],
		[PlayerRole.MIDFIELDER, -0.35, -0.30],
		[PlayerRole.ATTACKER, -0.10, 0.0], [PlayerRole.ATTACKER, -0.10, 0.40],
		[PlayerRole.ATTACKER, -0.10, -0.40],
	]},
	{"name": "3-5-2", "players": [
		[PlayerRole.GOALKEEPER, -0.93, 0.0],
		[PlayerRole.DEFENDER, -0.66, 0.0], [PlayerRole.DEFENDER, -0.64, 0.42],
		[PlayerRole.DEFENDER, -0.64, -0.42],
		[PlayerRole.MIDFIELDER, -0.35, 0.0], [PlayerRole.MIDFIELDER, -0.33, 0.28],
		[PlayerRole.MIDFIELDER, -0.33, -0.28], [PlayerRole.MIDFIELDER, -0.30, 0.55],
		[PlayerRole.MIDFIELDER, -0.30, -0.55],
		[PlayerRole.ATTACKER, -0.10, 0.20], [PlayerRole.ATTACKER, -0.10, -0.20],
	]},
	{"name": "5-3-2", "players": [
		[PlayerRole.GOALKEEPER, -0.93, 0.0],
		[PlayerRole.DEFENDER, -0.68, 0.0], [PlayerRole.DEFENDER, -0.66, 0.30],
		[PlayerRole.DEFENDER, -0.66, -0.30], [PlayerRole.DEFENDER, -0.62, 0.58],
		[PlayerRole.DEFENDER, -0.62, -0.58],
		[PlayerRole.MIDFIELDER, -0.35, 0.0], [PlayerRole.MIDFIELDER, -0.35, 0.32],
		[PlayerRole.MIDFIELDER, -0.35, -0.32],
		[PlayerRole.ATTACKER, -0.10, 0.22], [PlayerRole.ATTACKER, -0.10, -0.22],
	]},
	{"name": "3-4-3", "players": [
		[PlayerRole.GOALKEEPER, -0.93, 0.0],
		[PlayerRole.DEFENDER, -0.65, 0.0], [PlayerRole.DEFENDER, -0.63, 0.45],
		[PlayerRole.DEFENDER, -0.63, -0.45],
		[PlayerRole.MIDFIELDER, -0.35, 0.18], [PlayerRole.MIDFIELDER, -0.35, -0.18],
		[PlayerRole.MIDFIELDER, -0.37, 0.52], [PlayerRole.MIDFIELDER, -0.37, -0.52],
		[PlayerRole.ATTACKER, -0.10, 0.0], [PlayerRole.ATTACKER, -0.10, 0.40],
		[PlayerRole.ATTACKER, -0.10, -0.40],
	]},
	{"name": "4-5-1", "players": [
		[PlayerRole.GOALKEEPER, -0.93, 0.0],
		[PlayerRole.DEFENDER, -0.65, 0.25], [PlayerRole.DEFENDER, -0.65, -0.25],
		[PlayerRole.DEFENDER, -0.62, 0.55], [PlayerRole.DEFENDER, -0.62, -0.55],
		[PlayerRole.MIDFIELDER, -0.35, 0.0], [PlayerRole.MIDFIELDER, -0.33, 0.28],
		[PlayerRole.MIDFIELDER, -0.33, -0.28], [PlayerRole.MIDFIELDER, -0.32, 0.56],
		[PlayerRole.MIDFIELDER, -0.32, -0.56],
		[PlayerRole.ATTACKER, -0.10, 0.0],
	]},
]
const DEFAULT_FORMATION := 1   # 4-3-3

# Kit colour palette shown on the Choose Sides screen, picked per piece
# (shirt / shorts / boots) for each team.
const KIT_PALETTE := [
	{"name": "Vermelho", "color": Color(0.85, 0.05, 0.03)},
	{"name": "Azul", "color": Color(0.06, 0.22, 0.88)},
	{"name": "Verde", "color": Color(0.10, 0.55, 0.18)},
	{"name": "Amarelo", "color": Color(0.95, 0.82, 0.10)},
	{"name": "Branco", "color": Color(0.92, 0.92, 0.92)},
	{"name": "Preto", "color": Color(0.05, 0.05, 0.06)},
	{"name": "Laranja", "color": Color(0.95, 0.45, 0.05)},
	{"name": "Roxo", "color": Color(0.45, 0.12, 0.70)},
	{"name": "Ciano", "color": Color(0.10, 0.65, 0.75)},
	{"name": "Rosa", "color": Color(0.90, 0.30, 0.55)},
]
# Default kits: Time A red shirt, Time B blue shirt; both white shorts + black boots.
const DEFAULT_KIT_A := {"shirt": 0, "shorts": 4, "boots": 5}
const DEFAULT_KIT_B := {"shirt": 1, "shorts": 4, "boots": 5}
