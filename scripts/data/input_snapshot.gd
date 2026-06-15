class_name InputSnapshot
extends RefCounted

## Per-team human input for the current frame. `aim_vec` is an absolute field
## point when `aim_absolute` is true (mouse), otherwise a direction offset from
## the player (gamepad stick).

var axis := Vector2.ZERO
var shoot_held := false
var shoot_prev := false
var aim_vec := Vector2.ZERO
var aim_absolute := true
