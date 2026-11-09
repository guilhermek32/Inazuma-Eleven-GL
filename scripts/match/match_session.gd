class_name MatchSession
extends RefCounted

## One match's rules and flow, independent of any scene, device or network.
##
## Owns the MatchSimulation (ball, players, restarts) plus everything around it
## that used to live in the 3D controller: the match clock, halves, the goal
## celebration freeze, the half-time pause and special-shot slow motion. The
## offline controller and the online match runtime drive the same component:
##
##   initialize(config, seed)   once per match (may be called again to restart)
##   submit_input(team, input)  any time before step(); human teams only
##   step(dt)                   one fixed tick of real (unscaled) time
##   read_state()               match-level summary for HUD / snapshots
##   drain_events()             gameplay events since the last drain, in order
##
## Ownership: the session owns `sim` and `ai` and frees them in dispose(). The
## caller may read sim state for rendering but must not mutate gameplay fields.
## Teams' `device` is the only per-team field a caller sets (set_team_device),
## before initialize().
##
## Time: step(dt) takes real time. Slow motion is this session's own
## `time_scale` (never Engine.time_scale), applied exactly once to the sim and
## the match clock; the slow-mo countdown itself runs on real time. Several
## sessions in one process therefore never affect each other.
##
## Events are Dictionaries {"tick": int, "type": String, ...payload}. Types:
##   goal {scorer, goal_side, impact: Vector3 (field x, field y, height)}
##   kick, field_reset, special {name, color, team}
##   restart {restart_type, team}, foul {team, spot: Vector2}, offside {team}
##   player_action {team, index, action, duration}
##   half_time, full_time {score_left, score_right, stats}

enum Phase { PLAYING, GOAL_FREEZE, HALFTIME, FULLTIME }

const GOAL_FREEZE_TIME := 2.2
const HALFTIME_PAUSE := 2.0
const SLOWMO_SCALE := 0.45
const SLOWMO_TIME := 0.52   # real seconds a special-shot slow-mo lasts

var sim: MatchSimulation
var ai: AIController
var config: MatchConfig

var phase := Phase.PLAYING
var tick := 0
var match_time := 0.0
var current_half := 1
var halftime_pause := 0.0
var goal_freeze := 0.0
var time_scale := 1.0
var _slowmo_left := 0.0
var _events: Array[Dictionary] = []

func _init() -> void:
	sim = MatchSimulation.new()
	ai = AIController.new()
	ai.sim = sim
	sim.ai = ai
	sim.goal_scored.connect(_on_goal_scored)
	sim.ball_kicked.connect(func() -> void: _push("kick"))
	sim.special_fired.connect(_on_special_fired)
	sim.field_reset.connect(func() -> void: _push("field_reset"))
	sim.restart_awarded.connect(func(type: int, team: int) -> void: _push("restart", {"restart_type": type, "team": team}))
	sim.foul_committed.connect(func(team: int, spot: Vector2) -> void: _push("foul", {"team": team, "spot": spot}))
	sim.offside_called.connect(func(team: int) -> void: _push("offside", {"team": team}))
	sim.player_action.connect(func(team: int, index: int, action: String, duration: float) -> void:
		_push("player_action", {"team": team, "index": index, "action": action, "duration": duration}))
	config = MatchConfig.new()

## Frees the simulation. The session is unusable afterwards.
func dispose() -> void:
	if is_instance_valid(sim):
		sim.free()
	sim = null

func set_team_device(team_idx: int, device: int) -> void:
	sim.teams[team_idx].device = device

## Starts a fresh match. The RNG is seeded before any team is built, so the
## same (config, seed, inputs) replays identically within one engine build.
func initialize(cfg: MatchConfig, seed: int) -> void:
	assert(cfg.validate() == "", "MatchSession.initialize: invalid MatchConfig")
	config = cfg.copy()
	sim.config = config
	sim.seed_rng(seed)
	for t in 2:
		sim.teams[t].formation = config.formations[t]
		sim.teams[t].kit = MatchSimulation.kit_colors(config.kits[t])
		sim.teams[t].input = InputSnapshot.new()
	sim.create_teams()
	sim.reset_stats()
	sim.set_default_ends()
	sim.ball.friction = config.ball_friction()
	sim.score_left = 0
	sim.score_right = 0
	phase = Phase.PLAYING
	tick = 0
	match_time = 0.0
	current_half = 1
	halftime_pause = 0.0
	goal_freeze = 0.0
	time_scale = 1.0
	_slowmo_left = 0.0
	_events.clear()
	sim.reset_game(1)

func submit_input(team_idx: int, input: InputSnapshot) -> void:
	sim.teams[team_idx].input = input

func step(dt: float) -> void:
	if phase == Phase.FULLTIME:
		return
	tick += 1
	if _slowmo_left > 0.0:
		_slowmo_left -= dt
		if _slowmo_left <= 0.0:
			cancel_slow_motion()
	var sdt := dt * time_scale
	match phase:
		Phase.HALFTIME:
			halftime_pause = maxf(0.0, halftime_pause - sdt)
			if halftime_pause <= 0.0:
				phase = Phase.PLAYING
		Phase.GOAL_FREEZE:
			goal_freeze = maxf(0.0, goal_freeze - sdt)
			if goal_freeze <= 0.0:
				# If the clock already ran out while celebrating the goal,
				# end the half/match instead of restarting for a kickoff.
				if match_time >= config.half_length_s:
					_end_half()
				else:
					phase = Phase.PLAYING
					sim.reset_game(sim.pending_kickoff_side)
		Phase.PLAYING:
			var scorer := sim.step(sdt)
			if scorer != 0:
				_begin_goal_freeze()
			else:
				match_time += sdt
				if match_time >= config.half_length_s:
					_end_half()

## Ends any running slow motion immediately (e.g. when the offline game pauses).
func cancel_slow_motion() -> void:
	time_scale = 1.0
	_slowmo_left = 0.0

func is_over() -> bool:
	return phase == Phase.FULLTIME

func read_state() -> Dictionary:
	return {
		"tick": tick,
		"phase": phase,
		"match_time": match_time,
		"half_length_s": config.half_length_s,
		"current_half": current_half,
		"score_left": sim.score_left,
		"score_right": sim.score_right,
		"restart_timer": sim.restart_timer,
		"restart_type": sim.restart_type,
		"time_scale": time_scale,
	}

## Returns the queued events (oldest first) and clears the queue.
func drain_events() -> Array[Dictionary]:
	var out := _events
	_events = []
	return out

func _push(type: String, payload := {}) -> void:
	var ev := payload.duplicate()
	ev["tick"] = tick
	ev["type"] = type
	_events.append(ev)

func _on_goal_scored(scorer: int) -> void:
	# pending_kickoff_side is the side whose goal was just hit.
	_push("goal", {"scorer": scorer, "goal_side": sim.pending_kickoff_side,
			"impact": Vector3(sim.ball.x, sim.ball.y, sim.ball.h)})

func _on_special_fired(info: Dictionary) -> void:
	time_scale = SLOWMO_SCALE
	_slowmo_left = SLOWMO_TIME
	_push("special", {"name": info.name, "color": info.color, "team": info.team})

func _begin_goal_freeze() -> void:
	cancel_slow_motion()
	goal_freeze = GOAL_FREEZE_TIME
	phase = Phase.GOAL_FREEZE

## Advances out of the current half: half time after the first, full time after the second.
func _end_half() -> void:
	if current_half == 1:
		current_half = 2
		match_time = 0.0
		halftime_pause = HALFTIME_PAUSE
		phase = Phase.HALFTIME
		sim.switch_ends()
		sim.reset_game(1)
		_push("half_time")
	else:
		cancel_slow_motion()
		phase = Phase.FULLTIME
		_push("full_time", {"score_left": sim.score_left, "score_right": sim.score_right,
				"stats": sim.stats.duplicate(true)})
