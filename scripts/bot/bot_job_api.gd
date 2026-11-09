class_name BotJobApi
extends RefCounted

## Internal job API of the ai-bot service (lobby -> ai-bot), served by a
## ControlServer on BOT_CONTROL_PORT (8920), reachable only on the internal
## network. Every route except /health needs
## "Authorization: Bearer <BOT_CONTROL_TOKEN>" (401 otherwise, and always 401
## when no token is configured). Bodies are JSON objects.
##
##   GET    /health
##          200 {status: "ok", boot_id, active, capacity}
##   POST   /internal/v1/bots
##          body {match_id, token, ws_url, difficulty: "easy"|"normal"|"hard"}.
##          Idempotent by match_id: 201 accepted / 200 the same request
##          (whatever state its job is in now); 409 a different request for
##          that match_id; 400 invalid; 503 at capacity (BOT_MAX_SESSIONS).
##          ws_url must be ws:// or wss:// .../ws/game/<match_id>.
##   GET    /internal/v1/bots/{match_id}
##          200 {match_id, state: accepted|joined|playing|stopped|failed,
##          reason, difficulty, team, created_at, joined_at, counters};
##          404 unknown (never submitted, or forgotten after retention).
##   DELETE /internal/v1/bots/{match_id}
##          200 the job, now stopped (idempotent; a failed job stays failed);
##          404 unknown.

const ID_PATTERN := "[A-Za-z0-9_-]{1,64}"
const MAX_TOKEN_CHARS := MatchToken.MAX_TOKEN_CHARS
const MAX_URL_CHARS := 512

var service: BotService
var _token := ""
var _job_re := RegEx.create_from_string("^/internal/v1/bots/(" + ID_PATTERN + ")$")
var _id_re := RegEx.create_from_string("^" + ID_PATTERN + "$")

func _init(p_service: BotService, token: String) -> void:
	service = p_service
	_token = token

## ControlServer handler.
func handle(method: String, path: String, headers: Dictionary, body: PackedByteArray) -> Dictionary:
	if path == "/health":
		if method != "GET":
			return _reply(405, {"error": "method not allowed"})
		return _reply(200, {"status": "ok", "boot_id": service.boot_id, "active": service.active_count(),
				"capacity": service.max_sessions})
	if not _authorized(str(headers.get("authorization", ""))):
		return _reply(401, {"error": "unauthorized"})
	if path == "/internal/v1/bots":
		if method != "POST":
			return _reply(405, {"error": "method not allowed"})
		return _post(RuntimeControlApi._json_body(body))
	var m := _job_re.search(path)
	if m == null:
		return _reply(404, {"error": "not found"})
	var job := service.job(m.get_string(1))
	match method:
		"GET":
			return _reply(200, job.status()) if job != null else _reply(404, {"error": "unknown bot job"})
		"DELETE":
			job = service.stop_job(m.get_string(1))
			return _reply(200, job.status()) if job != null else _reply(404, {"error": "unknown bot job"})
	return _reply(405, {"error": "method not allowed"})

func _post(body: Variant) -> Dictionary:
	if typeof(body) != TYPE_DICTIONARY:
		return _reply(400, {"error": "body must be a JSON object"})
	for key in ["match_id", "token", "ws_url", "difficulty"]:
		if typeof(body.get(key)) != TYPE_STRING:
			return _reply(400, {"error": "%s must be a string" % key})
	var match_id: String = body.match_id
	var ws_url: String = body.ws_url
	if _id_re.search(match_id) == null:
		return _reply(400, {"error": "invalid match_id"})
	if body.token.is_empty() or body.token.length() > MAX_TOKEN_CHARS:
		return _reply(400, {"error": "invalid token"})
	if not BotBrain.is_difficulty(body.difficulty):
		return _reply(400, {"error": "difficulty must be easy, normal or hard"})
	if ws_url.length() > MAX_URL_CHARS or not (ws_url.begins_with("ws://") or ws_url.begins_with("wss://")) \
			or MatchRuntime.match_id_from_url(ws_url) != match_id:
		return _reply(400, {"error": "ws_url must be ws(s)://<host>/ws/game/<match_id>"})
	var res := service.submit(match_id, ws_url, body.token, body.difficulty)
	match int(res.status):
		503:
			return _reply(503, {"error": "bot service at capacity", "capacity": service.max_sessions})
		409:
			return _reply(409, {"error": "a different bot job exists for this match", "state": (res.job as BotSession).state_name()})
	return _reply(int(res.status), (res.job as BotSession).status())

func _authorized(header: String) -> bool:
	if _token == "" or not header.begins_with("Bearer "):
		return false
	return Crypto.new().constant_time_compare(_token.to_utf8_buffer(), header.substr(7).to_utf8_buffer())

static func _reply(status: int, body: Dictionary) -> Dictionary:
	return {"status": status, "body": body}
