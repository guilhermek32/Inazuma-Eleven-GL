class_name AIController
extends RefCounted

## Decision logic for AI-controlled players: goalkeeper positioning, owner
## dribble/pass/shoot choices, off-ball formation movement and pressing. Reads
## ball/player state and issues kicks/moves through the injected `sim` (the
## MatchSimulation), so random shoot/pass rolls scale with delta to stay
## frame-rate independent.

var sim: MatchSimulation

# Distances within this margin (normalized field units) count as a tie and are broken
# by player index, so two near-equidistant players never both elect themselves presser.
const PRESS_TIE_EPS := 0.02

func update_ai_player(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], team_idx: int, player_idx: int, delta: float, is_opponent: bool) -> void:
	if p.stun_timer > 0.0:
		p.stun_timer -= delta
	var speed_scale: float = sim.settings.ai_speed_mult if is_opponent else 1.0
	var current_speed: float = p.speed * speed_scale * (0.3 if p.stun_timer > 0.0 else 1.0)
	if p.role == GameConfig.PlayerRole.GOALKEEPER:
		if sim.ball.owner_team == team_idx and sim.ball.owner_index == player_idx:
			p.hold_timer += delta
			if p.hold_timer > 1.0:
				var clear_target := best_pass_target(p, team, opponents, -float(p.side) * GameConfig.FIELD_BOUNDARY_X)
				if clear_target != null:
					sim.kick_from_player(p, Vector2(clear_target.x, clear_target.y), 0.45, false)
				else:
					# Long clearance: hoof it high upfield.
					sim.kick_from_player(p, Vector2(-float(p.side) * 0.3, randf_range(-0.5, 0.5)), 0.7, false, GameConfig.CLEARANCE_LOFT)
			return
		p.hold_timer = 0.0
		var target_y := clampf(sim.ball.y, -GameConfig.GOAL_HALF_WIDTH, GameConfig.GOAL_HALF_WIDTH)
		var target_x := -GameConfig.FIELD_BOUNDARY_X if p.side == -1 else GameConfig.FIELD_BOUNDARY_X
		# Inbound shot: after a human-like reaction delay, stop ball-watching and
		# rush to where the shot will cross the line — so placed shots into the
		# corners genuinely beat a keeper that reacts late.
		var shot_inbound: bool = sim.ball.owner_team == -1 \
			and sim.ball.vx * float(p.side) > GameConfig.GK_SHOT_SPEED \
			and sim.ball.x * float(p.side) > 0.0
		if shot_inbound:
			if not p.gk_shot_active:
				p.gk_shot_active = true
				p.gk_react_timer = GameConfig.GK_REACTION[sim.settings.difficulty] if is_opponent else GameConfig.GK_REACTION[1]
			p.gk_react_timer = maxf(0.0, p.gk_react_timer - delta)
			if p.gk_react_timer <= 0.0:
				var time_to_line := absf(target_x - sim.ball.x) / maxf(absf(sim.ball.vx), 0.001)
				var intercept_y := sim.ball.y + sim.ball.vy * time_to_line
				target_y = clampf(intercept_y, -GameConfig.GOAL_HALF_WIDTH, GameConfig.GOAL_HALF_WIDTH)
		else:
			p.gk_shot_active = false
		sim.move_towards(p, Vector2(target_x, target_y), current_speed, delta)
		return
	if sim.ball.owner_team == team_idx and sim.ball.owner_index == player_idx:
		var decision_scale: float = sim.settings.ai_decision_mult if is_opponent else 1.0
		_update_ai_owner(p, team, opponents, delta, decision_scale)
		return
	var own_team_has_ball: bool = sim.ball.owner_team == team_idx
	var target := Vector2(p.start_x, p.start_y)
	var sprinting := false
	if own_team_has_ball:
		var attack_dir := -float(p.side)
		var advance: float = GameConfig.ROLE_ADVANCE[p.role]
		target = Vector2(p.start_x + attack_dir * advance, p.start_y * 0.85 + sim.ball.y * 0.15)
	else:
		var ball_owner: PlayerState = sim.owner_player()
		if ball_owner != null and ball_owner.role == GameConfig.PlayerRole.GOALKEEPER:
			target = Vector2(p.start_x, p.start_y)
		elif _is_presser(team, player_idx, 1):
			target = Vector2(sim.ball.x, sim.ball.y)
			# The presser sprints on the same stamina rules as a human sprinter…
			if p.stamina > 0.0:
				sprinting = true
				current_speed *= GameConfig.SPRINT_MULT
				p.stamina = maxf(0.0, p.stamina - GameConfig.SPRINT_DRAIN * delta)
			# …and commits to a tackle lunge when it closes on the carrier.
			var decision_scale: float = sim.settings.ai_decision_mult if is_opponent else 1.0
			if ball_owner != null and ball_owner.side != p.side and p.tackle_timer <= 0.0 and p.stun_timer <= 0.0:
				var carrier_dist := Vector2(ball_owner.x - p.x, ball_owner.y - p.y).length()
				if carrier_dist < GameConfig.AI_TACKLE_RANGE and randf() < GameConfig.AI_TACKLE_RATE * decision_scale * delta:
					p.tackle_timer = GameConfig.TACKLE_WINDOW
					p.play_action("tackle", 0.4)
		else:
			var ball_y_weight := 0.14 if _ball_in_own_third(p.side) else 0.25
			target = Vector2(p.start_x + (sim.ball.x - p.start_x) * 0.2, p.start_y + (sim.ball.y - p.start_y) * ball_y_weight)
			if _ball_in_own_third(p.side):
				var deepest_x := GameConfig.FIELD_BOUNDARY_X - (0.14 if p.role == GameConfig.PlayerRole.DEFENDER else 0.24)
				if p.side == 1:
					target.x = minf(target.x, deepest_x)
				else:
					target.x = maxf(target.x, -deepest_x)
	for mate in team:
		if mate == p:
			continue
		var away := Vector2(p.x - mate.x, p.y - mate.y)
		var d := away.length()
		if d < GameConfig.SPACING_DIST and d > 0.001:
			target += away / d * GameConfig.SPACING_PUSH
	if not sprinting:
		p.stamina = minf(1.0, p.stamina + GameConfig.SPRINT_REGEN * delta)
	sim.move_towards(p, target, current_speed * (0.88 if own_team_has_ball else 0.95), delta)


func _update_ai_owner(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], delta: float, decision_scale: float) -> void:
	var target_goal_x := GameConfig.FIELD_BOUNDARY_X if p.side == -1 else -GameConfig.FIELD_BOUNDARY_X
	var dist_to_goal := Vector2(target_goal_x - p.x, -p.y).length()
	# Find the nearest opponent bearing down on the carrier.
	var nearest_opp_dist := INF
	var nearest_opp: PlayerState = null
	for opp in opponents:
		var d := Vector2(opp.x - p.x, opp.y - p.y).length()
		if d < nearest_opp_dist:
			nearest_opp_dist = d
			nearest_opp = opp
	var under_pressure := nearest_opp_dist < GameConfig.AI_PRESSURE_DIST
	# When pressured, try to pass immediately before being tackled.
	if under_pressure and randf() < GameConfig.AI_PRESSURE_PASS_RATE * decision_scale * delta:
		var pass_target := best_pass_target(p, team, opponents, target_goal_x)
		if pass_target != null:
			sim.kick_from_player(p, Vector2(pass_target.x, pass_target.y), GameConfig.PASS_POWER, false)
			return
	# Shoot when close enough and facing the goal.
	var facing_goal := Vector2(target_goal_x - p.x, -p.y).normalized()
	var facing_dot := Vector2(p.facing_x, p.facing_y).dot(facing_goal)
	var shoot_range := GameConfig.AI_SHOOT_RANGE_FACING if facing_dot > 0.6 else GameConfig.AI_SHOOT_RANGE
	if dist_to_goal < shoot_range and randf() < GameConfig.AI_SHOOT_RATE * decision_scale * delta:
		var aim_y := clampf(randf_range(-0.06, 0.06), -GameConfig.GOAL_HALF_WIDTH * 0.8, GameConfig.GOAL_HALF_WIDTH * 0.8)
		var power := 0.65 + randf() * 0.2
		sim.kick_from_player(p, Vector2(target_goal_x, aim_y), power, false)
		return
	# Pass when a good option is available.
	if randf() < GameConfig.AI_PASS_RATE * decision_scale * delta:
		var pass_target := best_pass_target(p, team, opponents, target_goal_x)
		if pass_target != null:
			sim.kick_from_player(p, Vector2(pass_target.x, pass_target.y), GameConfig.PASS_POWER, false)
			return
	# Dribble toward goal, steering slightly away from the nearest opponent.
	var dribble := Vector2(target_goal_x - p.x, -p.y * 0.25)
	if nearest_opp != null and nearest_opp_dist < 0.25:
		var evade := Vector2(p.x - nearest_opp.x, p.y - nearest_opp.y).normalized()
		dribble += evade * 0.5
	if dribble.length() > 0.001:
		dribble = dribble.normalized()
		p.x += dribble.x * p.speed * 0.8 * delta
		p.y += dribble.y * p.speed * 0.8 * delta
		p.facing_x = dribble.x
		p.facing_y = dribble.y
		p.is_moving = true
		sim.clamp_player(p)

func best_pass_target(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], target_goal_x: float) -> PlayerState:
	var best: PlayerState = null
	var best_score := -999.0
	var from := Vector2(p.x, p.y)
	var owner_goal_dist := Vector2(target_goal_x - p.x, -p.y).length()
	for mate in team:
		if mate == p or mate.role == GameConfig.PlayerRole.GOALKEEPER:
			continue
		var to := Vector2(mate.x, mate.y)
		var mate_goal_dist := Vector2(target_goal_x - mate.x, -mate.y).length()
		# Backward/square passes are allowed (they recycle possession under
		# pressure) but penalised so forward options win when available.
		var backward_penalty := GameConfig.PASS_BACKWARD_PENALTY if mate_goal_dist >= owner_goal_dist else 0.0
		var open := true
		for opp in opponents:
			var opp_pos := Vector2(opp.x, opp.y)
			if opp_pos.distance_to(to) < GameConfig.PASS_OPENNESS_RADIUS:
				open = false
				break
			# An opponent standing on the passing lane intercepts the ball.
			if Geometry2D.get_closest_point_to_segment(opp_pos, from, to).distance_to(opp_pos) < GameConfig.PASS_LANE_RADIUS:
				open = false
				break
		if not open:
			continue
		var role_bonus := 4.0 if mate.role == GameConfig.PlayerRole.ATTACKER else (2.0 if mate.role == GameConfig.PlayerRole.MIDFIELDER else 0.0)
		var candidate := role_bonus - backward_penalty + 1.0 / (1.0 + from.distance_to(to))
		if candidate > best_score:
			best_score = candidate
			best = mate
	return best

func _is_presser(team: Array[PlayerState], player_idx: int, press_limit: int) -> bool:
	var my_dist := Vector2(team[player_idx].x - sim.ball.x, team[player_idx].y - sim.ball.y).length()
	var closer := 0
	for i in team.size():
		if i == player_idx or team[i].role == GameConfig.PlayerRole.GOALKEEPER:
			continue
		var d := Vector2(team[i].x - sim.ball.x, team[i].y - sim.ball.y).length()
		# Strictly nearer wins; on a near-tie the lower index wins. Without this both
		# equidistant players think they're the sole presser, charge the ball together
		# and deadlock flanking it just out of capture range.
		var ahead := d < my_dist - PRESS_TIE_EPS or (absf(d - my_dist) <= PRESS_TIE_EPS and i < player_idx)
		if ahead:
			closer += 1
			if closer >= press_limit:
				return false
	return true

func _ball_in_own_third(side: int) -> bool:
	return sim.ball.x * float(side) > 0.58
