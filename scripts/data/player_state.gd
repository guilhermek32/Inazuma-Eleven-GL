class_name PlayerState
extends RefCounted

## Plain gameplay state for a single player (no scene-tree behaviour).
## Positions live in the normalized 2D field space; `node`/`visual_model`/
## `animation_player` link to the 3D representation built by PlayerFactory.

var x := 0.0
var y := 0.0
var speed := 0.2
var start_x := 0.0
var start_y := 0.0
var facing_x := 1.0
var facing_y := 0.0
var side := 1
var role := GameConfig.PlayerRole.MIDFIELDER
var team_index := 0
var stun_timer := 0.0
var kick_power := 0.0
var hold_timer := 0.0
var is_moving := false
var is_targeting_ball := false
var node: Node3D
var uses_glb := false
var visual_model: Node3D
var animation_player: AnimationPlayer
var visual_state := ""
var action_timer := 0.0

func _init(p_x: float, p_y: float, p_speed: float, p_side: int, p_role: int) -> void:
	x = p_x
	y = p_y
	start_x = p_x
	start_y = p_y
	speed = p_speed
	side = p_side
	role = p_role
	team_index = 0 if p_side == -1 else 1
	facing_x = -float(p_side)

## Crossfades the GLB skeleton to a named looping clip (idle/run/gk_idle).
## No-op for the procedural box-figure fallback or an unknown clip.
func set_visual_state(state_name: String) -> void:
	if not uses_glb or animation_player == null:
		return
	if visual_state == state_name:
		return
	if not animation_player.has_animation(state_name):
		return
	visual_state = state_name
	animation_player.play(state_name, 0.15)

## Plays a one-shot action clip (kick/receive/tackle) and holds it for `duration`
## seconds before the per-frame visual update resumes idle/run selection.
func play_action(state_name: String, duration: float) -> void:
	if not uses_glb:
		return
	set_visual_state(state_name)
	action_timer = duration
