class_name BotSession
extends RefCounted

## One AI opponent playing one online match: a NetClient connected to the
## match runtime with the lobby-issued credential of its team, a mirror
## MatchSimulation rebuilt from the newest (undelayed) snapshot as its
## observation, and a BotBrain turning that into input every physics tick.
## The runtime cannot tell it from a browser.
##
## Job states (BotService exposes them through the job API):
##   accepted  created, connecting; must be welcomed within join_deadline_ms
##   joined    WELCOME received: the bot holds its team slot
##   playing   the match kicked off (kickoff / resumed, or a running snapshot)
##   stopped   the match ended (match_over / close 4410) or stop() was called
##   failed    join deadline missed, credential refused (4401/4404), slot
##             taken by another connection (4409), or the connection stayed
##             lost for longer than RECONNECT_WINDOW_MS
## A dropped connection after joining is retried with backoff inside the
## runtime's 30 s reconnect grace; the reconnect is a new input epoch.
##
## Owner calls poll(now_ms) every frame (network, deadlines) and
## tick(dt, now_ms) every physics tick (observe -> decide -> send).
## Decisions are logged as one-line JSON "bot_decision", sampled: at most one
## per DECISION_LOG_INTERVAL_MS, carrying how many were not logged since.

enum State { ACCEPTED, JOINED, PLAYING, STOPPED, FAILED }

const STATE_NAMES := ["accepted", "joined", "playing", "stopped", "failed"]
const JOIN_DEADLINE_MS := 10000
const RECONNECT_WINDOW_MS := 20000
const RECONNECT_BACKOFF_MS := [500, 1000, 2000, 4000]
const DECISION_LOG_INTERVAL_MS := 500
const FATAL_CLOSE := {NetProtocol.CLOSE_UNAUTHORIZED: "credential refused",
		NetProtocol.CLOSE_UNKNOWN_MATCH: "unknown match", NetProtocol.CLOSE_REPLACED: "slot taken by another connection"}

var match_id := ""
var ws_url := ""
var token := ""
var difficulty := "normal"
var team := -1
var state := State.ACCEPTED
var reason := ""
var join_deadline_ms := JOIN_DEADLINE_MS
var log_decisions := true
var net: NetClient
var brain: BotBrain
var mirror: MatchSession
var created_ms := 0
var ended_ms := 0
var created_unix := 0
var joined_unix := 0
var counters := {"inputs": 0, "decisions": 0, "logged": 0, "shoot": 0, "pass": 0, "tackle": 0, "switch": 0, "reconnects": 0}

var _mirror_half := 1
var _last_obs_tick := -1
var _lost_since_ms := 0     # first loss since the last WELCOME (0 = connected)
var _reconnect_at_ms := 0   # > 0 while a reconnect is scheduled
var _attempt := 0
var _last_log_ms := -DECISION_LOG_INTERVAL_MS
var _unlogged := 0

func _init(p_match_id: String, p_ws_url: String, p_token: String, p_difficulty: String) -> void:
	match_id = p_match_id
	ws_url = p_ws_url
	token = p_token
	difficulty = p_difficulty

func start(now_ms: int) -> void:
	created_ms = now_ms
	created_unix = int(Time.get_unix_time_from_system())
	_connect()

func state_name() -> String:
	return STATE_NAMES[state]

func is_active() -> bool:
	return state == State.ACCEPTED or state == State.JOINED or state == State.PLAYING

## Ends the session (job DELETE, service shutdown). No-op once terminal.
func stop(why := "stopped") -> void:
	if not is_active():
		return
	_end(State.STOPPED, why)

func dispose() -> void:
	if net != null:
		net.close()
	if mirror != null:
		mirror.dispose()
		mirror = null

func status() -> Dictionary:
	return {"match_id": match_id, "state": state_name(), "reason": reason, "difficulty": difficulty, "team": team,
			"created_at": _iso(created_unix), "joined_at": _iso(joined_unix) if joined_unix > 0 else null,
			"counters": counters.duplicate()}

func poll(now_ms: int) -> void:
	if not is_active():
		return
	if net != null:
		net.poll(now_ms)
	if not is_active():
		return
	if state == State.ACCEPTED and now_ms - created_ms > join_deadline_ms:
		_end(State.FAILED, "join_timeout")
		return
	if _reconnect_at_ms > 0 and now_ms >= _reconnect_at_ms:
		if state != State.ACCEPTED and now_ms - _lost_since_ms > RECONNECT_WINDOW_MS:
			_end(State.FAILED, "connection_lost")
			return
		counters.reconnects += 1
		_connect()

func tick(dt: float, now_ms: int) -> void:
	if (state != State.JOINED and state != State.PLAYING) or net == null or not net.is_ready() or mirror == null:
		return
	var snap := net.latest_snapshot
	if snap.is_empty():
		return
	if int(snap.tick) != _last_obs_tick:
		_last_obs_tick = int(snap.tick)
		observe(mirror.sim, snap)
		if state == State.JOINED and int(snap.room_state) == MatchRoom.State.RUNNING:
			_set_state(State.PLAYING, "")
	var playing := int(snap.room_state) == MatchRoom.State.RUNNING and int(snap.phase) == MatchSession.Phase.PLAYING \
			and float(snap.restart_timer) <= 0.0
	var input := brain.step(mirror.sim, playing, dt)
	net.send_input(input)
	counters.inputs += 1
	if brain.decision_fresh:
		_on_decision(snap, now_ms)

## Writes snapshot `snap` into the observation sim `sim` (never stepped). The
## snapshot carries no sides, so the ends are switched here when the half
## changes; stun and tackle state come from the player flags.
func observe(sim: MatchSimulation, snap: Dictionary) -> void:
	var half := int(snap.half)
	if (half == 2) != (_mirror_half == 2):
		sim.switch_ends()
	_mirror_half = half
	SnapshotBuffer.apply_to(sim, snap, snap, 0.0)
	for t in 2:
		var players := sim.teams[t].players
		var wire: Array = snap.teams[t].players
		for i in mini(players.size(), wire.size()):
			var flags := int(wire[i].flags)
			players[i].stun_timer = 0.1 if flags & NetProtocol.PLAYER_STUNNED else 0.0
			players[i].tackle_timer = 0.1 if flags & NetProtocol.PLAYER_TACKLING else 0.0

func _connect() -> void:
	_reconnect_at_ms = 0
	if net != null:
		net.close()
	net = NetClient.new()
	net.welcomed.connect(_on_welcomed)
	net.closed.connect(_on_closed)
	net.event_received.connect(_on_event)
	if net.connect_to(ws_url, token) != OK:
		_on_closed(0, "could not connect")

func _on_welcomed() -> void:
	_attempt = 0
	_lost_since_ms = 0
	if mirror == null:
		team = net.team
		mirror = MatchSession.new()
		for t in 2:
			mirror.set_team_device(t, GameConfig.DEVICE_REMOTE)
		mirror.initialize(net.config, 0)
		mirror.drain_events()
		brain = BotBrain.new(difficulty, team, hash(match_id))
	_mirror_half = 1
	mirror.sim.set_default_ends()
	_last_obs_tick = -1
	if state == State.ACCEPTED:
		joined_unix = int(Time.get_unix_time_from_system())
		_set_state(State.JOINED, "")
	else:
		BotService.log_event("bot_reconnected", {"match_id": match_id, "team": team, "epoch": net.epoch})

func _on_event(_tick: int, ev: Dictionary) -> void:
	match str(ev.type):
		"kickoff", "resumed":
			if state == State.JOINED:
				_set_state(State.PLAYING, "")
		"match_over":
			BotService.log_event("bot_match_over", {"match_id": match_id, "team": team, "reason": ev.get("reason", ""),
					"score": [ev.get("score_left", 0), ev.get("score_right", 0)], "counters": counters})
			_end(State.STOPPED, "match_over:%s" % ev.get("reason", ""))

func _on_closed(code: int, why: String) -> void:
	if not is_active():
		return
	if code == NetProtocol.CLOSE_MATCH_OVER:
		_end(State.STOPPED, "match_over")
		return
	if FATAL_CLOSE.has(code):
		_end(State.FAILED, "%s (%d)" % [FATAL_CLOSE[code], code])
		return
	# Transient: retry with backoff (before joining, until the join deadline).
	var now := Time.get_ticks_msec()
	if _lost_since_ms == 0:
		_lost_since_ms = now
	_reconnect_at_ms = now + int(RECONNECT_BACKOFF_MS[mini(_attempt, RECONNECT_BACKOFF_MS.size() - 1)])
	_attempt += 1
	BotService.log_event("bot_connection_lost", {"match_id": match_id, "code": code, "reason": why, "attempt": _attempt})

func _on_decision(snap: Dictionary, now_ms: int) -> void:
	counters.decisions += 1
	var d := brain.decision
	if d.action != "":
		counters[d.action] = int(counters.get(d.action, 0)) + 1
	if not log_decisions or now_ms - _last_log_ms < DECISION_LOG_INTERVAL_MS:
		_unlogged += 1
		return
	_last_log_ms = now_ms
	counters.logged += 1
	BotService.log_event("bot_decision", {"match_id": match_id, "team": team, "difficulty": difficulty,
			"match_time": snappedf(float(snap.match_time), 0.1), "half": int(snap.half),
			"score": [int(snap.score_left), int(snap.score_right)], "intent": d.intent, "action": d.action,
			"reason": d.reason, "player": d.player, "features": d.features, "unlogged": _unlogged})
	_unlogged = 0

func _set_state(s: State, why: String) -> void:
	state = s
	reason = why
	BotService.log_event("bot_state", {"match_id": match_id, "state": state_name(), "reason": why, "team": team})

func _end(s: State, why: String) -> void:
	ended_ms = Time.get_ticks_msec()
	_reconnect_at_ms = 0
	_set_state(s, why)
	if net != null:
		net.close()

static func _iso(unix: int) -> String:
	return Time.get_datetime_string_from_unix_time(unix) + "Z"
