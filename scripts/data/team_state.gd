class_name TeamState
extends RefCounted

## Everything the match tracks about one team: its players plus the per-team
## configuration (device, formation, kit) chosen on the setup screen and the
## human selection state. Index 0 = Time A (red, starts on -x), 1 = Time B.

var players: Array[PlayerState] = []
# Driving device: DEVICE_KBM, DEVICE_AI or a pad id (see GameConfig).
var device := GameConfig.DEVICE_AI
var formation := GameConfig.DEFAULT_FORMATION
# Kit colours: {"shirt": Color, "shorts": Color, "boots": Color}.
var kit := {}
# Player the human currently controls / the pre-computed Q-L1 switch target.
var selected_index := -1
var switch_candidate := -1
# Sampled human input for the current frame (untouched while device is the AI).
var input := InputSnapshot.new()

func is_human() -> bool:
	return device != GameConfig.DEVICE_AI
