class_name MatchHud
extends Node

## In-match heads-up display: a broadcast-style top-centre scoreboard panel with
## red/blue team chips around the score and the match clock / kickoff countdown
## below. update() is called every frame with the current match state.

var ui_layer: CanvasLayer
var panel: PanelContainer
var score_label: Label
var timer_label: Label
var _last_score := Vector2i(-1, -1)
var _flash := 0.0

func _build_ui() -> void:
	ui_layer = CanvasLayer.new()
	ui_layer.name = "ScoreboardUI"
	add_child(ui_layer)

	panel = PanelContainer.new()
	panel.name = "ScorePanel"
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.position.y = 14.0
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _panel_style())
	ui_layer.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_%s" % side, 22)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 10)
	panel.add_child(margin)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 2)
	margin.add_child(col)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	col.add_child(row)

	row.add_child(_team_chip("RED", Color(0.72, 0.12, 0.10)))

	score_label = Label.new()
	score_label.name = "ScoreLabel"
	score_label.text = "0 - 0"
	score_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	score_label.add_theme_font_size_override("font_size", 50)
	score_label.add_theme_color_override("font_color", Color.WHITE)
	score_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	score_label.add_theme_constant_override("outline_size", 6)
	row.add_child(score_label)

	row.add_child(_team_chip("BLUE", Color(0.12, 0.20, 0.70)))

	timer_label = Label.new()
	timer_label.name = "TimerLabel"
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer_label.add_theme_font_size_override("font_size", 22)
	timer_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.45))
	timer_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	timer_label.add_theme_constant_override("outline_size", 5)
	col.add_child(timer_label)

func _panel_style() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.06, 0.07, 0.10, 0.82)
	box.set_corner_radius_all(10)
	box.set_border_width_all(1)
	box.border_color = Color(1.0, 1.0, 1.0, 0.12)
	box.set_content_margin_all(0.0)
	return box

func _team_chip(text: String, color: Color) -> Label:
	var chip := Label.new()
	chip.text = text
	chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	chip.add_theme_font_size_override("font_size", 24)
	chip.add_theme_color_override("font_color", Color.WHITE)
	chip.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.6))
	chip.add_theme_constant_override("outline_size", 3)
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(6)
	box.content_margin_left = 12.0
	box.content_margin_right = 12.0
	box.content_margin_top = 4.0
	box.content_margin_bottom = 4.0
	chip.add_theme_stylebox_override("normal", box)
	return chip

func update(score_left: int, score_right: int, game_state: int, kickoff_timer: float, half_length: float, match_time: float, current_half: int) -> void:
	if panel == null:
		return
	panel.visible = game_state == GameConfig.GameState.PLAYING or game_state == GameConfig.GameState.PAUSED
	if not panel.visible:
		return

	score_label.text = "%d - %d" % [score_left, score_right]
	# Brief goal flash when the score changes.
	var score := Vector2i(score_left, score_right)
	if _last_score != Vector2i(-1, -1) and score != _last_score:
		_flash = 0.6
	_last_score = score
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - get_process_delta_time())
		score_label.add_theme_color_override("font_color", Color.WHITE.lerp(Color(1.0, 0.92, 0.25), _flash / 0.6))
		score_label.pivot_offset = score_label.size * 0.5
		score_label.scale = Vector2.ONE * (1.0 + 0.18 * (_flash / 0.6))
	else:
		score_label.add_theme_color_override("font_color", Color.WHITE)
		score_label.scale = Vector2.ONE

	if game_state != GameConfig.GameState.PLAYING:
		timer_label.text = ""
	elif kickoff_timer > 0.0:
		timer_label.text = "Kickoff %.1f" % kickoff_timer
	else:
		var remaining := int(ceil(maxf(0.0, half_length - match_time)))
		timer_label.text = "%d:%02d   %s  Half" % [remaining / 60, remaining % 60, "1st" if current_half == 1 else "2nd"]
