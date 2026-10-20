class_name Tactics
extends RefCounted

## Read-only tactical queries over a match's players and ball, shared by the
## in-simulation AI (AIController, which drives every AI player inside the
## authoritative MatchSimulation) and the online bot (BotBrain, which only
## sees snapshots and answers with player input).
##
## Contract: every function is static and pure. It reads PlayerState fields
## (position, velocity, facing, role, side) and the plain values it is given,
## never mutates anything and never draws random numbers; callers that want
## noise (AI aim error) add it themselves from their own RNG. Positions are in
## the normalized 2D field space (see GameConfig).

## x of the goal line `p` attacks (its side flips at half time).
static func target_goal_x(p: PlayerState) -> float:
	return GameConfig.FIELD_BOUNDARY_X if p.side == -1 else -GameConfig.FIELD_BOUNDARY_X

## x of the goal line `p` defends.
static func own_goal_x(p: PlayerState) -> float:
	return -target_goal_x(p)

static func opposing_keeper(opponents: Array[PlayerState]) -> PlayerState:
	for opp in opponents:
		if opp.role == GameConfig.PlayerRole.GOALKEEPER:
			return opp
	return null

## Distance from `p` to the nearest of `opponents` (INF when there are none).
static func nearest_opponent_dist(p: PlayerState, opponents: Array[PlayerState]) -> float:
	var best := INF
	for opp in opponents:
		best = minf(best, Vector2(opp.x - p.x, opp.y - p.y).length())
	return best

## Shot aim on the goal line at `target_goal_x`: the corner away from the
## keeper's current position, shifted by `offset` (the caller's aim error),
## clamped inside the posts.
static func shot_target(opponents: Array[PlayerState], target_goal_x: float, offset: float) -> Vector2:
	var corner := GameConfig.GOAL_HALF_WIDTH * 0.7
	var keeper := opposing_keeper(opponents)
	var aim_y := -corner if keeper != null and keeper.y > 0.0 else corner
	aim_y += offset
	return Vector2(target_goal_x, clampf(aim_y, -GameConfig.GOAL_HALF_WIDTH * 0.85, GameConfig.GOAL_HALF_WIDTH * 0.85))

## Samples a fan of forward directions around `goal_dir` and returns the most
## open one: {"dir": Vector2, "clearance": float in [0, 0.4]}, clearance being
## the distance from a probe point ahead to the nearest opponent.
static func best_dribble(p: PlayerState, opponents: Array[PlayerState], goal_dir: Vector2) -> Dictionary:
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

## The best open outfield receiver for a pass from `p`, or null when every
## lane is blocked or every mate marked. Forward options, attackers, runners
## toward goal and mates in the box score higher.
static func best_pass_target(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], target_goal_x: float) -> PlayerState:
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

## Depth (in `attack`-direction units, bigger = deeper) of the defending
## side's second-to-last man: the offside line.
static func second_defender_line(defenders: Array[PlayerState], attack: float) -> float:
	var depths: Array[float] = []
	for opp in defenders:
		depths.append(opp.x * attack)
	depths.sort()
	depths.reverse()
	return depths[1] if depths.size() >= 2 else 0.0

## Off-ball run destination: three channel candidates ahead of `p`, scored by
## opponent clearance minus travel cost, capped just short of the offside line.
static func run_target(p: PlayerState, opponents: Array[PlayerState], attack_dir: float) -> Vector2:
	var line := second_defender_line(opponents, attack_dir)
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

## Goal-side marking spot when `p` (team[player_idx]) is the designated marker
## of one of the two most dangerous opponents (goal-side of the ball at
## `ball_x`, nearest our goal first). (INF, INF) when it marks nobody: only
## defenders mark, and the nearest defender to each danger gets the job.
static func mark_target_for(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], player_idx: int, ball_x: float) -> Vector2:
	var no_mark := Vector2(INF, INF)
	if p.role != GameConfig.PlayerRole.DEFENDER:
		return no_mark
	var side := float(p.side)
	var dangers: Array[PlayerState] = []
	for opp in opponents:
		if opp.role == GameConfig.PlayerRole.GOALKEEPER:
			continue
		if opp.x * side > ball_x * side:
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

## Whether team[player_idx] is among the `press_limit` outfield players
## nearest `ball` (near-ties within `tie_eps` go to the lower index, so two
## equidistant players never both elect themselves).
static func is_presser(team: Array[PlayerState], player_idx: int, press_limit: int, ball: Vector2, tie_eps: float) -> bool:
	var my_dist := Vector2(team[player_idx].x - ball.x, team[player_idx].y - ball.y).length()
	var closer := 0
	for i in team.size():
		if i == player_idx or team[i].role == GameConfig.PlayerRole.GOALKEEPER:
			continue
		var d := Vector2(team[i].x - ball.x, team[i].y - ball.y).length()
		var ahead := d < my_dist - tie_eps or (absf(d - my_dist) <= tie_eps and i < player_idx)
		if ahead:
			closer += 1
			if closer >= press_limit:
				return false
	return true
