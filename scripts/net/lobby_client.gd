class_name LobbyClient
extends Node

## HTTP client of the public online services, through the gateway: the
## lobby's room API and the results service's public reads. Used by the
## in-game online menu (OnlineMenu); add it to the tree before calling.
##
## Endpoints (base_url = <origin>/api/lobby/v1, stats = <origin>/api/stats/v1):
##   create_room   POST /rooms               {nickname, half_length_s, request_id, player_id?}
##   join_room     POST /rooms/{code}/join   {nickname, request_id, player_id?}
##   room_status   GET  /rooms/{code}
##   recent_matches / leaderboard   GET <stats>/matches/recent, <stats>/leaderboard
## base_url defaults to the page's own origin on the web (same-origin, so no
## CORS) and to `-- --lobby=<url>` or DEFAULT_DESKTOP_BASE on desktop.
##
## Every call is a coroutine (use await) returning a reply:
##   {ok: bool, status: int (0 = no HTTP answer), error: String, message: String, body: Dictionary}
## `error` is the lobby's own code ("room_not_found", "room_full", "room_closed",
## "runtime_unavailable", "invalid_request", "player_not_found", ...) or a local
## one: "network" (no answer: timeout, DNS, refused), "unavailable" (502-504
## from the gateway), "bad_response" (not JSON), "busy" (a call is in flight;
## calls are not queued). describe() turns a reply into a player-facing line.
##
## Idempotency: create/join send a request_id. After a "network" or
## "runtime_unavailable" failure the same call (same parameters) reuses its
## request_id, as the lobby asks: a retried join then completes the pending
## reservation instead of finding the room full of our own half-made seat.

const DEFAULT_DESKTOP_BASE := "http://localhost:8080/api/lobby/v1"
const TIMEOUT_S := 10.0
const RETRYABLE := ["network", "runtime_unavailable", "unavailable"]

var base_url := ""
var _http: HTTPRequest
var _busy := false
var _retry_ids := {}   # call key -> request_id kept for a retry

func _ready() -> void:
	if base_url == "":
		base_url = default_base_url()
	_http = HTTPRequest.new()
	_http.timeout = TIMEOUT_S
	add_child(_http)

static func default_base_url() -> String:
	var arg := LaunchArgs.value("lobby")
	if arg != "":
		return arg.trim_suffix("/")
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("window.location.origin", true)) + "/api/lobby/v1"
	return DEFAULT_DESKTOP_BASE

## "scheme://host[:port]" of an absolute URL ("" if it has no scheme).
static func origin_of(url: String) -> String:
	var i := url.find("://")
	if i < 0:
		return ""
	var j := url.find("/", i + 3)
	return url if j < 0 else url.substr(0, j)

## The WebSocket URL for a lobby grant's ws_url path ("/ws/game/<id>"), on the
## lobby's own origin: http -> ws, https -> wss.
func ws_url(ws_path: String) -> String:
	var origin := origin_of(base_url)
	if origin.begins_with("https://"):
		return "wss://" + origin.substr(8) + ws_path
	return "ws://" + origin.trim_prefix("http://") + ws_path

func stats_base_url() -> String:
	return origin_of(base_url) + "/api/stats/v1"

func is_busy() -> bool:
	return _busy

func create_room(nickname: String, half_length_s: int, player_id := "") -> Dictionary:
	var body := {"nickname": nickname, "half_length_s": half_length_s}
	if player_id != "":
		body["player_id"] = player_id
	return await _post_idempotent("create|%s|%d|%s" % [nickname, half_length_s, player_id], base_url + "/rooms", body)

func join_room(code: String, nickname: String, player_id := "") -> Dictionary:
	var body := {"nickname": nickname}
	if player_id != "":
		body["player_id"] = player_id
	var url := "%s/rooms/%s/join" % [base_url, code.uri_encode()]
	return await _post_idempotent("join|%s|%s|%s" % [code, nickname, player_id], url, body)

func room_status(code: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "%s/rooms/%s" % [base_url, code.uri_encode()], null)

func recent_matches(limit := 8) -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "%s/matches/recent?limit=%d" % [stats_base_url(), limit], null)

func leaderboard(limit := 8) -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "%s/leaderboard?limit=%d" % [stats_base_url(), limit], null)

## A player-facing explanation of a failed reply.
static func describe(reply: Dictionary) -> String:
	match str(reply.get("error", "")):
		"room_not_found":
			return "No room with that code."
		"room_full":
			return "That room is full."
		"room_closed":
			return "That room is no longer open."
		"runtime_unavailable", "unavailable":
			return "The match server is unavailable. Try again in a moment."
		"invalid_request":
			return "Check the nickname (1-16 letters, digits, space, _ . -) and the room code."
		"network":
			return "Cannot reach the lobby. Check your connection."
		"busy":
			return "Still waiting for the previous request."
		"":
			return ""
	return "Lobby error: %s" % str(reply.get("message", reply.error))

static func new_request_id() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	return bytes.hex_encode()

func _post_idempotent(key: String, url: String, body: Dictionary) -> Dictionary:
	var request_id: String = _retry_ids.get(key, new_request_id())
	body["request_id"] = request_id
	var reply := await _request(HTTPClient.METHOD_POST, url, body)
	if reply.error in RETRYABLE:
		_retry_ids[key] = request_id
	elif reply.error != "busy":
		_retry_ids.erase(key)
	return reply

func _request(method: int, url: String, body) -> Dictionary:
	if _busy:
		return _reply(false, 0, "busy", "a request is in flight", {})
	var headers := PackedStringArray(["Accept: application/json"])
	var data := ""
	if body != null:
		headers.append("Content-Type: application/json")
		data = JSON.stringify(body)
	var err := _http.request(url, headers, method, data)
	if err != OK:
		return _reply(false, 0, "network", "could not start the request (%s)" % error_string(err), {})
	_busy = true
	var res: Array = await _http.request_completed
	_busy = false
	return parse_response(res[0], res[1], res[3])

## Turns an HTTPRequest completion into a reply (see the class doc).
static func parse_response(result: int, status: int, raw: PackedByteArray) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS:
		return _reply(false, 0, "network", "no response (HTTPRequest result %d)" % result, {})
	var text := raw.get_string_from_utf8()
	var parser := JSON.new()   # JSON.parse_string() would log every non-JSON answer as an engine error
	var parsed = parser.data if text != "" and parser.parse(text) == OK else null
	var json: Dictionary = parsed if parsed is Dictionary else {}
	if status >= 200 and status < 300:
		if parsed is Dictionary:
			return _reply(true, status, "", "", json)
		return _reply(false, status, "bad_response", "the answer was not a JSON object", {})
	if json.has("error"):
		var detail = json.get("detail", "")
		if detail is Array and not detail.is_empty() and detail[0] is Dictionary:
			detail = "%s: %s" % [detail[0].get("field", ""), detail[0].get("message", "")]
		return _reply(false, status, str(json.error), str(detail), json)
	if status in [502, 503, 504]:
		return _reply(false, status, "unavailable", "HTTP %d" % status, json)
	return _reply(false, status, "http_%d" % status, "HTTP %d" % status, json)

static func _reply(ok: bool, status: int, error: String, message: String, body: Dictionary) -> Dictionary:
	return {"ok": ok, "status": status, "error": error, "message": message, "body": body}
