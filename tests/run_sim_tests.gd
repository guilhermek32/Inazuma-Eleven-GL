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
	# Blue's kickoff taker owns the ball at the centre; park a red attacker on
	# top of them. Without a live tackle window no steal happens; with one the
	# red player wins the ball and the old carrier is stunned.
	var carrier: PlayerState = sim.owner_player()
	var red_att: PlayerState = sim.teams[0].players[9]
	red_att.x = sim.ball.x + 0.02
	red_att.y = sim.ball.y
	sim._resolve_ball_capture()
	_check(sim.ball.owner_team == 1, "contact alone no longer steals the ball")
	red_att.tackle_timer = GameConfig.TACKLE_WINDOW
	sim._resolve_ball_capture()
	_check(sim.ball.owner_team == 0 and sim.ball.owner_index == 9, "a live tackle window wins the steal")
	_check(carrier.stun_timer > 0.0, "the dispossessed carrier is stunned")
	_check(red_att.tackle_timer == 0.0, "winning consumes the tackle window")
	sim.free()

func _test_switch_ends() -> void:
	var sim := _make_sim()
	sim.reset_game(1)
	var gk_start: float = sim.teams[0].players[0].start_x
	var side_before: int = sim.teams[0].players[0].side
	sim.switch_ends()
	_check(sim.teams[0].players[0].start_x == -gk_start and sim.teams[0].players[0].side == -side_before, "switch_ends mirrors start positions and sides")
	sim.free()
