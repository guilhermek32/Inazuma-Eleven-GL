extends Node3D

var team_side := 1
var role := 0
var is_selected := false
var is_moving := false
var anim_time := 0.0

func set_visual_state(p_team_side: int, p_role: int, p_selected: bool, p_moving: bool, p_delta: float) -> void:
	team_side = p_team_side
	role = p_role
	is_selected = p_selected
	is_moving = p_moving
	if is_moving:
		anim_time += p_delta
