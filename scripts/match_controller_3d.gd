extends Node3D




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
var input_reader: InputReader
var ai: AIController
var hud: MatchHud
var audio: AudioManager
var settings: SettingsStore
var menu: MenuManager
var sim: MatchSimulation
var view: MatchView

# Game state / flow
var game_state := GameConfig.GameState.MENU
var prev_menu_state := GameConfig.GameState.MENU
var num_players := 1
var match_time := 0.0
var current_half := 1
var halftime_pause := 0.0

# Settings (defaults; overridden by _load_settings)

# Menu / audio nodes

func _ready() -> void:
	material_factory = MaterialFactory.new()
	material_factory._build_materials()
	_build_scene_roots()
	stadium_builder = StadiumBuilder.new()
	stadium_builder.mf = material_factory
	stadium_builder.host = self
	stadium_builder.stadium_root = stadium_root
	stadium_builder._build_environment()
	stadium_builder._build_camera()
	camera_rig = stadium_builder.camera_rig
	camera_3d = stadium_builder.camera_3d
	input_reader = InputReader.new()
	input_reader.camera_3d = camera_3d
	stadium_builder._build_lighting()
	pitch_builder = PitchBuilder.new()
	pitch_builder.mf = material_factory
	pitch_builder.pitch_root = pitch_root
	pitch_builder.lines_root = lines_root
	pitch_builder.goals_root = goals_root
	pitch_builder._build_pitch()
	pitch_builder._build_goals()
	stadium_builder._build_stadium()
	hud = MatchHud.new()
	add_child(hud)
	hud._build_ui()
	settings = SettingsStore.new()
	settings._setup_input_actions()
	player_factory = PlayerFactory.new()
	player_factory.mf = material_factory
	ai = AIController.new()
	sim = MatchSimulation.new()
	add_child(sim)
	view = MatchView.new()
	add_child(view)
	sim.players_root = players_root
	sim.player_factory = player_factory
	sim.ai = ai
	sim.settings = settings
	sim.view = view
	ai.sim = sim
	view.sim = sim
	view.material_factory = material_factory
	view.ball_root = ball_root
	view.vfx_root = vfx_root
	view.camera_rig = camera_rig
	view.camera_3d = camera_3d
	sim._create_teams()
	view._create_ball()
	view._create_ball_trail()
	audio = AudioManager.new()
	add_child(audio)
	audio._build_audio()
	sim.audio = audio
	view.audio = audio
	settings.audio = audio
	settings._load_settings()
	menu = MenuManager.new()
	add_child(menu)
	menu.controller = self
	menu.settings = settings
	menu._build_menus()
	sim._reset_game(1)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_set_game_state(GameConfig.GameState.MENU)
	print("Inazuma Eleven 3D environment ready")

func _process(delta: float) -> void:
	if game_state == GameConfig.GameState.PLAYING:
		if halftime_pause > 0.0:
			halftime_pause = maxf(0.0, halftime_pause - delta)
		else:
			input_reader.read(sim.inputs, num_players, sim.kickoff_timer)
			sim.step(delta, num_players)
			_update_match_clock(delta)
		view._update_visuals(delta, num_players)
	view._update_confetti(delta)
	hud.update(sim.score_left, sim.score_right, game_state, sim.kickoff_timer, settings.half_length, match_time, current_half)

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
	view._set_glb_animations_paused(next != GameConfig.GameState.PLAYING)
	if next == GameConfig.GameState.MENU:
		menu._refresh_two_player_availability()
	menu.show_for_state(next)

func _start_match() -> void:
	sim.score_left = 0
	sim.score_right = 0
	match_time = 0.0
	current_half = 1
	halftime_pause = 0.0
	sim._set_default_ends()
	sim._reset_game(1)
	_set_game_state(GameConfig.GameState.PLAYING)
	audio._play_whistle()

func _update_match_clock(delta: float) -> void:
	match_time += delta
	if match_time >= settings.half_length:
		if current_half == 1:
			current_half = 2
			match_time = 0.0
			halftime_pause = 2.0
			sim._switch_ends()
			sim._reset_game(1)
			audio._play_whistle()
		else:
			_end_match()

func _end_match() -> void:
	audio._play_whistle()
	var result := "DRAW"
	if sim.score_left > sim.score_right:
		result = "RED WINS"
	elif sim.score_right > sim.score_left:
		result = "BLUE WINS"
	menu.set_fulltime_text("FULL TIME\n%d - %d\n%s" % [sim.score_left, sim.score_right, result])
	_set_game_state(GameConfig.GameState.FULLTIME)

func _on_joy_connection_changed(_device: int, _connected: bool) -> void:
	if game_state == GameConfig.GameState.MENU:
		menu._refresh_two_player_availability()

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

# ---------------------------------------------------------------------------
# Audio
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Settings persistence
# ---------------------------------------------------------------------------