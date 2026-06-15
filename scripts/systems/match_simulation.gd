class_name MatchSimulation
extends Node

## Owns the gameplay state (both teams, the ball, score, timers) and advances it
## one frame via step(). Coordinate space is the normalized 2D field; positions
## are mirrored onto the 3D scene by MatchView. AI players defer to AIController.

var players_root: Node3D
var player_factory: PlayerFactory
var ai: AIController
var audio: AudioManager
var settings: SettingsStore
var view: MatchView

var team_red: Array[PlayerState] = []
var team_blue: Array[PlayerState] = []
var ball := BallState.new()
var score_left := 0
var score_right := 0
var kickoff_timer := 2.0
var inputs := [InputSnapshot.new(), InputSnapshot.new()]
var selected_index: Array[int] = [-1, -1]
var switch_candidate_index: Array[int] = [-1, -1]

## Advances one frame: kickoff timer, ball physics + goal detection, then each
## team's update. Returns the scoring side (-1 left, +1 right, 0 none).
func step(delta: float, num_players: int) -> int:
	_update_kickoff(delta)
	var scorer := _update_ball(delta)
	if scorer != 0:
		view._trigger_goal(scorer)
	_update_team(team_red, team_blue, 0, true, false, delta)
	_update_team(team_blue, team_red, 1, num_players == 2, num_players < 2, delta)
	return scorer

func _create_teams() -> void:
	team_red.clear()
	team_blue.clear()
	var s := 0.2
	var gk_speed := 0.32
	_add_player(team_red, -GameConfig.FIELD_BOUNDARY_X, 0.00, gk_speed, -1, GameConfig.PlayerRole.GOALKEEPER)
	_add_player(team_red, -0.65, 0.25, s, -1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_red, -0.65, -0.25, s, -1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_red, -0.60, 0.50, s, -1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_red, -0.60, -0.50, s, -1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_red, -0.35, 0.00, s, -1, GameConfig.PlayerRole.MIDFIELDER)
	_add_player(team_red, -0.35, 0.30, s, -1, GameConfig.PlayerRole.MIDFIELDER)
	_add_player(team_red, -0.35, -0.30, s, -1, GameConfig.PlayerRole.MIDFIELDER)
	_add_player(team_red, -0.10, 0.00, s, -1, GameConfig.PlayerRole.ATTACKER)
	_add_player(team_red, -0.10, 0.40, s, -1, GameConfig.PlayerRole.ATTACKER)
	_add_player(team_red, -0.10, -0.40, s, -1, GameConfig.PlayerRole.ATTACKER)
	_add_player(team_blue, GameConfig.FIELD_BOUNDARY_X, 0.00, gk_speed, 1, GameConfig.PlayerRole.GOALKEEPER)
	_add_player(team_blue, 0.65, 0.25, s, 1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_blue, 0.65, -0.25, s, 1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_blue, 0.60, 0.50, s, 1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_blue, 0.60, -0.50, s, 1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_blue, 0.35, 0.00, s, 1, GameConfig.PlayerRole.MIDFIELDER)
	_add_player(team_blue, 0.35, 0.30, s, 1, GameConfig.PlayerRole.MIDFIELDER)
	_add_player(team_blue, 0.35, -0.30, s, 1, GameConfig.PlayerRole.MIDFIELDER)
	_add_player(team_blue, 0.10, 0.00, s, 1, GameConfig.PlayerRole.ATTACKER)
	_add_player(team_blue, 0.10, 0.40, s, 1, GameConfig.PlayerRole.ATTACKER)
	_add_player(team_blue, 0.10, -0.40, s, 1, GameConfig.PlayerRole.ATTACKER)
	# Classic 4-3-3 jersey numbering: centre attacker wears 10 (the star number).
	# GK=1, DEF=2-5, MID=6-8, ATT-centre=10, ATT-right=9, ATT-left=11.
	var jersey := [1, 2, 3, 4, 5, 6, 7, 8, 10, 9, 11]
	for i in team_red.size():
		team_red[i].jersey_number = jersey[i]
		var lbl := team_red[i].node.get_node_or_null("JerseyNumber") as Label3D
		if lbl:
			lbl.text = str(jersey[i])
	for i in team_blue.size():
		team_blue[i].jersey_number = jersey[i]
		var lbl := team_blue[i].node.get_node_or_null("JerseyNumber") as Label3D
		if lbl:
			lbl.text = str(jersey[i])

func _add_player(team: Array[PlayerState], px: float, py: float, speed: float, side: int, role: int) -> void:
	var state := PlayerState.new(px, py, speed, side, role)
	state.node = player_factory._create_player_visual(state)
	players_root.add_child(state.node)
	team.append(state)

func _reset_game(kickoff_side: int) -> void:
	ball.x = 0.0
	ball.y = 0.0
	ball.vx = 0.0
	ball.vy = 0.0
	ball.is_super_shot = false
	ball.charging_power = 0.0
	ball.spin = 0.0
	view.reset_trail()
	_clear_owner()
	_reset_players(team_red)
	_reset_players(team_blue)
	var kickoff_team := _team_index_for_side(kickoff_side)
	_set_owner(kickoff_team, 5)
	var owner := _owner_player()
	if owner != null:
		owner.x = 0.0
		owner.y = 0.0
	kickoff_timer = 2.0
	# Start the user selection on the kickoff player (midfielder index 5 on red),
	# or on whichever red player is nearest the ball if red is not kicking off.
	selected_index[0] = _nearest_user_player(team_red, 0)
	selected_index[1] = -1
	switch_candidate_index[0] = -1
	switch_candidate_index[1] = -1

func _reset_players(team: Array[PlayerState]) -> void:
	for p in team:
		p.x = p.start_x
		p.y = p.start_y
		p.facing_x = -float(p.side)
		p.facing_y = 0.0
		p.stun_timer = 0.0
		p.kick_power = 0.0
		p.hold_timer = 0.0
		p.is_moving = false

func _team_index_for_side(side: int) -> int:
	if not team_red.is_empty() and team_red[0].side == side:
		return 0
	return 1

func _update_kickoff(delta: float) -> void:
	if kickoff_timer > 0.0:
		kickoff_timer = maxf(0.0, kickoff_timer - delta)

func _update_ball(delta: float) -> int:
	var owner := _owner_player()
	if owner != null:
		ball.x = owner.x + owner.facing_x * 0.035
		ball.y = owner.y + owner.facing_y * 0.035
		ball.vx = 0.0
		ball.vy = 0.0
		return 0
	ball.x += ball.vx * delta
	ball.y += ball.vy * delta
	var frame_friction := pow(ball.friction, delta * 60.0)
	ball.vx *= frame_friction
	ball.vy *= frame_friction
	ball.spin *= frame_friction
	var radius := 0.015
	var hit_x := false
	var hit_y := false
	if ball.x > GameConfig.FIELD_BOUNDARY_X - radius:
		ball.x = GameConfig.FIELD_BOUNDARY_X - radius
		hit_x = true
	elif ball.x < -GameConfig.FIELD_BOUNDARY_X + radius:
		ball.x = -GameConfig.FIELD_BOUNDARY_X + radius
		hit_x = true
	if ball.y > GameConfig.FIELD_BOUNDARY_Y - radius:
		ball.y = GameConfig.FIELD_BOUNDARY_Y - radius
		hit_y = true
	elif ball.y < -GameConfig.FIELD_BOUNDARY_Y + radius:
		ball.y = -GameConfig.FIELD_BOUNDARY_Y + radius
		hit_y = true
	if hit_y:
		ball.vy *= -1.0
	if hit_x:
		if absf(ball.y) > GameConfig.GOAL_HALF_WIDTH:
			ball.vx *= -1.0
		elif ball.x > 0.0:
			return _score_goal_against(1)
		else:
			return _score_goal_against(-1)
	return 0

func _score_goal_against(goal_side: int) -> int:
	var scoring_side := -goal_side
	if _team_index_for_side(scoring_side) == 0:
		score_left += 1
		_reset_game(goal_side)
		return -1
	score_right += 1
	_reset_game(goal_side)
	return 1

func _update_team(team: Array[PlayerState], opponents: Array[PlayerState], team_idx: int, is_user_team: bool, is_opponent: bool, delta: float) -> void:
	var snap: InputSnapshot = inputs[team_idx] if is_user_team else null
	if is_user_team and kickoff_timer <= 0.0:
		_handle_user_selection(team, team_idx, snap)
	var user_idx := selected_index[team_idx] if is_user_team else -1
	for i in team.size():
		var p := team[i]
		p.is_moving = false
		if kickoff_timer <= 0.0 and is_user_team and i == user_idx:
			_update_user_player(p, snap, team_idx, i, delta, team, opponents)
		elif kickoff_timer <= 0.0:
			ai._update_ai_player(p, team, opponents, team_idx, i, delta, is_opponent)
		if kickoff_timer <= 0.0:
			_try_capture_ball(team, team_idx, i)

func _handle_user_selection(team: Array[PlayerState], team_idx: int, snap: InputSnapshot) -> void:
	# In possession: control is locked to the ball carrier (FIFA-style). No switching.
	if ball.owner_team == team_idx:
		selected_index[team_idx] = ball.owner_index
		switch_candidate_index[team_idx] = -1
		return
	# Not in possession: on Q/L1 press, switch to the pre-computed candidate.
	if snap != null and snap.switch_pressed:
		var candidate := switch_candidate_index[team_idx]
		if candidate >= 0:
			selected_index[team_idx] = candidate
	# Every frame: recompute the switch candidate = nearest outfield player that
	# is NOT the currently selected one.
	var cur := selected_index[team_idx]
	var best := -1
	var best_dist := INF
	for i in team.size():
		if i == cur or team[i].role == GameConfig.PlayerRole.GOALKEEPER:
			continue
		var d := Vector2(team[i].x - ball.x, team[i].y - ball.y).length()
		if d < best_dist:
			best_dist = d
			best = i
	switch_candidate_index[team_idx] = best

func _nearest_user_player(team: Array[PlayerState], team_idx: int) -> int:
	var best := -1
	var best_dist := INF
	for i in team.size():
		if team[i].role == GameConfig.PlayerRole.GOALKEEPER and not (ball.owner_team == team_idx and ball.owner_index == i):
			continue
		var d := Vector2(team[i].x - ball.x, team[i].y - ball.y).length()
		if d < best_dist:
			best = i
			best_dist = d
	return best

func _update_user_player(p: PlayerState, snap: InputSnapshot, team_idx: int, player_idx: int, delta: float, team: Array[PlayerState], opponents: Array[PlayerState]) -> void:
	if p.stun_timer > 0.0:
		p.stun_timer -= delta
	var speed_mult := 0.3 if p.stun_timer > 0.0 else 1.0
	if p.kick_power > 0.0:
		speed_mult *= 0.8
	if snap.axis != Vector2.ZERO:
		p.x += snap.axis.x * p.speed * speed_mult * delta
		p.y += snap.axis.y * p.speed * speed_mult * delta
		p.facing_x = snap.axis.x if snap.axis.x != 0.0 else p.facing_x
		p.facing_y = snap.axis.y if snap.axis.y != 0.0 else p.facing_y
		p.is_moving = true
		_clamp_player(p)
	if ball.owner_team == team_idx and ball.owner_index == player_idx:
		ball.charging_power = p.kick_power
		if snap.pass_pressed:
			var target_goal_x := GameConfig.FIELD_BOUNDARY_X if p.side == -1 else -GameConfig.FIELD_BOUNDARY_X
			var pass_target := ai._best_pass_target(p, team, opponents, target_goal_x)
			if pass_target != null:
				_kick_from_player(p, Vector2(pass_target.x, pass_target.y), 0.35, false)
		elif snap.shoot_held:
			p.kick_power = minf(1.0, p.kick_power + delta * 2.0)
		elif snap.shoot_prev:
			_kick_from_player(p, _aim_target(snap, p), p.kick_power, true)
	else:
		p.kick_power = 0.0
		if ball.owner_team != team_idx or ball.owner_index != player_idx:
			ball.charging_power = 0.0

func _aim_target(snap: InputSnapshot, p: PlayerState) -> Vector2:
	if snap.aim_absolute:
		return snap.aim_vec
	var dir := snap.aim_vec if snap.aim_vec != Vector2.ZERO else Vector2(p.facing_x, p.facing_y)
	return Vector2(p.x, p.y) + dir

func _kick_from_player(p: PlayerState, target: Vector2, power: float, user_shot: bool) -> void:
	var dir := target - Vector2(p.x, p.y)
	if dir.length() <= 0.001:
		dir = Vector2(p.facing_x, p.facing_y)
	if dir.length() <= 0.001:
		dir = Vector2(float(p.side), 0.0)
	dir = dir.normalized()
	p.facing_x = dir.x
	p.facing_y = dir.y
	var final_power := 0.55 + power * 1.2
	ball.vx = dir.x * final_power
	ball.vy = dir.y * final_power
	ball.spin = final_power * 8.0
	var target_goal_x := GameConfig.FIELD_BOUNDARY_X if p.side == -1 else -GameConfig.FIELD_BOUNDARY_X
	var dist_to_goal := Vector2(target_goal_x - p.x, -p.y).length()
	ball.is_super_shot = user_shot and power > 0.5 and dist_to_goal < 0.65
	ball.charging_power = 0.0
	p.kick_power = 0.0
	p.hold_timer = 0.0
	p.stun_timer = 0.25 if power > 0.5 else 0.1
	_clear_owner()
	ball.x += ball.vx * 0.025
	ball.y += ball.vy * 0.025
	audio._play_kick()
	p.play_action("kick", 0.7)

func _try_capture_ball(team: Array[PlayerState], team_idx: int, player_idx: int) -> void:
	var p := team[player_idx]
	var capture_radius := 0.045
	if p.role == GameConfig.PlayerRole.GOALKEEPER:
		capture_radius = 0.05 if ball.is_super_shot else 0.10
	if Vector2(p.x - ball.x, p.y - ball.y).length() < capture_radius:
		if ball.owner_team == -1 and p.stun_timer <= 0.0:
			_set_owner(team_idx, player_idx)
			p.play_action("receive", 0.45)
		elif ball.owner_team != -1 and _owner_side() != p.side and p.stun_timer <= 0.0:
			var old := _owner_player()
			if old != null and old.role != GameConfig.PlayerRole.GOALKEEPER:
				old.stun_timer = 0.45
				old.kick_power = 0.0
				_set_owner(team_idx, player_idx)
				p.play_action("tackle", 0.55)

func _move_towards(p: PlayerState, target: Vector2, current_speed: float, delta: float) -> void:
	var diff := target - Vector2(p.x, p.y)
	if diff.length() > 0.005:
		var dir := diff.normalized()
		p.x += dir.x * current_speed * delta
		p.y += dir.y * current_speed * delta
		p.facing_x = dir.x
		p.facing_y = dir.y
		p.is_moving = true
		_clamp_player(p)

func _clamp_player(p: PlayerState) -> void:
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
	ball.is_super_shot = false
	ball.charging_power = 0.0

func _clear_owner() -> void:
	ball.owner_team = -1
	ball.owner_index = -1
	ball.charging_power = 0.0

func _owner_player() -> PlayerState:
	if ball.owner_team == 0 and ball.owner_index >= 0 and ball.owner_index < team_red.size():
		return team_red[ball.owner_index]
	if ball.owner_team == 1 and ball.owner_index >= 0 and ball.owner_index < team_blue.size():
		return team_blue[ball.owner_index]
	return null

func _owner_side() -> int:
	var owner := _owner_player()
	return owner.side if owner != null else 0

func _switch_ends() -> void:
	for p in team_red:
		_flip_player_end(p)
	for p in team_blue:
		_flip_player_end(p)

func _flip_player_end(p: PlayerState) -> void:
	p.side *= -1
	p.start_x *= -1.0
	p.x *= -1.0
	p.facing_x = -float(p.side)
	p.facing_y = 0.0

func _set_default_ends() -> void:
	for p in team_red:
		p.side = -1
		p.start_x = -absf(p.start_x)
		p.facing_x = 1.0
	for p in team_blue:
		p.side = 1
		p.start_x = absf(p.start_x)
		p.facing_x = -1.0
