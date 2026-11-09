class_name BotService
extends Node

## The ai-bot service: one process hosting up to `max_sessions` concurrent
## BotSessions (one per vs-AI match), driven through an internal job API
## (BotJobApi on a ControlServer). Polls the network and job deadlines each
## frame and ticks every live session on the fixed physics step.
##
## Jobs are keyed by match_id. A finished job (stopped/failed) stays readable
## for `retention_ms`, so the lobby can still learn why it ended, and is then
## forgotten. Logs are one JSON object per line on stdout ("svc": "ai-bot").

const DEFAULT_CONTROL_PORT := 8920
const MAX_SESSIONS := 8
const RETENTION_MS := 600000

var max_sessions := MAX_SESSIONS
var join_deadline_ms := BotSession.JOIN_DEADLINE_MS
var retention_ms := RETENTION_MS
var log_decisions := true
## Random UUID per process start (reported by /health).
var boot_id := MatchRuntime.new_uuid()
var control: ControlServer
var api: BotJobApi

var _jobs := {}   # match_id -> BotSession

func start_control(port: int, bind_address := "*", token := "") -> Error:
	api = BotJobApi.new(self, token)
	control = ControlServer.new()
	control.handler = api.handle
	var err := control.listen(port, bind_address)
	log_event("control_listening" if err == OK else "control_listen_failed", {"port": port, "auth": token != ""})
	return err

func stop() -> void:
	for job in _jobs.values():
		(job as BotSession).stop("service stopping")
		(job as BotSession).dispose()
	_jobs.clear()
	if control != null:
		control.stop()

func job(match_id: String) -> BotSession:
	return _jobs.get(match_id)

func jobs() -> Dictionary:
	return _jobs

func active_count() -> int:
	var n := 0
	for job in _jobs.values():
		if (job as BotSession).is_active():
			n += 1
	return n

## Starts a session, or returns the existing one for `match_id`. Returns
## {"status": 201 new | 200 same request | 409 different request | 503 full,
##  "job": BotSession or null}. The caller has validated the fields.
func submit(match_id: String, ws_url: String, token: String, difficulty: String) -> Dictionary:
	var existing: BotSession = _jobs.get(match_id)
	if existing != null:
		var same := existing.ws_url == ws_url and existing.token == token and existing.difficulty == difficulty
		return {"status": 200 if same else 409, "job": existing}
	if active_count() >= max_sessions:
		log_event("bot_refused", {"match_id": match_id, "reason": "capacity", "active": active_count()})
		return {"status": 503, "job": null}
	var s := BotSession.new(match_id, ws_url, token, difficulty)
	s.join_deadline_ms = join_deadline_ms
	s.log_decisions = log_decisions
	_jobs[match_id] = s
	log_event("bot_accepted", {"match_id": match_id, "difficulty": difficulty, "ws_url": ws_url})
	s.start(Time.get_ticks_msec())
	return {"status": 201, "job": s}

## Stops the job's session (kept readable as stopped). Null when unknown.
func stop_job(match_id: String) -> BotSession:
	var s: BotSession = _jobs.get(match_id)
	if s != null:
		s.stop("stopped by request")
	return s

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if control != null:
		control.poll(now)
	for match_id in _jobs.keys():
		var s: BotSession = _jobs[match_id]
		s.poll(now)
		if not s.is_active() and now - s.ended_ms > retention_ms:
			s.dispose()
			_jobs.erase(match_id)

func _physics_process(delta: float) -> void:
	var now := Time.get_ticks_msec()
	for s in _jobs.values():
		(s as BotSession).tick(delta, now)

static func log_event(event: String, fields := {}) -> void:
	var line := {"ts": Time.get_datetime_string_from_system(true), "svc": "ai-bot", "event": event}
	line.merge(fields)
	print(JSON.stringify(line))
