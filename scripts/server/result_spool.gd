class_name ResultSpool
extends RefCounted

## Durable, at-least-once delivery of finished-match results to the results
## service. The runtime writes each result here (atomically: temp file +
## rename) before it frees the room; poll() then delivers pending files in
## the background, one request at a time, never blocking the caller.
##
## Delivery: POST <results_url>/internal/v1/matches with the file's exact
## bytes, "Authorization: Bearer <ingest_token>". The results service is
## idempotent by match_id (an identical resubmission is acknowledged), so a
## retry after an unseen acknowledgement is harmless.
##   2xx               delivered: the file is deleted.
##   409, 400, 422     permanently refused (conflicting duplicate or invalid):
##                     the file moves to <dir>/rejected/ and is never retried.
##   anything else     (network error, timeout, 401/403/429/5xx) retried with
##                     exponential backoff from backoff_base_ms, capped at
##                     backoff_max_ms, plus up to 25% jitter.
## Pending files found in <dir> at open() (a restart) are queued again.

const REQUEST_TIMEOUT_MS := 10000
const BACKOFF_BASE_MS := 1000
const BACKOFF_MAX_MS := 60000
const MAX_RESPONSE_BYTES := 16384
const INGEST_PATH := "/internal/v1/matches"
const PERMANENT_FAILURES := [400, 409, 422]

var dir := ""
var results_url := ""
var ingest_token := ""
var backoff_base_ms := BACKOFF_BASE_MS
var backoff_max_ms := BACKOFF_MAX_MS
var delivered_count := 0
var rejected_count := 0

var _pending := {}   # match_id -> {attempts: int, next_ms: int}
var _inflight := {}  # {match_id, http: HTTPClient, phase, started_ms, code, body}
var _host := ""
var _port := 0
var _tls := false
var _base_path := ""

func open(spool_dir: String, now_ms: int = Time.get_ticks_msec()) -> Error:
	dir = spool_dir
	var err := DirAccess.make_dir_recursive_absolute(dir.path_join("rejected"))
	if err != OK:
		return err
	_pending.clear()
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".json.tmp"):
			DirAccess.remove_absolute(dir.path_join(file))   # torn write from a crash: never acknowledged
		elif file.ends_with(".json"):
			_pending[file.get_basename()] = {"attempts": 0, "next_ms": now_ms}
	if not _pending.is_empty():
		MatchRuntime.log_event("result_spool_recovered", {"pending": _pending.size()})
	return OK

## Sets the delivery target ("http(s)://host[:port][/base]"); "" disables delivery.
func configure(url: String, token: String) -> bool:
	results_url = url
	ingest_token = token
	_host = ""
	if url == "":
		return true
	var re := RegEx.create_from_string("^(https?)://([^/:]+)(?::(\\d+))?(/.*)?$")
	var m := re.search(url)
	if m == null:
		MatchRuntime.log_event("results_url_invalid", {"url": url})
		return false
	_tls = m.get_string(1) == "https"
	_host = m.get_string(2)
	_port = int(m.get_string(3)) if m.get_string(3) != "" else (443 if _tls else 80)
	_base_path = m.get_string(4).trim_suffix("/")
	return true

func pending_ids() -> Array:
	return _pending.keys()

func is_pending(match_id: String) -> bool:
	return _pending.has(match_id)

func file_path(match_id: String) -> String:
	return dir.path_join(match_id + ".json")

func rejected_path(match_id: String) -> String:
	return dir.path_join("rejected").path_join(match_id + ".json")

## Durably records a result and queues it for delivery.
func write(result: Dictionary, now_ms: int = Time.get_ticks_msec()) -> Error:
	var match_id := str(result.match_id)
	var err := TerminalRegistry.write_atomic(file_path(match_id), JSON.stringify(result))
	if err != OK:
		MatchRuntime.log_event("result_spool_write_failed", {"match_id": match_id, "error": error_string(err)})
		return err
	_pending[match_id] = {"attempts": 0, "next_ms": now_ms}
	MatchRuntime.log_event("result_spooled", {"match_id": match_id})
	return OK

## Advances the in-flight delivery or starts the next due one.
func poll(now_ms: int = Time.get_ticks_msec()) -> void:
	if not _inflight.is_empty():
		_advance(now_ms)
		return
	if _host == "" or _pending.is_empty():
		return
	for match_id in _pending:
		if int(_pending[match_id].next_ms) <= now_ms:
			_start(match_id, now_ms)
			return

func _start(match_id: String, now_ms: int) -> void:
	if not FileAccess.file_exists(file_path(match_id)):
		_pending.erase(match_id)
		return
	var http := HTTPClient.new()
	var err := http.connect_to_host(_host, _port, TLSOptions.client() if _tls else null)
	_inflight = {"match_id": match_id, "http": http, "phase": "connecting", "started_ms": now_ms,
			"code": 0, "body": PackedByteArray()}
	if err != OK:
		_finish(-1, now_ms, "connect: " + error_string(err))

func _advance(now_ms: int) -> void:
	var http: HTTPClient = _inflight.http
	if now_ms - int(_inflight.started_ms) > REQUEST_TIMEOUT_MS:
		_finish(-1, now_ms, "timeout")
		return
	http.poll()
	var status := http.get_status()
	match _inflight.phase:
		"connecting":
			if status == HTTPClient.STATUS_CONNECTED:
				var body := FileAccess.get_file_as_string(file_path(_inflight.match_id))
				var headers := PackedStringArray(["Content-Type: application/json",
						"Authorization: Bearer %s" % ingest_token])
				var err := http.request(HTTPClient.METHOD_POST, _base_path + INGEST_PATH, headers, body)
				if err != OK:
					_finish(-1, now_ms, "request: " + error_string(err))
					return
				_inflight.phase = "requesting"
			elif status != HTTPClient.STATUS_RESOLVING and status != HTTPClient.STATUS_CONNECTING:
				_finish(-1, now_ms, "connection status %d" % status)
		"requesting", "body":
			if status == HTTPClient.STATUS_REQUESTING:
				return
			if status == HTTPClient.STATUS_BODY:
				_inflight.code = http.get_response_code()
				_inflight.phase = "body"
				var chunk := http.read_response_body_chunk()
				var body: PackedByteArray = _inflight.body   # packed arrays are values: copy, append, store back
				if body.size() + chunk.size() <= MAX_RESPONSE_BYTES:
					body.append_array(chunk)
					_inflight.body = body
			elif _inflight.phase == "body":
				_finish(int(_inflight.code), now_ms, "")
			elif http.has_response():
				_finish(http.get_response_code(), now_ms, "")
			else:
				_finish(-1, now_ms, "connection status %d" % status)

func _finish(code: int, now_ms: int, error: String) -> void:
	var match_id: String = _inflight.match_id
	var reply := (_inflight.body as PackedByteArray).get_string_from_utf8()
	(_inflight.http as HTTPClient).close()
	_inflight = {}
	if code >= 200 and code < 300:
		DirAccess.remove_absolute(file_path(match_id))
		_pending.erase(match_id)
		delivered_count += 1
		MatchRuntime.log_event("result_delivered", {"match_id": match_id, "status": code})
		return
	if code in PERMANENT_FAILURES:
		DirAccess.rename_absolute(file_path(match_id), rejected_path(match_id))
		_pending.erase(match_id)
		rejected_count += 1
		MatchRuntime.log_event("result_rejected", {"match_id": match_id, "status": code, "reply": reply.left(300)})
		return
	var entry: Dictionary = _pending.get(match_id, {"attempts": 0})
	entry.attempts = int(entry.attempts) + 1
	var delay := mini(backoff_base_ms * (1 << mini(int(entry.attempts) - 1, 20)), backoff_max_ms)
	delay += randi_range(0, delay / 4)
	entry.next_ms = now_ms + delay
	_pending[match_id] = entry
	MatchRuntime.log_event("result_delivery_failed", {"match_id": match_id, "status": code, "error": error,
			"attempt": entry.attempts, "retry_in_ms": delay})
