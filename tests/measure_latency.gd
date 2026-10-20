extends SceneTree

## Input-to-visible delay and traffic of a desktop client against a running
## stack (docs/measurements.md). Two full 3D games (headless, so frame time is
## not the bottleneck) get their seats through the real lobby with LobbyClient
## and play through the gateway; red runs the LatencyProbe while move presses
## (400 ms, alternating right/left, every 1.6 s) are injected, blue sends
## neutral input. Extra network delay is added outside, e.g. tc netem on the
## gateway namespace's loopback.
##
##   docker run --rm --network container:inazuma-online-gateway-1 -v "$PWD:/project" inazuma/godot:4.7.2 \
##     --headless --path /project --script res://tests/measure_latency.gd -- \
##     --lobby=http://localhost/api/lobby/v1 --presses=20 --label=baseline
##
## Prints one line "LATENCY {json}"; exits 1 if the match could not start.

func _initialize() -> void:
	_run.call_deferred()

func _wait_ms(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await process_frame

func _until(cond: Callable, max_ms: int) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < max_ms:
		if cond.call():
			return true
		await process_frame
	return cond.call()

func _fail(why: String) -> bool:
	print("LATENCY FAILED: %s" % why)
	quit(1)
	return false

func _run() -> void:
	var presses := int(LaunchArgs.value("presses")) if LaunchArgs.value("presses") != "" else 20
	var label := LaunchArgs.value("label")
	var lobby := LobbyClient.new()
	root.add_child(lobby)
	var created: Dictionary = await lobby.create_room("LatRed", 300)
	if not created.ok:
		return _fail("create: %s" % created.error)
	var joined: Dictionary = await lobby.join_room(created.body.room_code, "LatBlue")
	if not joined.ok:
		return _fail("join: %s" % joined.error)
	var scene := load("res://scenes/main_3d.tscn") as PackedScene
	var red: Node = scene.instantiate()
	var blue: Node = scene.instantiate()
	root.add_child(red)
	root.add_child(blue)
	await process_frame
	red._latency_probe = LatencyProbe.new()
	red.start_online_from_lobby(lobby.ws_url(created.body.ws_url), created.body.token, false)
	blue.start_online_from_lobby(lobby.ws_url(joined.body.ws_url), joined.body.token, false)
	var playing := func() -> bool: return red.game_state == GameConfig.GameState.PLAYING and blue.game_state == GameConfig.GameState.PLAYING \
			and not red._online_state.is_empty() and float(red._online_state.get("restart_timer", 1.0)) <= 0.0
	if not await _until(playing, 60000):
		return _fail("the match did not start")
	blue.session.set_team_device(1, GameConfig.DEVICE_AI)   # blue's local input stays neutral
	await _wait_ms(1000)
	var rx0: Dictionary = red.net.rx_stats.duplicate(true)
	var tx0: Dictionary = red.net.tx_stats.duplicate(true)
	var rtts: Array[float] = []
	var t0 := Time.get_ticks_msec()
	for i in presses:
		var action := "move_right" if i % 2 == 0 else "move_left"
		Input.action_press(action)
		await _wait_ms(400)
		Input.action_release(action)
		await _wait_ms(1200)
		if red.net != null and red.net.rtt_ms >= 0.0:
			rtts.append(red.net.rtt_ms)
	var elapsed := float(Time.get_ticks_msec() - t0) / 1000.0
	if red.net == null:
		return _fail("red lost its connection")
	var summary := {
		"label": label, "presses": presses, "window_s": snappedf(elapsed, 0.1),
		"input_to_visible_ms": _stats(red._latency_probe.samples_ms),
		"rtt_ms": _stats(rtts),
		"snapshot": _traffic(red.net.rx_stats, rx0, NetProtocol.Type.SNAPSHOT, elapsed),
		"event": _traffic(red.net.rx_stats, rx0, NetProtocol.Type.EVENT, elapsed),
		"input": _traffic(red.net.tx_stats, tx0, NetProtocol.Type.INPUT, elapsed),
	}
	print("LATENCY " + JSON.stringify(summary))
	red._set_game_state(GameConfig.GameState.MENU)
	blue._set_game_state(GameConfig.GameState.MENU)
	await _wait_ms(300)
	quit(0)

static func _stats(xs: Array) -> Dictionary:
	if xs.is_empty():
		return {"n": 0}
	var s := xs.duplicate()
	s.sort()
	var total := 0.0
	for x in s:
		total += x
	var q := func(p: float) -> float: return s[mini(s.size() - 1, int(p * s.size()))]
	return {"n": s.size(), "mean": snappedf(total / s.size(), 0.1), "p50": snappedf(q.call(0.5), 0.1),
			"p95": snappedf(q.call(0.95), 0.1), "min": snappedf(s[0], 0.1), "max": snappedf(s[-1], 0.1)}

static func _traffic(now: Dictionary, before: Dictionary, type: int, elapsed: float) -> Dictionary:
	var a: Dictionary = now.get(type, {"count": 0, "bytes": 0})
	var b: Dictionary = before.get(type, {"count": 0, "bytes": 0})
	var count: int = a.count - b.count
	var bytes: int = a.bytes - b.bytes
	return {"per_s": snappedf(count / elapsed, 0.1), "avg_bytes": snappedf(float(bytes) / maxf(1.0, count), 0.1),
			"bytes_per_s": roundi(bytes / elapsed)}
