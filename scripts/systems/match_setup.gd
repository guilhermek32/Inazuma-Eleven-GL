class_name MatchSetup
extends Node

## Pre-match device-assignment screen. Each connected device (keyboard+mouse and
## every gamepad) gets a chip that starts in the MIDDLE column. A device moves its
## OWN chip toward RED (left) or BLUE (right) using its own input — a pad's left
## stick / D-pad, the keyboard's A / D. A side holds at most one chip; whoever
## lands on a side controls that team, an empty side is the AI. Once at least one
## side is filled, any device's confirm (pad START, keyboard Space/Enter) starts
## the match. The controller ticks update() each frame while in MATCH_SETUP.

const COL_RED := 0
const COL_MIDDLE := 1
const COL_BLUE := 2

const STICK_HI := 0.6   # left-stick magnitude that triggers a step
const STICK_LO := 0.3   # magnitude it must fall back under before another step

var controller
var sim: MatchSimulation

var setup_layer: CanvasLayer
var columns: Array[VBoxContainer] = []   # [red, middle, blue] chip containers
var hint_label: Label

# One entry per available device.
#   device: DEVICE_KBM or a pad id
#   column: COL_RED / COL_MIDDLE / COL_BLUE
#   node:   the chip Control
#   latched: stick debounce flag (pads only)
var chips: Array = []

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

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_CENTER)
	root.grow_horizontal = Control.GROW_DIRECTION_BOTH
	root.grow_vertical = Control.GROW_DIRECTION_BOTH
	root.add_theme_constant_override("separation", 24)
	panel.add_child(root)

	var title := Label.new()
	title.text = "Choose Sides"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color(1.0, 0.93, 0.55))
	root.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 28)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(row)
	columns = [
		_make_column(row, "RED", Color(0.95, 0.30, 0.26)),
		_make_column(row, "MIDDLE", Color(0.7, 0.7, 0.75)),
		_make_column(row, "BLUE", Color(0.36, 0.55, 1.0)),
	]

	hint_label = Label.new()
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.add_theme_font_size_override("font_size", 20)
	hint_label.add_theme_color_override("font_color", Color(0.85, 0.88, 0.95))
	root.add_child(hint_label)

	setup_layer.visible = false

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

func enter() -> void:
	# Rebuild the chip set from whatever is currently connected; everyone starts
	# in the middle.
	for chip in chips:
		(chip.node as Node).queue_free()
	chips.clear()
	_add_chip(GameConfig.DEVICE_KBM, "Keyboard + Mouse")
	var n := 1
	for pad in Input.get_connected_joypads():
		_add_chip(int(pad), "Controller %d" % n)
		n += 1
	_reparent_chips()
	_refresh_hint()
	setup_layer.visible = true

func exit() -> void:
	setup_layer.visible = false

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

## Per-frame: move each chip on its own device input, then check for confirm.
func update(_delta: float) -> void:
	var changed := false
	for chip in chips:
		var step := _device_step(chip)
		if step != 0 and _try_move(chip, step):
			changed = true
	if changed:
		_reparent_chips()
		_refresh_hint()
	if _filled_sides() > 0 and _confirm_pressed():
		_launch()

## Returns -1 (move toward red), +1 (toward blue) or 0 for a chip's own device.
func _device_step(chip: Dictionary) -> int:
	var dev: int = chip.device
	if dev == GameConfig.DEVICE_KBM:
		if Input.is_action_just_pressed("move_left"):
			return -1
		if Input.is_action_just_pressed("move_right"):
			return 1
		return 0
	# Gamepad: D-pad gives discrete steps; the left stick is debounced via latched.
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

## Moves a chip one column in `step` direction if allowed (a side holds one chip).
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

func _confirm_pressed() -> bool:
	if Input.is_action_just_pressed("ui_accept"):
		return true
	for pad in Input.get_connected_joypads():
		if Input.is_joy_button_pressed(int(pad), JOY_BUTTON_START):
			return true
	return false

func _refresh_hint() -> void:
	if hint_label == null:
		return
	var move_help := "Move: pad stick / D-pad  ·  keyboard A / D"
	if _filled_sides() > 0:
		hint_label.text = "%s\nPress START / Space to begin  ·  ESC to go back" % move_help
	else:
		hint_label.text = "%s\nPut at least one device on a side  ·  empty side = AI" % move_help

func _launch() -> void:
	var red: Variant = _chip_on_column(COL_RED)
	var blue: Variant = _chip_on_column(COL_BLUE)
	sim.team_device[0] = red.device if red != null else GameConfig.DEVICE_AI
	sim.team_device[1] = blue.device if blue != null else GameConfig.DEVICE_AI
	controller._start_match()
