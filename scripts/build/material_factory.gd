class_name MaterialFactory
extends RefCounted

## Builds and owns the shared `materials` palette and the low-level mesh/material/
## texture primitives used by every scene builder. Instantiated once; builders
## hold a reference to it as `mf`.

var materials := {}
# Original grass values, stashed the first time set_pitch_wet() darkens them.
var _dry_pitch := {}

# Goal-net ripple: vertices are displaced along their normal by a radial sine
# wave centred on the (world-space) ball impact point, decaying in both distance
# and time. ripple_strength 0 = completely still.
const NET_SHADER_CODE := "
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D albedo_tex : source_color;
uniform vec3 impact_world = vec3(0.0);
uniform float ripple_time = 10.0;
uniform float ripple_strength = 0.0;
void vertex() {
	vec3 wv = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float d = distance(wv, impact_world);
	float amp = ripple_strength * exp(-d * 1.6) * exp(-ripple_time * 2.6);
	VERTEX += NORMAL * amp * sin(d * 9.0 - ripple_time * 22.0);
}
void fragment() {
	vec4 c = texture(albedo_tex, UV);
	ALBEDO = c.rgb;
	ALPHA = c.a;
	ROUGHNESS = 0.7;
}
"

## Fresh net material instance (one per goal, so only the goal that concedes ripples).
func make_net_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = NET_SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("albedo_tex", _net_texture())
	return mat

## Rain visual: darkens and polishes the turf so the floodlights leave a wet sheen.
func set_pitch_wet(wet: bool) -> void:
	for key in ["grass", "grass_dark"]:
		var m: StandardMaterial3D = materials[key]
		if not _dry_pitch.has(key):
			_dry_pitch[key] = {"rough": m.roughness, "col": m.albedo_color}
		m.roughness = 0.40 if wet else _dry_pitch[key].rough
		m.albedo_color = (_dry_pitch[key].col as Color) * Color(0.78, 0.78, 0.85) if wet else _dry_pitch[key].col

func build_materials() -> void:
	# Pre-bake procedural normal maps: tangent-space RGB from height-field gradients.
	var grass_nrm := _normal_texture(2.5, 0x6752)
	var concrete_nrm := _normal_texture(3.0, 0xC0FF)
	var metal_nrm := _normal_texture(0.8, 0xFACE)

	# --- Pitch surfaces --- lower roughness so floodlights leave a turf sheen; the two
	# tones are pushed apart so the alternating mow stripes read clearly on broadcast.
	materials.grass = _material(Color.WHITE, 0.62, 0.0, _grass_texture(Color(0.105, 0.40, 0.145)), grass_nrm)
	materials.grass.normal_scale = 0.6
	materials.grass.anisotropy_enabled = true   # directional sheen along mow stripes
	materials.grass.anisotropy = 0.7
	materials.grass_dark = _material(Color.WHITE, 0.62, 0.0, _grass_texture(Color(0.068, 0.27, 0.10)), grass_nrm)
	materials.grass_dark.normal_scale = 0.6
	materials.grass_dark.anisotropy_enabled = true
	materials.grass_dark.anisotropy = 0.7
	materials.line = _material(Color(0.95, 0.97, 0.92), 0.55)

	# --- Goal structure: polished aluminium --- metallic BRDF, sky reflections
	materials.goal = _material(Color(0.87, 0.88, 0.90), 0.15, 0.85, null, metal_nrm)
	materials.goal.normal_scale = 0.25

	materials.net = _material(Color(1.0, 1.0, 1.0, 0.99), 0.7, 0.0, _net_texture())

	# --- Stadium surfaces: Lambert diffuse (flat/matte concrete) ---
	materials.concrete = _material(Color(0.37, 0.36, 0.34), 0.95, 0.0, _checker_texture(Color(0.28, 0.28, 0.27), Color(0.45, 0.44, 0.41), 128, 16), concrete_nrm)
	materials.concrete.normal_scale = 0.5
	materials.concrete.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT  # flat matte vs Burley elsewhere
	materials.asphalt = _material(Color.WHITE, 0.93, 0.0, _noise_texture(Color(0.125, 0.13, 0.145), 0.06), concrete_nrm)
	materials.asphalt.normal_scale = 0.4
	materials.asphalt.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT

	materials.wall = _material(Color(0.15, 0.16, 0.18), 0.95)
	materials.wall_top = _emission_material(Color(0.95, 0.88, 0.70), 0.5)
	materials.flag = _emission_material(Color(1.0, 0.85, 0.15), 0.8)
	materials.seat_red = _material(Color(0.55, 0.06, 0.05), 0.65)
	materials.seat_blue = _material(Color(0.04, 0.10, 0.55), 0.65)
	materials.crowd = _crowd_material()

	# --- Structural metal: poles, frames, hoarding rails ---
	materials.metal_dark = _material(Color(0.20, 0.21, 0.22), 0.36, 0.80, null, metal_nrm)
	materials.metal_dark.normal_scale = 0.28

	materials.light_emission = _emission_material(Color(1.0, 0.94, 0.72), 3.5)
	# Floodlight lamp cells: very bright cool white so the banks read as the
	# brightest objects in the scene and bloom through the glow threshold.
	materials.floodlamp = _emission_material(Color(0.90, 0.95, 1.0), 15.0)
	# Lighter mast metal so the towers catch the moon/sky and stay visible at night.
	materials.metal_mast = _material(Color(0.46, 0.49, 0.55), 0.4, 0.7, null)
	materials.ad_panels = [
		_emission_material(Color(0.92, 0.94, 0.98), 1.0),
		_emission_material(Color(0.10, 0.30, 0.95), 1.0),
		_emission_material(Color(0.90, 0.12, 0.10), 1.0),
		_emission_material(Color(1.0, 0.78, 0.10), 1.0),
	]
	materials.ad_text_colors = [Color(0.08, 0.10, 0.25), Color.WHITE, Color.WHITE, Color(0.15, 0.10, 0.02)]

	# --- Player kits: Burley diffuse + rim so players separate from dark backdrop ---
	materials.player_red = _material(Color(0.85, 0.05, 0.03), 0.58)
	materials.player_red.rim_enabled = true
	materials.player_red.rim = 0.35
	materials.player_red.rim_tint = 0.4
	materials.player_blue = _material(Color(0.04, 0.20, 0.88), 0.58)
	materials.player_blue.rim_enabled = true
	materials.player_blue.rim = 0.35
	materials.player_blue.rim_tint = 0.4
	materials.goalkeeper = _material(Color(1.0, 0.58, 0.05), 0.58)
	materials.goalkeeper.rim_enabled = true
	materials.goalkeeper.rim = 0.35
	materials.goalkeeper.rim_tint = 0.4

	# --- Skin: subsurface scattering for soft translucent shading ---
	materials.skin = _material(Color(0.72, 0.45, 0.28), 0.62)
	materials.skin.subsurf_scatter_enabled = true
	materials.skin.subsurf_scatter_strength = 0.25

	materials.hair = _material(Color(0.12, 0.07, 0.035), 0.7)
	materials.boots = _material(Color(0.03, 0.03, 0.035), 0.45, 0.55)

	# --- Ball: clearcoat for lacquered-leather double specular lobe ---
	materials.ball = _material(Color.WHITE, 0.42, 0.0, _checker_texture(Color(0.96, 0.96, 0.92), Color(0.02, 0.02, 0.025), 128, 24))
	materials.ball.clearcoat_enabled = true
	materials.ball.clearcoat = 1.0
	materials.ball.clearcoat_roughness = 0.08

	materials.selection = _emission_material(Color(1.0, 0.92, 0.08), 1.8)
	materials.selection_next = _emission_material(Color(0.25, 1.0, 0.72), 1.2)
	materials.power = _emission_material(Color(0.1, 0.65, 1.0), 1.7)
	materials.trail = _material(Color(1.0, 0.86, 0.25, 0.36), 0.35)
	materials.confetti_red = _emission_material(Color(1.0, 0.08, 0.04), 1.1)
	materials.confetti_blue = _emission_material(Color(0.08, 0.28, 1.0), 1.1)
	materials.confetti_gold = _emission_material(Color(1.0, 0.84, 0.12), 1.3)
	# Elemental aura around the ball during a named special shot. Additive + unshaded so
	# it glows independent of scene lighting; its albedo/emission are recoloured per shot.
	materials.special_aura = _emission_material(Color(1.0, 0.55, 0.12, 0.6), 4.0)
	materials.special_aura.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	materials.special_aura.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	materials.special_aura.cull_mode = BaseMaterial3D.CULL_DISABLED

func make_mesh(node_name: String, mesh: Mesh, mat: Material, pos: Vector3) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.material_override = mat
	node.position = pos
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return node

## Union of every MeshInstance3D AABB in `root`'s subtree, expressed in `root`'s
## local space (its own transform is ignored). Walks local transforms, so it works
## on a subtree not yet added to the scene tree; returns an empty AABB if none found.
## Used to size/centre loaded GLB models (ball, players).
func subtree_local_aabb(root: Node3D) -> AABB:
	var acc := {"box": AABB(), "has": false}
	_accumulate_subtree_aabb(root, Transform3D.IDENTITY, acc, true)
	return acc.box

func _accumulate_subtree_aabb(node: Node3D, xform: Transform3D, acc: Dictionary, is_root: bool) -> void:
	var here := xform if is_root else xform * node.transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var box := here * (node as MeshInstance3D).mesh.get_aabb()
		acc.box = (acc.box as AABB).merge(box) if acc.has else box
		acc.has = true
	for child in node.get_children():
		if child is Node3D:
			_accumulate_subtree_aabb(child as Node3D, here, acc, false)

func _material(color: Color, roughness := 0.65, metallic := 0.0, texture: Texture2D = null, normal: Texture2D = null) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.metallic = metallic
	if texture != null:
		mat.albedo_texture = texture
	if normal != null:
		mat.normal_enabled = true
		mat.normal_texture = normal
	if texture != null or normal != null:
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

# Crowd spectators rendered via MultiMesh: per-instance COLOR drives the albedo
# (team kit / skin tone) and INSTANCE_CUSTOM.x carries a 0..1 phase that offsets the
# instance vertically each frame for a subtle, out-of-sync idle bob.
func _crowd_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
uniform float bob_amp = 0.06;
uniform float bob_speed = 2.5;
void vertex() {
	float phase = INSTANCE_CUSTOM.x * 6.28318;
	VERTEX.y += sin(TIME * bob_speed + phase) * bob_amp;
}
void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.85;
	METALLIC = 0.0;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat

func _checker_texture(a: Color, b: Color, size: int, cells: int) -> Texture2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var use_a := ((x / cells) + (y / cells)) % 2 == 0
			img.set_pixel(x, y, a if use_a else b)
	return ImageTexture.create_from_image(img)

# Layered procedural turf albedo: low-frequency patch tone (worn/lush areas), a
# high-frequency per-blade speckle, and faint vertical (mow-direction) banding so the
# surface reads as blades catching light rather than flat noise.
func _grass_texture(base: Color, size := 512) -> Texture2D:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x6A55
	# Coarse patch field, bilinearly sampled for smooth large-scale tonal drift.
	var patch := 16
	var patch_field := PackedFloat32Array()
	patch_field.resize((patch + 1) * (patch + 1))
	for i in patch_field.size():
		patch_field[i] = rng.randf_range(-0.10, 0.10)
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			# Bilinear patch lookup.
			var fx := float(x) / float(size) * float(patch)
			var fy := float(y) / float(size) * float(patch)
			var ix := int(fx)
			var iy := int(fy)
			var tx := fx - float(ix)
			var ty := fy - float(iy)
			var p00 := patch_field[iy * (patch + 1) + ix]
			var p10 := patch_field[iy * (patch + 1) + ix + 1]
			var p01 := patch_field[(iy + 1) * (patch + 1) + ix]
			var p11 := patch_field[(iy + 1) * (patch + 1) + ix + 1]
			var patch_val := lerpf(lerpf(p00, p10, tx), lerpf(p01, p11, tx), ty)
			# High-frequency per-blade speckle.
			var blade := rng.randf_range(-0.07, 0.07)
			# Faint vertical mow banding (blades lie along the stripe direction).
			var band := sin(float(x) / float(size) * TAU * 24.0) * 0.025
			var f := 1.0 + patch_val + blade + band
			img.set_pixel(x, y, Color(base.r * f, base.g * f, base.b * f))
	img.generate_mipmaps()
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

# Soft radial scuff for the ball's grass trail: a dark pressed-turf disc that fades
# to fully transparent at the rim, with a little noise so repeated marks vary.
func decal_albedo_texture(size := 64) -> Texture2D:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xDEC0
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := float(size - 1) * 0.5
	for y in size:
		for x in size:
			var dx := (float(x) - c) / c
			var dy := (float(y) - c) / c
			var d := sqrt(dx * dx + dy * dy)
			var a := pow(clampf(1.0 - d, 0.0, 1.0), 1.25)
			a *= 1.0 + rng.randf_range(-0.15, 0.15)
			# Lighter, desaturated pressed-turf so the streak reads against dark night
			# grass (bent blades catch the floodlights, like a mow stripe).
			var shade := 1.0 + rng.randf_range(-0.12, 0.12)
			img.set_pixel(x, y, Color(0.34 * shade, 0.45 * shade, 0.24 * shade, clampf(a, 0.0, 1.0)))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

# Radial dimple normal map for the trail decal: the turf is pressed down where the
# ball rolled, so surface normals tilt inward — this is what perturbs ("interferes
# with") the grass normals under the decal so the floodlights catch the dent.
func decal_normal_texture(size := 64, strength := 4.0) -> Texture2D:
	var c := float(size - 1) * 0.5
	var h := PackedFloat32Array()
	h.resize(size * size)
	for y in size:
		for x in size:
			var dx := (float(x) - c) / c
			var dy := (float(y) - c) / c
			var d := clampf(sqrt(dx * dx + dy * dy), 0.0, 1.0)
			h[y * size + x] = -(1.0 - smoothstep(0.0, 1.0, d))   # dent: low centre, flat rim
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var h00 := h[y * size + x]
			var h10 := h[y * size + mini(x + 1, size - 1)]
			var h01 := h[mini(y + 1, size - 1) * size + x]
			var gx := (h10 - h00) * strength
			var gy := (h01 - h00) * strength
			var n := Vector3(-gx, -gy, 1.0).normalized()
			img.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

# Procedural tangent-space normal map from a blurred random height field.
# Finite-difference gradients → (R, G, B) = (Nx*0.5+0.5, Ny*0.5+0.5, Nz*0.5+0.5).
# `strength` scales the gradient; higher = more pronounced surface bumps.
func _normal_texture(strength: float, seed: int, size := 64) -> Texture2D:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var h := PackedFloat32Array()
	h.resize(size * size)
	for i in size * size:
		h[i] = rng.randf()
	var blurred := PackedFloat32Array()
	blurred.resize(size * size)
	for y in size:
		for x in size:
			var s := 0.0
			for ky in range(-1, 2):
				for kx in range(-1, 2):
					s += h[((y + ky + size) % size) * size + ((x + kx + size) % size)]
			blurred[y * size + x] = s / 9.0
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var h00 := blurred[y * size + x]
			var h10 := blurred[y * size + ((x + 1) % size)]
			var h01 := blurred[((y + 1) % size) * size + x]
			var gx := (h10 - h00) * strength
			var gy := (h01 - h00) * strength
			var n := Vector3(-gx, -gy, 1.0).normalized()
			img.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
