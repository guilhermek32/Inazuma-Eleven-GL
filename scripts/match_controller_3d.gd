extends Node3D

## Match controller / orchestrator for the 3D build.
##
## This is the script attached to scenes/main_3d.tscn. It owns no gameplay or
## rendering logic itself: _ready() builds the scene roots and wires the focused
## modules together (config/, data/, build/, systems/), _process() delegates to
## the simulation and the view, and the rest is the game-state machine and match
## clock. See CLAUDE.md for the module map.

# Scene roots (created in _build_scene_roots, populated by the builders)
var camera_rig: Node3D
var camera_3d: Camera3D
var pitch_root: Node3D
var lines_root: Node3D
var goals_root: Node3D
var stadium_root: Node3D
var players_root: Node3D
var ball_root: Node3D
var vfx_root: Node3D

# Subsystems
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
var setup: MatchSetup
var sim: MatchSimulation
var view: MatchView

# Game state / flow
var game_state := GameConfig.GameState.MENU
var prev_menu_state := GameConfig.GameState.MENU
var match_time := 0.0
var current_half := 1
var halftime_pause := 0.0
# Goal celebration: play freezes for this long after a goal (confetti + GOAL! banner +
# crowd roar) before the field resets for the next kickoff.
var goal_freeze := 0.0
# Wall-clock (ms) at which a special-shot slow-mo should end; 0 when not slowed.
var slowmo_until_ms := 0

const GOAL_FREEZE_TIME := 2.2
const SLOWMO_SCALE := 0.45
const SLOWMO_MS := 520

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
	# Build and bake the GI probe over the static scene now — the procedural meshes
	# are already in the tree, and baking here (before players are created) keeps the
	# dynamic players out of the probe so only the static neon hoardings
	# bounce coloured light onto the pitch.
	stadium_builder._build_gi()
	stadium_builder._bake_gi()
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
	view._create_grass_marks()
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
	setup = MatchSetup.new()
	add_child(setup)
	setup.controller = self
	setup.sim = sim
	setup.build()
	sim._reset_game(1)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_set_game_state(GameConfig.GameState.MENU)
	print("Inazuma Eleven 3D environment ready")

func _process(delta: float) -> void:
	_update_time_scale()
	if game_state == GameConfig.GameState.PLAYING:
		if halftime_pause > 0.0:
			halftime_pause = maxf(0.0, halftime_pause - delta)
		elif goal_freeze > 0.0:
			goal_freeze = maxf(0.0, goal_freeze - delta)
			if goal_freeze <= 0.0:
				sim._reset_game(sim.pending_kickoff_side)
		else:
			input_reader.read(sim.inputs, sim.team_device, sim.kickoff_timer)
			var scorer := sim.step(delta)
			if not sim.pending_special.is_empty():
				_begin_special_shot(sim.pending_special)
				sim.pending_special = {}
			if scorer != 0:
				_begin_goal_celebration(scorer)
			else:
				_update_match_clock(delta)
		view._update_visuals(delta)
	elif game_state == GameConfig.GameState.MATCH_SETUP:
		setup.update(delta)
	view._update_confetti(delta)
	hud.update(sim.score_left, sim.score_right, game_state, sim.kickoff_timer, settings.half_length, match_time, current_half)

## Restores normal speed once a special-shot slow-mo has run its (wall-clock) course.
func _update_time_scale() -> void:
	if slowmo_until_ms > 0 and Time.get_ticks_msec() >= slowmo_until_ms:
		slowmo_until_ms = 0
		Engine.time_scale = 1.0

func _begin_special_shot(info: Dictionary) -> void:
	slowmo_until_ms = Time.get_ticks_msec() + SLOWMO_MS
	Engine.time_scale = SLOWMO_SCALE
	hud.show_banner("%s!" % info.name, info.color, 1.1, false)
	audio._play_special()

func _begin_goal_celebration(scorer: int) -> void:
	# Drop any active slow-mo, then freeze the field for the celebration. The confetti
	# and whistle already fired inside sim.step(); the reset waits for the freeze to end.
	Engine.time_scale = 1.0
	slowmo_until_ms = 0
	goal_freeze = GOAL_FREEZE_TIME
	var col := Color(0.88, 0.20, 0.16) if scorer < 0 else Color(0.22, 0.38, 0.96)
	hud.show_banner("GOAL!", col, GOAL_FREEZE_TIME)
	audio._play_crowd_roar()

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		match game_state:
			GameConfig.GameState.PLAYING:
				_set_game_state(GameConfig.GameState.PAUSED)
			GameConfig.GameState.PAUSED:
				_set_game_state(GameConfig.GameState.PLAYING)
			GameConfig.GameState.HOWTO, GameConfig.GameState.SETTINGS:
				_set_game_state(prev_menu_state)
			GameConfig.GameState.MATCH_SETUP:
				# Only the keyboard Esc backs out here; the pad's Start/A are
				# MatchSetup's "begin match" confirm, so don't let Start (also bound
				# to ui_cancel) double as a cancel and bounce us back to the menu.
				if event is InputEventKey:
					_set_game_state(GameConfig.GameState.MENU)
		get_viewport().set_input_as_handled()

func _set_game_state(next: int) -> void:
	# Never leave the world in slow-mo when we step out of live play (pause, menus, …).
	if next != GameConfig.GameState.PLAYING:
		Engine.time_scale = 1.0
		slowmo_until_ms = 0
	if next == GameConfig.GameState.HOWTO or next == GameConfig.GameState.SETTINGS:
		prev_menu_state = game_state if game_state in [GameConfig.GameState.MENU, GameConfig.GameState.PAUSED] else GameConfig.GameState.MENU
	var leaving_setup := game_state == GameConfig.GameState.MATCH_SETUP and next != GameConfig.GameState.MATCH_SETUP
	game_state = next
	view._set_glb_animations_paused(next != GameConfig.GameState.PLAYING)
	if next == GameConfig.GameState.MATCH_SETUP:
		setup.enter()
	elif leaving_setup:
		setup.exit()
	menu.show_for_state(next)

func _start_match() -> void:
	sim.score_left = 0
	sim.score_right = 0
	match_time = 0.0
	current_half = 1
	halftime_pause = 0.0
	goal_freeze = 0.0
	Engine.time_scale = 1.0
	slowmo_until_ms = 0
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
			hud.show_banner("HALF TIME", Color(1.0, 0.95, 0.55), 2.0)
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
	if game_state == GameConfig.GameState.MATCH_SETUP:
		setup.enter()

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
