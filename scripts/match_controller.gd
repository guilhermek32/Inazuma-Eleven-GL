extends Node2D

enum PlayerRole { GOALKEEPER, DEFENDER, MIDFIELDER, ATTACKER }

const FIELD_HALF_WIDTH := 0.98
const FIELD_HALF_HEIGHT := 0.78
const FIELD_BOUNDARY_X := 0.93
const FIELD_BOUNDARY_Y := 0.73
const GOAL_HALF_WIDTH := 0.18
const GOAL_DEPTH := 0.05
const PENALTY_AREA_WIDTH := 0.22
const PENALTY_AREA_HEIGHT := 0.32
const BASE_SCALE := 520.0

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
	var is_targeting_ball := false
	var stun_timer := 0.0
	var kick_power := 0.0
	var anim_timer := 0.0
	var is_moving := false
	var tex_face: Texture2D
	var tex_back: Texture2D
	var tex_left: Texture2D
	var tex_right: Texture2D
	var run_frames_left: Array[Texture2D] = []
	var run_frames_right: Array[Texture2D] = []

	func _init(p_start_x: float, p_start_y: float, p_speed: float, p_side: int, p_role: int, p_face: Texture2D, p_back: Texture2D, p_left: Texture2D, p_right: Texture2D) -> void:
		x = p_start_x
		y = p_start_y
		start_x = p_start_x
		start_y = p_start_y
		speed = p_speed
		side = p_side
		role = p_role
		facing_x = float(p_side)
		tex_face = p_face
		tex_back = p_back
		tex_left = p_left
		tex_right = p_right

class BallState:
	var x := 0.0
	var y := 0.0
	var vx := 0.0
	var vy := 0.0
	var friction := 0.98
	var owner_team := -1
	var owner_index := -1
	var is_super_shot := false
	var rotation := 0.0
	var current_frame := 0
	var animation_timer := 0.0
	var spin_x := 0.0
	var spin_y := 0.0
	var spin_z := 0.0
	var magnus_force_scale := 0.8
	var charging_power := 0.0
	var trail: Array[Vector2] = []

class Particle:
	var pos := Vector2.ZERO
	var vel := Vector2.ZERO
	var life := 0.0
	var max_life := 0.0
	var size := 4.0
	var color := Color.WHITE

	func _init(p_pos: Vector2, p_vel: Vector2, p_life: float, p_size: float, p_color: Color) -> void:
		pos = p_pos
		vel = p_vel
		life = p_life
		max_life = p_life
		size = p_size
		color = p_color

var ball := BallState.new()
var team_red: Array[PlayerState] = []
var team_blue: Array[PlayerState] = []
var particles: Array[Particle] = []
var score_left := 0
var score_right := 0
var kickoff_timer := 2.0
var kickoff_whistle_played := false
var axis := Vector2.ZERO
var aim_world := Vector2.ZERO
var shoot_pressed := false
var shoot_was_pressed := false
var crowd_clock := 0.0
var celebration_timer := 0.0
var celebration_side := 0

var blue_face: Texture2D
var blue_back: Texture2D
var blue_left: Texture2D
var blue_right: Texture2D
var blue_gk: Texture2D
var red_face: Texture2D
var red_back: Texture2D
var red_left: Texture2D
var red_right: Texture2D
var red_gk: Texture2D
var blue_run_right: Array[Texture2D] = []
var blue_run_left: Array[Texture2D] = []
var red_run_right: Array[Texture2D] = []
var red_run_left: Array[Texture2D] = []
var ball_frames: Array[Texture2D] = []
var ball_super: Texture2D
var fans_blue: Array[Texture2D] = []
var fans_red: Array[Texture2D] = []
var music_stream: AudioStream
var kick_stream: AudioStream
var whistle_stream: AudioStream
var music_player: AudioStreamPlayer
var ui_layer: CanvasLayer
var score_label: Label
var timer_label: Label

func _ready() -> void:
	_setup_input_actions()
	_load_assets()
	_setup_audio()
	_setup_ui()
	_create_teams()
	_reset_game(1)
	set_process(true)

func _exit_tree() -> void:
	for child in get_children():
		if child is AudioStreamPlayer:
			child.stop()
			child.stream = null
	music_stream = null
	kick_stream = null
	whistle_stream = null

func _process(delta: float) -> void:
	crowd_clock += delta
	if celebration_timer > 0.0:
		celebration_timer = maxf(0.0, celebration_timer - delta)
	_update_kickoff(delta)
	_read_input()
	var scorer := _update_ball(delta)
	if scorer != 0:
		celebration_side = scorer
		celebration_timer = 1.5
		particles.clear()
		var goal_x := -0.93 if scorer > 0 else 0.93
		_emit_particles(Vector2(goal_x, 0.0), Vector2(0.0, 0.5), 40, 1.5, 6.0, Color(1.0, 0.84, 0.0))
		kickoff_whistle_played = false
	_update_ball_visuals(delta)
	_update_particles(delta)
	_update_team(team_red, team_blue, 0, true, delta)
	_update_team(team_blue, team_red, 1, false, delta)
	_update_ui()
	queue_redraw()

func _draw() -> void:
	_draw_stadium()
	_draw_field()
	_draw_ball_effects()
	_draw_ball()
	_draw_particles()
	for p in team_red:
		_draw_player(p)
	for p in team_blue:
		_draw_player(p)

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
	var has_event := false
	for existing in InputMap.action_get_events(action):
		if existing is InputEventKey and existing.physical_keycode == keycode:
			has_event = true
	if not has_event:
		InputMap.action_add_event(action, event)

func _load_assets() -> void:
	blue_face = _tex("res://assets/players_blue/face_blue.png")
	blue_back = _tex("res://assets/players_blue/back_blue.png")
	blue_left = _tex("res://assets/players_blue/left_blue.png")
	blue_right = _tex("res://assets/players_blue/right_blue.png")
	blue_gk = _tex("res://assets/players_blue/gk_blue_left.png")
	red_face = _tex("res://assets/players_red/face_Red.png")
	red_back = _tex("res://assets/players_red/back_red.png")
	red_left = _tex("res://assets/players_red/left_red.png")
	red_right = _tex("res://assets/players_red/right_red.png")
	red_gk = _tex("res://assets/players_red/gk_red_right_1.png")
	blue_run_right = _textures(["res://assets/players_blue/running/run_blue1.png", "res://assets/players_blue/running/run_blue2.png", "res://assets/players_blue/running/run_blue3.png", "res://assets/players_blue/running/run_blue4.png"])
	blue_run_left = _textures(["res://assets/players_blue/running/run_blue1_left.png", "res://assets/players_blue/running/run_blue2_left.png", "res://assets/players_blue/running/run_blue3_left.png", "res://assets/players_blue/running/run_blue_left4.png"])
	red_run_right = _textures(["res://assets/players_red/running/run_red_1.png", "res://assets/players_red/running/run_red2.png", "res://assets/players_red/running/run_red3.png", "res://assets/players_red/running/run_red4.png"])
	red_run_left = _textures(["res://assets/players_red/running/run_red_left2.png", "res://assets/players_red/running/run_red_left3.png", "res://assets/players_red/running/run_red_left4.png"])
	ball_frames = _textures(["res://assets/ball/ball1.png", "res://assets/ball/ball2.png", "res://assets/ball/ball3.png", "res://assets/ball/ball4.png", "res://assets/ball/ball5.png"])
	ball_super = _tex("res://assets/ball/ball_super1.png")
	fans_blue = _textures(["res://assets/fans/fans_blue_1.png", "res://assets/fans/fans_blue_2.png"])
	fans_red = _textures(["res://assets/fans/fans_red_1.png", "res://assets/fans/fans_red_2.png"])
	if DisplayServer.get_name() != "headless":
		music_stream = _res("res://assets/sound/background-sound.mp3")
		kick_stream = _res("res://assets/sound/kick.mp3")
		whistle_stream = _res("res://assets/sound/referee-start.mp3")

func _tex(path: String) -> Texture2D:
	return _res(path) as Texture2D

func _res(path: String) -> Resource:
	if ResourceLoader.exists(path):
		return load(path)
	return null

func _textures(paths: Array[String]) -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	for path in paths:
		var texture := _tex(path)
		if texture != null:
			out.append(texture)
	return out

func _setup_audio() -> void:
	if DisplayServer.get_name() == "headless":
		return
	music_player = AudioStreamPlayer.new()
	music_player.name = "MusicPlayer"
	music_player.stream = music_stream
	music_player.volume_db = linear_to_db(0.45)
	add_child(music_player)
	if music_stream != null:
		music_player.finished.connect(_on_music_finished)
		music_player.play()

func _on_music_finished() -> void:
	music_player.play()

func _play_sfx(stream: AudioStream, volume := 1.0) -> void:
	if stream == null:
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = linear_to_db(volume)
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()

func _setup_ui() -> void:
	ui_layer = CanvasLayer.new()
	add_child(ui_layer)
	score_label = Label.new()
	score_label.position = Vector2(720, 20)
	score_label.add_theme_font_size_override("font_size", 48)
	score_label.add_theme_color_override("font_color", Color.WHITE)
	ui_layer.add_child(score_label)
	timer_label = Label.new()
	timer_label.position = Vector2(735, 78)
	timer_label.add_theme_font_size_override("font_size", 28)
	timer_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.2))
	ui_layer.add_child(timer_label)

func _create_teams() -> void:
	team_red.clear()
	team_blue.clear()
	var s := 0.2
	team_red.append(PlayerState.new(-FIELD_BOUNDARY_X, 0.00, s, -1, PlayerRole.GOALKEEPER, red_gk, red_gk, red_gk, red_gk))
	team_red.append(PlayerState.new(-0.65, 0.25, s, -1, PlayerRole.DEFENDER, red_face, red_back, red_left, red_right))
	team_red.append(PlayerState.new(-0.65, -0.25, s, -1, PlayerRole.DEFENDER, red_face, red_back, red_left, red_right))
	team_red.append(PlayerState.new(-0.60, 0.50, s, -1, PlayerRole.DEFENDER, red_face, red_back, red_left, red_right))
	team_red.append(PlayerState.new(-0.60, -0.50, s, -1, PlayerRole.DEFENDER, red_face, red_back, red_left, red_right))
	team_red.append(PlayerState.new(-0.35, 0.00, s, -1, PlayerRole.MIDFIELDER, red_face, red_back, red_left, red_right))
	team_red.append(PlayerState.new(-0.35, 0.30, s, -1, PlayerRole.MIDFIELDER, red_face, red_back, red_left, red_right))
	team_red.append(PlayerState.new(-0.35, -0.30, s, -1, PlayerRole.MIDFIELDER, red_face, red_back, red_left, red_right))
	team_red.append(PlayerState.new(-0.10, 0.00, s, -1, PlayerRole.ATTACKER, red_face, red_back, red_left, red_right))
	team_red.append(PlayerState.new(-0.10, 0.40, s, -1, PlayerRole.ATTACKER, red_face, red_back, red_left, red_right))
	team_red.append(PlayerState.new(-0.10, -0.40, s, -1, PlayerRole.ATTACKER, red_face, red_back, red_left, red_right))
	team_blue.append(PlayerState.new(FIELD_BOUNDARY_X, 0.00, s, 1, PlayerRole.GOALKEEPER, blue_gk, blue_gk, blue_gk, blue_gk))
	team_blue.append(PlayerState.new(0.65, 0.25, s, 1, PlayerRole.DEFENDER, blue_face, blue_back, blue_left, blue_right))
	team_blue.append(PlayerState.new(0.65, -0.25, s, 1, PlayerRole.DEFENDER, blue_face, blue_back, blue_left, blue_right))
	team_blue.append(PlayerState.new(0.60, 0.50, s, 1, PlayerRole.DEFENDER, blue_face, blue_back, blue_left, blue_right))
	team_blue.append(PlayerState.new(0.60, -0.50, s, 1, PlayerRole.DEFENDER, blue_face, blue_back, blue_left, blue_right))
	team_blue.append(PlayerState.new(0.35, 0.00, s, 1, PlayerRole.MIDFIELDER, blue_face, blue_back, blue_left, blue_right))
	team_blue.append(PlayerState.new(0.35, 0.30, s, 1, PlayerRole.MIDFIELDER, blue_face, blue_back, blue_left, blue_right))
	team_blue.append(PlayerState.new(0.35, -0.30, s, 1, PlayerRole.MIDFIELDER, blue_face, blue_back, blue_left, blue_right))
	team_blue.append(PlayerState.new(0.10, 0.00, s, 1, PlayerRole.ATTACKER, blue_face, blue_back, blue_left, blue_right))
	team_blue.append(PlayerState.new(0.10, 0.40, s, 1, PlayerRole.ATTACKER, blue_face, blue_back, blue_left, blue_right))
	team_blue.append(PlayerState.new(0.10, -0.40, s, 1, PlayerRole.ATTACKER, blue_face, blue_back, blue_left, blue_right))
	for p in team_red:
		if p.role != PlayerRole.GOALKEEPER:
			p.run_frames_right = red_run_right if not red_run_right.is_empty() else [red_face]
			p.run_frames_left = red_run_left if not red_run_left.is_empty() else [red_face]
	for p in team_blue:
		if p.role != PlayerRole.GOALKEEPER:
			p.run_frames_right = blue_run_right if not blue_run_right.is_empty() else [blue_face]
			p.run_frames_left = blue_run_left if not blue_run_left.is_empty() else [blue_face]

func _reset_game(scoring_team_side: int) -> void:
	ball.x = 0.0
	ball.y = 0.0
	ball.vx = 0.0
	ball.vy = 0.0
	ball.owner_team = -1
	ball.owner_index = -1
	ball.charging_power = 0.0
	ball.trail.clear()
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
		p.stun_timer = 0.0
		p.kick_power = 0.0
		p.is_moving = false
		p.facing_x = float(p.side)
		p.facing_y = 0.0

func _set_owner(team_idx: int, player_idx: int) -> void:
	ball.owner_team = team_idx
	ball.owner_index = player_idx

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

func _update_kickoff(delta: float) -> void:
	if kickoff_timer > 0.0:
		kickoff_timer = maxf(0.0, kickoff_timer - delta)
		if kickoff_timer <= 0.0 and not kickoff_whistle_played:
			kickoff_whistle_played = true
			_play_sfx(whistle_stream, 0.3)

func _read_input() -> void:
	var allow := kickoff_timer <= 0.0
	axis = Vector2.ZERO
	if allow:
		axis.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
		axis.y = Input.get_action_strength("move_up") - Input.get_action_strength("move_down")
		axis = axis.normalized() if axis.length_squared() > 1.0 else axis
	shoot_was_pressed = shoot_pressed
	shoot_pressed = allow and Input.is_action_pressed("shoot")
	aim_world = _screen_to_world(get_viewport().get_mouse_position())

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
	var radius := 0.01
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

func _update_ball_visuals(delta: float) -> void:
	if ball.trail.size() >= 8:
		ball.trail.pop_front()
	ball.trail.append(Vector2(ball.x, ball.y))
	var speed := Vector2(ball.vx, ball.vy).length()
	if speed > 0.001:
		ball.rotation = fmod(ball.rotation + speed * 90.0 * delta, TAU)
		var spin_mag := Vector3(ball.spin_x, ball.spin_y, ball.spin_z).length()
		if spin_mag > 0.01:
			var magnus := spin_mag * ball.magnus_force_scale * 0.05
			ball.vx += -ball.vy * magnus * delta
			ball.vy += ball.vx * magnus * delta
			ball.spin_x *= pow(0.98, delta * 60.0)
			ball.spin_y *= pow(0.98, delta * 60.0)
			ball.spin_z *= pow(0.98, delta * 60.0)
	var owner := _owner_player()
	if owner != null and owner.is_moving and not ball.is_super_shot and not ball_frames.is_empty():
		ball.animation_timer += delta
		if ball.animation_timer >= 0.15:
			ball.current_frame = (ball.current_frame + 1) % ball_frames.size()
			ball.animation_timer = 0.0

func _update_team(team: Array[PlayerState], opponents: Array[PlayerState], team_idx: int, is_user_team: bool, delta: float) -> void:
	var team_possessing := ball.owner_team == team_idx
	var user_idx := -1
	if is_user_team:
		var min_dist := INF
		for i in team.size():
			if team[i].role == PlayerRole.GOALKEEPER and not (ball.owner_team == team_idx and ball.owner_index == i):
				continue
			var d := Vector2(team[i].x - ball.x, team[i].y - ball.y).length()
			if d < min_dist:
				min_dist = d
				user_idx = i
	var chasers: Array[int] = []
	if not team_possessing:
		var distances := []
		for i in team.size():
			if team[i].role != PlayerRole.GOALKEEPER:
				distances.append({"index": i, "dist": Vector2(team[i].x - ball.x, team[i].y - ball.y).length()})
		distances.sort_custom(func(a, b): return a["dist"] < b["dist"])
		for j in mini(2, distances.size()):
			chasers.append(distances[j]["index"])
	for i in team.size():
		var p := team[i]
		p.is_moving = false
		if kickoff_timer <= 0.0 and i == user_idx:
			_update_user_player(p, team_idx, i, delta)
		elif kickoff_timer <= 0.0:
			p.is_targeting_ball = chasers.has(i)
			_update_ai_player(p, team, opponents, delta)
			if ball.owner_team == team_idx and ball.owner_index == i:
				_update_ai_owner(p, team, opponents, team_idx, delta)
		_try_capture_ball(team, team_idx, i, opponents)

func _update_user_player(p: PlayerState, team_idx: int, player_idx: int, delta: float) -> void:
	var speed_mult := 0.3 if p.stun_timer > 0.0 else 1.0
	if p.kick_power > 0.0:
		speed_mult *= 0.8
	if axis != Vector2.ZERO:
		p.x += axis.x * p.speed * speed_mult * delta
		p.y += axis.y * p.speed * speed_mult * delta
		_clamp_player(p)
		if axis.x != 0.0:
			p.facing_x = axis.x
		if axis.y != 0.0:
			p.facing_y = axis.y
		p.is_moving = true
		p.anim_timer += delta * 10.0
	if p.stun_timer > 0.0:
		p.stun_timer -= delta
	if ball.owner_team == team_idx and ball.owner_index == player_idx:
		ball.charging_power = p.kick_power
		if shoot_pressed:
			p.kick_power = minf(1.0, p.kick_power + delta * 2.0)
		elif shoot_was_pressed:
			_kick_from_player(p, aim_world, p.kick_power, true)
	else:
		p.kick_power = 0.0
		ball.charging_power = 0.0

func _kick_from_player(p: PlayerState, target: Vector2, power: float, user_shot: bool) -> void:
	var dir := Vector2(target.x - p.x, target.y - p.y)
	if dir.length() > 0.001:
		dir = dir.normalized()
		p.facing_x = dir.x
		p.facing_y = dir.y
		var final_power := (0.012 + power * 0.023) * 30.0
		ball.vx = dir.x * final_power
		ball.vy = dir.y * final_power
		var target_goal_x := FIELD_BOUNDARY_X if p.side == -1 else -FIELD_BOUNDARY_X
		var dist_to_goal := Vector2(p.x - target_goal_x, p.y).length()
		ball.is_super_shot = user_shot and power > 0.5 and dist_to_goal < 0.6
		var spin_strength := power * 2.0
		ball.spin_z = spin_strength * 0.5
		ball.spin_x = randf_range(-0.5, 0.5) * spin_strength * 0.3
		ball.spin_y = randf_range(-0.5, 0.5) * spin_strength * 0.3
	_clear_owner()
	ball.x += ball.vx * 0.033
	ball.y += ball.vy * 0.033
	ball.charging_power = 0.0
	p.kick_power = 0.0
	p.stun_timer = 0.3
	_on_kick(ball.is_super_shot)

func _update_ai_player(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], delta: float) -> void:
	if p.stun_timer > 0.0:
		p.stun_timer -= delta
	var current_speed := p.speed * (0.3 if p.stun_timer > 0.0 else 1.0)
	var owner := _owner_player()
	if p.role == PlayerRole.GOALKEEPER:
		var area_limit_x := FIELD_BOUNDARY_X - PENALTY_AREA_WIDTH
		var in_area := false
		if p.side == -1:
			in_area = ball.x < -area_limit_x and absf(ball.y) < PENALTY_AREA_HEIGHT
		else:
			in_area = ball.x > area_limit_x and absf(ball.y) < PENALTY_AREA_HEIGHT
		var target := Vector2.ZERO
		if in_area:
			target = Vector2(ball.x, clampf(ball.y, -PENALTY_AREA_HEIGHT, PENALTY_AREA_HEIGHT))
			target.x = clampf(target.x, -FIELD_BOUNDARY_X, -area_limit_x) if p.side == -1 else clampf(target.x, area_limit_x, FIELD_BOUNDARY_X)
		else:
			target = Vector2(-FIELD_BOUNDARY_X if p.side == -1 else FIELD_BOUNDARY_X, clampf(ball.y, -GOAL_HALF_WIDTH, GOAL_HALF_WIDTH))
		_move_towards(p, target, current_speed, delta)
		return
	if owner != null and owner.role == PlayerRole.GOALKEEPER and owner.side != p.side:
		var away_x := (-FIELD_BOUNDARY_X + PENALTY_AREA_WIDTH + 0.2) if p.side == 1 else (FIELD_BOUNDARY_X - PENALTY_AREA_WIDTH - 0.2)
		var too_close := p.x < away_x if p.side == 1 else p.x > away_x
		if too_close:
			_move_towards(p, Vector2(away_x, p.y), current_speed * 0.5, delta)
			return
	var team_possessing := owner != null and owner.side == p.side
	if team_possessing:
		if owner == p:
			return
		var attack_dir := float(-p.side)
		var base_adv := 0.3 if p.role == PlayerRole.DEFENDER else (0.55 if p.role == PlayerRole.MIDFIELDER else 0.8)
		var target := Vector2((p.start_x + attack_dir * base_adv) * 0.5 + (ball.x + attack_dir * 0.15) * 0.5, p.start_y * 0.7 + ball.y * 0.3)
		for mate in team:
			if mate == p:
				continue
			var sep := Vector2(p.x - mate.x, p.y - mate.y)
			var d := sep.length()
			if d < 0.15 and d > 0.0001:
				target += sep / d * (0.15 - d) * 2.5
		for opp in opponents:
			var away := Vector2(p.x - opp.x, p.y - opp.y)
			var od := away.length()
			if od < 0.12 and od > 0.0001:
				target += away / od * 0.08
		target.x = minf(FIELD_BOUNDARY_X - 0.05, target.x) if attack_dir > 0 else maxf(-FIELD_BOUNDARY_X + 0.05, target.x)
		target.y = clampf(target.y, -FIELD_BOUNDARY_Y + 0.05, FIELD_BOUNDARY_Y - 0.05)
		_move_towards(p, target, current_speed * 0.95, delta)
	elif p.is_targeting_ball:
		_move_towards(p, Vector2(ball.x, ball.y), current_speed, delta)
	else:
		var mark := Vector2(p.start_x + (ball.x - p.start_x) * 0.15, p.start_y + (ball.y - p.start_y) * 0.25)
		for mate in team:
			if mate != p and Vector2(p.x - mate.x, p.y - mate.y).length_squared() < 0.0064:
				mark.y += 0.04 if p.y > mate.y else -0.04
		_move_towards(p, mark, current_speed * 0.75, delta)

func _update_ai_owner(p: PlayerState, team: Array[PlayerState], opponents: Array[PlayerState], _team_idx: int, delta: float) -> void:
	var target_goal_x := FIELD_BOUNDARY_X if p.side == -1 else -FIELD_BOUNDARY_X
	var best_target: PlayerState = null
	var best_score := -1.0
	for mate in team:
		if mate == p or mate.role == PlayerRole.GOALKEEPER:
			continue
		var mate_dist := Vector2(mate.x - p.x, mate.y - p.y).length()
		var role_bonus := 5.0 if mate.role == PlayerRole.ATTACKER else (2.0 if mate.role == PlayerRole.MIDFIELDER else -1.0)
		var mate_goal_dist := Vector2(target_goal_x - mate.x, -mate.y).length()
		var player_goal_dist := Vector2(target_goal_x - p.x, -p.y).length()
		if mate_goal_dist >= player_goal_dist:
			continue
		var open := true
		for opp in opponents:
			if Vector2(opp.x - mate.x, opp.y - mate.y).length() < 0.2:
				open = false
		if open:
			var candidate_score := 1.0 / (1.0 + mate_dist) + role_bonus
			if candidate_score > best_score:
				best_score = candidate_score
				best_target = mate
	var dist_to_goal := Vector2(target_goal_x - p.x, -p.y).length()
	if best_target != null and randi() % 100 < 3:
		var pass_dir := Vector2(best_target.x - p.x, best_target.y - p.y).normalized()
		p.facing_x = pass_dir.x
		p.facing_y = pass_dir.y
		ball.vx = pass_dir.x * 0.72
		ball.vy = pass_dir.y * 0.72
		_clear_owner()
		p.stun_timer = 0.8
		_on_kick(false)
	elif dist_to_goal < 0.4 and randi() % 100 < 5:
		var shot_dir := Vector2(target_goal_x - p.x, -p.y).normalized()
		p.facing_x = shot_dir.x
		p.facing_y = shot_dir.y
		var final_power := 0.9 + randf() * 0.6
		ball.vx = shot_dir.x * final_power
		ball.vy = shot_dir.y * final_power
		_clear_owner()
		ball.x += ball.vx * 0.033
		ball.y += ball.vy * 0.033
		p.stun_timer = 1.0
		ball.is_super_shot = true
		_on_kick(true)
	else:
		var dribble := Vector2(target_goal_x - p.x, -p.y * 0.3)
		if dribble.length() > 0.001:
			dribble = dribble.normalized()
			p.x += dribble.x * p.speed * 0.8 * delta
			p.y += dribble.y * p.speed * 0.8 * delta
			_clamp_player(p)
			p.facing_x = dribble.x
			p.facing_y = dribble.y
			p.is_moving = true
			p.anim_timer += delta * 10.0

func _try_capture_ball(team: Array[PlayerState], team_idx: int, player_idx: int, _opponents: Array[PlayerState]) -> void:
	var p := team[player_idx]
	if Vector2(p.x - ball.x, p.y - ball.y).length() < 0.04:
		if ball.owner_team == -1 and p.stun_timer <= 0.0:
			_set_owner(team_idx, player_idx)
		elif ball.owner_team != -1 and _owner_side() != p.side and p.stun_timer <= 0.0:
			var old_owner := _owner_player()
			if old_owner != null and old_owner.role != PlayerRole.GOALKEEPER:
				old_owner.stun_timer = 0.5
				old_owner.kick_power = 0.0
				_set_owner(team_idx, player_idx)

func _move_towards(p: PlayerState, target: Vector2, current_speed: float, delta: float) -> void:
	var diff := target - Vector2(p.x, p.y)
	var mag := diff.length()
	if mag > 0.005:
		var dir := diff / mag
		p.x += dir.x * current_speed * delta
		p.y += dir.y * current_speed * delta
		if absf(diff.x) > 0.001:
			p.facing_x = dir.x
		if absf(diff.y) > 0.001:
			p.facing_y = dir.y
		p.is_moving = true
		p.anim_timer += delta * 10.0
	_clamp_player(p)

func _clamp_player(p: PlayerState) -> void:
	var half := 0.026 if p.role == PlayerRole.GOALKEEPER else 0.02
	if p.role == PlayerRole.GOALKEEPER:
		var area_limit_x := FIELD_BOUNDARY_X - PENALTY_AREA_WIDTH
		if p.side == -1:
			p.x = clampf(p.x, -FIELD_BOUNDARY_X + half, -area_limit_x + half)
		else:
			p.x = clampf(p.x, area_limit_x - half, FIELD_BOUNDARY_X - half)
		p.y = clampf(p.y, -PENALTY_AREA_HEIGHT + half, PENALTY_AREA_HEIGHT - half)
	else:
		p.x = clampf(p.x, -FIELD_BOUNDARY_X + half, FIELD_BOUNDARY_X - half)
		p.y = clampf(p.y, -FIELD_BOUNDARY_Y + half, FIELD_BOUNDARY_Y - half)

func _emit_particles(pos: Vector2, vel: Vector2, count: int, lifetime: float, size: float, color: Color) -> void:
	for i in count:
		var angle := float(i) / maxf(1.0, float(count)) * TAU
		var spread := 0.3
		var ppos := pos + (vel + Vector2(cos(angle), sin(angle)) * spread) * 0.1
		var pvel := vel * 0.5 + Vector2(cos(angle), sin(angle)) * spread
		particles.append(Particle.new(ppos, pvel, lifetime, size, color))

func _update_particles(delta: float) -> void:
	for p in particles:
		p.vel.y -= delta * 0.5
		p.pos += p.vel * delta
		p.vel *= pow(0.95, delta * 60.0)
		p.life = maxf(0.0, p.life - delta)
	particles = particles.filter(func(p): return p.life > 0.0)

func _on_kick(special: bool) -> void:
	_play_sfx(kick_stream, 1.0)
	if special:
		if randi() % 2 == 0:
			_emit_particles(Vector2(ball.x, ball.y), Vector2(ball.vx, ball.vy) * 0.15, 25, 0.8, 5.0, Color(1.0, 0.5, 0.0))
			_emit_particles(Vector2(ball.x, ball.y), Vector2(ball.vx, ball.vy) * 0.15, 15, 0.6, 4.0, Color(1.0, 0.8, 0.0))
		else:
			_emit_particles(Vector2(ball.x, ball.y), Vector2(ball.vx, ball.vy) * 0.15, 25, 0.8, 5.0, Color(0.3, 0.8, 1.0))
			_emit_particles(Vector2(ball.x, ball.y), Vector2(ball.vx, ball.vy) * 0.15, 15, 0.6, 4.0, Color(0.7, 0.9, 1.0))
	else:
		_emit_particles(Vector2(ball.x, ball.y), Vector2(ball.vx, ball.vy) * 0.15, 15, 0.5, 4.0, Color(0.8, 0.7, 0.5))

func _draw_stadium() -> void:
	var rect := get_viewport_rect()
	draw_rect(rect, Color(0.05, 0.07, 0.06))
	var field_rect := _field_screen_rect()
	var top_stand := Rect2(0, 0, rect.size.x, maxf(0.0, field_rect.position.y - 8.0))
	var bottom_stand := Rect2(0, field_rect.end.y + 8.0, rect.size.x, maxf(0.0, rect.size.y - field_rect.end.y - 8.0))
	var left_stand := Rect2(0, field_rect.position.y, maxf(0.0, field_rect.position.x - 8.0), field_rect.size.y)
	var right_stand := Rect2(field_rect.end.x + 8.0, field_rect.position.y, maxf(0.0, rect.size.x - field_rect.end.x - 8.0), field_rect.size.y)
	_draw_crowd_stand(top_stand, 0)
	_draw_crowd_stand(bottom_stand, 3)
	_draw_crowd_stand(left_stand, 6)
	_draw_crowd_stand(right_stand, 9)

func _draw_crowd_stand(rect: Rect2, offset: int) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var textures := fans_red if offset % 2 == 0 else fans_blue
	var color := Color(0.35, 0.08, 0.08) if offset % 2 == 0 else Color(0.08, 0.12, 0.38)
	draw_rect(rect, color)
	if textures.is_empty():
		return
	var tex := textures[int(crowd_clock * 3.0 + offset) % textures.size()]
	if tex == null:
		return
	var sprite_size := minf(44.0, maxf(24.0, rect.size.y * 0.42))
	var step_x := sprite_size + 28.0
	var step_y := sprite_size + 20.0
	var jump := sin(crowd_clock * 20.0 + offset) * 5.0 if celebration_timer > 0.0 else sin(crowd_clock * 2.0 + offset) * 1.5
	var y_pos := rect.position.y + 8.0
	var row := 0
	while y_pos + sprite_size <= rect.end.y - 4.0:
		var x_pos := rect.position.x + 8.0 + (step_x * 0.5 if row % 2 == 1 else 0.0)
		while x_pos + sprite_size <= rect.end.x - 4.0:
			draw_texture_rect(tex, Rect2(Vector2(x_pos, y_pos + jump), Vector2(sprite_size, sprite_size)), false)
			x_pos += step_x
		y_pos += step_y
		row += 1

func _draw_field() -> void:
	var field_rect := _field_screen_rect()
	draw_rect(field_rect, Color(0.08, 0.42, 0.14))
	for i in 10:
		if i % 2 == 0:
			var stripe := Rect2(field_rect.position.x + field_rect.size.x * i / 10.0, field_rect.position.y, field_rect.size.x / 10.0, field_rect.size.y)
			draw_rect(stripe, Color(0.10, 0.48, 0.17))
	var line_color := Color(0.92, 0.95, 0.9)
	draw_rect(field_rect, line_color, false, 3.0)
	_draw_world_line(Vector2(0.0, -FIELD_HALF_HEIGHT), Vector2(0.0, FIELD_HALF_HEIGHT), line_color, 2.0)
	draw_arc(_world_to_screen(Vector2.ZERO), 0.16 * _scale(), 0.0, TAU, 96, line_color, 2.0)
	_draw_box(-1, line_color)
	_draw_box(1, line_color)
	_draw_goal(-1)
	_draw_goal(1)

func _draw_box(side: int, color: Color) -> void:
	var x0 := -FIELD_BOUNDARY_X if side == -1 else FIELD_BOUNDARY_X - PENALTY_AREA_WIDTH
	var x1 := -FIELD_BOUNDARY_X + PENALTY_AREA_WIDTH if side == -1 else FIELD_BOUNDARY_X
	var a := _world_to_screen(Vector2(x0, PENALTY_AREA_HEIGHT))
	var b := _world_to_screen(Vector2(x1, -PENALTY_AREA_HEIGHT))
	draw_rect(Rect2(a, b - a).abs(), color, false, 2.0)

func _draw_goal(side: int) -> void:
	var x := -FIELD_BOUNDARY_X - GOAL_DEPTH if side == -1 else FIELD_BOUNDARY_X
	var a := _world_to_screen(Vector2(x, GOAL_HALF_WIDTH))
	var b := _world_to_screen(Vector2(x + GOAL_DEPTH, -GOAL_HALF_WIDTH)) if side == -1 else _world_to_screen(Vector2(x + GOAL_DEPTH, -GOAL_HALF_WIDTH))
	draw_rect(Rect2(a, b - a).abs(), Color(0.7, 0.7, 0.72, 0.55), false, 2.0)

func _draw_player(p: PlayerState) -> void:
	var pos := _world_to_screen(Vector2(p.x, p.y))
	var height := 42.0 if p.role == PlayerRole.GOALKEEPER else 36.0
	var width := height * 0.65
	_draw_shadow_ellipse(pos + Vector2(0, height * 0.42), Vector2(width * 0.55, 5.0), Color(0, 0, 0, 0.35))
	var tex := _player_texture(p)
	if tex != null:
		draw_texture_rect(tex, Rect2(pos - Vector2(width, height) * 0.5, Vector2(width, height)), false)
	else:
		var color := Color.RED if p.side == -1 else Color.BLUE
		draw_circle(pos, 7.0 if p.role == PlayerRole.GOALKEEPER else 6.0, color)
	if p.kick_power > 0.01:
		var bar := Rect2(pos + Vector2(-24, -36), Vector2(48, 6))
		draw_rect(bar, Color.BLACK)
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * p.kick_power, bar.size.y)), Color(p.kick_power, 1.0 - p.kick_power, 0.0))

func _player_texture(p: PlayerState) -> Texture2D:
	if p.is_moving:
		var frames := p.run_frames_right if p.facing_x >= 0.0 else p.run_frames_left
		if not frames.is_empty():
			return frames[int(p.anim_timer) % frames.size()]
	if absf(p.facing_x) > absf(p.facing_y):
		return p.tex_right if p.facing_x > 0.0 else p.tex_left
	return p.tex_back if p.facing_y > 0.0 else p.tex_face

func _draw_ball() -> void:
	var tex: Texture2D = null
	if ball.is_super_shot and ball_super != null:
		tex = ball_super
	elif not ball_frames.is_empty():
		tex = ball_frames[ball.current_frame % ball_frames.size()]
	var pos := _world_to_screen(Vector2(ball.x, ball.y))
	if tex != null:
		draw_set_transform(pos, ball.rotation, Vector2.ONE)
		draw_texture_rect(tex, Rect2(Vector2(-9, -9), Vector2(18, 18)), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	else:
		draw_circle(pos, 8.0, Color.YELLOW)

func _draw_ball_effects() -> void:
	var speed := Vector2(ball.vx, ball.vy).length()
	if speed > 0.001:
		for i in ball.trail.size():
			var alpha := float(i) / maxf(1.0, float(ball.trail.size())) * 0.5
			draw_circle(_world_to_screen(ball.trail[i]), 6.0 - float(i) / maxf(1.0, float(ball.trail.size())) * 4.0, Color(1, 1, 1, alpha))
	var power := ball.charging_power
	if power <= 0.0:
		return
	var pos := _world_to_screen(Vector2(ball.x, ball.y))
	var color := Color(0.0, 0.7, 1.0, 0.8)
	if power > 0.8:
		color = Color(1.0, 0.9, 0.3, 0.9)
	elif power > 0.5:
		color = Color(1.0, 0.6, 0.0, 0.9)
	for ring in 3:
		var radius := (0.025 + power * 0.015) * _scale() * (0.6 + ring * 0.3)
		var angle_base := crowd_clock * (1.5 + ring * 0.8) + ring * 2.0
		for i in 4 + ring * 2:
			var angle := angle_base + float(i) / float(4 + ring * 2) * TAU
			draw_circle(pos + Vector2(cos(angle), sin(angle)) * radius, 3.0 + power * 2.0 - ring * 0.6, color)

func _draw_particles() -> void:
	for p in particles:
		var alpha := p.life / p.max_life
		var c := p.color
		c.a = alpha
		draw_circle(_world_to_screen(p.pos), p.size, c)

func _draw_shadow_ellipse(center: Vector2, radius: Vector2, color: Color) -> void:
	var points := PackedVector2Array()
	for i in 33:
		var a := float(i) / 32.0 * TAU
		points.append(center + Vector2(cos(a) * radius.x, sin(a) * radius.y))
	draw_colored_polygon(points, color)

func _draw_world_line(a: Vector2, b: Vector2, color: Color, width: float) -> void:
	draw_line(_world_to_screen(a), _world_to_screen(b), color, width)

func _world_to_screen(p: Vector2) -> Vector2:
	var rect := get_viewport_rect()
	return rect.size * 0.5 + Vector2(p.x * _scale(), -p.y * _scale())

func _field_screen_rect() -> Rect2:
	var top_left := _world_to_screen(Vector2(-FIELD_HALF_WIDTH, FIELD_HALF_HEIGHT))
	var bottom_right := _world_to_screen(Vector2(FIELD_HALF_WIDTH, -FIELD_HALF_HEIGHT))
	return Rect2(top_left, bottom_right - top_left).abs()

func _screen_to_world(p: Vector2) -> Vector2:
	var rect := get_viewport_rect()
	var centered := p - rect.size * 0.5
	return Vector2(centered.x / _scale(), -centered.y / _scale())

func _scale() -> float:
	var size := get_viewport_rect().size
	return minf(BASE_SCALE, minf(size.x / 2.4, size.y / 2.05))

func _update_ui() -> void:
	score_label.text = "%d - %d" % [score_left, score_right]
	timer_label.text = "Kickoff %.1f" % kickoff_timer if kickoff_timer > 0.0 else ""
