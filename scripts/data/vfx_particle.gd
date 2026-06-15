class_name VfxParticle
extends RefCounted

## A single confetti piece: its mesh node, world velocity and remaining life.

var node: MeshInstance3D
var velocity := Vector3.ZERO
var life := 0.0
var max_life := 0.0

func _init(p_node: MeshInstance3D, p_velocity: Vector3, p_life: float) -> void:
	node = p_node
	velocity = p_velocity
	life = p_life
	max_life = p_life
