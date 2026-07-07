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
			# Holding the ball: face infield so the glued ball sits in front of
			# the keeper, never behind him in the net.
			p.facing_x = -float(p.side)
			p.facing_y = 0.0
			p.hold_timer += delta
			if p.hold_timer > 1.0:
				var clear_target := best_pass_target(p, team, opponents, -float(p.side) * GameConfig.FIELD_BOUNDARY_X)
				if clear_target != null:
					sim.kick_from_player(p, sim.lead_pass_point(Vector2(p.x, p.y), clear_target), 0.45, false, -1.0, true)
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
		if p.gk_dive_timer > 0.0:
			p.gk_dive_timer = maxf(0.0, p.gk_dive_timer - delta)
		if shot_inbound:
			if not p.gk_shot_active:
				p.gk_shot_active = true
				p.gk_react_timer = GameConfig.GK_REACTION[sim.settings.difficulty] if is_opponent else GameConfig.GK_REACTION[1]
			p.gk_react_timer = maxf(0.0, p.gk_react_timer - delta)
			if p.gk_react_timer <= 0.0:
				var time_to_line := absf(target_x - sim.ball.x) / maxf(absf(sim.ball.vx), 0.001)
				var intercept_y := sim.ball.y + sim.ball.vy * time_to_line
				target_y = clampf(intercept_y, -GameConfig.GOAL_HALF_WIDTH, GameConfig.GOAL_HALF_WIDTH)
				# A wide intercept arriving fast triggers a dive: a sideways speed
				# burst now, plus the dive pose in the view while the timer runs.
				if p.gk_dive_timer <= 0.0 and absf(intercept_y - p.y) > GameConfig.GK_DIVE_MIN_OFFSET \
						and time_to_line < GameConfig.GK_DIVE_TIME_TO_LINE:
					p.gk_dive_timer = GameConfig.GK_DIVE_DURATION
					p.gk_dive_dir = 1 if intercept_y > p.y else -1
			if p.gk_dive_timer > 0.0:
				current_speed *= GameConfig.GK_DIVE_SPEED_MULT
		else:
			p.gk_shot_active = false
		sim.move_towards(p, Vector2(target_x, target_y), current_speed, delta)
		return
	if sim.ball.owner_team == team_idx and sim.ball.owner_index == player_idx:
		_update_ai_owner(p, team, opponents, delta, is_opponent)
		return
	var own_team_has_ball: bool = sim.ball.owner_team == team_idx
	var target := Vector2(p.start_x, p.start_y)
	var sprinting := false
	if own_team_has_ball:
		var attack_dir := -float(p.side)
		var advance: float = GameConfig.ROLE_ADVANCE[p.role]
		target = Vector2(p.start_x + attack_dir * advance, p.start_y * 0.85 + sim.ball.y * 0.15)
		# Staggered runs into space: attackers/mids periodically break from the
		# formation anchor toward the most open channel, staying onside.
		if p.role != GameConfig.PlayerRole.DEFENDER:
			p.run_timer -= delta
			if p.run_hold > 0.0:
				p.run_hold -= delta
				target = p.run_target
			elif p.run_timer <= 0.0:
				p.run_timer = randf_range(GameConfig.AI_RUN_INTERVAL_MIN, GameConfig.AI_RUN_INTERVAL_MAX) * p.decide_jitter
				# The attack alive in the final third: runs come far more often.
				if sim.ball.x * attack_dir > 0.3:
					p.run_timer *= 0.5
				p.run_target = pick_run_target(p, opponents, attack_dir)
				p.run_hold = GameConfig.AI_RUN_DURATION * randf_range(0.8, 1.25)
				target = p.run_target
	else:
		var ball_owner: PlayerState = sim.owner_player()
		if ball_owner != null and ball_owner.role == GameConfig.PlayerRole.GOALKEEPER:
			target = Vector2(p.start_x, p.start_y)
		elif _is_presser(team, player_idx, 1):
			target = Vector2(sim.ball.x, sim.ball.y)
			# A restart in progress: hold off at the clearance ring instead of
			# crowding the taker (the shield blocks steals anyway).
			if sim.restart_shield:
				var away := Vector2(p.x, p.y) - target
				if away.length() < 0.001:
					away = Vector2(float(p.side), 0.0)
				target += away.normalized() * GameConfig.RESTART_CLEAR_DIST
			# The presser sprints on the same stamina rules as a human sprinter…
			if p.stamina > 0.0:
				sprinting = true
				current_speed *= GameConfig.SPRINT_MULT
				p.stamina = maxf(0.0, p.stamina - GameConfig.SPRINT_DRAIN * delta)
			# …and commits to a tackle lunge when it closes on the carrier.
			var decision_scale: float = sim.settings.ai_decision_mult if is_opponent else 1.0
			if ball_owner != null and ball_owner.side != p.side and p.tackle_timer <= 0.0 and p.stun_timer <= 0.0 and not sim.restart_shield:
				var carrier_dist := Vector2(ball_owner.x - p.x, ball_owner.y - p.y).length()
				if carrier_dist < GameConfig.AI_TACKLE_RANGE and randf() < GameConfig.AI_TACKLE_RATE * decision_scale * delta:
					p.tackle_timer = GameConfig.TACKLE_WINDOW
					p.play_action("tackle", 0.4)
		elif _is_presser(team, player_idx, 2):
			# Second man in: cover goal-side of the presser so one dribble
			# can't beat two players at once.
			var own_goal := Vector2(float(p.side) * GameConfig.FIELD_BOUNDARY_X, 0.0)
			var to_goal := (own_goal - Vector2(sim.ball.x, sim.ball.y)).normalized()
			target = Vector2(sim.ball.x, sim.ball.y) + to_goal * 0.12
		else:
			var mark := mark_target_for(p, team, opponents, player_idx)
			if mark.x != INF:
				target = mark
			else:
				var ball_y_weight := 0.14 if _ball_in_own_third(p.side) else 0.25
				target = Vector2(p.start_x + (sim.ball.x - p.start_x) * 0.25, p.start_y + (sim.ball.y - p.start_y) * ball_y_weight)
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
	# Urgency: committed runs and long repositioning go at full pace; routine
	# shape-holding stays at a jog so the team doesn't look frantic.
	var pace := 0.95
	if own_team_has_ball:
		var to_target := (target - Vector2(p.x, p.y)).length()
		pace = 1.0 if (p.run_hold > 0.0 or to_target > 0.3) else 0.88
	sim.move_towards(p, target, current_speed * pace, delta)


# The carrier decides on think ticks (a human-like cadence with per-player
# jitter) and commits to the chosen action between ticks. Being pressured pulls
# the next think forward so the AI still reacts to an onrushing tackler.
func _update_ai_owner(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], delta: float, is_opponent: bool) -> void:
	var target_goal_x := GameConfig.FIELD_BOUNDARY_X if p.side == -1 else -GameConfig.FIELD_BOUNDARY_X
	var nearest_opp_dist := INF
	for opp in opponents:
		nearest_opp_dist = minf(nearest_opp_dist, Vector2(opp.x - p.x, opp.y - p.y).length())
	p.think_timer -= delta
	if nearest_opp_dist < GameConfig.AI_PRESSURE_DIST:
		p.think_timer = minf(p.think_timer, 0.08)
	if p.think_timer <= 0.0:
		var think_mult: float = sim.settings.ai_think_mult if is_opponent else 1.0
		p.think_timer = GameConfig.AI_THINK_INTERVAL * think_mult * p.decide_jitter
		if _decide_owner_action(p, team, opponents, target_goal_x, nearest_opp_dist, is_opponent):
			return   # ball was kicked
	# Committed action between ticks: dribble the chosen direction — pushing on
	# at near-full pace into open grass, more carefully when someone is close.
	if p.dribble_dir == Vector2.ZERO:
		p.dribble_dir = Vector2(target_goal_x - p.x, -p.y * 0.25).normalized()
	var pace := 1.0 if nearest_opp_dist > 0.22 else 0.85
	sim.apply_movement(p, p.dribble_dir * p.speed * pace, delta)

## One decision: scores shoot / pass / dribble-into-space and commits to the
## best. Returns true when the ball was played.
func _decide_owner_action(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], target_goal_x: float, nearest_opp_dist: float, is_opponent: bool) -> bool:
	var dist_to_goal := Vector2(target_goal_x - p.x, -p.y).length()
	var facing_goal := Vector2(target_goal_x - p.x, -p.y).normalized()
	var facing_dot := Vector2(p.facing_x, p.facing_y).dot(facing_goal)
	var under_pressure := nearest_opp_dist < GameConfig.AI_PRESSURE_DIST
	# Shoot: better when close, facing goal, and the keeper is off his line's centre.
	var shoot_score := -INF
	var shoot_range := GameConfig.AI_SHOOT_RANGE_FACING if facing_dot > 0.6 else GameConfig.AI_SHOOT_RANGE
	if dist_to_goal < shoot_range:
		shoot_score = (1.0 - dist_to_goal / shoot_range) * 2.2 * p.aggression + maxf(facing_dot, 0.0)
		var keeper := _opposing_keeper(opponents)
		if keeper != null and absf(keeper.y) > GameConfig.GOAL_HALF_WIDTH * 0.4:
			shoot_score += 0.6   # keeper dragged wide: the far corner is open
	# Pass: openness-scored receiver plus progression; much more attractive under pressure.
	var pass_target := best_pass_target(p, team, opponents, target_goal_x)
	var pass_score := -INF
	if pass_target != null:
		var mate_goal_dist := Vector2(target_goal_x - pass_target.x, -pass_target.y).length()
		pass_score = 0.9 + (dist_to_goal - mate_goal_dist) * 2.0
		if under_pressure:
			pass_score += 1.6
	# Dribble into space: commit to the most open forward lane until the next think.
	var dribble := _best_dribble(p, opponents, facing_goal)
	var dribble_score: float = 0.6 + dribble.clearance * 3.0 - (1.2 if under_pressure else 0.0)
	if shoot_score >= pass_score and shoot_score >= dribble_score:
		var power := 0.65 + randf() * 0.2
		sim.kick_from_player(p, pick_shot_target(p, opponents, target_goal_x, sim.settings.ai_aim_error if is_opponent else float(GameConfig.AI_AIM_ERROR[1])), power, false, -1.0, false, true)
		return true
	if pass_score >= dribble_score and pass_target != null:
		sim.kick_from_player(p, sim.lead_pass_point(Vector2(p.x, p.y), pass_target), GameConfig.PASS_POWER, false, -1.0, true)
		return true
	p.dribble_dir = dribble.dir
	return false

## Aims at the corner away from the keeper's current position, with a
## difficulty-scaled error. Public for the headless tests.
func pick_shot_target(p: PlayerState, opponents: Array[PlayerState], target_goal_x: float, aim_error: float) -> Vector2:
	var corner := GameConfig.GOAL_HALF_WIDTH * 0.7
	var keeper := _opposing_keeper(opponents)
	var aim_y := -corner if keeper != null and keeper.y > 0.0 else corner
	aim_y += randf_range(-1.0, 1.0) * aim_error
	return Vector2(target_goal_x, clampf(aim_y, -GameConfig.GOAL_HALF_WIDTH * 0.85, GameConfig.GOAL_HALF_WIDTH * 0.85))

func _opposing_keeper(opponents: Array[PlayerState]) -> PlayerState:
	for opp in opponents:
		if opp.role == GameConfig.PlayerRole.GOALKEEPER:
			return opp
	return null

## Samples a fan of forward directions and returns the most open one:
## clearance = distance from a probe point ahead to the nearest opponent.
func _best_dribble(p: PlayerState, opponents: Array[PlayerState], goal_dir: Vector2) -> Dictionary:
	var best_dir := goal_dir
	var best_clearance := -INF
	for i in GameConfig.AI_DRIBBLE_SAMPLES:
		var angle := lerpf(-1.0, 1.0, float(i) / float(GameConfig.AI_DRIBBLE_SAMPLES - 1))
		var dir := goal_dir.rotated(angle)
		var probe := Vector2(p.x, p.y) + dir * 0.18
		var clearance := INF
		for opp in opponents:
			clearance = minf(clearance, Vector2(opp.x - probe.x, opp.y - probe.y).length())
		# Prefer open lanes, but discount ones that turn away from goal.
		clearance -= absf(angle) * 0.04
		if clearance > best_clearance:
			best_clearance = clearance
			best_dir = dir
	return {"dir": best_dir, "clearance": clampf(best_clearance, 0.0, 0.4)}

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
		# Reward receivers making a run toward goal (through balls onto the led
		# pass) and receivers already in shooting territory.
		var goal_dir := Vector2(target_goal_x - mate.x, -mate.y).normalized()
		var runner_bonus: float = maxf(0.0, Vector2(mate.vel_x, mate.vel_y).dot(goal_dir)) * GameConfig.PASS_RUNNER_BONUS
		var box_bonus: float = GameConfig.PASS_BOX_BONUS if mate_goal_dist < 0.4 else 0.0
		var candidate := role_bonus + runner_bonus + box_bonus - backward_penalty + 1.0 / (1.0 + from.distance_to(to))
		if candidate > best_score:
			best_score = candidate
			best = mate
	return best

## Picks an off-ball run destination: three channel candidates ahead of the
## player, scored by opponent clearance minus travel cost; attackers are capped
## just short of the offside line. Public for the headless tests.
func pick_run_target(p: PlayerState, opponents: Array[PlayerState], attack_dir: float) -> Vector2:
	var line := sim.second_defender_line(opponents, attack_dir)
	var max_depth := minf(line - 0.02, GameConfig.FIELD_BOUNDARY_X - 0.06)
	var depth := clampf(p.x * attack_dir + 0.18, 0.05, max_depth)
	var best := Vector2(p.start_x, p.start_y)
	var best_score := -INF
	for ch in [-0.45, 0.0, 0.45]:
		var cand := Vector2(depth * attack_dir, ch)
		var clearance := INF
		for opp in opponents:
			clearance = minf(clearance, Vector2(opp.x - cand.x, opp.y - cand.y).length())
		var score: float = clearance - Vector2(cand.x - p.x, cand.y - p.y).length() * 0.5
		if score > best_score:
			best_score = score
			best = cand
	return best

## Goal-side marking spot when this player is the designated marker of one of
## the two most dangerous opponents (those between the ball and our goal,
## nearest our goal first). Returns (INF, INF) when this player marks nobody —
## only defenders mark, and the nearest defender to each danger gets the job.
func mark_target_for(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], player_idx: int) -> Vector2:
	var no_mark := Vector2(INF, INF)
	if p.role != GameConfig.PlayerRole.DEFENDER:
		return no_mark
	var side := float(p.side)
	# Dangerous: goal-side of the ball, ranked by proximity to our goal line.
	var dangers: Array[PlayerState] = []
	for opp in opponents:
		if opp.role == GameConfig.PlayerRole.GOALKEEPER:
			continue
		if opp.x * side > sim.ball.x * side:
			dangers.append(opp)
	dangers.sort_custom(func(a: PlayerState, b: PlayerState) -> bool: return a.x * side > b.x * side)
	var own_goal := Vector2(side * GameConfig.FIELD_BOUNDARY_X, 0.0)
	for n in mini(2, dangers.size()):
		var danger := dangers[n]
		# The nearest defender (lowest index on ties) is that danger's marker.
		var marker := -1
		var marker_dist := INF
		for i in team.size():
			if team[i].role != GameConfig.PlayerRole.DEFENDER:
				continue
			var d := Vector2(team[i].x - danger.x, team[i].y - danger.y).length()
			if d < marker_dist:
				marker_dist = d
				marker = i
		if marker == player_idx:
			var danger_pos := Vector2(danger.x, danger.y)
			return danger_pos + (own_goal - danger_pos).normalized() * GameConfig.AI_MARK_DIST
	return no_mark

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
