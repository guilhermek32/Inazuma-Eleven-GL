class_name MatchHud
extends Node

## In-match heads-up display: a broadcast-style top-centre scoreboard panel with
## red/blue team chips around the score and the match clock / kickoff countdown
## below. update() is called every frame with the current match state.

var ui_layer: CanvasLayer
var panel: PanelContainer
var score_label: Label
var timer_label: Label
var banner: Label
var chip_a: Label
var chip_b: Label
# Thin sprint-stamina bars under the panel, one per team; hidden for AI teams.
var stamina_bars: Array[ProgressBar] = []
var _last_score := Vector2i(-1, -1)
var _flash := 0.0
var _banner_timer := 0.0
var _banner_dur := 0.0

func build_ui() -> void:
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

	chip_a = _team_chip("TIME A", Color(0.72, 0.12, 0.10))
	row.add_child(chip_a)

	score_label = Label.new()
	score_label.name = "ScoreLabel"
	score_label.text = "0 - 0"
	score_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	score_label.add_theme_font_size_override("font_size", 50)
	score_label.add_theme_color_override("font_color", Color.WHITE)
	score_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	score_label.add_theme_constant_override("outline_size", 6)
	row.add_child(score_label)

	chip_b = _team_chip("TIME B", Color(0.12, 0.20, 0.70))
	row.add_child(chip_b)

	timer_label = Label.new()
	timer_label.name = "TimerLabel"
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer_label.add_theme_font_size_override("font_size", 22)
	timer_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.45))
	timer_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	timer_label.add_theme_constant_override("outline_size", 5)
	col.add_child(timer_label)

	# Sprint stamina of each human team's selected player.
	var bar_row := HBoxContainer.new()
	bar_row.alignment = BoxContainer.ALIGNMENT_CENTER
	bar_row.add_theme_constant_override("separation", 24)
	col.add_child(bar_row)
	for t in 2:
		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = 1.0
		bar.value = 1.0
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(90.0, 5.0)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(0.0, 0.0, 0.0, 0.55)
		bg.set_corner_radius_all(2)
		bar.add_theme_stylebox_override("background", bg)
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color(0.35, 0.95, 0.45)
		fill.set_corner_radius_all(2)
		bar.add_theme_stylebox_override("fill", fill)
		bar.visible = false
		bar_row.add_child(bar)
		stamina_bars.append(bar)

	# Transient on-screen banner, full screen width so the text always centres horizontally.
	# Size and vertical position are set per message in show_banner().
	banner = Label.new()
	banner.name = "BannerLabel"
	banner.anchor_left = 0.0
	banner.anchor_right = 1.0
	banner.offset_left = 0.0
	banner.offset_right = 0.0
	banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	banner.grow_vertical = Control.GROW_DIRECTION_BOTH
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	banner.add_theme_color_override("font_color", Color.WHITE)
	banner.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.visible = false
	ui_layer.add_child(banner)

## Flashes a message for `duration` seconds; _tick_banner() pops it in and fades it out.
## `big` = large and centred (GOAL!/HALF TIME, shown while play is frozen); otherwise a
## small caption up near the scoreboard so the live ball/players stay visible (special
## shot names, which fire during slow-mo play).
func show_banner(text: String, color: Color, duration: float, big := true) -> void:
	if banner == null:
		return
	banner.text = text
	banner.add_theme_color_override("font_color", color)
	banner.add_theme_font_size_override("font_size", 84 if big else 40)
	banner.add_theme_constant_override("outline_size", 10 if big else 6)
	var vfrac := 0.46 if big else 0.17
	banner.anchor_top = vfrac
	banner.anchor_bottom = vfrac
	banner.modulate = Color(1.0, 1.0, 1.0, 1.0)
	_banner_dur = maxf(0.1, duration)
	_banner_timer = _banner_dur
	banner.visible = true

func _tick_banner(delta: float) -> void:
	if banner == null or _banner_timer <= 0.0:
		return
	_banner_timer = maxf(0.0, _banner_timer - delta)
	if _banner_timer <= 0.0:
		banner.visible = false
		return
	var t := _banner_timer / _banner_dur            # 1 at start -> 0 at end
	var appear := clampf((1.0 - t) / 0.18, 0.0, 1.0)
	var fade := clampf(t / 0.35, 0.0, 1.0)
	banner.pivot_offset = banner.size * 0.5
	banner.scale = Vector2.ONE * (0.72 + 0.28 * appear + 0.05 * sin(_banner_timer * 16.0))
	banner.modulate.a = minf(appear, fade)

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

## Recolours the scoreboard chips to the chosen team shirt colours.
func set_team_colors(col_a: Color, col_b: Color) -> void:
	if chip_a != null:
		var sa := chip_a.get_theme_stylebox("normal") as StyleBoxFlat
		if sa != null:
			sa.bg_color = col_a
	if chip_b != null:
		var sb := chip_b.get_theme_stylebox("normal") as StyleBoxFlat
		if sb != null:
			sb.bg_color = col_b

## Clears per-match state so a rematch doesn't inherit the previous score
## (which would trigger a spurious goal flash on the first update).
func reset() -> void:
	_last_score = Vector2i(-1, -1)
	_flash = 0.0
	_banner_timer = 0.0
	if banner != null:
		banner.visible = false

const RESTART_LABELS := {
	MatchSimulation.Restart.KICKOFF: "Kickoff",
	MatchSimulation.Restart.THROW_IN: "Throw-in",
	MatchSimulation.Restart.CORNER: "Corner",
	MatchSimulation.Restart.GOAL_KICK: "Goal kick",
	MatchSimulation.Restart.FREE_KICK: "Free kick",
}

func update(score_left: int, score_right: int, game_state: int, restart_timer: float, restart_type: int, half_length: float, match_time: float, current_half: int, delta: float) -> void:
	if panel == null:
		return
	# HUD animations run on wall-clock time so special-shot slow-mo
	# (Engine.time_scale < 1) doesn't stretch the banner/goal flash.
	delta /= maxf(Engine.time_scale, 0.05)
	_tick_banner(delta)
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
		_flash = maxf(0.0, _flash - delta)
		score_label.add_theme_color_override("font_color", Color.WHITE.lerp(Color(1.0, 0.92, 0.25), _flash / 0.6))
		score_label.pivot_offset = score_label.size * 0.5
		score_label.scale = Vector2.ONE * (1.0 + 0.18 * (_flash / 0.6))
	else:
		score_label.add_theme_color_override("font_color", Color.WHITE)
		score_label.scale = Vector2.ONE

	if game_state != GameConfig.GameState.PLAYING:
		timer_label.text = ""
		for bar in stamina_bars:
			bar.visible = false
	elif restart_timer > 0.0:
		timer_label.text = "%s %.1f" % [RESTART_LABELS.get(restart_type, "Kickoff"), restart_timer]
	else:
		var remaining := int(ceil(maxf(0.0, half_length - match_time)))
		timer_label.text = "%d:%02d   %s  Half" % [remaining / 60, remaining % 60, "1st" if current_half == 1 else "2nd"]

## Shows each human team's selected-player sprint stamina; pass -1 to hide a bar.
func update_stamina(values: Array) -> void:
	for t in mini(values.size(), stamina_bars.size()):
		var v: float = values[t]
		stamina_bars[t].visible = v >= 0.0
		if v >= 0.0:
			stamina_bars[t].value = v
