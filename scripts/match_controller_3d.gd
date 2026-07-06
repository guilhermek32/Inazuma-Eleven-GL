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
	material_factory.build_materials()
	_build_scene_roots()
	stadium_builder = StadiumBuilder.new()
	stadium_builder.mf = material_factory
	stadium_builder.host = self
	stadium_builder.stadium_root = stadium_root
	stadium_builder.build_environment()
	stadium_builder.build_camera()
	camera_rig = stadium_builder.camera_rig
	camera_3d = stadium_builder.camera_3d
	input_reader = InputReader.new()
	input_reader.camera_3d = camera_3d
	stadium_builder.build_lighting()
	pitch_builder = PitchBuilder.new()
	pitch_builder.mf = material_factory
	pitch_builder.pitch_root = pitch_root
	pitch_builder.lines_root = lines_root
	pitch_builder.goals_root = goals_root
	pitch_builder.build_pitch()
	pitch_builder.build_goals()
	stadium_builder.build_stadium()
	# Build and bake the GI probe over the static scene now — the procedural meshes
	# are already in the tree, and baking here (before players are created) keeps the
	# dynamic players out of the probe so only the static neon hoardings
	# bounce coloured light onto the pitch.
	stadium_builder.build_gi()
	stadium_builder.bake_gi()
	hud = MatchHud.new()
	add_child(hud)
	hud.build_ui()
	settings = SettingsStore.new()
	settings.setup_input_actions()
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
	ai.sim = sim
	view.sim = sim
	view.material_factory = material_factory
	view.ball_root = ball_root
	view.vfx_root = vfx_root
	view.camera_rig = camera_rig
	view.camera_3d = camera_3d
	sim.create_teams()
	view.create_ball()
	view.create_ball_trail()
	view.create_grass_marks()
	view.create_confetti()
	audio = AudioManager.new()
	add_child(audio)
	audio.build_audio()
	view.audio = audio
	# Gameplay events -> presentation. The sim never touches view/audio directly.
	sim.goal_scored.connect(view.trigger_goal)
	sim.ball_kicked.connect(audio.play_kick)
	sim.special_fired.connect(_begin_special_shot)
	sim.field_reset.connect(view.reset_trail)
	sim.restart_awarded.connect(_on_restart_awarded)
	settings.audio = audio
	settings.load_settings()
	menu = MenuManager.new()
	add_child(menu)
	menu.controller = self
	menu.settings = settings
	menu.build_menus()
	setup = MatchSetup.new()
	add_child(setup)
	setup.controller = self
	setup.sim = sim
	setup.build()
	sim.reset_game(1)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_set_game_state(GameConfig.GameState.MENU)
	print("Inazuma Eleven 3D environment ready")

# Gameplay advances on the fixed physics tick so shot/capture outcomes don't vary
# with the render frame rate; rendering-side updates stay in _process below.
func _physics_process(delta: float) -> void:
	_update_time_scale()
	if game_state != GameConfig.GameState.PLAYING:
		return
	if halftime_pause > 0.0:
		halftime_pause = maxf(0.0, halftime_pause - delta)
	elif goal_freeze > 0.0:
		goal_freeze = maxf(0.0, goal_freeze - delta)
		if goal_freeze <= 0.0:
			# If the clock already ran out while celebrating the goal,
			# end the half/match instead of restarting for a kickoff.
			if match_time >= settings.half_length:
				_end_half()
			else:
				sim.reset_game(sim.pending_kickoff_side)
	else:
		input_reader.read(sim.teams, sim.restart_timer)
		var scorer := sim.step(delta)
		if scorer != 0:
			_begin_goal_celebration(scorer)
		else:
			_update_match_clock(delta)

func _process(delta: float) -> void:
	if game_state == GameConfig.GameState.PLAYING:
		view.update_visuals(delta)
	elif game_state == GameConfig.GameState.MATCH_SETUP:
		setup.update(delta)
	view.update_confetti(delta)
	hud.update(sim.score_left, sim.score_right, game_state, sim.restart_timer, sim.restart_type, settings.half_length, match_time, current_half, delta)
	hud.update_stamina(_selected_stamina())

## Sprint stamina of each human team's selected player (-1 hides that bar).
func _selected_stamina() -> Array:
	var values := [-1.0, -1.0]
	if game_state != GameConfig.GameState.PLAYING:
		return values
	for t in 2:
		var ts: TeamState = sim.teams[t]
		if ts.is_human() and ts.selected_index >= 0 and ts.selected_index < ts.players.size():
			values[t] = ts.players[ts.selected_index].stamina
	return values

## Restores normal speed once a special-shot slow-mo has run its (wall-clock) course.
func _update_time_scale() -> void:
	if slowmo_until_ms > 0 and Time.get_ticks_msec() >= slowmo_until_ms:
		slowmo_until_ms = 0
		Engine.time_scale = 1.0

func _begin_special_shot(info: Dictionary) -> void:
	slowmo_until_ms = Time.get_ticks_msec() + SLOWMO_MS
	Engine.time_scale = SLOWMO_SCALE
	hud.show_banner("%s!" % info.name, info.color, 1.1, false)
	audio.play_special()

func _on_restart_awarded(type: int, team: int) -> void:
	var labels := {
		MatchSimulation.Restart.THROW_IN: "THROW-IN",
		MatchSimulation.Restart.CORNER: "CORNER KICK",
		MatchSimulation.Restart.GOAL_KICK: "GOAL KICK",
	}
	if not labels.has(type):
		return
	hud.show_banner(labels[type], sim.teams[team].kit.shirt, 1.0, false)
	audio.play_whistle()

func _begin_goal_celebration(scorer: int) -> void:
	# Drop any active slow-mo, then freeze the field for the celebration. The confetti
	# and whistle already fired inside sim.step(); the reset waits for the freeze to end.
	Engine.time_scale = 1.0
	slowmo_until_ms = 0
	goal_freeze = GOAL_FREEZE_TIME
	var col: Color = sim.teams[0].kit.shirt if scorer < 0 else sim.teams[1].kit.shirt
	hud.show_banner("GOAL!", col, GOAL_FREEZE_TIME)
	audio.play_crowd_roar()

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
				# Keyboard Esc steps back: kit page -> Choose Sides, Choose Sides -> menu.
				# The pad's Start/A are MatchSetup's confirm, so (also bound to ui_cancel)
				# they must not double as a cancel here.
				if event is InputEventKey and not setup.back():
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
	view.set_glb_animations_paused(next != GameConfig.GameState.PLAYING)
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
	view.clear_confetti()
	# Rebuild both teams from the formation/kit picked on the Choose Sides screen.
	sim.create_teams()
	hud.set_team_colors(sim.teams[0].kit.shirt, sim.teams[1].kit.shirt)
	sim.set_default_ends()
	sim.reset_game(1)
	_set_game_state(GameConfig.GameState.PLAYING)
	audio.play_whistle()

func _update_match_clock(delta: float) -> void:
	match_time += delta
	if match_time >= settings.half_length:
		_end_half()

## Advances out of the current half: half time after the first, full time after the second.
func _end_half() -> void:
	if current_half == 1:
		current_half = 2
		match_time = 0.0
		halftime_pause = 2.0
		sim.switch_ends()
		sim.reset_game(1)
		audio.play_whistle()
		hud.show_banner("HALF TIME", Color(1.0, 0.95, 0.55), 2.0)
	else:
		_end_match()

func _end_match() -> void:
	audio.play_whistle()
	var result := "DRAW"
	if sim.score_left > sim.score_right:
		result = "TIME A WINS"
	elif sim.score_right > sim.score_left:
		result = "TIME B WINS"
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
