class_name InputReader
extends RefCounted

## Samples keyboard+mouse (player 1) and gamepad (player 2) into the per-team
## InputSnapshots each frame. Mouse aim is ray-cast onto the ground plane via
## the broadcast camera.

var camera_3d: Camera3D
# Cached world position of the last successful mouse ray-cast; returned on miss
# so the aim vector never snaps to the origin mid-game.
var _last_valid_aim := Vector2.ZERO

func read(teams: Array[TeamState], kickoff_timer: float) -> void:
	var allow := kickoff_timer <= 0.0
	# Each team is driven by whatever device the setup screen assigned to it.
	for ts in teams:
		if ts.device == GameConfig.DEVICE_KBM:
			_read_keyboard_input(ts.input, allow)
		elif ts.device >= 0:
			_read_gamepad_input(ts.input, ts.device, allow)
		# DEVICE_AI: leave the snapshot untouched — the team runs on the AI.

func _read_keyboard_input(snap: InputSnapshot, allow: bool) -> void:
	snap.axis = Vector2.ZERO
	if allow:
		snap.axis.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
		snap.axis.y = Input.get_action_strength("move_up") - Input.get_action_strength("move_down")
		snap.axis = snap.axis.normalized() if snap.axis.length_squared() > 1.0 else snap.axis
	snap.shoot_prev = snap.shoot_held
	snap.shoot_held = allow and Input.is_action_pressed("shoot")
	snap.pass_pressed = allow and Input.is_action_just_pressed("pass")
	snap.switch_pressed = allow and Input.is_action_just_pressed("switch_player")
	snap.tackle_pressed = allow and Input.is_action_just_pressed("tackle")
	snap.sprint_held = allow and Input.is_action_pressed("sprint")
	snap.aim_vec = _mouse_aim_world()
	snap.aim_absolute = true

func _read_gamepad_input(snap: InputSnapshot, device: int, allow: bool) -> void:
	var dead := 0.22
	snap.axis = Vector2.ZERO
	var move := Vector2(Input.get_joy_axis(device, JOY_AXIS_LEFT_X), -Input.get_joy_axis(device, JOY_AXIS_LEFT_Y))
	if allow and move.length() > dead:
		snap.axis = move if move.length() <= 1.0 else move.normalized()
	snap.shoot_prev = snap.shoot_held
	# Shoot is the right shoulder button: R1 on PlayStation, RB on Xbox (SDL-abstracted).
	snap.shoot_held = allow and Input.is_joy_button_pressed(device, JOY_BUTTON_RIGHT_SHOULDER)
	var pass_now := allow and Input.is_joy_button_pressed(device, JOY_BUTTON_A) and not snap.shoot_held
	snap.pass_pressed = pass_now and not snap.pass_held
	snap.pass_held = pass_now
	var switch_now := allow and Input.is_joy_button_pressed(device, JOY_BUTTON_LEFT_SHOULDER)
	snap.switch_pressed = switch_now and not snap.switch_held
	snap.switch_held = switch_now
	# Tackle on X/Square, sprint on the right trigger.
	var tackle_now := allow and Input.is_joy_button_pressed(device, JOY_BUTTON_X)
	snap.tackle_pressed = tackle_now and not snap.tackle_held
	snap.tackle_held = tackle_now
	snap.sprint_held = allow and Input.get_joy_axis(device, JOY_AXIS_TRIGGER_RIGHT) > 0.4
	# Right stick aims as a direction relative to the player; world point computed at kick time.
	var look := Vector2(Input.get_joy_axis(device, JOY_AXIS_RIGHT_X), -Input.get_joy_axis(device, JOY_AXIS_RIGHT_Y))
	snap.aim_absolute = false
	snap.aim_vec = look.normalized() if look.length() > dead else Vector2.ZERO

func _mouse_aim_world() -> Vector2:
	if camera_3d == null:
		return _last_valid_aim
	var mouse := camera_3d.get_viewport().get_mouse_position()
	var origin := camera_3d.project_ray_origin(mouse)
	var dir := camera_3d.project_ray_normal(mouse)
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(origin, dir)
	if hit == null:
		# Ray is nearly parallel to the ground (extreme camera angle); keep the
		# last known aim so the shot direction doesn't snap to the origin.
		return _last_valid_aim
	_last_valid_aim = Vector2(hit.x / GameConfig.FIELD_SCALE, -hit.z / GameConfig.FIELD_SCALE)
	return _last_valid_aim
