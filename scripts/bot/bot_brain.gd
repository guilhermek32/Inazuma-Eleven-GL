class_name BotBrain
extends RefCounted

## Input-level policy of the online AI opponent: an autonomous agent that
## plays one team exactly like a remote human would.
##
## Goal: win the match by scoring and by stopping the opponent scoring.
## Observation: a mirror MatchSimulation written from the newest snapshot
##   (positions, velocities, facing, stamina, possession, selection and the
##   switch candidate of every player); never the server's hidden state.
## Decide: every think interval (difficulty-scaled reaction time, with a
##   little jitter) it reads the situation of its selected player:
##     we carry the ball   shoot when in range and facing goal, pass when
##                         pressed with no open lane or a mate is much
##                         closer to goal, else dribble into the most open lane
##     they carry it       switch to a nearer team-mate, chase goal-side of
##                         the carrier, then step in front of the ball and
##                         tackle it once within reach (never from behind)
##     loose ball          switch to the best interceptor and run onto it
## Act: the decision becomes held input (move axis, sprint while stamina
##   allows) and one-tick actions (pass, switch, tackle, shoot start/release
##   with an aim point carrying a difficulty-scaled error, plus small
##   steering noise), sent like a human's input. Off-ball team-mates stay
##   with the runtime's own AI.
##
## step() is called once per physics tick and returns that tick's
## InputSnapshot. `decision` describes the latest choice; `decision_fresh`
## is true on the tick a new intent or action was chosen (for the sampled
## decision log). All randomness comes from `rng` (seedable for tests).

const DIFFICULTIES := ["easy", "normal", "hard"]

## Per difficulty: think_s reaction/think interval, aim_error shot aim noise
## (field units on the goal line), noise steering noise (radians),
## shoot_range distance to goal to shoot, pressure_dist opponent distance that
## counts as pressure, pass_gain goal-distance gain that justifies a pass,
## tackle_range / tackle_cooldown_s (a lunge from too far whiffs: Easy lunges
## early, Hard waits until the steal is likely), switch_margin how much nearer a mate must
## be to switch, sprint_stamina minimum stamina to sprint, charge [min, max]
## shot charge, lead_s how far ahead it reads the carrier's run.
const PROFILES := {
	"easy": {"think_s": 0.45, "aim_error": 0.09, "noise": 0.35, "shoot_range": 0.34, "pressure_dist": 0.08,
			"pass_gain": 0.35, "tackle_range": 0.09, "tackle_cooldown_s": 1.0, "switch_margin": 0.15,
			"sprint_stamina": 0.6, "charge": [0.35, 0.6], "lead_s": 0.0},
	"normal": {"think_s": 0.20, "aim_error": 0.045, "noise": 0.15, "shoot_range": 0.44, "pressure_dist": 0.11,
			"pass_gain": 0.25, "tackle_range": 0.065, "tackle_cooldown_s": 0.8, "switch_margin": 0.10,
			"sprint_stamina": 0.4, "charge": [0.55, 0.8], "lead_s": 0.15},
	"hard": {"think_s": 0.10, "aim_error": 0.015, "noise": 0.05, "shoot_range": 0.50, "pressure_dist": 0.13,
			"pass_gain": 0.18, "tackle_range": 0.07, "tackle_cooldown_s": 0.6, "switch_margin": 0.06,
			"sprint_stamina": 0.25, "charge": [0.7, 0.95], "lead_s": 0.25},
}
const PASS_COOLDOWN_S := 0.6
const OPEN_LANE := 0.12          # dribble-lane clearance that still counts as open
const MAX_RECYCLE_LOSS := 0.35   # goal distance a pass under pressure may give back
const SWITCH_COOLDOWN_S := 0.8
const CLOSE_DOWN_DIST := 0.15    # nearer than this the bot attacks the ball itself
const FOUL_MARGIN := 0.2         # stay this far (in dot) from a from-behind tackle

var difficulty := "normal"
var profile: Dictionary
var team := 1
var rng := RandomNumberGenerator.new()
var decision := {}
var decision_fresh := false
var decisions_made := 0

var _held := InputSnapshot.new()
var _think_left := 0.0
var _charge_left := -1.0   # >= 0 while a shot is being charged
var _tackle_cd := 0.0
var _pass_cd := 0.0
var _switch_cd := 0.0

func _init(p_difficulty := "normal", p_team := 1, seed_value := 0) -> void:
	difficulty = p_difficulty if p_difficulty in DIFFICULTIES else "normal"
	profile = PROFILES[difficulty]
	team = p_team
	rng.seed = seed_value
	_held.aim_absolute = true

static func is_difficulty(name: String) -> bool:
	return name in DIFFICULTIES

## MatchConfig.team_difficulty index (0 Easy, 1 Normal, 2 Hard).
static func difficulty_index(name: String) -> int:
	return maxi(0, DIFFICULTIES.find(name))

## One input tick against the observation `sim`. `playing` is false outside
## live play (waiting room, pause, goal freeze, half time, restart freeze):
## the bot then lets go of everything.
func step(sim: MatchSimulation, playing: bool, dt: float) -> InputSnapshot:
	decision_fresh = false
	var out := InputSnapshot.new()
	out.aim_absolute = true
	out.shoot_prev = _held.shoot_held
	_tackle_cd -= dt
	_pass_cd -= dt
	_switch_cd -= dt
	if not playing:
		_held = InputSnapshot.new()
		_held.aim_absolute = true
		_charge_left = -1.0
		_think_left = 0.0
		return out
	if _charge_left >= 0.0:
		_charge_left -= dt
		if _charge_left < 0.0 or not _owns_ball(sim):
			_held.shoot_held = false   # release: the runtime kicks with the aim sent now
			_charge_left = -1.0
	else:
		_think_left -= dt
		if _think_left <= 0.0:
			_think_left = float(profile.think_s) * rng.randf_range(0.85, 1.15)
			_decide(sim, out)
	out.axis = _held.axis
	out.sprint_held = _held.sprint_held
	out.shoot_held = _held.shoot_held
	out.aim_vec = _held.aim_vec
	return out

func _owns_ball(sim: MatchSimulation) -> bool:
	return sim.ball.owner_team == team and sim.ball.owner_index == sim.teams[team].selected_index

func _decide(sim: MatchSimulation, out: InputSnapshot) -> void:
	var ts := sim.teams[team]
	if ts.selected_index < 0 or ts.selected_index >= ts.players.size():
		_held.axis = Vector2.ZERO
		_record("idle", "", "no player selected", -1, {})
		return
	var p := ts.players[ts.selected_index]
	if _owns_ball(sim):
		_attack(sim, p, out)
	elif sim.ball.owner_team == 1 - team and sim.ball.owner_index >= 0:
		_defend(sim, p, out)
	else:
		_chase(sim, p, out)

# --- we have the ball -------------------------------------------------------------

func _attack(sim: MatchSimulation, p: PlayerState, out: InputSnapshot) -> void:
	var mates := sim.teams[team].players
	var opps := sim.teams[1 - team].players
	var gx := Tactics.target_goal_x(p)
	var to_goal := Vector2(gx - p.x, -p.y)
	var dist := to_goal.length()
	var goal_dir := to_goal.normalized()
	var facing := Vector2(p.facing_x, p.facing_y).dot(goal_dir)
	var nearest := Tactics.nearest_opponent_dist(p, opps)
	var pressure := nearest < float(profile.pressure_dist)
	var features := {"dist_goal": snappedf(dist, 0.01), "facing": snappedf(facing, 0.01), "nearest_opp": snappedf(minf(nearest, 9.0), 0.01)}
	if dist < float(profile.shoot_range) and (facing > 0.3 or dist < 0.22):
		var power := rng.randf_range(profile.charge[0], profile.charge[1])
		_charge_left = power / GameConfig.CHARGE_RATE
		_held.aim_vec = Tactics.shot_target(opps, gx, rng.randf_range(-1.0, 1.0) * float(profile.aim_error))
		_held.shoot_held = true
		_held.axis = _noisy(goal_dir)
		_held.sprint_held = false
		features["power"] = snappedf(power, 0.01)
		features["aim"] = [snappedf(_held.aim_vec.x, 0.01), snappedf(_held.aim_vec.y, 0.01)]
		_record("attack", "shoot", "in range and facing goal", sim.teams[team].selected_index, features)
		return
	var lane := Tactics.best_dribble(p, opps, goal_dir)
	var clearance := float(lane.clearance)
	features["clearance"] = snappedf(clearance, 0.01)
	var target := Tactics.best_pass_target(p, mates, opps, gx)
	if target != null and _pass_cd <= 0.0:
		var gain := dist - Vector2(gx - target.x, -target.y).length()
		features["pass_gain"] = snappedf(gain, 0.01)
		# Pressed with no open lane ahead: recycle it, but never hoof it far back.
		var recycle := pressure and clearance < OPEN_LANE and gain > -MAX_RECYCLE_LOSS
		if recycle or gain > float(profile.pass_gain):
			out.pass_pressed = true
			_pass_cd = PASS_COOLDOWN_S
			_record("attack", "pass", "pressed with no open lane" if recycle else "mate much closer to goal", sim.teams[team].selected_index, features)
			return
	_held.axis = _noisy(lane.dir)
	_held.aim_vec = Vector2(gx, 0.0)
	_held.sprint_held = p.stamina > float(profile.sprint_stamina) and clearance > 0.1
	_record("attack", "", "dribble into the open lane", sim.teams[team].selected_index, features)

# --- they have the ball -----------------------------------------------------------

func _defend(sim: MatchSimulation, p: PlayerState, out: InputSnapshot) -> void:
	var ts := sim.teams[team]
	var carrier := sim.teams[1 - team].players[sim.ball.owner_index]
	var carrier_pos := Vector2(carrier.x, carrier.y)
	var pos := Vector2(p.x, p.y)
	var dist := pos.distance_to(carrier_pos)
	var features := {"carrier_dist": snappedf(dist, 0.01), "stamina": snappedf(p.stamina, 0.01)}
	if _try_switch(sim, carrier_pos, dist, out, features):
		return
	if carrier.role == GameConfig.PlayerRole.GOALKEEPER:
		# Their keeper holds it: drop back into shape instead of crowding him.
		_steer(Vector2(p.start_x, p.start_y) - pos, false)
		_record("defend", "", "keeper has the ball: recover shape", ts.selected_index, features)
		return
	# The steal is decided at the ball, which runs ahead of the carrier's feet;
	# coming in from behind the carrier is a foul, so the bot steps in front.
	var ball_pos := Vector2(sim.ball.x, sim.ball.y)
	var face := Vector2(carrier.facing_x, carrier.facing_y)
	var ball_dist := pos.distance_to(ball_pos)
	var from_front := dist < 0.001 or (pos - carrier_pos).normalized().dot(face) > GameConfig.FOUL_BEHIND_DOT + FOUL_MARGIN
	features["ball_dist"] = snappedf(ball_dist, 0.01)
	var stunned := p.stun_timer > 0.0
	if ball_dist < float(profile.tackle_range) and from_front and _tackle_cd <= 0.0 and not stunned and p.tackle_timer <= 0.0:
		out.tackle_pressed = true
		_tackle_cd = float(profile.tackle_cooldown_s)
		_steer(ball_pos - pos, false)
		_record("defend", "tackle", "ball within reach, in front of the carrier", ts.selected_index, features)
		return
	if dist > CLOSE_DOWN_DIST:
		var own_goal := Vector2(Tactics.own_goal_x(p), 0.0)
		var target := carrier_pos + Vector2(carrier.vel_x, carrier.vel_y) * float(profile.lead_s) \
				+ (own_goal - carrier_pos).normalized() * 0.03
		_steer(target - pos, dist > 0.1 and p.stamina > float(profile.sprint_stamina))
		_record("defend", "", "close down goal-side of the carrier", ts.selected_index, features)
		return
	_steer(ball_pos + face * 0.02 - pos, false)
	_record("defend", "", "step in front of the ball", ts.selected_index, features)

# --- loose ball -------------------------------------------------------------------

func _chase(sim: MatchSimulation, p: PlayerState, out: InputSnapshot) -> void:
	var ball := sim.ball
	var pos := Vector2(p.x, p.y)
	var lead := clampf(pos.distance_to(Vector2(ball.x, ball.y)) / maxf(p.speed * 1.2, 0.01), 0.0, 0.6)
	var predict := Vector2(clampf(ball.x + ball.vx * lead, -GameConfig.FIELD_BOUNDARY_X, GameConfig.FIELD_BOUNDARY_X),
			clampf(ball.y + ball.vy * lead, -GameConfig.FIELD_BOUNDARY_Y, GameConfig.FIELD_BOUNDARY_Y))
	var dist := pos.distance_to(predict)
	var features := {"ball_dist": snappedf(dist, 0.01), "ball": [snappedf(ball.x, 0.01), snappedf(ball.y, 0.01)]}
	if _try_switch(sim, predict, dist, out, features):
		return
	_steer(predict - pos, dist > 0.12 and p.stamina > float(profile.sprint_stamina))
	_record("chase", "", "run onto the loose ball", sim.teams[team].selected_index, features)

## Presses switch when the runtime's switch candidate is clearly nearer `spot`.
func _try_switch(sim: MatchSimulation, spot: Vector2, my_dist: float, out: InputSnapshot, features: Dictionary) -> bool:
	var ts := sim.teams[team]
	var cand := ts.switch_candidate
	if _switch_cd > 0.0 or cand < 0 or cand >= ts.players.size() or cand == ts.selected_index:
		return false
	var c := ts.players[cand]
	var cand_dist := Vector2(c.x, c.y).distance_to(spot)
	if cand_dist + float(profile.switch_margin) >= my_dist:
		return false
	out.switch_pressed = true
	_switch_cd = SWITCH_COOLDOWN_S
	_think_left = 0.0   # re-plan as soon as the new player is selected
	features["candidate"] = cand
	features["candidate_dist"] = snappedf(cand_dist, 0.01)
	_record("switch", "switch", "a team-mate is nearer the ball", ts.selected_index, features)
	return true

func _steer(delta: Vector2, sprint: bool) -> void:
	if delta.length() < 0.01:
		_held.axis = Vector2.ZERO
		_held.sprint_held = false
		return
	_held.axis = _noisy(delta.normalized())
	_held.sprint_held = sprint

func _noisy(dir: Vector2) -> Vector2:
	return dir.rotated(rng.randf_range(-1.0, 1.0) * float(profile.noise)).normalized()

func _record(intent: String, action: String, reason: String, player: int, features: Dictionary) -> void:
	decision_fresh = action != "" or intent != str(decision.get("intent", ""))
	decisions_made += 1
	decision = {"intent": intent, "action": action, "reason": reason, "player": player, "features": features}
