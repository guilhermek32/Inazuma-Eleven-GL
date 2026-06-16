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
var voxel_gi: VoxelGI

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
	# IBL: drive ambient and reflections from the procedural night sky so metallic
	# surfaces (posts, poles) catch the sky colour instead of a flat grey fill.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = Color(0.45, 0.55, 0.78)
	env.ambient_light_energy = 0.28
	# ACES HDR tonemapping: cinematic highlight roll-off so the bright floodlights
	# and neon signs compress gracefully instead of blowing out.
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.1
	env.tonemap_white = 8.0
	# Glow/bloom: raised HDR threshold + lower intensity so only the brightest
	# emitters (lamp housings, neon ad-boards, scoreboard) bloom without leaking
	# into and washing out the darker stands.
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_strength = 1.2
	env.glow_bloom = 0.2
	env.glow_hdr_threshold = 1.1
	# SSAO: screen-space ambient occlusion darkens contact areas (players on grass,
	# inside goal mouth, stand tiers) without expensive ray-traced GI.
	env.ssao_enabled = true
	env.ssao_radius = 0.8
	env.ssao_intensity = 2.0
	env.ssao_power = 1.6
	# SSIL: screen-space indirect lighting lets the red/blue neon boards bleed coloured
	# light onto nearby players and turf, on top of the VoxelGI bounce.
	env.ssil_enabled = true
	env.ssil_radius = 6.0
	env.ssil_intensity = 1.4
	# Volumetric fog: faint stadium haze so the floodlight cones become visible light
	# shafts and the far end of the pitch falls off with atmospheric depth.
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.012
	env.volumetric_fog_albedo = Color(0.85, 0.90, 1.0)
	env.volumetric_fog_emission = Color(0.0, 0.0, 0.0)
	env.volumetric_fog_emission_energy = 0.0
	env.volumetric_fog_gi_inject = 1.0
	env.volumetric_fog_ambient_inject = 0.4
	env.volumetric_fog_length = 96.0
	env.volumetric_fog_detail_spread = 2.0
	world.environment = env
	host.add_child(world)

func _build_camera() -> void:
	camera_rig = Node3D.new()
	camera_rig.name = "CameraRig"
	var s := GameConfig.FIELD_SCALE
	camera_rig.position = Vector3(0.0, s, s * (4.0 / 3.0))
	host.add_child(camera_rig)
	camera_3d = Camera3D.new()
	camera_3d.name = "Camera3D"
	camera_3d.fov = 49.0
	camera_3d.current = true
	camera_rig.add_child(camera_3d)
	camera_3d.look_at(Vector3.ZERO, Vector3.UP)

func _build_lighting() -> void:
	# Bigger positional shadow atlas so each of the four far floodlights gets enough
	# texels to resolve a crisp player shadow (default 2048 split four ways is too
	# coarse for cones firing across the whole pitch from the corners).
	var vp := host.get_viewport()
	if vp != null:
		vp.positional_shadow_atlas_size = 4096
		vp.positional_shadow_atlas_quad_0 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_1
		vp.positional_shadow_atlas_quad_1 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_4
	var moon := DirectionalLight3D.new()
	moon.name = "MoonLight"
	moon.light_color = Color(0.60, 0.68, 0.88)
	moon.light_energy = 0.45
	moon.light_specular = 0.5
	moon.light_angular_distance = 0.8
	# Moon is fill light only — its single hard CSM shadow was the lone visible one
	# and drowned out the four floodlight shadows, so it no longer casts.
	moon.shadow_enabled = false
	moon.rotation_degrees = Vector3(-52.0, -34.0, 0.0)
	host.add_child(moon)
	var flood_root := Node3D.new()
	flood_root.name = "FloodLights"
	host.add_child(flood_root)
	# Lamp posts at the four corners, just outside the stands. Kept moderate height so
	# the head sits within the down-angled broadcast frame (peeking over the stand
	# corner) instead of towering off-screen into the sky. top_y = mast height.
	var mast_x := GameConfig.FIELD_HALF_WIDTH * GameConfig.FIELD_SCALE + 8.5
	var mast_z := GameConfig.FIELD_HALF_HEIGHT * GameConfig.FIELD_SCALE + 9.5
	var top_y := 13.0
	var positions := [
		Vector3(-mast_x, top_y, -mast_z),
		Vector3(mast_x, top_y, -mast_z),
		Vector3(-mast_x, top_y, mast_z),
		Vector3(mast_x, top_y, mast_z),
	]
	for i in positions.size():
		_add_floodlight(flood_root, positions[i], i)

# Global illumination probe. Created after the static geometry (pitch, stands,
# goals, emissive hoardings/scoreboard) is built; bake() is triggered separately by
# the controller, deferred one frame and before the dynamic players exist, so the
# probe captures only static surfaces and the coloured neon spill bounces onto turf.
func _build_gi() -> void:
	var s := GameConfig.FIELD_SCALE
	voxel_gi = VoxelGI.new()
	voxel_gi.name = "VoxelGI"
	voxel_gi.subdiv = VoxelGI.SUBDIV_256   # high resolution; realism is the priority
	# Cover the playfield + lower stands + hoardings/scoreboard height.
	voxel_gi.size = Vector3(s * (72.0 / 18.0), 16.0, s * (68.0 / 18.0))
	voxel_gi.position = Vector3(0.0, 5.0, 0.0)
	host.add_child(voxel_gi)

func _bake_gi() -> void:
	if voxel_gi != null:
		voxel_gi.bake()

func _add_floodlight(parent: Node3D, pos: Vector3, index: int) -> void:
	var tower := Node3D.new()
	tower.name = "FloodlightTower%d" % index
	tower.position = pos
	parent.add_child(tower)
	# Thick tapered steel mast rising from the ground to the head (lit metal so the
	# pole itself reads clearly as a structure, not a hairline).
	var pole := mf._mesh("Pole", CylinderMesh.new(), mf.materials.metal_mast, Vector3.ZERO)
	pole.mesh.height = pos.y
	pole.mesh.top_radius = 0.45
	pole.mesh.bottom_radius = 0.70
	pole.position.y = -pos.y * 0.5
	tower.add_child(pole)
	# Base plinth so the pole reads as planted in the ground.
	var base := mf._mesh("MastBase", CylinderMesh.new(), mf.materials.metal_dark, Vector3(0.0, -pos.y + 0.4, 0.0))
	base.mesh.height = 0.8
	base.mesh.top_radius = 0.9
	base.mesh.bottom_radius = 1.1
	tower.add_child(base)
	# Lamp head: aim its -Z toward the pitch centre, then hang the chunky housing
	# off that face so the bright lamps point at the pitch.
	var head := Node3D.new()
	head.name = "LampHead"
	tower.add_child(head)
	head.look_at(Vector3.ZERO, Vector3.UP)
	_build_lamp_bank(head)
	# Warm omni accent at the head: local emissive halo around the fitting.
	var accent := OmniLight3D.new()
	accent.name = "LampAccent"
	accent.light_color = Color(0.9, 0.95, 1.0)
	accent.light_energy = 6.0
	accent.omni_range = 9.0
	accent.omni_attenuation = 2.0
	accent.shadow_enabled = false
	head.add_child(accent)
	# Spot (cone source): crisp falloff, specular highlights on players/posts.
	# All four towers cast soft shadows for the classic overlapping-shadows look.
	# Parented to the head and pushed out IN FRONT of the lamp cells so the fixture
	# never occludes its own beam; the head's -Z already aims at the pitch centre.
	var spot := SpotLight3D.new()
	spot.name = "SpotLight3D"
	spot.light_color = Color(0.85, 0.92, 1.0)
	spot.light_energy = 18.0
	spot.light_specular = 1.0
	spot.spot_range = 90.0
	spot.spot_angle = 50.0
	spot.spot_attenuation = 1.4
	spot.light_size = 0.9        # tighter source → crisper, readable shadow edges
	spot.shadow_enabled = true
	spot.shadow_blur = 0.6
	spot.shadow_bias = 0.03
	spot.position = Vector3(0.0, 0.0, -1.7)
	head.add_child(spot)

# Chunky 3D lamp housing (a deep box, not a flat panel — so it never collapses to a
# thin stripe when seen from the side) with a grid of protruding bright lamp cells on
# the front face. Built on the head's -Z face so it points at the pitch centre.
func _build_lamp_bank(head: Node3D) -> void:
	# Short bracket arm tying the housing to the mast top. The fixture geometry never
	# casts shadows — otherwise it would occlude its own (and neighbouring) floodlights.
	var arm := mf._mesh("LampArm", BoxMesh.new(), mf.materials.metal_dark, Vector3(0.0, 0.0, 0.4))
	arm.mesh.size = Vector3(0.35, 0.35, 1.0)
	arm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	head.add_child(arm)
	# Deep housing box: width × height × depth, so it has real volume from any angle.
	var housing := mf._mesh("LampHousing", BoxMesh.new(), mf.materials.metal_dark, Vector3(0.0, 0.0, -0.7))
	housing.mesh.size = Vector3(4.4, 2.6, 1.2)
	housing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	head.add_child(housing)
	var cols := 4
	var rows := 3
	for r in rows:
		for c in cols:
			var cx := (float(c) - float(cols - 1) * 0.5) * 1.0
			var cy := (float(r) - float(rows - 1) * 0.5) * 0.78
			var cell := mf._mesh("LampCell%d_%d" % [r, c], BoxMesh.new(), mf.materials.floodlamp, Vector3(cx, cy, -1.35))
			cell.mesh.size = Vector3(0.82, 0.62, 0.22)
			cell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			head.add_child(cell)

func _build_stadium() -> void:
	var field_x := GameConfig.FIELD_HALF_WIDTH * GameConfig.FIELD_SCALE
	var field_z := GameConfig.FIELD_HALF_HEIGHT * GameConfig.FIELD_SCALE
	var s := GameConfig.FIELD_SCALE
	var stand_gap_z := s * (5.0 / 18.0)
	var stand_gap_x := s * (5.5 / 18.0)
	_add_ground_apron()
	_add_perimeter_walls()
	_add_stand("NorthStand", Vector3(0.0, 1.0, -field_z - stand_gap_z), Vector3(field_x * 2.5, 2.0, s * (5.0 / 18.0)), mf.materials.concrete)
	_add_stand("SouthStand", Vector3(0.0, 1.0, field_z + stand_gap_z), Vector3(field_x * 2.5, 2.0, s * (5.0 / 18.0)), mf.materials.concrete)
	_add_stand("WestStand", Vector3(-field_x - stand_gap_x, 1.0, 0.0), Vector3(s * (5.0 / 18.0), 2.0, field_z * 2.0), mf.materials.concrete)
	_add_stand("EastStand", Vector3(field_x + stand_gap_x, 1.0, 0.0), Vector3(s * (5.0 / 18.0), 2.0, field_z * 2.0), mf.materials.concrete)
	_add_crowd(field_x, field_z)
	_add_hoardings()

func _add_ground_apron() -> void:
	var apron := mf._mesh("GroundApron", BoxMesh.new(), mf.materials.asphalt, Vector3(0.0, -0.06, 0.0))
	var s := GameConfig.FIELD_SCALE
	apron.mesh.size = Vector3(s * (72.0 / 18.0), 0.08, s * (68.0 / 18.0))
	apron.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stadium_root.add_child(apron)

func _add_perimeter_walls() -> void:
	var s := GameConfig.FIELD_SCALE
	var walls := [
		["NorthWall", Vector3(0.0, 4.0, -s * (33.7 / 18.0)), Vector3(s * (72.0 / 18.0), 8.0, 0.6)],
		["SouthWall", Vector3(0.0, 4.0, s * (33.7 / 18.0)), Vector3(s * (72.0 / 18.0), 8.0, 0.6)],
		["WestWall", Vector3(-s * (35.7 / 18.0), 4.0, 0.0), Vector3(0.6, 8.0, s * (68.0 / 18.0))],
		["EastWall", Vector3(s * (35.7 / 18.0), 4.0, 0.0), Vector3(0.6, 8.0, s * (68.0 / 18.0))],
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
	var s2 := GameConfig.FIELD_SCALE
	sign.position = Vector3(0.0, 6.5, -s2 * (33.3 / 18.0))
	stadium_root.add_child(sign)

func _add_hoardings() -> void:
	var ads := ["INAZUMA", "RAIMON FC", "ELEVEN TV", "KICK & GO", "SUPERNOVA", "GOAL MART", "METEOR LTD", "STRIKER+"]
	var bx := GameConfig.FIELD_BOUNDARY_X * GameConfig.FIELD_SCALE
	var bz := GameConfig.FIELD_BOUNDARY_Y * GameConfig.FIELD_SCALE
	var s := GameConfig.FIELD_SCALE
	var h_start := -s * (13.65 / 18.0)
	var h_step := s * (3.9 / 18.0)
	var h_offset := s * (1.7 / 18.0)
	var v_start := -s * (7.8 / 18.0)
	var v_step := s * (3.9 / 18.0)
	var v_offset := s * (2.2 / 18.0)
	var idx := 0
	for i in 8:
		var x := h_start + float(i) * h_step
		_add_hoarding(Vector3(x, 0.0, -bz - h_offset), 0.0, ads[idx % ads.size()], idx)
		idx += 1
		_add_hoarding(Vector3(x, 0.0, bz + h_offset), PI, ads[idx % ads.size()], idx)
		idx += 1
	for i in 5:
		var z := v_start + float(i) * v_step
		_add_hoarding(Vector3(-bx - v_offset, 0.0, z), PI * 0.5, ads[idx % ads.size()], idx)
		idx += 1
		_add_hoarding(Vector3(bx + v_offset, 0.0, z), -PI * 0.5, ads[idx % ads.size()], idx)
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

# Dense 3D crowd via two MultiMeshes (bodies + heads). Each spectator is a capsule
# body (team kit colour) topped by a sphere head (skin tone), placed in raked banks
# rising away from the pitch on each of the four stands, with per-instance colour,
# scale and position jitter plus a subtle GPU idle bob (see materials.crowd).
func _add_crowd(field_x: float, field_z: float) -> void:
	var s := GameConfig.FIELD_SCALE
	var cross_half := s * (5.0 / 18.0) * 0.5
	# center, long-axis length, long axis is x?, sign toward the pitch on the cross
	# axis, dominant team colour for this stand.
	var stands := [
		{"center": Vector3(0.0, 1.0, -field_z - s * (5.0 / 18.0)), "long": field_x * 2.5, "along_x": true, "to_pitch": 1.0, "team": "red"},
		{"center": Vector3(0.0, 1.0, field_z + s * (5.0 / 18.0)), "long": field_x * 2.5, "along_x": true, "to_pitch": -1.0, "team": "blue"},
		{"center": Vector3(-field_x - s * (5.5 / 18.0), 1.0, 0.0), "long": field_z * 2.0, "along_x": false, "to_pitch": 1.0, "team": "mix"},
		{"center": Vector3(field_x + s * (5.5 / 18.0), 1.0, 0.0), "long": field_z * 2.0, "along_x": false, "to_pitch": 1.0, "team": "mix"},
	]
	# East stand sits on +x, so its pitch direction is -x.
	stands[3]["to_pitch"] = -1.0

	var reds := [Color(0.72, 0.12, 0.10), Color(0.60, 0.07, 0.06), Color(0.82, 0.22, 0.16)]
	var blues := [Color(0.10, 0.18, 0.66), Color(0.06, 0.12, 0.50), Color(0.16, 0.26, 0.74)]
	var neutrals := [Color(0.85, 0.85, 0.88), Color(0.42, 0.42, 0.45), Color(0.55, 0.45, 0.32), Color(0.20, 0.45, 0.28), Color(0.66, 0.62, 0.20)]
	var mixed := []
	mixed.append_array(reds)
	mixed.append_array(blues)
	mixed.append_array(neutrals)
	var skins := [Color(0.86, 0.66, 0.52), Color(0.72, 0.52, 0.38), Color(0.52, 0.36, 0.24), Color(0.94, 0.78, 0.62)]

	var n_depth := 7
	var depth_step := 0.55
	var rise_step := 0.34
	var col_spacing := 0.6
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xC0DDED

	var body_xforms: Array[Transform3D] = []
	var body_colors: PackedColorArray = []
	var head_colors: PackedColorArray = []
	var phases: PackedFloat32Array = []

	for stand in stands:
		var center: Vector3 = stand["center"]
		var along_x: bool = stand["along_x"]
		var to_pitch: float = stand["to_pitch"]
		var team: String = stand["team"]
		var center_cross: float = center.z if along_x else center.x
		var usable := float(stand["long"]) * 0.92
		var n_cols := int(usable / col_spacing)
		for r in n_depth:
			var cross := center_cross + to_pitch * cross_half - to_pitch * (0.2 + float(r) * depth_step)
			var feet_y := center.y + 0.4 + float(r) * rise_step
			for c in n_cols:
				var along := -usable * 0.5 + float(c) * col_spacing + rng.randf_range(-0.18, 0.18)
				var cy := feet_y + rng.randf_range(-0.05, 0.08)
				var cx := cross + rng.randf_range(-0.12, 0.12)
				var feet := Vector3(along, cy, cx) if along_x else Vector3(cx, cy, along)
				var sc := rng.randf_range(0.9, 1.12)
				var basis := Basis().scaled(Vector3(sc, sc, sc))
				body_xforms.append(Transform3D(basis, feet + Vector3(0.0, 0.435 * sc, 0.0)))
				body_colors.append(_pick_crowd_color(rng, team, reds, blues, mixed))
				head_colors.append(skins[rng.randi() % skins.size()])
				phases.append(rng.randf())

	_build_crowd_multimesh("CrowdBodies", _crowd_body_mesh(), body_xforms, body_colors, phases, 0.0)
	_build_crowd_multimesh("CrowdHeads", _crowd_head_mesh(), body_xforms, head_colors, phases, 0.5)

func _pick_crowd_color(rng: RandomNumberGenerator, team: String, reds: Array, blues: Array, mixed: Array) -> Color:
	if team == "red" and rng.randf() < 0.7:
		return reds[rng.randi() % reds.size()]
	if team == "blue" and rng.randf() < 0.7:
		return blues[rng.randi() % blues.size()]
	return mixed[rng.randi() % mixed.size()]

func _crowd_body_mesh() -> Mesh:
	var m := CapsuleMesh.new()
	m.radius = 0.16
	m.height = 0.55
	m.radial_segments = 6
	m.rings = 3
	return m

func _crowd_head_mesh() -> Mesh:
	var m := SphereMesh.new()
	m.radius = 0.13
	m.height = 0.26
	m.radial_segments = 6
	m.rings = 4
	return m

func _build_crowd_multimesh(node_name: String, mesh: Mesh, xforms: Array[Transform3D], colors: PackedColorArray, phases: PackedFloat32Array, lift: float) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		var x: Transform3D = xforms[i]
		if lift != 0.0:
			x.origin += x.basis.y * lift   # head offset scales with the instance
		mm.set_instance_transform(i, x)
		mm.set_instance_color(i, colors[i])
		mm.set_instance_custom_data(i, Color(phases[i], 0.0, 0.0, 0.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = mf.materials.crowd
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stadium_root.add_child(mmi)
