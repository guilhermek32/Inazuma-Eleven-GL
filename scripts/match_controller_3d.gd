extends Node3D

## Match controller / orchestrator for the 3D build.
##
## This is the script attached to scenes/main_3d.tscn. It owns no gameplay or
## rendering logic itself: _ready() builds the scene roots and wires the focused
## modules together (config/, data/, build/, match/, systems/). The match rules,
## clock and halves live in MatchSession; this controller is the *offline
## adapter* around it: local devices feed it input, and its drained events drive
## the view, HUD and audio. The rest is the UI state machine (menus, pause).
## Online it is the *online adapter* instead (see "online adapter" below).
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

# Online mode (the *online adapter*): the match runs on the match runtime;
# `session` then only holds a mirror of its state, filled from interpolated
# snapshots and never stepped. null while playing offline.
var net: NetClient
var _online_state := {}
# Creator of a lobby room: stay on the waiting page until the kickoff event.
var _await_kickoff := false
# The local device that last produced input (DEVICE_KBM or a pad id); it drives
# our team online, so a pad works there as well as keyboard+mouse.
var _last_device := GameConfig.DEVICE_KBM
var _latency_probe: LatencyProbe
var render_tier := RenderTier.FULL

func _ready() -> void:
	material_factory = MaterialFactory.new()
	material_factory.build_materials()
	_build_scene_roots()
	stadium_builder = StadiumBuilder.new()
	stadium_builder.mf = material_factory
	stadium_builder.host = self
	stadium_builder.stadium_root = stadium_root
	render_tier = RenderTier.detect()
	stadium_builder.web_tier = render_tier == RenderTier.WEB
	print("[render] tier=%s method=%s" % [RenderTier.tier_name(render_tier), RenderingServer.get_current_rendering_method()])
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
	# bounce coloured light onto the pitch. (Both are no-ops on the web tier.)
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
	if LaunchArgs.flag("latency"):
		_latency_probe = LatencyProbe.new()
	_set_game_state(GameConfig.GameState.MENU)
	print("Inazuma Eleven 3D environment ready")
	_start_online_from_launch_args()

func _exit_tree() -> void:
	session.dispose()

# Gameplay advances on the fixed physics tick so shot/capture outcomes don't vary
# with the render frame rate; rendering-side updates stay in _process below.
func _physics_process(delta: float) -> void:
	if game_state != GameConfig.GameState.PLAYING:
		return
	input_reader.read(sim.teams, sim.restart_timer)
	if net != null:
		# Online: the runtime simulates; we only send our team's input.
		var ts: TeamState = sim.teams[net.team]
		if _latency_probe != null and ts.selected_index >= 0 and ts.selected_index < ts.players.size():
			_latency_probe.on_input(ts.input.axis, ts.players[ts.selected_index], Time.get_ticks_usec())
		net.send_input(ts.input)
		return
	session.step(delta)
	for ev in session.drain_events():
		_dispatch_event(ev)

func _process(delta: float) -> void:
	if net != null:
		_poll_online()
	var st := _hud_state()
	# The match's slow motion slows its 3D visuals; HUD/menus keep real time.
	var time_scale: float = st.time_scale
	var visual_delta := delta * time_scale
	if game_state == GameConfig.GameState.PLAYING:
		view.set_glb_animation_speed(time_scale)
		view.update_visuals(visual_delta)
	elif game_state == GameConfig.GameState.MATCH_SETUP:
		setup.update(delta)
	view.update_confetti(visual_delta)
	hud.update(st.score_left, st.score_right, game_state, st.restart_timer, st.restart_type, st.half_length_s, st.match_time, st.current_half, delta)
	hud.update_stamina(_selected_stamina())

## Match-level values for the HUD: the local session offline, the latest
## interpolated snapshot online.
func _hud_state() -> Dictionary:
	if net == null:
		return session.read_state()
	if _online_state.is_empty():
		return {"score_left": 0, "score_right": 0, "restart_timer": 0.0, "restart_type": 0,
				"half_length_s": session.config.half_length_s, "match_time": 0.0, "current_half": 1, "time_scale": 1.0}
	return _online_state

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

## Presentation adapter: turns one gameplay event (from the local session, or
## from the runtime online) into view, HUD and audio cues. The rules never
## touch presentation directly.
func _dispatch_event(ev: Dictionary) -> void:
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
			var players := sim.teams[ev.team].players
			if ev.index >= 0 and ev.index < players.size():
				players[ev.index].play_action(ev.action, ev.duration)
		"half_time":
			audio.play_whistle()
			hud.show_banner("HALF TIME", Color(1.0, 0.95, 0.55), 2.0)
		"full_time", "match_over":
			_end_match(ev)
		# Online-only room events.
		"kickoff":
			print("[online] kickoff")
			if game_state == GameConfig.GameState.ONLINE:
				_await_kickoff = false
				_set_game_state(GameConfig.GameState.PLAYING)
				_apply_weather()
			audio.play_whistle()
			hud.show_banner("KICK OFF", Color(1.0, 0.95, 0.55), 1.2)
		"paused":
			print("[online] paused (team %d disconnected)" % ev.team)
			var who := "YOU" if ev.team == net_team() else "OPPONENT"
			hud.show_banner("%s DISCONNECTED - WAITING %ds" % [who, int(ev.grace_s)], Color(1.0, 0.55, 0.2), float(ev.grace_s), false)
		"resumed":
			print("[online] resumed")
			hud.show_banner("RESUMED", Color(0.5, 1.0, 0.6), 1.0, false)

# --- online adapter -----------------------------------------------------------------

## Starts online play when the process was launched for it:
##   desktop:  godot-4 --path . -- --connect=ws://host:8910/ws/game/<id> --token=<credential>
##   web:      https://<gateway>/?match=<id>&token=<credential>   (same-origin WebSocket)
## The in-game Play Online menu (OnlineMenu) goes through start_online_from_lobby().
func _start_online_from_launch_args() -> void:
	var url := LaunchArgs.value("connect")
	var token := LaunchArgs.value("token")
	if OS.has_feature("web"):
		var match_id := LaunchArgs.value("match")
		if match_id != "":
			var proto := str(JavaScriptBridge.eval("window.location.protocol", true))
			var host := str(JavaScriptBridge.eval("window.location.host", true))
			url = "%s//%s/ws/game/%s" % ["wss:" if proto == "https:" else "ws:", host, match_id.uri_encode()]
	if url != "" and token != "":
		# Let the scene render (and compile its shaders) before the socket opens,
		# so the first heavy frames don't eat into the runtime's HELLO deadline.
		for i in 3:
			await get_tree().process_frame
		start_online(url, token)

func start_online(url: String, token: String) -> void:
	if net != null:
		_leave_online()
	net = NetClient.new()
	net.welcomed.connect(_on_net_welcome)
	net.closed.connect(_on_net_closed)
	if net.connect_to(url, token) != OK:
		_on_net_closed(0, "could not connect")
		return
	hud.show_banner("CONNECTING...", Color(0.8, 0.9, 1.0), 10.0, false)

## A lobby grant from the Play Online menu. The creator (`await_kickoff`)
## keeps the waiting page with the room code up until the opponent joins and
## the runtime kicks off; a joiner enters the match on WELCOME.
func start_online_from_lobby(url: String, token: String, await_kickoff: bool) -> void:
	start_online(url, token)
	_await_kickoff = await_kickoff and net != null

## Cancel on the waiting page: drop the connection (the unjoined room expires
## on the runtime's waiting deadline).
func leave_online_wait() -> void:
	print("[online] left the waiting room")
	_await_kickoff = false
	_leave_online()

func net_team() -> int:
	return net.team if net != null else -1

## WELCOME: build the mirror match from the runtime's MatchConfig so rosters,
## kits and rules match, then show it while waiting for kickoff.
func _on_net_welcome() -> void:
	print("[online] joined match %s as team %d" % [net.match_id, net.team])
	for t in 2:
		session.set_team_device(t, _last_device if t == net.team else GameConfig.DEVICE_REMOTE)
	session.initialize(net.config, 0)
	session.drain_events()
	_online_state = {}
	view.clear_confetti()
	_rebuild_player_visuals()
	hud.set_team_colors(sim.teams[0].kit.shirt, sim.teams[1].kit.shirt)
	hud.reset()
	hud.show_banner("WAITING FOR OPPONENT", Color(0.8, 0.9, 1.0), 600.0, false)
	if _await_kickoff and game_state == GameConfig.GameState.ONLINE:
		return   # the waiting page stays up; the kickoff event enters the match
	_set_game_state(GameConfig.GameState.PLAYING)
	_apply_weather()

func _poll_online() -> void:
	net.poll()
	if net == null:
		return
	var now := float(Time.get_ticks_msec())
	var s := net.buffer.sample(now)
	if not s.is_empty() and net.config != null:
		_online_state = SnapshotBuffer.apply_to(sim, s.a, s.b, s.t)
		_online_state["half_length_s"] = net.config.half_length_s
		if _latency_probe != null:
			var ms := _latency_probe.on_frame(Time.get_ticks_usec())
			if ms >= 0.0:
				print("[latency] input_to_visible_ms=%.1f rtt_ms=%d" % [ms, roundi(net.rtt_ms)])
	for ev in net.buffer.take_due_events(now):
		_dispatch_event(ev)

func _on_net_closed(code: int, reason: String) -> void:
	print("[online] connection closed (%d) %s" % [code, reason])
	# Events that arrived before the close still play (a slow client can get
	# match_over and the close in the same frame).
	for ev in net.buffer.take_all_events():
		_dispatch_event(ev)
	var why := reason if reason != "" else "connection lost"
	if game_state == GameConfig.GameState.ONLINE:
		# Still in the lobby screens (waiting room, or connecting after a join).
		_await_kickoff = false
		menu.online.show_connection_error("Connection to the match closed: %s (code %d)" % [why, code])
	elif game_state != GameConfig.GameState.FULLTIME:
		# A finished match closes the connection after its final events: nothing to report.
		menu.set_fulltime_text("CONNECTION CLOSED\n%s\n(code %d)" % [why, code])
		menu.set_fulltime_online(true)
		_set_game_state(GameConfig.GameState.FULLTIME)
	_leave_online.call_deferred()

func _leave_online() -> void:
	if net == null:
		return
	net.close()
	net = null
	_online_state = {}
	for t in 2:
		session.set_team_device(t, _lineup_devices[t])

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
	_note_input_device(event)
	if event.is_action_pressed("ui_cancel"):
		match game_state:
			GameConfig.GameState.PLAYING:
				# An online match can't be paused locally; Esc leaves it.
				if net != null:
					print("[online] left the match")
				_set_game_state(GameConfig.GameState.MENU if net != null else GameConfig.GameState.PAUSED)
			GameConfig.GameState.ONLINE:
				menu.online.back()
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

## Tracks the local device that last produced input; online, our team follows
## it (so a pad can take over from keyboard+mouse and back mid-match). Mouse
## motion alone doesn't count, so a nudged mouse never steals a pad's aim.
func _note_input_device(event: InputEvent) -> void:
	var device := _last_device
	if event is InputEventJoypadButton and event.pressed:
		device = event.device
	elif event is InputEventJoypadMotion and absf(event.axis_value) > 0.5:
		device = event.device
	elif event is InputEventKey or event is InputEventMouseButton:
		device = GameConfig.DEVICE_KBM
	if device == _last_device:
		return
	_last_device = device
	if net != null and net.team >= 0 and sim.teams[net.team].device != GameConfig.DEVICE_REMOTE:
		session.set_team_device(net.team, device)
		print("[online] input device: %s" % ("keyboard+mouse" if device == GameConfig.DEVICE_KBM else "pad %d" % device))

func _set_game_state(next: int) -> void:
	# Never leave the world in slow-mo when we step out of live play (pause, menus, …).
	if next != GameConfig.GameState.PLAYING:
		session.cancel_slow_motion()
	if (next == GameConfig.GameState.MENU or next == GameConfig.GameState.ONLINE) and net != null:
		_leave_online()
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
	# Restart / Rematch after an online match plays an offline one (a new
	# online match goes through the lobby).
	_leave_online()
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
	if net != null:
		print("[online] match over (%s) %d-%d" % [ev.get("reason", "full_time"), ev.score_left, ev.score_right])
	menu.set_fulltime_online(net != null)
	audio.play_whistle()
	var result := "DRAW"
	if ev.score_left > ev.score_right:
		result = "TIME A WINS"
	elif ev.score_right > ev.score_left:
		result = "TIME B WINS"
	# Online matches can also end early ("match_over" carries the reason).
	var title := "FULL TIME"
	match str(ev.get("reason", "full_time")):
		"forfeit":
			title = "FORFEIT"
			result = "TIME A WINS" if ev.winner == 0 else ("TIME B WINS" if ev.winner == 1 else "NO WINNER")
		"cancelled":
			title = "MATCH CANCELLED"
	menu.set_fulltime_text("%s\n%d - %d\n%s" % [title, ev.score_left, ev.score_right, result])
	# Online stats arrive as plain JSON arrays; the menu wants Array[Dictionary].
	var stats: Array[Dictionary] = []
	stats.assign(ev.stats)
	menu.set_fulltime_stats(stats, sim.teams[0].kit.shirt, sim.teams[1].kit.shirt)
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
