class_name RuntimeControlApi
extends RefCounted

## Internal control API of the match runtime (lobby -> runtime), served by a
## ControlServer on RUNTIME_CONTROL_PORT (8911), reachable only on the
## internal network. Every route except /health needs
## "Authorization: Bearer <RUNTIME_CONTROL_TOKEN>" (401 otherwise, and always
## 401 when no token is configured). Bodies are JSON objects.
##
##   GET    /health
##          200 {status: "ok", boot_id, rooms, connections}
##   PUT    /internal/v1/matches/{match_id}
##          body {config: MatchConfig dict, expires_at: unix seconds (latest
##          credential expiry the lobby will issue for this match)}.
##          Idempotent: 201 created / 200 same config already provisioned;
##          409 different config, a dev room, or a terminal match; 400 invalid;
##          503 at capacity.
##   PUT    /internal/v1/matches/{match_id}/reservations/{team}
##          body {reservation_id, player_id, nickname}. Idempotent: 201 / 200
##          identical; 409 slot reserved differently or match not waiting;
##          404 unknown match.
##   GET    /internal/v1/matches/{match_id}
##          200 {match_id, state, reason, boot_id, connected: [b, b],
##          reserved: [b, b], reservations: [id|null, id|null], score: [l, r],
##          half, created_at, started_at}; terminal matches (also after a
##          restart) report state "completed"/"cancelled"; 404 {boot_id} unknown.
##   DELETE /internal/v1/matches/{match_id}
##          200 {state: "cancelled"} for a waiting match (or one already
##          terminal); 409 while running/paused; 404 unknown.
##
## match_id, reservation_id and player_id: 1-64 chars of [A-Za-z0-9_-];
## nickname: 1-32 characters.

const ID_PATTERN := "[A-Za-z0-9_-]{1,64}"
const MAX_NICKNAME := 32

var runtime: MatchRuntime
var _token := ""
var _match_re := RegEx.create_from_string("^/internal/v1/matches/(" + ID_PATTERN + ")$")
var _res_re := RegEx.create_from_string("^/internal/v1/matches/(" + ID_PATTERN + ")/reservations/([0-9]+)$")
var _id_re := RegEx.create_from_string("^" + ID_PATTERN + "$")

func _init(p_runtime: MatchRuntime, token: String) -> void:
	runtime = p_runtime
	_token = token

## ControlServer handler.
func handle(method: String, path: String, headers: Dictionary, body: PackedByteArray) -> Dictionary:
	if path == "/health":
		if method != "GET":
			return _reply(405, {"error": "method not allowed"})
		return _reply(200, {"status": "ok", "boot_id": runtime.boot_id, "rooms": runtime.rooms().size(),
				"connections": runtime.connection_count()})
	if not _authorized(str(headers.get("authorization", ""))):
		return _reply(401, {"error": "unauthorized"})
	var m := _res_re.search(path)
	if m != null:
		if method != "PUT":
			return _reply(405, {"error": "method not allowed"})
		var team := int(m.get_string(2)) if m.get_string(2).length() == 1 else -1
		if team != 0 and team != 1:
			return _reply(404, {"error": "no such team"})
		return _put_reservation(m.get_string(1), team, _json_body(body))
	m = _match_re.search(path)
	if m == null:
		return _reply(404, {"error": "not found"})
	var match_id := m.get_string(1)
	match method:
		"PUT":
			return _put_match(match_id, _json_body(body))
		"GET":
			return _get_match(match_id)
		"DELETE":
			return _delete_match(match_id)
	return _reply(405, {"error": "method not allowed"})

func _authorized(header: String) -> bool:
	if _token == "" or not header.begins_with("Bearer "):
		return false
	return Crypto.new().constant_time_compare(_token.to_utf8_buffer(), header.substr(7).to_utf8_buffer())

func _put_match(match_id: String, body: Variant) -> Dictionary:
	if typeof(body) != TYPE_DICTIONARY or typeof(body.get("config")) != TYPE_DICTIONARY or not _is_int(body.get("expires_at")):
		return _reply(400, {"error": "body must be {config: object, expires_at: integer}"})
	var config := MatchConfig.from_dict(body.config)
	if config == null:
		return _reply(400, {"error": "invalid config"})
	var expires_at := int(body.expires_at)
	var terminal := runtime.registry.lookup(match_id)
	if not terminal.is_empty():
		return _reply(409, {"error": "match is terminal", "state": terminal.state})
	var r: MatchRoom = runtime.room(match_id)
	if r != null:
		if r.provisioned and r.config.to_dict() == config.to_dict() and r.expires_at == expires_at:
			return _reply(200, _status(r))
		return _reply(409, {"error": "match already provisioned with a different configuration"})
	if runtime.rooms().size() >= runtime.max_rooms:
		return _reply(503, {"error": "runtime at capacity"})
	return _reply(201, _status(runtime.provision(match_id, config, expires_at)))

func _put_reservation(match_id: String, team: int, body: Variant) -> Dictionary:
	if typeof(body) != TYPE_DICTIONARY:
		return _reply(400, {"error": "body must be a JSON object"})
	var rid := str(body.get("reservation_id", ""))
	var pid := str(body.get("player_id", ""))
	var nick := str(body.get("nickname", "")).strip_edges()
	if typeof(body.get("reservation_id")) != TYPE_STRING or typeof(body.get("player_id")) != TYPE_STRING \
			or _id_re.search(rid) == null or _id_re.search(pid) == null or nick.is_empty() or nick.length() > MAX_NICKNAME:
		return _reply(400, {"error": "invalid reservation"})
	var terminal := runtime.registry.lookup(match_id)
	if not terminal.is_empty():
		return _reply(409, {"error": "match is terminal", "state": terminal.state})
	var r: MatchRoom = runtime.room(match_id)
	if r == null or not r.provisioned:
		return _reply(404, {"error": "unknown match", "boot_id": runtime.boot_id})
	var want := {"reservation_id": rid, "player_id": pid, "nickname": nick}
	var have: Dictionary = r.reservations[team]
	if have == want:
		return _reply(200, _status(r))
	if not have.is_empty():
		return _reply(409, {"error": "team already reserved"})
	if r.state != MatchRoom.State.WAITING:
		return _reply(409, {"error": "match is not waiting", "state": MatchRuntime.state_name(r)})
	r.reservations[team] = want
	MatchRuntime.log_event("reservation_made", {"match_id": match_id, "team": team, "reservation_id": rid})
	return _reply(201, _status(r))

func _get_match(match_id: String) -> Dictionary:
	var r: MatchRoom = runtime.room(match_id)
	if r != null and r.provisioned:
		return _reply(200, _status(r))
	var terminal := runtime.registry.lookup(match_id)
	if not terminal.is_empty():
		return _reply(200, {"match_id": match_id, "state": terminal.state, "reason": terminal.reason,
				"boot_id": runtime.boot_id, "connected": [false, false]})
	return _reply(404, {"error": "unknown match", "boot_id": runtime.boot_id})

func _delete_match(match_id: String) -> Dictionary:
	var r: MatchRoom = runtime.room(match_id)
	if r == null or not r.provisioned:
		var terminal := runtime.registry.lookup(match_id)
		if not terminal.is_empty():
			return _reply(200, {"match_id": match_id, "state": terminal.state, "boot_id": runtime.boot_id})
		return _reply(404, {"error": "unknown match", "boot_id": runtime.boot_id})
	if r.state == MatchRoom.State.FINISHED or runtime.cancel(match_id):
		MatchRuntime.log_event("match_cancel_requested", {"match_id": match_id, "state": MatchRuntime.state_name(r)})
		return _reply(200, _status(r))
	return _reply(409, {"error": "match is running", "state": MatchRuntime.state_name(r)})

func _status(r: MatchRoom) -> Dictionary:
	var reservations := []
	var reserved := []
	var connected := []
	for t in 2:
		var res: Dictionary = r.reservations[t]
		reservations.append(res.get("reservation_id") if not res.is_empty() else null)
		reserved.append(not res.is_empty())
		connected.append(r.is_attached(t))
	return {"match_id": r.match_id, "state": MatchRuntime.state_name(r), "reason": r.result.get("reason", ""),
			"boot_id": runtime.boot_id, "connected": connected, "reserved": reserved, "reservations": reservations,
			"score": [r.session.sim.score_left, r.session.sim.score_right], "half": r.session.current_half,
			"created_at": MatchRuntime.iso_time(r.created_unix),
			"started_at": MatchRuntime.iso_time(r.started_unix) if r.started_unix > 0 else null,
			"expires_at": r.expires_at}

static func _json_body(body: PackedByteArray) -> Variant:
	if body.is_empty():
		return null
	var json := JSON.new()   # unlike JSON.parse_string, logs nothing on bad input
	return json.data if json.parse(body.get_string_from_utf8()) == OK else null

static func _is_int(v: Variant) -> bool:
	return (typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT) and float(v) == floorf(float(v)) and float(v) >= 0.0

static func _reply(status: int, body: Dictionary) -> Dictionary:
	return {"status": status, "body": body}
