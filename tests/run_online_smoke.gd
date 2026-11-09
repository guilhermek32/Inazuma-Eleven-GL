extends SceneTree

## End-to-end smoke test of online play inside one process: a MatchRuntime and
## two full 3D game instances (scenes/main_3d.tscn) connected to it over
## loopback WebSockets, one per team. Checks that both games enter the match,
## mirror the runtime's state through interpolated snapshots, play the goal
## events, and finish on the runtime's match_over. The red game goes through
## the Play Online menu's creator path (waiting page until kickoff), and a
## pad press hands its team to that pad.
##
## Run: godot-4 --headless --path . --script res://tests/run_online_smoke.gd
## Exits 0 on success, 1 otherwise.

const PORT := 18911
const MATCH_ID := "smoke"

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(cond: bool, test_name: String) -> void:
	if cond:
		print("PASS  %s" % test_name)
	else:
		failures += 1
		print("FAIL  %s" % test_name)

func _frames_until(cond: Callable, max_frames: int) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await process_frame
	return cond.call()

func _run() -> void:
	var runtime := MatchRuntime.new()
	runtime.allow_dev_tokens = true
	runtime.dev_config.half_length_s = 60.0
	root.add_child(runtime)
	runtime.start(PORT, "127.0.0.1")
	var scene := load("res://scenes/main_3d.tscn") as PackedScene
	var games: Array = []
	for team in 2:
		var game: Node = scene.instantiate()
		root.add_child(game)
		games.append(game)
	await process_frame
	var url := "ws://127.0.0.1:%d/ws/game/%s" % [PORT, MATCH_ID]
	var red: Node = games[0]
	var blue: Node = games[1]
	# Red creates the room from the Play Online menu: it waits on the room-code
	# page, connected, until the opponent arrives and the runtime kicks off.
	red._set_game_state(GameConfig.GameState.ONLINE)
	red.menu.online.show_page("waiting")
	red.start_online_from_lobby(url, "dev:0", true)
	var red_welcomed := func() -> bool: return red.net != null and red.net.is_ready()
	_check(await _frames_until(red_welcomed, 600), "the creator connects from the waiting page")
	await _frames_until(func() -> bool: return false, 30)
	_check(red.game_state == GameConfig.GameState.ONLINE and red.menu.online.panel.visible and red.menu.online.page == "waiting",
			"the creator stays on the waiting page while alone in the room")
	blue.start_online(url, "dev:1")

	var joined := func() -> bool: return red.game_state == GameConfig.GameState.PLAYING and blue.game_state == GameConfig.GameState.PLAYING and red.net_team() == 0 and blue.net_team() == 1
	_check(await _frames_until(joined, 600), "both games join the online match on their own teams")
	var room: MatchRoom = runtime.room(MATCH_ID)
	var running := func() -> bool: return room != null and room.state == MatchRoom.State.RUNNING
	_check(await _frames_until(running, 300), "the runtime kicks off")

	# The last-used local device drives our team online: a pad, then the keyboard.
	var pad := InputEventJoypadButton.new()
	pad.device = 0
	pad.button_index = JOY_BUTTON_A
	pad.pressed = true
	red._input(pad)
	_check(red.sim.teams[0].device == 0, "a pad press hands the online team to that pad")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_D
	key.pressed = true
	red._input(key)
	_check(red.sim.teams[0].device == GameConfig.DEVICE_KBM and red.sim.teams[1].device == GameConfig.DEVICE_REMOTE,
			"a key press hands it back to keyboard+mouse; the opponent stays remote")

	# The mirrors follow the authoritative ball within interpolation lag: kick it
	# on the runtime and compare a moving ball.
	room.session.sim.restart_timer = 0.0
	await _frames_until(func() -> bool: return false, 30)
	var carrier: PlayerState = room.session.sim.owner_player()
	var kick_from := Vector2(room.session.sim.ball.x, room.session.sim.ball.y)
	room.session.sim.kick_from_player(carrier, kick_from + Vector2(0.0, 0.6), 0.4, false)
	await _frames_until(func() -> bool: return false, 20)
	var server_ball := Vector2(room.session.sim.ball.x, room.session.sim.ball.y)
	var mirror_ball := Vector2(red.sim.ball.x, red.sim.ball.y)
	var gap := mirror_ball.distance_to(server_ball)
	_check(mirror_ball.distance_to(kick_from) > 0.05 and gap < 0.15 and red.sim.teams[1].players.size() == 11,
			"the red game mirrors a moving ball within interpolation lag (moved %.3f, gap %.3f)" % [mirror_ball.distance_to(kick_from), gap])

	# A goal on the runtime reaches both games as score + celebration.
	var sim := room.session.sim
	sim._clear_owner()
	sim.ball.x = 0.9
	sim.ball.y = 0.0
	sim.ball.h = 0.0
	sim.ball.vx = 2.0
	sim.ball.vy = 0.0
	var both_scored := func() -> bool: return red.sim.score_left == 1 and blue.sim.score_left == 1
	_check(await _frames_until(both_scored, 600), "both games show the goal in the score")
	_check(red.view.celebration_timer > 0.0 and blue.view.celebration_timer > 0.0, "the goal event drove both celebrations")

	# Full time on the runtime ends both games.
	room.session.current_half = 2
	room.session.match_time = room.session.config.half_length_s - 0.05
	var both_over := func() -> bool: return red.game_state == GameConfig.GameState.FULLTIME and blue.game_state == GameConfig.GameState.FULLTIME
	_check(await _frames_until(both_over, 900), "full time on the runtime ends both games")
	_check(red.menu.fulltime_label.text.begins_with("FULL TIME") and red.menu.fulltime_label.text.contains("1 - 0"),
			"the full-time screen shows the runtime's result")
	_check(red.menu.new_online_button.visible and not red.menu.rematch_button.visible,
			"an online full time offers New Online Match, not an offline rematch")
	# The runtime then closes the finished room; the games drop back to offline.
	_check(await _frames_until(func() -> bool: return red.net == null and blue.net == null, 600), "the games leave online mode once the room closes")

	runtime.stop()
	print("ONLINE SMOKE PASSED" if failures == 0 else "ONLINE SMOKE FAILED (%d)" % failures)
	quit(1 if failures > 0 else 0)
