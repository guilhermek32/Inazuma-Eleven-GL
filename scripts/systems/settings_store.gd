class_name SettingsStore
extends RefCounted

## Holds tunable settings, persists them to disk, applies their side effects
## (AI difficulty multipliers, window mode, audio volumes) and registers the
## keyboard/gamepad input actions used by the match.

var difficulty := 1            # 0 Easy, 1 Normal, 2 Hard
var ai_speed_mult := 1.0
var ai_decision_mult := 1.0
var camera_angle := 1          # 0 Low, 1 Broadcast, 2 High, 3 Top-down
var cam_height_mult := 1.0     # derived from camera_angle in _apply_settings()
var cam_dist_mult := 1.0
var camera_distance := 1       # 0 Close, 1 Normal, 2 Far, 3 Very Far
var cam_zoom_mult := 1.0       # derived from camera_distance in _apply_settings()
var half_length := 120.0       # seconds per half
var fullscreen := false
var vol_master := 0.9
var vol_music := 0.7
var vol_sfx := 1.0
var audio: AudioManager

func apply() -> void:
	_apply_settings()

func save() -> void:
	_save_settings()

func _apply_settings() -> void:
	match difficulty:
		0: ai_speed_mult = 0.80; ai_decision_mult = 0.5
		1: ai_speed_mult = 1.0; ai_decision_mult = 1.0
		2: ai_speed_mult = 1.25; ai_decision_mult = 2.0
	# Camera presets: higher height_mult + lower dist_mult => steeper, more top-down angle.
	match camera_angle:
		0: cam_height_mult = 0.66; cam_dist_mult = 1.12   # Low / cinematic
		1: cam_height_mult = 1.0; cam_dist_mult = 1.0     # Broadcast (default)
		2: cam_height_mult = 1.45; cam_dist_mult = 0.82   # High
		3: cam_height_mult = 2.2; cam_dist_mult = 0.42    # Top-down
	# Distance/zoom: scales height + distance together, so it moves the camera nearer/
	# farther along its view without changing the angle preset above.
	match camera_distance:
		0: cam_zoom_mult = 0.8     # Close
		1: cam_zoom_mult = 1.0     # Normal
		2: cam_zoom_mult = 1.25    # Far
		3: cam_zoom_mult = 1.55    # Very Far
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	DisplayServer.window_set_mode(mode)
	apply_volumes()

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(GameConfig.SETTINGS_PATH) == OK:
		difficulty = cfg.get_value("game", "difficulty", difficulty)
		half_length = cfg.get_value("game", "half_length", half_length)
		fullscreen = cfg.get_value("video", "fullscreen", fullscreen)
		camera_angle = cfg.get_value("video", "camera_angle", camera_angle)
		camera_distance = cfg.get_value("video", "camera_distance", camera_distance)
		vol_master = cfg.get_value("audio", "master", vol_master)
		vol_music = cfg.get_value("audio", "music", vol_music)
		vol_sfx = cfg.get_value("audio", "sfx", vol_sfx)
	_apply_settings()

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("game", "difficulty", difficulty)
	cfg.set_value("game", "half_length", half_length)
	cfg.set_value("video", "fullscreen", fullscreen)
	cfg.set_value("video", "camera_angle", camera_angle)
	cfg.set_value("video", "camera_distance", camera_distance)
	cfg.set_value("audio", "master", vol_master)
	cfg.set_value("audio", "music", vol_music)
	cfg.set_value("audio", "sfx", vol_sfx)
	cfg.save(GameConfig.SETTINGS_PATH)

func setup_input_actions() -> void:
	_add_key_action("move_up", KEY_W)
	_add_key_action("move_down", KEY_S)
	_add_key_action("move_left", KEY_A)
	_add_key_action("move_right", KEY_D)
	_add_key_action("shoot", KEY_SPACE)
	_add_key_action("pass", KEY_E)
	_add_key_action("switch_player", KEY_Q)
	_add_key_action("tackle", KEY_CTRL)
	_add_mouse_button_action("tackle", MOUSE_BUTTON_RIGHT)
	_add_key_action("sprint", KEY_SHIFT)
	_add_joy_button_action("pass", JOY_BUTTON_A)
	_add_joy_button_action("switch_player", JOY_BUTTON_LEFT_SHOULDER)
	_add_joy_button_action("ui_cancel", JOY_BUTTON_START)
	# D-pad and confirm for menu navigation (joystick 0).
	_add_joy_button_action("ui_accept", JOY_BUTTON_A)
	_add_joy_button_action("ui_up", JOY_BUTTON_DPAD_UP)
	_add_joy_button_action("ui_down", JOY_BUTTON_DPAD_DOWN)
	_add_joy_button_action("ui_left", JOY_BUTTON_DPAD_LEFT)
	_add_joy_button_action("ui_right", JOY_BUTTON_DPAD_RIGHT)

func _add_key_action(action: StringName, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	for existing in InputMap.action_get_events(action):
		if existing is InputEventKey and existing.physical_keycode == keycode:
			return
	InputMap.action_add_event(action, event)

func _add_mouse_button_action(action: StringName, button_index: MouseButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var event := InputEventMouseButton.new()
	event.button_index = button_index
	for existing in InputMap.action_get_events(action):
		if existing is InputEventMouseButton and existing.button_index == button_index:
			return
	InputMap.action_add_event(action, event)

func _add_joy_button_action(action: StringName, button_index: JoyButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var event := InputEventJoypadButton.new()
	event.button_index = button_index
	event.device = -1   # all devices, so any pad (not just gamepad 0) can confirm/pause menus
	for existing in InputMap.action_get_events(action):
		if existing is InputEventJoypadButton and existing.button_index == button_index:
			return
	InputMap.action_add_event(action, event)

## Pushes the current volumes to the audio buses.
func apply_volumes() -> void:
	if audio != null:
		audio.apply_volumes(vol_master, vol_music, vol_sfx)
