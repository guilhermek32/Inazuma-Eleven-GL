extends SceneTree

## Headless gameplay-logic tests for MatchSimulation, MatchConfig and
## MatchSession. Nothing here builds a 3D node, so these exercise pure game
## state: kickoff possession, goal detection, boundary clamps, the
## nearest-player capture rule, end switching, and the session's clock, halves,
## seeded reproducibility and per-session slow motion.
##
## Run: godot-4 --headless --path . --script res://tests/run_sim_tests.gd
## Exits 0 when every check passes, 1 otherwise.

var failures := 0

func _initialize() -> void:
	_test_kickoff_possession()
	_test_goal_detection()
	_test_crossbar_denies_high_shot()
	_test_throw_in()
	_test_nearest_capture_wins()
	_test_lofted_ball_clears_defenders()
	_test_steal_requires_tackle()
	_test_switch_ends()
	_test_foul_from_behind()
	_test_frontal_tackle_is_clean()
	_test_fouls_toggle_off()
	_test_offside_flagged_receiver()
	_test_onside_receiver_plays_on()
	_test_offside_toggle_off()
	_test_stats_tracking()
	_test_gk_dive_triggers()
	_test_rain_friction()
	_test_arrive_dead_zone()
	_test_pass_prefers_runner()
	_test_gk_holding_never_own_goals()
	_test_ai_think_cadence()
	_test_ai_shot_picks_far_corner()
	_test_ai_run_finds_space()
	_test_ai_defender_marks_goal_side()
	_test_difficulty_is_not_speed()
	_test_restart_clears_space()
	_test_restart_shield_blocks_steal()
	_test_restart_shield_expires()
	_test_movement_momentum()
	_test_knock_ahead_dribble()
	_test_led_pass()
	_test_switch_targets_predicted_ball()
	_test_actions_are_events()
	_test_config_round_trip()
	_test_config_rejects_invalid()
	_test_session_seed_reproducible()
	_test_session_halves_and_full_time()
	_test_session_slowmo_is_per_session()
	_test_session_restart_reinitializes()
	_test_cancelled_charge_is_dropped()
	if failures == 0:
		print("ALL TESTS PASSED")
	else:
		print("%d TEST(S) FAILED" % failures)
	quit(1 if failures > 0 else 0)

func _check(cond: bool, test_name: String) -> void:
	if cond:
		print("PASS  %s" % test_name)
	else:
		failures += 1
		print("FAIL  %s" % test_name)

func _make_sim() -> MatchSimulation:
	var sim := MatchSimulation.new()
	sim.ai = AIController.new()
	sim.ai.sim = sim
	sim.create_teams()
	return sim

func _test_kickoff_possession() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	_check(sim.teams[0].players.size() == 11 and sim.teams[1].players.size() == 11, "teams have 11 players each")
	var owner: PlayerState = sim.owner_player()
	_check(owner != null and owner.side == 1, "kickoff side +1 hands the ball to the blue team")
	_check(owner != null and owner.role == GameConfig.PlayerRole.MIDFIELDER, "kickoff taker is a midfielder")
	_check(owner != null and absf(owner.x) < 0.001 and absf(owner.y) < 0.001, "kickoff taker stands at the centre spot")
	sim.free()

func _test_goal_detection() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	sim.restart_timer = 0.0
	sim._clear_owner()
	sim.ball.x = 0.90
	sim.ball.y = 0.0
	sim.ball.vx = 2.0
	sim.ball.vy = 0.0
	var scorer: int = sim.step(0.05)
	_check(scorer == -1, "shot into the +x goal credits the left (red) side")
	_check(sim.score_left == 1 and sim.score_right == 0, "score_left incremented")
	_check(sim.pending_kickoff_side == 1, "conceding side kicks off next")
	sim.free()

func _test_crossbar_denies_high_shot() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	sim.restart_timer = 0.0
	sim._clear_owner()
	# Blue (side +1 by default) touched last, so a ball over its own bar at +x
	# is a corner for red. Keep it high enough to stay above GOAL_HEIGHT.
	sim.ball.last_touch_team = 1
	sim.ball.x = 0.90
	sim.ball.y = 0.0
	sim.ball.vx = 2.0
	sim.ball.h = 3.0
	sim.ball.vh = 2.0
	var scorer: int = sim.step(0.016)
	_check(scorer == 0, "shot over the bar does not score")
	_check(sim.restart_type == MatchSimulation.Restart.CORNER, "over the bar off a defender = corner")
	_check(sim.ball.owner_team == 0, "corner is taken by the attacking team")
	_check(sim.restart_timer > 0.0, "restart freeze is running")
	sim.free()

func _test_throw_in() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	sim.restart_timer = 0.0
	sim._clear_owner()
	sim.ball.last_touch_team = 1
	sim.ball.x = 0.0
	sim.ball.y = 0.70
	sim.ball.vx = 0.0
	sim.ball.vy = 2.0
	sim.step(0.05)
	_check(sim.restart_type == MatchSimulation.Restart.THROW_IN, "ball over the touchline = throw-in")
	_check(sim.ball.owner_team == 0, "throw-in goes against the last-touch team")
	sim.free()

func _test_lofted_ball_clears_defenders() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	sim._clear_owner()
	sim.ball.x = 0.5
	sim.ball.y = 0.3
	sim.ball.h = GameConfig.CAPTURE_MAX_HEIGHT + 0.4
	sim.teams[1].players[9].x = 0.51
	sim.teams[1].players[9].y = 0.3
	sim._resolve_ball_capture()
	_check(sim.ball.owner_team == -1, "outfielder cannot capture a ball above head height")
	sim.free()

func _test_nearest_capture_wins() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	sim._clear_owner()
	# Red would win an update-order tie; the blue player is strictly nearer, so
	# the global nearest-player rule must hand the ball to blue.
	sim.ball.x = 0.5
	sim.ball.y = 0.3
	sim.teams[0].players[9].x = 0.53
	sim.teams[0].players[9].y = 0.3
	sim.teams[1].players[9].x = 0.51
	sim.teams[1].players[9].y = 0.3
	sim._resolve_ball_capture()
	_check(sim.ball.owner_team == 1 and sim.ball.owner_index == 9, "nearest player captures the loose ball regardless of team order")
	sim.free()

func _test_steal_requires_tackle() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	# Blue's kickoff taker owns the ball at the centre; park a red attacker in
	# front of them (a frontal challenge, so the new foul rule stays out of the
	# picture). Without a live tackle window no steal happens; with one the
	# red player wins the ball and the old carrier is stunned.
	var carrier: PlayerState = sim.owner_player()
	var red_att: PlayerState = sim.teams[0].players[9]
	red_att.x = sim.ball.x - 0.02
	red_att.y = sim.ball.y
	sim._resolve_ball_capture()
	_check(sim.ball.owner_team == 1, "contact alone no longer steals the ball")
	red_att.tackle_timer = GameConfig.TACKLE_WINDOW
	sim._resolve_ball_capture()
	_check(sim.ball.owner_team == 0 and sim.ball.owner_index == 9, "a live tackle window wins the steal")
	_check(carrier.stun_timer > 0.0, "the dispossessed carrier is stunned")
	_check(red_att.tackle_timer == 0.0, "winning consumes the tackle window")
	sim.free()

func _test_foul_from_behind() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	# Blue's kickoff taker holds the ball facing -x; a red tackler arriving from
	# +x (behind him) wins the contact but it's a foul: free kick to blue.
	var carrier: PlayerState = sim.owner_player()
	var red_att: PlayerState = sim.teams[0].players[9]
	red_att.x = carrier.x + 0.02
	red_att.y = carrier.y
	red_att.tackle_timer = GameConfig.TACKLE_WINDOW
	sim._resolve_ball_capture()
	_check(sim.restart_type == MatchSimulation.Restart.FREE_KICK, "tackle from behind awards a free kick")
	_check(sim.ball.owner_team == 1, "free kick goes to the fouled team")
	_check(red_att.stun_timer > 0.0, "the fouling tackler is stunned")
	_check(sim.stats[0].fouls == 1, "the foul is counted for the tackling team")
	sim.free()

func _test_frontal_tackle_is_clean() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	# Same situation but the tackler comes from the front (where the carrier is
	# facing): a clean steal, counted in the stats.
	var carrier: PlayerState = sim.owner_player()
	var red_att: PlayerState = sim.teams[0].players[9]
	red_att.x = carrier.x - 0.02
	red_att.y = carrier.y
	red_att.tackle_timer = GameConfig.TACKLE_WINDOW
	sim._resolve_ball_capture()
	_check(sim.ball.owner_team == 0, "frontal tackle is a clean steal")
	_check(sim.stats[0].steals == 1, "the steal is counted")
	sim.free()

func _test_fouls_toggle_off() -> void:
	var sim := _make_sim()
	sim.config.fouls_enabled = false
	sim.reset_game(1)
	var carrier: PlayerState = sim.owner_player()
	var red_att: PlayerState = sim.teams[0].players[9]
	red_att.x = carrier.x + 0.02
	red_att.y = carrier.y
	red_att.tackle_timer = GameConfig.TACKLE_WINDOW
	sim._resolve_ball_capture()
	_check(sim.ball.owner_team == 0, "with fouls disabled a tackle from behind steals normally")
	sim.free()

func _test_offside_flagged_receiver() -> void:
	var sim := _make_sim()
	sim.config.offside_enabled = true
	sim.reset_game(1)
	sim.restart_timer = 0.0
	# Red (attacks +x) passes to a striker beyond blue's second-to-last defender
	# (defenders sit at ~0.65, keeper at 0.93): offside, free kick to blue.
	var kicker: PlayerState = sim.teams[0].players[5]
	kicker.x = 0.2
	kicker.y = 0.0
	var striker: PlayerState = sim.teams[0].players[9]
	striker.x = 0.75
	striker.y = 0.1
	sim.ball.x = kicker.x
	sim.ball.y = kicker.y
	sim.kick_from_player(kicker, Vector2(striker.x, striker.y), GameConfig.PASS_POWER, false, -1.0, true)
	_check(striker in sim.offside_flags, "the striker beyond the line is flagged at the pass")
	striker.stun_timer = 0.0
	sim.ball.x = striker.x
	sim.ball.y = striker.y
	sim.ball.h = 0.0
	sim._resolve_ball_capture()
	_check(sim.restart_type == MatchSimulation.Restart.FREE_KICK and sim.ball.owner_team == 1,
			"flagged receiver collecting the pass concedes a free kick to the defenders")
	_check(sim.stats[0].offsides == 1, "the offside is counted")
	sim.free()

func _test_onside_receiver_plays_on() -> void:
	var sim := _make_sim()
	sim.config.offside_enabled = true
	sim.reset_game(1)
	sim.restart_timer = 0.0
	var kicker: PlayerState = sim.teams[0].players[5]
	kicker.x = 0.2
	kicker.y = 0.0
	var striker: PlayerState = sim.teams[0].players[9]
	striker.x = 0.5   # short of blue's second-to-last defender (~0.65)
	striker.y = 0.1
	sim.ball.x = kicker.x
	sim.ball.y = kicker.y
	sim.kick_from_player(kicker, Vector2(striker.x, striker.y), GameConfig.PASS_POWER, false, -1.0, true)
	_check(not striker in sim.offside_flags, "a receiver level with play is not flagged")
	striker.stun_timer = 0.0
	sim.ball.x = striker.x
	sim.ball.y = striker.y
	sim.ball.h = 0.0
	sim._resolve_ball_capture()
	_check(sim.ball.owner_team == 0, "onside receiver keeps possession")
	sim.free()

func _test_offside_toggle_off() -> void:
	var sim := _make_sim()
	sim.config.offside_enabled = false
	sim.reset_game(1)
	sim.restart_timer = 0.0
	var kicker: PlayerState = sim.teams[0].players[5]
	kicker.x = 0.2
	var striker: PlayerState = sim.teams[0].players[9]
	striker.x = 0.75
	striker.y = 0.0
	sim.kick_from_player(kicker, Vector2(striker.x, striker.y), GameConfig.PASS_POWER, false, -1.0, true)
	_check(sim.offside_flags.is_empty(), "offside disabled: no receivers are flagged")
	sim.free()

func _test_stats_tracking() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	# Possession accrues per owned second (kickoff taker holds through the freeze).
	sim.step(0.5)
	_check(absf(sim.stats[1].possession - 0.5) < 0.01, "possession time accrues to the owning team")
	# A shot aimed inside the goal mouth counts as a shot on target.
	var shooter: PlayerState = sim.teams[0].players[9]
	shooter.x = 0.5
	shooter.y = 0.0
	sim.ball.x = shooter.x
	sim.ball.y = shooter.y
	sim.kick_from_player(shooter, Vector2(GameConfig.FIELD_BOUNDARY_X, 0.0), 0.7, true)
	_check(sim.stats[0].shots == 1 and sim.stats[0].on_target == 1, "an on-target shot bumps shots and on-target")
	sim.free()

func _test_gk_dive_triggers() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	sim.restart_timer = 0.0
	sim._clear_owner()
	# Fast shot arcing toward the top corner of blue's goal: after the reaction
	# delay the keeper commits to a dive toward the predicted intercept.
	var keeper: PlayerState = sim.teams[1].players[0]
	sim.ball.x = 0.5
	sim.ball.y = 0.0
	sim.ball.vx = 2.0
	sim.ball.vy = 0.4
	sim.ai.update_ai_player(keeper, sim.teams[1].players, sim.teams[0].players, 1, 0, 0.3)
	_check(keeper.gk_dive_timer > 0.0, "a wide fast shot triggers the keeper dive")
	_check(keeper.gk_dive_dir == 1, "the dive heads toward the intercept side")
	sim.free()

func _test_rain_friction() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	sim.restart_timer = 0.0
	sim._clear_owner()
	var dist := {}
	for fric in [GameConfig.BALL_FRICTION, GameConfig.RAIN_BALL_FRICTION]:
		sim.ball.x = -0.5
		sim.ball.y = 0.0
		sim.ball.vx = 0.8
		sim.ball.vy = 0.0
		sim.ball.friction = fric
		for i in 90:
			sim._update_ball(1.0 / 60.0)
		dist[fric] = sim.ball.x
	_check(dist[GameConfig.RAIN_BALL_FRICTION] > dist[GameConfig.BALL_FRICTION],
			"the wet ball skids farther than the dry ball")
	sim.free()

func _test_arrive_dead_zone() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	var p: PlayerState = sim.teams[0].players[9]
	p.x = 0.2
	p.y = 0.2
	p.vel_x = 0.0
	p.vel_y = 0.0
	p.is_moving = false
	sim.move_towards(p, Vector2(0.21, 0.2), p.speed, 0.05)
	_check(absf(p.x - 0.2) < 0.0001 and not p.is_moving, "a player already at their spot stands still instead of shuffling")
	sim.free()

func _test_pass_prefers_runner() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	# Two attackers mirror-placed; only one is running toward goal. The pass
	# scoring must prefer the runner (through ball onto the led pass).
	var carrier: PlayerState = sim.teams[0].players[5]
	carrier.x = 0.0
	carrier.y = 0.0
	var runner: PlayerState = sim.teams[0].players[9]
	runner.x = 0.3
	runner.y = 0.3
	runner.vel_x = 0.2
	var walker: PlayerState = sim.teams[0].players[10]
	walker.x = 0.3
	walker.y = -0.3
	for opp in sim.teams[1].players:
		opp.x = -0.8
	var pick: PlayerState = sim.ai.best_pass_target(carrier, sim.teams[0].players, sim.teams[1].players, GameConfig.FIELD_BOUNDARY_X)
	_check(pick == runner, "the pass targets the teammate running toward goal")
	sim.free()

func _test_gk_holding_never_own_goals() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	sim.restart_timer = 0.0
	# Regression: a keeper who caught the ball while retreating faced his own
	# net, the dribble lead pushed the glued ball over the line, and his
	# clearance kicked off from inside the goal — an instant own goal.
	var keeper: PlayerState = sim.teams[1].players[0]
	keeper.x = 0.92
	keeper.y = 0.0
	keeper.facing_x = 1.0   # facing his own goal
	keeper.facing_y = 0.0
	keeper.vel_x = 0.4      # arrived at speed, maximizing the dribble lead
	sim._set_owner(1, 0)
	sim.ball.x = 0.95       # ball already carried past the line
	sim.ball.y = 0.0
	var scorer := 0
	for i in 30:
		scorer = sim.step(1.0 / 60.0)
		if scorer != 0:
			break
	_check(scorer == 0, "a keeper holding the ball can never concede an own goal")
	_check(sim.ball.x < GameConfig.FIELD_BOUNDARY_X - 0.015, "the held ball is clamped back inside the field")
	sim.free()

func _test_ai_think_cadence() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	sim.restart_timer = 0.0
	# Red attacker alone in front of the +x goal with the whole blue team pushed
	# away: with the think timer armed no kick fires; once it expires the carrier
	# decides (and in this setup, shoots).
	var p: PlayerState = sim.teams[0].players[9]
	p.x = 0.75
	p.y = 0.0
	p.facing_x = 1.0
	p.facing_y = 0.0
	for opp in sim.teams[1].players:
		opp.x = -0.8
	sim._set_owner(0, 9)
	sim.ball.x = p.x
	sim.ball.y = p.y
	p.think_timer = 10.0
	for i in 5:
		sim.ai.update_ai_player(p, sim.teams[0].players, sim.teams[1].players, 0, 9, 0.05)
	_check(sim.ball.owner_team == 0, "no decision fires while the think timer is armed")
	p.think_timer = 0.0
	sim.ai.update_ai_player(p, sim.teams[0].players, sim.teams[1].players, 0, 9, 0.05)
	_check(sim.ball.owner_team == -1 and sim.stats[0].shots >= 1, "on the think tick the open carrier shoots")
	sim.free()

func _test_ai_shot_picks_far_corner() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	var p: PlayerState = sim.teams[0].players[9]
	p.x = 0.6
	p.y = 0.0
	var keeper: PlayerState = sim.teams[1].players[0]
	keeper.y = 0.06   # keeper dragged toward +y
	var aim := sim.ai.pick_shot_target(p, sim.teams[1].players, GameConfig.FIELD_BOUNDARY_X, 0.0)
	_check(aim.y < 0.0, "the AI shoots at the corner away from the keeper")
	keeper.y = -0.06
	aim = sim.ai.pick_shot_target(p, sim.teams[1].players, GameConfig.FIELD_BOUNDARY_X, 0.0)
	_check(aim.y > 0.0, "...on either side")
	sim.free()

func _test_ai_run_finds_space() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	# Crowd the +y channel with blue players: a red attacker's run must head for
	# a channel with more clearance than the crowded one.
	var p: PlayerState = sim.teams[0].players[9]
	p.x = 0.2
	p.y = 0.0
	for i in range(1, 6):
		sim.teams[1].players[i].x = 0.35
		sim.teams[1].players[i].y = 0.45
	var run := sim.ai.pick_run_target(p, sim.teams[1].players, 1.0)
	_check(run.y < 0.45 - 0.1, "the run target avoids the crowded channel")
	var line := sim.second_defender_line(sim.teams[1].players, 1.0)
	_check(run.x <= line - 0.019, "the run stays onside of the second defender")
	sim.free()

func _test_ai_defender_marks_goal_side() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	sim.restart_timer = 0.0
	sim._clear_owner()
	# Loose ball at midfield; a blue striker lurks between the ball and the red
	# goal. The nearest red defender must be told to mark him goal-side.
	sim.ball.x = 0.0
	sim.ball.y = 0.0
	var striker: PlayerState = sim.teams[1].players[9]
	striker.x = -0.5
	striker.y = 0.1
	var marker: PlayerState = sim.teams[0].players[1]   # a red defender
	marker.x = -0.55
	marker.y = 0.05
	var mark := sim.ai.mark_target_for(marker, sim.teams[0].players, sim.teams[1].players, 1)
	_check(mark.x != INF, "the nearest defender is assigned the dangerous striker")
	_check(mark.x < striker.x and absf(mark.y - striker.y) < 0.1, "the marking spot is goal-side of the striker")
	sim.free()

func _test_difficulty_is_not_speed() -> void:
	var hard: Dictionary = MatchConfig.DIFFICULTY_PROFILES[2]
	var easy: Dictionary = MatchConfig.DIFFICULTY_PROFILES[0]
	_check(hard.speed <= 1.05 and easy.speed >= 0.95, "difficulty barely touches movement speed")
	_check(hard.think < easy.think, "hard AI thinks faster than easy AI")
	_check(hard.aim_error < easy.aim_error, "hard AI aims more precisely than easy AI")

func _test_restart_clears_space() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	sim.restart_timer = 0.0
	sim._clear_owner()
	# Park a blue defender right on the future throw-in spot, then boot the ball
	# out off blue: the restart must push him to the clearance ring and pull two
	# red teammates in close as passing options.
	sim.teams[1].players[3].x = 0.0
	sim.teams[1].players[3].y = 0.70
	sim.ball.last_touch_team = 1
	sim.ball.x = 0.0
	sim.ball.y = 0.70
	sim.ball.vy = 2.0
	sim.step(0.05)
	var spot := Vector2(sim.ball.x, sim.ball.y)
	var clear := true
	for opp in sim.teams[1].players:
		if Vector2(opp.x - spot.x, opp.y - spot.y).length() < GameConfig.RESTART_CLEAR_DIST - 0.01:
			clear = false
	_check(clear, "opponents are pushed out of the restart clearance ring")
	var close_mates := 0
	for i in sim.teams[0].players.size():
		if i == sim.ball.owner_index:
			continue
		if Vector2(sim.teams[0].players[i].x - spot.x, sim.teams[0].players[i].y - spot.y).length() < GameConfig.RESTART_SUPPORT_DIST + 0.05:
			close_mates += 1
	_check(close_mates >= 2, "two teammates step close as pass options")
	sim.free()

func _test_restart_shield_blocks_steal() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	sim.restart_timer = 0.0
	sim._clear_owner()
	sim.ball.last_touch_team = 1
	sim.ball.x = 0.0
	sim.ball.y = 0.70
	sim.ball.vy = 2.0
	sim.step(0.05)   # throw-in awarded to red, shield up
	sim.restart_timer = 0.0
	var taker: PlayerState = sim.owner_player()
	var thief: PlayerState = sim.teams[1].players[5]
	thief.x = taker.x + 0.01
	thief.y = taker.y
	thief.stun_timer = 0.0
	thief.tackle_timer = GameConfig.TACKLE_WINDOW
	sim.ball.x = taker.x
	sim.ball.y = taker.y
	sim._resolve_ball_capture()
	_check(sim.ball.owner_team == 0, "the restart shield blocks steals before the ball is played")
	# Once the taker plays the ball the shield drops.
	sim.kick_from_player(taker, Vector2(0.0, 0.0), GameConfig.PASS_POWER, false, -1.0, true)
	_check(not sim.restart_shield, "playing the ball ends the restart shield")
	sim.free()

func _test_restart_shield_expires() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	sim.restart_timer = 0.0
	sim._clear_owner()
	sim.ball.last_touch_team = 1
	sim.ball.x = 0.0
	sim.ball.y = 0.70
	sim.ball.vy = 2.0
	sim.step(0.05)
	sim.restart_timer = 0.0
	for i in 60:
		sim.step(GameConfig.RESTART_SHIELD_TIME / 30.0)
		if not sim.restart_shield:
			break
	_check(not sim.restart_shield, "the restart shield times out so play cannot stall")
	sim.free()

func _test_movement_momentum() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	var p: PlayerState = sim.teams[0].players[9]
	sim.apply_movement(p, Vector2(p.speed, 0.0), 0.05)
	var v1 := Vector2(p.vel_x, p.vel_y).length()
	_check(v1 > 0.0 and v1 < p.speed * 0.5, "one tick of acceleration is well below top speed")
	for i in 30:
		sim.apply_movement(p, Vector2(p.speed, 0.0), 0.05)
	_check(absf(Vector2(p.vel_x, p.vel_y).length() - p.speed) < 0.01, "velocity converges on the desired speed")
	sim.free()

func _test_knock_ahead_dribble() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	var owner: PlayerState = sim.owner_player()
	owner.facing_x = 1.0
	owner.facing_y = 0.0
	owner.vel_x = owner.speed * GameConfig.SPRINT_MULT
	for i in 60:
		sim._update_ball(1.0 / 60.0)
	_check(sim.ball.x - owner.x > 0.05, "a sprinting carrier pushes the ball ahead of the glue offset")
	owner.vel_x = 0.0
	for i in 60:
		sim._update_ball(1.0 / 60.0)
	_check(absf(sim.ball.x - owner.x - 0.035) < 0.005, "a standing carrier keeps the ball at the base offset")
	sim.free()

func _test_led_pass() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	var mate: PlayerState = sim.teams[0].players[9]
	mate.x = 0.3
	mate.y = 0.0
	mate.vel_x = 0.2
	var led := sim.lead_pass_point(Vector2.ZERO, mate)
	_check(led.x > mate.x + 0.02, "a pass leads a moving receiver in their running direction")
	mate.vel_x = 0.0
	var still := sim.lead_pass_point(Vector2.ZERO, mate)
	_check(still.is_equal_approx(Vector2(mate.x, mate.y)), "a stationary receiver is aimed at directly")
	sim.free()

func _test_switch_targets_predicted_ball() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	sim.restart_timer = 0.0
	sim._clear_owner()
	# Ball at the centre rolling hard toward a red player parked at +0.4; another
	# red stands nearer the ball's current spot. The candidate ring must pick the
	# interceptor at the predicted point, not the player nearest the ball now.
	sim.ball.x = 0.0
	sim.ball.y = 0.0
	sim.ball.vx = 0.8
	sim.ball.vy = 0.0
	sim.teams[0].players[9].x = 0.4
	sim.teams[0].players[9].y = 0.0
	sim.teams[0].players[5].x = 0.05
	sim.teams[0].players[5].y = 0.15
	sim.teams[0].selected_index = 1
	sim.teams[0].switch_candidate = -1
	sim._handle_user_selection(sim.teams[0])
	_check(sim.teams[0].switch_candidate == 9, "switch candidate is the interceptor of the rolling ball")
	sim.free()

## Online, a silent or reconnecting client's charge is cancelled (neither
## held nor just released): the carrier must not keep the stored power.
func _test_cancelled_charge_is_dropped() -> void:
	var sim := _make_sim()
	sim.reset_game(-1)   # red kicks off: red's selected player carries the ball
	sim.restart_timer = 0.0
	var ts := sim.teams[0]
	var carrier: PlayerState = sim.owner_player()
	for opp in sim.teams[1].players:   # nobody near enough to tackle
		opp.x = 0.85
		opp.start_x = 0.85
	var snap := InputSnapshot.new()
	snap.shoot_held = true
	ts.input = snap
	for i in 30:
		snap.shoot_prev = snap.shoot_held
		sim.step(1.0 / 60.0)
	var charged := carrier.kick_power
	snap.shoot_held = false
	snap.shoot_prev = false
	sim.step(1.0 / 60.0)
	_check(charged > 0.3 and carrier.kick_power == 0.0 and sim.ball.charging_power == 0.0 and sim.ball.owner_team == 0,
			"a cancelled charge is dropped without a kick (charged %.2f)" % charged)
	sim.free()

func _test_switch_ends() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	var gk_start: float = sim.teams[0].players[0].start_x
	var side_before: int = sim.teams[0].players[0].side
	sim.switch_ends()
	_check(sim.teams[0].players[0].start_x == -gk_start and sim.teams[0].players[0].side == -side_before, "switch_ends mirrors start positions and sides")
	sim.free()

func _test_actions_are_events() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	var cues: Array = []
	sim.player_action.connect(func(team: int, index: int, action: String, _d: float) -> void: cues.append([team, index, action]))
	var shooter: PlayerState = sim.teams[0].players[9]
	sim.kick_from_player(shooter, Vector2(GameConfig.FIELD_BOUNDARY_X, 0.0), 0.3, false)
	_check(cues.size() == 1 and cues[0] == [0, 9, "kick"], "a kick is announced as a player_action event for the kicker")
	_check(shooter.action_timer == 0.0, "the rules never touch animation state themselves")
	sim.free()

func _make_config() -> MatchConfig:
	var cfg := MatchConfig.new()
	cfg.half_length_s = 30.0
	cfg.formations[1] = 0
	cfg.kits[1] = {"shirt": 2, "shorts": 4, "boots": 5}
	cfg.team_difficulty[1] = 2
	cfg.offside_enabled = true
	cfg.weather = 1
	return cfg

func _test_config_round_trip() -> void:
	var cfg := _make_config()
	# Through JSON, as the lobby/runtime will carry it: ints come back as floats.
	var parsed = JSON.parse_string(JSON.stringify(cfg.to_dict()))
	var back := MatchConfig.from_dict(parsed)
	_check(back != null and back.to_dict() == cfg.to_dict(), "MatchConfig survives a JSON round trip")
	_check(back != null and back.ball_friction() == GameConfig.RAIN_BALL_FRICTION, "rain config yields the wet-ball friction")
	_check(back != null and back.ai_profile(1) == MatchConfig.DIFFICULTY_PROFILES[2], "per-team difficulty selects that team's AI profile")

func _test_config_rejects_invalid() -> void:
	var good := _make_config().to_dict()
	var bad_cases := {
		"half too short": {"half_length_s": 1.0},
		"unknown formation": {"formations": [0, 99]},
		"unknown difficulty": {"team_difficulty": [1, 7]},
		"bad kit": {"kits": [{"shirt": 0, "shorts": 4, "boots": 5}, {"shirt": -1, "shorts": 4, "boots": 5}]},
		"wrong version": {"version": 99},
		"mistyped toggle": {"fouls_enabled": "yes"},
	}
	var all_rejected := true
	for label in bad_cases:
		var d := good.duplicate(true)
		d.merge(bad_cases[label], true)
		if MatchConfig.from_dict(d) != null:
			all_rejected = false
			print("      accepted invalid config: %s" % label)
	var missing := good.duplicate(true)
	missing.erase("weather")
	_check(all_rejected and MatchConfig.from_dict(missing) == null, "invalid or incomplete configs are rejected")

## Snapshot of everything that moves, for comparing two runs.
func _session_fingerprint(session: MatchSession) -> Array:
	var out := [session.sim.score_left, session.sim.score_right, session.match_time,
			session.sim.ball.x, session.sim.ball.y, session.sim.ball.h, session.sim.ball.owner_team]
	for ts in session.sim.teams:
		for p in ts.players:
			out.append_array([p.x, p.y, p.stamina, p.kick_power])
	return out

func _run_ai_session(seed_value: int, ticks: int) -> Array:
	var session := MatchSession.new()
	session.set_team_device(0, GameConfig.DEVICE_AI)
	session.set_team_device(1, GameConfig.DEVICE_AI)
	session.initialize(_make_config(), seed_value)
	for i in ticks:
		session.step(1.0 / 60.0)
	var fp := _session_fingerprint(session)
	session.dispose()
	return fp

func _test_session_seed_reproducible() -> void:
	# 20 s of AI-vs-AI football exercises every random roll (jitter, runs,
	# tackles, shot picks). Same seed + same build => identical match.
	var a := _run_ai_session(1234, 1200)
	var b := _run_ai_session(1234, 1200)
	var c := _run_ai_session(98765, 1200)
	_check(a == b, "same seed and inputs replay the match identically")
	_check(a != c, "a different seed plays a different match")

func _test_session_halves_and_full_time() -> void:
	var session := MatchSession.new()
	session.set_team_device(0, GameConfig.DEVICE_AI)
	session.set_team_device(1, GameConfig.DEVICE_AI)
	session.initialize(_make_config(), 7)
	var red_gk_side: int = session.sim.teams[0].players[0].side
	var types: Array[String] = []
	var full_time: Dictionary = {}
	var half_tick := -1
	for i in 60 * 120:
		session.step(1.0 / 60.0)
		for ev in session.drain_events():
			types.append(ev.type)
			if ev.type == "half_time":
				half_tick = session.tick
				_check(session.phase == MatchSession.Phase.HALFTIME and session.current_half == 2, "half time pauses play and starts the second half")
				_check(session.sim.teams[0].players[0].side == -red_gk_side, "teams switch ends at half time")
			elif ev.type == "full_time":
				full_time = ev
		if session.is_over():
			break
	_check(half_tick > 0 and types.has("full_time"), "a match runs half time then full time")
	_check(full_time.get("score_left", -1) == session.sim.score_left and full_time.has("stats"), "full time reports the final score and stats")
	var frozen_tick := session.tick
	session.step(1.0 / 60.0)
	_check(session.tick == frozen_tick, "a finished session no longer advances")
	session.dispose()

func _test_session_slowmo_is_per_session() -> void:
	var a := MatchSession.new()
	var b := MatchSession.new()
	for s in [a, b]:
		s.set_team_device(0, GameConfig.DEVICE_AI)
		s.set_team_device(1, GameConfig.DEVICE_AI)
		s.initialize(_make_config(), 3)
		s.sim.restart_timer = 0.0
	# A special shot in session A only (as kick_from_player emits it).
	a.sim.special_fired.emit({"name": "Fire Tornado", "color": Color.RED, "team": 0})
	a.step(0.1)
	b.step(0.1)
	_check(a.time_scale == MatchSession.SLOWMO_SCALE and b.time_scale == 1.0, "slow motion stays inside the session that fired it")
	_check(absf(a.match_time - 0.1 * MatchSession.SLOWMO_SCALE) < 0.0001 and absf(b.match_time - 0.1) < 0.0001, "the slowed session's clock runs slower, applied once")
	_check(Engine.time_scale == 1.0, "the engine time scale is never touched")
	for i in 6:
		a.step(0.1)
	_check(a.time_scale == 1.0, "slow motion ends after its real-time duration")
	a.dispose()
	b.dispose()

func _test_session_restart_reinitializes() -> void:
	var session := MatchSession.new()
	session.initialize(_make_config(), 11)
	for i in 300:
		session.step(1.0 / 60.0)
	session.sim.score_left = 3
	var cfg := _make_config()
	cfg.weather = 0
	session.initialize(cfg, 11)
	_check(session.sim.score_left == 0 and session.match_time == 0.0 and session.tick == 0, "initialize resets score, clock and tick")
	_check(session.sim.ball.friction == GameConfig.BALL_FRICTION, "the new config's weather sets the ball friction")
	cfg.weather = 1
	_check(session.config.weather == 0, "editing the caller's config does not reach the running match")
	session.dispose()
