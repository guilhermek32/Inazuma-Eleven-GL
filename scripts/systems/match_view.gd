class_name MatchView
extends Node

## Mirrors the MatchSimulation state onto the 3D scene every frame: player
## transforms/animations, ball position/spin/trail, the broadcast camera and the
## goal celebration confetti. Reads from `sim`; never mutates gameplay state.

var sim: MatchSimulation
var material_factory: MaterialFactory
var audio: AudioManager
var ball_root: Node3D
var vfx_root: Node3D
var camera_rig: Node3D
var camera_3d: Camera3D
var num_players := 1

var ball_trail: Array[MeshInstance3D] = []
var ball_trail_points: Array[Vector3] = []
var confetti: Array[VfxParticle] = []
var celebration_timer := 0.0
var camera_look := Vector3.ZERO

## Clears the ball trail (called by the simulation on kickoff / goal reset).
func reset_trail() -> void:
	ball_trail_points.clear()
	for trail in ball_trail:
		trail.visible = false

func _create_ball() -> void:
	var root := Node3D.new()
	root.name = "Ball3D"
	var mesh := material_factory._mesh("BallMesh", SphereMesh.new(), material_factory.materials.ball, Vector3.ZERO)
	mesh.mesh.radius = 0.24
	mesh.mesh.height = 0.48
	root.add_child(mesh)
	var glow := OmniLight3D.new()
	glow.name = "SpecialShotLight"
	glow.light_color = Color(1.0, 0.75, 0.18)
	glow.light_energy = 0.0
	glow.omni_range = 5.0
	root.add_child(glow)
	sim.ball.node = root
	sim.ball.light = glow
	ball_root.add_child(root)

func _create_ball_trail() -> void:
	for i in 10:
		var trail := material_factory._mesh("BallTrail%d" % i, SphereMesh.new(), material_factory.materials.trail, Vector3.ZERO)
		trail.mesh.radius = 0.12 - float(i) * 0.007
		trail.mesh.height = trail.mesh.radius * 2.0
		trail.visible = false
		vfx_root.add_child(trail)
		ball_trail.append(trail)

func _update_visuals(delta: float, p_num_players: int) -> void:
	num_players = p_num_players
	for i in sim.team_red.size():
		_update_player_visual(sim.team_red[i], sim.ball.owner_team == 0 and sim.ball.owner_index == i, delta)
	for i in sim.team_blue.size():
		_update_player_visual(sim.team_blue[i], sim.ball.owner_team == 1 and sim.ball.owner_index == i, delta)
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
	var is_selected := (p.team_index == 0 and sim.team_red.find(p) == sim.selected_index[0]) or (p.team_index == 1 and num_players == 2 and sim.team_blue.find(p) == sim.selected_index[1])
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
	var is_selected := (p.team_index == 0 and sim.team_red.find(p) == sim.selected_index[0]) or (p.team_index == 1 and num_players == 2 and sim.team_blue.find(p) == sim.selected_index[1])
	(p.node.get_node("SelectedRing") as Node3D).visible = owns_ball or is_selected
	var power_ring := p.node.get_node("PowerRing") as Node3D
	power_ring.visible = p.kick_power > 0.01
	power_ring.scale = Vector3.ONE * (0.55 + p.kick_power * 0.55)

func _update_ball_visual(delta: float) -> void:
	if sim.ball.node == null:
		return
	var speed := Vector2(sim.ball.vx, sim.ball.vy).length()
	var visual_height := 0.26 + minf(0.55, speed * 0.22)
	sim.ball.node.position = GameConfig.to_3d(Vector2(sim.ball.x, sim.ball.y), visual_height)
	sim.ball.node.rotate_x(speed * delta * 14.0)
	sim.ball.node.rotate_z(sim.ball.spin * delta)
	sim.ball.light.light_energy = sim.ball.charging_power * 4.0 + (2.5 if sim.ball.is_super_shot and speed > 0.05 else 0.0)
	sim.ball.light.light_color = Color(1.0, 0.82, 0.20) if sim.ball.charging_power > 0.5 or sim.ball.is_super_shot else Color(0.1, 0.7, 1.0)
	_update_ball_trail(speed)

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
	var target_pos := Vector3(clampf(sim.ball.x * GameConfig.FIELD_SCALE * 0.25, -5.0, 5.0), 18.0, 24.0 + clampf(-sim.ball.y * GameConfig.FIELD_SCALE * 0.12, -2.5, 2.5))
	camera_rig.position = camera_rig.position.lerp(target_pos, 1.0 - exp(-1.8 * delta))
	camera_look = camera_look.lerp(GameConfig.to_3d(Vector2(sim.ball.x, sim.ball.y), 0.2), 1.0 - exp(-3.5 * delta))
	camera_3d.look_at(camera_look, Vector3.UP)

func _trigger_goal(_scorer: int) -> void:
	celebration_timer = 1.5
	_spawn_confetti()
	audio._play_whistle()

func _spawn_confetti() -> void:
	for i in 72:
		var mat: Material = material_factory.materials.confetti_gold
		if i % 3 == 0:
			mat = material_factory.materials.confetti_red
		elif i % 3 == 1:
			mat = material_factory.materials.confetti_blue
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

func _set_glb_animations_paused(paused: bool) -> void:
	var speed := 0.0 if paused else 1.0
	for p in sim.team_red:
		if p.animation_player != null:
			p.animation_player.speed_scale = speed
	for p in sim.team_blue:
		if p.animation_player != null:
			p.animation_player.speed_scale = speed
