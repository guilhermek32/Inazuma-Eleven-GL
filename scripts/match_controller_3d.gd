extends Node3D




var materials := {}
var glb_scene_cache := {}
var player_anim_library: AnimationLibrary
var player_anim_ready := false
var camera_rig: Node3D
var camera_3d: Camera3D
var pitch_root: Node3D
var lines_root: Node3D
var goals_root: Node3D
var stadium_root: Node3D
var players_root: Node3D
var ball_root: Node3D
var vfx_root: Node3D
var material_factory: MaterialFactory
var pitch_builder: PitchBuilder
var stadium_builder: StadiumBuilder
var player_factory: PlayerFactory
var ui_layer: CanvasLayer
var score_label: Label
var timer_label: Label
var team_red: Array[PlayerState] = []
var team_blue: Array[PlayerState] = []
var ball := BallState.new()
var ball_trail: Array[MeshInstance3D] = []
var ball_trail_points: Array[Vector3] = []
var confetti: Array[VfxParticle] = []
var score_left := 0
var score_right := 0
var kickoff_timer := 2.0
var inputs := [InputSnapshot.new(), InputSnapshot.new()]
var selected_index: Array[int] = [-1, -1]
var celebration_timer := 0.0
var camera_look := Vector3.ZERO

# Game state / flow
var game_state := GameConfig.GameState.MENU
var prev_menu_state := GameConfig.GameState.MENU
var num_players := 1
var match_time := 0.0
var current_half := 1
var halftime_pause := 0.0

# Settings (defaults; overridden by _load_settings)
var difficulty := 1            # 0 Easy, 1 Normal, 2 Hard
var ai_speed_mult := 1.0
var ai_decision_mult := 1.0
var half_length := 120.0       # seconds per half
var fullscreen := false
var vol_master := 0.9
var vol_music := 0.7
var vol_sfx := 1.0

# Menu / audio nodes
var menu_layer: CanvasLayer
var menu_panels := {}
var play_2p_button: Button
var play_2p_hint: Label
var fulltime_label: Label
var music_player: AudioStreamPlayer
var sfx_kick: AudioStreamPlayer
var sfx_whistle: AudioStreamPlayer
var bus_music := -1
var bus_sfx := -1

func _ready() -> void:
	material_factory = MaterialFactory.new()
	material_factory._build_materials()
	materials = material_factory.materials
	_build_scene_roots()
	stadium_builder = StadiumBuilder.new()
	stadium_builder.mf = material_factory
	stadium_builder.host = self
	stadium_builder.stadium_root = stadium_root
	stadium_builder._build_environment()
	stadium_builder._build_camera()
	camera_rig = stadium_builder.camera_rig
	camera_3d = stadium_builder.camera_3d
	stadium_builder._build_lighting()
	pitch_builder = PitchBuilder.new()
	pitch_builder.mf = material_factory
	pitch_builder.pitch_root = pitch_root
	pitch_builder.lines_root = lines_root
	pitch_builder.goals_root = goals_root
	pitch_builder._build_pitch()
	pitch_builder._build_goals()
	stadium_builder._build_stadium()
	_build_ui()
	_setup_input_actions()
	player_factory = PlayerFactory.new()
	player_factory.mf = material_factory
	_create_teams()
	_create_ball()
	_create_ball_trail()
	_build_audio()
	_load_settings()
	_build_menus()
	_reset_game(1)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_set_game_state(GameConfig.GameState.MENU)
	print("Inazuma Eleven 3D environment ready")

func _process(delta: float) -> void:
	if game_state == GameConfig.GameState.PLAYING:
		if halftime_pause > 0.0:
			halftime_pause = maxf(0.0, halftime_pause - delta)
		else:
			_read_input()
			_update_kickoff(delta)
			var scorer := _update_ball(delta)
			if scorer != 0:
				_trigger_goal(scorer)
			_update_team(team_red, team_blue, 0, true, delta)
			_update_team(team_blue, team_red, 1, num_players == 2, delta)
			_update_match_clock(delta)
		_update_visuals(delta)
	_update_confetti(delta)
	_update_scoreboard()

func _exit_tree() -> void:
	for player in [music_player, sfx_kick, sfx_whistle]:
		if player != null:
			player.stop()
			player.stream = null

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		match game_state:
			GameConfig.GameState.PLAYING:
				_set_game_state(GameConfig.GameState.PAUSED)
			GameConfig.GameState.PAUSED:
				_set_game_state(GameConfig.GameState.PLAYING)
			GameConfig.GameState.HOWTO, GameConfig.GameState.SETTINGS:
				_set_game_state(prev_menu_state)
		get_viewport().set_input_as_handled()

func _set_game_state(next: int) -> void:
	if next == GameConfig.GameState.HOWTO or next == GameConfig.GameState.SETTINGS:
		prev_menu_state = game_state if game_state in [GameConfig.GameState.MENU, GameConfig.GameState.PAUSED] else GameConfig.GameState.MENU
	game_state = next
	_set_glb_animations_paused(next != GameConfig.GameState.PLAYING)
	for key in menu_panels:
		(menu_panels[key] as Control).visible = false
	match next:
		GameConfig.GameState.MENU:
			_refresh_two_player_availability()
			menu_panels.main.visible = true
		GameConfig.GameState.HOWTO:
			menu_panels.howto.visible = true
		GameConfig.GameState.SETTINGS:
			menu_panels.settings.visible = true
		GameConfig.GameState.PAUSED:
			menu_panels.pause.visible = true
		GameConfig.GameState.FULLTIME:
			menu_panels.fulltime.visible = true

func _start_match() -> void:
	score_left = 0
	score_right = 0
	match_time = 0.0
	current_half = 1
	halftime_pause = 0.0
	_set_default_ends()
	_reset_game(1)
	_set_game_state(GameConfig.GameState.PLAYING)
	_play_whistle()

func _update_match_clock(delta: float) -> void:
	match_time += delta
	if match_time >= half_length:
		if current_half == 1:
			current_half = 2
			match_time = 0.0
			halftime_pause = 2.0
			_switch_ends()
			_reset_game(1)
			_play_whistle()
		else:
			_end_match()

func _end_match() -> void:
	_play_whistle()
	var result := "DRAW"
	if score_left > score_right:
		result = "RED WINS"
	elif score_right > score_left:
		result = "BLUE WINS"
	if fulltime_label != null:
		fulltime_label.text = "FULL TIME\n%d - %d\n%s" % [score_left, score_right, result]
	_set_game_state(GameConfig.GameState.FULLTIME)

func _switch_ends() -> void:
	for p in team_red:
		_flip_player_end(p)
	for p in team_blue:
		_flip_player_end(p)

func _flip_player_end(p: PlayerState) -> void:
	p.side *= -1
	p.start_x *= -1.0
	p.x *= -1.0
	p.facing_x = float(p.side)
	p.facing_y = 0.0

func _set_default_ends() -> void:
	for p in team_red:
		p.side = -1
		p.start_x = -absf(p.start_x)
		p.facing_x = -1.0
	for p in team_blue:
		p.side = 1
		p.start_x = absf(p.start_x)
		p.facing_x = 1.0

func _set_glb_animations_paused(paused: bool) -> void:
	var speed := 0.0 if paused else 1.0
	for p in team_red:
		if p.animation_player != null:
			p.animation_player.speed_scale = speed
	for p in team_blue:
		if p.animation_player != null:
			p.animation_player.speed_scale = speed

func _on_joy_connection_changed(_device: int, _connected: bool) -> void:
	if game_state == GameConfig.GameState.MENU:
		_refresh_two_player_availability()

func _refresh_two_player_availability() -> void:
	if play_2p_button == null:
		return
	var pads := Input.get_connected_joypads().size()
	play_2p_button.disabled = pads < 1
	if play_2p_hint != null:
		play_2p_hint.text = "" if pads >= 1 else "Connect 1 controller for 2-player"

func _build_scene_roots() -> void:
	pitch_root = _new_root("Pitch")
	lines_root = _new_root("FieldLines")
	goals_root = _new_root("Goals")
	stadium_root = _new_root("Stadium")
	players_root = _new_root("Players")
	ball_root = _new_root("Ball")
	vfx_root = _new_root("VFX")

func _new_root(root_name: String) -> Node3D:
	var node := Node3D.new()
	node.name = root_name
	add_child(node)
	return node

func _build_ui() -> void:
	ui_layer = CanvasLayer.new()
	ui_layer.name = "ScoreboardUI"
	add_child(ui_layer)
	score_label = Label.new()
	score_label.name = "ScoreLabel"
	score_label.text = "0 - 0"
	score_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	score_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	score_label.position.y = 20.0
	score_label.add_theme_font_size_override("font_size", 56)
	score_label.add_theme_color_override("font_color", Color.WHITE)
	ui_layer.add_child(score_label)
	timer_label = Label.new()
	timer_label.name = "TimerLabel"
	timer_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	timer_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	timer_label.position.y = 88.0
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer_label.add_theme_font_size_override("font_size", 26)
	timer_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.25))
	ui_layer.add_child(timer_label)

# ---------------------------------------------------------------------------
# Audio
# ---------------------------------------------------------------------------
func _build_audio() -> void:
	if DisplayServer.get_name() == "headless":
		return
	bus_music = _add_audio_bus("Music")
	bus_sfx = _add_audio_bus("SFX")
	music_player = _make_stream_player("MusicPlayer", "res://assets/sound/background-sound.mp3", "Music", true)
	sfx_kick = _make_stream_player("KickSfx", "res://assets/sound/kick.mp3", "SFX", false)
	sfx_whistle = _make_stream_player("WhistleSfx", "res://assets/sound/referee-start.mp3", "SFX", false)
	if music_player != null:
		music_player.play()

func _add_audio_bus(bus_name: String) -> int:
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, "Master")
	return idx

func _make_stream_player(node_name: String, path: String, bus: String, loop: bool) -> AudioStreamPlayer:
	if not ResourceLoader.exists(path):
		push_warning("Audio asset missing: %s" % path)
		return null
	var player := AudioStreamPlayer.new()
	player.name = node_name
	var stream := load(path)
	if stream is AudioStreamMP3:
		stream.loop = loop
	player.stream = stream
	player.bus = bus
	add_child(player)
	return player

func _play_kick() -> void:
	if sfx_kick != null:
		sfx_kick.play()

func _play_whistle() -> void:
	if sfx_whistle != null:
		sfx_whistle.play()

func _apply_volumes() -> void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), linear_to_db(vol_master))
	if bus_music >= 0:
		AudioServer.set_bus_volume_db(bus_music, linear_to_db(vol_music))
	if bus_sfx >= 0:
		AudioServer.set_bus_volume_db(bus_sfx, linear_to_db(vol_sfx))

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------
func _build_menus() -> void:
	menu_layer = CanvasLayer.new()
	menu_layer.name = "MenuUI"
	menu_layer.layer = 2
	add_child(menu_layer)
	_build_main_menu()
	_build_howto_panel()
	_build_settings_panel()
	_build_pause_panel()
	_build_fulltime_panel()

func _make_panel(panel_name: String, dim := true) -> Control:
	var panel := Control.new()
	panel.name = panel_name
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	menu_layer.add_child(panel)
	if dim:
		var bg := ColorRect.new()
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.color = Color(0.02, 0.03, 0.06, 0.82)
		panel.add_child(bg)
	menu_panels[panel_name] = panel
	return panel

func _make_vbox(parent: Control) -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_CENTER)
	vb.grow_horizontal = Control.GROW_DIRECTION_BOTH
	vb.grow_vertical = Control.GROW_DIRECTION_BOTH
	vb.add_theme_constant_override("separation", 14)
	parent.add_child(vb)
	return vb

func _make_title(parent: Control, text: String, size := 64) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color(1.0, 0.93, 0.55))
	parent.add_child(label)
	return label

func _make_button(parent: Control, text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(320, 52)
	button.add_theme_font_size_override("font_size", 26)
	button.pressed.connect(handler)
	parent.add_child(button)
	return button

func _build_main_menu() -> void:
	var panel := _make_panel("main", false)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.05, 0.10, 1.0)
	panel.add_child(bg)
	var vb := _make_vbox(panel)
	_make_title(vb, "INAZUMA ELEVEN", 72)
	_make_title(vb, "GL", 32).add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	_make_button(vb, "Play - 1 Player", func() -> void: num_players = 1; _start_match())
	play_2p_button = _make_button(vb, "Play - 2 Players", func() -> void: num_players = 2; _start_match())
	play_2p_hint = Label.new()
	play_2p_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	play_2p_hint.add_theme_font_size_override("font_size", 16)
	play_2p_hint.add_theme_color_override("font_color", Color(1.0, 0.6, 0.4))
	vb.add_child(play_2p_hint)
	_make_button(vb, "How to Play", func() -> void: _set_game_state(GameConfig.GameState.HOWTO))
	_make_button(vb, "Settings", func() -> void: _set_game_state(GameConfig.GameState.SETTINGS))
	_make_button(vb, "Quit", func() -> void: get_tree().quit())

func _build_howto_panel() -> void:
	var panel := _make_panel("howto")
	var vb := _make_vbox(panel)
	_make_title(vb, "How to Play")
	var text := Label.new()
	text.add_theme_font_size_override("font_size", 22)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.text = "1 PLAYER (keyboard + mouse)\nMove: W A S D\nAim: Mouse\nShoot: hold SPACE to charge, release to kick\n\n2 PLAYERS (keyboard + mouse vs controller)\nP1 Move: W A S D    Aim: Mouse    Shoot: SPACE\nP2 Move: Left stick    Aim: Right stick\nP2 Shoot: R1 / RB  (hold to charge)\n\nYou control the player nearest the ball.\nPress ESC to pause."
	vb.add_child(text)
	_make_button(vb, "Back", func() -> void: _set_game_state(prev_menu_state))

func _build_pause_panel() -> void:
	var panel := _make_panel("pause")
	var vb := _make_vbox(panel)
	_make_title(vb, "Paused")
	_make_button(vb, "Resume", func() -> void: _set_game_state(GameConfig.GameState.PLAYING))
	_make_button(vb, "Restart Match", func() -> void: _start_match())
	_make_button(vb, "Settings", func() -> void: _set_game_state(GameConfig.GameState.SETTINGS))
	_make_button(vb, "Back to Menu", func() -> void: _set_game_state(GameConfig.GameState.MENU))

func _build_fulltime_panel() -> void:
	var panel := _make_panel("fulltime")
	var vb := _make_vbox(panel)
	fulltime_label = _make_title(vb, "FULL TIME")
	_make_button(vb, "Rematch", func() -> void: _start_match())
	_make_button(vb, "Back to Menu", func() -> void: _set_game_state(GameConfig.GameState.MENU))

func _build_settings_panel() -> void:
	var panel := _make_panel("settings")
	var vb := _make_vbox(panel)
	_make_title(vb, "Settings")

	var difficulty_opt := OptionButton.new()
	difficulty_opt.add_item("Easy")
	difficulty_opt.add_item("Normal")
	difficulty_opt.add_item("Hard")
	difficulty_opt.selected = difficulty
	difficulty_opt.item_selected.connect(func(i: int) -> void: difficulty = i; _apply_settings(); _save_settings())
	_settings_row(vb, "Difficulty", difficulty_opt)

	var length_opt := OptionButton.new()
	length_opt.add_item("2 min halves")
	length_opt.add_item("5 min halves")
	length_opt.add_item("10 min halves")
	length_opt.selected = GameConfig.MATCH_LENGTHS.find(half_length) if GameConfig.MATCH_LENGTHS.has(half_length) else 0
	length_opt.item_selected.connect(func(i: int) -> void: half_length = GameConfig.MATCH_LENGTHS[i]; _save_settings())
	_settings_row(vb, "Match Length", length_opt)

	var fs_check := CheckButton.new()
	fs_check.button_pressed = fullscreen
	fs_check.toggled.connect(func(on: bool) -> void: fullscreen = on; _apply_settings(); _save_settings())
	_settings_row(vb, "Fullscreen", fs_check)

	_settings_row(vb, "Master Volume", _make_volume_slider(func() -> float: return vol_master, func(v: float) -> void: vol_master = v))
	_settings_row(vb, "Music Volume", _make_volume_slider(func() -> float: return vol_music, func(v: float) -> void: vol_music = v))
	_settings_row(vb, "SFX Volume", _make_volume_slider(func() -> float: return vol_sfx, func(v: float) -> void: vol_sfx = v))

	_make_button(vb, "Back", func() -> void: _set_game_state(prev_menu_state))

func _settings_row(vb: VBoxContainer, label_text: String, control: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(200, 0)
	label.add_theme_font_size_override("font_size", 22)
	row.add_child(label)
	control.custom_minimum_size = Vector2(220, 36)
	row.add_child(control)
	vb.add_child(row)

func _make_volume_slider(getter: Callable, setter: Callable) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = getter.call()
	slider.value_changed.connect(func(v: float) -> void: setter.call(v); _apply_volumes(); _save_settings())
	return slider

# ---------------------------------------------------------------------------
# Settings persistence
# ---------------------------------------------------------------------------
func _apply_settings() -> void:
	match difficulty:
		0: ai_speed_mult = 0.85; ai_decision_mult = 0.6
		1: ai_speed_mult = 1.0; ai_decision_mult = 1.0
		2: ai_speed_mult = 1.15; ai_decision_mult = 1.5
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	DisplayServer.window_set_mode(mode)
	_apply_volumes()

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(GameConfig.SETTINGS_PATH) == OK:
		difficulty = cfg.get_value("game", "difficulty", difficulty)
		half_length = cfg.get_value("game", "half_length", half_length)
		fullscreen = cfg.get_value("video", "fullscreen", fullscreen)
		vol_master = cfg.get_value("audio", "master", vol_master)
		vol_music = cfg.get_value("audio", "music", vol_music)
		vol_sfx = cfg.get_value("audio", "sfx", vol_sfx)
	_apply_settings()

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("game", "difficulty", difficulty)
	cfg.set_value("game", "half_length", half_length)
	cfg.set_value("video", "fullscreen", fullscreen)
	cfg.set_value("audio", "master", vol_master)
	cfg.set_value("audio", "music", vol_music)
	cfg.set_value("audio", "sfx", vol_sfx)
	cfg.save(GameConfig.SETTINGS_PATH)

func _setup_input_actions() -> void:
	_add_key_action("move_up", KEY_W)
	_add_key_action("move_down", KEY_S)
	_add_key_action("move_left", KEY_A)
	_add_key_action("move_right", KEY_D)
	_add_key_action("shoot", KEY_SPACE)
	_add_joy_button_action("ui_cancel", JOY_BUTTON_START)

func _add_key_action(action: StringName, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	for existing in InputMap.action_get_events(action):
		if existing is InputEventKey and existing.physical_keycode == keycode:
			return
	InputMap.action_add_event(action, event)

func _add_joy_button_action(action: StringName, button_index: JoyButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var event := InputEventJoypadButton.new()
	event.button_index = button_index
	for existing in InputMap.action_get_events(action):
		if existing is InputEventJoypadButton and existing.button_index == button_index:
			return
	InputMap.action_add_event(action, event)

func _create_teams() -> void:
	team_red.clear()
	team_blue.clear()
	var s := 0.2
	var gk_speed := 0.32
	_add_player(team_red, -GameConfig.FIELD_BOUNDARY_X, 0.00, gk_speed, -1, GameConfig.PlayerRole.GOALKEEPER)
	_add_player(team_red, -0.65, 0.25, s, -1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_red, -0.65, -0.25, s, -1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_red, -0.60, 0.50, s, -1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_red, -0.60, -0.50, s, -1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_red, -0.35, 0.00, s, -1, GameConfig.PlayerRole.MIDFIELDER)
	_add_player(team_red, -0.35, 0.30, s, -1, GameConfig.PlayerRole.MIDFIELDER)
	_add_player(team_red, -0.35, -0.30, s, -1, GameConfig.PlayerRole.MIDFIELDER)
	_add_player(team_red, -0.10, 0.00, s, -1, GameConfig.PlayerRole.ATTACKER)
	_add_player(team_red, -0.10, 0.40, s, -1, GameConfig.PlayerRole.ATTACKER)
	_add_player(team_red, -0.10, -0.40, s, -1, GameConfig.PlayerRole.ATTACKER)
	_add_player(team_blue, GameConfig.FIELD_BOUNDARY_X, 0.00, gk_speed, 1, GameConfig.PlayerRole.GOALKEEPER)
	_add_player(team_blue, 0.65, 0.25, s, 1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_blue, 0.65, -0.25, s, 1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_blue, 0.60, 0.50, s, 1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_blue, 0.60, -0.50, s, 1, GameConfig.PlayerRole.DEFENDER)
	_add_player(team_blue, 0.35, 0.00, s, 1, GameConfig.PlayerRole.MIDFIELDER)
	_add_player(team_blue, 0.35, 0.30, s, 1, GameConfig.PlayerRole.MIDFIELDER)
	_add_player(team_blue, 0.35, -0.30, s, 1, GameConfig.PlayerRole.MIDFIELDER)
	_add_player(team_blue, 0.10, 0.00, s, 1, GameConfig.PlayerRole.ATTACKER)
	_add_player(team_blue, 0.10, 0.40, s, 1, GameConfig.PlayerRole.ATTACKER)
	_add_player(team_blue, 0.10, -0.40, s, 1, GameConfig.PlayerRole.ATTACKER)

func _add_player(team: Array[PlayerState], px: float, py: float, speed: float, side: int, role: int) -> void:
	var state := PlayerState.new(px, py, speed, side, role)
	state.node = player_factory._create_player_visual(state)
	players_root.add_child(state.node)
	team.append(state)

func _create_ball() -> void:
	var root := Node3D.new()
	root.name = "Ball3D"
	var mesh := material_factory._mesh("BallMesh", SphereMesh.new(), materials.ball, Vector3.ZERO)
	mesh.mesh.radius = 0.24
	mesh.mesh.height = 0.48
	root.add_child(mesh)
	var glow := OmniLight3D.new()
	glow.name = "SpecialShotLight"
	glow.light_color = Color(1.0, 0.75, 0.18)
	glow.light_energy = 0.0
	glow.omni_range = 5.0
	root.add_child(glow)
	ball.node = root
	ball.light = glow
	ball_root.add_child(root)

func _create_ball_trail() -> void:
	for i in 10:
		var trail := material_factory._mesh("BallTrail%d" % i, SphereMesh.new(), materials.trail, Vector3.ZERO)
		trail.mesh.radius = 0.12 - float(i) * 0.007
		trail.mesh.height = trail.mesh.radius * 2.0
		trail.visible = false
		vfx_root.add_child(trail)
		ball_trail.append(trail)

func _reset_game(kickoff_side: int) -> void:
	ball.x = 0.0
	ball.y = 0.0
	ball.vx = 0.0
	ball.vy = 0.0
	ball.is_super_shot = false
	ball.charging_power = 0.0
	ball.spin = 0.0
	ball_trail_points.clear()
	for trail in ball_trail:
		trail.visible = false
	_clear_owner()
	_reset_players(team_red)
	_reset_players(team_blue)
	var kickoff_team := _team_index_for_side(kickoff_side)
	_set_owner(kickoff_team, 5)
	var owner := _owner_player()
	if owner != null:
		owner.x = 0.0
		owner.y = 0.0
	kickoff_timer = 2.0

func _reset_players(team: Array[PlayerState]) -> void:
	for p in team:
		p.x = p.start_x
		p.y = p.start_y
		p.facing_x = float(p.side)
		p.facing_y = 0.0
		p.stun_timer = 0.0
		p.kick_power = 0.0
		p.hold_timer = 0.0
		p.is_moving = false

func _team_index_for_side(side: int) -> int:
	if not team_red.is_empty() and team_red[0].side == side:
		return 0
	return 1

func _read_input() -> void:
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
	var mouse := get_viewport().get_mouse_position()
	var origin := camera_3d.project_ray_origin(mouse)
	var dir := camera_3d.project_ray_normal(mouse)
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(origin, dir)
	if hit == null:
		return Vector2.ZERO
	return Vector2(hit.x / GameConfig.FIELD_SCALE, -hit.z / GameConfig.FIELD_SCALE)

func _update_kickoff(delta: float) -> void:
	if kickoff_timer > 0.0:
		kickoff_timer = maxf(0.0, kickoff_timer - delta)

func _update_ball(delta: float) -> int:
	var owner := _owner_player()
	if owner != null:
		ball.x = owner.x + owner.facing_x * 0.035
		ball.y = owner.y + owner.facing_y * 0.035
		ball.vx = 0.0
		ball.vy = 0.0
		return 0
	ball.x += ball.vx * delta
	ball.y += ball.vy * delta
	var frame_friction := pow(ball.friction, delta * 60.0)
	ball.vx *= frame_friction
	ball.vy *= frame_friction
	ball.spin *= frame_friction
	var radius := 0.015
	var hit_x := false
	var hit_y := false
	if ball.x > GameConfig.FIELD_BOUNDARY_X - radius:
		ball.x = GameConfig.FIELD_BOUNDARY_X - radius
		hit_x = true
	elif ball.x < -GameConfig.FIELD_BOUNDARY_X + radius:
		ball.x = -GameConfig.FIELD_BOUNDARY_X + radius
		hit_x = true
	if ball.y > GameConfig.FIELD_BOUNDARY_Y - radius:
		ball.y = GameConfig.FIELD_BOUNDARY_Y - radius
		hit_y = true
	elif ball.y < -GameConfig.FIELD_BOUNDARY_Y + radius:
		ball.y = -GameConfig.FIELD_BOUNDARY_Y + radius
		hit_y = true
	if hit_y:
		ball.vy *= -1.0
	if hit_x:
		if absf(ball.y) > GameConfig.GOAL_HALF_WIDTH:
			ball.vx *= -1.0
		elif ball.x > 0.0:
			return _score_goal_against(1)
		else:
			return _score_goal_against(-1)
	return 0

func _score_goal_against(goal_side: int) -> int:
	var scoring_side := -goal_side
	if _team_index_for_side(scoring_side) == 0:
		score_left += 1
		_reset_game(goal_side)
		return -1
	score_right += 1
	_reset_game(goal_side)
	return 1

func _update_team(team: Array[PlayerState], opponents: Array[PlayerState], team_idx: int, is_user_team: bool, delta: float) -> void:
	var user_idx := _nearest_user_player(team, team_idx) if is_user_team else -1
	selected_index[team_idx] = user_idx
	var snap: InputSnapshot = inputs[team_idx] if is_user_team else null
	for i in team.size():
		var p := team[i]
		p.is_moving = false
		if kickoff_timer <= 0.0 and i == user_idx and _has_user_input(snap, p):
			_update_user_player(p, snap, team_idx, i, delta)
		elif kickoff_timer <= 0.0:
			_update_ai_player(p, team, opponents, team_idx, i, delta)
		if kickoff_timer <= 0.0:
			_try_capture_ball(team, team_idx, i)

func _has_user_input(snap: InputSnapshot, p: PlayerState) -> bool:
	return snap.axis != Vector2.ZERO or snap.shoot_held or snap.shoot_prev or p.kick_power > 0.0

func _nearest_user_player(team: Array[PlayerState], team_idx: int) -> int:
	var best := -1
	var best_dist := INF
	for i in team.size():
		if team[i].role == GameConfig.PlayerRole.GOALKEEPER and not (ball.owner_team == team_idx and ball.owner_index == i):
			continue
		var d := Vector2(team[i].x - ball.x, team[i].y - ball.y).length()
		if d < best_dist:
			best = i
			best_dist = d
	return best

func _update_user_player(p: PlayerState, snap: InputSnapshot, team_idx: int, player_idx: int, delta: float) -> void:
	if p.stun_timer > 0.0:
		p.stun_timer -= delta
	var speed_mult := 0.3 if p.stun_timer > 0.0 else 1.0
	if p.kick_power > 0.0:
		speed_mult *= 0.8
	if snap.axis != Vector2.ZERO:
		p.x += snap.axis.x * p.speed * speed_mult * delta
		p.y += snap.axis.y * p.speed * speed_mult * delta
		p.facing_x = snap.axis.x if snap.axis.x != 0.0 else p.facing_x
		p.facing_y = snap.axis.y if snap.axis.y != 0.0 else p.facing_y
		p.is_moving = true
		_clamp_player(p)
	if ball.owner_team == team_idx and ball.owner_index == player_idx:
		ball.charging_power = p.kick_power
		if snap.shoot_held:
			p.kick_power = minf(1.0, p.kick_power + delta * 2.0)
		elif snap.shoot_prev:
			_kick_from_player(p, _aim_target(snap, p), p.kick_power, true)
	else:
		p.kick_power = 0.0
		if ball.owner_team != team_idx or ball.owner_index != player_idx:
			ball.charging_power = 0.0

func _aim_target(snap: InputSnapshot, p: PlayerState) -> Vector2:
	if snap.aim_absolute:
		return snap.aim_vec
	var dir := snap.aim_vec if snap.aim_vec != Vector2.ZERO else Vector2(p.facing_x, p.facing_y)
	return Vector2(p.x, p.y) + dir

func _update_ai_player(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], team_idx: int, player_idx: int, delta: float) -> void:
	if p.stun_timer > 0.0:
		p.stun_timer -= delta
	var current_speed := p.speed * ai_speed_mult * (0.3 if p.stun_timer > 0.0 else 1.0)
	if p.role == GameConfig.PlayerRole.GOALKEEPER:
		if ball.owner_team == team_idx and ball.owner_index == player_idx:
			p.hold_timer += delta
			if p.hold_timer > 1.0:
				var clear_target := _best_pass_target(p, team, opponents, -float(p.side) * GameConfig.FIELD_BOUNDARY_X)
				if clear_target != null:
					_kick_from_player(p, Vector2(clear_target.x, clear_target.y), 0.45, false)
				else:
					_kick_from_player(p, Vector2(-float(p.side) * 0.3, randf_range(-0.5, 0.5)), 0.7, false)
			return
		p.hold_timer = 0.0
		var target_y := clampf(ball.y, -GameConfig.GOAL_HALF_WIDTH, GameConfig.GOAL_HALF_WIDTH)
		var target_x := -GameConfig.FIELD_BOUNDARY_X if p.side == -1 else GameConfig.FIELD_BOUNDARY_X
		_move_towards(p, Vector2(target_x, target_y), current_speed, delta)
		return
	if ball.owner_team == team_idx and ball.owner_index == player_idx:
		_update_ai_owner(p, team, opponents, delta)
		return
	var own_team_has_ball := ball.owner_team == team_idx
	var target := Vector2(p.start_x, p.start_y)
	if own_team_has_ball:
		var attack_dir := -float(p.side)
		var advance := 0.25 if p.role == GameConfig.PlayerRole.DEFENDER else (0.50 if p.role == GameConfig.PlayerRole.MIDFIELDER else 0.78)
		target = Vector2(p.start_x + attack_dir * advance, p.start_y * 0.85 + ball.y * 0.15)
	else:
		var ball_owner := _owner_player()
		if ball_owner != null and ball_owner.role == GameConfig.PlayerRole.GOALKEEPER:
			target = Vector2(p.start_x, p.start_y)
		elif _is_presser(team, player_idx, 1 if _ball_in_own_third(p.side) else 2):
			target = Vector2(ball.x, ball.y)
		else:
			var ball_y_weight := 0.14 if _ball_in_own_third(p.side) else 0.25
			target = Vector2(p.start_x + (ball.x - p.start_x) * 0.2, p.start_y + (ball.y - p.start_y) * ball_y_weight)
			if _ball_in_own_third(p.side):
				var deepest_x := GameConfig.FIELD_BOUNDARY_X - (0.14 if p.role == GameConfig.PlayerRole.DEFENDER else 0.24)
				if p.side == 1:
					target.x = minf(target.x, deepest_x)
				else:
					target.x = maxf(target.x, -deepest_x)
	for mate in team:
		if mate == p:
			continue
		var away := Vector2(p.x - mate.x, p.y - mate.y)
		var d := away.length()
		if d < 0.20 and d > 0.001:
			target += away / d * 0.14
	_move_towards(p, target, current_speed * (0.88 if own_team_has_ball else 0.95), delta)

func _is_presser(team: Array[PlayerState], player_idx: int, press_limit: int) -> bool:
	var my_dist := Vector2(team[player_idx].x - ball.x, team[player_idx].y - ball.y).length()
	var closer := 0
	for i in team.size():
		if i == player_idx or team[i].role == GameConfig.PlayerRole.GOALKEEPER:
			continue
		if Vector2(team[i].x - ball.x, team[i].y - ball.y).length() < my_dist:
			closer += 1
			if closer >= press_limit:
				return false
	return true

func _ball_in_own_third(side: int) -> bool:
	return ball.x * float(side) > 0.58

func _update_ai_owner(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], delta: float) -> void:
	var target_goal_x := GameConfig.FIELD_BOUNDARY_X if p.side == -1 else -GameConfig.FIELD_BOUNDARY_X
	var dist_to_goal := Vector2(target_goal_x - p.x, -p.y).length()
	if dist_to_goal < 0.40 and randf() < 2.4 * ai_decision_mult * delta:
		_kick_from_player(p, Vector2(target_goal_x, 0.0), 0.75, false)
		ball.is_super_shot = true
		return
	if randf() < 1.8 * ai_decision_mult * delta:
		var target := _best_pass_target(p, team, opponents, target_goal_x)
		if target != null:
			_kick_from_player(p, Vector2(target.x, target.y), 0.35, false)
			return
	var dribble := Vector2(target_goal_x - p.x, -p.y * 0.25)
	if dribble.length() > 0.001:
		dribble = dribble.normalized()
		p.x += dribble.x * p.speed * 0.8 * delta
		p.y += dribble.y * p.speed * 0.8 * delta
		p.facing_x = dribble.x
		p.facing_y = dribble.y
		p.is_moving = true
		_clamp_player(p)

func _best_pass_target(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], target_goal_x: float) -> PlayerState:
	var best: PlayerState = null
	var best_score := -999.0
	var owner_goal_dist := Vector2(target_goal_x - p.x, -p.y).length()
	for mate in team:
		if mate == p or mate.role == GameConfig.PlayerRole.GOALKEEPER:
			continue
		var mate_goal_dist := Vector2(target_goal_x - mate.x, -mate.y).length()
		if mate_goal_dist >= owner_goal_dist:
			continue
		var open := true
		for opp in opponents:
			if Vector2(opp.x - mate.x, opp.y - mate.y).length() < 0.18:
				open = false
		var role_bonus := 4.0 if mate.role == GameConfig.PlayerRole.ATTACKER else (2.0 if mate.role == GameConfig.PlayerRole.MIDFIELDER else 0.0)
		var candidate := role_bonus + 1.0 / (1.0 + Vector2(mate.x - p.x, mate.y - p.y).length())
		if open and candidate > best_score:
			best_score = candidate
			best = mate
	return best

func _kick_from_player(p: PlayerState, target: Vector2, power: float, user_shot: bool) -> void:
	var dir := target - Vector2(p.x, p.y)
	if dir.length() <= 0.001:
		dir = Vector2(p.facing_x, p.facing_y)
	if dir.length() <= 0.001:
		dir = Vector2(float(p.side), 0.0)
	dir = dir.normalized()
	p.facing_x = dir.x
	p.facing_y = dir.y
	var final_power := 0.55 + power * 1.2
	ball.vx = dir.x * final_power
	ball.vy = dir.y * final_power
	ball.spin = final_power * 8.0
	var target_goal_x := GameConfig.FIELD_BOUNDARY_X if p.side == -1 else -GameConfig.FIELD_BOUNDARY_X
	var dist_to_goal := Vector2(target_goal_x - p.x, -p.y).length()
	ball.is_super_shot = user_shot and power > 0.5 and dist_to_goal < 0.65
	ball.charging_power = 0.0
	p.kick_power = 0.0
	p.hold_timer = 0.0
	p.stun_timer = 0.25 if power > 0.5 else 0.1
	_clear_owner()
	ball.x += ball.vx * 0.025
	ball.y += ball.vy * 0.025
	_play_kick()
	p.play_action("kick", 0.7)

func _try_capture_ball(team: Array[PlayerState], team_idx: int, player_idx: int) -> void:
	var p := team[player_idx]
	var capture_radius := 0.045
	if p.role == GameConfig.PlayerRole.GOALKEEPER:
		capture_radius = 0.05 if ball.is_super_shot else 0.10
	if Vector2(p.x - ball.x, p.y - ball.y).length() < capture_radius:
		if ball.owner_team == -1 and p.stun_timer <= 0.0:
			_set_owner(team_idx, player_idx)
			p.play_action("receive", 0.45)
		elif ball.owner_team != -1 and _owner_side() != p.side and p.stun_timer <= 0.0:
			var old := _owner_player()
			if old != null and old.role != GameConfig.PlayerRole.GOALKEEPER:
				old.stun_timer = 0.45
				old.kick_power = 0.0
				_set_owner(team_idx, player_idx)
				p.play_action("tackle", 0.55)

func _move_towards(p: PlayerState, target: Vector2, current_speed: float, delta: float) -> void:
	var diff := target - Vector2(p.x, p.y)
	if diff.length() > 0.005:
		var dir := diff.normalized()
		p.x += dir.x * current_speed * delta
		p.y += dir.y * current_speed * delta
		p.facing_x = dir.x
		p.facing_y = dir.y
		p.is_moving = true
		_clamp_player(p)

func _clamp_player(p: PlayerState) -> void:
	var half := 0.025
	if p.role == GameConfig.PlayerRole.GOALKEEPER:
		var area_limit := GameConfig.FIELD_BOUNDARY_X - GameConfig.PENALTY_AREA_WIDTH
		if p.side == -1:
			p.x = clampf(p.x, -GameConfig.FIELD_BOUNDARY_X + half, -area_limit + half)
		else:
			p.x = clampf(p.x, area_limit - half, GameConfig.FIELD_BOUNDARY_X - half)
		p.y = clampf(p.y, -GameConfig.PENALTY_AREA_HEIGHT + half, GameConfig.PENALTY_AREA_HEIGHT - half)
	else:
		p.x = clampf(p.x, -GameConfig.FIELD_BOUNDARY_X + half, GameConfig.FIELD_BOUNDARY_X - half)
		p.y = clampf(p.y, -GameConfig.FIELD_BOUNDARY_Y + half, GameConfig.FIELD_BOUNDARY_Y - half)

func _update_visuals(delta: float) -> void:
	for i in team_red.size():
		_update_player_visual(team_red[i], ball.owner_team == 0 and ball.owner_index == i, delta)
	for i in team_blue.size():
		_update_player_visual(team_blue[i], ball.owner_team == 1 and ball.owner_index == i, delta)
	_update_ball_visual(delta)
	_update_camera(delta)
	if celebration_timer > 0.0:
		celebration_timer = maxf(0.0, celebration_timer - delta)

func _update_player_visual(p: PlayerState, owns_ball: bool, delta: float) -> void:
	if p.node == null:
		return
	if p.uses_glb:
		_update_glb_player_visual(p, owns_ball, delta)
		return
	p.node.position = GameConfig.to_3d(Vector2(p.x, p.y), 0.0)
	var face := Vector3(p.facing_x, 0.0, -p.facing_y)
	if face.length() > 0.001:
		p.node.rotation.y = atan2(face.x, face.z)
	var swing := sin(Time.get_ticks_msec() * 0.012) * (0.55 if p.is_moving else 0.08)
	(p.node.get_node("ArmL") as Node3D).rotation.x = swing
	(p.node.get_node("ArmR") as Node3D).rotation.x = -swing
	(p.node.get_node("LegL") as Node3D).rotation.x = -swing
	(p.node.get_node("LegR") as Node3D).rotation.x = swing
	var is_selected := (p.team_index == 0 and team_red.find(p) == selected_index[0]) or (p.team_index == 1 and num_players == 2 and team_blue.find(p) == selected_index[1])
	(p.node.get_node("SelectedRing") as Node3D).visible = owns_ball or is_selected
	var power_ring := p.node.get_node("PowerRing") as Node3D
	power_ring.visible = p.kick_power > 0.01
	power_ring.scale = Vector3.ONE * (0.55 + p.kick_power * 0.55)
	if p.is_moving:
		p.node.position.y = absf(sin(Time.get_ticks_msec() * 0.018)) * 0.05
	else:
		p.node.position.y = 0.0

func _update_glb_player_visual(p: PlayerState, owns_ball: bool, delta: float) -> void:
	p.node.position = GameConfig.to_3d(Vector2(p.x, p.y), 0.0)
	var face := Vector3(p.facing_x, 0.0, -p.facing_y)
	if face.length() > 0.001:
		p.node.rotation.y = atan2(face.x, face.z)
	if p.action_timer > 0.0:
		p.action_timer = maxf(0.0, p.action_timer - delta)
	else:
		if p.role == GameConfig.PlayerRole.GOALKEEPER:
			p.set_visual_state("run" if p.is_moving else "gk_idle")
		else:
			p.set_visual_state("run" if p.is_moving else "idle")
	var is_selected := (p.team_index == 0 and team_red.find(p) == selected_index[0]) or (p.team_index == 1 and num_players == 2 and team_blue.find(p) == selected_index[1])
	(p.node.get_node("SelectedRing") as Node3D).visible = owns_ball or is_selected
	var power_ring := p.node.get_node("PowerRing") as Node3D
	power_ring.visible = p.kick_power > 0.01
	power_ring.scale = Vector3.ONE * (0.55 + p.kick_power * 0.55)

func _update_ball_visual(delta: float) -> void:
	if ball.node == null:
		return
	var speed := Vector2(ball.vx, ball.vy).length()
	var visual_height := 0.26 + minf(0.55, speed * 0.22)
	ball.node.position = GameConfig.to_3d(Vector2(ball.x, ball.y), visual_height)
	ball.node.rotate_x(speed * delta * 14.0)
	ball.node.rotate_z(ball.spin * delta)
	ball.light.light_energy = ball.charging_power * 4.0 + (2.5 if ball.is_super_shot and speed > 0.05 else 0.0)
	ball.light.light_color = Color(1.0, 0.82, 0.20) if ball.charging_power > 0.5 or ball.is_super_shot else Color(0.1, 0.7, 1.0)
	_update_ball_trail(speed)

func _update_ball_trail(speed: float) -> void:
	if speed > 0.04:
		ball_trail_points.push_front(ball.node.position)
	if ball_trail_points.size() > ball_trail.size():
		ball_trail_points.resize(ball_trail.size())
	for i in ball_trail.size():
		var trail := ball_trail[i]
		if i < ball_trail_points.size() and speed > 0.04:
			trail.visible = true
			trail.position = ball_trail_points[i]
			trail.scale = Vector3.ONE * (1.0 - float(i) * 0.07)
		else:
			trail.visible = false

func _update_camera(delta: float) -> void:
	if camera_rig == null or camera_3d == null:
		return
	var target_pos := Vector3(clampf(ball.x * GameConfig.FIELD_SCALE * 0.25, -5.0, 5.0), 18.0, 24.0 + clampf(-ball.y * GameConfig.FIELD_SCALE * 0.12, -2.5, 2.5))
	camera_rig.position = camera_rig.position.lerp(target_pos, 1.0 - exp(-1.8 * delta))
	camera_look = camera_look.lerp(GameConfig.to_3d(Vector2(ball.x, ball.y), 0.2), 1.0 - exp(-3.5 * delta))
	camera_3d.look_at(camera_look, Vector3.UP)

func _update_scoreboard() -> void:
	if score_label != null:
		score_label.text = "%d - %d" % [score_left, score_right]
	if timer_label != null:
		if game_state != GameConfig.GameState.PLAYING:
			timer_label.text = ""
		elif kickoff_timer > 0.0:
			timer_label.text = "Kickoff %.1f" % kickoff_timer
		else:
			var remaining := int(ceil(maxf(0.0, half_length - match_time)))
			timer_label.text = "%d:%02d  -  %s Half" % [remaining / 60, remaining % 60, "1st" if current_half == 1 else "2nd"]

func _trigger_goal(_scorer: int) -> void:
	celebration_timer = 1.5
	_spawn_confetti()
	_play_whistle()

func _spawn_confetti() -> void:
	for i in 72:
		var mat: Material = materials.confetti_gold
		if i % 3 == 0:
			mat = materials.confetti_red
		elif i % 3 == 1:
			mat = materials.confetti_blue
		var piece := material_factory._mesh("Confetti", BoxMesh.new(), mat, GameConfig.to_3d(Vector2(randf_range(-0.75, 0.75), randf_range(-0.55, 0.55)), randf_range(2.2, 4.2)))
		piece.mesh.size = Vector3(0.10, 0.035, 0.16)
		vfx_root.add_child(piece)
		var velocity := Vector3(randf_range(-2.0, 2.0), randf_range(2.0, 4.4), randf_range(-2.0, 2.0))
		confetti.append(VfxParticle.new(piece, velocity, randf_range(1.2, 2.3)))

func _update_confetti(delta: float) -> void:
	for i in range(confetti.size() - 1, -1, -1):
		var p := confetti[i]
		p.life -= delta
		p.velocity.y -= 4.8 * delta
		p.node.position += p.velocity * delta
		p.node.rotate_x(delta * 8.0)
		p.node.rotate_y(delta * 10.0)
		if p.life <= 0.0:
			p.node.queue_free()
			confetti.remove_at(i)

func _set_owner(team_idx: int, player_idx: int) -> void:
	ball.owner_team = team_idx
	ball.owner_index = player_idx
	ball.is_super_shot = false
	ball.charging_power = 0.0

func _clear_owner() -> void:
	ball.owner_team = -1
	ball.owner_index = -1
	ball.charging_power = 0.0

func _owner_player() -> PlayerState:
	if ball.owner_team == 0 and ball.owner_index >= 0 and ball.owner_index < team_red.size():
		return team_red[ball.owner_index]
	if ball.owner_team == 1 and ball.owner_index >= 0 and ball.owner_index < team_blue.size():
		return team_blue[ball.owner_index]
	return null

func _owner_side() -> int:
	var owner := _owner_player()
	return owner.side if owner != null else 0
