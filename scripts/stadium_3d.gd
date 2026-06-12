extends Node3D

var celebration_timer := 0.0

func trigger_celebration() -> void:
	celebration_timer = 1.5

func _process(delta: float) -> void:
	celebration_timer = maxf(0.0, celebration_timer - delta)
