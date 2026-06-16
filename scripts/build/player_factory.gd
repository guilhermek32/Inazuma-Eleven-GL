class_name PlayerFactory
extends RefCounted

## Creates each player's 3D visual: a Mixamo GLB character with a retargeted
## animation library when available, otherwise a procedural box figure. Owns the
## GLB scene cache and the shared animation library.

var mf: MaterialFactory
var glb_scene_cache := {}
var player_anim_library: AnimationLibrary
var player_anim_ready := false

func _create_player_visual(state: PlayerState) -> Node3D:
	var glb_visual = _create_glb_player_visual(state)
	if glb_visual != null:
		return glb_visual
	var root := Node3D.new()
	root.name = "RedPlayer" if state.side == -1 else "BluePlayer"
	var uniform: Material = mf.materials.goalkeeper if state.role == GameConfig.PlayerRole.GOALKEEPER else (mf.materials.player_red if state.side == -1 else mf.materials.player_blue)
	var body := mf._mesh("Body", BoxMesh.new(), uniform, Vector3(0.0, 0.78, 0.0))
	body.mesh.size = Vector3(0.42, 0.82, 0.26)
	root.add_child(body)
	var head := mf._mesh("Head", SphereMesh.new(), mf.materials.skin, Vector3(0.0, 1.34, 0.0))
	head.mesh.radius = 0.22
	head.mesh.height = 0.42
	root.add_child(head)
	var hair := mf._mesh("Hair", SphereMesh.new(), mf.materials.hair, Vector3(0.0, 1.50, -0.02))
	hair.mesh.radius = 0.19
	hair.mesh.height = 0.18
	root.add_child(hair)
	for limb_name in ["ArmL", "ArmR", "LegL", "LegR"]:
		var limb_mat: Material = uniform if limb_name.begins_with("Arm") else mf.materials.boots
		var limb := mf._mesh(limb_name, BoxMesh.new(), limb_mat, Vector3.ZERO)
		limb.mesh.size = Vector3(0.13, 0.62, 0.13)
		root.add_child(limb)
	root.get_node("ArmL").position = Vector3(-0.32, 0.72, 0.0)
	root.get_node("ArmR").position = Vector3(0.32, 0.72, 0.0)
	root.get_node("LegL").position = Vector3(-0.13, 0.28, 0.0)
	root.get_node("LegR").position = Vector3(0.13, 0.28, 0.0)
	var marker := mf._mesh("SelectedRing", CylinderMesh.new(), mf.materials.selection, Vector3(0.0, 0.035, 0.0))
	marker.mesh.top_radius = 0.48
	marker.mesh.bottom_radius = 0.48
	marker.mesh.height = 0.025
	marker.visible = false
	root.add_child(marker)
	var next_marker := mf._mesh("NextRing", CylinderMesh.new(), mf.materials.selection_next, Vector3(0.0, 0.035, 0.0))
	next_marker.mesh.top_radius = 0.48
	next_marker.mesh.bottom_radius = 0.48
	next_marker.mesh.height = 0.025
	next_marker.visible = false
	root.add_child(next_marker)
	var power := mf._mesh("PowerRing", CylinderMesh.new(), mf.materials.power, Vector3(0.0, 0.07, 0.0))
	power.mesh.top_radius = 0.64
	power.mesh.bottom_radius = 0.64
	power.mesh.height = 0.025
	power.visible = false
	root.add_child(power)
	root.add_child(_jersey_label(1.85))
	return root

func _create_glb_player_visual(state: PlayerState):
	var root := Node3D.new()
	root.name = "RedGLBPlayer" if state.team_index == 0 else "BlueGLBPlayer"
	state.uses_glb = true
	state.node = root
	var marker := mf._mesh("SelectedRing", CylinderMesh.new(), mf.materials.selection, Vector3(0.0, 0.035, 0.0))
	marker.mesh.top_radius = 0.48
	marker.mesh.bottom_radius = 0.48
	marker.mesh.height = 0.025
	marker.visible = false
	root.add_child(marker)
	var next_marker := mf._mesh("NextRing", CylinderMesh.new(), mf.materials.selection_next, Vector3(0.0, 0.035, 0.0))
	next_marker.mesh.top_radius = 0.48
	next_marker.mesh.bottom_radius = 0.48
	next_marker.mesh.height = 0.025
	next_marker.visible = false
	root.add_child(next_marker)
	var power := mf._mesh("PowerRing", CylinderMesh.new(), mf.materials.power, Vector3(0.0, 0.07, 0.0))
	power.mesh.top_radius = 0.64
	power.mesh.bottom_radius = 0.64
	power.mesh.height = 0.025
	power.visible = false
	root.add_child(power)
	# Load the character mesh once and drive its skeleton with retargeted Mixamo clips.
	var model: Node3D = _instantiate_glb(GameConfig.PLAYER_ASSET_DIR + GameConfig.PLAYER_MESH_FILE)
	if model == null:
		push_warning("Player GLB mesh failed to load: %s" % (GameConfig.PLAYER_ASSET_DIR + GameConfig.PLAYER_MESH_FILE))
		state.uses_glb = false
		root.free()
		return null
	_place_glb_model(model)
	_apply_team_tint(model, state.team_index)
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

func _apply_team_tint(model: Node3D, team_index: int) -> void:
	var tint := Color(0.95, 0.10, 0.08) if team_index == 0 else Color(0.08, 0.36, 1.0)
	_apply_team_tint_recursive(model, tint)

func _apply_team_tint_recursive(node: Node, tint: Color) -> void:
	if node is MeshInstance3D and _is_uniform_mesh(node.name):
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
					base.albedo_color = base.albedo_color.lerp(tint, 0.62)
				mesh_instance.set_surface_override_material(surface_idx, mat)
	for child: Node in node.get_children():
		_apply_team_tint_recursive(child, tint)

func _is_uniform_mesh(node_name: StringName) -> bool:
	var n := String(node_name).to_lower()
	return n.contains("shirt") or n.contains("short") or n.contains("sock")

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
