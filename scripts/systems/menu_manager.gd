class_name MenuManager
extends Node

## Builds and drives all menu panels (main, how-to, settings, pause, full-time).
## `controller` is the match controller it asks to change game state / start a
## match; `settings` backs the settings panel. The controller owns the state
## machine and calls show_for_state()/refresh on transitions.

var controller
var settings: SettingsStore
var menu_layer: CanvasLayer
var menu_panels := {}
var fulltime_label: Label

func _build_menus() -> void:
	menu_layer = CanvasLayer.new()
	menu_layer.name = "MenuUI"
	menu_layer.layer = 2
	add_child(menu_layer)
	_build_main_menu()
	_build_howto_panel()
	_build_settings_panel()
	_build_pause_panel()
	_build_fulltime_panel()

func _make_panel(panel_name: String, dim := true) -> Control:
	var panel := Control.new()
	panel.name = panel_name
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	menu_layer.add_child(panel)
	if dim:
		var bg := ColorRect.new()
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.color = Color(0.02, 0.03, 0.06, 0.82)
		panel.add_child(bg)
	menu_panels[panel_name] = panel
	return panel

func _make_vbox(parent: Control) -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_CENTER)
	vb.grow_horizontal = Control.GROW_DIRECTION_BOTH
	vb.grow_vertical = Control.GROW_DIRECTION_BOTH
	vb.add_theme_constant_override("separation", 14)
	parent.add_child(vb)
	return vb

func _make_title(parent: Control, text: String, size := 64) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color(1.0, 0.93, 0.55))
	parent.add_child(label)
	return label

func _make_button(parent: Control, text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(320, 52)
	button.add_theme_font_size_override("font_size", 26)
	button.pressed.connect(handler)
	parent.add_child(button)
	return button

func _build_main_menu() -> void:
	var panel := _make_panel("main", false)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.05, 0.10, 1.0)
	panel.add_child(bg)
	var vb := _make_vbox(panel)
	_make_title(vb, "INAZUMA ELEVEN", 72)
	_make_title(vb, "GL", 32).add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	_make_button(vb, "Play Now", func() -> void: controller._set_game_state(GameConfig.GameState.MATCH_SETUP))
	_make_button(vb, "How to Play", func() -> void: controller._set_game_state(GameConfig.GameState.HOWTO))
	_make_button(vb, "Settings", func() -> void: controller._set_game_state(GameConfig.GameState.SETTINGS))
	_make_button(vb, "Quit", func() -> void: controller.get_tree().quit())

func _build_howto_panel() -> void:
	var panel := _make_panel("howto")
	var vb := _make_vbox(panel)
	_make_title(vb, "How to Play")
	var text := Label.new()
	text.add_theme_font_size_override("font_size", 22)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.text = "CHOOSE SIDES (Play Now)\nEach device moves its own chip: pad left stick / D-pad, keyboard A / D.\nLeft = RED, right = BLUE. One device per side; an empty side is the AI.\nPress START / Space to begin once a side is filled.\n\nKEYBOARD + MOUSE\nMove: W A S D    Aim: Mouse\nShoot: hold SPACE to charge, release to kick    Pass: E    Switch: Q\n\nCONTROLLER\nMove: Left stick    Aim: Right stick\nShoot: R1/RB (hold to charge)    Pass: A    Switch: L1/LB\n\nYour selected player keeps the ring — press Switch to jump to the nearest teammate.\nControl auto-follows whoever wins the ball.\nPress ESC to pause."
	vb.add_child(text)
	_make_button(vb, "Back", func() -> void: controller._set_game_state(controller.prev_menu_state))

func _build_pause_panel() -> void:
	var panel := _make_panel("pause")
	var vb := _make_vbox(panel)
	_make_title(vb, "Paused")
	_make_button(vb, "Resume", func() -> void: controller._set_game_state(GameConfig.GameState.PLAYING))
	_make_button(vb, "Restart Match", func() -> void: controller._start_match())
	_make_button(vb, "Settings", func() -> void: controller._set_game_state(GameConfig.GameState.SETTINGS))
	_make_button(vb, "Back to Menu", func() -> void: controller._set_game_state(GameConfig.GameState.MENU))

func _build_fulltime_panel() -> void:
	var panel := _make_panel("fulltime")
	var vb := _make_vbox(panel)
	fulltime_label = _make_title(vb, "FULL TIME")
	_make_button(vb, "Rematch", func() -> void: controller._start_match())
	_make_button(vb, "Back to Menu", func() -> void: controller._set_game_state(GameConfig.GameState.MENU))

func _build_settings_panel() -> void:
	var panel := _make_panel("settings")
	var vb := _make_vbox(panel)
	_make_title(vb, "Settings")

	var difficulty_opt := OptionButton.new()
	difficulty_opt.add_item("Easy")
	difficulty_opt.add_item("Normal")
	difficulty_opt.add_item("Hard")
	difficulty_opt.selected = settings.difficulty
	difficulty_opt.item_selected.connect(func(i: int) -> void: settings.difficulty = i; settings.apply(); settings.save())
	_settings_row(vb, "Difficulty", difficulty_opt)

	var length_opt := OptionButton.new()
	length_opt.add_item("2 min halves")
	length_opt.add_item("5 min halves")
	length_opt.add_item("10 min halves")
	length_opt.selected = GameConfig.MATCH_LENGTHS.find(settings.half_length) if GameConfig.MATCH_LENGTHS.has(settings.half_length) else 0
	length_opt.item_selected.connect(func(i: int) -> void: settings.half_length = GameConfig.MATCH_LENGTHS[i]; settings.save())
	_settings_row(vb, "Match Length", length_opt)

	var fs_check := CheckButton.new()
	fs_check.button_pressed = settings.fullscreen
	fs_check.toggled.connect(func(on: bool) -> void: settings.fullscreen = on; settings.apply(); settings.save())
	_settings_row(vb, "Fullscreen", fs_check)

	_settings_row(vb, "Master Volume", _make_volume_slider(func() -> float: return settings.vol_master, func(v: float) -> void: settings.vol_master = v))
	_settings_row(vb, "Music Volume", _make_volume_slider(func() -> float: return settings.vol_music, func(v: float) -> void: settings.vol_music = v))
	_settings_row(vb, "SFX Volume", _make_volume_slider(func() -> float: return settings.vol_sfx, func(v: float) -> void: settings.vol_sfx = v))

	_make_button(vb, "Back", func() -> void: controller._set_game_state(controller.prev_menu_state))

func _settings_row(vb: VBoxContainer, label_text: String, control: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(200, 0)
	label.add_theme_font_size_override("font_size", 22)
	row.add_child(label)
	control.custom_minimum_size = Vector2(220, 36)
	row.add_child(control)
	vb.add_child(row)

func _make_volume_slider(getter: Callable, setter: Callable) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = getter.call()
	slider.value_changed.connect(func(v: float) -> void: setter.call(v); settings.apply_volumes(); settings.save())
	return slider

## Shows only the panel matching the given GameConfig.GameState (hides the rest).
func show_for_state(state: int) -> void:
	for key in menu_panels:
		(menu_panels[key] as Control).visible = false
	var active: Control = null
	match state:
		GameConfig.GameState.INTRO:
			pass
		GameConfig.GameState.MENU:
			active = menu_panels.main
		GameConfig.GameState.HOWTO:
			active = menu_panels.howto
		GameConfig.GameState.SETTINGS:
			active = menu_panels.settings
		GameConfig.GameState.PAUSED:
			active = menu_panels.pause
		GameConfig.GameState.FULLTIME:
			active = menu_panels.fulltime
	if active != null:
		active.visible = true
		_focus_first_button(active)

func _focus_first_button(node: Control) -> bool:
	if node is Button and node.focus_mode != Control.FOCUS_NONE and node.visible and not (node as Button).disabled:
		(node as Button).grab_focus()
		return true
	for child in node.get_children():
		if child is Control:
			if _focus_first_button(child as Control):
				return true
	return false

func set_fulltime_text(text: String) -> void:
	if fulltime_label != null:
		fulltime_label.text = text
