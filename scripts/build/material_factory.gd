class_name MaterialFactory
extends RefCounted

## Builds and owns the shared `materials` palette and the low-level mesh/material/
## texture primitives used by every scene builder. Instantiated once; builders
## hold a reference to it as `mf`.

var materials := {}

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
	materials.selection_next = _emission_material(Color(0.25, 1.0, 0.72), 1.2)
	materials.power = _emission_material(Color(0.1, 0.65, 1.0), 1.7)
	materials.trail = _material(Color(1.0, 0.86, 0.25, 0.36), 0.35)
	materials.confetti_red = _emission_material(Color(1.0, 0.08, 0.04), 1.1)
	materials.confetti_blue = _emission_material(Color(0.08, 0.28, 1.0), 1.1)
	materials.confetti_gold = _emission_material(Color(1.0, 0.84, 0.12), 1.3)

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
