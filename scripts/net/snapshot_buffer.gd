class_name SnapshotBuffer
extends RefCounted

## Client-side snapshot interpolation.
##
## Snapshots arrive every few server ticks with jitter. The buffer estimates the
## server's current tick from arrival times and renders `delay_ticks` behind
## it, interpolating between the two snapshots that bracket that render tick:
##
## - Continuous fields (positions, velocities, facing, charge, clock) are
##   interpolated. Discrete fields (possession, score, selection, phase,
##   restart type, flags) come from the older snapshot.
## - Two snapshots from different state epochs (a kickoff, restart or half-time
##   reset happened between them) are never blended: the older one is shown
##   until the render tick reaches the newer one, so nobody slides across the
##   pitch through a teleport.
## - Past the newest snapshot the state holds; there is no extrapolation.
##
## Events are queued with their server tick and released when the render tick
## reaches them, so a goal celebration starts when the ball is seen crossing.

const MAX_SNAPSHOTS := 32
const MAX_EVENTS := 256

var tick_rate := 60.0
var delay_ticks := 6.0   # 100 ms at 60 Hz

var _snaps: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _offset := NAN   # estimated (server tick - local ms * tick_rate / 1000)

func clear() -> void:
	_snaps.clear()
	_events.clear()
	_offset = NAN

func size() -> int:
	return _snaps.size()

func latest() -> Dictionary:
	return _snaps[-1] if not _snaps.is_empty() else {}

func push_snapshot(s: Dictionary, now_ms: float) -> void:
	if not _snaps.is_empty() and int(s.tick) <= int(_snaps[-1].tick):
		return
	var estimate := float(s.tick) - now_ms * tick_rate / 1000.0
	# The fastest arrival is the best clock estimate; drift slowly toward later
	# arrivals so a lasting increase in latency is eventually absorbed.
	if is_nan(_offset) or estimate > _offset:
		_offset = estimate
	else:
		_offset = lerpf(_offset, estimate, 0.02)
	_snaps.append(s)
	if _snaps.size() > MAX_SNAPSHOTS:
		_snaps.pop_front()

func push_event(tick: int, event: Dictionary) -> void:
	if _events.size() < MAX_EVENTS:
		_events.append({"tick": tick, "event": event})

func render_tick(now_ms: float) -> float:
	if is_nan(_offset):
		return 0.0
	return now_ms * tick_rate / 1000.0 + _offset - delay_ticks

## {"a": older snapshot, "b": newer snapshot, "t": 0..1}, or {} before the
## first snapshot.
func sample(now_ms: float) -> Dictionary:
	if _snaps.is_empty():
		return {}
	var rt := render_tick(now_ms)
	if rt <= float(_snaps[0].tick):
		return {"a": _snaps[0], "b": _snaps[0], "t": 0.0}
	for i in range(_snaps.size() - 1):
		var a: Dictionary = _snaps[i]
		var b: Dictionary = _snaps[i + 1]
		if rt < float(b.tick):
			# Snapshots older than `a` can never be needed again.
			if i > 0:
				_snaps.assign(_snaps.slice(i))
			if a.state_epoch != b.state_epoch:
				return {"a": a, "b": a, "t": 0.0}
			var t := (rt - float(a.tick)) / float(b.tick - a.tick)
			return {"a": a, "b": b, "t": clampf(t, 0.0, 1.0)}
	return {"a": _snaps[-1], "b": _snaps[-1], "t": 0.0}

## Events whose tick the render time has reached, oldest first.
func take_due_events(now_ms: float) -> Array[Dictionary]:
	var rt := render_tick(now_ms)
	var due: Array[Dictionary] = []
	while not _events.is_empty() and float(_events[0].tick) <= rt + 1.0:
		due.append(_events.pop_front().event)
	return due

## Writes the interpolated state into a mirror MatchSimulation (one that is
## never stepped) so MatchView renders it unchanged. Returns the match-level
## values the HUD needs.
static func apply_to(sim: MatchSimulation, a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	for team in 2:
		var ta: Dictionary = a.teams[team]
		var tb: Dictionary = b.teams[team]
		var players := sim.teams[team].players
		for i in mini(players.size(), mini(ta.players.size(), tb.players.size())):
			var pa: Dictionary = ta.players[i]
			var pb: Dictionary = tb.players[i]
			var p := players[i]
			p.x = lerpf(pa.x, pb.x, t)
			p.y = lerpf(pa.y, pb.y, t)
			p.vel_x = lerpf(pa.vx, pb.vx, t)
			p.vel_y = lerpf(pa.vy, pb.vy, t)
			var face := Vector2(lerpf(pa.fx, pb.fx, t), lerpf(pa.fy, pb.fy, t))
			if face.length() > 0.01:
				face = face.normalized()
				p.facing_x = face.x
				p.facing_y = face.y
			p.is_moving = int(pa.flags) & NetProtocol.PLAYER_MOVING != 0
			p.kick_power = lerpf(pa.kick_power, pb.kick_power, t)
			p.stamina = lerpf(pa.stamina, pb.stamina, t)
			p.gk_dive_timer = pa.dive_timer
			p.gk_dive_dir = pa.dive_dir
		sim.teams[team].selected_index = ta.selected
		sim.teams[team].switch_candidate = ta.candidate
	var ba: Dictionary = a.ball
	var bb: Dictionary = b.ball
	sim.ball.x = lerpf(ba.x, bb.x, t)
	sim.ball.y = lerpf(ba.y, bb.y, t)
	sim.ball.h = lerpf(ba.h, bb.h, t)
	sim.ball.vx = lerpf(ba.vx, bb.vx, t)
	sim.ball.vy = lerpf(ba.vy, bb.vy, t)
	sim.ball.spin = ba.spin
	sim.ball.owner_team = ba.owner_team
	sim.ball.owner_index = ba.owner_index
	sim.ball.charging_power = lerpf(ba.charge, bb.charge, t)
	sim.ball.is_super_shot = ba.super
	var special := int(ba.special)
	if special >= 0 and special < GameConfig.SPECIAL_SHOTS.size():
		sim.ball.special_name = GameConfig.SPECIAL_SHOTS[special].name
		sim.ball.special_color = GameConfig.SPECIAL_SHOTS[special].color
	else:
		sim.ball.special_name = ""
		sim.ball.special_color = Color(1.0, 1.0, 1.0)
	sim.score_left = a.score_left
	sim.score_right = a.score_right
	sim.restart_type = a.restart_type
	sim.restart_timer = lerpf(a.restart_timer, b.restart_timer, t)
	return {
		"room_state": a.room_state, "phase": a.phase, "current_half": a.half,
		"match_time": lerpf(a.match_time, b.match_time, t) if a.half == b.half else float(a.match_time),
		"score_left": a.score_left, "score_right": a.score_right,
		"restart_timer": sim.restart_timer, "restart_type": a.restart_type, "time_scale": a.time_scale,
	}
