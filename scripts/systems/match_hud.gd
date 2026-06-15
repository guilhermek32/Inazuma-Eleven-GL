class_name MatchHud
extends Node

## In-match heads-up display: the centred score and the match clock / kickoff
## countdown. update() is called every frame with the current match state.

var ui_layer: CanvasLayer
var score_label: Label
var timer_label: Label

func _build_ui() -> void:
	ui_layer = CanvasLayer.new()
	ui_layer.name = "ScoreboardUI"
	add_child(ui_layer)
	score_label = Label.new()
	score_label.name = "ScoreLabel"
	score_label.text = "0 - 0"
	score_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	score_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	score_label.position.y = 20.0
	score_label.add_theme_font_size_override("font_size", 56)
	score_label.add_theme_color_override("font_color", Color.WHITE)
	ui_layer.add_child(score_label)
	timer_label = Label.new()
	timer_label.name = "TimerLabel"
	timer_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	timer_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	timer_label.position.y = 88.0
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer_label.add_theme_font_size_override("font_size", 26)
	timer_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.25))
	ui_layer.add_child(timer_label)

func update(score_left: int, score_right: int, game_state: int, kickoff_timer: float, half_length: float, match_time: float, current_half: int) -> void:
	if score_label != null:
		score_label.text = "%d - %d" % [score_left, score_right]
	if timer_label != null:
		if game_state != GameConfig.GameState.PLAYING:
			timer_label.text = ""
		elif kickoff_timer > 0.0:
			timer_label.text = "Kickoff %.1f" % kickoff_timer
		else:
			var remaining := int(ceil(maxf(0.0, half_length - match_time)))
			timer_label.text = "%d:%02d  -  %s Half" % [remaining / 60, remaining % 60, "1st" if current_half == 1 else "2nd"]
