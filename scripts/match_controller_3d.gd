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
var input_reader: InputReader
var hud: MatchHud
var audio: AudioManager
var settings: SettingsStore
var menu: MenuManager
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

# Menu / audio nodes

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
	_create_teams()
	_create_ball()
	_create_ball_trail()
	audio = AudioManager.new()
	add_child(audio)
	audio._build_audio()
	settings.audio = audio
	settings._load_settings()
	menu = MenuManager.new()
	add_child(menu)
	menu.controller = self
	menu.settings = settings
	menu._build_menus()
	_reset_game(1)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_set_game_state(GameConfig.GameState.MENU)
	print("Inazuma Eleven 3D environment ready")

func _process(delta: float) -> void:
	if game_state == GameConfig.GameState.PLAYING:
		if halftime_pause > 0.0:
			halftime_pause = maxf(0.0, halftime_pause - delta)
		else:
			input_reader.read(inputs, num_players, kickoff_timer)
			_update_kickoff(delta)
			var scorer := _update_ball(delta)
			if scorer != 0:
				_trigger_goal(scorer)
			_update_team(team_red, team_blue, 0, true, delta)
			_update_team(team_blue, team_red, 1, num_players == 2, delta)
			_update_match_clock(delta)
		_update_visuals(delta)
	_update_confetti(delta)
	hud.update(score_left, score_right, game_state, kickoff_timer, settings.half_length, match_time, current_half)

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
	if next == GameConfig.GameState.MENU:
		menu._refresh_two_player_availability()
	menu.show_for_state(next)

func _start_match() -> void:
	score_left = 0
	score_right = 0
	match_time = 0.0
	current_half = 1
	halftime_pause = 0.0
	_set_default_ends()
	_reset_game(1)
	_set_game_state(GameConfig.GameState.PLAYING)
	audio._play_whistle()

func _update_match_clock(delta: float) -> void:
	match_time += delta
	if match_time >= settings.half_length:
		if current_half == 1:
			current_half = 2
			match_time = 0.0
			halftime_pause = 2.0
			_switch_ends()
			_reset_game(1)
			audio._play_whistle()
		else:
			_end_match()

func _end_match() -> void:
	audio._play_whistle()
	var result := "DRAW"
	if score_left > score_right:
		result = "RED WINS"
	elif score_right > score_left:
		result = "BLUE WINS"
	menu.set_fulltime_text("FULL TIME\n%d - %d\n%s" % [score_left, score_right, result])
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
	var current_speed := p.speed * settings.ai_speed_mult * (0.3 if p.stun_timer > 0.0 else 1.0)
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
	if dist_to_goal < 0.40 and randf() < 2.4 * settings.ai_decision_mult * delta:
		_kick_from_player(p, Vector2(target_goal_x, 0.0), 0.75, false)
		ball.is_super_shot = true
		return
	if randf() < 1.8 * settings.ai_decision_mult * delta:
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
	audio._play_kick()
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

func _trigger_goal(_scorer: int) -> void:
	celebration_timer = 1.5
	_spawn_confetti()
	audio._play_whistle()

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
