class_name MatchConfig
extends RefCounted

## Gameplay-only configuration of one match: everything the rules need and
## nothing the presentation or the local player's preferences own (camera,
## audio, window). Built from the local settings/setup screen offline, or from
## the lobby's provisioning request online, then handed to MatchSession.
##
## Treat an instance as immutable once a session is initialized with it:
## MatchSession keeps its own private copy (see copy()), so later edits to the
## caller's instance never reach a running match.
##
## Wire form: to_dict()/from_dict() round-trip through plain JSON-safe values.
## from_dict() returns null for anything invalid; validate() names the problem.

const VERSION := 1

# AI intelligence by difficulty (0 Easy, 1 Normal, 2 Hard). Difficulty is
# intelligence, not velocity: harder AI thinks faster, aims better and lunges
# more decisively; the speed spread stays nearly flat.
const DIFFICULTY_PROFILES := [
	{"speed": 0.95, "decision": 0.7, "think": 1.5, "aim_error": GameConfig.AI_AIM_ERROR[0], "gk_reaction": GameConfig.GK_REACTION[0]},
	{"speed": 1.0, "decision": 1.0, "think": 1.0, "aim_error": GameConfig.AI_AIM_ERROR[1], "gk_reaction": GameConfig.GK_REACTION[1]},
	{"speed": 1.05, "decision": 1.4, "think": 0.7, "aim_error": GameConfig.AI_AIM_ERROR[2], "gk_reaction": GameConfig.GK_REACTION[2]},
]
const DIFFICULTY_NORMAL := 1

const MIN_HALF_LENGTH_S := 30.0
const MAX_HALF_LENGTH_S := 900.0

var version := VERSION
var half_length_s := 120.0
# Per team (index 0 = red, 1 = blue): formation index into GameConfig.FORMATIONS
# and kit as KIT_PALETTE indices {"shirt", "shorts", "boots"}.
var formations: Array[int] = [GameConfig.DEFAULT_FORMATION, GameConfig.DEFAULT_FORMATION]
var kits: Array[Dictionary] = [GameConfig.DEFAULT_KIT_A.duplicate(), GameConfig.DEFAULT_KIT_B.duplicate()]
# Difficulty profile driving each team's AI players. A human-led team's AI
# teammates play at Normal; an all-AI opponent plays at the chosen difficulty.
var team_difficulty: Array[int] = [DIFFICULTY_NORMAL, DIFFICULTY_NORMAL]
var fouls_enabled := true
var offside_enabled := false
var weather := 0   # 0 Clear, 1 Rain

func ai_profile(team_idx: int) -> Dictionary:
	return DIFFICULTY_PROFILES[team_difficulty[team_idx]]

func ball_friction() -> float:
	return GameConfig.RAIN_BALL_FRICTION if weather == 1 else GameConfig.BALL_FRICTION

func copy() -> MatchConfig:
	return MatchConfig.from_dict(to_dict())

## Returns "" when the config is playable, otherwise a short reason.
func validate() -> String:
	if version != VERSION:
		return "unsupported config version %d" % version
	if half_length_s < MIN_HALF_LENGTH_S or half_length_s > MAX_HALF_LENGTH_S:
		return "half_length_s out of range"
	if weather < 0 or weather > 1:
		return "weather out of range"
	for t in 2:
		if formations[t] < 0 or formations[t] >= GameConfig.FORMATIONS.size():
			return "formation out of range"
		if team_difficulty[t] < 0 or team_difficulty[t] >= DIFFICULTY_PROFILES.size():
			return "difficulty out of range"
		for part in ["shirt", "shorts", "boots"]:
			var idx = kits[t].get(part, -1)
			if typeof(idx) != TYPE_INT or idx < 0 or idx >= GameConfig.KIT_PALETTE.size():
				return "kit %s out of range" % part
	return ""

func to_dict() -> Dictionary:
	return {
		"version": version,
		"half_length_s": half_length_s,
		"formations": [formations[0], formations[1]],
		"kits": [kits[0].duplicate(), kits[1].duplicate()],
		"team_difficulty": [team_difficulty[0], team_difficulty[1]],
		"fouls_enabled": fouls_enabled,
		"offside_enabled": offside_enabled,
		"weather": weather,
	}

## Parses a wire/JSON dictionary. JSON numbers arrive as floats, so integral
## fields are converted explicitly. Returns null if a field is missing,
## mistyped or out of range.
static func from_dict(d: Dictionary) -> MatchConfig:
	var c := MatchConfig.new()
	if not _has_number(d, "version") or not _has_number(d, "half_length_s") or not _has_number(d, "weather"):
		return null
	if typeof(d.get("fouls_enabled")) != TYPE_BOOL or typeof(d.get("offside_enabled")) != TYPE_BOOL:
		return null
	for key in ["formations", "kits", "team_difficulty"]:
		if typeof(d.get(key)) != TYPE_ARRAY or d[key].size() != 2:
			return null
	c.version = int(d.version)
	c.half_length_s = float(d.half_length_s)
	c.weather = int(d.weather)
	c.fouls_enabled = d.fouls_enabled
	c.offside_enabled = d.offside_enabled
	for t in 2:
		if not _is_number(d.formations[t]) or not _is_number(d.team_difficulty[t]) or typeof(d.kits[t]) != TYPE_DICTIONARY:
			return null
		c.formations[t] = int(d.formations[t])
		c.team_difficulty[t] = int(d.team_difficulty[t])
		var kit := {}
		for part in ["shirt", "shorts", "boots"]:
			if not _is_number(d.kits[t].get(part)):
				return null
			kit[part] = int(d.kits[t][part])
		c.kits[t] = kit
	if c.validate() != "":
		return null
	return c

static func _has_number(d: Dictionary, key: String) -> bool:
	return d.has(key) and _is_number(d[key])

static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT
