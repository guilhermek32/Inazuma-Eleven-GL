extends Node3D

@export var target_path: NodePath
@export var follow_strength := 2.2
@export var max_offset := 5.0

var base_position := Vector3.ZERO

func _ready() -> void:
	base_position = global_position

func _process(delta: float) -> void:
	if target_path.is_empty():
		return
	var target := get_node_or_null(target_path) as Node3D
	if target == null:
		return
	var desired := base_position + Vector3(clampf(target.global_position.x * 0.18, -max_offset, max_offset), 0.0, clampf(target.global_position.z * 0.10, -max_offset, max_offset))
	global_position = global_position.lerp(desired, 1.0 - exp(-follow_strength * delta))
