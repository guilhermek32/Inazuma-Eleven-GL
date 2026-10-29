extends SceneTree

## Headless tests of the match runtime's Milestone 3 contracts: credential
## vectors shared with the lobby, the internal control API (auth, idempotent
## provisioning/reservations, bounded HTTP parsing), signed-credential HELLO,
## the terminal registry and the result spool, including delivery retries
## against a fake results service and recovery after a runtime restart.
## Also the configurable capacity limits, and the game's LobbyClient against a
## fake lobby (request ids, error mapping, URL derivation).
##
## Run: godot-4 --headless --path . --script res://tests/run_runtime_tests.gd
## Exits 0 when every check passes, 1 otherwise.

const WS_PORT := 18920
const CONTROL_PORT := 18921
const RESULTS_PORT := 18922
const LOBBY_PORT := 18923
const CONTROL_TOKEN := "test-control-token"
const INGEST_TOKEN := "test-ingest-token"
const SECRET := "runtime-test-secret"
const DATA_DIR := "user://runtime_tests"
const VECTORS := "res://tests/vectors/token_vectors.json"

var failures := 0
var runtime: MatchRuntime
var fake_results: ControlServer
var results_status := 500
var results_bodies: Array = []
var results_auth: Array = []
var _clients: Array = []
var fake_lobby: ControlServer
var lobby_requests: Array = []

func _initialize() -> void:
	_run.call_deferred()

func _check(cond: bool, test_name: String) -> void:
	if cond:
		print("PASS  %s" % test_name)
	else:
		failures += 1
		print("FAIL  %s" % test_name)

func _run() -> void:
	_wipe(DATA_DIR)
	_test_token_vectors()
	_test_request_parser()
	fake_results = ControlServer.new()
	fake_results.handler = _fake_results_handler
	_check(fake_results.listen(RESULTS_PORT, "127.0.0.1") == OK, "fake results service listens")
	runtime = _new_runtime()
	await _test_health_and_auth()
	await _test_provisioning()
	await _test_capacity_limits()
	await _test_reservations()
	await _test_bounded_parsing()
	await _test_signed_hello()
	await _test_cancel_and_terminal()
	await _test_full_time_spool()
	await _test_rejected_result()
	await _test_restart_recovery()
	await _test_lobby_client()
	runtime.stop()
	fake_results.stop()
	_wipe(DATA_DIR)
	print("ALL TESTS PASSED" if failures == 0 else "%d TEST(S) FAILED" % failures)
	quit(1 if failures > 0 else 0)

# --- helpers ------------------------------------------------------------------------

func _new_runtime() -> MatchRuntime:
	var rt := MatchRuntime.new()
	rt.match_secret = SECRET.to_utf8_buffer()
	rt.open_storage(DATA_DIR)
	rt.spool.configure("http://127.0.0.1:%d" % RESULTS_PORT, INGEST_TOKEN)
	rt.spool.backoff_base_ms = 100
	rt.spool.backoff_max_ms = 400
	root.add_child(rt)
	rt.start(WS_PORT, "127.0.0.1")
	rt.start_control(CONTROL_PORT, "127.0.0.1", CONTROL_TOKEN)
	return rt

func _fake_results_handler(method: String, path: String, headers: Dictionary, body: PackedByteArray) -> Dictionary:
	results_bodies.append(body.get_string_from_utf8())
	results_auth.append(str(headers.get("authorization", "")))
	return {"status": results_status, "body": {"method": method, "path": path}}

## One frame: the runtime polls itself; the test polls the fake service and clients.
func _frame() -> void:
	await process_frame
	fake_results.poll()
	for c in _clients:
		(c as NetClient).poll()

func _frames_until(cond: Callable, max_ms := 5000) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < max_ms:
		if cond.call():
			return true
		await _frame()
	return cond.call()

func _wait_ms(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await _frame()

static func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for sub in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(sub))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)

## Sends raw bytes to the control port and returns the whole response text.
func _raw(request: PackedByteArray, max_ms := 4000) -> String:
	var tcp := StreamPeerTCP.new()
	tcp.connect_to_host("127.0.0.1", CONTROL_PORT)
	var sent := false
	var got := PackedByteArray()
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < max_ms:
		tcp.poll()
		var st := tcp.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			if not sent:
				tcp.put_data(request)
				sent = true
			var n := tcp.get_available_bytes()
			if n > 0:
				got.append_array(tcp.get_partial_data(n)[1])
		elif st != StreamPeerTCP.STATUS_CONNECTING:
			break
		await _frame()
	tcp.disconnect_from_host()
	return got.get_string_from_utf8()

## Returns {status: int, body: Variant}; status 0 when no response arrived.
func _http(method: String, path: String, body: Variant = null, token := CONTROL_TOKEN) -> Dictionary:
	var payload: String = "" if body == null else (body if body is String else JSON.stringify(body))
	var req := "%s %s HTTP/1.1\r\nHost: runtime\r\nContent-Type: application/json\r\nContent-Length: %d\r\n" % [method, path, payload.to_utf8_buffer().size()]
	if token != "":
		req += "Authorization: Bearer %s\r\n" % token
	return _parse_response(await _raw((req + "\r\n" + payload).to_utf8_buffer()))

static func _parse_response(text: String) -> Dictionary:
	if not text.begins_with("HTTP/1.1 "):
		return {"status": 0, "body": null}
	var split := text.find("\r\n\r\n")
	return {"status": int(text.substr(9, 3)), "body": JSON.parse_string(text.substr(split + 4)) if split >= 0 else null}

func _config(half := 60.0) -> Dictionary:
	var c := MatchConfig.new()
	c.half_length_s = half
	return c.to_dict()

func _provision(match_id: String, half := 60.0, expires_at := 0) -> Dictionary:
	var exp := expires_at if expires_at > 0 else MatchRuntime.now_unix() + 7200
	return await _http("PUT", "/internal/v1/matches/" + match_id, {"config": _config(half), "expires_at": exp})

func _reserve(match_id: String, team: int, rid: String, pid: String, nick := "Player") -> Dictionary:
	return await _http("PUT", "/internal/v1/matches/%s/reservations/%d" % [match_id, team],
			{"reservation_id": rid, "player_id": pid, "nickname": nick})

func _token(match_id: String, team: int, rid: String, pid: String, exp_in := 3600, aud := MatchToken.AUDIENCE, secret := SECRET) -> String:
	return MatchToken.sign({"match_id": match_id, "reservation_id": rid, "team": team, "player_id": pid,
			"aud": aud, "exp": MatchRuntime.now_unix() + exp_in}, secret.to_utf8_buffer())

## Opens a raw WebSocket to /ws/game/<path_id>, sends HELLO and returns
## {"welcome": msg} or {"close": code}.
func _hello(path_id: String, token: String) -> Dictionary:
	var ws := WebSocketPeer.new()
	ws.connect_to_url("ws://127.0.0.1:%d/ws/game/%s" % [WS_PORT, path_id])
	var sent := false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000:
		ws.poll()
		var st := ws.get_ready_state()
		if st == WebSocketPeer.STATE_OPEN:
			if not sent:
				ws.send(NetProtocol.encode_hello(token))
				sent = true
			while ws.get_available_packet_count() > 0:
				var msg := NetProtocol.decode(ws.get_packet())
				if msg.get("type") == NetProtocol.Type.WELCOME:
					ws.close()
					return {"welcome": msg}
		elif st == WebSocketPeer.STATE_CLOSED:
			return {"close": ws.get_close_code()}
		await _frame()
	ws.close()
	return {"close": -1}

func _net_client(match_id: String, token: String) -> NetClient:
	var c := NetClient.new()
	c.connect_to("ws://127.0.0.1:%d/ws/game/%s" % [WS_PORT, match_id], token)
	_clients.append(c)
	return c

# --- unit: credentials / parser -------------------------------------------------------

func _test_token_vectors() -> void:
	var doc = JSON.parse_string(FileAccess.get_file_as_string(VECTORS))
	_check(typeof(doc) == TYPE_DICTIONARY and doc.valid.size() > 0 and doc.invalid.size() > 0, "token vectors load")
	var key: PackedByteArray = str(doc.secret).to_utf8_buffer()
	var now := int(doc.now)
	var valid_ok := true
	for v in doc.valid:
		var claims := {}
		for k in v.claims:
			claims[k] = int(v.claims[k]) if v.claims[k] is float else v.claims[k]
		var signed := MatchToken.sign(claims, key)
		var res := MatchToken.verify(v.token, key, now, str(doc.audience))
		if signed != v.token or not res.ok or res.claims != claims:
			valid_ok = false
			print("      vector mismatch: %s" % v.name)
	_check(valid_ok, "valid vectors sign byte-identically and verify to the same claims (%d)" % doc.valid.size())
	var invalid_ok := true
	for v in doc.invalid:
		var res := MatchToken.verify(v.token, key, now, str(doc.audience))
		if res.ok or res.error != v.error:
			invalid_ok = false
			print("      vector %s: expected %s, got %s" % [v.name, v.error, res.get("error", "ok")])
	_check(invalid_ok, "invalid vectors fail with the expected error (%d)" % doc.invalid.size())

func _test_request_parser() -> void:
	var partial := ControlServer.parse_request("GET /health HTTP/1.1\r\nHost: x\r\n".to_utf8_buffer())
	var full := ControlServer.parse_request("PUT /a?b=1 HTTP/1.1\r\nContent-Length: 2\r\nX-Y: z\r\n\r\n{}".to_utf8_buffer())
	var waiting_body := ControlServer.parse_request("PUT /a HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}".to_utf8_buffer())
	_check(partial.is_empty() and waiting_body.is_empty(), "incomplete requests wait for more bytes")
	_check(full.get("method") == "PUT" and full.path == "/a" and full.headers["x-y"] == "z" and full.body.get_string_from_utf8() == "{}",
			"a complete request parses (query stripped, headers lower-cased)")
	_check(ControlServer.parse_request("PUT /a HTTP/1.1\r\nContent-Length: 9000\r\n\r\n".to_utf8_buffer()).get("error") == 413
			and ControlServer.parse_request("PUT /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".to_utf8_buffer()).get("error") == 501
			and ControlServer.parse_request("NONSENSE\r\n\r\n".to_utf8_buffer()).get("error") == 400
			and ControlServer.parse_request("GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n".to_utf8_buffer()).get("error") == 400,
			"oversized, chunked and malformed requests are refused")
	var overflow_ok := true
	for cl in ["9223372036854775807", "99999999999999999999", "18446744073709551615"]:
		if ControlServer.parse_request(("PUT /a HTTP/1.1\r\nContent-Length: %s\r\n\r\n" % cl).to_utf8_buffer()).get("error") != 413:
			overflow_ok = false
	_check(overflow_ok, "an overflowing Content-Length is refused as too large, not parsed as complete")

# --- control API ----------------------------------------------------------------------------

func _test_health_and_auth() -> void:
	var health := await _http("GET", "/health", null, "")
	_check(health.status == 200 and health.body.boot_id == runtime.boot_id and runtime.boot_id.length() == 36, "GET /health needs no auth and reports the boot id")
	_check((await _http("GET", "/internal/v1/matches/x", null, "")).status == 401, "control routes require a bearer token")
	_check((await _http("GET", "/internal/v1/matches/x", null, "wrong-token")).status == 401, "a wrong bearer token is refused")
	_check((await _http("GET", "/internal/v1/nothing")).status == 404, "unknown routes are 404")

func _test_provisioning() -> void:
	var first := await _provision("prov-1", 60.0, 2000000000)
	_check(first.status == 201 and first.body.state == "waiting" and first.body.boot_id == runtime.boot_id, "PUT match provisions a waiting room (201)")
	_check((await _provision("prov-1", 60.0, 2000000000)).status == 200, "re-provisioning with the same config is idempotent (200)")
	_check((await _provision("prov-1", 90.0, 2000000000)).status == 409, "a conflicting config is refused (409)")
	_check((await _http("PUT", "/internal/v1/matches/prov-2", {"config": {"version": 1}, "expires_at": 1})).status == 400, "an invalid config is refused (400)")
	_check((await _http("PUT", "/internal/v1/matches/prov-2", "{not json")).status == 400, "a malformed body is refused (400)")
	_check(runtime.room("prov-2") == null, "refused provisioning creates no room")
	var status := await _http("GET", "/internal/v1/matches/prov-1")
	_check(status.status == 200 and status.body.state == "waiting" and status.body.connected == [false, false]
			and status.body.reserved == [false, false], "GET match reports state, slots and connections")
	var unknown := await _http("GET", "/internal/v1/matches/nope")
	_check(unknown.status == 404 and unknown.body.boot_id == runtime.boot_id, "GET of an unknown match is 404 with the boot id")

func _test_reservations() -> void:
	_check((await _reserve("prov-1", 0, "res-a", "player-a", "Ana")).status == 201, "PUT reservation reserves a slot (201)")
	_check((await _reserve("prov-1", 0, "res-a", "player-a", "Ana")).status == 200, "repeating the same reservation is idempotent (200)")
	_check((await _reserve("prov-1", 0, "res-b", "player-b", "Bia")).status == 409, "a different reservation for a taken slot is refused (409)")
	_check((await _reserve("nope", 1, "res-b", "player-b")).status == 404, "reserving in an unknown match is 404")
	_check((await _http("PUT", "/internal/v1/matches/prov-1/reservations/2", {"reservation_id": "r", "player_id": "p", "nickname": "n"})).status == 404, "team 2 does not exist")
	_check((await _reserve("prov-1", 1, "bad id!", "player-b")).status == 400, "an invalid reservation body is refused (400)")
	var status := await _http("GET", "/internal/v1/matches/prov-1")
	_check(status.body.reserved == [true, false] and status.body.reservations[0] == "res-a", "GET reports the reservation")

func _test_bounded_parsing() -> void:
	var big := "PUT /internal/v1/matches/x HTTP/1.1\r\nContent-Length: 9000\r\n\r\n" + "x".repeat(9000)
	_check((await _raw(big.to_utf8_buffer())).begins_with("HTTP/1.1 413"), "a request over 8 KB is refused with 413")
	_check((await _raw(("GET /" + "a".repeat(9000)).to_utf8_buffer())).begins_with("HTTP/1.1 413"), "an unterminated 9 KB header is refused with 413")
	var t0 := Time.get_ticks_msec()
	var slow := await _raw("PUT /internal/v1/matches/x HTTP/1.1\r\nContent-Length: 10\r\n\r\n{".to_utf8_buffer(), 5000)
	var waited := Time.get_ticks_msec() - t0
	_check(slow.begins_with("HTTP/1.1 408") and waited < 4000, "a stalled request is cut off at the 2 s deadline (%d ms)" % waited)
	var idle: Array[StreamPeerTCP] = []
	for i in ControlServer.MAX_CONNECTIONS + 4:
		var tcp := StreamPeerTCP.new()
		tcp.connect_to_host("127.0.0.1", CONTROL_PORT)
		idle.append(tcp)
	# The listen backlog is small, so some connects complete only on a SYN retry (~1 s).
	var poll_idle := func() -> bool:
		for tcp in idle:
			tcp.poll()
		return runtime.control.connection_count() >= ControlServer.MAX_CONNECTIONS
	await _frames_until(poll_idle, 1800)
	await _wait_ms(100)
	var held := runtime.control.connection_count()
	_check(held == ControlServer.MAX_CONNECTIONS, "connections over the cap are closed on accept (%d held)" % held)
	for tcp in idle:
		tcp.disconnect_from_host()
	await _wait_ms(2300)
	_check(runtime.control.connection_count() == 0, "abandoned connections are released by the deadline")
	_check((await _http("GET", "/health", null, "")).status == 200, "the control API still serves afterwards")

# --- signed HELLO -------------------------------------------------------------------------

func _test_signed_hello() -> void:
	await _provision("hello-1")
	await _reserve("hello-1", 0, "res-0", "player-0", "Red")
	await _reserve("hello-1", 1, "res-1", "player-1", "Blue")
	var ok := await _hello("hello-1", _token("hello-1", 1, "res-1", "player-1"))
	_check(ok.has("welcome") and ok.welcome.team == 1, "a valid signed credential is welcomed on its team")
	var cases := [
		["bad signature", "hello-1", _token("hello-1", 0, "res-0", "player-0", 3600, MatchToken.AUDIENCE, "another-secret"), NetProtocol.CLOSE_UNAUTHORIZED],
		["expired", "hello-1", _token("hello-1", 0, "res-0", "player-0", -5), NetProtocol.CLOSE_UNAUTHORIZED],
		["wrong audience", "hello-1", _token("hello-1", 0, "res-0", "player-0", 3600, "lobby"), NetProtocol.CLOSE_UNAUTHORIZED],
		["path mismatch", "prov-1", _token("hello-1", 0, "res-0", "player-0"), NetProtocol.CLOSE_UNAUTHORIZED],
		["unprovisioned match", "ghost", _token("ghost", 0, "res-0", "player-0"), NetProtocol.CLOSE_UNKNOWN_MATCH],
		["wrong reservation", "hello-1", _token("hello-1", 0, "res-1", "player-0"), NetProtocol.CLOSE_UNAUTHORIZED],
		["wrong player", "hello-1", _token("hello-1", 0, "res-0", "player-1"), NetProtocol.CLOSE_UNAUTHORIZED],
		["outlives the match", "prov-1", _token("prov-1", 0, "res-a", "player-a", 2000000000 - MatchRuntime.now_unix() + 60), NetProtocol.CLOSE_UNAUTHORIZED],
		["dev token without DEV_NO_AUTH", "hello-1", "dev:0", NetProtocol.CLOSE_UNAUTHORIZED],
	]
	for c in cases:
		var res := await _hello(c[1], c[2])
		_check(res.get("close", 0) == c[3], "HELLO refused: %s (%s)" % [c[0], res])
	_check(runtime.room("ghost") == null, "a refused HELLO creates no room")

func _test_cancel_and_terminal() -> void:
	await _provision("cancel-1")
	await _reserve("cancel-1", 0, "res-0", "player-0")
	var del := await _http("DELETE", "/internal/v1/matches/cancel-1")
	_check(del.status == 200 and del.body.state == "cancelled", "DELETE cancels a waiting match")
	_check((await _http("DELETE", "/internal/v1/matches/cancel-1")).status == 200, "DELETE is idempotent")
	_check((await _http("GET", "/internal/v1/matches/cancel-1")).body.state == "cancelled", "a cancelled match reports cancelled")
	_check((await _provision("cancel-1")).status == 409, "a terminal match can't be provisioned again (409)")
	_check((await _hello("cancel-1", _token("cancel-1", 0, "res-0", "player-0"))).get("close") == NetProtocol.CLOSE_MATCH_OVER,
			"a still-valid credential for a terminal match is refused (4410)")
	_check(not runtime.spool.is_pending("cancel-1"), "a cancelled match spools no result")
	_check((await _http("DELETE", "/internal/v1/matches/nope")).status == 404, "DELETE of an unknown match is 404")

# --- result spool ---------------------------------------------------------------------------

## Provisions, reserves and connects both teams; returns the running room.
func _start_match(match_id: String) -> MatchRoom:
	await _provision(match_id, 30.0)
	await _reserve(match_id, 0, "r0-" + match_id, "p0-" + match_id, "Red")
	await _reserve(match_id, 1, "r1-" + match_id, "p1-" + match_id, "Blue")
	_net_client(match_id, _token(match_id, 0, "r0-" + match_id, "p0-" + match_id))
	_net_client(match_id, _token(match_id, 1, "r1-" + match_id, "p1-" + match_id))
	var r := runtime.room(match_id)
	await _frames_until(func() -> bool: return r.state == MatchRoom.State.RUNNING)
	return r

func _force_full_time(r: MatchRoom) -> void:
	r.session.current_half = 2
	r.session.match_time = r.config.half_length_s - 0.05

func _test_full_time_spool() -> void:
	var r := await _start_match("ft-1")
	_check(r.state == MatchRoom.State.RUNNING, "two signed clients kick off a provisioned match")
	_check((await _http("DELETE", "/internal/v1/matches/ft-1")).status == 409, "DELETE of a running match is refused (409)")
	results_status = 500
	results_bodies.clear()
	results_auth.clear()
	r.session.sim.score_left = 2
	_force_full_time(r)
	_check(await _frames_until(func() -> bool: return r.recorded), "the room records its finish")
	_check(runtime.room("ft-1") != null and FileAccess.file_exists(runtime.spool.file_path("ft-1")),
			"the result is spooled before the room is freed")
	_check(runtime.registry.lookup("ft-1").get("state") == "completed", "the terminal state is recorded")
	_check(await _frames_until(func() -> bool: return results_bodies.size() >= 2, 4000), "delivery is retried while results fails (%d attempts)" % results_bodies.size())
	_check(FileAccess.file_exists(runtime.spool.file_path("ft-1")), "the spool file survives failed deliveries")
	results_status = 201
	_check(await _frames_until(func() -> bool: return not FileAccess.file_exists(runtime.spool.file_path("ft-1")), 4000),
			"the spool file is deleted after a 2xx")
	var identical := true
	for b in results_bodies:
		identical = identical and b == results_bodies[0]
	var doc = JSON.parse_string(results_bodies[0])
	_check(identical and results_auth[0] == "Bearer " + INGEST_TOKEN, "every attempt sends identical bytes with the ingest token")
	_check(doc.match_id == "ft-1" and doc.reason == "full_time" and doc.score_left == 2 and doc.winner == 0
			and doc.players[1].nickname == "Blue" and doc.players[0].player_id == "p0-ft-1" and doc.stats.size() == 2
			and doc.finished_at.ends_with("Z") and doc.started_at != null and doc.config_version == 1,
			"the result is self-contained (players, score, winner, stats, timestamps)")
	await _frames_until(func() -> bool: return runtime.room("ft-1") == null, 5000)
	_check((await _http("GET", "/internal/v1/matches/ft-1")).body.get("state") == "completed", "a freed match still reports completed")
	_check((await _hello("ft-1", _token("ft-1", 0, "r0-ft-1", "p0-ft-1"))).get("close") == NetProtocol.CLOSE_MATCH_OVER,
			"credentials for a finished match are refused (4410)")
	_clients.clear()

func _test_rejected_result() -> void:
	results_status = 409
	results_bodies.clear()
	var r := await _start_match("rej-1")
	_force_full_time(r)
	_check(await _frames_until(func() -> bool: return FileAccess.file_exists(runtime.spool.rejected_path("rej-1")), 4000),
			"a 409 moves the result to spool/rejected/")
	await _wait_ms(1200)
	_check(results_bodies.size() == 1 and not runtime.spool.is_pending("rej-1"), "a rejected result is not retried")
	_clients.clear()

func _test_restart_recovery() -> void:
	results_status = 503
	results_bodies.clear()
	runtime.spool.write({"match_id": "pending-1", "reason": "full_time"})
	await _frames_until(func() -> bool: return results_bodies.size() >= 1, 3000)
	runtime.stop()
	runtime.queue_free()
	await _wait_ms(100)
	runtime = _new_runtime()
	_check(runtime.spool.is_pending("pending-1"), "a restarted runtime queues the undelivered result again")
	_check(runtime.registry.lookup("ft-1").get("state") == "completed" and runtime.registry.lookup("cancel-1").get("state") == "cancelled",
			"the terminal registry survives the restart")
	_check((await _provision("ft-1")).status == 409, "a finished match can't be re-provisioned after a restart")
	_check((await _hello("ft-1", _token("ft-1", 0, "r0-ft-1", "p0-ft-1"))).get("close") == NetProtocol.CLOSE_MATCH_OVER,
			"its credentials are still refused after a restart")
	_check((await _http("GET", "/internal/v1/matches/hello-1")).status == 404, "live matches don't survive a restart (404)")
	results_status = 200
	_check(await _frames_until(func() -> bool: return not runtime.spool.is_pending("pending-1"), 4000), "the recovered result is delivered")

func _test_capacity_limits() -> void:
	var rooms_cap := runtime.max_rooms
	runtime.max_rooms = runtime.rooms().size()
	_check((await _provision("cap-1")).status == 503 and runtime.room("cap-1") == null,
			"provisioning past max_rooms (RUNTIME_MAX_ROOMS) is refused with 503")
	runtime.max_rooms = rooms_cap
	var conns_cap := runtime.max_connections
	runtime.max_connections = runtime.connection_count()
	var ws := WebSocketPeer.new()
	ws.connect_to_url("ws://127.0.0.1:%d/ws/game/cap-1" % WS_PORT)
	var closed := func() -> bool:
		ws.poll()
		return ws.get_ready_state() == WebSocketPeer.STATE_CLOSED
	_check(await _frames_until(closed, 3000) and runtime.connection_count() == runtime.max_connections,
			"a connection past max_connections (RUNTIME_MAX_CONNECTIONS) is closed on accept")
	runtime.max_connections = conns_cap

# --- LobbyClient against a fake lobby ------------------------------------------------

func _fake_lobby_handler(method: String, path: String, _headers: Dictionary, body: PackedByteArray) -> Dictionary:
	var json = JSON.parse_string(body.get_string_from_utf8()) if body.size() > 0 else null
	lobby_requests.append({"method": method, "path": path, "body": json})
	match path:
		"/api/lobby/v1/rooms":
			return {"status": 201, "body": {"room_code": "ABC234", "match_id": "m-1", "team": 0, "token": "tok",
					"ws_url": "/ws/game/m-1", "player_id": "p-1", "nickname": json.nickname}}
		"/api/lobby/v1/rooms/NOPE22/join":
			return {"status": 404, "body": {"error": "room_not_found", "detail": "no room with that code"}}
		"/api/lobby/v1/rooms/BUSY22/join":
			return {"status": 503, "body": {"error": "runtime_unavailable", "detail": "retry with the same request_id"}}
		"/api/stats/v1/leaderboard":
			return {"status": 200, "body": {"items": [{"rank": 1, "nickname": "Ana", "points": 3, "wins": 1, "draws": 0,
					"losses": 0, "goal_diff": 2, "goals_for": 2, "player_id": "p-1"}], "next_cursor": null}}
		"/api/recommendations/v1/recommendations":
			return {"status": 200, "body": {"player": {"player_id": "p-1", "rating": 1032, "played": 2, "wins": 2,
					"draws": 0, "losses": 0, "form": "WW", "provisional": true},
					"ai_level": {"level": "normal", "win_probability": 0.47, "reason": "matched_to_rating", "options": []},
					"rivals": [{"player_id": "p-2", "nickname": "Bia", "rating": 1010, "played": 3, "win_probability": 0.53}],
					"model": {"matches": 5, "players": 5, "stale": false, "updated_at": null}}}
	return {"status": 404, "body": {"error": "not_found"}}

## Runs one LobbyClient coroutine to completion while polling the fake lobby.
func _lobby_call(fn: Callable) -> Dictionary:
	var box := {}
	var run := func() -> void: box["r"] = await fn.call()
	run.call()
	var t0 := Time.get_ticks_msec()
	while not box.has("r") and Time.get_ticks_msec() - t0 < 12000:
		await process_frame
		fake_lobby.poll()
	return box.get("r", {})

func _last_request_id() -> String:
	return str(lobby_requests.back().body.get("request_id", "")) if not lobby_requests.is_empty() else ""

func _test_lobby_client() -> void:
	fake_lobby = ControlServer.new()
	fake_lobby.handler = _fake_lobby_handler
	_check(fake_lobby.listen(LOBBY_PORT, "127.0.0.1") == OK, "fake lobby listens")
	var lobby := LobbyClient.new()
	lobby.base_url = "http://127.0.0.1:%d/api/lobby/v1" % LOBBY_PORT
	root.add_child(lobby)
	var created := await _lobby_call(func() -> Dictionary: return await lobby.create_room("Ana", 30))
	var sent: Dictionary = lobby_requests.back().body if not lobby_requests.is_empty() else {}
	_check(created.get("ok", false) and created.status == 201 and created.body.room_code == "ABC234",
			"create_room returns the lobby's grant")
	_check(sent.get("nickname") == "Ana" and int(sent.get("half_length_s", 0)) == 30 and not sent.has("player_id")
			and RegEx.create_from_string("^[A-Za-z0-9_-]{8,64}$").search(str(sent.get("request_id", ""))) != null,
			"create_room sends nickname, half length and a valid request_id")
	await _lobby_call(func() -> Dictionary: return await lobby.create_room("Ana", 30, "", "hard"))
	var vs_ai: Dictionary = lobby_requests.back().body
	_check(vs_ai.get("mode") == "vs_ai" and vs_ai.get("difficulty") == "hard" and _last_request_id() != str(sent.get("request_id")),
			"create_room with a difficulty asks for a vs-AI room (its own request_id)")
	var no_bot := LobbyClient.parse_response(HTTPRequest.RESULT_SUCCESS, 503,
			JSON.stringify({"error": "bot_unavailable", "detail": "x"}).to_utf8_buffer())
	_check(no_bot.error == "bot_unavailable" and LobbyClient.describe(no_bot).begins_with("The AI opponent is unavailable"),
			"bot_unavailable is reported to the player")
	_check(lobby.ws_url("/ws/game/m-1") == "ws://127.0.0.1:%d/ws/game/m-1" % LOBBY_PORT
			and lobby.stats_base_url() == "http://127.0.0.1:%d/api/stats/v1" % LOBBY_PORT,
			"the WebSocket and stats URLs derive from the lobby origin")
	var secure := LobbyClient.new()
	secure.base_url = "https://game.example.com/api/lobby/v1"
	_check(secure.ws_url("/ws/game/x") == "wss://game.example.com/ws/game/x", "an https lobby gives a wss match URL")
	secure.free()
	var missing := await _lobby_call(func() -> Dictionary: return await lobby.join_room("NOPE22", "Bia"))
	var first_missing_id := _last_request_id()
	_check(not missing.get("ok", true) and missing.status == 404 and missing.error == "room_not_found"
			and LobbyClient.describe(missing) == "No room with that code.", "an unknown room maps to room_not_found")
	await _lobby_call(func() -> Dictionary: return await lobby.join_room("BUSY22", "Bia"))
	var busy_id := _last_request_id()
	var retry := await _lobby_call(func() -> Dictionary: return await lobby.join_room("BUSY22", "Bia"))
	_check(retry.error == "runtime_unavailable" and _last_request_id() == busy_id,
			"a join retried after runtime_unavailable reuses its request_id")
	await _lobby_call(func() -> Dictionary: return await lobby.join_room("NOPE22", "Bia"))
	_check(_last_request_id() != first_missing_id and _last_request_id() != busy_id,
			"a definitive answer retires the request_id")
	var board := await _lobby_call(func() -> Dictionary: return await lobby.leaderboard(5))
	_check(board.get("ok", false) and OnlineMenu.format_board(board).begins_with("1. Ana   3 pts"),
			"leaderboard() reads the stats API and formats for the menu")
	var rec := await _lobby_call(func() -> Dictionary: return await lobby.recommendations("p-1"))
	var rec_text: Dictionary = OnlineMenu.format_recommendation(rec.get("body", {}))
	_check(rec.get("ok", false) and rec_text.level == "NORMAL   47% expected score"
			and rec_text.player == "Rating 1032  (provisional)\n2 played (2-0-0)   form WW"
			and rec_text.rivals == "Bia   1010   (53%)" and rec_text.reason == OnlineMenu.REASON_TEXT.matched_to_rating,
			"recommendations() reads the recommendation API and formats for the menu")
	var fresh: Dictionary = OnlineMenu.format_recommendation({"player": {"rating": 1000, "played": 0}, "rivals": [],
			"ai_level": {"level": "easy", "win_probability": 0.64, "reason": "first_match"}})
	_check(fresh.rivals.begins_with("No rated rivals") and fresh.level.begins_with("EASY"),
			"a new player's recommendation has no rivals yet")
	_check(lobby.recommendations_base_url() == "http://127.0.0.1:%d/api/recommendations/v1" % LOBBY_PORT
			and lobby.status_base_url() == "http://127.0.0.1:%d/api/status/v1/" % LOBBY_PORT,
			"the recommendation and status URLs derive from the lobby origin")
	var both := {}
	var first_call := func() -> void: both["a"] = await lobby.leaderboard(5)
	first_call.call()
	var second: Dictionary = await lobby.leaderboard(5)
	_check(second.error == "busy", "a second call while one is in flight is refused as busy")
	var wait_first := func() -> Dictionary:
		while not both.has("a"):
			await process_frame
		return both.a
	_check((await _lobby_call(wait_first)).get("ok", false), "the first call still completes")
	var offline := LobbyClient.new()
	offline.base_url = "http://127.0.0.1:1/api/lobby/v1"
	root.add_child(offline)
	var down := await _lobby_call(func() -> Dictionary: return await offline.create_room("Ana", 120))
	_check(down.get("error") == "network" and down.status == 0 and LobbyClient.describe(down).begins_with("Cannot reach"),
			"an unreachable lobby is a network error")
	var invalid := LobbyClient.parse_response(HTTPRequest.RESULT_SUCCESS, 422,
			JSON.stringify({"error": "invalid_request", "detail": [{"field": "nickname", "message": "too long"}]}).to_utf8_buffer())
	_check(invalid.error == "invalid_request" and invalid.message == "nickname: too long", "a 422 carries the first field problem")
	_check(LobbyClient.parse_response(HTTPRequest.RESULT_SUCCESS, 502, PackedByteArray()).error == "unavailable"
			and LobbyClient.parse_response(HTTPRequest.RESULT_SUCCESS, 200, "<html>".to_utf8_buffer()).error == "bad_response",
			"gateway errors and non-JSON answers are mapped")
	lobby.queue_free()
	offline.queue_free()
	fake_lobby.stop()
