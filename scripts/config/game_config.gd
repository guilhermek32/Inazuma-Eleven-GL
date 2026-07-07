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

# --- Gameplay tuning -----------------------------------------------------------
# Every feel-critical number of the simulation and AI lives here so balancing is a
# one-file job. Distances/speeds are in normalized field units (x in ±0.93).

# Player movement (per-role speeds: attackers edge out defenders)
const PLAYER_SPEED := 0.2            # fallback outfield speed
const GK_SPEED := 0.32               # goalkeeper shuffle speed
const ROLE_SPEED := {PlayerRole.GOALKEEPER: GK_SPEED, PlayerRole.DEFENDER: 0.19, PlayerRole.MIDFIELDER: 0.20, PlayerRole.ATTACKER: 0.215}
const SPRINT_MULT := 1.4             # speed multiplier while sprinting
# Movement momentum: players accelerate/brake instead of snapping to full speed.
const PLAYER_ACCEL := 1.2            # field units/s^2 toward the desired velocity
const PLAYER_DECEL := 1.8            # ...and a bit sharper when slowing/turning
# Knock-ahead dribble: the ball is pushed a step ahead of a running carrier and
# chases the lead point with smoothing, so it lags/swings on sharp turns.
const DRIBBLE_LEAD := 0.16           # extra ball lead per unit of carrier speed
const DRIBBLE_SMOOTH := 9.0          # per-second chase rate of the ball to its lead point
const PASS_LEAD_MAX := 0.35          # max seconds a pass leads a moving receiver
const SWITCH_PREDICT_TIME := 0.5     # switch candidate targets the ball this far ahead
const SPRINT_DRAIN := 0.35           # stamina drained per second sprinting
const SPRINT_REGEN := 0.25           # stamina regained per second otherwise

# Ball capture / tackling
const CAPTURE_RADIUS := 0.045        # outfield players
const GK_CAPTURE_RADIUS := 0.10      # keeper's normal reach
const GK_CAPTURE_RADIUS_SUPER := 0.05  # keeper's reach against a super shot
const TACKLE_STUN := 0.45            # stun on the player who loses a tackle
const TACKLE_WINDOW := 0.25          # seconds a tackle press stays "live"
const TACKLE_WHIFF_STUN := 0.5       # self-stun when a tackle wins nothing
const AI_TACKLE_RATE := 3.0          # per-second chance the AI presser lunges
const AI_TACKLE_RANGE := 0.09        # ...when this close to the carrier

# Kicking
const KICK_BASE_POWER := 0.55        # ball speed = base + charge * scale
const KICK_POWER_SCALE := 1.2
const CHARGE_RATE := 2.0             # charge fraction gained per second holding shoot
const PASS_POWER := 0.35             # fixed charge fraction used for passes
const KICK_SELF_STUN_HARD := 0.25    # post-kick stun (stops instant re-capture)
const KICK_SELF_STUN_SOFT := 0.1

# AI decision-making (rates are per-second probabilities, scaled by delta)
const AI_PRESSURE_DIST := 0.15       # opponent this close = carrier under pressure
const AI_PRESSURE_PASS_RATE := 4.0
const AI_SHOOT_RATE := 3.0
const AI_PASS_RATE := 1.8
const AI_SHOOT_RANGE_FACING := 0.50  # shooting range when facing the goal
const AI_SHOOT_RANGE := 0.30         # shooting range otherwise
const PASS_OPENNESS_RADIUS := 0.12   # receiver counts as marked inside this radius
const PASS_LANE_RADIUS := 0.035      # opponent this close to the passing lane blocks it
const PASS_RUNNER_BONUS := 6.0       # pass-score bonus per unit of receiver velocity toward goal
const PASS_BOX_BONUS := 1.5          # bonus for receivers already near the goal
const PASS_BACKWARD_PENALTY := 2.5   # score malus for passing away from goal
# AI intelligence. Decisions fire on think ticks (not per-frame dice) and
# difficulty adjusts thinking speed / aim quality rather than movement speed.
const AI_THINK_INTERVAL := 0.28      # seconds between carrier decisions (× difficulty × jitter)
const AI_AIM_ERROR := [0.05, 0.03, 0.012]   # shot aim noise by difficulty (Easy/Normal/Hard)
const AI_RUN_INTERVAL_MIN := 4.0     # seconds between an off-ball player's runs
const AI_RUN_INTERVAL_MAX := 7.0
const AI_RUN_DURATION := 2.0         # how long a run is committed to before reverting
const AI_MARK_DIST := 0.06           # goal-side marking distance from the marked opponent
const AI_DRIBBLE_SAMPLES := 5        # directions sampled when dribbling into space
# Arrive behavior: off-ball players ease into their targets and stand inside the
# dead zone instead of micro-shuffling on top of it forever.
const ARRIVE_RADIUS := 0.08
const ARRIVE_DEADZONE := 0.02

# Keeper reaction delay (s) to an inbound shot, by difficulty (Easy/Normal/Hard).
const GK_REACTION := [0.28, 0.20, 0.12]
const GK_SHOT_SPEED := 0.5           # ball speed toward goal that reads as a shot

# Off-ball movement
const ROLE_ADVANCE := {PlayerRole.DEFENDER: 0.25, PlayerRole.MIDFIELDER: 0.50, PlayerRole.ATTACKER: 0.78}
const SPACING_DIST := 0.20           # teammates closer than this push apart
const SPACING_PUSH := 0.14

# Ball flight. Heights and vertical speeds are in WORLD units (the pitch is ~56
# world units long, the crossbar sits at GOAL_HEIGHT); the 2D plane stays normalized.
const GOAL_HEIGHT := 1.8             # crossbar height, shared with PitchBuilder
const BALL_GRAVITY := 16.0           # world units/s^2 (arcade-snappy, not 9.8)
const BALL_BOUNCE := 0.45            # vertical restitution on landing
const BALL_BOUNCE_MIN := 0.9         # kill bounces below this upward speed
const AIR_FRICTION := 0.995          # per-frame-at-60fps drag while airborne
const SHOT_LOFT := 2.4               # shot vh = charge * SHOT_LOFT
const CLEARANCE_LOFT := 4.2          # keeper clearances / corner kicks arc
const CAPTURE_MAX_HEIGHT := 1.1      # outfielders can't control a ball above this
const GK_REACH_HEIGHT := 1.8         # the keeper can reach up to the bar
const HARD_SHOT_CURVE := 0.3         # max random Magnus curve (rad/s) on ordinary hard shots

# Fouls & offside (each can be disabled in Settings for arcade play)
const FOUL_BEHIND_DOT := -0.35       # tackle counts as from-behind when the tackler
                                     # sits this far behind the carrier's facing
const FREE_KICK_MIN_GOAL_DIST := 0.20  # free-kick spots are pushed out of the goalmouth
const OFFSIDE_EPS := 0.005           # tolerance on the second-to-last-defender line

# Goalkeeper dive (visual lunge toward the predicted intercept point)
const GK_DIVE_MIN_OFFSET := 0.04     # intercept must be this far from the keeper
const GK_DIVE_TIME_TO_LINE := 0.45   # ...and arriving within this many seconds
const GK_DIVE_DURATION := 0.5
const GK_DIVE_SPEED_MULT := 1.8      # burst toward the ball while diving

# Rain weather: slicker turf so the ball skids farther
const RAIN_BALL_FRICTION := 0.986
const RAIN_PARTICLES := 2500

# Restart play (throw-ins / corners / goal kicks)
const RESTART_FREEZE := 1.2          # seconds play holds while the taker sets up
const RESTART_CLEAR_DIST := 0.16     # opponents are pushed at least this far from the spot
const RESTART_SUPPORT_DIST := 0.14   # two teammates are pulled this close as pass options
const RESTART_SHIELD_TIME := 2.5     # post-freeze grace during which the taker can't be robbed
const CORNER_SPOT_X := 0.90          # normalized corner-arc restart spot
const CORNER_SPOT_Y := 0.70
const GOAL_KICK_X := 0.84            # normalized |x| where the keeper places a goal kick
const THROW_IN_MAX_X := 0.88         # throw-in spots clamp inside the corners

const MATCH_LENGTHS := [120.0, 300.0, 600.0]
const SETTINGS_PATH := "user://settings.cfg"
const BALL_FRICTION := 0.98   # velocity multiplier applied per-second (frame-rate independent via pow)

# Inazuma-style named special shots ("hissatsu"). A fully-charged user shot (or an
# occasional powerful AI shot) "evolves" into one of these: the ball gains an elemental
# aura/light in this colour, a brief slow-mo plays and the name flashes on the HUD.
const SPECIAL_SHOT_CHARGE := 0.85   # charge fraction a user shot needs to evolve
# `curve` is the signed Magnus curl (rad/s) so each special has its own flight path.
const SPECIAL_SHOTS := [
	{"name": "FIRE TORNADO", "color": Color(1.0, 0.45, 0.08), "curve": 2.2},
	{"name": "ETERNAL BLIZZARD", "color": Color(0.45, 0.85, 1.0), "curve": -2.2},
	{"name": "THE EARTHQUAKE", "color": Color(0.62, 0.85, 0.28), "curve": 0.0},
	{"name": "LIGHTNING ACCEL", "color": Color(1.0, 0.95, 0.25), "curve": -0.8},
	{"name": "TIDAL WAVE", "color": Color(0.20, 0.55, 1.0), "curve": 1.4},
	{"name": "DARK PHOENIX", "color": Color(0.85, 0.25, 0.95), "curve": -1.6},
]

## Projects a normalized 2D field point onto the 3D world. Note the sign flip:
## 2D +y maps to 3D -z.
static func to_3d(p: Vector2, height := 0.0) -> Vector3:
	return Vector3(p.x * FIELD_SCALE, height, -p.y * FIELD_SCALE)

# --- Team customization -------------------------------------------------------
# Selectable formations grouped offensive / balanced / defensive. Each lists its
# 11 players as [role, x, y] in the RED-side normalized field space (x negative);
# the blue team mirrors x. Index 0 is always the goalkeeper. Picked on the
# Choose Sides screen; consumed by MatchSimulation.create_teams().
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
