class_name PlayerFactory
extends RefCounted

## Creates each player's 3D visual: a Mixamo GLB character with a retargeted
## animation library when available, otherwise a procedural box figure. Owns the
## GLB scene cache and the shared animation library.

var mf: MaterialFactory
var glb_scene_cache := {}
var player_anim_library: AnimationLibrary
var player_anim_ready := false

func create_player_visual(state: PlayerState, kit: Dictionary) -> Node3D:
	var glb_visual = _create_glb_player_visual(state, kit)
	if glb_visual != null:
		return glb_visual
	var shirt_mat := _kit_mat(kit.shirt)
	var shorts_mat := _kit_mat(kit.shorts)
	var boots_mat := _kit_mat(kit.boots)
	var root := Node3D.new()
	root.name = "PlayerA" if state.side == -1 else "PlayerB"
	var body := mf.make_mesh("Body", BoxMesh.new(), shirt_mat, Vector3(0.0, 0.78, 0.0))
	body.mesh.size = Vector3(0.42, 0.82, 0.26)
	root.add_child(body)
	var shorts := mf.make_mesh("Shorts", BoxMesh.new(), shorts_mat, Vector3(0.0, 0.42, 0.0))
	shorts.mesh.size = Vector3(0.40, 0.26, 0.24)
	root.add_child(shorts)
	var head := mf.make_mesh("Head", SphereMesh.new(), mf.materials.skin, Vector3(0.0, 1.34, 0.0))
	head.mesh.radius = 0.22
	head.mesh.height = 0.42
	root.add_child(head)
	var hair := mf.make_mesh("Hair", SphereMesh.new(), mf.materials.hair, Vector3(0.0, 1.50, -0.02))
	hair.mesh.radius = 0.19
	hair.mesh.height = 0.18
	root.add_child(hair)
	for limb_name in ["ArmL", "ArmR", "LegL", "LegR"]:
		var limb_mat: Material = shirt_mat if limb_name.begins_with("Arm") else boots_mat
		var limb := mf.make_mesh(limb_name, BoxMesh.new(), limb_mat, Vector3.ZERO)
		limb.mesh.size = Vector3(0.13, 0.62, 0.13)
		root.add_child(limb)
	root.get_node("ArmL").position = Vector3(-0.32, 0.72, 0.0)
	root.get_node("ArmR").position = Vector3(0.32, 0.72, 0.0)
	root.get_node("LegL").position = Vector3(-0.13, 0.28, 0.0)
	root.get_node("LegR").position = Vector3(0.13, 0.28, 0.0)
	_add_ground_markers(root)
	root.add_child(_jersey_label(1.85))
	return root

## Shared per-player ground furniture: selection/next rings (thin torus outlines
## instead of filled discs), the charge power ring and a soft blob shadow that
## keeps players grounded when the real floodlight shadows fade at distance.
func _add_ground_markers(root: Node3D) -> void:
	var blob := mf.make_mesh("BlobShadow", QuadMesh.new(), _blob_shadow_material(), Vector3(0.0, 0.03, 0.0))
	blob.mesh.size = Vector2(1.1, 1.1)
	blob.rotation_degrees.x = -90.0
	blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(blob)
	var marker := _ring_marker("SelectedRing", mf.materials.selection, 0.46)
	root.add_child(marker)
	var next_marker := _ring_marker("NextRing", mf.materials.selection_next, 0.46)
	root.add_child(next_marker)
	var power := mf.make_mesh("PowerRing", CylinderMesh.new(), mf.materials.power, Vector3(0.0, 0.07, 0.0))
	power.mesh.top_radius = 0.64
	power.mesh.bottom_radius = 0.64
	power.mesh.height = 0.025
	power.visible = false
	root.add_child(power)

func _ring_marker(ring_name: String, mat: Material, radius: float) -> MeshInstance3D:
	var ring := mf.make_mesh(ring_name, TorusMesh.new(), mat, Vector3(0.0, 0.035, 0.0))
	ring.mesh.inner_radius = radius - 0.06
	ring.mesh.outer_radius = radius
	ring.scale.y = 0.3   # flatten the torus tube into a ground outline
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.visible = false
	return ring

func _blob_shadow_material() -> StandardMaterial3D:
	if not mf.materials.has("blob_shadow"):
		mf.materials.blob_shadow = mf.make_blob_shadow_material()
	return mf.materials.blob_shadow

func _create_glb_player_visual(state: PlayerState, kit: Dictionary):
	var root := Node3D.new()
	root.name = "PlayerAGLB" if state.team_index == 0 else "PlayerBGLB"
	state.uses_glb = true
	state.node = root
	_add_ground_markers(root)
	# Load the character mesh once and drive its skeleton with retargeted Mixamo clips.
	var model: Node3D = _instantiate_glb(GameConfig.PLAYER_ASSET_DIR + GameConfig.PLAYER_MESH_FILE)
	if model == null:
		push_warning("Player GLB mesh failed to load: %s" % (GameConfig.PLAYER_ASSET_DIR + GameConfig.PLAYER_MESH_FILE))
		state.uses_glb = false
		root.free()
		return null
	_place_glb_model(model)
	_apply_team_kit(model, kit)
	model.name = "Model"
	model.rotation_degrees = Vector3(0.0, GameConfig.PLAYER_GLB_YAW_OFFSET, 0.0)
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
	state.set_visual_state("gk_idle" if state.role == GameConfig.PlayerRole.GOALKEEPER else "idle")
	root.add_child(_jersey_label(2.3))
	return root

# Builds the shared library of named clips extracted from the animation-only action GLBs.

func _ensure_player_anim_library() -> bool:
	if player_anim_ready:
		return player_anim_library != null
	player_anim_ready = true
	var lib := AnimationLibrary.new()
	for state_name in GameConfig.PLAYER_ANIM_FILES:
		var entry: Array = GameConfig.PLAYER_ANIM_FILES[state_name]
		var path: String = GameConfig.PLAYER_ASSET_DIR + entry[0]
		var anim := _load_player_animation(path)
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

func _load_player_animation(path: String) -> Animation:
	if not ResourceLoader.exists(path, "PackedScene"):
		push_warning("Player animation file is not imported as PackedScene: %s" % path)
		return null
	var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
	if packed == null:
		push_warning("Player animation file failed to load: %s" % path)
		return null
	var scene := packed.instantiate()
	var ap := _find_animation_player(scene)
	var anim: Animation = null
	if ap != null:
		var anim_name := _first_glb_animation(ap)
		if not String(anim_name).is_empty():
			anim = ap.get_animation(anim_name).duplicate()
	else:
		push_warning("Player animation scene has no AnimationPlayer: %s" % path)
	scene.free()
	return anim

func _first_glb_animation(player: AnimationPlayer) -> StringName:
	if player.has_animation(GameConfig.PLAYER_GLTF_ANIM):
		return StringName(GameConfig.PLAYER_GLTF_ANIM)
	for anim_name in player.get_animation_list():
		if String(anim_name).to_lower() != "reset":
			return anim_name
	return StringName()

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
	var bounds := mf.subtree_local_aabb(model)
	if bounds.size.length() <= 0.001 or bounds.size.y <= 0.001:
		model.scale = Vector3.ONE * GameConfig.PLAYER_GLB_SCALE
		model.position = Vector3(0.0, GameConfig.PLAYER_GLB_Y_OFFSET, 0.0)
		push_warning("Player GLB bounds unavailable; using fixed imported-model scale.")
		return
	var scale := GameConfig.PLAYER_GLB_SCALE
	var center := bounds.position + bounds.size * 0.5
	model.scale = Vector3.ONE * scale
	model.position = Vector3(-center.x * scale, GameConfig.PLAYER_GLB_Y_OFFSET - bounds.position.y * scale, -center.z * scale)

func _apply_team_kit(model: Node3D, kit: Dictionary) -> void:
	_apply_team_kit_recursive(model, kit)

func _apply_team_kit_recursive(node: Node, kit: Dictionary) -> void:
	if node is MeshInstance3D:
		var part := _kit_part(node.name)
		if part != "":
			var tint: Color = kit[part]
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
						base.albedo_color = base.albedo_color.lerp(tint, 0.85)
					mesh_instance.set_surface_override_material(surface_idx, mat)
	for child: Node in node.get_children():
		_apply_team_kit_recursive(child, kit)

# Maps a GLB mesh name to a kit piece (shirt/shorts/boots), or "" to leave it as-is.
func _kit_part(node_name: StringName) -> String:
	var n := String(node_name).to_lower()
	if n.contains("shirt") or n.contains("jersey"):
		return "shirt"
	if n.contains("short") or n.contains("trouser") or n.contains("pant"):
		return "shorts"
	if n.contains("sock") or n.contains("shoe") or n.contains("boot"):
		return "boots"
	return ""

# A team-kit material built from a chosen colour (used by the box-figure fallback).
func _kit_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.58
	m.rim_enabled = true
	m.rim = 0.35
	m.rim_tint = 0.4
	return m

func _jersey_label(height: float) -> Label3D:
	var label := Label3D.new()
	label.name = "JerseyNumber"
	label.text = ""
	label.font_size = 64
	label.pixel_size = 0.006
	label.modulate = Color(1.0, 1.0, 1.0, 0.92)
	label.outline_size = 7
	label.outline_modulate = Color(0.0, 0.0, 0.0, 0.88)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0.0, height, 0.0)
	return label
