class_name MatchView
extends Node

## Mirrors the MatchSimulation state onto the 3D scene every frame: player
## transforms/animations, ball position/spin/trail, the broadcast camera and the
## goal celebration confetti. Reads from `sim`; never mutates gameplay state.

# Smoothed per-frame speed (field units) a keeper must exceed to read as strafing rather
# than holding position; below it the keeper plays the idle stance.
const GK_STRAFE_MIN_VEL := 0.0012

var sim: MatchSimulation
var material_factory: MaterialFactory
var audio: AudioManager
var ball_root: Node3D
var vfx_root: Node3D
var camera_rig: Node3D
var camera_3d: Camera3D

var ball_trail: Array[MeshInstance3D] = []
var ball_trail_points: Array[Vector3] = []
var celebration_timer := 0.0
var camera_look := Vector3.ZERO

# Goal confetti: three pre-built MultiMeshes (gold/red/blue), one draw call each,
# so a goal never allocates nodes. Dead pieces are hidden with a zero-scale basis.
const CONFETTI_PER_COLOR := 48
var confetti_mms: Array[MultiMesh] = []
var confetti_vel: Array = []      # per pool: PackedVector3Array
var confetti_life: Array = []     # per pool: PackedFloat32Array
var confetti_cursor: Array[int] = []

# Ball grass-trail: a ring buffer of Decal nodes pressed into the turf along the
# ball's ground path, each fading over MARK_LIFETIME seconds.
const MARK_LIFETIME := 7.0
const MARK_SPACING := 0.3   # world units the ball must travel before a new mark
var grass_marks: Array[Decal] = []
var grass_mark_life: PackedFloat32Array = []
var grass_mark_index := 0
var last_mark_pos := Vector2(1.0e9, 1.0e9)

## Clears the ball trail (called by the simulation on kickoff / goal reset).
func reset_trail() -> void:
	ball_trail_points.clear()
	for trail in ball_trail:
		trail.visible = false
	# Drop the spacing anchor so the ball's teleport on reset can't smear a streak;
	# existing grass marks keep fading naturally.
	last_mark_pos = Vector2(1.0e9, 1.0e9)

## Immediately hides any live confetti particles (called on match start so
## leftover pieces from the previous match don't bleed into the new one).
func clear_confetti() -> void:
	for pool in confetti_mms.size():
		for slot in CONFETTI_PER_COLOR:
			confetti_life[pool][slot] = 0.0
			confetti_mms[pool].set_instance_transform(slot, _hidden_xform())

func _hidden_xform() -> Transform3D:
	return Transform3D(Basis().scaled(Vector3.ZERO), Vector3(0.0, -10.0, 0.0))

## Builds the confetti MultiMesh pools once at startup.
func create_confetti() -> void:
	var mats: Array = [material_factory.materials.confetti_gold,
			material_factory.materials.confetti_red,
			material_factory.materials.confetti_blue]
	for mat in mats:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		var piece := BoxMesh.new()
		piece.size = Vector3(0.10, 0.035, 0.16)
		mm.mesh = piece
		mm.instance_count = CONFETTI_PER_COLOR
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "ConfettiPool"
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		vfx_root.add_child(mmi)
		confetti_mms.append(mm)
		confetti_vel.append(PackedVector3Array())
		confetti_vel[-1].resize(CONFETTI_PER_COLOR)
		confetti_life.append(PackedFloat32Array())
		confetti_life[-1].resize(CONFETTI_PER_COLOR)
		confetti_cursor.append(0)
	clear_confetti()

func create_ball() -> void:
	var root := Node3D.new()
	root.name = "Ball3D"
	if not _add_ball_glb(root):
		_add_fallback_ball(root)
	var glow := OmniLight3D.new()
	glow.name = "SpecialShotLight"
	glow.light_color = Color(1.0, 0.75, 0.18)
	glow.light_energy = 0.0
	glow.omni_range = 5.0
	root.add_child(glow)
	# Elemental aura orb, hidden until a named special shot is in flight.
	var aura := material_factory.make_mesh("SpecialAura", SphereMesh.new(), material_factory.materials.special_aura, Vector3.ZERO)
	(aura.mesh as SphereMesh).radius = GameConfig.BALL_RADIUS * 2.2
	(aura.mesh as SphereMesh).height = GameConfig.BALL_RADIUS * 4.4
	aura.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	aura.visible = false
	root.add_child(aura)
	sim.ball.node = root
	sim.ball.light = glow
	sim.ball.aura = aura
	ball_root.add_child(root)

## Loads the Trionda GLB, scales it to the match ball size and centres it on the
## spinning root. Returns false (so the caller falls back) if the model is missing.
func _add_ball_glb(root: Node3D) -> bool:
	var packed := ResourceLoader.load(GameConfig.BALL_GLB, "PackedScene") as PackedScene
	if packed == null:
		return false
	var inst := packed.instantiate() as Node3D
	if inst == null:
		return false
	inst.name = "BallMesh"
	var aabb := material_factory.subtree_local_aabb(inst)
	var largest := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	if largest > 0.0001:
		inst.scale = Vector3.ONE * (GameConfig.BALL_RADIUS * 2.0 / largest)
	# Re-centre so the model's bounds sit on the root origin (clean spin).
	inst.position = -(aabb.position + aabb.size * 0.5) * inst.scale.x
	root.add_child(inst)
	return true

func _add_fallback_ball(root: Node3D) -> void:
	var mesh := material_factory.make_mesh("BallMesh", SphereMesh.new(), material_factory.materials.ball, Vector3.ZERO)
	mesh.mesh.radius = GameConfig.BALL_RADIUS
	mesh.mesh.height = GameConfig.BALL_RADIUS * 2.0
	mesh.mesh.radial_segments = 32
	mesh.mesh.rings = 16
	root.add_child(mesh)

func create_ball_trail() -> void:
	for i in 10:
		var trail := material_factory.make_mesh("BallTrail%d" % i, SphereMesh.new(), material_factory.materials.trail, Vector3.ZERO)
		trail.mesh.radius = 0.12 - float(i) * 0.007
		trail.mesh.height = trail.mesh.radius * 2.0
		trail.visible = false
		vfx_root.add_child(trail)
		ball_trail.append(trail)

## Pool of decals that mark the grass where the ball rolls. Built once; all hidden
## until the ball moves over them. Shared albedo/normal textures (one each).
func create_grass_marks() -> void:
	var albedo := material_factory.decal_albedo_texture()
	var normal := material_factory.decal_normal_texture()
	for i in 48:
		var mark := Decal.new()
		mark.name = "GrassMark%d" % i
		mark.texture_albedo = albedo
		mark.texture_normal = normal
		mark.size = Vector3(1.45, 0.8, 1.45)   # x/z footprint, y = downward projection depth
		mark.albedo_mix = 1.0
		mark.upper_fade = 0.3
		mark.lower_fade = 0.3
		mark.modulate = Color(1.0, 1.0, 1.0, 0.0)
		mark.visible = false
		vfx_root.add_child(mark)
		grass_marks.append(mark)
		grass_mark_life.append(0.0)

func update_visuals(delta: float) -> void:
	for t in 2:
		var players := sim.teams[t].players
		for i in players.size():
			_update_player_visual(players[i], i, sim.ball.owner_team == t and sim.ball.owner_index == i, delta)
	_update_ball_visual(delta)
	_update_camera(delta)
	if celebration_timer > 0.0:
		celebration_timer = maxf(0.0, celebration_timer - delta)

func _update_player_visual(p: PlayerState, player_index: int, owns_ball: bool, delta: float) -> void:
	if p.node == null:
		return
	if p.uses_glb:
		_update_glb_player_visual(p, player_index, owns_ball, delta)
		return
	p.node.position = GameConfig.to_3d(Vector2(p.x, p.y), 0.0)
	var face := _facing_vector(p)
	if face.length() > 0.001:
		p.node.rotation.y = atan2(face.x, face.z)
	var swing := sin(Time.get_ticks_msec() * 0.012) * (0.55 if p.is_moving else 0.08)
	(p.node.get_node("ArmL") as Node3D).rotation.x = swing
	(p.node.get_node("ArmR") as Node3D).rotation.x = -swing
	(p.node.get_node("LegL") as Node3D).rotation.x = -swing
	(p.node.get_node("LegR") as Node3D).rotation.x = swing
	var t := p.team_index
	var is_selected := sim.team_is_human(t) and player_index == sim.teams[t].selected_index
	var is_candidate := sim.team_is_human(t) and player_index == sim.teams[t].switch_candidate
	(p.node.get_node("SelectedRing") as Node3D).visible = is_selected
	(p.node.get_node("NextRing") as Node3D).visible = is_candidate and not is_selected and not owns_ball
	var power_ring := p.node.get_node("PowerRing") as Node3D
	power_ring.visible = p.kick_power > 0.01
	power_ring.scale = Vector3.ONE * (0.55 + p.kick_power * 0.55)
	if p.is_moving:
		p.node.position.y = absf(sin(Time.get_ticks_msec() * 0.018)) * 0.05
	else:
		p.node.position.y = 0.0

func _update_glb_player_visual(p: PlayerState, player_index: int, owns_ball: bool, delta: float) -> void:
	p.node.position = GameConfig.to_3d(Vector2(p.x, p.y), 0.0)
	var face := _facing_vector(p)
	if face.length() > 0.001:
		p.node.rotation.y = atan2(face.x, face.z)
	if p.action_timer > 0.0:
		p.action_timer = maxf(0.0, p.action_timer - delta)
	else:
		if p.role == GameConfig.PlayerRole.GOALKEEPER:
			p.set_visual_state(_gk_move_state(p))
		else:
			p.set_visual_state("run" if p.is_moving else "idle")
	p.prev_x = p.x
	p.prev_y = p.y
	var t := p.team_index
	var is_selected := sim.team_is_human(t) and player_index == sim.teams[t].selected_index
	var is_candidate := sim.team_is_human(t) and player_index == sim.teams[t].switch_candidate
	(p.node.get_node("SelectedRing") as Node3D).visible = is_selected
	(p.node.get_node("NextRing") as Node3D).visible = is_candidate and not is_selected and not owns_ball
	var power_ring := p.node.get_node("PowerRing") as Node3D
	power_ring.visible = p.kick_power > 0.01
	power_ring.scale = Vector3.ONE * (0.55 + p.kick_power * 0.55)

# Picks the forward-facing sideways shuffle clip for a moving keeper. The keeper always
# faces the ball, so the shuffle is purely lateral: the sign of (facing × movement) tells
# us whether it is stepping to its own left or right along the goal line.
func _gk_move_state(p: PlayerState) -> String:
	# Keepers micro-adjust toward their target every frame, so `is_moving` is almost always
	# true. Drive the shuffle off the actual per-frame displacement instead: below a small
	# threshold they stand still (gk_idle), above it they strafe in the stepped direction.
	var move := Vector2(p.x - p.prev_x, p.y - p.prev_y)
	p.gk_vel_x = lerp(p.gk_vel_x, move.x, 0.25)
	p.gk_vel_y = lerp(p.gk_vel_y, move.y, 0.25)
	var vel := Vector2(p.gk_vel_x, p.gk_vel_y)
	if vel.length() < GK_STRAFE_MIN_VEL:
		return "gk_idle"
	var facing := Vector2(sim.ball.x - p.x, sim.ball.y - p.y)
	if facing.length_squared() < 0.0001:
		return "gk_idle"
	var cross := facing.x * vel.y - facing.y * vel.x
	return "gk_left" if cross > 0.0 else "gk_right"

func _facing_vector(p: PlayerState) -> Vector3:
	# Keepers always face the ball (they shuffle sideways along their line, so using the
	# movement direction would point them along the goal instead of at the pitch).
	if not p.is_moving or p.role == GameConfig.PlayerRole.GOALKEEPER:
		var to_ball := Vector2(sim.ball.x - p.x, sim.ball.y - p.y)
		if to_ball.length_squared() > 0.0001:
			return Vector3(to_ball.x, 0.0, -to_ball.y).normalized()
	return Vector3(p.facing_x, 0.0, -p.facing_y)

func _update_ball_visual(delta: float) -> void:
	if sim.ball.node == null:
		return
	var speed := Vector2(sim.ball.vx, sim.ball.vy).length()
	# The ball's simulated flight height, plus its radius so it rests on the turf.
	var visual_height := GameConfig.BALL_RADIUS + 0.06 + sim.ball.h
	sim.ball.node.position = GameConfig.to_3d(Vector2(sim.ball.x, sim.ball.y), visual_height)
	sim.ball.node.rotate_x(speed * delta * 14.0)
	sim.ball.node.rotate_z(sim.ball.spin * delta)
	_update_special_aura(speed)
	_update_ball_trail(speed)
	_update_grass_marks(speed, delta)

## Drives the ball light, elemental aura orb and trail tint. A named special shot in
## flight glows in its element colour; otherwise it falls back to the charge/super-shot
## light cue and the trail to its default gold.
func _update_special_aura(speed: float) -> void:
	var special := sim.ball.special_name != "" and speed > 0.03
	var trail_mat := material_factory.materials.trail as StandardMaterial3D
	if special:
		var col: Color = sim.ball.special_color
		var pulse := 1.0 + 0.16 * sin(Time.get_ticks_msec() * 0.02)
		sim.ball.light.light_color = col
		sim.ball.light.light_energy = 6.5 * pulse
		if sim.ball.aura != null:
			sim.ball.aura.visible = true
			sim.ball.aura.scale = Vector3.ONE * pulse
			var aura_mat := material_factory.materials.special_aura as StandardMaterial3D
			aura_mat.albedo_color = Color(col.r, col.g, col.b, 0.6)
			aura_mat.emission = col
		if trail_mat != null:
			trail_mat.albedo_color = Color(col.r, col.g, col.b, 0.5)
	else:
		if sim.ball.aura != null:
			sim.ball.aura.visible = false
		sim.ball.light.light_energy = sim.ball.charging_power * 4.0 + (2.5 if sim.ball.is_super_shot and speed > 0.05 else 0.0)
		sim.ball.light.light_color = Color(1.0, 0.82, 0.20) if sim.ball.charging_power > 0.5 or sim.ball.is_super_shot else Color(0.1, 0.7, 1.0)
		if trail_mat != null:
			trail_mat.albedo_color = Color(1.0, 0.86, 0.25, 0.36)

## Presses a fresh decal into the turf once the ball has rolled MARK_SPACING from the
## last mark, then fades every live mark toward transparent over MARK_LIFETIME.
func _update_grass_marks(speed: float, delta: float) -> void:
	if grass_marks.is_empty():
		return
	var ground := GameConfig.to_3d(Vector2(sim.ball.x, sim.ball.y), 0.3)
	var ground2 := Vector2(ground.x, ground.z)
	if speed > 0.04 and sim.ball.h < 0.25 and ground2.distance_to(last_mark_pos) > MARK_SPACING:
		last_mark_pos = ground2
		var mark := grass_marks[grass_mark_index]
		var sc := randf_range(0.85, 1.3)
		mark.position = ground
		mark.rotation = Vector3(0.0, randf() * TAU, 0.0)
		mark.size = Vector3(1.45 * sc, 0.8, 1.45 * sc)
		mark.visible = true
		grass_mark_life[grass_mark_index] = MARK_LIFETIME
		grass_mark_index = (grass_mark_index + 1) % grass_marks.size()
	for i in grass_marks.size():
		var life := grass_mark_life[i]
		if life <= 0.0:
			continue
		life -= delta
		grass_mark_life[i] = life
		if life <= 0.0:
			grass_marks[i].visible = false
		else:
			grass_marks[i].modulate.a = clampf(life / MARK_LIFETIME, 0.0, 1.0)

func _update_ball_trail(speed: float) -> void:
	if speed > 0.04:
		ball_trail_points.push_front(sim.ball.node.position)
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
	var _fs := GameConfig.FIELD_SCALE
	# Height and base distance are scaled by the player's chosen camera-angle preset.
	var zoom := sim.settings.cam_zoom_mult
	var cam_h := _fs * sim.settings.cam_height_mult * zoom
	var cam_z := _fs * (4.0 / 3.0) * sim.settings.cam_dist_mult * zoom
	var follow_z := clampf(-sim.ball.y * _fs * 0.12, -_fs * (2.5 / 18.0), _fs * (2.5 / 18.0))
	# Keep the camera behind the ball along +z so it never crosses to the far side of it.
	# If it did, look_at would swing ~180 deg and mirror the on-screen directions (mouse
	# aim + movement) -- exactly what the short-distance Top-down preset was hitting.
	var ball_z := -sim.ball.y * _fs
	var target_z := maxf(cam_z + follow_z, ball_z + _fs * 0.27)
	var target_pos := Vector3(clampf(sim.ball.x * _fs * 0.25, -_fs * (5.0 / 18.0), _fs * (5.0 / 18.0)), cam_h, target_z)
	camera_rig.position = camera_rig.position.lerp(target_pos, 1.0 - exp(-1.8 * delta))
	camera_look = camera_look.lerp(GameConfig.to_3d(Vector2(sim.ball.x, sim.ball.y), 0.2), 1.0 - exp(-3.5 * delta))
	camera_3d.look_at(camera_look, Vector3.UP)

func trigger_goal(_scorer: int) -> void:
	celebration_timer = 1.5
	_spawn_confetti()
	audio.play_whistle()

func _spawn_confetti() -> void:
	if confetti_mms.is_empty():
		return
	for i in 72:
		var pool := i % confetti_mms.size()
		var slot: int = confetti_cursor[pool]
		confetti_cursor[pool] = (slot + 1) % CONFETTI_PER_COLOR
		var origin := GameConfig.to_3d(Vector2(randf_range(-0.75, 0.75), randf_range(-0.55, 0.55)), randf_range(2.2, 4.2))
		var basis := Basis.from_euler(Vector3(randf() * TAU, randf() * TAU, 0.0))
		confetti_mms[pool].set_instance_transform(slot, Transform3D(basis, origin))
		confetti_vel[pool][slot] = Vector3(randf_range(-2.0, 2.0), randf_range(2.0, 4.4), randf_range(-2.0, 2.0))
		confetti_life[pool][slot] = randf_range(1.2, 2.3)

func update_confetti(delta: float) -> void:
	for pool in confetti_mms.size():
		var mm: MultiMesh = confetti_mms[pool]
		for slot in CONFETTI_PER_COLOR:
			var life: float = confetti_life[pool][slot]
			if life <= 0.0:
				continue
			life -= delta
			confetti_life[pool][slot] = life
			if life <= 0.0:
				mm.set_instance_transform(slot, _hidden_xform())
				continue
			var vel: Vector3 = confetti_vel[pool][slot]
			vel.y -= 4.8 * delta
			confetti_vel[pool][slot] = vel
			var xform := mm.get_instance_transform(slot)
			xform.origin += vel * delta
			xform.basis = xform.basis.rotated(Vector3.RIGHT, delta * 8.0).rotated(Vector3.UP, delta * 10.0)
			mm.set_instance_transform(slot, xform)

func set_glb_animations_paused(paused: bool) -> void:
	var speed := 0.0 if paused else 1.0
	for ts in sim.teams:
		for p in ts.players:
			if p.animation_player != null:
				p.animation_player.speed_scale = speed
