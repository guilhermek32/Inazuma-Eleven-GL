class_name MatchSimulation
extends Node

## Owns the gameplay state (both teams, the ball, score, timers) and advances it
## one frame via step(). Coordinate space is the normalized 2D field; positions
## are mirrored onto the 3D scene by MatchView. AI players defer to AIController.

# Gameplay events, connected by the controller to the view/audio/HUD so the
# simulation never touches presentation modules directly.
signal goal_scored(scorer: int)
signal ball_kicked
signal special_fired(info: Dictionary)
signal field_reset
# A restart (throw-in / corner / goal kick / free kick) was just awarded to `team`.
signal restart_awarded(type: int, team: int)
# `team` committed a foul (tackle from behind) at `spot`; a free kick follows.
signal foul_committed(team: int, spot: Vector2)
# A flagged player of `team` received a pass in an offside position.
signal offside_called(team: int)

enum Restart { KICKOFF, THROW_IN, CORNER, GOAL_KICK, FREE_KICK }

var players_root: Node3D
var player_factory: PlayerFactory
var ai: AIController
var settings: SettingsStore

# teams[0] = Time A (red, starts on -x), teams[1] = Time B. Each TeamState holds
# the players plus the setup-screen config (device/formation/kit) and the human
# selection state. Defaults reproduce the old 1P setup: A on keyboard+mouse, B AI.
var teams: Array[TeamState] = []
var ball := BallState.new()
var score_left := 0
var score_right := 0
# Freeze that holds play while a restart (kickoff, throw-in, corner, goal kick)
# is being set up; play resumes when it reaches 0.
var restart_timer := 2.0
var restart_type := Restart.KICKOFF
# Side that kicks off after the current goal celebration: set when a goal is scored,
# consumed by the controller once it ends the goal freeze and resets for kickoff.
var pending_kickoff_side := 0

# Per-team match statistics for the full-time screen. Possession accumulates in
# seconds of ownership; the rest are event counters bumped where they happen.
var stats: Array[Dictionary] = [{}, {}]
# Players flagged offside on the last pass by `offside_team`; judged when one of
# them collects the loose ball, cleared on any kick / possession / restart.
var offside_flags: Array[PlayerState] = []
var offside_team := -1

# Restart shield: after a restart is awarded the taker cannot be dispossessed
# until they play the ball (or dribble off the spot / the grace time runs out),
# so opponents can't just take the ball the instant the freeze ends.
var restart_shield := false
var restart_spot := Vector2.ZERO
var restart_shield_timer := 0.0

# How much nearer (normalized field units) a rival must be than the current switch
# candidate before the "next player" ring moves to them. Hysteresis stops the ring
# flickering between two near-equidistant players.
const SWITCH_CANDIDATE_HYSTERESIS := 0.05

func _init() -> void:
	reset_stats()
	for t in 2:
		teams.append(TeamState.new())
	teams[0].device = GameConfig.DEVICE_KBM
	teams[1].device = GameConfig.DEVICE_AI
	teams[0].kit = _kit_colors(GameConfig.DEFAULT_KIT_A)
	teams[1].kit = _kit_colors(GameConfig.DEFAULT_KIT_B)

static func _kit_colors(kit_indices: Dictionary) -> Dictionary:
	return {"shirt": GameConfig.KIT_PALETTE[kit_indices.shirt].color,
			"shorts": GameConfig.KIT_PALETTE[kit_indices.shorts].color,
			"boots": GameConfig.KIT_PALETTE[kit_indices.boots].color}

func team_is_human(t: int) -> bool:
	return teams[t].is_human()

## Zeroes the per-team match statistics (called at the start of every match).
func reset_stats() -> void:
	for t in 2:
		stats[t] = {"possession": 0.0, "shots": 0, "on_target": 0, "steals": 0, "fouls": 0, "offsides": 0}

## Advances one frame: kickoff timer, ball physics + goal detection, then each
## team's update. Returns the scoring side (-1 left, +1 right, 0 none).
func step(delta: float) -> int:
	_update_restart(delta)
	_update_restart_shield(delta)
	if ball.owner_team >= 0:
		stats[ball.owner_team].possession += delta
	var scorer := _update_ball(delta)
	if scorer != 0:
		# Goal: fire confetti/whistle now, but skip the team updates this frame and leave
		# the field reset to the controller once the goal-celebration freeze ends.
		goal_scored.emit(scorer)
		return scorer
	_update_team(0, delta)
	_update_team(1, delta)
	if restart_timer <= 0.0:
		_resolve_ball_capture()
	return scorer

func create_teams() -> void:
	# Re-runnable: drop existing player nodes so a fresh formation/kit can be built.
	# players_root/player_factory may be null in the headless test harness, which
	# runs the simulation without any 3D representation.
	if players_root != null:
		for child in players_root.get_children():
			players_root.remove_child(child)
			child.queue_free()
	for t in 2:
		var ts := teams[t]
		ts.players.clear()
		var side := -1 if t == 0 else 1
		var form: Dictionary = GameConfig.FORMATIONS[ts.formation]
		for entry in form.players:
			var role: int = entry[0]
			var spd: float = GameConfig.ROLE_SPEED.get(role, GameConfig.PLAYER_SPEED)
			# Formations are authored for the -x half; mirror x for team B.
			var px := float(entry[1]) if t == 0 else -float(entry[1])
			_add_player(ts, px, entry[2], spd, side, role)
		_assign_jerseys(ts.players)

func _assign_jerseys(players: Array[PlayerState]) -> void:
	# GK wears 1; the rest are numbered by their slot in the formation list.
	for i in players.size():
		players[i].jersey_number = i + 1
		if players[i].node == null:
			continue
		var lbl := players[i].node.get_node_or_null("JerseyNumber") as Label3D
		if lbl:
			lbl.text = str(i + 1)

func _add_player(ts: TeamState, px: float, py: float, speed: float, side: int, role: int) -> void:
	var state := PlayerState.new(px, py, speed, side, role)
	if player_factory != null and players_root != null:
		state.node = player_factory.create_player_visual(state, ts.kit)
		players_root.add_child(state.node)
	ts.players.append(state)

func reset_game(kickoff_side: int) -> void:
	ball.x = 0.0
	ball.y = 0.0
	ball.vx = 0.0
	ball.vy = 0.0
	ball.is_super_shot = false
	ball.charging_power = 0.0
	ball.spin = 0.0
	ball.curve = 0.0
	ball.h = 0.0
	ball.vh = 0.0
	ball.last_touch_team = -1
	ball.special_name = ""
	ball.special_color = Color(1.0, 1.0, 1.0)
	restart_type = Restart.KICKOFF
	_clear_offside_flags()
	restart_shield = false
	field_reset.emit()
	_clear_owner()
	for ts in teams:
		_reset_players(ts.players)
	var kickoff_team := _team_index_for_side(kickoff_side)
	_set_owner(kickoff_team, _kickoff_index(kickoff_team))
	var owner := owner_player()
	if owner != null:
		owner.x = 0.0
		owner.y = 0.0
	restart_timer = 2.0
	# Each human team starts selecting whichever of its players is nearest the
	# ball; AI teams keep no selection.
	for t in 2:
		teams[t].selected_index = _nearest_user_player(teams[t].players, t) if team_is_human(t) else -1
		teams[t].switch_candidate = -1

func _reset_players(players: Array[PlayerState]) -> void:
	for p in players:
		p.x = p.start_x
		p.y = p.start_y
		p.facing_x = -float(p.side)
		p.facing_y = 0.0
		p.stun_timer = 0.0
		p.kick_power = 0.0
		p.hold_timer = 0.0
		p.is_moving = false
		p.vel_x = 0.0
		p.vel_y = 0.0
		p.tackle_timer = 0.0
		p.stamina = 1.0
		p.gk_shot_active = false
		p.gk_react_timer = 0.0
		p.gk_dive_timer = 0.0
		p.gk_dive_dir = 0

func _team_index_for_side(side: int) -> int:
	if not teams[0].players.is_empty() and teams[0].players[0].side == side:
		return 0
	return 1

func _kickoff_index(team_idx: int) -> int:
	# Player handed the ball at kickoff: first midfielder, else first attacker.
	var players := teams[team_idx].players
	for i in players.size():
		if players[i].role == GameConfig.PlayerRole.MIDFIELDER:
			return i
	for i in players.size():
		if players[i].role == GameConfig.PlayerRole.ATTACKER:
			return i
	return mini(1, players.size() - 1)

func _update_restart(delta: float) -> void:
	if restart_timer <= 0.0:
		return
	restart_timer = maxf(0.0, restart_timer - delta)
	if restart_timer > 0.0:
		return
	# Play just resumed. An AI corner taker immediately swings a lofted ball
	# toward the penalty spot; every other restart plays out as a normal kick.
	if restart_type == Restart.CORNER:
		var owner := owner_player()
		if owner != null and not team_is_human(ball.owner_team):
			var target_goal_x := GameConfig.FIELD_BOUNDARY_X if owner.side == -1 else -GameConfig.FIELD_BOUNDARY_X
			var spot_x := target_goal_x + (GameConfig.PENALTY_SPOT_DIST if target_goal_x < 0.0 else -GameConfig.PENALTY_SPOT_DIST)
			kick_from_player(owner, Vector2(spot_x, 0.0), 0.55, false, GameConfig.CLEARANCE_LOFT)

## The shield ends when the taker plays the ball (kick_from_player), dribbles
## away from the spot, or the post-freeze grace period runs out.
func _update_restart_shield(delta: float) -> void:
	if not restart_shield or restart_timer > 0.0:
		return
	restart_shield_timer -= delta
	var off_spot := Vector2(ball.x - restart_spot.x, ball.y - restart_spot.y).length() > 0.12
	if restart_shield_timer <= 0.0 or off_spot:
		restart_shield = false

func _update_ball(delta: float) -> int:
	var owner := owner_player()
	if owner != null:
		# Knock-ahead dribble: the ball chases a lead point pushed farther ahead
		# the faster the carrier runs, with smoothing so it lags and swings around
		# on sharp turns instead of being welded to the boots.
		var carrier_speed := Vector2(owner.vel_x, owner.vel_y).length()
		var lead := 0.035 + carrier_speed * GameConfig.DRIBBLE_LEAD
		var chase := 1.0 - exp(-GameConfig.DRIBBLE_SMOOTH * delta)
		ball.x = lerpf(ball.x, owner.x + owner.facing_x * lead, chase)
		ball.y = lerpf(ball.y, owner.y + owner.facing_y * lead, chase)
		ball.vx = 0.0
		ball.vy = 0.0
		ball.h = 0.0
		ball.vh = 0.0
		return 0
	ball.x += ball.vx * delta
	ball.y += ball.vy * delta
	# Vertical flight in world units: gravity, then a damped bounce on landing.
	if ball.h > 0.0 or ball.vh != 0.0:
		ball.h += ball.vh * delta
		ball.vh -= GameConfig.BALL_GRAVITY * delta
		if ball.h <= 0.0:
			ball.h = 0.0
			ball.vh = -ball.vh * GameConfig.BALL_BOUNCE
			if ball.vh < GameConfig.BALL_BOUNCE_MIN:
				ball.vh = 0.0
	# Rolling balls feel turf friction; airborne balls only light drag.
	var fric := ball.friction if ball.h <= 0.01 else GameConfig.AIR_FRICTION
	var frame_friction := pow(fric, delta * 60.0)
	ball.vx *= frame_friction
	ball.vy *= frame_friction
	ball.spin *= frame_friction
	# Magnus effect: sidespin bends the flight path while the ball is still fast.
	if ball.curve != 0.0:
		var v := Vector2(ball.vx, ball.vy)
		if v.length() > 0.25:
			v = v.rotated(ball.curve * delta)
			ball.vx = v.x
			ball.vy = v.y
		ball.curve *= frame_friction
	var radius := 0.015
	# End lines (±x): goal if inside the mouth and under the bar, otherwise a
	# corner or goal kick. Touchlines (±y): throw-in.
	if ball.x > GameConfig.FIELD_BOUNDARY_X - radius or ball.x < -GameConfig.FIELD_BOUNDARY_X + radius:
		var goal_side := 1 if ball.x > 0.0 else -1
		if absf(ball.y) <= GameConfig.GOAL_HALF_WIDTH and ball.h < GameConfig.GOAL_HEIGHT:
			return _score_goal_against(goal_side)
		_award_end_line_restart(goal_side)
		return 0
	if absf(ball.y) > GameConfig.FIELD_BOUNDARY_Y - radius:
		_award_throw_in()
	return 0

## Ball crossed the end line outside the goal (or over the bar): corner for the
## attackers if a defender touched it last, goal kick for the defenders otherwise.
func _award_end_line_restart(goal_side: int) -> void:
	var defending_team := _team_index_for_side(goal_side)
	if ball.last_touch_team == defending_team:
		var attacking_team := 1 - defending_team
		var corner_y := GameConfig.CORNER_SPOT_Y if ball.y >= 0.0 else -GameConfig.CORNER_SPOT_Y
		var corner_x := GameConfig.CORNER_SPOT_X if goal_side == 1 else -GameConfig.CORNER_SPOT_X
		_award_restart(Restart.CORNER, attacking_team, Vector2(corner_x, corner_y))
	else:
		var gk_x := GameConfig.GOAL_KICK_X if goal_side == 1 else -GameConfig.GOAL_KICK_X
		_award_restart(Restart.GOAL_KICK, defending_team, Vector2(gk_x, 0.0))

func _award_throw_in() -> void:
	# Unknown last touch (shouldn't happen in play): fall back to a bounce.
	if ball.last_touch_team < 0:
		ball.y = clampf(ball.y, -GameConfig.FIELD_BOUNDARY_Y + 0.02, GameConfig.FIELD_BOUNDARY_Y - 0.02)
		ball.vy *= -1.0
		return
	var team_idx := 1 - ball.last_touch_team
	var spot_x := clampf(ball.x, -GameConfig.THROW_IN_MAX_X, GameConfig.THROW_IN_MAX_X)
	var spot_y := GameConfig.FIELD_BOUNDARY_Y if ball.y > 0.0 else -GameConfig.FIELD_BOUNDARY_Y
	_award_restart(Restart.THROW_IN, team_idx, Vector2(spot_x, spot_y))

## Stops play, places the ball and the awarded team's taker at the spot, gives
## them possession and freezes everyone briefly (mirrors the kickoff freeze).
func _award_restart(type: int, team_idx: int, spot: Vector2) -> void:
	_clear_offside_flags()
	ball.x = spot.x
	ball.y = spot.y
	ball.vx = 0.0
	ball.vy = 0.0
	ball.h = 0.0
	ball.vh = 0.0
	ball.spin = 0.0
	var taker_idx := 0 if type == Restart.GOAL_KICK else _nearest_player_to(teams[team_idx].players, spot)
	var taker := teams[team_idx].players[taker_idx]
	taker.x = spot.x
	taker.y = spot.y
	taker.stun_timer = 0.0
	taker.vel_x = 0.0
	taker.vel_y = 0.0
	clamp_player(taker)
	_set_owner(team_idx, taker_idx)
	# Face into the pitch so the glued ball sits in bounds.
	var inward := Vector2(-spot.x, -spot.y).normalized()
	taker.facing_x = inward.x
	taker.facing_y = inward.y
	_clear_restart_space(team_idx, spot)
	_pull_support_teammates(team_idx, taker_idx, spot)
	restart_shield = true
	restart_spot = spot
	restart_shield_timer = GameConfig.RESTART_SHIELD_TIME
	restart_type = type
	restart_timer = GameConfig.RESTART_FREEZE
	restart_awarded.emit(type, team_idx)

## Opponents inside the clearance ring are pushed radially out to its edge, like
## a referee walking the wall back.
func _clear_restart_space(team_idx: int, spot: Vector2) -> void:
	for opp in teams[1 - team_idx].players:
		var off := Vector2(opp.x - spot.x, opp.y - spot.y)
		if off.length() >= GameConfig.RESTART_CLEAR_DIST:
			continue
		if off.length() < 0.001:
			off = Vector2(-spot.x, -spot.y).normalized()   # degenerate: push infield
			if off.length() < 0.001:
				off = Vector2(1.0, 0.0)
		var pushed := spot + off.normalized() * GameConfig.RESTART_CLEAR_DIST
		opp.x = pushed.x
		opp.y = pushed.y
		opp.vel_x = 0.0
		opp.vel_y = 0.0
		clamp_player(opp)

## The taker's two nearest outfield teammates step in as short passing options,
## fanned infield from the spot.
func _pull_support_teammates(team_idx: int, taker_idx: int, spot: Vector2) -> void:
	var players := teams[team_idx].players
	var candidates: Array[int] = []
	for i in players.size():
		if i == taker_idx or players[i].role == GameConfig.PlayerRole.GOALKEEPER:
			continue
		candidates.append(i)
	candidates.sort_custom(func(a: int, b: int) -> bool:
		return Vector2(players[a].x - spot.x, players[a].y - spot.y).length_squared() \
				< Vector2(players[b].x - spot.x, players[b].y - spot.y).length_squared())
	var inward := Vector2(-spot.x, -spot.y).normalized()
	if inward.length() < 0.001:
		inward = Vector2(1.0, 0.0)
	var angles := [0.6, -0.6]
	for n in mini(2, candidates.size()):
		var mate := players[candidates[n]]
		var pos := spot + inward.rotated(angles[n]) * GameConfig.RESTART_SUPPORT_DIST
		mate.x = pos.x
		mate.y = pos.y
		mate.vel_x = 0.0
		mate.vel_y = 0.0
		clamp_player(mate)

func _nearest_player_to(players: Array[PlayerState], spot: Vector2) -> int:
	var best := 0
	var best_dist := INF
	for i in players.size():
		if players[i].role == GameConfig.PlayerRole.GOALKEEPER:
			continue
		var d := Vector2(players[i].x - spot.x, players[i].y - spot.y).length()
		if d < best_dist:
			best_dist = d
			best = i
	return best

func _score_goal_against(goal_side: int) -> int:
	# Record the score and which side kicks off next, but defer the field reset: the
	# controller freezes play for the goal celebration and resets when the freeze ends.
	var scoring_side := -goal_side
	pending_kickoff_side = goal_side
	if _team_index_for_side(scoring_side) == 0:
		score_left += 1
		return -1
	score_right += 1
	return 1

func _update_team(team_idx: int, delta: float) -> void:
	var ts := teams[team_idx]
	var opponents := teams[1 - team_idx].players
	var is_user_team := ts.is_human()
	var snap: InputSnapshot = ts.input if is_user_team else null
	if is_user_team and restart_timer <= 0.0:
		_handle_user_selection(ts)
	var user_idx := ts.selected_index if is_user_team else -1
	for i in ts.players.size():
		var p := ts.players[i]
		p.is_moving = false
		# Live tackle window: expires into a whiff self-stun if no ball was won
		# (a winning tackle zeroes the timer in _resolve_ball_capture). Frozen
		# during restarts, like stun_timer, so nobody resumes play mid-stun.
		if restart_timer <= 0.0 and p.tackle_timer > 0.0:
			p.tackle_timer -= delta
			if p.tackle_timer <= 0.0:
				p.tackle_timer = 0.0
				p.stun_timer = GameConfig.TACKLE_WHIFF_STUN
		if restart_timer <= 0.0 and is_user_team and i == user_idx:
			_update_user_player(p, snap, team_idx, i, delta, ts.players, opponents)
		elif restart_timer <= 0.0:
			ai.update_ai_player(p, ts.players, opponents, team_idx, i, delta, not is_user_team)

func _handle_user_selection(ts: TeamState) -> void:
	var team_idx := teams.find(ts)
	# In possession: control is locked to the ball carrier (FIFA-style). No switching.
	if ball.owner_team == team_idx:
		ts.selected_index = ball.owner_index
		ts.switch_candidate = -1
		return
	# Not in possession: on Q/L1 press, switch to the pre-computed candidate.
	if ts.input.switch_pressed and ts.switch_candidate >= 0:
		ts.selected_index = ts.switch_candidate
	# Every frame: recompute the switch candidate = nearest outfield player that is NOT
	# the currently selected one. Hysteresis keeps the current candidate unless a rival
	# is clearly nearer, so two near-equidistant players can't flip the ring (and bounce
	# control) every frame.
	# Candidates are ranked against where the ball is *going*, not where it is,
	# so on defense the ring lands on the best interceptor of a rolling ball.
	# A stationary ball degrades this to plain nearest-player.
	var predict := Vector2(
		clampf(ball.x + ball.vx * GameConfig.SWITCH_PREDICT_TIME, -GameConfig.FIELD_BOUNDARY_X, GameConfig.FIELD_BOUNDARY_X),
		clampf(ball.y + ball.vy * GameConfig.SWITCH_PREDICT_TIME, -GameConfig.FIELD_BOUNDARY_Y, GameConfig.FIELD_BOUNDARY_Y))
	var players := ts.players
	var cur := ts.selected_index
	var incumbent := ts.switch_candidate
	var incumbent_dist := INF
	if incumbent >= 0 and incumbent != cur and players[incumbent].role != GameConfig.PlayerRole.GOALKEEPER:
		incumbent_dist = Vector2(players[incumbent].x - predict.x, players[incumbent].y - predict.y).length()
	else:
		incumbent = -1
	var best := -1
	var best_dist := INF
	for i in players.size():
		if i == cur or players[i].role == GameConfig.PlayerRole.GOALKEEPER:
			continue
		var d := Vector2(players[i].x - predict.x, players[i].y - predict.y).length()
		if d < best_dist:
			best_dist = d
			best = i
	# Stay on the incumbent unless the new nearest beats it by more than the margin.
	if incumbent >= 0 and best_dist >= incumbent_dist - SWITCH_CANDIDATE_HYSTERESIS:
		best = incumbent
	ts.switch_candidate = best

func _nearest_teammate(p: PlayerState, players: Array[PlayerState]) -> PlayerState:
	var best: PlayerState = null
	var best_dist := INF
	for mate in players:
		if mate == p or mate.role == GameConfig.PlayerRole.GOALKEEPER:
			continue
		var d := Vector2(mate.x - p.x, mate.y - p.y).length()
		if d < best_dist:
			best_dist = d
			best = mate
	return best

func _nearest_user_player(players: Array[PlayerState], team_idx: int) -> int:
	var best := -1
	var best_dist := INF
	for i in players.size():
		if players[i].role == GameConfig.PlayerRole.GOALKEEPER and not (ball.owner_team == team_idx and ball.owner_index == i):
			continue
		var d := Vector2(players[i].x - ball.x, players[i].y - ball.y).length()
		if d < best_dist:
			best = i
			best_dist = d
	return best

func _update_user_player(p: PlayerState, snap: InputSnapshot, team_idx: int, player_idx: int, delta: float, players: Array[PlayerState], opponents: Array[PlayerState]) -> void:
	if p.stun_timer > 0.0:
		p.stun_timer -= delta
	var speed_mult := 0.3 if p.stun_timer > 0.0 else 1.0
	if p.kick_power > 0.0:
		speed_mult *= 0.8
	# Sprint while held and the tank lasts; recover otherwise.
	var sprinting := snap.sprint_held and p.stamina > 0.0 and snap.axis != Vector2.ZERO
	if sprinting:
		speed_mult *= GameConfig.SPRINT_MULT
		p.stamina = maxf(0.0, p.stamina - GameConfig.SPRINT_DRAIN * delta)
	else:
		p.stamina = minf(1.0, p.stamina + GameConfig.SPRINT_REGEN * delta)
	# Tackle lunge: opens a short steal window; whiffing it costs a self-stun.
	var is_carrier := ball.owner_team == team_idx and ball.owner_index == player_idx
	if snap.tackle_pressed and not is_carrier and p.stun_timer <= 0.0 and p.tackle_timer <= 0.0:
		p.tackle_timer = GameConfig.TACKLE_WINDOW
		p.play_action("tackle", 0.4)
	apply_movement(p, snap.axis * p.speed * speed_mult, delta)
	if ball.owner_team == team_idx and ball.owner_index == player_idx:
		ball.charging_power = p.kick_power
		if snap.pass_pressed:
			var target_goal_x := GameConfig.FIELD_BOUNDARY_X if p.side == -1 else -GameConfig.FIELD_BOUNDARY_X
			var pass_target := ai.best_pass_target(p, players, opponents, target_goal_x)
			if pass_target == null:
				# No forward option: fall back to the nearest teammate so the
				# press is never silently swallowed.
				pass_target = _nearest_teammate(p, players)
			if pass_target != null:
				kick_from_player(p, lead_pass_point(Vector2(p.x, p.y), pass_target), GameConfig.PASS_POWER, false, -1.0, true)
			else:
				kick_from_player(p, Vector2(p.x + p.facing_x, p.y + p.facing_y), GameConfig.PASS_POWER, false, -1.0, true)
		elif snap.shoot_held:
			p.kick_power = minf(1.0, p.kick_power + delta * GameConfig.CHARGE_RATE)
		elif snap.shoot_prev:
			kick_from_player(p, _aim_target(snap, p), p.kick_power, true)
	else:
		# Not the ball carrier: never charging a kick.
		p.kick_power = 0.0
		ball.charging_power = 0.0

func _aim_target(snap: InputSnapshot, p: PlayerState) -> Vector2:
	if snap.aim_absolute:
		return snap.aim_vec
	var dir := snap.aim_vec if snap.aim_vec != Vector2.ZERO else Vector2(p.facing_x, p.facing_y)
	return Vector2(p.x, p.y) + dir

## Where to aim a pass so a moving receiver runs onto it: the target is led by
## the mate's velocity over the estimated flight time, clamped inside the field.
func lead_pass_point(from: Vector2, mate: PlayerState) -> Vector2:
	var mate_pos := Vector2(mate.x, mate.y)
	var pass_ball_speed := GameConfig.KICK_BASE_POWER + GameConfig.PASS_POWER * GameConfig.KICK_POWER_SCALE
	var t := clampf(from.distance_to(mate_pos) / pass_ball_speed, 0.0, GameConfig.PASS_LEAD_MAX)
	var target := mate_pos + Vector2(mate.vel_x, mate.vel_y) * t
	target.x = clampf(target.x, -GameConfig.FIELD_BOUNDARY_X + 0.03, GameConfig.FIELD_BOUNDARY_X - 0.03)
	target.y = clampf(target.y, -GameConfig.FIELD_BOUNDARY_Y + 0.03, GameConfig.FIELD_BOUNDARY_Y - 0.03)
	return target

## `loft` is the vertical launch speed in world units; < 0 picks a default
## (shots arc with charge, passes stay on the ground). `is_pass` marks kicks
## aimed at a teammate (they arm the offside flags); `is_shot` marks goal
## attempts for the match statistics.
func kick_from_player(p: PlayerState, target: Vector2, power: float, user_shot: bool, loft := -1.0, is_pass := false, is_shot := false) -> void:
	_clear_offside_flags()
	restart_shield = false
	var dir := target - Vector2(p.x, p.y)
	if dir.length() <= 0.001:
		dir = Vector2(p.facing_x, p.facing_y)
	if dir.length() <= 0.001:
		dir = Vector2(float(p.side), 0.0)
	dir = dir.normalized()
	p.facing_x = dir.x
	p.facing_y = dir.y
	var final_power := GameConfig.KICK_BASE_POWER + power * GameConfig.KICK_POWER_SCALE
	ball.vx = dir.x * final_power
	ball.vy = dir.y * final_power
	ball.spin = final_power * 8.0
	# Vertical launch: charged shots rise with power, passes roll along the turf.
	ball.h = 0.0
	ball.vh = loft if loft >= 0.0 else (power * GameConfig.SHOT_LOFT if power > 0.5 else 0.0)
	ball.last_touch_team = p.team_index
	var target_goal_x := GameConfig.FIELD_BOUNDARY_X if p.side == -1 else -GameConfig.FIELD_BOUNDARY_X
	var dist_to_goal := Vector2(target_goal_x - p.x, -p.y).length()
	# A fully-charged shot toward goal "evolves" into a named special: the user always
	# triggers one at full charge; the AI does so on a coin-flip when it shoots that hard.
	var is_named := power >= GameConfig.SPECIAL_SHOT_CHARGE and dist_to_goal < 0.95 and (user_shot or randf() < 0.5)
	ball.is_super_shot = is_named or (power > 0.5 and dist_to_goal < 0.55)
	if is_named:
		var pick: Dictionary = GameConfig.SPECIAL_SHOTS[randi() % GameConfig.SPECIAL_SHOTS.size()]
		ball.special_name = pick.name
		ball.special_color = pick.color
		ball.curve = pick.curve
		special_fired.emit({"name": pick.name, "color": pick.color, "team": p.team_index})
		# A special carries extra venom and spin.
		ball.vx *= 1.18
		ball.vy *= 1.18
		ball.spin *= 1.4
	else:
		ball.special_name = ""
		ball.special_color = Color(1.0, 1.0, 1.0)
		# Ordinary hard shots pick up a touch of random swerve; passes fly true.
		ball.curve = randf_range(-1.0, 1.0) * GameConfig.HARD_SHOT_CURVE if power > 0.5 else 0.0
	if is_shot or user_shot:
		stats[p.team_index].shots += 1
		if _shot_on_target(p):
			stats[p.team_index].on_target += 1
	if is_pass and settings != null and settings.offside_enabled:
		_flag_offside_receivers(p)
	ball.charging_power = 0.0
	p.kick_power = 0.0
	p.hold_timer = 0.0
	# Brief self-stun after kicking: _resolve_ball_capture ignores stunned players, so
	# this — not the small forward nudge below — is what stops the kicker instantly
	# re-grabbing their own pass/shot.
	p.stun_timer = GameConfig.KICK_SELF_STUN_HARD if power > 0.5 else GameConfig.KICK_SELF_STUN_SOFT
	_clear_owner()
	ball.x += ball.vx * 0.025
	ball.y += ball.vy * 0.025
	ball_kicked.emit()
	p.play_action("kick", 0.7)

## Straight-line estimate of whether the ball just kicked by `p` is heading
## inside the goal mouth (ignores curve/friction — good enough for the stats).
func _shot_on_target(p: PlayerState) -> bool:
	var goal_x := GameConfig.FIELD_BOUNDARY_X if p.side == -1 else -GameConfig.FIELD_BOUNDARY_X
	if absf(ball.vx) < 0.001:
		return false
	var t := (goal_x - ball.x) / ball.vx
	if t <= 0.0:
		return false
	return absf(ball.y + ball.vy * t) <= GameConfig.GOAL_HALF_WIDTH

## Snapshots the offside line at the moment of a pass: teammates in the attacking
## half, ahead of the ball and beyond the second-to-last defender are flagged.
func _flag_offside_receivers(kicker: PlayerState) -> void:
	offside_team = kicker.team_index
	var attack := -float(kicker.side)   # attacking direction sign on x
	# Second-to-last defender depth (the keeper is usually the last man).
	var depths: Array[float] = []
	for opp in teams[1 - kicker.team_index].players:
		depths.append(opp.x * attack)
	depths.sort()
	depths.reverse()
	var line: float = depths[1] if depths.size() >= 2 else 0.0
	for mate in teams[kicker.team_index].players:
		if mate == kicker:
			continue
		var depth := mate.x * attack
		if depth <= 0.0 or depth <= ball.x * attack:
			continue   # own half / level with or behind the ball: never offside
		if depth > line + GameConfig.OFFSIDE_EPS:
			offside_flags.append(mate)
	if offside_flags.is_empty():
		offside_team = -1

func _clear_offside_flags() -> void:
	offside_flags.clear()
	offside_team = -1

## A winning tackle counts as a foul when the tackler came from behind the
## carrier (opposite the direction the carrier is facing).
func _is_foul_tackle(tackler: PlayerState, carrier: PlayerState) -> bool:
	var approach := Vector2(tackler.x - carrier.x, tackler.y - carrier.y)
	if approach.length() < 0.001:
		return false
	return approach.normalized().dot(Vector2(carrier.facing_x, carrier.facing_y)) < GameConfig.FOUL_BEHIND_DOT

## Free kicks are taken where the ball is, nudged inside the boundary and out of
## the goalmouth (no penalty system — the spot is pushed up the pitch instead).
func _free_kick_spot() -> Vector2:
	var max_x := GameConfig.FIELD_BOUNDARY_X - GameConfig.FREE_KICK_MIN_GOAL_DIST
	var max_y := GameConfig.FIELD_BOUNDARY_Y - 0.05
	return Vector2(clampf(ball.x, -max_x, max_x), clampf(ball.y, -max_y, max_y))

# Runs once per frame after both team updates: the globally nearest eligible player
# wins the ball, so contested captures no longer favour the team updated first.
func _resolve_ball_capture() -> void:
	var owner := owner_player()
	# Loose ball: anyone can capture. Owned ball: only opponents can steal, and
	# never from the goalkeeper.
	if owner != null and owner.role == GameConfig.PlayerRole.GOALKEEPER:
		return
	var best_team := -1
	var best_idx := -1
	var best_dist := INF
	for team_idx in 2:
		if owner != null and ball.owner_team == team_idx:
			continue
		var players := teams[team_idx].players
		for i in players.size():
			var p := players[i]
			if p.stun_timer > 0.0:
				continue
			var capture_radius := GameConfig.CAPTURE_RADIUS
			var reach := GameConfig.CAPTURE_MAX_HEIGHT
			if p.role == GameConfig.PlayerRole.GOALKEEPER:
				capture_radius = GameConfig.GK_CAPTURE_RADIUS_SUPER if ball.is_super_shot else GameConfig.GK_CAPTURE_RADIUS
				reach = GameConfig.GK_REACH_HEIGHT
			# A lofted ball sails over everyone who can't reach it.
			if ball.h > reach:
				continue
			# Stealing an owned ball takes a live tackle attempt (keepers may
			# always claim); loose balls are still collected on contact. While
			# the restart shield is up the taker cannot be dispossessed at all.
			if owner != null and restart_shield:
				continue
			if owner != null and p.tackle_timer <= 0.0 and p.role != GameConfig.PlayerRole.GOALKEEPER:
				continue
			var d := Vector2(p.x - ball.x, p.y - ball.y).length()
			if d < capture_radius and d < best_dist:
				best_dist = d
				best_team = team_idx
				best_idx = i
	if best_idx < 0:
		return
	var winner := teams[best_team].players[best_idx]
	if owner == null:
		# Offside: a flagged receiver collecting his team's pass concedes an
		# indirect free kick instead of gaining possession.
		if settings != null and settings.offside_enabled and best_team == offside_team and winner in offside_flags:
			stats[best_team].offsides += 1
			winner.tackle_timer = 0.0
			offside_called.emit(best_team)
			_award_restart(Restart.FREE_KICK, 1 - best_team, _free_kick_spot())
			return
		winner.tackle_timer = 0.0
		_set_owner(best_team, best_idx)
		winner.play_action("receive", 0.45)
	else:
		# A tackle from behind is a foul: no steal, free kick to the carrier's team.
		if settings != null and settings.fouls_enabled and _is_foul_tackle(winner, owner):
			stats[best_team].fouls += 1
			winner.tackle_timer = 0.0
			winner.stun_timer = GameConfig.TACKLE_WHIFF_STUN
			winner.play_action("tackle", 0.55)
			foul_committed.emit(best_team, Vector2(ball.x, ball.y))
			_award_restart(Restart.FREE_KICK, 1 - best_team, _free_kick_spot())
			return
		stats[best_team].steals += 1
		owner.stun_timer = GameConfig.TACKLE_STUN
		owner.kick_power = 0.0
		# Winning the ball consumes the tackle window (no whiff stun).
		winner.tackle_timer = 0.0
		_set_owner(best_team, best_idx)
		winner.play_action("tackle", 0.55)

func move_towards(p: PlayerState, target: Vector2, current_speed: float, delta: float) -> void:
	var diff := target - Vector2(p.x, p.y)
	if diff.length() > 0.005:
		apply_movement(p, diff.normalized() * current_speed, delta)
	else:
		apply_movement(p, Vector2.ZERO, delta)

## Accelerates the player's actual velocity toward `desired` and integrates the
## position. Every mover (user input, AI move_towards, AI dribble) routes through
## here so players carry momentum instead of snapping to full speed; facing and
## is_moving derive from the real velocity.
func apply_movement(p: PlayerState, desired: Vector2, delta: float) -> void:
	var vel := Vector2(p.vel_x, p.vel_y)
	var accel := GameConfig.PLAYER_ACCEL if desired.length_squared() > vel.length_squared() else GameConfig.PLAYER_DECEL
	# Keepers stay twitchy: their line shuffle and dive burst need near-instant
	# direction flips or saves arrive late.
	if p.role == GameConfig.PlayerRole.GOALKEEPER:
		accel *= 2.5
	vel = vel.move_toward(desired, accel * delta)
	p.vel_x = vel.x
	p.vel_y = vel.y
	if vel.length() > 0.01:
		p.x += vel.x * delta
		p.y += vel.y * delta
		var dir := vel.normalized()
		p.facing_x = dir.x
		p.facing_y = dir.y
		p.is_moving = true
		clamp_player(p)

func clamp_player(p: PlayerState) -> void:
	var half := 0.025
	if p.role == GameConfig.PlayerRole.GOALKEEPER:
		var area_limit := GameConfig.FIELD_BOUNDARY_X - GameConfig.PENALTY_AREA_WIDTH
		if p.side == -1:
			p.x = clampf(p.x, -GameConfig.FIELD_BOUNDARY_X + half, -area_limit - half)
		else:
			p.x = clampf(p.x, area_limit + half, GameConfig.FIELD_BOUNDARY_X - half)
		p.y = clampf(p.y, -GameConfig.PENALTY_AREA_HEIGHT + half, GameConfig.PENALTY_AREA_HEIGHT - half)
	else:
		p.x = clampf(p.x, -GameConfig.FIELD_BOUNDARY_X + half, GameConfig.FIELD_BOUNDARY_X - half)
		p.y = clampf(p.y, -GameConfig.FIELD_BOUNDARY_Y + half, GameConfig.FIELD_BOUNDARY_Y - half)

func _set_owner(team_idx: int, player_idx: int) -> void:
	_clear_offside_flags()
	ball.owner_team = team_idx
	ball.owner_index = player_idx
	ball.last_touch_team = team_idx
	ball.is_super_shot = false
	ball.charging_power = 0.0
	ball.special_name = ""
	ball.special_color = Color(1.0, 1.0, 1.0)
	# Immediately snap the human selection to the new ball carrier so the player
	# doesn't have to press Q/L1 to regain control after winning a tackle.
	if team_is_human(team_idx):
		teams[team_idx].selected_index = player_idx

func _clear_owner() -> void:
	ball.owner_team = -1
	ball.owner_index = -1
	ball.charging_power = 0.0

func owner_player() -> PlayerState:
	if ball.owner_team < 0 or ball.owner_team > 1:
		return null
	var players := teams[ball.owner_team].players
	if ball.owner_index >= 0 and ball.owner_index < players.size():
		return players[ball.owner_index]
	return null

func _owner_side() -> int:
	var owner := owner_player()
	return owner.side if owner != null else 0

func switch_ends() -> void:
	for ts in teams:
		for p in ts.players:
			_flip_player_end(p)

func _flip_player_end(p: PlayerState) -> void:
	p.side *= -1
	p.start_x *= -1.0
	p.x *= -1.0
	p.facing_x = -float(p.side)
	p.facing_y = 0.0
	# NOTE: team_index is intentionally NOT updated here. It records which array
	# (teams[0]/teams[1]) the player lives in — that never changes. Only
	# `side` reflects which goal the player is currently attacking.

func set_default_ends() -> void:
	for t in 2:
		var side := -1 if t == 0 else 1
		for p in teams[t].players:
			p.side = side
			p.start_x = -absf(p.start_x) if t == 0 else absf(p.start_x)
			p.facing_x = -float(side)
