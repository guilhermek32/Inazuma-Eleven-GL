extends Node3D

## Match controller / orchestrator for the 3D build.
##
## This is the script attached to scenes/main_3d.tscn. It owns no gameplay or
## rendering logic itself: _ready() builds the scene roots and wires the focused
## modules together (config/, data/, build/, match/, systems/). The match rules,
## clock and halves live in MatchSession; this controller is the *offline
## adapter* around it: local devices feed it input, and its drained events drive
## the view, HUD and audio. The rest is the UI state machine (menus, pause).
## See CLAUDE.md for the module map.

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
var session: MatchSession
var sim: MatchSimulation   # session.sim, read by the view/HUD for rendering
var view: MatchView

# UI state machine (menus / pause); the match flow itself is session.phase.
var game_state := GameConfig.GameState.MENU
var prev_menu_state := GameConfig.GameState.MENU

# Lineup chosen on the Choose Sides screen, reused by Restart/Rematch.
# Defaults reproduce the 1P setup: red on keyboard+mouse, blue AI.
var _lineup_devices: Array[int] = [GameConfig.DEVICE_KBM, GameConfig.DEVICE_AI]
var _lineup_formations: Array[int] = [GameConfig.DEFAULT_FORMATION, GameConfig.DEFAULT_FORMATION]
var _lineup_kits: Array[Dictionary] = [GameConfig.DEFAULT_KIT_A.duplicate(), GameConfig.DEFAULT_KIT_B.duplicate()]

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
	session = MatchSession.new()
	sim = session.sim
	ai = session.ai
	view = MatchView.new()
	add_child(view)
	view.sim = sim
	view.settings = settings
	view.material_factory = material_factory
	view.ball_root = ball_root
	view.vfx_root = vfx_root
	view.camera_rig = camera_rig
	view.camera_3d = camera_3d
	view.create_ball()
	view.create_ball_trail()
	view.create_grass_marks()
	view.create_confetti()
	audio = AudioManager.new()
	add_child(audio)
	audio.build_audio()
	view.audio = audio
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
	setup.build()
	view.net_materials = pitch_builder.net_materials
	stadium_builder.build_weather()
	_initialize_session()
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_set_game_state(GameConfig.GameState.MENU)
	print("Inazuma Eleven 3D environment ready")

func _exit_tree() -> void:
	session.dispose()

# Gameplay advances on the fixed physics tick so shot/capture outcomes don't vary
# with the render frame rate; rendering-side updates stay in _process below.
func _physics_process(delta: float) -> void:
	if game_state != GameConfig.GameState.PLAYING:
		return
	input_reader.read(sim.teams, sim.restart_timer)
	session.step(delta)
	_dispatch_events()

func _process(delta: float) -> void:
	# The match's slow motion slows its 3D visuals; HUD/menus keep real time.
	var visual_delta := delta * session.time_scale
	if game_state == GameConfig.GameState.PLAYING:
		view.set_glb_animation_speed(session.time_scale)
		view.update_visuals(visual_delta)
	elif game_state == GameConfig.GameState.MATCH_SETUP:
		setup.update(delta)
	view.update_confetti(visual_delta)
	var st := session.read_state()
	hud.update(st.score_left, st.score_right, game_state, st.restart_timer, st.restart_type, st.half_length_s, st.match_time, st.current_half, delta)
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

## Presentation adapter: turns the session's gameplay events into view, HUD
## and audio cues. The session never touches presentation directly.
func _dispatch_events() -> void:
	for ev in session.drain_events():
		match ev.type:
			"goal":
				_on_goal(ev)
			"kick":
				audio.play_kick()
			"special":
				hud.show_banner("%s!" % ev.name, ev.color, 1.1, false)
				audio.play_special()
			"field_reset":
				view.reset_trail()
			"restart":
				_on_restart_awarded(ev.restart_type, ev.team)
			"foul":
				# Fouls/offside show their own banner; the FREE_KICK restart that follows is
				# deliberately absent from _on_restart_awarded's labels so they don't double-fire
				# (the restart still shows as "Free kick" in the HUD timer text).
				hud.show_banner("FOUL!", Color(1.0, 0.85, 0.3), 0.9, false)
				audio.play_whistle()
			"offside":
				hud.show_banner("OFFSIDE", Color(1.0, 0.55, 0.2), 0.9, false)
				audio.play_whistle()
			"player_action":
				sim.teams[ev.team].players[ev.index].play_action(ev.action, ev.duration)
			"half_time":
				audio.play_whistle()
				hud.show_banner("HALF TIME", Color(1.0, 0.95, 0.55), 2.0)
			"full_time":
				_end_match(ev)

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

## Goal: confetti + whistle, the net ripple at the impact point, then the GOAL!
## banner and crowd roar for the session's celebration freeze.
func _on_goal(ev: Dictionary) -> void:
	view.trigger_goal(ev.scorer)
	var impact: Vector3 = ev.impact
	view.trigger_net_ripple(ev.goal_side, GameConfig.to_3d(Vector2(impact.x, impact.y), impact.z + GameConfig.BALL_RADIUS))
	var col: Color = sim.teams[0].kit.shirt if ev.scorer < 0 else sim.teams[1].kit.shirt
	hud.show_banner("GOAL!", col, MatchSession.GOAL_FREEZE_TIME)
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
		session.cancel_slow_motion()
	if next == GameConfig.GameState.HOWTO or next == GameConfig.GameState.SETTINGS:
		prev_menu_state = game_state if game_state in [GameConfig.GameState.MENU, GameConfig.GameState.PAUSED] else GameConfig.GameState.MENU
	var leaving_setup := game_state == GameConfig.GameState.MATCH_SETUP and next != GameConfig.GameState.MATCH_SETUP
	game_state = next
	view.set_glb_animation_speed(session.time_scale if next == GameConfig.GameState.PLAYING else 0.0)
	if next == GameConfig.GameState.MATCH_SETUP:
		setup.enter()
	elif leaving_setup:
		setup.exit()
	menu.show_for_state(next)

## Called by the Choose Sides screen before _start_match(); Restart/Rematch
## reuse the last lineup.
func set_match_lineup(devices: Array[int], formations: Array[int], kits: Array[Dictionary]) -> void:
	_lineup_devices = devices.duplicate()
	_lineup_formations = formations.duplicate()
	_lineup_kits = kits.duplicate(true)

func _start_match() -> void:
	view.clear_confetti()
	_initialize_session()
	hud.set_team_colors(sim.teams[0].kit.shirt, sim.teams[1].kit.shirt)
	hud.reset()
	_set_game_state(GameConfig.GameState.PLAYING)
	audio.play_whistle()

## Starts a fresh session from the lineup + local rule preferences, then
## rebuilds the player visuals for the new PlayerStates.
func _initialize_session() -> void:
	for t in 2:
		session.set_team_device(t, _lineup_devices[t])
	session.initialize(_build_match_config(), randi())
	_rebuild_player_visuals()
	_apply_weather()

## Offline MatchConfig: rules from the saved preferences, teams from the lineup.
## A human-led team's AI teammates play at Normal and an AI team at the chosen
## difficulty, as before the session existed.
func _build_match_config() -> MatchConfig:
	var cfg := MatchConfig.new()
	cfg.half_length_s = clampf(settings.half_length, MatchConfig.MIN_HALF_LENGTH_S, MatchConfig.MAX_HALF_LENGTH_S)
	cfg.fouls_enabled = settings.fouls_enabled
	cfg.offside_enabled = settings.offside_enabled
	cfg.weather = clampi(settings.weather, 0, 1)
	for t in 2:
		cfg.formations[t] = _lineup_formations[t]
		cfg.kits[t] = _lineup_kits[t].duplicate()
		var is_ai := _lineup_devices[t] == GameConfig.DEVICE_AI
		cfg.team_difficulty[t] = clampi(settings.difficulty, 0, 2) if is_ai else MatchConfig.DIFFICULTY_NORMAL
	return cfg

func _rebuild_player_visuals() -> void:
	for child in players_root.get_children():
		players_root.remove_child(child)
		child.queue_free()
	for ts in sim.teams:
		for p in ts.players:
			p.node = player_factory.create_player_visual(p, ts.kit)
			players_root.add_child(p.node)
			var lbl := p.node.get_node_or_null("JerseyNumber") as Label3D
			if lbl:
				lbl.text = str(p.jersey_number)
	view.refresh_animation_speed()

func _end_match(ev: Dictionary) -> void:
	audio.play_whistle()
	var result := "DRAW"
	if ev.score_left > ev.score_right:
		result = "TIME A WINS"
	elif ev.score_right > ev.score_left:
		result = "TIME B WINS"
	menu.set_fulltime_text("FULL TIME\n%d - %d\n%s" % [ev.score_left, ev.score_right, result])
	menu.set_fulltime_stats(ev.stats, sim.teams[0].kit.shirt, sim.teams[1].kit.shirt)
	_set_game_state(GameConfig.GameState.FULLTIME)

## Shows rain + a wet pitch. During a match this follows the match's own
## MatchConfig (which also fixed the ball friction at kickoff); in the menus it
## previews the saved preference. A weather change made from the pause menu
## therefore applies from the next match, like every other rule.
func _apply_weather() -> void:
	var in_match := game_state == GameConfig.GameState.PLAYING or game_state == GameConfig.GameState.PAUSED \
			or (game_state == GameConfig.GameState.SETTINGS and prev_menu_state == GameConfig.GameState.PAUSED)
	var raining: bool = (session.config.weather if in_match else settings.weather) == 1
	stadium_builder.set_rain_active(raining)
	material_factory.set_pitch_wet(raining)

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
