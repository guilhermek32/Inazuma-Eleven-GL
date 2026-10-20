class_name MatchRoom
extends RefCounted

## One authoritative online match: a MatchSession driven by two remote players.
##
## Lifecycle: WAITING (until both team slots are attached, or the waiting
## deadline cancels it) -> RUNNING <-> PAUSED (a player dropped; the match
## freezes while anyone is away. Each absent team has its own deadline:
## RECONNECT_GRACE_MS of real time per absence, but at most
## MAX_TOTAL_PAUSE_MS of absence per team over the match, so repeated
## drop-and-reconnect can't stall it forever; the first team past its
## deadline forfeits) -> FINISHED (full time, forfeit or cancelled; the room lingers a
## moment so the final events reach the clients, then the runtime frees it).
##
## Each room tick: apply every team's RemoteInputQueue, step the session,
## broadcast its events, and send each attached peer a snapshot every
## SNAPSHOT_EVERY ticks. Resets (kickoff, restarts, half time) bump
## `state_epoch` and force an immediate snapshot flagged as a discontinuity,
## so clients snap instead of interpolating across the teleport.
##
## The room never touches sockets: it talks to the runtime through the two
## Callables it is given, send(peer_id, bytes, droppable) and
## close(peer_id, code, reason).
##
## A *provisioned* room (created by the lobby through the runtime's control
## API) also carries its credential expiry and the two team reservations
## {reservation_id, player_id, nickname}; HELLO credentials must match them.
## Development rooms (dev tokens, created on first use) have neither.

enum State { WAITING, RUNNING, PAUSED, FINISHED }

const TICK_RATE := 60
const SNAPSHOT_EVERY := 2
const RECONNECT_GRACE_MS := 30000
const MAX_TOTAL_PAUSE_MS := 60000
const WAITING_DEADLINE_MS := 300000
# Long enough for a stalled browser (software-rendered, a few fps) to read the
# final events before the close: native WebSocketPeer drops unread packets on close.
const FINISHED_LINGER_TICKS := 180
# Session events that teleport players or the ball.
const DISCONTINUOUS_EVENTS := ["field_reset", "restart", "half_time"]

# Deadlines (real time); tests shorten them.
var reconnect_grace_ms := RECONNECT_GRACE_MS
var max_total_pause_ms := MAX_TOTAL_PAUSE_MS
var waiting_deadline_ms := WAITING_DEADLINE_MS

var match_id: String
var config: MatchConfig
var session: MatchSession
var state := State.WAITING
var tick := 0
var state_epoch := 0
var result := {}
# Provisioning (see the header); unix seconds for the timestamps.
var provisioned := false
var expires_at := 0
var reservations: Array[Dictionary] = [{}, {}]
var created_unix := 0
var started_unix := 0
var finished_unix := 0
# Set by the runtime once the terminal state and result are durably recorded.
var recorded := false
# Per team: {peer: int (-1 = empty), epoch: int, queue: RemoteInputQueue}
var slots: Array[Dictionary] = []

var _send: Callable
var _close: Callable
var _event_seq := 0
var _discontinuity := true
var _created_ms := 0
# Per team: when its current absence started (0 = present) and the absence
# time already used in earlier pauses.
var _absent_since_ms: Array[int] = [0, 0]
var _paused_total_ms: Array[int] = [0, 0]
var _finished_ticks := 0

func _init(p_match_id: String, p_config: MatchConfig, seed_value: int, send: Callable, close: Callable) -> void:
	match_id = p_match_id
	config = p_config.copy()
	_send = send
	_close = close
	_created_ms = Time.get_ticks_msec()
	created_unix = int(Time.get_unix_time_from_system())
	session = MatchSession.new()
	for t in 2:
		session.set_team_device(t, GameConfig.DEVICE_REMOTE)
		slots.append({"peer": -1, "epoch": 0, "queue": RemoteInputQueue.new()})
	session.initialize(config, seed_value)
	session.drain_events()   # the initial field_reset predates every client

func dispose() -> void:
	session.dispose()

func team_of(peer_id: int) -> int:
	for t in 2:
		if slots[t].peer == peer_id:
			return t
	return -1

func is_attached(team: int) -> bool:
	return slots[team].peer >= 0

## Seats `peer_id` in `team`, replacing (and closing) any previous connection
## for that slot. Starts a new input epoch, sends WELCOME plus a full baseline
## snapshot, and kicks off / resumes once both slots are filled.
func attach(team: int, peer_id: int) -> int:
	var slot: Dictionary = slots[team]
	var previous: int = slot.peer
	slot.peer = peer_id
	slot.epoch = (int(slot.epoch) + 1) & 0xFFFF
	(slot.queue as RemoteInputQueue).reset(slot.epoch)
	if previous >= 0 and previous != peer_id:
		_close.call(previous, NetProtocol.CLOSE_REPLACED, "replaced by a newer connection")
	_send.call(peer_id, NetProtocol.encode_welcome(match_id, team, slot.epoch, TICK_RATE, SNAPSHOT_EVERY, 3, config), false)
	_send.call(peer_id, _snapshot_for(team, NetProtocol.SNAP_DISCONTINUITY), false)
	if is_attached(0) and is_attached(1):
		if state == State.WAITING:
			state = State.RUNNING
			started_unix = int(Time.get_unix_time_from_system())
			_broadcast_event({"type": "kickoff"})
		elif state == State.PAUSED:
			state = State.RUNNING
			_broadcast_event({"type": "resumed"})
	if _absent_since_ms[team] > 0:
		_paused_total_ms[team] += Time.get_ticks_msec() - _absent_since_ms[team]
		_absent_since_ms[team] = 0
	return slot.epoch

## The peer's connection ended. A running match pauses for the reconnect grace.
func detach(peer_id: int) -> void:
	var team := team_of(peer_id)
	if team < 0:
		return
	var slot: Dictionary = slots[team]
	slot.peer = -1
	(slot.queue as RemoteInputQueue).reset(slot.epoch)
	if state == State.RUNNING or state == State.PAUSED:
		state = State.PAUSED
		_absent_since_ms[team] = Time.get_ticks_msec()
		_broadcast_event({"type": "paused", "team": team, "grace_s": _grace_ms(team) / 1000.0})

## This team's grace for its current absence: the per-absence grace, capped by
## what is left of its total pause budget.
func _grace_ms(team: int) -> int:
	return clampi(max_total_pause_ms - _paused_total_ms[team], 0, reconnect_grace_ms)

func on_input(peer_id: int, frame: Dictionary) -> void:
	var team := team_of(peer_id)
	if team >= 0 and state != State.FINISHED:
		(slots[team].queue as RemoteInputQueue).push(frame, tick)

## Cancels a match that hasn't kicked off. Returns false once it has.
func cancel() -> bool:
	if state != State.WAITING:
		return false
	_finish("cancelled", -1)
	return true

func is_done() -> bool:
	return state == State.FINISHED and _finished_ticks > FINISHED_LINGER_TICKS

## One fixed tick of real time.
func step(dt: float) -> void:
	tick += 1
	var now := Time.get_ticks_msec()
	match state:
		State.WAITING:
			if now - _created_ms > waiting_deadline_ms:
				_finish("cancelled", -1)
		State.PAUSED:
			for t in 2:
				if _absent_since_ms[t] > 0 and now >= _absent_since_ms[t] + _grace_ms(t):
					# The other team wins if it is here; with both gone, nobody does.
					_finish("forfeit", (1 - t) if is_attached(1 - t) else -1)
					break
		State.RUNNING:
			for t in 2:
				(slots[t].queue as RemoteInputQueue).apply(session.sim.teams[t].input, tick)
			session.step(dt)
			for ev in session.drain_events():
				if ev.type in DISCONTINUOUS_EVENTS:
					state_epoch = (state_epoch + 1) & 0xFFFF
					_discontinuity = true
				if ev.type == "full_time":
					var winner := 0 if session.sim.score_left > session.sim.score_right else (1 if session.sim.score_right > session.sim.score_left else -1)
					_finish("full_time", winner)
				else:
					_broadcast_event(ev)
		State.FINISHED:
			_finished_ticks += 1
	if tick % SNAPSHOT_EVERY == 0 or _discontinuity:
		var flags := NetProtocol.SNAP_DISCONTINUITY if _discontinuity else 0
		_discontinuity = false
		for t in 2:
			if is_attached(t):
				_send.call(slots[t].peer, _snapshot_for(t, flags), flags == 0)

func _finish(reason: String, winner: int) -> void:
	if state == State.FINISHED:
		return
	state = State.FINISHED
	finished_unix = int(Time.get_unix_time_from_system())
	session.cancel_slow_motion()
	result = {"match_id": match_id, "reason": reason, "winner": winner,
			"score_left": session.sim.score_left, "score_right": session.sim.score_right,
			"stats": session.sim.stats.duplicate(true)}
	var ev := result.duplicate(true)
	ev.erase("match_id")
	ev["type"] = "match_over"
	_broadcast_event(ev)

func _snapshot_for(team: int, flags: int) -> PackedByteArray:
	var ack: int = maxi((slots[team].queue as RemoteInputQueue).last_seq, 0)
	return NetProtocol.encode_snapshot(NetProtocol.snapshot_from_session(session, tick, state_epoch, flags, ack, state))

func _broadcast_event(ev: Dictionary) -> void:
	_event_seq += 1
	var bytes := NetProtocol.encode_event(tick, _event_seq, ev)
	for t in 2:
		if is_attached(t):
			_send.call(slots[t].peer, bytes, false)
