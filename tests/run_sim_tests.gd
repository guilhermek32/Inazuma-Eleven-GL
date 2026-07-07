extends SceneTree

## Headless gameplay-logic tests for MatchSimulation. The sim runs without any
## 3D representation (player_factory/players_root stay null), so these exercise
## pure game state: kickoff possession, goal detection, boundary clamps, the
## nearest-player capture rule and end switching.
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
	_test_restart_clears_space()
	_test_restart_shield_blocks_steal()
	_test_restart_shield_expires()
	_test_movement_momentum()
	_test_knock_ahead_dribble()
	_test_led_pass()
	_test_switch_targets_predicted_ball()
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
	sim.settings = SettingsStore.new()
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
	sim.settings.fouls_enabled = false
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
	sim.settings.offside_enabled = true
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
	sim.settings.offside_enabled = true
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
	sim.settings.offside_enabled = false
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
	sim.ai.update_ai_player(keeper, sim.teams[1].players, sim.teams[0].players, 1, 0, 0.3, false)
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

func _test_switch_ends() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	var gk_start: float = sim.teams[0].players[0].start_x
	var side_before: int = sim.teams[0].players[0].side
	sim.switch_ends()
	_check(sim.teams[0].players[0].start_x == -gk_start and sim.teams[0].players[0].side == -side_before, "switch_ends mirrors start positions and sides")
	sim.free()
