class_name IntroManager
extends CanvasLayer

## Plays the startup intro sequence (play2 → intro + music → loop + prompt)
## before handing off to the main menu.

signal finished

const PATH_PLAY2 := "res://assets/intro/play2.ogv"
const PATH_INTRO := "res://assets/intro/intro.ogv"
const PATH_LOOP_OGV := "res://assets/intro/loop.ogv"
const PATH_LOOP_MP4 := "res://assets/intro/loop.mp4"
const PATH_MUSIC := "res://assets/intro/intro.mp3"

enum Phase { PLAY2, INTRO, LOOP }

var controller
var settings: SettingsStore
var audio: AudioManager

var _phase := Phase.PLAY2
var _waiting := false
var _root: Control
var _video: VideoStreamPlayer
var _hud_layer: CanvasLayer
var _music: AudioStreamPlayer
var _prompt_hud: PanelContainer
var _prompt_label: Label
var _prompt_pulse := 0.0

func _build() -> void:
	layer = 20
	visible = false
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color.BLACK
	_root.add_child(bg)
	_video = VideoStreamPlayer.new()
	_video.name = "IntroVideo"
	_video.set_anchors_preset(Control.PRESET_FULL_RECT)
	_video.expand = true
	_video.z_index = 0
	_video.finished.connect(_on_video_finished)
	_root.add_child(_video)
	_hud_layer = CanvasLayer.new()
	_hud_layer.name = "IntroHudLayer"
	_hud_layer.layer = 10
	_hud_layer.visible = false
	add_child(_hud_layer)
	var hud_root := Control.new()
	hud_root.name = "IntroHudRoot"
	hud_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(hud_root)
	var hud_layout := MarginContainer.new()
	hud_layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud_layout.add_theme_constant_override("margin_bottom", 52)
	hud_layout.add_theme_constant_override("margin_left", 24)
	hud_layout.add_theme_constant_override("margin_right", 24)
	hud_root.add_child(hud_layout)
	var hud_stack := VBoxContainer.new()
	hud_stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud_stack.alignment = BoxContainer.ALIGNMENT_END
	hud_layout.add_child(hud_stack)
	var hud_spacer := Control.new()
	hud_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hud_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_stack.add_child(hud_spacer)
	_prompt_hud = PanelContainer.new()
	_prompt_hud.name = "IntroPromptHud"
	_prompt_hud.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_prompt_hud.custom_minimum_size = Vector2(680, 64)
	_prompt_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt_hud.add_theme_stylebox_override("panel", _prompt_panel_style())
	hud_stack.add_child(_prompt_hud)
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_%s" % side, 28)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 14)
	_prompt_hud.add_child(margin)
	_prompt_label = Label.new()
	_prompt_label.text = "Pressione ENTER para iniciar o jogo"
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_font_size_override("font_size", 26)
	_prompt_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.45))
	_prompt_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	_prompt_label.add_theme_constant_override("outline_size", 5)
	margin.add_child(_prompt_label)
	_music = AudioStreamPlayer.new()
	_music.name = "IntroMusic"
	_music.bus = "Music"
	add_child(_music)
	set_process(false)

func _prompt_panel_style() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.06, 0.07, 0.10, 0.82)
	box.set_corner_radius_all(10)
	box.set_border_width_all(1)
	box.border_color = Color(1.0, 1.0, 1.0, 0.12)
	box.set_content_margin_all(0.0)
	return box

func _process(delta: float) -> void:
	if not _waiting or _prompt_label == null:
		return
	_prompt_pulse += delta * 2.4
	var t := 0.5 + 0.5 * sin(_prompt_pulse)
	_prompt_label.modulate = Color(1.0, 1.0, 1.0, 0.55 + 0.45 * t)

func start() -> void:
	if DisplayServer.get_name() == "headless":
		finished.emit()
		return
	if audio != null and audio.music_player != null:
		audio.music_player.stop()
	visible = true
	_waiting = false
	_hud_layer.visible = false
	set_process(false)
	_phase = Phase.PLAY2
	_play_video(PATH_PLAY2, false, false)

func _loop_path() -> String:
	if ResourceLoader.exists(PATH_LOOP_OGV):
		return PATH_LOOP_OGV
	return PATH_LOOP_MP4

func _play_video(path: String, loop: bool, mute: bool) -> void:
	if not ResourceLoader.exists(path):
		push_warning("Intro video missing: %s" % path)
		_advance_after_video()
		return
	_video.loop = loop
	_video.audio_track = -1 if mute else 0
	_video.stream = load(path) as VideoStream
	_video.play()

func _start_intro_music() -> void:
	if not ResourceLoader.exists(PATH_MUSIC):
		push_warning("Intro music missing: %s" % PATH_MUSIC)
		return
	var stream := load(PATH_MUSIC)
	if stream is AudioStreamMP3:
		stream.loop = true
	_music.stream = stream
	if settings != null:
		settings.apply_volumes()
	_music.play()

func _on_video_finished() -> void:
	if _video.loop:
		return
	_advance_after_video()

func _advance_after_video() -> void:
	match _phase:
		Phase.PLAY2:
			_phase = Phase.INTRO
			_start_intro_music()
			_play_video(PATH_INTRO, false, true)
		Phase.INTRO:
			_phase = Phase.LOOP
			_waiting = true
			_prompt_pulse = 0.0
			_show_loop_prompt()
			_play_video(_loop_path(), true, true)
		Phase.LOOP:
			pass

func _unhandled_input(event: InputEvent) -> void:
	if not _waiting:
		return
	var enter := false
	if event is InputEventKey:
		var key := event as InputEventKey
		enter = key.pressed and not key.echo and key.keycode in [KEY_ENTER, KEY_KP_ENTER]
	if enter or event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		_finish()

func _show_loop_prompt() -> void:
	_resize_hud_layer()
	_hud_layer.visible = true
	_prompt_label.modulate = Color.WHITE
	set_process(true)

func _resize_hud_layer() -> void:
	if _hud_layer == null or _hud_layer.get_child_count() == 0:
		return
	var vp_size := get_viewport().get_visible_rect().size
	var hud_root := _hud_layer.get_child(0) as Control
	hud_root.set_size(vp_size)
	hud_root.set_position(Vector2.ZERO)

func _finish() -> void:
	_waiting = false
	_hud_layer.visible = false
	set_process(false)
	_video.stop()
	_music.stop()
	visible = false
	if audio != null and audio.music_player != null:
		if settings != null:
			settings.apply_volumes()
		audio.music_player.play()
	finished.emit()
