class_name BallState
extends RefCounted

## Plain gameplay state for the ball. `owner_team`/`owner_index` identify the
## possessing player (-1 = loose); while owned, physics is skipped and the ball
## is glued to the owner's feet. `node`/`light` link to the 3D representation.

var x := 0.0
var y := 0.0
var vx := 0.0
var vy := 0.0
# Vertical flight: height above the turf and vertical speed, in WORLD units
# (the 2D plane stays normalized). 0 = rolling on the ground.
var h := 0.0
var vh := 0.0
# Team (0/1) that last kicked or carried the ball; decides who is awarded a
# restart when it leaves play. -1 = untouched since reset.
var last_touch_team := -1
var friction := GameConfig.BALL_FRICTION
var owner_team := -1
var owner_index := -1
var is_super_shot := false
var charging_power := 0.0
var spin := 0.0
# Signed Magnus curl (rad/s): bends the flight path while the ball is fast.
var curve := 0.0
# Active named special shot (Inazuma "hissatsu"): name flashed on the HUD and the
# element colour driving the ball's aura/light/trail. Empty name = ordinary ball.
var special_name := ""
var special_color := Color(1.0, 1.0, 1.0)
var node: Node3D
var light: OmniLight3D
var aura: MeshInstance3D
