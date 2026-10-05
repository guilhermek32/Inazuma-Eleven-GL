class_name RemoteInputQueue
extends RefCounted

## Turns one remote player's INPUT messages into the per-tick InputSnapshot the
## simulation reads, with server-side semantics that hold up under jitter,
## batching, duplicates and disconnects:
##
## - Held state (axis, sprint, continuous aim) comes from the newest frame.
##   Frames from another connection epoch or with an old seq are ignored.
## - Discrete actions (pass, switch, tackle, shoot start/release) carry a
##   client-assigned, increasing action_id. Each id is applied exactly once,
##   in strict id order; duplicates are dropped, and an action still queued
##   after MAX_ACTION_AGE_TICKS is discarded as stale.
## - At most one action of each kind, and at most one shoot transition, is
##   applied per tick; a conflicting action waits (with everything after it)
##   for the next tick. The shot charge is therefore measured by the server:
##   it is the number of ticks between the applied SHOOT_START and
##   SHOOT_RELEASE (the sim charges while shoot_held), so a start and release
##   arriving together yield the minimum one-tick charge.
## - A SHOOT_RELEASE uses the aim it was sent with, not the latest aim.
## - With no frame for SILENCE_TICKS the held state goes neutral (no movement,
##   charge cancelled without kicking); reset() clears everything on
##   disconnect/reconnect.

const MAX_PENDING_ACTIONS := 32
const MAX_ACTION_AGE_TICKS := 60   # 1 s at 60 Hz
const SILENCE_TICKS := 15          # 250 ms at 60 Hz

var epoch := 0
var last_seq := -1
var _last_action_id := -1          # highest id ever accepted (applied or queued)
var _pending: Array[Dictionary] = []   # {id, kind, aim_mode, aim, received_tick}
var _held := {"axis": Vector2.ZERO, "sprint": false, "aim_mode": NetProtocol.AIM_NONE, "aim": Vector2.ZERO}
var _last_frame_tick := -1000000
var _shoot_held := false

## Starts a new connection epoch: everything from the previous connection is dropped.
func reset(new_epoch: int) -> void:
	epoch = new_epoch
	last_seq = -1
	_last_action_id = -1
	_pending.clear()
	_held = {"axis": Vector2.ZERO, "sprint": false, "aim_mode": NetProtocol.AIM_NONE, "aim": Vector2.ZERO}
	_last_frame_tick = -1000000
	_shoot_held = false

## Accepts a decoded INPUT message received at server tick `tick`.
## Returns false when the frame was ignored (wrong epoch or stale seq).
func push(frame: Dictionary, tick: int) -> bool:
	if int(frame.epoch) != (epoch & 0xFFFF) or int(frame.seq) <= last_seq:
		return false
	last_seq = int(frame.seq)
	_last_frame_tick = tick
	_held = {"axis": frame.axis, "sprint": frame.sprint, "aim_mode": frame.aim_mode, "aim": frame.aim}
	for a in frame.actions:
		if int(a.id) <= _last_action_id:
			continue
		_last_action_id = int(a.id)
		if _pending.size() >= MAX_PENDING_ACTIONS:
			continue
		var queued: Dictionary = a.duplicate()
		queued["received_tick"] = tick
		_pending.append(queued)
	return true

func pending_count() -> int:
	return _pending.size()

## Writes this tick's input into `snap` (the team's InputSnapshot).
func apply(snap: InputSnapshot, tick: int) -> void:
	var silent := tick - _last_frame_tick > SILENCE_TICKS
	snap.shoot_prev = _shoot_held
	snap.pass_pressed = false
	snap.switch_pressed = false
	snap.tackle_pressed = false
	var release_aim: Variant = null
	# Stale actions are dropped; the rest apply in id order, one per kind.
	_pending.assign(_pending.filter(func(a: Dictionary) -> bool: return tick - int(a.received_tick) <= MAX_ACTION_AGE_TICKS))
	# Strict id order: the first action that can't apply this tick (its kind,
	# or a shoot transition, was already used) defers itself and everything after it.
	var used_kinds := {}
	var shoot_transition := false
	var applied := 0
	for a in _pending:
		var kind := int(a.kind)
		var is_shoot := kind == NetProtocol.Action.SHOOT_START or kind == NetProtocol.Action.SHOOT_RELEASE
		if used_kinds.has(kind) or (is_shoot and shoot_transition):
			break
		applied += 1
		used_kinds[kind] = true
		match kind:
			NetProtocol.Action.PASS:
				snap.pass_pressed = true
			NetProtocol.Action.SWITCH:
				snap.switch_pressed = true
			NetProtocol.Action.TACKLE:
				snap.tackle_pressed = true
			NetProtocol.Action.SHOOT_START:
				shoot_transition = true
				_shoot_held = true
			NetProtocol.Action.SHOOT_RELEASE:
				shoot_transition = true
				if _shoot_held:
					_shoot_held = false
					release_aim = a
	_pending.assign(_pending.slice(applied))
	if silent:
		snap.axis = Vector2.ZERO
		snap.sprint_held = false
		if _shoot_held:
			# Cancel the charge without kicking: neither held nor just released.
			_shoot_held = false
			snap.shoot_prev = false
	else:
		snap.axis = _held.axis
		snap.sprint_held = _held.sprint
	snap.shoot_held = _shoot_held
	var aim_src: Dictionary = release_aim if release_aim != null else _held
	_write_aim(snap, int(aim_src.aim_mode), aim_src.aim)

static func _write_aim(snap: InputSnapshot, mode: int, aim: Vector2) -> void:
	match mode:
		NetProtocol.AIM_POINT:
			snap.aim_absolute = true
			snap.aim_vec = aim
		NetProtocol.AIM_DIR:
			snap.aim_absolute = false
			snap.aim_vec = aim
		_:
			# No aim: a zero relative direction makes the sim use the player's facing.
			snap.aim_absolute = false
			snap.aim_vec = Vector2.ZERO
