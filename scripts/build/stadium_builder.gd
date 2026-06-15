class_name StadiumBuilder
extends RefCounted

## Builds the night environment, broadcast camera, floodlights and the stadium
## shell (stands, walls, hoardings, scoreboard, crowd). `host` receives the
## top-level nodes (environment/camera/lights); `stadium_root` the structure.
## After `_build_camera()`, read back `camera_rig`/`camera_3d`.

var mf: MaterialFactory
var host: Node3D
var stadium_root: Node3D
var camera_rig: Node3D
var camera_3d: Camera3D

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
	host.add_child(world)

func _build_camera() -> void:
	camera_rig = Node3D.new()
	camera_rig.name = "CameraRig"
	camera_rig.position = Vector3(0.0, 18.0, 24.0)
	host.add_child(camera_rig)
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
	host.add_child(moon)
	var flood_root := Node3D.new()
	flood_root.name = "FloodLights"
	host.add_child(flood_root)
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
	var pole := mf._mesh("Pole", CylinderMesh.new(), mf.materials.metal_dark, Vector3.ZERO)
	pole.mesh.height = pos.y
	pole.mesh.top_radius = 0.08
	pole.mesh.bottom_radius = 0.10
	pole.position.y = -pos.y * 0.5
	tower.add_child(pole)
	var lamp := mf._mesh("Lamp", BoxMesh.new(), mf.materials.light_emission, Vector3.ZERO)
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

func _build_stadium() -> void:
	var field_x := GameConfig.FIELD_HALF_WIDTH * GameConfig.FIELD_SCALE
	var field_z := GameConfig.FIELD_HALF_HEIGHT * GameConfig.FIELD_SCALE
	_add_ground_apron()
	_add_perimeter_walls()
	_add_stand("NorthStand", Vector3(0.0, 1.0, -field_z - 5.0), Vector3(field_x * 2.5, 2.0, 5.0), mf.materials.concrete)
	_add_stand("SouthStand", Vector3(0.0, 1.0, field_z + 5.0), Vector3(field_x * 2.5, 2.0, 5.0), mf.materials.concrete)
	_add_stand("WestStand", Vector3(-field_x - 5.5, 1.0, 0.0), Vector3(5.0, 2.0, field_z * 2.0), mf.materials.concrete)
	_add_stand("EastStand", Vector3(field_x + 5.5, 1.0, 0.0), Vector3(5.0, 2.0, field_z * 2.0), mf.materials.concrete)
	_add_crowd_cards(field_x, field_z)
	_add_hoardings()
	_add_scoreboard(Vector3(0.0, 5.2, -field_z - 7.8))

func _add_ground_apron() -> void:
	var apron := mf._mesh("GroundApron", BoxMesh.new(), mf.materials.asphalt, Vector3(0.0, -0.06, 0.0))
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
		var wall := mf._mesh(w[0], BoxMesh.new(), mf.materials.wall, w[1])
		wall.mesh.size = w[2]
		stadium_root.add_child(wall)
		var band := mf._mesh("%sBand" % w[0], BoxMesh.new(), mf.materials.wall_top, w[1] + Vector3(0.0, 4.35, 0.0))
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
	var bx := GameConfig.FIELD_BOUNDARY_X * GameConfig.FIELD_SCALE
	var bz := GameConfig.FIELD_BOUNDARY_Y * GameConfig.FIELD_SCALE
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
	var frame := mf._mesh("Frame", BoxMesh.new(), mf.materials.metal_dark, Vector3(0.0, 0.46, -0.04))
	frame.mesh.size = Vector3(3.7, 0.92, 0.08)
	board.add_child(frame)
	var scheme: int = idx % mf.materials.ad_panels.size()
	var panel := mf._mesh("Panel", BoxMesh.new(), mf.materials.ad_panels[scheme], Vector3(0.0, 0.46, 0.02))
	panel.mesh.size = Vector3(3.55, 0.78, 0.05)
	board.add_child(panel)
	var label := Label3D.new()
	label.name = "AdText"
	label.text = text
	label.font_size = 96
	label.modulate = mf.materials.ad_text_colors[scheme]
	label.position = Vector3(0.0, 0.46, 0.06)
	board.add_child(label)

func _add_stand(stand_name: String, pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> void:
	var stand := Node3D.new()
	stand.name = stand_name
	stand.position = pos
	stadium_root.add_child(stand)
	for tier in 4:
		var tier_mesh := mf._mesh("Tier%d" % tier, BoxMesh.new(), mat, Vector3(0.0, float(tier) * 0.55, 0.0))
		tier_mesh.mesh.size = Vector3(size.x - float(tier) * 0.55, 0.42, size.z - float(tier) * 0.35)
		stand.add_child(tier_mesh)
		var seat_mat: Material = mf.materials.seat_red if tier % 2 == 0 else mf.materials.seat_blue
		var seat := mf._mesh("SeatBand%d" % tier, BoxMesh.new(), seat_mat, Vector3(0.0, float(tier) * 0.55 + 0.27, 0.0))
		seat.mesh.size = Vector3(tier_mesh.mesh.size.x * 0.94, 0.08, tier_mesh.mesh.size.z * 0.72)
		stand.add_child(seat)

func _add_scoreboard(pos: Vector3) -> void:
	var board := mf._mesh("Scoreboard", BoxMesh.new(), mf.materials.scoreboard, pos)
	board.mesh.size = Vector3(5.2, 1.8, 0.18)
	stadium_root.add_child(board)
	board.look_at(Vector3.ZERO, Vector3.UP)
	for pole_side in [-1.0, 1.0]:
		var pole := mf._mesh("ScoreboardPole%d" % pole_side, CylinderMesh.new(), mf.materials.metal_dark, Vector3(pole_side * 1.8, pos.y * 0.5 - 0.45, pos.z))
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
