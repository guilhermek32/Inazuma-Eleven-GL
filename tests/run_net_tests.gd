extends SceneTree

## Headless network tests. Unit sections cover the wire protocol, the
## server-side input queue and the client interpolation buffer; integration
## sections run the match runtime and real NetClient/WebSocketPeer clients
## inside one process over loopback.
##
## Run: godot-4 --headless --path . --script res://tests/run_net_tests.gd
## Exits 0 when every check passes, 1 otherwise.

const PORT := 18910

var failures := 0
var runtime: MatchRuntime

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_test_bootstrap_dispatch()
	_test_match_id_parsing()
	_test_protocol_round_trips()
	_test_protocol_rejects_malformed()
	_test_input_queue()
	_test_snapshot_buffer()
	runtime = MatchRuntime.new()
	runtime.allow_dev_tokens = true
	runtime.dev_config.half_length_s = 60.0
	root.add_child(runtime)
	_check(runtime.start(PORT, "127.0.0.1") == OK, "runtime listens on loopback")
	await _test_probe_round_trip()
	await _test_bad_path_rejected()
	await _test_bad_message_closes()
	await _test_hello_rules()
	await _test_online_match()
	await _test_forfeit()
	await _test_per_team_grace()
	await _test_pending_connection_cap()
	runtime.stop()
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

# --- helpers ---------------------------------------------------------------------

func _url(path: String) -> String:
	return "ws://127.0.0.1:%d%s" % [PORT, path]

## Polls a raw client until it reaches `state` (the runtime polls itself each physics frame).
func _await_state(client: WebSocketPeer, state: int, max_frames := 300) -> bool:
	for i in max_frames:
		client.poll()
		if client.get_ready_state() == state:
			return true
		await physics_frame
	return false

func _await_text(client: WebSocketPeer, max_frames := 300) -> String:
	for i in max_frames:
		client.poll()
		if client.get_available_packet_count() > 0:
			return client.get_packet().get_string_from_utf8()
		if client.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			return ""
		await physics_frame
	return ""

## Advances `frames` physics frames, polling every NetClient each frame and
## calling `each_frame` (if given) before the frame.
func _pump(clients: Array, frames: int, each_frame := Callable()) -> void:
	for i in frames:
		if each_frame.is_valid():
			each_frame.call(i)
		await physics_frame
		for c in clients:
			(c as NetClient).poll()

## Pumps until `cond` is true or `max_frames` pass; returns whether it became true.
func _pump_until(clients: Array, cond: Callable, max_frames := 600) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await physics_frame
		for c in clients:
			(c as NetClient).poll()
	return cond.call()

func _client(match_id: String, token: String) -> Array:
	var c := NetClient.new()
	var events: Array = []
	c.event_received.connect(func(_tick: int, ev: Dictionary) -> void: events.append(ev))
	c.connect_to(_url("/ws/game/" + match_id), token)
	return [c, events]

static func _has_event(events: Array, type: String) -> bool:
	for ev in events:
		if ev.type == type:
			return true
	return false

static func _find_event(events: Array, type: String) -> Dictionary:
	for ev in events:
		if ev.type == type:
			return ev
	return {}

# --- unit: bootstrap / paths ---------------------------------------------------------

func _test_bootstrap_dispatch() -> void:
	var boot := preload("res://scripts/bootstrap.gd")
	_check(boot.choose_scene(PackedStringArray(), false, "") == boot.GAME_SCENE, "no flags boots the 3D game")
	_check(boot.choose_scene(PackedStringArray(["--server"]), false, "") == boot.SERVER_SCENE, "--server boots the match runtime")
	_check(boot.choose_scene(PackedStringArray(), true, "") == boot.SERVER_SCENE, "a dedicated-server export boots the match runtime")
	_check(boot.choose_scene(PackedStringArray(["--bot"]), true, "") == boot.BOT_SCENE, "--bot wins over the dedicated-server feature")
	_check(boot.choose_scene(PackedStringArray(), false, "?netprobe") == boot.NET_PROBE_SCENE, "?netprobe opens the connectivity probe")

func _test_match_id_parsing() -> void:
	_check(MatchRuntime.match_id_from_url("ws://h:1/ws/game/abc-123") == "abc-123", "match id parsed from the URL path")
	_check(MatchRuntime.match_id_from_url("/ws/game/abc?x=1") == "abc", "query string ignored")
	var rejected := ["ws://h/ws/game/", "ws://h/other/abc", "ws://h/ws/game/a/b", "ws://h/ws/game/%2e%2e", "ws://h/ws/game/" + "x".repeat(65)]
	var all_rejected := true
	for url in rejected:
		if MatchRuntime.match_id_from_url(url) != "":
			all_rejected = false
	_check(all_rejected, "malformed or foreign paths are rejected")

# --- unit: protocol --------------------------------------------------------------------

func _test_protocol_round_trips() -> void:
	var hello := NetProtocol.decode(NetProtocol.encode_hello("dev:1"))
	_check(hello.get("type") == NetProtocol.Type.HELLO and hello.token == "dev:1", "HELLO round trip")

	var cfg := MatchConfig.new()
	cfg.half_length_s = 300.0
	cfg.team_difficulty[1] = 2
	var welcome := NetProtocol.decode(NetProtocol.encode_welcome("m-1", 1, 7, 60, 2, 3, cfg))
	_check(welcome.get("team") == 1 and welcome.epoch == 7 and welcome.config.to_dict() == cfg.to_dict(), "WELCOME round trip carries the MatchConfig")

	var frame := {"epoch": 3, "seq": 99, "axis": Vector2(0.6, -0.8), "sprint": true, "shoot": false,
			"aim_mode": NetProtocol.AIM_POINT, "aim": Vector2(0.9, -0.1),
			"actions": [{"id": 41, "kind": NetProtocol.Action.PASS, "aim_mode": NetProtocol.AIM_NONE, "aim": Vector2.ZERO},
					{"id": 42, "kind": NetProtocol.Action.SHOOT_RELEASE, "aim_mode": NetProtocol.AIM_DIR, "aim": Vector2(0.0, 1.0)}]}
	var inp := NetProtocol.decode(NetProtocol.encode_input(frame))
	_check(inp.get("seq") == 99 and inp.epoch == 3 and inp.sprint and not inp.shoot
			and inp.axis.distance_to(Vector2(0.6, -0.8)) < 0.02 and inp.aim.distance_to(Vector2(0.9, -0.1)) < 0.001
			and inp.actions.size() == 2 and inp.actions[1].id == 42 and inp.actions[1].kind == NetProtocol.Action.SHOOT_RELEASE
			and inp.actions[1].aim.distance_to(Vector2(0.0, 1.0)) < 0.001, "INPUT round trip keeps actions and their aims")

	# A snapshot of a real, played-out session.
	var session := MatchSession.new()
	session.set_team_device(0, GameConfig.DEVICE_AI)
	session.set_team_device(1, GameConfig.DEVICE_AI)
	session.initialize(MatchConfig.new(), 5)
	for i in 400:
		session.step(1.0 / 60.0)
	var bytes := NetProtocol.encode_snapshot(NetProtocol.snapshot_from_session(session, 1234, 9, NetProtocol.SNAP_DISCONTINUITY, 77, MatchRoom.State.RUNNING))
	var snap := NetProtocol.decode(bytes)
	var max_err := 0.0
	for t in 2:
		for i in session.sim.teams[t].players.size():
			var p: PlayerState = session.sim.teams[t].players[i]
			var q: Dictionary = snap.teams[t].players[i]
			max_err = maxf(max_err, maxf(absf(p.x - q.x), absf(p.y - q.y)))
	_check(snap.get("tick") == 1234 and snap.state_epoch == 9 and snap.ack_seq == 77 and snap.flags == NetProtocol.SNAP_DISCONTINUITY,
			"SNAPSHOT header round trip")
	_check(max_err <= 1.0 / NetProtocol.POS_SCALE and absf(snap.ball.x - session.sim.ball.x) <= 1.0 / NetProtocol.POS_SCALE
			and snap.ball.owner_team == session.sim.ball.owner_team and snap.score_left == session.sim.score_left,
			"SNAPSHOT positions survive quantization (error %.6f)" % max_err)
	print("      snapshot size: %d bytes (22 players)" % bytes.size())
	_check(bytes.size() < 600, "a full snapshot stays under 600 bytes")
	session.dispose()

	var goal := NetProtocol.decode(NetProtocol.encode_event(50, 3, {"type": "goal", "tick": 49, "scorer": -1, "goal_side": 1, "impact": Vector3(0.95, 0.1, 0.4)}))
	_check(goal.get("tick") == 50 and goal.event.type == "goal" and goal.event.scorer == -1 and typeof(goal.event.scorer) == TYPE_INT
			and goal.event.impact is Vector3 and goal.event.impact.distance_to(Vector3(0.95, 0.1, 0.4)) < 0.0001, "EVENT round trip restores ints and vectors")
	var special := NetProtocol.decode(NetProtocol.encode_event(1, 1, {"type": "special", "name": "FIRE TORNADO", "color": Color(1.0, 0.45, 0.08), "team": 0}))
	var col: Color = special.event.color if special.event.color is Color else Color.BLACK
	var col_err := maxf(absf(col.r - 1.0), maxf(absf(col.g - 0.45), absf(col.b - 0.08)))
	_check(special.event.color is Color and col_err <= 1.0 / 255.0, "EVENT round trip restores colours (8-bit hex)")

func _test_protocol_rejects_malformed() -> void:
	var good := NetProtocol.encode_input({"epoch": 1, "seq": 1, "axis": Vector2.ZERO, "sprint": false, "shoot": false,
			"aim_mode": NetProtocol.AIM_NONE, "aim": Vector2.ZERO, "actions": []})
	var cases := {}
	cases["truncated"] = good.slice(0, good.size() - 1)
	var wrong_version := good.duplicate()
	wrong_version[0] = 9
	cases["wrong version"] = wrong_version
	var trailing := good.duplicate()
	trailing.append(0)
	cases["trailing byte"] = trailing
	var unknown := good.duplicate()
	unknown[1] = 200
	cases["unknown type"] = unknown
	var too_many := good.duplicate()
	too_many[too_many.size() - 1] = NetProtocol.MAX_ACTIONS + 1
	cases["too many actions"] = too_many
	cases["empty"] = PackedByteArray()
	var bad_ping := NetProtocol.encode_ping(1.0)
	bad_ping.encode_double(2, NAN)
	cases["NaN float"] = bad_ping
	var all_rejected := true
	for label in cases:
		if not NetProtocol.decode(cases[label]).is_empty():
			all_rejected = false
			print("      accepted malformed message: %s" % label)
	_check(all_rejected, "malformed messages are rejected")

# --- unit: input queue -----------------------------------------------------------------

func _frame(seq: int, actions: Array, axis := Vector2.ZERO, epoch := 1) -> Dictionary:
	return {"epoch": epoch, "seq": seq, "axis": axis, "sprint": false, "shoot": false,
			"aim_mode": NetProtocol.AIM_NONE, "aim": Vector2.ZERO, "actions": actions}

func _act(id: int, kind: int, aim := Vector2.ZERO) -> Dictionary:
	return {"id": id, "kind": kind, "aim_mode": NetProtocol.AIM_POINT if aim != Vector2.ZERO else NetProtocol.AIM_NONE, "aim": aim}

func _test_input_queue() -> void:
	var q := RemoteInputQueue.new()
	q.reset(1)
	var snap := InputSnapshot.new()
	# The same pass resent in a later frame (and the same frame replayed) applies once.
	q.push(_frame(1, [_act(1, NetProtocol.Action.PASS)]), 0)
	q.push(_frame(1, [_act(1, NetProtocol.Action.PASS)]), 0)
	q.push(_frame(2, [_act(1, NetProtocol.Action.PASS)]), 0)
	var passes := 0
	for t in 5:
		q.apply(snap, t)
		passes += 1 if snap.pass_pressed else 0
	_check(passes == 1, "a duplicated action applies exactly once")

	# Two passes and a tackle in one frame: one pass per tick, strict id order.
	q.push(_frame(3, [_act(2, NetProtocol.Action.PASS), _act(3, NetProtocol.Action.PASS), _act(4, NetProtocol.Action.TACKLE)]), 5)
	q.apply(snap, 5)
	var first := [snap.pass_pressed, snap.tackle_pressed]
	q.apply(snap, 6)
	var second := [snap.pass_pressed, snap.tackle_pressed]
	_check(first == [true, false] and second == [true, true], "same-kind actions spread over ticks without reordering")

	# Start + release in one frame: held for exactly one tick, then released with the action's aim.
	var aim := Vector2(0.9, 0.2)
	q.push(_frame(4, [_act(5, NetProtocol.Action.SHOOT_START), _act(6, NetProtocol.Action.SHOOT_RELEASE, aim)]), 10)
	q.apply(snap, 10)
	var tick1 := [snap.shoot_held, snap.shoot_prev]
	q.apply(snap, 11)
	var tick2 := [snap.shoot_held, snap.shoot_prev]
	_check(tick1 == [true, false] and tick2 == [false, true] and snap.aim_absolute and snap.aim_vec.distance_to(aim) < 0.001,
			"a tap shot charges one tick and kicks toward its own aim")

	# Silence: held movement goes neutral and a charge is cancelled without a kick.
	q.push(_frame(5, [_act(7, NetProtocol.Action.SHOOT_START)], Vector2(1.0, 0.0)), 20)
	q.apply(snap, 20)
	var moving := snap.axis == Vector2(1.0, 0.0) and snap.shoot_held
	var kicked := false
	for t in range(21, 21 + RemoteInputQueue.SILENCE_TICKS + 3):
		q.apply(snap, t)
		if snap.shoot_prev and not snap.shoot_held:
			kicked = true
	_check(moving and snap.axis == Vector2.ZERO and not snap.shoot_held and not kicked, "silence neutralizes input and cancels a charge without kicking")

	# Old epoch and stale seq are ignored; stale actions expire.
	_check(not q.push(_frame(6, [], Vector2.ZERO, 0), 40), "a frame from an older connection epoch is ignored")
	_check(not q.push(_frame(5, []), 40), "a frame with an old seq is ignored")
	q.push(_frame(7, [_act(8, NetProtocol.Action.PASS), _act(9, NetProtocol.Action.PASS)]), 50)
	q.apply(snap, 50)
	q.apply(snap, 50 + RemoteInputQueue.MAX_ACTION_AGE_TICKS + 1)
	_check(not snap.pass_pressed and q.pending_count() == 0, "actions queued too long are dropped as stale")

	# Reset (reconnect) clears everything and restarts action ids.
	q.reset(2)
	q.push(_frame(1, [_act(1, NetProtocol.Action.TACKLE)], Vector2.ZERO, 2), 60)
	q.apply(snap, 60)
	_check(snap.tackle_pressed, "after a reconnect the new connection's actions apply")

# --- unit: snapshot buffer -----------------------------------------------------------------

func _snap(tick: int, epoch: int, x: float) -> Dictionary:
	var players := []
	for i in 11:
		players.append({"x": x, "y": 0.0, "vx": 0.0, "vy": 0.0, "fx": 1.0, "fy": 0.0, "flags": 0,
				"kick_power": 0.0, "stamina": 1.0, "dive_timer": 0.0, "dive_dir": 0})
	var team := {"selected": 0, "candidate": -1, "players": players}
	return {"tick": tick, "state_epoch": epoch, "flags": 0, "ack_seq": 0, "room_state": 1, "phase": 0, "half": 1,
			"match_time": tick / 60.0, "score_left": 0, "score_right": 0, "restart_type": 0, "restart_timer": 0.0,
			"time_scale": 1.0, "ball": {"x": x, "y": 0.0, "h": 0.0, "vx": 0.0, "vy": 0.0, "spin": 0.0,
			"owner_team": -1, "owner_index": -1, "charge": 0.0, "special": -1, "super": false}, "teams": [team, team.duplicate(true)]}

func _test_snapshot_buffer() -> void:
	var buf := SnapshotBuffer.new()
	# Snapshots every 2 ticks arriving exactly on time (tick t at t/60 s).
	for tick in range(0, 40, 2):
		buf.push_snapshot(_snap(tick, 0, tick * 0.01), tick * 1000.0 / 60.0)
	# At 31 ticks of local time the render tick is 31 - 6 = 25 -> between 24 and 26.
	var s := buf.sample(31 * 1000.0 / 60.0)
	_check(s.a.tick == 24 and s.b.tick == 26 and absf(s.t - 0.5) < 0.01, "render time sits delay_ticks behind and brackets two snapshots")
	var mirror := MatchSimulation.new()
	mirror.create_teams()
	var hud := SnapshotBuffer.apply_to(mirror, s.a, s.b, s.t)
	_check(absf(mirror.ball.x - 0.25) < 0.0001 and absf(mirror.teams[1].players[3].x - 0.25) < 0.0001, "continuous fields are interpolated")
	_check(hud.has("match_time") and hud.room_state == 1, "the HUD state comes back with the sample")
	mirror.free()

	var jump := SnapshotBuffer.new()
	jump.push_snapshot(_snap(0, 0, 0.0), 0.0)
	jump.push_snapshot(_snap(2, 1, 0.8), 2000.0 / 60.0)   # reset in between: new state epoch
	jump.push_snapshot(_snap(4, 1, 0.8), 4000.0 / 60.0)
	var mid := jump.sample(7 * 1000.0 / 60.0)   # render tick 1: between the epochs
	_check(mid.a.tick == 0 and mid.b.tick == 0 and mid.t == 0.0, "snapshots across a reset are not blended")

	jump.push_event(3, {"type": "goal"})
	var early := jump.take_due_events(7 * 1000.0 / 60.0)   # render tick 1
	var later := jump.take_due_events(9 * 1000.0 / 60.0)   # render tick 3
	_check(early.is_empty() and later.size() == 1, "events are released when render time reaches them")

# --- integration ----------------------------------------------------------------------------

func _test_probe_round_trip() -> void:
	var client := WebSocketPeer.new()
	client.connect_to_url(_url("/ws/game/probe"))
	_check(await _await_state(client, WebSocketPeer.STATE_OPEN), "client completes the WebSocket handshake")
	client.send_text("ping")
	_check(await _await_text(client) == "pong", "runtime answers the probe")
	client.close()
	await _await_state(client, WebSocketPeer.STATE_CLOSED)
	for i in 30:
		await physics_frame
	_check(runtime.connection_count() == 0, "closed connections are released")

func _test_bad_path_rejected() -> void:
	var client := WebSocketPeer.new()
	client.connect_to_url(_url("/elsewhere"))
	await _await_state(client, WebSocketPeer.STATE_CLOSED)
	_check(client.get_close_code() == NetProtocol.CLOSE_BAD_PATH, "a connection outside /ws/game/<id> is closed with 4404")

func _test_bad_message_closes() -> void:
	var client := WebSocketPeer.new()
	client.connect_to_url(_url("/ws/game/probe"))
	await _await_state(client, WebSocketPeer.STATE_OPEN)
	client.send_text("not a protocol message")
	await _await_state(client, WebSocketPeer.STATE_CLOSED)
	_check(client.get_close_code() == NetProtocol.CLOSE_BAD_MESSAGE, "an unexpected message closes the connection with 4400")

func _test_hello_rules() -> void:
	var bad := WebSocketPeer.new()
	bad.connect_to_url(_url("/ws/game/rules"))
	await _await_state(bad, WebSocketPeer.STATE_OPEN)
	bad.send(NetProtocol.encode_hello("dev:7"))
	await _await_state(bad, WebSocketPeer.STATE_CLOSED)
	_check(bad.get_close_code() == NetProtocol.CLOSE_UNAUTHORIZED, "an invalid token is refused with 4401")
	_check(runtime.room("rules") == null, "a refused HELLO creates no room")

	var early := WebSocketPeer.new()
	early.connect_to_url(_url("/ws/game/rules"))
	await _await_state(early, WebSocketPeer.STATE_OPEN)
	early.send(NetProtocol.encode_ping(1.0))
	await _await_state(early, WebSocketPeer.STATE_CLOSED)
	_check(early.get_close_code() == NetProtocol.CLOSE_BAD_MESSAGE, "anything before HELLO is refused")

func _test_online_match() -> void:
	var a := _client("m1", "dev:0")
	var b := _client("m1", "dev:1")
	var c0: NetClient = a[0]
	var c1: NetClient = b[0]
	var ev0: Array = a[1]
	var ev1: Array = b[1]
	var clients := [c0, c1]
	_check(await _pump_until(clients, func() -> bool: return c0.is_ready() and c1.is_ready()), "both players receive WELCOME")
	_check(c0.team == 0 and c1.team == 1 and c0.config.half_length_s == 60.0, "WELCOME assigns the token's team and the match config")
	_check(await _pump_until(clients, func() -> bool: return _has_event(ev0, "kickoff") and _has_event(ev1, "kickoff")), "the match kicks off once both are connected")

	var room := runtime.room("m1")
	var sim := room.session.sim
	sim.restart_timer = 0.0   # skip the kickoff freeze
	# Blue kicked off, so blue's selected player is the ball carrier.
	var blue := sim.teams[1].players[sim.teams[1].selected_index]
	var blue_start := Vector2(blue.x, blue.y)
	var red := sim.teams[0].players[sim.teams[0].selected_index]
	var red_start_x := red.x
	var snaps_before := c0.buffer.size()
	var first_tick := int(c0.latest_snapshot.get("tick", 0))
	await _pump(clients, 30, func(_i: int) -> void:
		c0.send_frame(Vector2(1.0, 0.0), false, false, NetProtocol.AIM_NONE, Vector2.ZERO, []))
	_check(red.x - red_start_x > 0.03, "red's input moves red's selected player")
	_check(Vector2(blue.x, blue.y).distance_to(blue_start) < 0.002, "red's input never moves the blue player")
	var ticks := int(c0.latest_snapshot.tick) - first_tick
	_check(ticks > 0 and c0.buffer.size() > snaps_before, "snapshots keep arriving with increasing ticks (%d ticks)" % ticks)
	_check(int(c0.latest_snapshot.ack_seq) >= 25, "snapshots acknowledge the client's input sequence")

	# Silence: no more frames -> red stops within the silence window.
	await _pump(clients, RemoteInputQueue.SILENCE_TICKS + 30)
	var still_x := red.x
	await _pump(clients, 10)
	_check(absf(red.x - still_x) < 0.001 and Vector2(red.vel_x, red.vel_y).length() < 0.01, "a silent client's player comes to rest")

	# A goal: the event reaches both clients, and the kickoff after the
	# celebration arrives as a new state epoch flagged as a discontinuity.
	var epoch_before := int(c0.latest_snapshot.state_epoch)
	sim._clear_owner()
	sim.ball.x = 0.9
	sim.ball.y = 0.0
	sim.ball.h = 0.0
	sim.ball.vx = 2.0
	sim.ball.vy = 0.0
	_check(await _pump_until(clients, func() -> bool: return _has_event(ev0, "goal") and _has_event(ev1, "goal")), "a goal is broadcast to both players")
	var goal := _find_event(ev0, "goal")
	_check(goal.get("scorer") == -1 and goal.impact is Vector3, "the goal event names the scorer and the impact point")
	var saw_discontinuity := [false]
	var check_flag := func() -> bool:
		var s: Dictionary = c0.latest_snapshot
		if int(s.state_epoch) > epoch_before and int(s.flags) & NetProtocol.SNAP_DISCONTINUITY:
			saw_discontinuity[0] = true
		return saw_discontinuity[0]
	_check(await _pump_until(clients, check_flag, 400), "the post-goal kickoff arrives as a discontinuity in a new state epoch")
	_check(c0.latest_snapshot.score_left == 1, "snapshots carry the new score")

	# Reconnect: a second connection for red replaces the first.
	var a2 := _client("m1", "dev:0")
	var c0b: NetClient = a2[0]
	_check(await _pump_until([c0, c0b, c1], func() -> bool: return c0b.is_ready() and c0.status == NetClient.Status.CLOSED),
			"a newer connection for the same team takes over")
	_check(c0.close_code == NetProtocol.CLOSE_REPLACED and c0b.epoch == c0.epoch + 1, "the old connection is closed as replaced and the epoch advances")

	# Disconnect pauses the match for the other player; reconnecting resumes it.
	c0b.close()
	_check(await _pump_until([c0b, c1], func() -> bool: return _has_event(ev1, "paused")), "a disconnect pauses the match for the opponent")
	var paused_tick := room.session.tick
	await _pump([c1], 20)
	_check(room.session.tick == paused_tick and room.state == MatchRoom.State.PAUSED, "the match clock is frozen while paused")
	var a3 := _client("m1", "dev:0")
	var c0c: NetClient = a3[0]
	_check(await _pump_until([c0c, c1], func() -> bool: return c0c.is_ready() and _has_event(ev1, "resumed")), "reconnecting resumes the match")
	# WELCOME clears the buffer, so its first entry is the baseline sent on attach.
	_check(c0c.buffer.size() > 0 and int(c0c.buffer._snaps[0].flags) & NetProtocol.SNAP_DISCONTINUITY,
			"the reconnecting player gets a full baseline snapshot")
	c0c.close()
	c1.close()
	await _pump([c0c, c1], 10)

func _test_forfeit() -> void:
	var a := _client("m2", "dev:0")
	var b := _client("m2", "dev:1")
	var c0: NetClient = a[0]
	var c1: NetClient = b[0]
	var ev0: Array = a[1]
	await _pump_until([c0, c1], func() -> bool: return _has_event(ev0, "kickoff"))
	runtime.room("m2").reconnect_grace_ms = 300
	c1.close()
	_check(await _pump_until([c0, c1], func() -> bool: return _has_event(ev0, "match_over")), "a player who doesn't return in time forfeits")
	var over := _find_event(ev0, "match_over")
	_check(over.get("reason") == "forfeit" and over.get("winner") == 0, "the forfeit names the remaining player as winner")
	_check(await _pump_until([c0], func() -> bool: return c0.status == NetClient.Status.CLOSED, 300)
			and c0.close_code == NetProtocol.CLOSE_MATCH_OVER and runtime.room("m2") == null,
			"the finished room is closed and freed")

## Each absent team gets its own reconnect deadline: red drops, blue drops later,
## red returns; blue must keep its full grace (not red's leftover).
func _test_per_team_grace() -> void:
	var a := _client("m3", "dev:0")
	var b := _client("m3", "dev:1")
	var c0: NetClient = a[0]
	var c1: NetClient = b[0]
	var ev0: Array = a[1]
	await _pump_until([c0, c1], func() -> bool: return _has_event(ev0, "kickoff"))
	var room := runtime.room("m3")
	room.reconnect_grace_ms = 1500
	var t0 := Time.get_ticks_msec()
	c0.close()
	await _pump_until([c0, c1], func() -> bool: return Time.get_ticks_msec() - t0 > 700, 600)
	c1.close()
	await _pump_until([c0, c1], func() -> bool: return Time.get_ticks_msec() - t0 > 900, 600)
	var back := _client("m3", "dev:0")
	var c0b: NetClient = back[0]
	var ev0b: Array = back[1]
	await _pump_until([c0b], func() -> bool: return c0b.is_ready(), 600)
	# Red's own deadline (t0 + 1.5 s) passes while blue is still inside its grace.
	await _pump_until([c0b], func() -> bool: return Time.get_ticks_msec() - t0 > 1900, 600)
	_check(room.state == MatchRoom.State.PAUSED, "a second absence gets its own grace, not the first one's leftover")
	_check(await _pump_until([c0b], func() -> bool: return _has_event(ev0b, "match_over"), 600)
			and _find_event(ev0b, "match_over").get("winner") == 0, "the team still away past its own deadline forfeits")
	c0b.close()
	await _pump([c0b], 10)

## Connections that never send HELLO are capped, so they can't take every slot.
func _test_pending_connection_cap() -> void:
	var idle: Array[WebSocketPeer] = []
	for i in MatchRuntime.MAX_PENDING_PEERS + 4:
		var ws := WebSocketPeer.new()
		ws.connect_to_url(_url("/ws/game/idle"))
		idle.append(ws)
	for i in 60:
		for ws in idle:
			ws.poll()
		await physics_frame
	var held := runtime.connection_count()
	_check(held > 0 and held <= MatchRuntime.MAX_PENDING_PEERS,
			"the runtime holds at most %d connections that haven't sent HELLO (%d)" % [MatchRuntime.MAX_PENDING_PEERS, held])
	var a := _client("m4", "dev:0")
	for ws in idle:
		ws.close()
	await _pump([], 20)
	var c0: NetClient = a[0]
	_check(await _pump_until([c0], func() -> bool: return c0.is_ready(), 600), "a real player still gets in once idle sockets go away")
	c0.close()
	await _pump([c0], 10)
