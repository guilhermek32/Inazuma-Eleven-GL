class_name BallState
extends RefCounted

## Plain gameplay state for the ball. `owner_team`/`owner_index` identify the
## possessing player (-1 = loose); while owned, physics is skipped and the ball
## is glued to the owner's feet. `node`/`light` link to the 3D representation.

var x := 0.0
var y := 0.0
var vx := 0.0
var vy := 0.0
var friction := 0.98
var owner_team := -1
var owner_index := -1
var is_super_shot := false
var charging_power := 0.0
var spin := 0.0
var node: Node3D
var light: OmniLight3D
