class_name LatencyProbe
extends RefCounted

## Measures input-to-visible delay on an online client: the time from the
## physics tick that samples a move input (from standstill) to the first
## rendered frame whose interpolated mirror shows the selected player moved
## MOVE_THRESHOLD in that direction. It therefore covers client send, network,
## the runtime's tick + snapshot schedule, the way back and the SnapshotBuffer
## interpolation delay; not the browser's compositor or the display.
##
## The online adapter calls on_input() every physics tick with the local team's
## move axis and selected player, and on_frame() after applying each frame's
## interpolated snapshot. A measurement starts only when the axis goes from
## neutral to pressed while that player stands still, and gives up after
## TIMEOUT_US (the press may have been absorbed, e.g. by a restart freeze).
## Enabled by `?latency` (web) or `-- --latency` (desktop).

const MOVE_THRESHOLD := 0.003      # field units (~7 cm on the 3D pitch)
const STILL_SPEED := 0.02          # field units/s: "standing still"
const TIMEOUT_US := 3_000_000

var samples_ms: Array[float] = []
var _axis_was_neutral := true
var _player: PlayerState
var _origin := Vector2.ZERO
var _dir := Vector2.ZERO
var _t0_us := 0

func on_input(axis: Vector2, player: PlayerState, now_us: int) -> void:
	var neutral := axis.length() < 0.1
	if not neutral and _axis_was_neutral and _player == null and player != null \
			and Vector2(player.vel_x, player.vel_y).length() < STILL_SPEED:
		_player = player
		_origin = Vector2(player.x, player.y)
		_dir = axis.normalized()
		_t0_us = now_us
	_axis_was_neutral = neutral

## Returns the measured delay in ms when this frame completes a measurement, else -1.
func on_frame(now_us: int) -> float:
	if _player == null:
		return -1.0
	if (Vector2(_player.x, _player.y) - _origin).dot(_dir) >= MOVE_THRESHOLD:
		var ms := float(now_us - _t0_us) / 1000.0
		_player = null
		samples_ms.append(ms)
		return ms
	if now_us - _t0_us > TIMEOUT_US:
		_player = null
	return -1.0
