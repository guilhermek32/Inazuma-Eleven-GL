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
# A restart (throw-in / corner / goal kick) was just awarded to `team`.
signal restart_awarded(type: int, team: int)

enum Restart { KICKOFF, THROW_IN, CORNER, GOAL_KICK }

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

# How much nearer (normalized field units) a rival must be than the current switch
# candidate before the "next player" ring moves to them. Hysteresis stops the ring
# flickering between two near-equidistant players.
const SWITCH_CANDIDATE_HYSTERESIS := 0.05

func _init() -> void:
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

## Advances one frame: kickoff timer, ball physics + goal detection, then each
## team's update. Returns the scoring side (-1 left, +1 right, 0 none).
func step(delta: float) -> int:
	_update_restart(delta)
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
		p.tackle_timer = 0.0
		p.stamina = 1.0
		p.gk_shot_active = false
		p.gk_react_timer = 0.0

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

func _update_ball(delta: float) -> int:
	var owner := owner_player()
	if owner != null:
		ball.x = owner.x + owner.facing_x * 0.035
		ball.y = owner.y + owner.facing_y * 0.035
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
	clamp_player(taker)
	_set_owner(team_idx, taker_idx)
	# Face into the pitch so the glued ball sits in bounds.
	var inward := Vector2(-spot.x, -spot.y).normalized()
	taker.facing_x = inward.x
	taker.facing_y = inward.y
	restart_type = type
	restart_timer = GameConfig.RESTART_FREEZE
	restart_awarded.emit(type, team_idx)

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
		# (a winning tackle zeroes the timer in _resolve_ball_capture).
		if p.tackle_timer > 0.0:
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
	var players := ts.players
	var cur := ts.selected_index
	var incumbent := ts.switch_candidate
	var incumbent_dist := INF
	if incumbent >= 0 and incumbent != cur and players[incumbent].role != GameConfig.PlayerRole.GOALKEEPER:
		incumbent_dist = Vector2(players[incumbent].x - ball.x, players[incumbent].y - ball.y).length()
	else:
		incumbent = -1
	var best := -1
	var best_dist := INF
	for i in players.size():
		if i == cur or players[i].role == GameConfig.PlayerRole.GOALKEEPER:
			continue
		var d := Vector2(players[i].x - ball.x, players[i].y - ball.y).length()
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
	if snap.axis != Vector2.ZERO:
		p.x += snap.axis.x * p.speed * speed_mult * delta
		p.y += snap.axis.y * p.speed * speed_mult * delta
		p.facing_x = snap.axis.x if snap.axis.x != 0.0 else p.facing_x
		p.facing_y = snap.axis.y if snap.axis.y != 0.0 else p.facing_y
		p.is_moving = true
		clamp_player(p)
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
				kick_from_player(p, Vector2(pass_target.x, pass_target.y), GameConfig.PASS_POWER, false)
			else:
				kick_from_player(p, Vector2(p.x + p.facing_x, p.y + p.facing_y), GameConfig.PASS_POWER, false)
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

## `loft` is the vertical launch speed in world units; < 0 picks a default
## (shots arc with charge, passes stay on the ground).
func kick_from_player(p: PlayerState, target: Vector2, power: float, user_shot: bool, loft := -1.0) -> void:
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
			# always claim); loose balls are still collected on contact.
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
		winner.tackle_timer = 0.0
		_set_owner(best_team, best_idx)
		winner.play_action("receive", 0.45)
	else:
		owner.stun_timer = GameConfig.TACKLE_STUN
		owner.kick_power = 0.0
		# Winning the ball consumes the tackle window (no whiff stun).
		winner.tackle_timer = 0.0
		_set_owner(best_team, best_idx)
		winner.play_action("tackle", 0.55)

func move_towards(p: PlayerState, target: Vector2, current_speed: float, delta: float) -> void:
	var diff := target - Vector2(p.x, p.y)
	if diff.length() > 0.005:
		var dir := diff.normalized()
		p.x += dir.x * current_speed * delta
		p.y += dir.y * current_speed * delta
		p.facing_x = dir.x
		p.facing_y = dir.y
		p.is_moving = true
		clamp_player(p)

func clamp_player(p: PlayerState) -> void:
	var half := 0.025
	if p.role == GameConfig.PlayerRole.GOALKEEPER:
		var area_limit := GameConfig.FIELD_BOUNDARY_X - GameConfig.PENALTY_AREA_WIDTH
		if p.side == -1:
			p.x = clampf(p.x, -GameConfig.FIELD_BOUNDARY_X + half, -area_limit + half)
		else:
			p.x = clampf(p.x, area_limit - half, GameConfig.FIELD_BOUNDARY_X - half)
		p.y = clampf(p.y, -GameConfig.PENALTY_AREA_HEIGHT + half, GameConfig.PENALTY_AREA_HEIGHT - half)
	else:
		p.x = clampf(p.x, -GameConfig.FIELD_BOUNDARY_X + half, GameConfig.FIELD_BOUNDARY_X - half)
		p.y = clampf(p.y, -GameConfig.FIELD_BOUNDARY_Y + half, GameConfig.FIELD_BOUNDARY_Y - half)

func _set_owner(team_idx: int, player_idx: int) -> void:
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
