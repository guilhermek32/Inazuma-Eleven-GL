class_name PitchBuilder
extends RefCounted

## Procedurally builds the grass pitch, all field-line markings and both goals.
## Wire `mf` and the target roots, then call `_build_pitch()` and `_build_goals()`.

var mf: MaterialFactory
var pitch_root: Node3D
var lines_root: Node3D
var goals_root: Node3D

func _build_pitch() -> void:
	var field_size := Vector2(GameConfig.FIELD_HALF_WIDTH * 2.0 * GameConfig.FIELD_SCALE, GameConfig.FIELD_HALF_HEIGHT * 2.0 * GameConfig.FIELD_SCALE)
	var pitch := mf._mesh("GrassPitch", BoxMesh.new(), mf.materials.grass, Vector3(0.0, -0.04, 0.0))
	pitch.mesh.size = Vector3(field_size.x, 0.08, field_size.y)
	pitch_root.add_child(pitch)
	for i in 10:
		if i % 2 == 0:
			var stripe := mf._mesh("GrassStripe%d" % i, BoxMesh.new(), mf.materials.grass_dark, Vector3.ZERO)
			stripe.mesh.size = Vector3(field_size.x / 10.0, 0.012, field_size.y)
			stripe.position = Vector3(-field_size.x * 0.5 + field_size.x * (float(i) + 0.5) / 10.0, 0.012, 0.0)
			pitch_root.add_child(stripe)
	_add_field_lines()

func _add_field_lines() -> void:
	var x := GameConfig.FIELD_BOUNDARY_X * GameConfig.FIELD_SCALE
	var z := GameConfig.FIELD_BOUNDARY_Y * GameConfig.FIELD_SCALE
	_add_line_segment(Vector3(-x, 0.06, -z), Vector3(x, 0.06, -z), 0.07, "SidelineTop")
	_add_line_segment(Vector3(-x, 0.06, z), Vector3(x, 0.06, z), 0.07, "SidelineBottom")
	_add_line_segment(Vector3(-x, 0.06, -z), Vector3(-x, 0.06, z), 0.07, "EndlineLeft")
	_add_line_segment(Vector3(x, 0.06, -z), Vector3(x, 0.06, z), 0.07, "EndlineRight")
	_add_line_segment(Vector3(0.0, 0.065, -z), Vector3(0.0, 0.065, z), 0.06, "HalfwayLine")
	_add_circle(Vector3.ZERO, GameConfig.CENTER_CIRCLE_RADIUS * GameConfig.FIELD_SCALE, 64, 0.055, "CenterCircle")
	_add_spot(Vector3(0.0, 0.055, 0.0), "CenterSpot")
	for side in [-1, 1]:
		_add_box_lines(side, GameConfig.PENALTY_AREA_WIDTH, GameConfig.PENALTY_AREA_HEIGHT, "Penalty")
		_add_box_lines(side, GameConfig.GOAL_AREA_WIDTH, GameConfig.GOAL_AREA_HEIGHT, "GoalArea")
		_add_penalty_arc(side)
		_add_spot(Vector3((GameConfig.FIELD_BOUNDARY_X - GameConfig.PENALTY_SPOT_DIST) * GameConfig.FIELD_SCALE * float(side), 0.055, 0.0), "PenaltySpot%d" % side)
	for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		_add_corner_arc(corner)
		_add_corner_flag(corner)

func _add_box_lines(side: int, depth: float, half_z: float, prefix: String) -> void:
	var xb := GameConfig.FIELD_BOUNDARY_X * GameConfig.FIELD_SCALE * float(side)
	var xi := (GameConfig.FIELD_BOUNDARY_X - depth) * GameConfig.FIELD_SCALE * float(side)
	var z := half_z * GameConfig.FIELD_SCALE
	_add_line_segment(Vector3(xb, 0.07, -z), Vector3(xi, 0.07, -z), 0.055, "%sA%d" % [prefix, side])
	_add_line_segment(Vector3(xb, 0.07, z), Vector3(xi, 0.07, z), 0.055, "%sB%d" % [prefix, side])
	_add_line_segment(Vector3(xi, 0.07, -z), Vector3(xi, 0.07, z), 0.055, "%sC%d" % [prefix, side])

func _add_penalty_arc(side: int) -> void:
	var radius := GameConfig.CENTER_CIRCLE_RADIUS * GameConfig.FIELD_SCALE
	var spot_x := (GameConfig.FIELD_BOUNDARY_X - GameConfig.PENALTY_SPOT_DIST) * GameConfig.FIELD_SCALE * float(side)
	var box_x := (GameConfig.FIELD_BOUNDARY_X - GameConfig.PENALTY_AREA_WIDTH) * GameConfig.FIELD_SCALE * float(side)
	var half_angle := acos(absf(box_x - spot_x) / radius)
	var facing := PI if side == 1 else 0.0
	_add_arc(Vector3(spot_x, 0.075, 0.0), radius, facing - half_angle, facing + half_angle, 18, 0.055, "PenaltyArc%d" % side)

func _add_corner_arc(corner: Vector2) -> void:
	var center := Vector3(GameConfig.FIELD_BOUNDARY_X * GameConfig.FIELD_SCALE * corner.x, 0.075, GameConfig.FIELD_BOUNDARY_Y * GameConfig.FIELD_SCALE * corner.y)
	var a_start := 0.0
	if corner == Vector2(1, -1):
		a_start = PI * 0.5
	elif corner == Vector2(1, 1):
		a_start = PI
	elif corner == Vector2(-1, 1):
		a_start = PI * 1.5
	_add_arc(center, GameConfig.CORNER_ARC_RADIUS * GameConfig.FIELD_SCALE, a_start, a_start + PI * 0.5, 8, 0.05, "CornerArc%d%d" % [corner.x, corner.y])

func _add_corner_flag(corner: Vector2) -> void:
	var x := GameConfig.FIELD_BOUNDARY_X * GameConfig.FIELD_SCALE * corner.x
	var z := GameConfig.FIELD_BOUNDARY_Y * GameConfig.FIELD_SCALE * corner.y
	var pole := mf._mesh("CornerPole%d%d" % [corner.x, corner.y], CylinderMesh.new(), mf.materials.goal, Vector3(x, 0.75, z))
	pole.mesh.height = 1.5
	pole.mesh.top_radius = 0.022
	pole.mesh.bottom_radius = 0.022
	pitch_root.add_child(pole)
	var flag := mf._mesh("CornerFlag%d%d" % [corner.x, corner.y], BoxMesh.new(), mf.materials.flag, Vector3(x - corner.x * 0.2, 1.36, z))
	flag.mesh.size = Vector3(0.38, 0.24, 0.02)
	pitch_root.add_child(flag)

func _add_spot(pos: Vector3, node_name: String) -> void:
	var spot := mf._mesh(node_name, CylinderMesh.new(), mf.materials.line, pos)
	spot.mesh.top_radius = 0.12
	spot.mesh.bottom_radius = 0.12
	spot.mesh.height = 0.02
	lines_root.add_child(spot)

func _add_circle(center: Vector3, radius: float, segments: int, width: float, node_name: String) -> void:
	for i in segments:
		var a0 := float(i) / float(segments) * TAU
		var a1 := float(i + 1) / float(segments) * TAU
		var p0 := center + Vector3(cos(a0) * radius, 0.075, sin(a0) * radius)
		var p1 := center + Vector3(cos(a1) * radius, 0.075, sin(a1) * radius)
		_add_line_segment(p0, p1, width, "%s%d" % [node_name, i])

func _add_arc(center: Vector3, radius: float, a_start: float, a_end: float, segments: int, width: float, node_name: String) -> void:
	for i in segments:
		var a0 := lerpf(a_start, a_end, float(i) / float(segments))
		var a1 := lerpf(a_start, a_end, float(i + 1) / float(segments))
		var p0 := center + Vector3(cos(a0) * radius, 0.0, sin(a0) * radius)
		var p1 := center + Vector3(cos(a1) * radius, 0.0, sin(a1) * radius)
		_add_line_segment(p0, p1, width, "%s%d" % [node_name, i])

func _add_line_segment(a: Vector3, b: Vector3, width: float, node_name: String) -> void:
	var mid := (a + b) * 0.5
	var len := a.distance_to(b)
	var line := mf._mesh(node_name, BoxMesh.new(), mf.materials.line, mid)
	line.mesh.size = Vector3(len, 0.035, width)
	line.rotation.y = atan2(a.z - b.z, b.x - a.x)
	lines_root.add_child(line)

func _build_goals() -> void:
	_add_goal(-1)
	_add_goal(1)

func _add_goal(side: int) -> void:
	var goal := Node3D.new()
	goal.name = "GoalLeft" if side == -1 else "GoalRight"
	goals_root.add_child(goal)
	var x := GameConfig.FIELD_BOUNDARY_X * GameConfig.FIELD_SCALE * float(side)
	var depth := GameConfig.GOAL_DEPTH * GameConfig.FIELD_SCALE * float(side)
	var half_w := GameConfig.GOAL_HALF_WIDTH * GameConfig.FIELD_SCALE
	var height := 1.8
	var post_a := _goal_post(Vector3(x, height * 0.5, -half_w))
	var post_b := _goal_post(Vector3(x, height * 0.5, half_w))
	var bar := _goal_bar(Vector3(x, height, 0.0), half_w * 2.0, Vector3(90.0, 0.0, 0.0))
	var back_bar := _goal_bar(Vector3(x + depth, height, 0.0), half_w * 2.0, Vector3(90.0, 0.0, 0.0))
	var top_depth_a := _goal_bar(Vector3(x + depth * 0.5, height, -half_w), absf(depth), Vector3(0.0, 0.0, 90.0))
	var top_depth_b := _goal_bar(Vector3(x + depth * 0.5, height, half_w), absf(depth), Vector3(0.0, 0.0, 90.0))
	goal.add_child(post_a)
	goal.add_child(post_b)
	goal.add_child(bar)
	goal.add_child(back_bar)
	goal.add_child(top_depth_a)
	goal.add_child(top_depth_b)
	var net_back := _net_panel("NetBack", Vector3(x + depth, height * 0.5, 0.0), Vector3(0.03, height, half_w * 2.0))
	goal.add_child(net_back)
	var net_top := _net_panel("NetTop", Vector3(x + depth * 0.5, height, 0.0), Vector3(absf(depth), 0.03, half_w * 2.0))
	goal.add_child(net_top)
	for net_side in [-1.0, 1.0]:
		var panel := _net_panel("NetSide%d" % net_side, Vector3(x + depth * 0.5, height * 0.5, half_w * net_side), Vector3(absf(depth), height, 0.03))
		goal.add_child(panel)

func _net_panel(panel_name: String, pos: Vector3, size: Vector3) -> MeshInstance3D:
	var panel := mf._mesh(panel_name, BoxMesh.new(), mf.materials.net, pos)
	panel.mesh.size = size
	panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return panel

func _goal_post(pos: Vector3) -> MeshInstance3D:
	var post := mf._mesh("Post", CylinderMesh.new(), mf.materials.goal, pos)
	post.mesh.height = 1.8
	post.mesh.top_radius = 0.055
	post.mesh.bottom_radius = 0.055
	return post

func _goal_bar(pos: Vector3, length: float, rot_degrees: Vector3) -> MeshInstance3D:
	var bar := mf._mesh("Bar", CylinderMesh.new(), mf.materials.goal, pos)
	bar.mesh.height = length
	bar.mesh.top_radius = 0.055
	bar.mesh.bottom_radius = 0.055
	bar.rotation_degrees = rot_degrees
	return bar
