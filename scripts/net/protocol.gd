class_name NetProtocol
extends RefCounted

## Wire protocol between browser/bot clients and the match runtime, version 1.
##
## Every message is one binary WebSocket frame: u8 protocol version, u8 type,
## then the type's payload. All integers are little-endian. Decoders never
## trust the input: they return {} for anything truncated, oversized, out of
## range or of an unknown version/type, and the runtime closes the connection
## with CLOSE_BAD_MESSAGE.
##
## Client -> runtime
##   HELLO   token: str16
##   INPUT   epoch u16, seq u32, axis i8 x2, held u8 (HELD_*), aim (AIM),
##           n u8 (<= MAX_ACTIONS), n x {action_id u32, kind u8 (ACTION_*), aim (AIM)}
##   PING    client_ms f64
## Runtime -> client
##   WELCOME match_id str16, team u8, epoch u16, tick_rate u8, snapshot_every u8,
##           human_mask u8, config str16 (MatchConfig.to_dict() as JSON)
##   SNAPSHOT  see encode_snapshot()
##   EVENT   tick u32, seq u32, type str16, payload str16 (JSON, see event_to_wire)
##   PONG    client_ms f64, tick u32
##   ERROR   code u16, message str16 (the connection closes right after)
##
## AIM = mode u8 (AIM_NONE / AIM_POINT field point / AIM_DIR direction), i16 x2.
## str16 = u16 byte length + UTF-8 bytes.
##
## Quantization: positions and aim points i16 at POS_SCALE (+-1.09 field units),
## velocities i16 at VEL_SCALE (+-4.09/s), ball height u16 in milli-world-units,
## unit directions/axes i8 at 127, fractions u8 at 255.

const VERSION := 1
const MAX_MESSAGE_BYTES := 4096   # inbound limit, enforced by the runtime

enum Type { HELLO = 1, WELCOME = 2, INPUT = 3, SNAPSHOT = 4, EVENT = 5, PING = 6, PONG = 7, ERROR = 8 }

const HELD_SPRINT := 1
const HELD_SHOOT := 2

enum Action { PASS = 1, SWITCH = 2, TACKLE = 3, SHOOT_START = 4, SHOOT_RELEASE = 5 }
const MAX_ACTIONS := 8

const AIM_NONE := 0
const AIM_POINT := 1
const AIM_DIR := 2

const POS_SCALE := 30000.0
const VEL_SCALE := 8000.0
const H_SCALE := 1000.0

const SNAP_DISCONTINUITY := 1
const PLAYER_MOVING := 1
const PLAYER_STUNNED := 2
const PLAYER_TACKLING := 4

# WebSocket close codes (application range).
const CLOSE_BAD_MESSAGE := 4400
const CLOSE_UNAUTHORIZED := 4401
const CLOSE_BAD_PATH := 4404
const CLOSE_HELLO_TIMEOUT := 4408
const CLOSE_REPLACED := 4409
const CLOSE_MATCH_OVER := 4410
const CLOSE_TOO_SLOW := 4429

# --- encoders -------------------------------------------------------------------

static func encode_hello(token: String) -> PackedByteArray:
	var w := _writer(Type.HELLO)
	_put_str(w, token)
	return w.data_array

static func encode_welcome(match_id: String, team: int, epoch: int, tick_rate: int, snapshot_every: int, human_mask: int, config: MatchConfig) -> PackedByteArray:
	var w := _writer(Type.WELCOME)
	_put_str(w, match_id)
	w.put_u8(team)
	w.put_u16(epoch)
	w.put_u8(tick_rate)
	w.put_u8(snapshot_every)
	w.put_u8(human_mask)
	_put_str(w, JSON.stringify(config.to_dict()))
	return w.data_array

## `frame` = {epoch, seq, axis: Vector2, sprint, shoot: bool, aim_mode, aim: Vector2,
##            actions: [{id, kind, aim_mode, aim}]}
static func encode_input(frame: Dictionary) -> PackedByteArray:
	var w := _writer(Type.INPUT)
	w.put_u16(int(frame.epoch) & 0xFFFF)
	w.put_u32(int(frame.seq))
	var axis: Vector2 = frame.axis
	w.put_8(_unit_i8(axis.x))
	w.put_8(_unit_i8(axis.y))
	var held := (HELD_SPRINT if frame.sprint else 0) | (HELD_SHOOT if frame.shoot else 0)
	w.put_u8(held)
	_put_aim(w, frame.aim_mode, frame.aim)
	var actions: Array = frame.actions
	w.put_u8(mini(actions.size(), MAX_ACTIONS))
	for i in mini(actions.size(), MAX_ACTIONS):
		var a: Dictionary = actions[i]
		w.put_u32(int(a.id))
		w.put_u8(int(a.kind))
		_put_aim(w, a.aim_mode, a.aim)
	return w.data_array

static func encode_ping(client_ms: float) -> PackedByteArray:
	var w := _writer(Type.PING)
	w.put_double(client_ms)
	return w.data_array

static func encode_pong(client_ms: float, tick: int) -> PackedByteArray:
	var w := _writer(Type.PONG)
	w.put_double(client_ms)
	w.put_u32(tick)
	return w.data_array

static func encode_error(code: int, message: String) -> PackedByteArray:
	var w := _writer(Type.ERROR)
	w.put_u16(code)
	_put_str(w, message)
	return w.data_array

static func encode_event(tick: int, seq: int, event: Dictionary) -> PackedByteArray:
	var w := _writer(Type.EVENT)
	w.put_u32(tick)
	w.put_u32(seq)
	var payload := event_to_wire(event)
	_put_str(w, str(event.type))
	_put_str(w, JSON.stringify(payload))
	return w.data_array

## Snapshot of everything a client renders and a bot observes:
##   tick u32, state_epoch u16, flags u8, ack_seq u32,
##   room_state u8, phase u8, half u8, match_time f32, score u8 x2,
##   restart_type u8, restart_timer f32, time_scale u8 (x100),
##   ball: x i16, y i16, h u16, vx i16, vy i16, spin f32, owner_team i8,
##         owner_index i8, charge u8, special i8, super u8
##   per team: selected i8, candidate i8, n u8, n x player:
##         x i16, y i16, vx i16, vy i16, facing i8 x2, flags u8,
##         kick_power u8, stamina u8, dive_timer u8 (x100), dive_dir i8
static func encode_snapshot(s: Dictionary) -> PackedByteArray:
	var w := _writer(Type.SNAPSHOT)
	w.put_u32(int(s.tick))
	w.put_u16(int(s.state_epoch) & 0xFFFF)
	w.put_u8(int(s.flags))
	w.put_u32(int(s.ack_seq))
	w.put_u8(int(s.room_state))
	w.put_u8(int(s.phase))
	w.put_u8(int(s.half))
	w.put_float(float(s.match_time))
	w.put_u8(clampi(int(s.score_left), 0, 255))
	w.put_u8(clampi(int(s.score_right), 0, 255))
	w.put_u8(int(s.restart_type))
	w.put_float(float(s.restart_timer))
	w.put_u8(clampi(roundi(float(s.time_scale) * 100.0), 0, 255))
	var b: Dictionary = s.ball
	w.put_16(_pos_i16(b.x))
	w.put_16(_pos_i16(b.y))
	w.put_u16(clampi(roundi(float(b.h) * H_SCALE), 0, 65535))
	w.put_16(_vel_i16(b.vx))
	w.put_16(_vel_i16(b.vy))
	w.put_float(float(b.spin))
	w.put_8(int(b.owner_team))
	w.put_8(int(b.owner_index))
	w.put_u8(_frac_u8(b.charge))
	w.put_8(int(b.special))
	w.put_u8(1 if b.super else 0)
	for t in 2:
		var team: Dictionary = s.teams[t]
		w.put_8(int(team.selected))
		w.put_8(int(team.candidate))
		var players: Array = team.players
		w.put_u8(players.size())
		for p in players:
			w.put_16(_pos_i16(p.x))
			w.put_16(_pos_i16(p.y))
			w.put_16(_vel_i16(p.vx))
			w.put_16(_vel_i16(p.vy))
			w.put_8(_unit_i8(p.fx))
			w.put_8(_unit_i8(p.fy))
			w.put_u8(int(p.flags))
			w.put_u8(_frac_u8(p.kick_power))
			w.put_u8(_frac_u8(p.stamina))
			w.put_u8(clampi(roundi(float(p.dive_timer) * 100.0), 0, 255))
			w.put_8(int(p.dive_dir))
	return w.data_array

## Builds the snapshot Dictionary from a live session (runtime side).
static func snapshot_from_session(session: MatchSession, tick: int, state_epoch: int, flags: int, ack_seq: int, room_state: int) -> Dictionary:
	var sim := session.sim
	var special := -1
	if sim.ball.special_name != "":
		for i in GameConfig.SPECIAL_SHOTS.size():
			if GameConfig.SPECIAL_SHOTS[i].name == sim.ball.special_name:
				special = i
	var teams := []
	for ts in sim.teams:
		var players := []
		for p in ts.players:
			var pflags := (PLAYER_MOVING if p.is_moving else 0) | (PLAYER_STUNNED if p.stun_timer > 0.0 else 0) \
					| (PLAYER_TACKLING if p.tackle_timer > 0.0 else 0)
			players.append({"x": p.x, "y": p.y, "vx": p.vel_x, "vy": p.vel_y, "fx": p.facing_x, "fy": p.facing_y,
					"flags": pflags, "kick_power": p.kick_power, "stamina": p.stamina,
					"dive_timer": p.gk_dive_timer, "dive_dir": p.gk_dive_dir})
		teams.append({"selected": ts.selected_index, "candidate": ts.switch_candidate, "players": players})
	return {
		"tick": tick, "state_epoch": state_epoch, "flags": flags, "ack_seq": ack_seq,
		"room_state": room_state, "phase": session.phase, "half": session.current_half,
		"match_time": session.match_time, "score_left": sim.score_left, "score_right": sim.score_right,
		"restart_type": sim.restart_type, "restart_timer": sim.restart_timer, "time_scale": session.time_scale,
		"ball": {"x": sim.ball.x, "y": sim.ball.y, "h": sim.ball.h, "vx": sim.ball.vx, "vy": sim.ball.vy,
				"spin": sim.ball.spin, "owner_team": sim.ball.owner_team, "owner_index": sim.ball.owner_index,
				"charge": sim.ball.charging_power, "special": special, "super": sim.ball.is_super_shot},
		"teams": teams,
	}

# --- decoder --------------------------------------------------------------------

## Decodes any message. Returns {} when malformed; otherwise a Dictionary with
## "type" plus the type's fields (positions already dequantized).
static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 2 or bytes.size() > 65536:
		return {}
	var r := _Reader.new(bytes)
	if r.u8() != VERSION:
		return {}
	var type := r.u8()
	var out := {}
	match type:
		Type.HELLO:
			out = {"token": r.str16()}
		Type.WELCOME:
			out = {"match_id": r.str16(), "team": r.u8(), "epoch": r.u16(), "tick_rate": r.u8(),
					"snapshot_every": r.u8(), "human_mask": r.u8()}
			var parsed = JSON.parse_string(r.str16())
			var cfg: MatchConfig = MatchConfig.from_dict(parsed) if typeof(parsed) == TYPE_DICTIONARY else null
			if cfg == null or out.team > 1:
				return {}
			out["config"] = cfg
		Type.INPUT:
			out = {"epoch": r.u16(), "seq": r.u32(), "axis": Vector2(r.unit_i8(), r.unit_i8())}
			var held := r.u8()
			out["sprint"] = held & HELD_SPRINT != 0
			out["shoot"] = held & HELD_SHOOT != 0
			var aim := r.aim()
			out["aim_mode"] = aim[0]
			out["aim"] = aim[1]
			var n := r.u8()
			if n > MAX_ACTIONS:
				return {}
			var actions := []
			for i in n:
				var id := r.u32()
				var kind := r.u8()
				var action_aim := r.aim()
				if kind < Action.PASS or kind > Action.SHOOT_RELEASE:
					return {}
				actions.append({"id": id, "kind": kind, "aim_mode": action_aim[0], "aim": action_aim[1]})
			out["actions"] = actions
			if out.axis.length() > 1.01:
				out.axis = out.axis.normalized()
		Type.SNAPSHOT:
			out = _decode_snapshot(r)
		Type.EVENT:
			out = {"tick": r.u32(), "seq": r.u32(), "event_type": r.str16()}
			var payload = JSON.parse_string(r.str16())
			if typeof(payload) != TYPE_DICTIONARY:
				return {}
			out["event"] = event_from_wire(out.event_type, payload)
		Type.PING:
			out = {"client_ms": r.f64()}
		Type.PONG:
			out = {"client_ms": r.f64(), "tick": r.u32()}
		Type.ERROR:
			out = {"code": r.u16(), "message": r.str16()}
		_:
			return {}
	if r.failed or not r.at_end():
		return {}
	out["type"] = type
	return out

static func _decode_snapshot(r: _Reader) -> Dictionary:
	var s := {"tick": r.u32(), "state_epoch": r.u16(), "flags": r.u8(), "ack_seq": r.u32(),
			"room_state": r.u8(), "phase": r.u8(), "half": r.u8(), "match_time": r.f32(),
			"score_left": r.u8(), "score_right": r.u8(), "restart_type": r.u8(),
			"restart_timer": r.f32(), "time_scale": r.u8() / 100.0}
	s["ball"] = {"x": r.pos(), "y": r.pos(), "h": r.u16() / H_SCALE, "vx": r.vel(), "vy": r.vel(),
			"spin": r.f32(), "owner_team": r.i8(), "owner_index": r.i8(), "charge": r.u8() / 255.0,
			"special": r.i8(), "super": r.u8() != 0}
	var teams := []
	for t in 2:
		var team := {"selected": r.i8(), "candidate": r.i8()}
		var n := r.u8()
		if n > 16:
			r.failed = true
			return {}
		var players := []
		for i in n:
			players.append({"x": r.pos(), "y": r.pos(), "vx": r.vel(), "vy": r.vel(),
					"fx": r.unit_i8(), "fy": r.unit_i8(), "flags": r.u8(), "kick_power": r.u8() / 255.0,
					"stamina": r.u8() / 255.0, "dive_timer": r.u8() / 100.0, "dive_dir": r.i8()})
		team["players"] = players
		teams.append(team)
	s["teams"] = teams
	return s

# --- event payloads ---------------------------------------------------------------

## Session event -> JSON-safe payload (drops "type"/"tick", converts Color /
## Vector2 / Vector3 to strings and arrays).
static func event_to_wire(event: Dictionary) -> Dictionary:
	var out := {}
	for key in event:
		if key == "type" or key == "tick":
			continue
		var v = event[key]
		match typeof(v):
			TYPE_COLOR:
				out[key] = (v as Color).to_html(true)
			TYPE_VECTOR2:
				out[key] = [v.x, v.y]
			TYPE_VECTOR3:
				out[key] = [v.x, v.y, v.z]
			_:
				out[key] = v
	return out

## Inverse of event_to_wire for the keys the presentation layer reads. JSON
## numbers come back as floats; integral fields are converted back to int.
static func event_from_wire(type: String, payload: Dictionary) -> Dictionary:
	var ev := payload.duplicate(true)
	ev["type"] = type
	if ev.has("color") and typeof(ev.color) == TYPE_STRING:
		ev.color = Color.html(ev.color)
	if ev.has("impact") and typeof(ev.impact) == TYPE_ARRAY and ev.impact.size() == 3:
		ev.impact = Vector3(ev.impact[0], ev.impact[1], ev.impact[2])
	if ev.has("spot") and typeof(ev.spot) == TYPE_ARRAY and ev.spot.size() == 2:
		ev.spot = Vector2(ev.spot[0], ev.spot[1])
	for key in ["scorer", "goal_side", "team", "index", "restart_type", "score_left", "score_right", "winner"]:
		if ev.has(key) and typeof(ev[key]) == TYPE_FLOAT:
			ev[key] = int(ev[key])
	return ev

# --- helpers ----------------------------------------------------------------------

static func _writer(type: int) -> StreamPeerBuffer:
	var w := StreamPeerBuffer.new()
	w.big_endian = false
	w.put_u8(VERSION)
	w.put_u8(type)
	return w

static func _put_str(w: StreamPeerBuffer, s: String) -> void:
	var bytes := s.to_utf8_buffer()
	w.put_u16(mini(bytes.size(), 65535))
	w.put_data(bytes.slice(0, 65535))

static func _put_aim(w: StreamPeerBuffer, mode: int, aim: Vector2) -> void:
	w.put_u8(mode)
	if mode == AIM_DIR:
		w.put_16(clampi(roundi(aim.x * 32767.0), -32767, 32767))
		w.put_16(clampi(roundi(aim.y * 32767.0), -32767, 32767))
	else:
		w.put_16(_pos_i16(aim.x))
		w.put_16(_pos_i16(aim.y))

static func _pos_i16(v: float) -> int:
	return clampi(roundi(v * POS_SCALE), -32767, 32767)

static func _vel_i16(v: float) -> int:
	return clampi(roundi(v * VEL_SCALE), -32767, 32767)

static func _unit_i8(v: float) -> int:
	return clampi(roundi(v * 127.0), -127, 127)

static func _frac_u8(v: float) -> int:
	return clampi(roundi(v * 255.0), 0, 255)

## Bounds-checked little-endian reader: any short read sets `failed` and
## returns zeros, so a decoder can finish its field list and then reject.
class _Reader:
	var buf: StreamPeerBuffer
	var failed := false

	func _init(bytes: PackedByteArray) -> void:
		buf = StreamPeerBuffer.new()
		buf.big_endian = false
		buf.data_array = bytes

	func _need(n: int) -> bool:
		if failed or buf.get_available_bytes() < n:
			failed = true
			return false
		return true

	func at_end() -> bool:
		return buf.get_available_bytes() == 0

	func u8() -> int:
		return buf.get_u8() if _need(1) else 0

	func i8() -> int:
		return buf.get_8() if _need(1) else 0

	func u16() -> int:
		return buf.get_u16() if _need(2) else 0

	func i16() -> int:
		return buf.get_16() if _need(2) else 0

	func u32() -> int:
		return buf.get_u32() if _need(4) else 0

	func f32() -> float:
		var v := buf.get_float() if _need(4) else 0.0
		if is_nan(v) or is_inf(v):
			failed = true
			return 0.0
		return v

	func f64() -> float:
		var v := buf.get_double() if _need(8) else 0.0
		if is_nan(v) or is_inf(v):
			failed = true
			return 0.0
		return v

	func pos() -> float:
		return i16() / NetProtocol.POS_SCALE

	func vel() -> float:
		return i16() / NetProtocol.VEL_SCALE

	func unit_i8() -> float:
		return i8() / 127.0

	func str16() -> String:
		var n := u16()
		if not _need(n):
			return ""
		var res := buf.get_data(n)
		return (res[1] as PackedByteArray).get_string_from_utf8()

	func aim() -> Array:
		var mode := u8()
		if mode > NetProtocol.AIM_DIR:
			failed = true
		var x := i16()
		var y := i16()
		if mode == NetProtocol.AIM_DIR:
			return [mode, Vector2(x / 32767.0, y / 32767.0)]
		return [mode, Vector2(x / NetProtocol.POS_SCALE, y / NetProtocol.POS_SCALE)]
