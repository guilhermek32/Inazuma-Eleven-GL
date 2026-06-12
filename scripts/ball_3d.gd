extends Node3D

var velocity := Vector3.ZERO
var charge_power := 0.0
var is_super_shot := false

func set_visual_state(p_velocity: Vector3, p_charge_power: float, p_super_shot: bool) -> void:
	velocity = p_velocity
	charge_power = p_charge_power
	is_super_shot = p_super_shot
