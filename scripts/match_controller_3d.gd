extends Node3D

enum PlayerRole { GOALKEEPER, DEFENDER, MIDFIELDER, ATTACKER }

const FIELD_HALF_WIDTH := 0.98
const FIELD_HALF_HEIGHT := 0.78
const FIELD_BOUNDARY_X := 0.93
const FIELD_BOUNDARY_Y := 0.73
const GOAL_HALF_WIDTH := 0.18
const GOAL_DEPTH := 0.05
const PENALTY_AREA_WIDTH := 0.22
const PENALTY_AREA_HEIGHT := 0.32
const GOAL_AREA_WIDTH := 0.10
const GOAL_AREA_HEIGHT := 0.20
const PENALTY_SPOT_DIST := 0.15
const CENTER_CIRCLE_RADIUS := 0.16
const CORNER_ARC_RADIUS := 0.035
const FIELD_SCALE := 18.0
const PITCH_Y := 0.0
const PLAYER_GLB_SCALE := 1.14
const PLAYER_GLB_Y_OFFSET := 0.0
const PLAYER_GLB_YAW_OFFSET := 0.0
const PLAYER_ASSET_DIR := "res://assets/obj_3d_player/"
const PLAYER_MESH_FILE := "Ch38_nonPBR.glb"
const PLAYER_GLTF_ANIM := "Armature|mixamo.com|Layer0"
# Friendly state name -> [animation-only GLB, should loop]. All share the Ch38 mixamorig5 rig,
# so their clips retarget onto the character mesh skeleton directly.
const PLAYER_ANIM_FILES := {
	"idle": ["offensive idle.glb", true],
	"run": ["jog forward.glb", true],
	"gk_idle": ["goalkeeper idle.glb", true],
	"kick": ["kick soccerball.glb", false],
	"receive": ["receive soccerball.glb", false],
	"tackle": ["soccer tackle.glb", false],
}

class PlayerState:
	var x := 0.0
	var y := 0.0
	var speed := 0.2
	var start_x := 0.0
	var start_y := 0.0
	var facing_x := 1.0
	var facing_y := 0.0
	var side := 1
	var role := PlayerRole.MIDFIELDER
	var team_index := 0
	var stun_timer := 0.0
	var kick_power := 0.0
	var hold_timer := 0.0
	var is_moving := false
	var is_targeting_ball := false
	var node: Node3D
	var uses_glb := false
	var visual_model: Node3D
	var animation_player: AnimationPlayer
	var visual_state := ""
	var action_timer := 0.0

	func _init(p_x: float, p_y: float, p_speed: float, p_side: int, p_role: int) -> void:
		x = p_x
		y = p_y
		start_x = p_x
		start_y = p_y
		speed = p_speed
		side = p_side
		role = p_role
		team_index = 0 if p_side == -1 else 1
		facing_x = float(p_side)

class BallState:
	var x := 0.0
	var y := 0.0
	var vx := 0.0
	var vy := 0.0
	var friction := 0.98
	var owner_team := -1
	var owner_index := -1
	var is_super_shot := false
	var charging_power := 0.0
	var spin := 0.0
	var node: Node3D
	var light: OmniLight3D

class VfxParticle:
	var node: MeshInstance3D
	var velocity := Vector3.ZERO
	var life := 0.0
	var max_life := 0.0

	func _init(p_node: MeshInstance3D, p_velocity: Vector3, p_life: float) -> void:
		node = p_node
		velocity = p_velocity
		life = p_life
		max_life = p_life

# Per-team human input for the current frame. aim_vec is an absolute field point when
# aim_absolute is true (mouse), otherwise a direction offset from the player (gamepad stick).
class InputSnapshot:
	var axis := Vector2.ZERO
	var shoot_held := false
	var shoot_prev := false
	var aim_vec := Vector2.ZERO
	var aim_absolute := true

enum GameState { MENU, HOWTO, SETTINGS, PLAYING, PAUSED, FULLTIME }

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
var game_state := GameState.MENU
var prev_menu_state := GameState.MENU
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
const MATCH_LENGTHS := [120.0, 300.0, 600.0]
const SETTINGS_PATH := "user://settings.cfg"

func _ready() -> void:
	_build_materials()
	_build_scene_roots()
	_build_environment()
	_build_camera()
	_build_lighting()
	_build_pitch()
	_build_goals()
	_build_stadium()
	_build_ui()
	_setup_input_actions()
	_create_teams()
	_create_ball()
	_create_ball_trail()
	_build_audio()
	_load_settings()
	_build_menus()
	_reset_game(1)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_set_game_state(GameState.MENU)
	print("Inazuma Eleven 3D environment ready")

func _process(delta: float) -> void:
	if game_state == GameState.PLAYING:
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
			GameState.PLAYING:
				_set_game_state(GameState.PAUSED)
			GameState.PAUSED:
				_set_game_state(GameState.PLAYING)
			GameState.HOWTO, GameState.SETTINGS:
				_set_game_state(prev_menu_state)
		get_viewport().set_input_as_handled()

func _set_game_state(next: int) -> void:
	if next == GameState.HOWTO or next == GameState.SETTINGS:
		prev_menu_state = game_state if game_state in [GameState.MENU, GameState.PAUSED] else GameState.MENU
	game_state = next
	_set_glb_animations_paused(next != GameState.PLAYING)
	for key in menu_panels:
		(menu_panels[key] as Control).visible = false
	match next:
		GameState.MENU:
			_refresh_two_player_availability()
			menu_panels.main.visible = true
		GameState.HOWTO:
			menu_panels.howto.visible = true
		GameState.SETTINGS:
			menu_panels.settings.visible = true
		GameState.PAUSED:
			menu_panels.pause.visible = true
		GameState.FULLTIME:
			menu_panels.fulltime.visible = true

func _start_match() -> void:
	score_left = 0
	score_right = 0
	match_time = 0.0
	current_half = 1
	halftime_pause = 0.0
	_set_default_ends()
	_reset_game(1)
	_set_game_state(GameState.PLAYING)
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
	_set_game_state(GameState.FULLTIME)

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
	if game_state == GameState.MENU:
		_refresh_two_player_availability()

func _refresh_two_player_availability() -> void:
	if play_2p_button == null:
		return
	var pads := Input.get_connected_joypads().size()
	play_2p_button.disabled = pads < 2
	if play_2p_hint != null:
		play_2p_hint.text = "" if pads >= 2 else "Connect 2 controllers for 2-player"

func _build_materials() -> void:
	materials.grass = _material(Color.WHITE, 0.9, 0.0, _noise_texture(Color(0.10, 0.35, 0.13), 0.05))
	materials.grass_dark = _material(Color.WHITE, 0.9, 0.0, _noise_texture(Color(0.088, 0.315, 0.115), 0.05))
	materials.line = _material(Color(0.95, 0.97, 0.92), 0.55)
	materials.goal = _material(Color(0.92, 0.93, 0.90), 0.28, 0.25)
	materials.net = _material(Color(1.0, 1.0, 1.0, 0.99), 0.7, 0.0, _net_texture())
	materials.concrete = _material(Color(0.37, 0.36, 0.34), 0.92, 0.0, _checker_texture(Color(0.28, 0.28, 0.27), Color(0.45, 0.44, 0.41), 128, 16))
	materials.asphalt = _material(Color.WHITE, 0.95, 0.0, _noise_texture(Color(0.125, 0.13, 0.145), 0.06))
	materials.wall = _material(Color(0.15, 0.16, 0.18), 0.95)
	materials.wall_top = _emission_material(Color(0.95, 0.88, 0.70), 0.5)
	materials.flag = _emission_material(Color(1.0, 0.85, 0.15), 0.8)
	materials.seat_red = _material(Color(0.55, 0.06, 0.05), 0.65)
	materials.seat_blue = _material(Color(0.04, 0.10, 0.55), 0.65)
	materials.metal_dark = _material(Color(0.20, 0.21, 0.22), 0.38, 0.55)
	materials.light_emission = _emission_material(Color(1.0, 0.94, 0.72), 3.5)
	materials.ad_panels = [
		_emission_material(Color(0.92, 0.94, 0.98), 1.0),
		_emission_material(Color(0.10, 0.30, 0.95), 1.0),
		_emission_material(Color(0.90, 0.12, 0.10), 1.0),
		_emission_material(Color(1.0, 0.78, 0.10), 1.0),
	]
	materials.ad_text_colors = [Color(0.08, 0.10, 0.25), Color.WHITE, Color.WHITE, Color(0.15, 0.10, 0.02)]
	materials.scoreboard = _emission_material(Color(0.1, 0.85, 0.25), 1.4)
	materials.player_red = _material(Color(0.85, 0.05, 0.03), 0.58)
	materials.player_blue = _material(Color(0.04, 0.20, 0.88), 0.58)
	materials.goalkeeper = _material(Color(1.0, 0.58, 0.05), 0.58)
	materials.skin = _material(Color(0.72, 0.45, 0.28), 0.62)
	materials.hair = _material(Color(0.12, 0.07, 0.035), 0.7)
	materials.boots = _material(Color(0.03, 0.03, 0.035), 0.45)
	materials.ball = _material(Color.WHITE, 0.42, 0.0, _checker_texture(Color(0.96, 0.96, 0.92), Color(0.02, 0.02, 0.025), 128, 24))
	materials.selection = _emission_material(Color(1.0, 0.92, 0.08), 1.8)
	materials.power = _emission_material(Color(0.1, 0.65, 1.0), 1.7)
	materials.trail = _material(Color(1.0, 0.86, 0.25, 0.36), 0.35)
	materials.confetti_red = _emission_material(Color(1.0, 0.08, 0.04), 1.1)
	materials.confetti_blue = _emission_material(Color(0.08, 0.28, 1.0), 1.1)
	materials.confetti_gold = _emission_material(Color(1.0, 0.84, 0.12), 1.3)

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

func _build_environment() -> void:
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.010, 0.018, 0.045)
	sky_mat.sky_horizon_color = Color(0.055, 0.075, 0.13)
	sky_mat.ground_bottom_color = Color(0.010, 0.012, 0.02)
	sky_mat.ground_horizon_color = Color(0.04, 0.05, 0.08)
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.55, 0.78)
	env.ambient_light_energy = 0.4
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.3
	world.environment = env
	add_child(world)

func _build_camera() -> void:
	camera_rig = Node3D.new()
	camera_rig.name = "CameraRig"
	camera_rig.position = Vector3(0.0, 18.0, 24.0)
	add_child(camera_rig)
	camera_3d = Camera3D.new()
	camera_3d.name = "Camera3D"
	camera_3d.fov = 49.0
	camera_3d.current = true
	camera_rig.add_child(camera_3d)
	camera_3d.look_at(Vector3.ZERO, Vector3.UP)

func _build_lighting() -> void:
	var moon := DirectionalLight3D.new()
	moon.name = "MoonLight"
	moon.light_color = Color(0.60, 0.68, 0.88)
	moon.light_energy = 0.3
	moon.shadow_enabled = false
	moon.light_angular_distance = 0.8
	moon.rotation_degrees = Vector3(-52.0, -34.0, 0.0)
	add_child(moon)
	var flood_root := Node3D.new()
	flood_root.name = "FloodLights"
	add_child(flood_root)
	var positions := [
		Vector3(-24.0, 14.0, -19.0),
		Vector3(24.0, 14.0, -19.0),
		Vector3(-24.0, 14.0, 19.0),
		Vector3(24.0, 14.0, 19.0),
	]
	for i in positions.size():
		_add_floodlight(flood_root, positions[i], i)

func _add_floodlight(parent: Node3D, pos: Vector3, index: int) -> void:
	var tower := Node3D.new()
	tower.name = "FloodlightTower%d" % index
	tower.position = pos
	parent.add_child(tower)
	var pole := _mesh("Pole", CylinderMesh.new(), materials.metal_dark, Vector3.ZERO)
	pole.mesh.height = pos.y
	pole.mesh.top_radius = 0.08
	pole.mesh.bottom_radius = 0.10
	pole.position.y = -pos.y * 0.5
	tower.add_child(pole)
	var lamp := _mesh("Lamp", BoxMesh.new(), materials.light_emission, Vector3.ZERO)
	lamp.mesh.size = Vector3(1.5, 0.42, 0.35)
	tower.add_child(lamp)
	var spot := SpotLight3D.new()
	spot.name = "SpotLight3D"
	spot.light_color = Color(0.78, 0.88, 1.0)
	spot.light_energy = 7.0
	spot.spot_range = 60.0
	spot.spot_angle = 48.0
	spot.light_size = 1.2
	spot.shadow_enabled = index < 4
	tower.add_child(spot)
	spot.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)

func _build_pitch() -> void:
	var field_size := Vector2(FIELD_HALF_WIDTH * 2.0 * FIELD_SCALE, FIELD_HALF_HEIGHT * 2.0 * FIELD_SCALE)
	var pitch := _mesh("GrassPitch", BoxMesh.new(), materials.grass, Vector3(0.0, -0.04, 0.0))
	pitch.mesh.size = Vector3(field_size.x, 0.08, field_size.y)
	pitch_root.add_child(pitch)
	for i in 10:
		if i % 2 == 0:
			var stripe := _mesh("GrassStripe%d" % i, BoxMesh.new(), materials.grass_dark, Vector3.ZERO)
			stripe.mesh.size = Vector3(field_size.x / 10.0, 0.012, field_size.y)
			stripe.position = Vector3(-field_size.x * 0.5 + field_size.x * (float(i) + 0.5) / 10.0, 0.012, 0.0)
			pitch_root.add_child(stripe)
	_add_field_lines()

func _add_field_lines() -> void:
	var x := FIELD_BOUNDARY_X * FIELD_SCALE
	var z := FIELD_BOUNDARY_Y * FIELD_SCALE
	_add_line_segment(Vector3(-x, 0.06, -z), Vector3(x, 0.06, -z), 0.07, "SidelineTop")
	_add_line_segment(Vector3(-x, 0.06, z), Vector3(x, 0.06, z), 0.07, "SidelineBottom")
	_add_line_segment(Vector3(-x, 0.06, -z), Vector3(-x, 0.06, z), 0.07, "EndlineLeft")
	_add_line_segment(Vector3(x, 0.06, -z), Vector3(x, 0.06, z), 0.07, "EndlineRight")
	_add_line_segment(Vector3(0.0, 0.065, -z), Vector3(0.0, 0.065, z), 0.06, "HalfwayLine")
	_add_circle(Vector3.ZERO, CENTER_CIRCLE_RADIUS * FIELD_SCALE, 64, 0.055, "CenterCircle")
	_add_spot(Vector3(0.0, 0.055, 0.0), "CenterSpot")
	for side in [-1, 1]:
		_add_box_lines(side, PENALTY_AREA_WIDTH, PENALTY_AREA_HEIGHT, "Penalty")
		_add_box_lines(side, GOAL_AREA_WIDTH, GOAL_AREA_HEIGHT, "GoalArea")
		_add_penalty_arc(side)
		_add_spot(Vector3((FIELD_BOUNDARY_X - PENALTY_SPOT_DIST) * FIELD_SCALE * float(side), 0.055, 0.0), "PenaltySpot%d" % side)
	for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		_add_corner_arc(corner)
		_add_corner_flag(corner)

func _add_box_lines(side: int, depth: float, half_z: float, prefix: String) -> void:
	var xb := FIELD_BOUNDARY_X * FIELD_SCALE * float(side)
	var xi := (FIELD_BOUNDARY_X - depth) * FIELD_SCALE * float(side)
	var z := half_z * FIELD_SCALE
	_add_line_segment(Vector3(xb, 0.07, -z), Vector3(xi, 0.07, -z), 0.055, "%sA%d" % [prefix, side])
	_add_line_segment(Vector3(xb, 0.07, z), Vector3(xi, 0.07, z), 0.055, "%sB%d" % [prefix, side])
	_add_line_segment(Vector3(xi, 0.07, -z), Vector3(xi, 0.07, z), 0.055, "%sC%d" % [prefix, side])

func _add_penalty_arc(side: int) -> void:
	var radius := CENTER_CIRCLE_RADIUS * FIELD_SCALE
	var spot_x := (FIELD_BOUNDARY_X - PENALTY_SPOT_DIST) * FIELD_SCALE * float(side)
	var box_x := (FIELD_BOUNDARY_X - PENALTY_AREA_WIDTH) * FIELD_SCALE * float(side)
	var half_angle := acos(absf(box_x - spot_x) / radius)
	var facing := PI if side == 1 else 0.0
	_add_arc(Vector3(spot_x, 0.075, 0.0), radius, facing - half_angle, facing + half_angle, 18, 0.055, "PenaltyArc%d" % side)

func _add_corner_arc(corner: Vector2) -> void:
	var center := Vector3(FIELD_BOUNDARY_X * FIELD_SCALE * corner.x, 0.075, FIELD_BOUNDARY_Y * FIELD_SCALE * corner.y)
	var a_start := 0.0
	if corner == Vector2(1, -1):
		a_start = PI * 0.5
	elif corner == Vector2(1, 1):
		a_start = PI
	elif corner == Vector2(-1, 1):
		a_start = PI * 1.5
	_add_arc(center, CORNER_ARC_RADIUS * FIELD_SCALE, a_start, a_start + PI * 0.5, 8, 0.05, "CornerArc%d%d" % [corner.x, corner.y])

func _add_corner_flag(corner: Vector2) -> void:
	var x := FIELD_BOUNDARY_X * FIELD_SCALE * corner.x
	var z := FIELD_BOUNDARY_Y * FIELD_SCALE * corner.y
	var pole := _mesh("CornerPole%d%d" % [corner.x, corner.y], CylinderMesh.new(), materials.goal, Vector3(x, 0.75, z))
	pole.mesh.height = 1.5
	pole.mesh.top_radius = 0.022
	pole.mesh.bottom_radius = 0.022
	pitch_root.add_child(pole)
	var flag := _mesh("CornerFlag%d%d" % [corner.x, corner.y], BoxMesh.new(), materials.flag, Vector3(x - corner.x * 0.2, 1.36, z))
	flag.mesh.size = Vector3(0.38, 0.24, 0.02)
	pitch_root.add_child(flag)

func _add_spot(pos: Vector3, node_name: String) -> void:
	var spot := _mesh(node_name, CylinderMesh.new(), materials.line, pos)
	spot.mesh.top_radius = 0.12
	spot.mesh.bottom_radius = 0.12
	spot.mesh.height = 0.02
	lines_root.add_child(spot)

func _add_circle(center: Vector3, radius: float, segments: int, width: float, node_name: String) -> void:
	for i in segments:
		var a0 := float(i) / float(segments) * TAU
		var a1 := float(i + 1) / float(segments) * TAU
		var p0 := center + Vector3(cos(a0) * radius, 0.075, sin(a0) * radius)
		var p1 := center + Vector3(cos(a1) * radius, 0.075, sin(a1) * radius)
		_add_line_segment(p0, p1, width, "%s%d" % [node_name, i])

func _add_arc(center: Vector3, radius: float, a_start: float, a_end: float, segments: int, width: float, node_name: String) -> void:
	for i in segments:
		var a0 := lerpf(a_start, a_end, float(i) / float(segments))
		var a1 := lerpf(a_start, a_end, float(i + 1) / float(segments))
		var p0 := center + Vector3(cos(a0) * radius, 0.0, sin(a0) * radius)
		var p1 := center + Vector3(cos(a1) * radius, 0.0, sin(a1) * radius)
		_add_line_segment(p0, p1, width, "%s%d" % [node_name, i])

func _add_line_segment(a: Vector3, b: Vector3, width: float, node_name: String) -> void:
	var mid := (a + b) * 0.5
	var len := a.distance_to(b)
	var line := _mesh(node_name, BoxMesh.new(), materials.line, mid)
	line.mesh.size = Vector3(len, 0.035, width)
	line.rotation.y = atan2(a.z - b.z, b.x - a.x)
	lines_root.add_child(line)

func _build_goals() -> void:
	_add_goal(-1)
	_add_goal(1)

func _add_goal(side: int) -> void:
	var goal := Node3D.new()
	goal.name = "GoalLeft" if side == -1 else "GoalRight"
	goals_root.add_child(goal)
	var x := FIELD_BOUNDARY_X * FIELD_SCALE * float(side)
	var depth := GOAL_DEPTH * FIELD_SCALE * float(side)
	var half_w := GOAL_HALF_WIDTH * FIELD_SCALE
	var height := 1.8
	var post_a := _goal_post(Vector3(x, height * 0.5, -half_w))
	var post_b := _goal_post(Vector3(x, height * 0.5, half_w))
	var bar := _goal_bar(Vector3(x, height, 0.0), half_w * 2.0, Vector3(90.0, 0.0, 0.0))
	var back_bar := _goal_bar(Vector3(x + depth, height, 0.0), half_w * 2.0, Vector3(90.0, 0.0, 0.0))
	var top_depth_a := _goal_bar(Vector3(x + depth * 0.5, height, -half_w), absf(depth), Vector3(0.0, 0.0, 90.0))
	var top_depth_b := _goal_bar(Vector3(x + depth * 0.5, height, half_w), absf(depth), Vector3(0.0, 0.0, 90.0))
	goal.add_child(post_a)
	goal.add_child(post_b)
	goal.add_child(bar)
	goal.add_child(back_bar)
	goal.add_child(top_depth_a)
	goal.add_child(top_depth_b)
	var net_back := _net_panel("NetBack", Vector3(x + depth, height * 0.5, 0.0), Vector3(0.03, height, half_w * 2.0))
	goal.add_child(net_back)
	var net_top := _net_panel("NetTop", Vector3(x + depth * 0.5, height, 0.0), Vector3(absf(depth), 0.03, half_w * 2.0))
	goal.add_child(net_top)
	for net_side in [-1.0, 1.0]:
		var panel := _net_panel("NetSide%d" % net_side, Vector3(x + depth * 0.5, height * 0.5, half_w * net_side), Vector3(absf(depth), height, 0.03))
		goal.add_child(panel)

func _net_panel(panel_name: String, pos: Vector3, size: Vector3) -> MeshInstance3D:
	var panel := _mesh(panel_name, BoxMesh.new(), materials.net, pos)
	panel.mesh.size = size
	panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return panel

func _goal_post(pos: Vector3) -> MeshInstance3D:
	var post := _mesh("Post", CylinderMesh.new(), materials.goal, pos)
	post.mesh.height = 1.8
	post.mesh.top_radius = 0.055
	post.mesh.bottom_radius = 0.055
	return post

func _goal_bar(pos: Vector3, length: float, rot_degrees: Vector3) -> MeshInstance3D:
	var bar := _mesh("Bar", CylinderMesh.new(), materials.goal, pos)
	bar.mesh.height = length
	bar.mesh.top_radius = 0.055
	bar.mesh.bottom_radius = 0.055
	bar.rotation_degrees = rot_degrees
	return bar

func _build_stadium() -> void:
	var field_x := FIELD_HALF_WIDTH * FIELD_SCALE
	var field_z := FIELD_HALF_HEIGHT * FIELD_SCALE
	_add_ground_apron()
	_add_perimeter_walls()
	_add_stand("NorthStand", Vector3(0.0, 1.0, -field_z - 5.0), Vector3(field_x * 2.5, 2.0, 5.0), materials.concrete)
	_add_stand("SouthStand", Vector3(0.0, 1.0, field_z + 5.0), Vector3(field_x * 2.5, 2.0, 5.0), materials.concrete)
	_add_stand("WestStand", Vector3(-field_x - 5.5, 1.0, 0.0), Vector3(5.0, 2.0, field_z * 2.0), materials.concrete)
	_add_stand("EastStand", Vector3(field_x + 5.5, 1.0, 0.0), Vector3(5.0, 2.0, field_z * 2.0), materials.concrete)
	_add_crowd_cards(field_x, field_z)
	_add_hoardings()
	_add_scoreboard(Vector3(0.0, 5.2, -field_z - 7.8))

func _add_ground_apron() -> void:
	var apron := _mesh("GroundApron", BoxMesh.new(), materials.asphalt, Vector3(0.0, -0.06, 0.0))
	apron.mesh.size = Vector3(72.0, 0.08, 68.0)
	apron.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stadium_root.add_child(apron)

func _add_perimeter_walls() -> void:
	var walls := [
		["NorthWall", Vector3(0.0, 4.0, -33.7), Vector3(72.0, 8.0, 0.6)],
		["SouthWall", Vector3(0.0, 4.0, 33.7), Vector3(72.0, 8.0, 0.6)],
		["WestWall", Vector3(-35.7, 4.0, 0.0), Vector3(0.6, 8.0, 68.0)],
		["EastWall", Vector3(35.7, 4.0, 0.0), Vector3(0.6, 8.0, 68.0)],
	]
	for w in walls:
		var wall := _mesh(w[0], BoxMesh.new(), materials.wall, w[1])
		wall.mesh.size = w[2]
		stadium_root.add_child(wall)
		var band := _mesh("%sBand" % w[0], BoxMesh.new(), materials.wall_top, w[1] + Vector3(0.0, 4.35, 0.0))
		band.mesh.size = Vector3(maxf(w[2].x, 0.8), 0.7, maxf(w[2].z, 0.8))
		stadium_root.add_child(band)
	var sign := Label3D.new()
	sign.name = "StadiumSign"
	sign.text = "INAZUMA STADIUM"
	sign.font_size = 260
	sign.modulate = Color(0.98, 0.92, 0.72)
	sign.position = Vector3(0.0, 6.5, -33.3)
	stadium_root.add_child(sign)

func _add_hoardings() -> void:
	var ads := ["INAZUMA", "RAIMON FC", "ELEVEN TV", "KICK & GO", "SUPERNOVA", "GOAL MART", "METEOR LTD", "STRIKER+"]
	var bx := FIELD_BOUNDARY_X * FIELD_SCALE
	var bz := FIELD_BOUNDARY_Y * FIELD_SCALE
	var idx := 0
	for i in 8:
		var x := -13.65 + float(i) * 3.9
		_add_hoarding(Vector3(x, 0.0, -bz - 1.7), 0.0, ads[idx % ads.size()], idx)
		idx += 1
		_add_hoarding(Vector3(x, 0.0, bz + 1.7), PI, ads[idx % ads.size()], idx)
		idx += 1
	for i in 5:
		var z := -7.8 + float(i) * 3.9
		_add_hoarding(Vector3(-bx - 2.2, 0.0, z), PI * 0.5, ads[idx % ads.size()], idx)
		idx += 1
		_add_hoarding(Vector3(bx + 2.2, 0.0, z), -PI * 0.5, ads[idx % ads.size()], idx)
		idx += 1

func _add_hoarding(pos: Vector3, yaw: float, text: String, idx: int) -> void:
	var board := Node3D.new()
	board.name = "Hoarding%d" % idx
	board.position = pos
	board.rotation = Vector3(-0.12, yaw, 0.0)
	stadium_root.add_child(board)
	var frame := _mesh("Frame", BoxMesh.new(), materials.metal_dark, Vector3(0.0, 0.46, -0.04))
	frame.mesh.size = Vector3(3.7, 0.92, 0.08)
	board.add_child(frame)
	var scheme: int = idx % materials.ad_panels.size()
	var panel := _mesh("Panel", BoxMesh.new(), materials.ad_panels[scheme], Vector3(0.0, 0.46, 0.02))
	panel.mesh.size = Vector3(3.55, 0.78, 0.05)
	board.add_child(panel)
	var label := Label3D.new()
	label.name = "AdText"
	label.text = text
	label.font_size = 96
	label.modulate = materials.ad_text_colors[scheme]
	label.position = Vector3(0.0, 0.46, 0.06)
	board.add_child(label)

func _add_stand(stand_name: String, pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> void:
	var stand := Node3D.new()
	stand.name = stand_name
	stand.position = pos
	stadium_root.add_child(stand)
	for tier in 4:
		var tier_mesh := _mesh("Tier%d" % tier, BoxMesh.new(), mat, Vector3(0.0, float(tier) * 0.55, 0.0))
		tier_mesh.mesh.size = Vector3(size.x - float(tier) * 0.55, 0.42, size.z - float(tier) * 0.35)
		stand.add_child(tier_mesh)
		var seat_mat: Material = materials.seat_red if tier % 2 == 0 else materials.seat_blue
		var seat := _mesh("SeatBand%d" % tier, BoxMesh.new(), seat_mat, Vector3(0.0, float(tier) * 0.55 + 0.27, 0.0))
		seat.mesh.size = Vector3(tier_mesh.mesh.size.x * 0.94, 0.08, tier_mesh.mesh.size.z * 0.72)
		stand.add_child(seat)

func _add_scoreboard(pos: Vector3) -> void:
	var board := _mesh("Scoreboard", BoxMesh.new(), materials.scoreboard, pos)
	board.mesh.size = Vector3(5.2, 1.8, 0.18)
	stadium_root.add_child(board)
	board.look_at(Vector3.ZERO, Vector3.UP)
	for pole_side in [-1.0, 1.0]:
		var pole := _mesh("ScoreboardPole%d" % pole_side, CylinderMesh.new(), materials.metal_dark, Vector3(pole_side * 1.8, pos.y * 0.5 - 0.45, pos.z))
		pole.mesh.height = pos.y - 0.9
		pole.mesh.top_radius = 0.09
		pole.mesh.bottom_radius = 0.11
		stadium_root.add_child(pole)

func _add_crowd_cards(field_x: float, field_z: float) -> void:
	var fan_textures: Array[Texture2D] = []
	for path in [
		"res://assets/fans/fans_red_1.png",
		"res://assets/fans/fans_red_2.png",
		"res://assets/fans/fans_blue_1.png",
		"res://assets/fans/fans_blue_2.png",
	]:
		if ResourceLoader.exists(path):
			fan_textures.append(load(path))
	if fan_textures.is_empty():
		return
	for row in 3:
		for i in 22:
			var x := -field_x * 1.12 + float(i) * (field_x * 2.24 / 21.0)
			_add_fan_sprite(fan_textures[(i + row) % fan_textures.size()], Vector3(x, 1.45 + row * 0.70, -field_z - 4.05 - row * 0.72), Vector3(0.0, PI, 0.0))
			_add_fan_sprite(fan_textures[(i + row + 1) % fan_textures.size()], Vector3(x, 1.45 + row * 0.70, field_z + 4.05 + row * 0.72), Vector3.ZERO)
	for row in 2:
		for i in 14:
			var z := -field_z * 0.9 + float(i) * (field_z * 1.8 / 13.0)
			_add_fan_sprite(fan_textures[(i + row) % fan_textures.size()], Vector3(-field_x - 4.25 - row * 0.70, 1.45 + row * 0.70, z), Vector3(0.0, PI * 0.5, 0.0))
			_add_fan_sprite(fan_textures[(i + row + 2) % fan_textures.size()], Vector3(field_x + 4.25 + row * 0.70, 1.45 + row * 0.70, z), Vector3(0.0, -PI * 0.5, 0.0))

func _add_fan_sprite(texture: Texture2D, feet_pos: Vector3, rot: Vector3) -> void:
	var sprite := Sprite3D.new()
	sprite.name = "CrowdCard"
	sprite.texture = texture
	var fan_height := 1.55
	sprite.pixel_size = fan_height / float(texture.get_height())
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.position = feet_pos + Vector3(0.0, fan_height * 0.5, 0.0)
	sprite.rotation = rot
	stadium_root.add_child(sprite)

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
	_make_button(vb, "How to Play", func() -> void: _set_game_state(GameState.HOWTO))
	_make_button(vb, "Settings", func() -> void: _set_game_state(GameState.SETTINGS))
	_make_button(vb, "Quit", func() -> void: get_tree().quit())

func _build_howto_panel() -> void:
	var panel := _make_panel("howto")
	var vb := _make_vbox(panel)
	_make_title(vb, "How to Play")
	var text := Label.new()
	text.add_theme_font_size_override("font_size", 22)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.text = "1 PLAYER (keyboard + mouse)\nMove: W A S D\nAim: Mouse\nShoot: hold SPACE to charge, release to kick\n\n2 PLAYERS (two controllers required)\nMove: Left stick    Aim: Right stick\nShoot: R1 / RB  (hold to charge)\n\nYou control the player nearest the ball.\nPress ESC to pause."
	vb.add_child(text)
	_make_button(vb, "Back", func() -> void: _set_game_state(prev_menu_state))

func _build_pause_panel() -> void:
	var panel := _make_panel("pause")
	var vb := _make_vbox(panel)
	_make_title(vb, "Paused")
	_make_button(vb, "Resume", func() -> void: _set_game_state(GameState.PLAYING))
	_make_button(vb, "Restart Match", func() -> void: _start_match())
	_make_button(vb, "Settings", func() -> void: _set_game_state(GameState.SETTINGS))
	_make_button(vb, "Back to Menu", func() -> void: _set_game_state(GameState.MENU))

func _build_fulltime_panel() -> void:
	var panel := _make_panel("fulltime")
	var vb := _make_vbox(panel)
	fulltime_label = _make_title(vb, "FULL TIME")
	_make_button(vb, "Rematch", func() -> void: _start_match())
	_make_button(vb, "Back to Menu", func() -> void: _set_game_state(GameState.MENU))

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
	length_opt.selected = MATCH_LENGTHS.find(half_length) if MATCH_LENGTHS.has(half_length) else 0
	length_opt.item_selected.connect(func(i: int) -> void: half_length = MATCH_LENGTHS[i]; _save_settings())
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
	if cfg.load(SETTINGS_PATH) == OK:
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
	cfg.save(SETTINGS_PATH)

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
	_add_player(team_red, -FIELD_BOUNDARY_X, 0.00, gk_speed, -1, PlayerRole.GOALKEEPER)
	_add_player(team_red, -0.65, 0.25, s, -1, PlayerRole.DEFENDER)
	_add_player(team_red, -0.65, -0.25, s, -1, PlayerRole.DEFENDER)
	_add_player(team_red, -0.60, 0.50, s, -1, PlayerRole.DEFENDER)
	_add_player(team_red, -0.60, -0.50, s, -1, PlayerRole.DEFENDER)
	_add_player(team_red, -0.35, 0.00, s, -1, PlayerRole.MIDFIELDER)
	_add_player(team_red, -0.35, 0.30, s, -1, PlayerRole.MIDFIELDER)
	_add_player(team_red, -0.35, -0.30, s, -1, PlayerRole.MIDFIELDER)
	_add_player(team_red, -0.10, 0.00, s, -1, PlayerRole.ATTACKER)
	_add_player(team_red, -0.10, 0.40, s, -1, PlayerRole.ATTACKER)
	_add_player(team_red, -0.10, -0.40, s, -1, PlayerRole.ATTACKER)
	_add_player(team_blue, FIELD_BOUNDARY_X, 0.00, gk_speed, 1, PlayerRole.GOALKEEPER)
	_add_player(team_blue, 0.65, 0.25, s, 1, PlayerRole.DEFENDER)
	_add_player(team_blue, 0.65, -0.25, s, 1, PlayerRole.DEFENDER)
	_add_player(team_blue, 0.60, 0.50, s, 1, PlayerRole.DEFENDER)
	_add_player(team_blue, 0.60, -0.50, s, 1, PlayerRole.DEFENDER)
	_add_player(team_blue, 0.35, 0.00, s, 1, PlayerRole.MIDFIELDER)
	_add_player(team_blue, 0.35, 0.30, s, 1, PlayerRole.MIDFIELDER)
	_add_player(team_blue, 0.35, -0.30, s, 1, PlayerRole.MIDFIELDER)
	_add_player(team_blue, 0.10, 0.00, s, 1, PlayerRole.ATTACKER)
	_add_player(team_blue, 0.10, 0.40, s, 1, PlayerRole.ATTACKER)
	_add_player(team_blue, 0.10, -0.40, s, 1, PlayerRole.ATTACKER)

func _add_player(team: Array[PlayerState], px: float, py: float, speed: float, side: int, role: int) -> void:
	var state := PlayerState.new(px, py, speed, side, role)
	state.node = _create_player_visual(state)
	players_root.add_child(state.node)
	team.append(state)

func _create_player_visual(state: PlayerState) -> Node3D:
	var glb_visual = _create_glb_player_visual(state)
	if glb_visual != null:
		return glb_visual
	var root := Node3D.new()
	root.name = "RedPlayer" if state.side == -1 else "BluePlayer"
	var uniform: Material = materials.goalkeeper if state.role == PlayerRole.GOALKEEPER else (materials.player_red if state.side == -1 else materials.player_blue)
	var body := _mesh("Body", BoxMesh.new(), uniform, Vector3(0.0, 0.78, 0.0))
	body.mesh.size = Vector3(0.42, 0.82, 0.26)
	root.add_child(body)
	var head := _mesh("Head", SphereMesh.new(), materials.skin, Vector3(0.0, 1.34, 0.0))
	head.mesh.radius = 0.22
	head.mesh.height = 0.42
	root.add_child(head)
	var hair := _mesh("Hair", SphereMesh.new(), materials.hair, Vector3(0.0, 1.50, -0.02))
	hair.mesh.radius = 0.19
	hair.mesh.height = 0.18
	root.add_child(hair)
	for limb_name in ["ArmL", "ArmR", "LegL", "LegR"]:
		var limb_mat: Material = uniform if limb_name.begins_with("Arm") else materials.boots
		var limb := _mesh(limb_name, BoxMesh.new(), limb_mat, Vector3.ZERO)
		limb.mesh.size = Vector3(0.13, 0.62, 0.13)
		root.add_child(limb)
	root.get_node("ArmL").position = Vector3(-0.32, 0.72, 0.0)
	root.get_node("ArmR").position = Vector3(0.32, 0.72, 0.0)
	root.get_node("LegL").position = Vector3(-0.13, 0.28, 0.0)
	root.get_node("LegR").position = Vector3(0.13, 0.28, 0.0)
	var marker := _mesh("SelectedRing", CylinderMesh.new(), materials.selection, Vector3(0.0, 0.035, 0.0))
	marker.mesh.top_radius = 0.48
	marker.mesh.bottom_radius = 0.48
	marker.mesh.height = 0.025
	marker.visible = false
	root.add_child(marker)
	var power := _mesh("PowerRing", CylinderMesh.new(), materials.power, Vector3(0.0, 0.07, 0.0))
	power.mesh.top_radius = 0.64
	power.mesh.bottom_radius = 0.64
	power.mesh.height = 0.025
	power.visible = false
	root.add_child(power)
	return root

func _create_glb_player_visual(state: PlayerState):
	var root := Node3D.new()
	root.name = "RedGLBPlayer" if state.team_index == 0 else "BlueGLBPlayer"
	state.uses_glb = true
	state.node = root
	var marker := _mesh("SelectedRing", CylinderMesh.new(), materials.selection, Vector3(0.0, 0.035, 0.0))
	marker.mesh.top_radius = 0.48
	marker.mesh.bottom_radius = 0.48
	marker.mesh.height = 0.025
	marker.visible = false
	root.add_child(marker)
	var power := _mesh("PowerRing", CylinderMesh.new(), materials.power, Vector3(0.0, 0.07, 0.0))
	power.mesh.top_radius = 0.64
	power.mesh.bottom_radius = 0.64
	power.mesh.height = 0.025
	power.visible = false
	root.add_child(power)
	# Load the character mesh once and drive its skeleton with retargeted Mixamo clips.
	var model: Node3D = _instantiate_glb(PLAYER_ASSET_DIR + PLAYER_MESH_FILE)
	if model == null:
		push_warning("Player GLB mesh failed to load: %s" % (PLAYER_ASSET_DIR + PLAYER_MESH_FILE))
		state.uses_glb = false
		root.free()
		return null
	_place_glb_model(model)
	_apply_team_tint(model, state.team_index)
	model.name = "Model"
	model.rotation_degrees = Vector3(0.0, PLAYER_GLB_YAW_OFFSET, 0.0)
	root.add_child(model)
	if _ensure_player_anim_library():
		var anim := AnimationPlayer.new()
		anim.name = "AnimationPlayer"
		model.add_child(anim)
		# Tracks read "Armature/Skeleton3D:bone", so resolve them from the model root.
		anim.root_node = anim.get_path_to(model)
		anim.add_animation_library("", player_anim_library)
		state.animation_player = anim
	else:
		push_warning("Player GLB animations unavailable; using static mesh.")
	state.visual_model = model
	_set_glb_visual_state(state, "gk_idle" if state.role == PlayerRole.GOALKEEPER else "idle")
	return root

# Builds the shared library of named clips extracted from the animation-only action GLBs.
func _ensure_player_anim_library() -> bool:
	if player_anim_ready:
		return player_anim_library != null
	player_anim_ready = true
	var lib := AnimationLibrary.new()
	for state_name in PLAYER_ANIM_FILES:
		var entry: Array = PLAYER_ANIM_FILES[state_name]
		var path: String = PLAYER_ASSET_DIR + entry[0]
		var anim := _load_glb_animation(path)
		if anim == null:
			push_warning("Player animation missing or unreadable: %s" % path)
			continue
		if entry[1]:
			anim.loop_mode = Animation.LOOP_LINEAR
		lib.add_animation(state_name, anim)
	if not lib.has_animation("idle"):
		push_warning("Player animation library missing required idle clip.")
		return false
	player_anim_library = lib
	return true

func _load_glb_animation(path: String) -> Animation:
	if not ResourceLoader.exists(path, "PackedScene"):
		push_warning("GLB animation file is not imported as PackedScene: %s" % path)
		return null
	var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
	if packed == null:
		push_warning("GLB animation file failed to load: %s" % path)
		return null
	var scene := packed.instantiate()
	var ap := _find_animation_player(scene)
	var anim: Animation = null
	if ap != null:
		var anim_name := _first_glb_animation(ap)
		if not String(anim_name).is_empty():
			anim = ap.get_animation(anim_name).duplicate()
	else:
		push_warning("GLB has no AnimationPlayer: %s" % path)
	scene.free()
	return anim

func _first_glb_animation(player: AnimationPlayer) -> StringName:
	if player.has_animation(PLAYER_GLTF_ANIM):
		return StringName(PLAYER_GLTF_ANIM)
	for anim_name in player.get_animation_list():
		if String(anim_name).to_lower() != "reset":
			return anim_name
	return StringName()

func _set_glb_visual_state(p: PlayerState, state_name: String) -> void:
	if not p.uses_glb or p.animation_player == null:
		return
	if p.visual_state == state_name:
		return
	if not p.animation_player.has_animation(state_name):
		return
	p.visual_state = state_name
	p.animation_player.play(state_name, 0.15)

func _play_glb_action(p: PlayerState, state_name: String, duration: float) -> void:
	if not p.uses_glb:
		return
	_set_glb_visual_state(p, state_name)
	p.action_timer = duration

func _instantiate_glb(path: String):
	var packed: PackedScene = null
	if glb_scene_cache.has(path):
		packed = glb_scene_cache[path]
	else:
		if not ResourceLoader.exists(path, "PackedScene"):
			glb_scene_cache[path] = null
			return null
		var res := ResourceLoader.load(path, "PackedScene")
		packed = res as PackedScene
		glb_scene_cache[path] = packed
	if packed == null:
		return null
	var instance := packed.instantiate()
	if instance is Node3D:
		return instance
	var wrapper := Node3D.new()
	wrapper.add_child(instance)
	return wrapper

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null

func _place_glb_model(model: Node3D) -> void:
	model.scale = Vector3.ONE
	model.position = Vector3.ZERO
	var bounds := _node_local_bounds(model)
	if bounds.size.length() <= 0.001 or bounds.size.y <= 0.001:
		model.scale = Vector3.ONE * PLAYER_GLB_SCALE
		model.position = Vector3(0.0, PLAYER_GLB_Y_OFFSET, 0.0)
		push_warning("Player GLB bounds unavailable; using fixed imported-model scale.")
		return
	var scale := PLAYER_GLB_SCALE
	var center := bounds.position + bounds.size * 0.5
	model.scale = Vector3.ONE * scale
	model.position = Vector3(-center.x * scale, PLAYER_GLB_Y_OFFSET - bounds.position.y * scale, -center.z * scale)

func _apply_team_tint(model: Node3D, team_index: int) -> void:
	var tint := Color(0.95, 0.10, 0.08) if team_index == 0 else Color(0.08, 0.36, 1.0)
	_apply_team_tint_recursive(model, tint)

func _apply_team_tint_recursive(node: Node, tint: Color) -> void:
	if node is MeshInstance3D and _is_uniform_mesh(node.name):
		var mesh_instance := node as MeshInstance3D
		var mesh := mesh_instance.mesh
		if mesh != null:
			for surface_idx in mesh.get_surface_count():
				var base_mat := mesh_instance.get_surface_override_material(surface_idx)
				if base_mat == null:
					base_mat = mesh.surface_get_material(surface_idx)
				var mat: Material = base_mat.duplicate() if base_mat != null else StandardMaterial3D.new()
				if mat is BaseMaterial3D:
					var base := mat as BaseMaterial3D
					base.albedo_color = base.albedo_color.lerp(tint, 0.62)
				mesh_instance.set_surface_override_material(surface_idx, mat)
	for child: Node in node.get_children():
		_apply_team_tint_recursive(child, tint)

func _is_uniform_mesh(node_name: StringName) -> bool:
	var n := String(node_name).to_lower()
	return n.contains("shirt") or n.contains("short") or n.contains("sock")

func _node_local_bounds(root: Node3D) -> AABB:
	var state := [false, Vector3.ZERO, Vector3.ZERO]
	for child: Node in root.get_children():
		_accumulate_local_bounds(child, Transform3D.IDENTITY, state)
	if not state[0]:
		return AABB()
	return AABB(state[1], state[2] - state[1])

func _accumulate_local_bounds(node: Node, parent_xform: Transform3D, state: Array) -> void:
	var current := parent_xform
	if node is Node3D:
		current = parent_xform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		var aabb: AABB = mesh_instance.get_aabb()
		for i in 8:
			var local_point: Vector3 = current * _aabb_corner(aabb, i)
			if not state[0]:
				state[1] = local_point
				state[2] = local_point
				state[0] = true
			else:
				var min_v: Vector3 = state[1]
				var max_v: Vector3 = state[2]
				state[1] = Vector3(minf(min_v.x, local_point.x), minf(min_v.y, local_point.y), minf(min_v.z, local_point.z))
				state[2] = Vector3(maxf(max_v.x, local_point.x), maxf(max_v.y, local_point.y), maxf(max_v.z, local_point.z))
	for child: Node in node.get_children():
		_accumulate_local_bounds(child, current, state)

func _aabb_corner(aabb: AABB, index: int) -> Vector3:
	return aabb.position + Vector3(
		aabb.size.x if index & 1 else 0.0,
		aabb.size.y if index & 2 else 0.0,
		aabb.size.z if index & 4 else 0.0
	)

func _create_ball() -> void:
	var root := Node3D.new()
	root.name = "Ball3D"
	var mesh := _mesh("BallMesh", SphereMesh.new(), materials.ball, Vector3.ZERO)
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
		var trail := _mesh("BallTrail%d" % i, SphereMesh.new(), materials.trail, Vector3.ZERO)
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
	# Red (team 0) is keyboard+mouse in 1P, gamepad 0 in 2P. Blue (team 1) is gamepad 1 in 2P.
	if num_players == 1:
		_read_keyboard_input(inputs[0], allow)
	else:
		_read_gamepad_input(inputs[0], 0, allow)
		_read_gamepad_input(inputs[1], 1, allow)

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
	var move := Vector2(Input.get_joy_axis(device, JOY_AXIS_LEFT_X), Input.get_joy_axis(device, JOY_AXIS_LEFT_Y))
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
	return Vector2(hit.x / FIELD_SCALE, -hit.z / FIELD_SCALE)

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
	if ball.x > FIELD_BOUNDARY_X - radius:
		ball.x = FIELD_BOUNDARY_X - radius
		hit_x = true
	elif ball.x < -FIELD_BOUNDARY_X + radius:
		ball.x = -FIELD_BOUNDARY_X + radius
		hit_x = true
	if ball.y > FIELD_BOUNDARY_Y - radius:
		ball.y = FIELD_BOUNDARY_Y - radius
		hit_y = true
	elif ball.y < -FIELD_BOUNDARY_Y + radius:
		ball.y = -FIELD_BOUNDARY_Y + radius
		hit_y = true
	if hit_y:
		ball.vy *= -1.0
	if hit_x:
		if absf(ball.y) > GOAL_HALF_WIDTH:
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
		if team[i].role == PlayerRole.GOALKEEPER and not (ball.owner_team == team_idx and ball.owner_index == i):
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
	if p.role == PlayerRole.GOALKEEPER:
		if ball.owner_team == team_idx and ball.owner_index == player_idx:
			p.hold_timer += delta
			if p.hold_timer > 1.0:
				var clear_target := _best_pass_target(p, team, opponents, -float(p.side) * FIELD_BOUNDARY_X)
				if clear_target != null:
					_kick_from_player(p, Vector2(clear_target.x, clear_target.y), 0.45, false)
				else:
					_kick_from_player(p, Vector2(-float(p.side) * 0.3, randf_range(-0.5, 0.5)), 0.7, false)
			return
		p.hold_timer = 0.0
		var target_y := clampf(ball.y, -GOAL_HALF_WIDTH, GOAL_HALF_WIDTH)
		var target_x := -FIELD_BOUNDARY_X if p.side == -1 else FIELD_BOUNDARY_X
		_move_towards(p, Vector2(target_x, target_y), current_speed, delta)
		return
	if ball.owner_team == team_idx and ball.owner_index == player_idx:
		_update_ai_owner(p, team, opponents, delta)
		return
	var own_team_has_ball := ball.owner_team == team_idx
	var target := Vector2(p.start_x, p.start_y)
	if own_team_has_ball:
		var attack_dir := -float(p.side)
		var advance := 0.25 if p.role == PlayerRole.DEFENDER else (0.50 if p.role == PlayerRole.MIDFIELDER else 0.78)
		target = Vector2(p.start_x + attack_dir * advance, p.start_y * 0.85 + ball.y * 0.15)
	else:
		var ball_owner := _owner_player()
		if ball_owner != null and ball_owner.role == PlayerRole.GOALKEEPER:
			target = Vector2(p.start_x, p.start_y)
		elif _is_presser(team, player_idx, 1 if _ball_in_own_third(p.side) else 2):
			target = Vector2(ball.x, ball.y)
		else:
			var ball_y_weight := 0.14 if _ball_in_own_third(p.side) else 0.25
			target = Vector2(p.start_x + (ball.x - p.start_x) * 0.2, p.start_y + (ball.y - p.start_y) * ball_y_weight)
			if _ball_in_own_third(p.side):
				var deepest_x := FIELD_BOUNDARY_X - (0.14 if p.role == PlayerRole.DEFENDER else 0.24)
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
		if i == player_idx or team[i].role == PlayerRole.GOALKEEPER:
			continue
		if Vector2(team[i].x - ball.x, team[i].y - ball.y).length() < my_dist:
			closer += 1
			if closer >= press_limit:
				return false
	return true

func _ball_in_own_third(side: int) -> bool:
	return ball.x * float(side) > 0.58

func _update_ai_owner(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], delta: float) -> void:
	var target_goal_x := FIELD_BOUNDARY_X if p.side == -1 else -FIELD_BOUNDARY_X
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
		if mate == p or mate.role == PlayerRole.GOALKEEPER:
			continue
		var mate_goal_dist := Vector2(target_goal_x - mate.x, -mate.y).length()
		if mate_goal_dist >= owner_goal_dist:
			continue
		var open := true
		for opp in opponents:
			if Vector2(opp.x - mate.x, opp.y - mate.y).length() < 0.18:
				open = false
		var role_bonus := 4.0 if mate.role == PlayerRole.ATTACKER else (2.0 if mate.role == PlayerRole.MIDFIELDER else 0.0)
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
	var target_goal_x := FIELD_BOUNDARY_X if p.side == -1 else -FIELD_BOUNDARY_X
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
	_play_glb_action(p, "kick", 0.7)

func _try_capture_ball(team: Array[PlayerState], team_idx: int, player_idx: int) -> void:
	var p := team[player_idx]
	var capture_radius := 0.045
	if p.role == PlayerRole.GOALKEEPER:
		capture_radius = 0.05 if ball.is_super_shot else 0.10
	if Vector2(p.x - ball.x, p.y - ball.y).length() < capture_radius:
		if ball.owner_team == -1 and p.stun_timer <= 0.0:
			_set_owner(team_idx, player_idx)
			_play_glb_action(p, "receive", 0.45)
		elif ball.owner_team != -1 and _owner_side() != p.side and p.stun_timer <= 0.0:
			var old := _owner_player()
			if old != null and old.role != PlayerRole.GOALKEEPER:
				old.stun_timer = 0.45
				old.kick_power = 0.0
				_set_owner(team_idx, player_idx)
				_play_glb_action(p, "tackle", 0.55)

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
	if p.role == PlayerRole.GOALKEEPER:
		var area_limit := FIELD_BOUNDARY_X - PENALTY_AREA_WIDTH
		if p.side == -1:
			p.x = clampf(p.x, -FIELD_BOUNDARY_X + half, -area_limit + half)
		else:
			p.x = clampf(p.x, area_limit - half, FIELD_BOUNDARY_X - half)
		p.y = clampf(p.y, -PENALTY_AREA_HEIGHT + half, PENALTY_AREA_HEIGHT - half)
	else:
		p.x = clampf(p.x, -FIELD_BOUNDARY_X + half, FIELD_BOUNDARY_X - half)
		p.y = clampf(p.y, -FIELD_BOUNDARY_Y + half, FIELD_BOUNDARY_Y - half)

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
	p.node.position = to_3d(Vector2(p.x, p.y), 0.0)
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
	p.node.position = to_3d(Vector2(p.x, p.y), 0.0)
	var face := Vector3(p.facing_x, 0.0, -p.facing_y)
	if face.length() > 0.001:
		p.node.rotation.y = atan2(face.x, face.z)
	if p.action_timer > 0.0:
		p.action_timer = maxf(0.0, p.action_timer - delta)
	else:
		if p.role == PlayerRole.GOALKEEPER:
			_set_glb_visual_state(p, "run" if p.is_moving else "gk_idle")
		else:
			_set_glb_visual_state(p, "run" if p.is_moving else "idle")
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
	ball.node.position = to_3d(Vector2(ball.x, ball.y), visual_height)
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
	var target_pos := Vector3(clampf(ball.x * FIELD_SCALE * 0.25, -5.0, 5.0), 18.0, 24.0 + clampf(-ball.y * FIELD_SCALE * 0.12, -2.5, 2.5))
	camera_rig.position = camera_rig.position.lerp(target_pos, 1.0 - exp(-1.8 * delta))
	camera_look = camera_look.lerp(to_3d(Vector2(ball.x, ball.y), 0.2), 1.0 - exp(-3.5 * delta))
	camera_3d.look_at(camera_look, Vector3.UP)

func _update_scoreboard() -> void:
	if score_label != null:
		score_label.text = "%d - %d" % [score_left, score_right]
	if timer_label != null:
		if game_state != GameState.PLAYING:
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
		var piece := _mesh("Confetti", BoxMesh.new(), mat, to_3d(Vector2(randf_range(-0.75, 0.75), randf_range(-0.55, 0.55)), randf_range(2.2, 4.2)))
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

func _mesh(node_name: String, mesh: Mesh, mat: Material, pos: Vector3) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.material_override = mat
	node.position = pos
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return node

func _material(color: Color, roughness := 0.65, metallic := 0.0, texture: Texture2D = null) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.metallic = metallic
	if texture != null:
		mat.albedo_texture = texture
		mat.uv1_scale = Vector3(8.0, 8.0, 1.0)
	if color.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.no_depth_test = false
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat

func _emission_material(color: Color, energy := 1.0) -> StandardMaterial3D:
	var mat := _material(color, 0.35)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	return mat

func _checker_texture(a: Color, b: Color, size: int, cells: int) -> Texture2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var use_a := ((x / cells) + (y / cells)) % 2 == 0
			img.set_pixel(x, y, a if use_a else b)
	return ImageTexture.create_from_image(img)

func _noise_texture(base: Color, variation: float, size := 128) -> Texture2D:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x1EE7
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var f := 1.0 + rng.randf_range(-variation, variation)
			img.set_pixel(x, y, Color(base.r * f, base.g * f, base.b * f))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _net_texture(size := 64, step := 8) -> Texture2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 0.0))
	for y in size:
		for x in size:
			if x % step == 0 or y % step == 0:
				img.set_pixel(x, y, Color(0.92, 0.95, 1.0, 0.8))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func to_3d(p: Vector2, height := 0.0) -> Vector3:
	return Vector3(p.x * FIELD_SCALE, height, -p.y * FIELD_SCALE)
