extends SceneTree

## Headless tests of the online AI bot (Milestone 5): BotBrain's input policy
## against hand-built observations, BotSession's snapshot observation, the
## ai-bot job API (auth, validation, idempotency, join deadline, capacity) and
## a loopback match in which a BotSession plays a provisioned, credentialed
## match against a scripted client to full time.
##
## Run: godot-4 --headless --path . --script res://tests/run_bot_tests.gd
## Exits 0 when every check passes, 1 otherwise.

const WS_PORT := 18930
const BOT_PORT := 18931
const DEAD_PORT := 18939   # nothing listens here
const BOT_TOKEN := "test-bot-token"
const SECRET := "bot-test-secret"
const DATA_DIR := "user://bot_tests"

var failures := 0
var runtime: MatchRuntime
var bots: BotService
var _clients: Array = []

func _initialize() -> void:
	_run.call_deferred()

func _check(cond: bool, test_name: String) -> void:
	if cond:
		print("PASS  %s" % test_name)
	else:
		failures += 1
		print("FAIL  %s" % test_name)

func _run() -> void:
	_test_brain_chases_loose_ball()
	_test_brain_shoots_in_range()
	_test_brain_passes_under_pressure()
	_test_brain_tackles_nearby_carrier()
	_test_brain_switches_when_defending()
	_test_brain_idle_outside_play()
	_test_brain_sprint_rule()
	_test_difficulty_profiles()
	_test_observation_switches_ends()
	runtime = MatchRuntime.new()
	runtime.match_secret = SECRET.to_utf8_buffer()
	runtime.open_storage(DATA_DIR)
	root.add_child(runtime)
	_check(runtime.start(WS_PORT, "127.0.0.1") == OK, "runtime listens on loopback")
	bots = BotService.new()
	bots.log_decisions = false
	root.add_child(bots)
	_check(bots.start_control(BOT_PORT, "127.0.0.1", BOT_TOKEN) == OK, "bot job API listens on loopback")
	await _test_job_api_auth_and_validation()
	await _test_job_idempotency_and_stop()
	await _test_join_deadline_and_refusal()
	await _test_capacity()
	await _test_loopback_match()
	bots.stop()
	runtime.stop()
	_wipe(DATA_DIR)
	print("ALL TESTS PASSED" if failures == 0 else "%d TEST(S) FAILED" % failures)
	quit(1 if failures > 0 else 0)

# --- observation fixtures ---------------------------------------------------------

## A fresh observation sim: both teams remote, players parked far from the
## action (team 0 near its own corner, team 1 near the other), ball loose at
## the centre, no restart pending.
func _obs() -> MatchSession:
	var s := MatchSession.new()
	for t in 2:
		s.set_team_device(t, GameConfig.DEVICE_REMOTE)
	s.initialize(MatchConfig.new(), 3)
	var sim := s.sim
	sim.ball.owner_team = -1
	sim.ball.owner_index = -1
	sim.restart_timer = 0.0
	for t in 2:
		var players := sim.teams[t].players
		for i in players.size():
			var p := players[i]
			p.x = (-0.85 if t == 0 else 0.85) + 0.01 * i
			p.y = (-0.65 if t == 0 else 0.65)
			p.vel_x = 0.0
			p.vel_y = 0.0
		sim.teams[t].selected_index = -1
		sim.teams[t].switch_candidate = -1
	return s

func _place(p: PlayerState, x: float, y: float, face := Vector2.ZERO) -> void:
	p.x = x
	p.y = y
	if face != Vector2.ZERO:
		p.facing_x = face.x
		p.facing_y = face.y

func _outfield(sim: MatchSimulation, team: int, role: int) -> int:
	for i in sim.teams[team].players.size():
		if sim.teams[team].players[i].role == role:
			return i
	return 1

## Steps the brain `ticks` times and returns every InputSnapshot.
func _run_brain(brain: BotBrain, sim: MatchSimulation, ticks: int, playing := true) -> Array[InputSnapshot]:
	var out: Array[InputSnapshot] = []
	for i in ticks:
		out.append(brain.step(sim, playing, 1.0 / 60.0))
	return out

# --- BotBrain -------------------------------------------------------------------------

func _test_brain_chases_loose_ball() -> void:
	for diff in BotBrain.DIFFICULTIES:
		var s := _obs()
		var sim := s.sim
		var idx := _outfield(sim, 1, GameConfig.PlayerRole.MIDFIELDER)
		sim.teams[1].selected_index = idx
		_place(sim.teams[1].players[idx], 0.0, 0.0)
		sim.ball.x = 0.3
		sim.ball.y = 0.2
		var brain := BotBrain.new(diff, 1, 11)
		var input: InputSnapshot = _run_brain(brain, sim, 1)[0]
		_check(input.axis.normalized().dot(Vector2(0.3, 0.2).normalized()) > 0.9 and brain.decision.intent == "chase",
				"%s bot runs toward a loose ball" % diff)
		s.dispose()

func _test_brain_shoots_in_range() -> void:
	var s := _obs()
	var sim := s.sim
	var idx := _outfield(sim, 1, GameConfig.PlayerRole.ATTACKER)
	sim.teams[1].selected_index = idx
	var p := sim.teams[1].players[idx]
	_place(p, -0.6, 0.05, Vector2(-1.0, 0.0))
	sim.ball.owner_team = 1
	sim.ball.owner_index = idx
	_place(sim.teams[0].players[0], -0.9, 0.0)   # their keeper on his line
	var brain := BotBrain.new("hard", 1, 5)
	var inputs := _run_brain(brain, sim, 60)
	var start := -1
	var release := -1
	for i in inputs.size():
		if start < 0 and inputs[i].shoot_held and not inputs[i].shoot_prev:
			start = i
		if start >= 0 and release < 0 and inputs[i].shoot_prev and not inputs[i].shoot_held:
			release = i
	_check(start == 0 and brain.decision.action == "shoot", "in range and facing goal, the bot starts a shot at once")
	var charge := float(release - start) / 60.0 * GameConfig.CHARGE_RATE
	_check(release > start and charge >= 0.6 and charge <= 1.0, "it holds the shot for a hard-difficulty charge (%.2f)" % charge)
	var aim := inputs[maxi(release, 0)].aim_vec
	_check(is_equal_approx(aim.x, -GameConfig.FIELD_BOUNDARY_X) and absf(aim.y) < GameConfig.GOAL_HALF_WIDTH,
			"the release aims inside the posts of the goal it attacks (%.2f, %.2f)" % [aim.x, aim.y])
	_check(inputs[1].axis.x < -0.9, "it keeps running at goal while charging")
	s.dispose()

func _test_brain_passes_under_pressure() -> void:
	var s := _obs()
	var sim := s.sim
	var idx := _outfield(sim, 1, GameConfig.PlayerRole.MIDFIELDER)
	sim.teams[1].selected_index = idx
	_place(sim.teams[1].players[idx], 0.3, 0.0, Vector2(-1.0, 0.0))
	sim.ball.owner_team = 1
	sim.ball.owner_index = idx
	# Three pressers close off every lane ahead; one mate is open just behind.
	_place(sim.teams[0].players[3], 0.23, 0.03)
	_place(sim.teams[0].players[4], 0.24, -0.07)
	_place(sim.teams[0].players[5], 0.25, 0.09)
	var mate := _outfield(sim, 1, GameConfig.PlayerRole.DEFENDER)
	_place(sim.teams[1].players[mate], 0.45, 0.3)
	_place(sim.teams[0].players[6], 0.9, 0.62)   # marks the parked team-mates
	var brain := BotBrain.new("normal", 1, 9)
	var input: InputSnapshot = _run_brain(brain, sim, 1)[0]
	_check(input.pass_pressed and brain.decision.action == "pass" and not input.shoot_held,
			"pressed with no open lane, the bot recycles the ball to an open mate (%s)" % brain.decision.get("reason", ""))
	_check(not _run_brain(brain, sim, 1)[0].pass_pressed, "a pass is a one-tick press with a cooldown")
	# No pressure, but a mate unmarked far up the pitch: a progressive pass.
	for i in [3, 4, 5]:
		_place(sim.teams[0].players[i], -0.85, -0.65)
	var striker := _outfield(sim, 1, GameConfig.PlayerRole.ATTACKER)
	_place(sim.teams[1].players[striker], -0.35, 0.2)
	var brain2 := BotBrain.new("normal", 1, 9)
	_check(_run_brain(brain2, sim, 1)[0].pass_pressed and brain2.decision.reason == "mate much closer to goal",
			"unpressed, it plays a mate much closer to goal")
	s.dispose()

func _test_brain_tackles_nearby_carrier() -> void:
	var s := _obs()
	var sim := s.sim
	var carrier := _outfield(sim, 0, GameConfig.PlayerRole.ATTACKER)
	_place(sim.teams[0].players[carrier], 0.0, 0.0, Vector2(1.0, 0.0))
	sim.ball.owner_team = 0
	sim.ball.owner_index = carrier
	sim.ball.x = 0.035   # glued just ahead of the carrier's feet
	sim.ball.y = 0.0
	var idx := _outfield(sim, 1, GameConfig.PlayerRole.DEFENDER)
	sim.teams[1].selected_index = idx
	_place(sim.teams[1].players[idx], 0.07, 0.0)
	var brain := BotBrain.new("normal", 1, 2)
	var input: InputSnapshot = _run_brain(brain, sim, 1)[0]
	_check(input.tackle_pressed and brain.decision.action == "tackle", "a ball within reach, in front of its carrier, is tackled")
	# The carrier turns his back: the ball is on the far side and a lunge would be a foul.
	_place(sim.teams[0].players[carrier], 0.0, 0.0, Vector2(-1.0, 0.0))
	sim.ball.x = -0.035
	_place(sim.teams[1].players[idx], 0.02, 0.0)   # ball 0.055 away: in range
	var behind := BotBrain.new("normal", 1, 2)
	var around: InputSnapshot = _run_brain(behind, sim, 1)[0]
	_check(not around.tackle_pressed and behind.decision.reason == "step in front of the ball",
			"it never tackles from behind; it steps round to the ball instead")
	_place(sim.teams[0].players[carrier], 0.0, 0.0, Vector2(1.0, 0.0))
	sim.ball.x = 0.035
	_place(sim.teams[1].players[idx], 0.07, 0.0)
	sim.teams[1].players[idx].stun_timer = 0.3
	var brain2 := BotBrain.new("normal", 1, 2)
	_check(not _run_brain(brain2, sim, 1)[0].tackle_pressed, "a stunned player does not tackle")
	_place(sim.teams[1].players[idx], 0.4, 0.0)
	sim.teams[1].players[idx].stun_timer = 0.0
	var brain3 := BotBrain.new("normal", 1, 2)
	var chase: InputSnapshot = _run_brain(brain3, sim, 1)[0]
	_check(not chase.tackle_pressed and chase.axis.x < -0.8, "a distant carrier is closed down, not lunged at")
	s.dispose()

func _test_brain_switches_when_defending() -> void:
	var s := _obs()
	var sim := s.sim
	var carrier := _outfield(sim, 0, GameConfig.PlayerRole.ATTACKER)
	_place(sim.teams[0].players[carrier], 0.5, 0.3)
	sim.ball.owner_team = 0
	sim.ball.owner_index = carrier
	sim.teams[1].selected_index = 1
	_place(sim.teams[1].players[1], -0.5, -0.5)
	sim.teams[1].switch_candidate = 2
	_place(sim.teams[1].players[2], 0.45, 0.32)
	var brain := BotBrain.new("normal", 1, 4)
	var input: InputSnapshot = _run_brain(brain, sim, 1)[0]
	_check(input.switch_pressed and brain.decision.action == "switch", "defending, the bot switches to the team-mate nearest the carrier")
	sim.teams[1].switch_candidate = 1
	sim.teams[1].selected_index = 2
	var brain2 := BotBrain.new("normal", 1, 4)
	_check(not _run_brain(brain2, sim, 1)[0].switch_pressed, "it does not switch away from the nearest player")
	s.dispose()

func _test_brain_idle_outside_play() -> void:
	var s := _obs()
	var sim := s.sim
	sim.teams[1].selected_index = 2
	sim.ball.x = 0.4
	var brain := BotBrain.new("hard", 1, 1)
	var idle := true
	for input in _run_brain(brain, sim, 30, false):
		idle = idle and input.axis == Vector2.ZERO and not (input.pass_pressed or input.tackle_pressed or input.switch_pressed or input.shoot_held)
	_check(idle, "outside live play (restart, freeze, pause) the bot lets go of every input")
	s.dispose()

func _test_brain_sprint_rule() -> void:
	var s := _obs()
	var sim := s.sim
	var idx := _outfield(sim, 1, GameConfig.PlayerRole.MIDFIELDER)
	sim.teams[1].selected_index = idx
	var p := sim.teams[1].players[idx]
	_place(p, 0.6, 0.0)
	sim.ball.x = -0.2
	p.stamina = 1.0
	_check(_run_brain(BotBrain.new("normal", 1, 3), sim, 1)[0].sprint_held, "a far loose ball is chased at a sprint while stamina lasts")
	p.stamina = 0.1
	_check(not _run_brain(BotBrain.new("normal", 1, 3), sim, 1)[0].sprint_held, "with the tank nearly empty the bot jogs")
	s.dispose()

func _test_difficulty_profiles() -> void:
	var e: Dictionary = BotBrain.PROFILES.easy
	var n: Dictionary = BotBrain.PROFILES.normal
	var h: Dictionary = BotBrain.PROFILES.hard
	_check(e.think_s > n.think_s and n.think_s > h.think_s, "harder bots think more often")
	_check(e.aim_error > n.aim_error and n.aim_error > h.aim_error and e.noise > h.noise, "harder bots aim and steer more precisely")
	_check(BotBrain.difficulty_index("easy") == 0 and BotBrain.difficulty_index("hard") == 2 and not BotBrain.is_difficulty("insane"),
			"difficulty names map onto MatchConfig difficulty indices")
	_check(BotBrain.new("insane").difficulty == "normal", "an unknown difficulty falls back to normal")

## A snapshot taken in the second half (ends switched) must flip the observer's
## sides too: the snapshot carries positions, not sides.
func _test_observation_switches_ends() -> void:
	var server := MatchSession.new()
	for t in 2:
		server.set_team_device(t, GameConfig.DEVICE_REMOTE)
	server.initialize(MatchConfig.new(), 8)
	var mirror := _obs()
	var session := BotSession.new("obs", "ws://x/ws/game/obs", "t", "normal")
	var decode := func(s: MatchSession) -> Dictionary:
		return NetProtocol.decode(NetProtocol.encode_snapshot(NetProtocol.snapshot_from_session(s, 1, 0, 0, 0, MatchRoom.State.RUNNING)))
	session.observe(mirror.sim, decode.call(server))
	_check(mirror.sim.teams[1].players[3].side == 1 and is_equal_approx(mirror.sim.teams[1].players[3].x, server.sim.teams[1].players[3].x),
			"first half: positions copied, team 1 defends +x")
	server.current_half = 2
	server.sim.switch_ends()
	server.sim.teams[0].players[4].stun_timer = 0.3
	session.observe(mirror.sim, decode.call(server))
	_check(mirror.sim.teams[1].players[3].side == -1 and mirror.sim.teams[0].players[0].side == 1
			and is_equal_approx(mirror.sim.teams[1].players[3].start_x, server.sim.teams[1].players[3].start_x),
			"second half: the observer switches ends with the snapshot's half")
	_check(mirror.sim.teams[0].players[4].stun_timer > 0.0 and mirror.sim.teams[0].players[5].stun_timer == 0.0,
			"stun state comes from the player flags")
	server.dispose()
	mirror.dispose()

# --- job API ---------------------------------------------------------------------------

func _frame() -> void:
	await process_frame
	for c in _clients:
		(c as NetClient).poll()

func _frames_until(cond: Callable, max_ms := 5000) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < max_ms:
		if cond.call():
			return true
		await _frame()
	return cond.call()

## Sends one request to the bot job API; {status, body} (status 0 = no answer).
func _http(method: String, path: String, body: Variant = null, token := BOT_TOKEN) -> Dictionary:
	var payload: String = "" if body == null else (body if body is String else JSON.stringify(body))
	var req := "%s %s HTTP/1.1\r\nHost: ai-bot\r\nContent-Type: application/json\r\nContent-Length: %d\r\n" % [method, path, payload.to_utf8_buffer().size()]
	if token != "":
		req += "Authorization: Bearer %s\r\n" % token
	var tcp := StreamPeerTCP.new()
	tcp.connect_to_host("127.0.0.1", BOT_PORT)
	var sent := false
	var got := PackedByteArray()
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 4000:
		tcp.poll()
		var st := tcp.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			if not sent:
				tcp.put_data((req + "\r\n" + payload).to_utf8_buffer())
				sent = true
			var n := tcp.get_available_bytes()
			if n > 0:
				got.append_array(tcp.get_partial_data(n)[1])
		elif st != StreamPeerTCP.STATUS_CONNECTING:
			break
		await _frame()
	tcp.disconnect_from_host()
	var text := got.get_string_from_utf8()
	if not text.begins_with("HTTP/1.1 "):
		return {"status": 0, "body": null}
	var split := text.find("\r\n\r\n")
	return {"status": int(text.substr(9, 3)), "body": JSON.parse_string(text.substr(split + 4)) if split >= 0 else null}

func _job(match_id: String, port := WS_PORT, token := "tok", difficulty := "normal") -> Dictionary:
	return {"match_id": match_id, "token": token, "difficulty": difficulty,
			"ws_url": "ws://127.0.0.1:%d/ws/game/%s" % [port, match_id]}

func _test_job_api_auth_and_validation() -> void:
	var health := await _http("GET", "/health", null, "")
	_check(health.status == 200 and health.body.status == "ok" and int(health.body.capacity) == BotService.MAX_SESSIONS,
			"/health answers without a token")
	_check((await _http("POST", "/internal/v1/bots", _job("a-1"), "")).status == 401, "job routes require a bearer token")
	_check((await _http("GET", "/internal/v1/bots/a-1", null, "wrong")).status == 401, "a wrong bearer token is refused")
	var bad_diff := _job("a-1")
	bad_diff.difficulty = "insane"
	_check((await _http("POST", "/internal/v1/bots", bad_diff)).status == 400, "an unknown difficulty is refused (400)")
	var bad_url := _job("a-1")
	bad_url.ws_url = "ws://127.0.0.1:1/ws/game/other-match"
	_check((await _http("POST", "/internal/v1/bots", bad_url)).status == 400, "a ws_url for another match is refused (400)")
	var bad_scheme := _job("a-1")
	bad_scheme.ws_url = "http://127.0.0.1/ws/game/a-1"
	_check((await _http("POST", "/internal/v1/bots", bad_scheme)).status == 400, "a non-WebSocket URL is refused (400)")
	_check((await _http("POST", "/internal/v1/bots", "{not json")).status == 400, "a malformed body is refused (400)")
	_check((await _http("GET", "/internal/v1/bots/never")).status == 404, "an unknown job is 404")
	_check((await _http("DELETE", "/internal/v1/bots/never")).status == 404, "DELETE of an unknown job is 404")
	_check(bots.jobs().is_empty(), "no job was created by refused requests")

func _test_job_idempotency_and_stop() -> void:
	var first := await _http("POST", "/internal/v1/bots", _job("idem-1", DEAD_PORT))
	_check(first.status == 201 and first.body.state == "accepted", "a new job is accepted (201)")
	var again := await _http("POST", "/internal/v1/bots", _job("idem-1", DEAD_PORT))
	_check(again.status == 200 and again.body.match_id == "idem-1" and bots.jobs().size() == 1, "the same request again is 200, one job")
	_check((await _http("POST", "/internal/v1/bots", _job("idem-1", DEAD_PORT, "other-token"))).status == 409,
			"a different request for the same match is 409")
	var del := await _http("DELETE", "/internal/v1/bots/idem-1")
	_check(del.status == 200 and del.body.state == "stopped", "DELETE stops the job")
	_check((await _http("DELETE", "/internal/v1/bots/idem-1")).body.state == "stopped", "DELETE is idempotent")
	_check((await _http("GET", "/internal/v1/bots/idem-1")).body.state == "stopped", "a stopped job stays readable")

func _test_join_deadline_and_refusal() -> void:
	bots.join_deadline_ms = 1500
	await _http("POST", "/internal/v1/bots", _job("late-1", DEAD_PORT))
	var job := bots.job("late-1")
	_check(await _frames_until(func() -> bool: return not job.is_active(), 5000) and job.state == BotSession.State.FAILED
			and job.reason == "join_timeout", "a bot that cannot join within the deadline fails (join_timeout)")
	_check((await _http("GET", "/internal/v1/bots/late-1")).body.state == "failed", "the job API reports it failed")
	bots.join_deadline_ms = BotSession.JOIN_DEADLINE_MS
	# The runtime knows no such match: refused with 4404 at HELLO.
	await _http("POST", "/internal/v1/bots", _job("ghost-1", WS_PORT, _token("ghost-1", 1)))
	var ghost := bots.job("ghost-1")
	_check(await _frames_until(func() -> bool: return not ghost.is_active(), 5000) and ghost.state == BotSession.State.FAILED
			and ghost.reason.contains("4404"), "a credential for an unprovisioned match fails at once (%s)" % ghost.reason)
	_provision("badtok-1")
	await _http("POST", "/internal/v1/bots", _job("badtok-1", WS_PORT, _token("badtok-1", 1, "wrong-reservation")))
	var bad := bots.job("badtok-1")
	_check(await _frames_until(func() -> bool: return not bad.is_active(), 5000) and bad.reason.contains("4401"),
			"a credential that doesn't match the reservation fails (%s)" % bad.reason)
	runtime.cancel("badtok-1")

func _test_capacity() -> void:
	bots.max_sessions = 2
	var active := bots.active_count()
	var ok := true
	for i in 2 - active:
		ok = ok and (await _http("POST", "/internal/v1/bots", _job("cap-%d" % i, DEAD_PORT))).status == 201
	var full := await _http("POST", "/internal/v1/bots", _job("cap-x", DEAD_PORT))
	_check(ok and full.status == 503 and bots.job("cap-x") == null, "past BOT_MAX_SESSIONS active sessions a job is refused (503)")
	for i in 2:
		await _http("DELETE", "/internal/v1/bots/cap-%d" % i)
	_check((await _http("POST", "/internal/v1/bots", _job("cap-x", DEAD_PORT))).status == 201, "stopped sessions free their capacity")
	await _http("DELETE", "/internal/v1/bots/cap-x")
	bots.max_sessions = BotService.MAX_SESSIONS

# --- loopback match ---------------------------------------------------------------------

func _token(match_id: String, team: int, rid := "") -> String:
	var reservation := rid if rid != "" else "r%d-%s" % [team, match_id]
	return MatchToken.sign({"match_id": match_id, "reservation_id": reservation, "team": team,
			"player_id": "p%d-%s" % [team, match_id], "aud": MatchToken.AUDIENCE,
			"exp": MatchRuntime.now_unix() + 3600}, SECRET.to_utf8_buffer())

func _provision(match_id: String, bot_difficulty := 1) -> MatchRoom:
	var cfg := MatchConfig.new()
	cfg.half_length_s = 30.0
	cfg.team_difficulty = [1, bot_difficulty]
	var r := runtime.provision(match_id, cfg, MatchRuntime.now_unix() + 7200)
	for t in 2:
		r.reservations[t] = {"reservation_id": "r%d-%s" % [t, match_id], "player_id": "p%d-%s" % [t, match_id],
				"nickname": "Human" if t == 0 else "AI (Hard)"}
	return r

## The bot (team 1, hard) joins a provisioned match first, a scripted human
## (team 0) then kicks it off, and the match is played to full time with the
## clock fast-forwarded near the end of each half.
func _test_loopback_match() -> void:
	var match_id := "bot-match-1"
	var r := _provision(match_id, 2)
	var post := await _http("POST", "/internal/v1/bots", _job(match_id, WS_PORT, _token(match_id, 1), "hard"))
	var job := bots.job(match_id)
	_check(post.status == 201 and await _frames_until(func() -> bool: return job.state == BotSession.State.JOINED, 5000),
			"the bot joins its team slot (job state joined)")
	_check(r.is_attached(1) and r.state == MatchRoom.State.WAITING, "the runtime seats it on team 1 and waits for the human")
	var human := NetClient.new()
	human.connect_to("ws://127.0.0.1:%d/ws/game/%s" % [WS_PORT, match_id], _token(match_id, 0))
	_clients.append(human)
	_check(await _frames_until(func() -> bool: return job.state == BotSession.State.PLAYING and r.state == MatchRoom.State.RUNNING, 5000),
			"the human's arrival kicks off; the job reports playing")
	var bot_moved := await _frames_until(func() -> bool: return job.brain != null and job.brain.decisions_made > 20 and r.slots[1].queue.last_seq > 100, 15000)
	_check(bot_moved, "the bot observes, decides and streams input (%s)" % JSON.stringify(job.counters))
	var actions := int(job.counters.shoot) + int(job.counters.pass) + int(job.counters.tackle) + int(job.counters.switch)
	_check(actions > 0, "it takes on-ball actions (shoot/pass/tackle/switch: %d)" % actions)
	_check(await _frames_until(func() -> bool: return r.session.sim.teams[1].input.axis.length() > 0.5, 3000),
			"the runtime applies the bot's movement to team 1's selected player")
	r.session.match_time = r.config.half_length_s - 0.05
	_check(await _frames_until(func() -> bool: return r.session.current_half == 2 and r.session.phase == MatchSession.Phase.PLAYING, 8000),
			"the first half ends; play resumes in the second")
	var before := job.brain.decisions_made
	_check(await _frames_until(func() -> bool: return job.brain.decisions_made > before + 10, 8000)
			and job.mirror.sim.teams[1].players[0].side == -1, "after half time the bot plays on toward the other goal")
	r.session.match_time = r.config.half_length_s - 0.05
	_check(await _frames_until(func() -> bool: return job.state == BotSession.State.STOPPED, 10000)
			and job.reason == "match_over:full_time", "at full time the job stops (%s)" % job.reason)
	_check(r.result.get("reason") == "full_time" and runtime.registry.lookup(match_id).get("state") == "completed",
			"the runtime records the full-time result")
	var status := await _http("GET", "/internal/v1/bots/" + match_id)
	_check(status.body.state == "stopped" and int(status.body.team) == 1 and status.body.difficulty == "hard",
			"the job API reports the finished job")
	human.close()
	_clients.erase(human)

static func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for sub in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(sub))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
