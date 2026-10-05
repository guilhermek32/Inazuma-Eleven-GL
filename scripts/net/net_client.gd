class_name NetClient
extends RefCounted

## Client end of the match protocol (browser, desktop or bot). Call poll()
## every frame and send_input() every physics tick.
##
## Connects, sends HELLO with the credential, and on WELCOME learns its team,
## connection epoch and the match's MatchConfig. Snapshots and events go into
## `buffer` (a SnapshotBuffer) for interpolated rendering; `latest_snapshot`
## is the newest one, undelayed, for observers that need fresh state (the bot).
##
## Input: send_input() turns the local InputSnapshot's edges into numbered
## actions (pass, switch, tackle, shoot start, shoot release + its aim) and
## sends them with the held state in one INPUT frame per tick. The runtime
## de-duplicates and orders them (see RemoteInputQueue). A reconnect is a new
## epoch: nothing queued under the previous connection is replayed.

signal welcomed
signal closed(code: int, reason: String)
# Raised as each EVENT arrives (undelayed); rendering uses buffer.take_due_events().
signal event_received(tick: int, event: Dictionary)

enum Status { IDLE, CONNECTING, AWAITING_WELCOME, READY, CLOSED }

const PING_INTERVAL_MS := 1000

var status := Status.IDLE
var match_id := ""
var team := -1
var epoch := 0
var config: MatchConfig
var human_mask := 0
var tick_rate := 60
var buffer := SnapshotBuffer.new()
var latest_snapshot := {}
var rtt_ms := -1.0
var last_error := {}
var close_code := 0

var _ws := WebSocketPeer.new()
var _token := ""
var _seq := 0
var _next_action_id := 1
var _last_ping_ms := 0

func connect_to(url: String, token: String) -> Error:
	_token = token
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 1 << 18
	var err := _ws.connect_to_url(url)
	status = Status.CONNECTING if err == OK else Status.CLOSED
	return err

func close(code := 1000, reason := "") -> void:
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN or _ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		_ws.close(code, reason)

func is_ready() -> bool:
	return status == Status.READY

func poll(now_ms: float = Time.get_ticks_msec()) -> void:
	if status == Status.IDLE or status == Status.CLOSED:
		return
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN and status == Status.CONNECTING:
		_ws.send(NetProtocol.encode_hello(_token))
		status = Status.AWAITING_WELCOME
	# Drain in every state: a slow client can receive the final events, the
	# ERROR and the close in one frame, and must still see those events.
	while _ws.get_available_packet_count() > 0:
		_on_packet(_ws.get_packet(), now_ms)
		if status == Status.CLOSED:
			return
	match state:
		WebSocketPeer.STATE_OPEN:
			if status == Status.READY and now_ms - _last_ping_ms > PING_INTERVAL_MS:
				_last_ping_ms = int(now_ms)
				_ws.send(NetProtocol.encode_ping(now_ms))
		WebSocketPeer.STATE_CLOSED:
			status = Status.CLOSED
			close_code = _ws.get_close_code()
			var reason: String = last_error.get("message", _ws.get_close_reason())
			closed.emit(close_code, reason)

func _on_packet(bytes: PackedByteArray, now_ms: float) -> void:
	var msg := NetProtocol.decode(bytes)
	if msg.is_empty():
		return
	match msg.type:
		NetProtocol.Type.WELCOME:
			match_id = msg.match_id
			team = msg.team
			epoch = msg.epoch
			tick_rate = msg.tick_rate
			human_mask = msg.human_mask
			config = msg.config
			buffer.clear()
			buffer.tick_rate = float(tick_rate)
			latest_snapshot = {}
			status = Status.READY
			welcomed.emit()
		NetProtocol.Type.SNAPSHOT:
			latest_snapshot = msg
			buffer.push_snapshot(msg, now_ms)
		NetProtocol.Type.EVENT:
			buffer.push_event(msg.tick, msg.event)
			event_received.emit(msg.tick, msg.event)
		NetProtocol.Type.PONG:
			rtt_ms = now_ms - float(msg.client_ms)
		NetProtocol.Type.ERROR:
			last_error = msg

## Sends this tick's input for our team.
func send_input(snap: InputSnapshot) -> void:
	if status != Status.READY:
		return
	var aim_mode := NetProtocol.AIM_POINT if snap.aim_absolute else (NetProtocol.AIM_DIR if snap.aim_vec != Vector2.ZERO else NetProtocol.AIM_NONE)
	var actions := []
	if snap.pass_pressed:
		actions.append(_action(NetProtocol.Action.PASS, aim_mode, snap.aim_vec))
	if snap.switch_pressed:
		actions.append(_action(NetProtocol.Action.SWITCH, aim_mode, snap.aim_vec))
	if snap.tackle_pressed:
		actions.append(_action(NetProtocol.Action.TACKLE, aim_mode, snap.aim_vec))
	if snap.shoot_held and not snap.shoot_prev:
		actions.append(_action(NetProtocol.Action.SHOOT_START, aim_mode, snap.aim_vec))
	if snap.shoot_prev and not snap.shoot_held:
		actions.append(_action(NetProtocol.Action.SHOOT_RELEASE, aim_mode, snap.aim_vec))
	send_frame(snap.axis, snap.sprint_held, snap.shoot_held, aim_mode, snap.aim_vec, actions)

## Lower-level send used by send_input() and by tests/bots that script inputs.
func send_frame(axis: Vector2, sprint: bool, shoot: bool, aim_mode: int, aim: Vector2, actions: Array) -> void:
	if status != Status.READY:
		return
	_seq += 1
	_ws.send(NetProtocol.encode_input({"epoch": epoch, "seq": _seq, "axis": axis, "sprint": sprint,
			"shoot": shoot, "aim_mode": aim_mode, "aim": aim, "actions": actions}))

func new_action(kind: int, aim_mode := NetProtocol.AIM_NONE, aim := Vector2.ZERO) -> Dictionary:
	return _action(kind, aim_mode, aim)

func _action(kind: int, aim_mode: int, aim: Vector2) -> Dictionary:
	var a := {"id": _next_action_id, "kind": kind, "aim_mode": aim_mode, "aim": aim}
	_next_action_id += 1
	return a
