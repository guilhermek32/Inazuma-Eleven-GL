class_name InputReader
extends RefCounted

## Samples keyboard+mouse (player 1) and gamepad (player 2) into the per-team
## InputSnapshots each frame. Mouse aim is ray-cast onto the ground plane via
## the broadcast camera.

var camera_3d: Camera3D

func read(inputs: Array, num_players: int, kickoff_timer: float) -> void:
	var allow := kickoff_timer <= 0.0
	# Red (team 0) always uses keyboard+mouse. In 2P, blue uses the first connected controller.
	_read_keyboard_input(inputs[0], allow)
	if num_players == 2:
		_read_gamepad_input(inputs[1], _first_connected_gamepad(), allow)

func _first_connected_gamepad() -> int:
	var pads := Input.get_connected_joypads()
	return -1 if pads.size() == 0 else int(pads[0])

func _read_keyboard_input(snap: InputSnapshot, allow: bool) -> void:
	snap.axis = Vector2.ZERO
	if allow:
		snap.axis.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
		snap.axis.y = Input.get_action_strength("move_up") - Input.get_action_strength("move_down")
		snap.axis = snap.axis.normalized() if snap.axis.length_squared() > 1.0 else snap.axis
	snap.shoot_prev = snap.shoot_held
	snap.shoot_held = allow and Input.is_action_pressed("shoot")
	snap.aim_vec = _mouse_aim_world()
	snap.aim_absolute = true

func _read_gamepad_input(snap: InputSnapshot, device: int, allow: bool) -> void:
	var dead := 0.22
	snap.axis = Vector2.ZERO
	if device < 0:
		snap.shoot_prev = snap.shoot_held
		snap.shoot_held = false
		snap.aim_vec = Vector2.ZERO
		snap.aim_absolute = false
		return
	var move := Vector2(Input.get_joy_axis(device, JOY_AXIS_LEFT_X), -Input.get_joy_axis(device, JOY_AXIS_LEFT_Y))
	if allow and move.length() > dead:
		snap.axis = move if move.length() <= 1.0 else move.normalized()
	snap.shoot_prev = snap.shoot_held
	# Shoot is the right shoulder button: R1 on PlayStation, RB on Xbox (SDL-abstracted).
	snap.shoot_held = allow and Input.is_joy_button_pressed(device, JOY_BUTTON_RIGHT_SHOULDER)
	# Right stick aims as a direction relative to the player; world point computed at kick time.
	var look := Vector2(Input.get_joy_axis(device, JOY_AXIS_RIGHT_X), -Input.get_joy_axis(device, JOY_AXIS_RIGHT_Y))
	snap.aim_absolute = false
	snap.aim_vec = look.normalized() if look.length() > dead else Vector2.ZERO

func _mouse_aim_world() -> Vector2:
	if camera_3d == null:
		return Vector2.ZERO
	var mouse := camera_3d.get_viewport().get_mouse_position()
	var origin := camera_3d.project_ray_origin(mouse)
	var dir := camera_3d.project_ray_normal(mouse)
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(origin, dir)
	if hit == null:
		return Vector2.ZERO
	return Vector2(hit.x / GameConfig.FIELD_SCALE, -hit.z / GameConfig.FIELD_SCALE)
