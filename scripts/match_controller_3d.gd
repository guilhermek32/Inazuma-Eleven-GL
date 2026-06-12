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
const FIELD_SCALE := 18.0
const PITCH_Y := 0.0

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
	var stun_timer := 0.0
	var kick_power := 0.0
	var hold_timer := 0.0
	var is_moving := false
	var is_targeting_ball := false
	var node: Node3D

	func _init(p_x: float, p_y: float, p_speed: float, p_side: int, p_role: int) -> void:
		x = p_x
		y = p_y
		start_x = p_x
		start_y = p_y
		speed = p_speed
		side = p_side
		role = p_role
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

var materials := {}
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
var scoreboard_3d_label: Label3D
var team_red: Array[PlayerState] = []
var team_blue: Array[PlayerState] = []
var ball := BallState.new()
var ball_trail: Array[MeshInstance3D] = []
var ball_trail_points: Array[Vector3] = []
var confetti: Array[VfxParticle] = []
var score_left := 0
var score_right := 0
var kickoff_timer := 2.0
var axis := Vector2.ZERO
var shoot_pressed := false
var shoot_was_pressed := false
var aim_world := Vector2.ZERO
var selected_player_index := -1
var celebration_timer := 0.0
var camera_look := Vector3.ZERO

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
	_reset_game(1)
	print("Inazuma Eleven 3D environment ready")

func _process(delta: float) -> void:
	_read_input()
	_update_kickoff(delta)
	var scorer := _update_ball(delta)
	if scorer != 0:
		_trigger_goal(scorer)
	_update_team(team_red, team_blue, 0, true, delta)
	_update_team(team_blue, team_red, 1, false, delta)
	_update_visuals(delta)
	_update_confetti(delta)
	_update_scoreboard()

func _build_materials() -> void:
	materials.grass = _material(Color(0.08, 0.42, 0.13), 0.85, 0.0, _checker_texture(Color(0.06, 0.35, 0.10), Color(0.13, 0.53, 0.18), 128, 8))
	materials.grass_dark = _material(Color(0.06, 0.33, 0.10), 0.9)
	materials.line = _material(Color(0.95, 0.97, 0.92), 0.55)
	materials.goal = _material(Color(0.92, 0.93, 0.90), 0.28, 0.25)
	materials.net = _material(Color(0.86, 0.92, 1.0, 0.34), 0.72)
	materials.concrete = _material(Color(0.37, 0.36, 0.34), 0.92, 0.0, _checker_texture(Color(0.28, 0.28, 0.27), Color(0.45, 0.44, 0.41), 128, 16))
	materials.seat_red = _material(Color(0.55, 0.06, 0.05), 0.65)
	materials.seat_blue = _material(Color(0.04, 0.10, 0.55), 0.65)
	materials.metal_dark = _material(Color(0.20, 0.21, 0.22), 0.38, 0.55)
	materials.light_emission = _emission_material(Color(1.0, 0.94, 0.72), 2.0)
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
	sky_mat.sky_top_color = Color(0.18, 0.35, 0.62)
	sky_mat.sky_horizon_color = Color(0.72, 0.80, 0.90)
	sky_mat.ground_bottom_color = Color(0.05, 0.08, 0.07)
	sky_mat.ground_horizon_color = Color(0.18, 0.22, 0.18)
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.38
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.25
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
	var sun := DirectionalLight3D.new()
	sun.name = "SunLight"
	sun.light_color = Color(1.0, 0.92, 0.78)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.light_angular_distance = 0.8
	sun.rotation_degrees = Vector3(-52.0, -34.0, 0.0)
	add_child(sun)
	var flood_root := Node3D.new()
	flood_root.name = "FloodLights"
	add_child(flood_root)
	var positions := [
		Vector3(-24.0, 14.0, -19.0),
		Vector3(24.0, 14.0, -19.0),
		Vector3(-24.0, 14.0, 19.0),
		Vector3(24.0, 14.0, 19.0),
		Vector3(0.0, 16.0, -31.0),
		Vector3(0.0, 16.0, 31.0),
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
	spot.light_energy = 4.5
	spot.spot_range = 52.0
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
	var x := FIELD_HALF_WIDTH * FIELD_SCALE
	var z := FIELD_HALF_HEIGHT * FIELD_SCALE
	_add_line_segment(Vector3(-x, 0.06, -z), Vector3(x, 0.06, -z), 0.07, "SidelineTop")
	_add_line_segment(Vector3(-x, 0.06, z), Vector3(x, 0.06, z), 0.07, "SidelineBottom")
	_add_line_segment(Vector3(-x, 0.06, -z), Vector3(-x, 0.06, z), 0.07, "EndlineLeft")
	_add_line_segment(Vector3(x, 0.06, -z), Vector3(x, 0.06, z), 0.07, "EndlineRight")
	_add_line_segment(Vector3(0.0, 0.065, -z), Vector3(0.0, 0.065, z), 0.06, "HalfwayLine")
	_add_circle(Vector3.ZERO, 0.16 * FIELD_SCALE, 64, 0.055, "CenterCircle")
	_add_penalty_box(-1)
	_add_penalty_box(1)

func _add_penalty_box(side: int) -> void:
	var xb := FIELD_BOUNDARY_X * FIELD_SCALE * float(side)
	var xi := (FIELD_BOUNDARY_X - PENALTY_AREA_WIDTH) * FIELD_SCALE * float(side)
	var z := PENALTY_AREA_HEIGHT * FIELD_SCALE
	_add_line_segment(Vector3(xb, 0.07, -z), Vector3(xi, 0.07, -z), 0.055, "PenaltyA%d" % side)
	_add_line_segment(Vector3(xb, 0.07, z), Vector3(xi, 0.07, z), 0.055, "PenaltyB%d" % side)
	_add_line_segment(Vector3(xi, 0.07, -z), Vector3(xi, 0.07, z), 0.055, "PenaltyC%d" % side)

func _add_circle(center: Vector3, radius: float, segments: int, width: float, node_name: String) -> void:
	for i in segments:
		var a0 := float(i) / float(segments) * TAU
		var a1 := float(i + 1) / float(segments) * TAU
		var p0 := center + Vector3(cos(a0) * radius, 0.075, sin(a0) * radius)
		var p1 := center + Vector3(cos(a1) * radius, 0.075, sin(a1) * radius)
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
	var net := _mesh("Net", BoxMesh.new(), materials.net, Vector3(x + depth * 0.5, height * 0.52, 0.0))
	net.mesh.size = Vector3(absf(depth), height, half_w * 2.0)
	goal.add_child(net)

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
	_add_stand("NorthStand", Vector3(0.0, 1.0, -field_z - 5.0), Vector3(field_x * 2.5, 2.0, 5.0), materials.concrete)
	_add_stand("SouthStand", Vector3(0.0, 1.0, field_z + 5.0), Vector3(field_x * 2.5, 2.0, 5.0), materials.concrete)
	_add_stand("WestStand", Vector3(-field_x - 5.5, 1.0, 0.0), Vector3(5.0, 2.0, field_z * 2.0), materials.concrete)
	_add_stand("EastStand", Vector3(field_x + 5.5, 1.0, 0.0), Vector3(5.0, 2.0, field_z * 2.0), materials.concrete)
	_add_crowd_cards(field_x, field_z)
	_add_scoreboard(Vector3(0.0, 5.2, -field_z - 7.8))

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
	scoreboard_3d_label = Label3D.new()
	scoreboard_3d_label.name = "ScoreboardText"
	scoreboard_3d_label.text = "0 - 0"
	scoreboard_3d_label.font_size = 96
	scoreboard_3d_label.modulate = Color(0.45, 1.0, 0.55)
	scoreboard_3d_label.position = pos + Vector3(0.0, 0.08, 0.18)
	stadium_root.add_child(scoreboard_3d_label)
	scoreboard_3d_label.look_at(Vector3.ZERO, Vector3.UP)

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
			_add_fan_sprite(fan_textures[(i + row) % fan_textures.size()], Vector3(x, 1.25 + row * 0.62, -field_z - 3.6 - row * 0.55), Vector3(0.0, PI, 0.0))
			_add_fan_sprite(fan_textures[(i + row + 1) % fan_textures.size()], Vector3(x, 1.25 + row * 0.62, field_z + 3.6 + row * 0.55), Vector3.ZERO)
	for row in 2:
		for i in 14:
			var z := -field_z * 0.9 + float(i) * (field_z * 1.8 / 13.0)
			_add_fan_sprite(fan_textures[(i + row) % fan_textures.size()], Vector3(-field_x - 3.8 - row * 0.55, 1.25 + row * 0.62, z), Vector3(0.0, PI * 0.5, 0.0))
			_add_fan_sprite(fan_textures[(i + row + 2) % fan_textures.size()], Vector3(field_x + 3.8 + row * 0.55, 1.25 + row * 0.62, z), Vector3(0.0, -PI * 0.5, 0.0))

func _add_fan_sprite(texture: Texture2D, feet_pos: Vector3, rot: Vector3) -> void:
	var sprite := Sprite3D.new()
	sprite.name = "CrowdCard"
	sprite.texture = texture
	var fan_height := 1.9
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
	score_label.position = Vector2(720.0, 20.0)
	score_label.add_theme_font_size_override("font_size", 56)
	score_label.add_theme_color_override("font_color", Color.WHITE)
	ui_layer.add_child(score_label)
	timer_label = Label.new()
	timer_label.name = "TimerLabel"
	timer_label.position = Vector2(700.0, 88.0)
	timer_label.add_theme_font_size_override("font_size", 26)
	timer_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.25))
	ui_layer.add_child(timer_label)

func _setup_input_actions() -> void:
	_add_key_action("move_up", KEY_W)
	_add_key_action("move_down", KEY_S)
	_add_key_action("move_left", KEY_A)
	_add_key_action("move_right", KEY_D)
	_add_key_action("shoot", KEY_SPACE)

func _add_key_action(action: StringName, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	for existing in InputMap.action_get_events(action):
		if existing is InputEventKey and existing.physical_keycode == keycode:
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

func _reset_game(scoring_team_side: int) -> void:
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
	if scoring_team_side == -1:
		_set_owner(0, 5)
	else:
		_set_owner(1, 5)
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

func _read_input() -> void:
	var allow := kickoff_timer <= 0.0
	axis = Vector2.ZERO
	if allow:
		axis.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
		axis.y = Input.get_action_strength("move_up") - Input.get_action_strength("move_down")
		axis = axis.normalized() if axis.length_squared() > 1.0 else axis
	shoot_was_pressed = shoot_pressed
	shoot_pressed = allow and Input.is_action_pressed("shoot")
	aim_world = _mouse_aim_world()

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
			score_left += 1
			_reset_game(1)
			return -1
		else:
			score_right += 1
			_reset_game(-1)
			return 1
	return 0

func _update_team(team: Array[PlayerState], opponents: Array[PlayerState], team_idx: int, is_user_team: bool, delta: float) -> void:
	var user_idx := _nearest_user_player(team, team_idx) if is_user_team else -1
	if is_user_team:
		selected_player_index = user_idx
	for i in team.size():
		var p := team[i]
		p.is_moving = false
		if kickoff_timer <= 0.0 and i == user_idx and _has_user_input(p):
			_update_user_player(p, team_idx, i, delta)
		elif kickoff_timer <= 0.0:
			_update_ai_player(p, team, opponents, team_idx, i, delta)
		_try_capture_ball(team, team_idx, i)

func _has_user_input(p: PlayerState) -> bool:
	return axis != Vector2.ZERO or shoot_pressed or shoot_was_pressed or p.kick_power > 0.0

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

func _update_user_player(p: PlayerState, team_idx: int, player_idx: int, delta: float) -> void:
	if p.stun_timer > 0.0:
		p.stun_timer -= delta
	var speed_mult := 0.3 if p.stun_timer > 0.0 else 1.0
	if p.kick_power > 0.0:
		speed_mult *= 0.8
	if axis != Vector2.ZERO:
		p.x += axis.x * p.speed * speed_mult * delta
		p.y += axis.y * p.speed * speed_mult * delta
		p.facing_x = axis.x if axis.x != 0.0 else p.facing_x
		p.facing_y = axis.y if axis.y != 0.0 else p.facing_y
		p.is_moving = true
		_clamp_player(p)
	if ball.owner_team == team_idx and ball.owner_index == player_idx:
		ball.charging_power = p.kick_power
		if shoot_pressed:
			p.kick_power = minf(1.0, p.kick_power + delta * 2.0)
		elif shoot_was_pressed:
			_kick_from_player(p, aim_world, p.kick_power, true)
	else:
		p.kick_power = 0.0

func _update_ai_player(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], team_idx: int, player_idx: int, delta: float) -> void:
	if p.stun_timer > 0.0:
		p.stun_timer -= delta
	var current_speed := p.speed * (0.3 if p.stun_timer > 0.0 else 1.0)
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
		elif _is_presser(team, player_idx):
			target = Vector2(ball.x, ball.y)
		else:
			target = Vector2(p.start_x + (ball.x - p.start_x) * 0.2, p.start_y + (ball.y - p.start_y) * 0.25)
	for mate in team:
		if mate == p:
			continue
		var away := Vector2(p.x - mate.x, p.y - mate.y)
		var d := away.length()
		if d < 0.16 and d > 0.001:
			target += away / d * 0.10
	_move_towards(p, target, current_speed * (0.88 if own_team_has_ball else 0.95), delta)

func _is_presser(team: Array[PlayerState], player_idx: int) -> bool:
	var my_dist := Vector2(team[player_idx].x - ball.x, team[player_idx].y - ball.y).length()
	var closer := 0
	for i in team.size():
		if i == player_idx or team[i].role == PlayerRole.GOALKEEPER:
			continue
		if Vector2(team[i].x - ball.x, team[i].y - ball.y).length() < my_dist:
			closer += 1
			if closer >= 2:
				return false
	return true

func _update_ai_owner(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], delta: float) -> void:
	var target_goal_x := FIELD_BOUNDARY_X if p.side == -1 else -FIELD_BOUNDARY_X
	var dist_to_goal := Vector2(target_goal_x - p.x, -p.y).length()
	if dist_to_goal < 0.40 and randf() < 2.4 * delta:
		_kick_from_player(p, Vector2(target_goal_x, 0.0), 0.75, false)
		ball.is_super_shot = true
		return
	if randf() < 1.8 * delta:
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

func _try_capture_ball(team: Array[PlayerState], team_idx: int, player_idx: int) -> void:
	var p := team[player_idx]
	var capture_radius := 0.045
	if p.role == PlayerRole.GOALKEEPER:
		capture_radius = 0.05 if ball.is_super_shot else 0.10
	if Vector2(p.x - ball.x, p.y - ball.y).length() < capture_radius:
		if ball.owner_team == -1 and p.stun_timer <= 0.0:
			_set_owner(team_idx, player_idx)
		elif ball.owner_team != -1 and _owner_side() != p.side and p.stun_timer <= 0.0:
			var old := _owner_player()
			if old != null and old.role != PlayerRole.GOALKEEPER:
				old.stun_timer = 0.45
				old.kick_power = 0.0
				_set_owner(team_idx, player_idx)

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
	p.node.position = to_3d(Vector2(p.x, p.y), 0.0)
	var face := Vector3(p.facing_x, 0.0, -p.facing_y)
	if face.length() > 0.001:
		p.node.rotation.y = atan2(face.x, face.z)
	var swing := sin(Time.get_ticks_msec() * 0.012) * (0.55 if p.is_moving else 0.08)
	(p.node.get_node("ArmL") as Node3D).rotation.x = swing
	(p.node.get_node("ArmR") as Node3D).rotation.x = -swing
	(p.node.get_node("LegL") as Node3D).rotation.x = -swing
	(p.node.get_node("LegR") as Node3D).rotation.x = swing
	(p.node.get_node("SelectedRing") as Node3D).visible = owns_ball or (p.side == -1 and team_red.find(p) == selected_player_index)
	var power_ring := p.node.get_node("PowerRing") as Node3D
	power_ring.visible = p.kick_power > 0.01
	power_ring.scale = Vector3.ONE * (0.55 + p.kick_power * 0.55)
	if p.is_moving:
		p.node.position.y = absf(sin(Time.get_ticks_msec() * 0.018)) * 0.05
	else:
		p.node.position.y = 0.0

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
	if scoreboard_3d_label != null:
		scoreboard_3d_label.text = "%d - %d" % [score_left, score_right]
	if timer_label != null:
		timer_label.text = "Kickoff %.1f" % kickoff_timer if kickoff_timer > 0.0 else ""

func _trigger_goal(_scorer: int) -> void:
	celebration_timer = 1.5
	_spawn_confetti()

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

func _clear_owner() -> void:
	ball.owner_team = -1
	ball.owner_index = -1

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

func to_3d(p: Vector2, height := 0.0) -> Vector3:
	return Vector3(p.x * FIELD_SCALE, height, -p.y * FIELD_SCALE)
