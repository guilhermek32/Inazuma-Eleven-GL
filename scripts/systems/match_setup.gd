class_name MatchSetup
extends Node

## Two-step pre-match flow.
##
## STEP 1 - Choose Sides: each connected device (keyboard+mouse and every gamepad)
## gets a chip starting in the MIDDLE column and moves it toward TIME A (left) or
## TIME B (right) on its own input. A side holds one chip; an empty side is the AI.
## Confirm (pad START / keyboard Space-Enter / pad A) once a side is filled advances
## to step 2 -- it does NOT start the match.
##
## STEP 2 - Teams & Kits: formation + shirt/shorts/boots menus for both teams.
## Navigable by mouse, keyboard (arrows + Enter) or controller (D-pad + A). Press the
## "Comecar" button, pad START, or A on the button to kick off. ESC goes back to step 1.

const COL_RED := 0
const COL_MIDDLE := 1
const COL_BLUE := 2

const STICK_HI := 0.6
const STICK_LO := 0.3

const PHASE_SIDES := 0
const PHASE_KIT := 1

var controller
var sim: MatchSimulation

var setup_layer: CanvasLayer
var sides_page: VBoxContainer
var kit_page: VBoxContainer
var columns: Array[VBoxContainer] = []
var hint_label: Label
var start_button: Button
var phase := PHASE_SIDES

# Per-team config selectors (index 0 = Time A, 1 = Time B), read on _launch().
var cfg_form: Array[OptionButton] = []
var cfg_shirt: Array[OptionButton] = []
var cfg_shorts: Array[OptionButton] = []
var cfg_boots: Array[OptionButton] = []

# One entry per available device: {device, column, node, latched}.
var chips: Array = []
var _start_held_prev := false

func build() -> void:
	setup_layer = CanvasLayer.new()
	setup_layer.name = "SetupUI"
	setup_layer.layer = 2
	add_child(setup_layer)

	var panel := Control.new()
	panel.name = "setup"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	setup_layer.add_child(panel)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.05, 0.10, 1.0)
	panel.add_child(bg)

	_build_sides_page(panel)
	_build_kit_page(panel)
	setup_layer.visible = false

# --- Step 1: Choose Sides ----------------------------------------------------

func _build_sides_page(panel: Control) -> void:
	sides_page = _centered_vbox(panel)
	var title := _title(sides_page, "Choose Sides")
	title.add_theme_font_size_override("font_size", 56)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 28)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	sides_page.add_child(row)
	columns = [
		_make_column(row, "TIME A", Color(0.95, 0.30, 0.26)),
		_make_column(row, "MIDDLE", Color(0.7, 0.7, 0.75)),
		_make_column(row, "TIME B", Color(0.36, 0.55, 1.0)),
	]

	hint_label = Label.new()
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.add_theme_font_size_override("font_size", 20)
	hint_label.add_theme_color_override("font_color", Color(0.85, 0.88, 0.95))
	sides_page.add_child(hint_label)

func _make_column(parent: HBoxContainer, label_text: String, tint: Color) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(260, 280)
	box.add_theme_constant_override("separation", 10)
	box.alignment = BoxContainer.ALIGNMENT_BEGIN
	var header := Label.new()
	header.text = label_text
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.custom_minimum_size = Vector2(260, 0)
	header.add_theme_font_size_override("font_size", 28)
	header.add_theme_color_override("font_color", tint)
	box.add_child(header)
	parent.add_child(box)
	return box

# --- Step 2: Teams & Kits ----------------------------------------------------

func _build_kit_page(panel: Control) -> void:
	kit_page = _centered_vbox(panel)
	kit_page.visible = false
	var title := _title(kit_page, "Times & Uniformes")
	title.add_theme_font_size_override("font_size", 48)

	var cfg_row := HBoxContainer.new()
	cfg_row.add_theme_constant_override("separation", 40)
	cfg_row.alignment = BoxContainer.ALIGNMENT_CENTER
	kit_page.add_child(cfg_row)
	_make_team_config(cfg_row, "TIME A", GameConfig.DEFAULT_KIT_A)
	_make_team_config(cfg_row, "TIME B", GameConfig.DEFAULT_KIT_B)

	start_button = Button.new()
	start_button.text = "Começar"
	start_button.custom_minimum_size = Vector2(240, 50)
	start_button.add_theme_font_size_override("font_size", 24)
	start_button.add_theme_stylebox_override("normal", _start_box(false))
	start_button.add_theme_stylebox_override("hover", _start_box(true))
	start_button.add_theme_stylebox_override("pressed", _start_box(true))
	start_button.add_theme_stylebox_override("focus", _start_box(true))
	start_button.pressed.connect(_launch)
	var center := HBoxContainer.new()
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(start_button)
	kit_page.add_child(center)

	var kit_hint := Label.new()
	kit_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kit_hint.add_theme_font_size_override("font_size", 19)
	kit_hint.add_theme_color_override("font_color", Color(0.85, 0.88, 0.95))
	kit_hint.text = "D-pad / setas navegam  ·  A / Enter muda  ·  START ou Começar inicia  ·  ESC volta"
	kit_page.add_child(kit_hint)

func _make_team_config(parent: HBoxContainer, title_text: String, def_kit: Dictionary) -> void:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(320, 0)
	box.add_theme_constant_override("separation", 8)
	var header := Label.new()
	header.text = title_text
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 24)
	box.add_child(header)
	var form := _config_row(box, "Formação", _formation_names())
	form.selected = GameConfig.DEFAULT_FORMATION
	var shirt := _color_row(box, "Camisa")
	shirt.selected = def_kit.shirt
	var shorts := _color_row(box, "Bermuda")
	shorts.selected = def_kit.shorts
	var boots := _color_row(box, "Chuteira")
	boots.selected = def_kit.boots
	cfg_form.append(form)
	cfg_shirt.append(shirt)
	cfg_shorts.append(shorts)
	cfg_boots.append(boots)
	parent.add_child(box)

func _config_row(box: VBoxContainer, label_text: String, items: PackedStringArray) -> OptionButton:
	var row := _row_with_label(box, label_text)
	var opt := OptionButton.new()
	for it in items:
		opt.add_item(it)
	_style_option(opt)
	row.add_child(opt)
	return opt

# Like _config_row, but every item carries a colour-chip icon (used for the kit pieces).
func _color_row(box: VBoxContainer, label_text: String) -> OptionButton:
	var row := _row_with_label(box, label_text)
	var opt := OptionButton.new()
	for i in GameConfig.KIT_PALETTE.size():
		opt.add_icon_item(_palette_icon(GameConfig.KIT_PALETTE[i].color), GameConfig.KIT_PALETTE[i].name)
	_style_option(opt)
	row.add_child(opt)
	return opt

func _row_with_label(box: VBoxContainer, label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(110, 0)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 18)
	row.add_child(lbl)
	box.add_child(row)
	return row

# Shared rounded styling so the dropdowns read as proper buttons.
func _style_option(opt: OptionButton) -> void:
	opt.custom_minimum_size = Vector2(190, 38)
	opt.add_theme_font_size_override("font_size", 18)
	opt.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	opt.add_theme_stylebox_override("normal", _opt_box(false))
	opt.add_theme_stylebox_override("hover", _opt_box(true))
	opt.add_theme_stylebox_override("pressed", _opt_box(true))
	opt.add_theme_stylebox_override("focus", _opt_box(true))

func _opt_box(hl: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.18, 0.24, 0.34, 1.0) if hl else Color(0.11, 0.15, 0.23, 1.0)
	box.set_corner_radius_all(8)
	box.set_border_width_all(1)
	box.border_color = Color(1.0, 1.0, 1.0, 0.35) if hl else Color(1.0, 1.0, 1.0, 0.18)
	box.content_margin_left = 12.0
	box.content_margin_right = 12.0
	box.content_margin_top = 6.0
	box.content_margin_bottom = 6.0
	return box

func _start_box(hl: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.18, 0.62, 0.30, 1.0) if hl else Color(0.13, 0.48, 0.23, 1.0)
	box.set_corner_radius_all(10)
	box.set_border_width_all(2)
	box.border_color = Color(1.0, 1.0, 1.0, 0.5) if hl else Color(1.0, 1.0, 1.0, 0.22)
	box.content_margin_left = 18.0
	box.content_margin_right = 18.0
	box.content_margin_top = 8.0
	box.content_margin_bottom = 8.0
	return box

func _palette_icon(color: Color) -> ImageTexture:
	var img := Image.create(20, 20, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)

func _formation_names() -> PackedStringArray:
	var names := PackedStringArray()
	for form in GameConfig.FORMATIONS:
		names.append(form.name)
	return names

func _title(parent: VBoxContainer, text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color(1.0, 0.93, 0.55))
	parent.add_child(lbl)
	return lbl

func _centered_vbox(parent: Control) -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_CENTER)
	vb.grow_horizontal = Control.GROW_DIRECTION_BOTH
	vb.grow_vertical = Control.GROW_DIRECTION_BOTH
	vb.add_theme_constant_override("separation", 22)
	parent.add_child(vb)
	return vb

# --- Flow / lifecycle --------------------------------------------------------

func enter() -> void:
	phase = PHASE_SIDES
	if sides_page != null:
		sides_page.visible = true
	if kit_page != null:
		kit_page.visible = false
	for chip in chips:
		(chip.node as Node).queue_free()
	chips.clear()
	_add_chip(GameConfig.DEVICE_KBM, "Teclado + Mouse")
	var n := 1
	for pad in Input.get_connected_joypads():
		_add_chip(int(pad), "Controle %d" % n)
		n += 1
	_reparent_chips()
	_refresh_hint()
	_start_held_prev = false
	setup_layer.visible = true

func exit() -> void:
	setup_layer.visible = false

## ESC handler delegated by the controller: backs out of the kit page to Choose
## Sides. Returns false on the Choose Sides page so the controller goes to the menu.
func back() -> bool:
	if phase == PHASE_KIT:
		phase = PHASE_SIDES
		kit_page.visible = false
		sides_page.visible = true
		_refresh_hint()
		return true
	return false

func _add_chip(device: int, label_text: String) -> void:
	var chip := PanelContainer.new()
	chip.custom_minimum_size = Vector2(240, 56)
	var label := Label.new()
	label.text = label_text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 22)
	chip.add_child(label)
	chips.append({"device": device, "column": COL_MIDDLE, "node": chip, "latched": false})

func _reparent_chips() -> void:
	for chip in chips:
		var node := chip.node as Control
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		(columns[chip.column] as VBoxContainer).add_child(node)

## Per-frame tick. Step 1 moves chips and advances to step 2; step 2 waits for the
## pad START shortcut (mouse / keyboard / controller use the Comecar button).
func update(_delta: float) -> void:
	var start_edge := _pad_start_edge()
	if phase == PHASE_SIDES:
		var changed := false
		for chip in chips:
			var step := _device_step(chip)
			if step != 0 and _try_move(chip, step):
				changed = true
		if changed:
			_reparent_chips()
			_refresh_hint()
		if _filled_sides() > 0 and (start_edge or Input.is_action_just_pressed("ui_accept")):
			_goto_kit()
	elif start_edge:
		_launch()

func _goto_kit() -> void:
	phase = PHASE_KIT
	sides_page.visible = false
	kit_page.visible = true
	_refresh_hint()
	# Park focus on the first dropdown so a controller/keyboard can navigate the page.
	if not cfg_form.is_empty():
		cfg_form[0].call_deferred("grab_focus")

## Rising-edge detector for any pad's START button (also bound to ui_cancel, so we
## read it directly rather than through the InputMap).
func _pad_start_edge() -> bool:
	var held := false
	for pad in Input.get_connected_joypads():
		if Input.is_joy_button_pressed(int(pad), JOY_BUTTON_START):
			held = true
			break
	var edge := held and not _start_held_prev
	_start_held_prev = held
	return edge

## Returns -1 (toward TIME A), +1 (toward TIME B) or 0 for a chip's own device.
func _device_step(chip: Dictionary) -> int:
	var dev: int = chip.device
	if dev == GameConfig.DEVICE_KBM:
		if Input.is_action_just_pressed("move_left"):
			return -1
		if Input.is_action_just_pressed("move_right"):
			return 1
		return 0
	if Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_LEFT) and not chip.latched:
		chip.latched = true
		return -1
	if Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_RIGHT) and not chip.latched:
		chip.latched = true
		return 1
	var x := Input.get_joy_axis(dev, JOY_AXIS_LEFT_X)
	if absf(x) < STICK_LO:
		if not Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_LEFT) and not Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_RIGHT):
			chip.latched = false
	elif absf(x) >= STICK_HI and not chip.latched:
		chip.latched = true
		return -1 if x < 0.0 else 1
	return 0

func _try_move(chip: Dictionary, step: int) -> bool:
	var target: int = clampi(chip.column + step, COL_RED, COL_BLUE)
	if target == chip.column:
		return false
	if target != COL_MIDDLE and _chip_on_column(target) != null:
		return false   # side already occupied
	chip.column = target
	return true

func _chip_on_column(col: int) -> Variant:
	for chip in chips:
		if chip.column == col:
			return chip
	return null

func _filled_sides() -> int:
	var count := 0
	if _chip_on_column(COL_RED) != null:
		count += 1
	if _chip_on_column(COL_BLUE) != null:
		count += 1
	return count

func _refresh_hint() -> void:
	if hint_label == null:
		return
	var move_help := "Mover: stick / D-pad  ·  teclado A / D"
	if _filled_sides() > 0:
		hint_label.text = "%s\nSTART / Espaço / A avança para os uniformes  ·  ESC volta" % move_help
	else:
		hint_label.text = "%s\nLeve ao menos um dispositivo para um lado  ·  lado vazio = IA" % move_help

func _launch() -> void:
	var a: Variant = _chip_on_column(COL_RED)
	var b: Variant = _chip_on_column(COL_BLUE)
	sim.team_device[0] = a.device if a != null else GameConfig.DEVICE_AI
	sim.team_device[1] = b.device if b != null else GameConfig.DEVICE_AI
	for t in 2:
		sim.team_formation[t] = cfg_form[t].selected
		sim.team_kit[t] = {
			"shirt": GameConfig.KIT_PALETTE[cfg_shirt[t].selected].color,
			"shorts": GameConfig.KIT_PALETTE[cfg_shorts[t].selected].color,
			"boots": GameConfig.KIT_PALETTE[cfg_boots[t].selected].color,
		}
	controller._start_match()
