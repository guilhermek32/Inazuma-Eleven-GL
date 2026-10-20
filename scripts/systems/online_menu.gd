class_name OnlineMenu
extends Node

## The "Play Online" screens (GameState.ONLINE), one panel in MenuManager's
## menu layer with three pages:
##   home     nickname, half length, Create room; room code + Join room;
##            Recent matches & leaderboard; Back. One status line shows
##            progress and errors (LobbyClient.describe()).
##   waiting  the created room's code, "waiting for opponent", Cancel.
##   stats    recent matches and the leaderboard from the results service.
## Create/join go through `lobby` (LobbyClient), then hand the grant to
## controller.start_online_from_lobby(); the controller enters the match on
## WELCOME (joiner) or on the kickoff event (creator, from the waiting page).
## A reply that arrives after the player left the page is ignored (the room
## then expires on the runtime's waiting deadline).
##
## Console lines for automation: "[online] room created <code> (match <id>)",
## "[online] joined room <code> (match <id>)", "[online] lobby error <code>:
## <message>", and MenuManager.log_layout()'s "[ui] online_<page> ..." line.

const HALF_LENGTHS := [30, 120, 300, 600]
const HALF_LABELS := ["30 s", "2 min", "5 min", "10 min"]
const NICKNAME_PATTERN := "^[A-Za-z0-9_.\\- ]{1,16}$"   # the lobby's own rule
const CODE_LENGTH := 6
const ERROR_COLOR := Color(1.0, 0.45, 0.4)
const INFO_COLOR := Color(0.8, 0.9, 1.0)

var controller
var settings: SettingsStore
var lobby: LobbyClient
var panel: Control
var page := "home"
var nickname_edit: LineEdit
var code_edit: LineEdit
var status_label: Label
var waiting_code_label: Label
var recent_label: Label
var board_label: Label
var _pages := {}
var _half_buttons: Array[Button] = []
var _action_buttons: Array[Button] = []
var _nickname_re := RegEx.create_from_string(NICKNAME_PATTERN)

func build(layer: CanvasLayer) -> void:
	lobby = LobbyClient.new()
	lobby.name = "LobbyClient"
	add_child(lobby)
	panel = Control.new()
	panel.name = "online"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.visible = false
	layer.add_child(panel)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.05, 0.10, 1.0)
	panel.add_child(bg)
	_build_home()
	_build_waiting()
	_build_stats()

## Shows `page_name` ("home", "waiting", "stats") and logs its layout.
func show_page(page_name: String) -> void:
	page = page_name
	for key in _pages:
		(_pages[key] as Control).visible = key == page_name
	if page_name == "home":
		_set_busy(lobby.is_busy())
		if nickname_edit.text == "":
			nickname_edit.grab_focus()
		else:
			_action_buttons[0].grab_focus()
	elif page_name == "stats":
		_load_stats()
	MenuManager.log_layout(_pages[page_name], "online_" + page_name)

## Back / Esc: waiting -> cancel the room wait, stats -> home, home -> main menu.
func back() -> void:
	match page:
		"waiting":
			controller.leave_online_wait()
			show_page("home")
		"stats":
			show_page("home")
		_:
			controller._set_game_state(GameConfig.GameState.MENU)

## The online connection ended before the match started (from the waiting page
## or while connecting after a join).
func show_connection_error(text: String) -> void:
	show_page("home")
	_show_status(text, true)

func _build_home() -> void:
	var vb := _page_box("home")
	_title(vb, "PLAY ONLINE", 56)
	nickname_edit = _line_edit("Your nickname", 16)
	nickname_edit.text = settings.online_nickname
	nickname_edit.set_meta("ui_id", "nickname")
	_row(vb, "Nickname", nickname_edit)
	var halves := HBoxContainer.new()
	halves.add_theme_constant_override("separation", 8)
	var group := ButtonGroup.new()
	for i in HALF_LENGTHS.size():
		var b := Button.new()
		b.text = HALF_LABELS[i]
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(72, 36)
		b.add_theme_font_size_override("font_size", 18)
		b.button_pressed = HALF_LENGTHS[i] == settings.online_half_length
		b.set_meta("ui_id", "half_%d" % HALF_LENGTHS[i])
		halves.add_child(b)
		_half_buttons.append(b)
	if group.get_pressed_button() == null:
		_half_buttons[1].button_pressed = true
	_row(vb, "Half length", halves)
	_action_buttons.append(_button(vb, "Create Room", _on_create, "create"))
	code_edit = _line_edit("Room code", CODE_LENGTH)
	code_edit.set_meta("ui_id", "code")
	code_edit.text_changed.connect(_on_code_changed)
	code_edit.text_submitted.connect(func(_t: String) -> void: _on_join())
	_row(vb, "Room code", code_edit)
	_action_buttons.append(_button(vb, "Join Room", _on_join, "join"))
	_action_buttons.append(_button(vb, "Recent Matches & Leaderboard", func() -> void: show_page("stats"), "stats"))
	_button(vb, "Back", back, "back")
	status_label = Label.new()
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.custom_minimum_size = Vector2(560, 32)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_font_size_override("font_size", 20)
	vb.add_child(status_label)

func _build_waiting() -> void:
	var vb := _page_box("waiting")
	_title(vb, "ROOM CODE", 40)
	waiting_code_label = _title(vb, "------", 110)
	waiting_code_label.add_theme_color_override("font_color", Color.WHITE)
	var info := Label.new()
	info.text = "Waiting for opponent...\nShare this code: the match starts as soon as they join."
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_theme_font_size_override("font_size", 22)
	vb.add_child(info)
	_button(vb, "Cancel", back, "cancel")

func _build_stats() -> void:
	var vb := _page_box("stats")
	_title(vb, "RECENT MATCHES", 36)
	recent_label = _text_block(vb)
	_title(vb, "LEADERBOARD", 36)
	board_label = _text_block(vb)
	_button(vb, "Refresh", _load_stats, "refresh")
	_button(vb, "Back", back, "back")

func _on_create() -> void:
	var nick := _checked_nickname()
	if nick == "" or lobby.is_busy():
		return
	_begin("Creating a room...")
	var reply: Dictionary = await lobby.create_room(nick, _half_length(), settings.online_player_id)
	if reply.error == "player_not_found":   # the lobby no longer knows this guest: start a new identity
		settings.online_player_id = ""
		reply = await lobby.create_room(nick, _half_length())
	_set_busy(false)
	if not _still_here("home"):
		return
	if not reply.ok:
		_fail(reply)
		return
	_remember(reply.body)
	print("[online] room created %s (match %s)" % [reply.body.room_code, reply.body.match_id])
	waiting_code_label.text = reply.body.room_code
	show_page("waiting")
	controller.start_online_from_lobby(lobby.ws_url(reply.body.ws_url), reply.body.token, true)

func _on_join() -> void:
	var nick := _checked_nickname()
	if nick == "" or lobby.is_busy():
		return
	var code := code_edit.text.strip_edges().to_upper()
	if code.length() != CODE_LENGTH:
		_show_status("Enter the %d-character room code." % CODE_LENGTH, true)
		code_edit.grab_focus()
		return
	_begin("Joining room %s..." % code)
	var reply: Dictionary = await lobby.join_room(code, nick, settings.online_player_id)
	if reply.error == "player_not_found":
		settings.online_player_id = ""
		reply = await lobby.join_room(code, nick)
	_set_busy(false)
	if not _still_here("home"):
		return
	if not reply.ok:
		_fail(reply)
		return
	_remember(reply.body)
	print("[online] joined room %s (match %s)" % [code, reply.body.match_id])
	_show_status("Connecting to the match...", false)
	_set_busy(true)   # until the match starts or the connection fails
	controller.start_online_from_lobby(lobby.ws_url(reply.body.ws_url), reply.body.token, false)

func _load_stats() -> void:
	if lobby.is_busy():
		return
	recent_label.text = "Loading..."
	board_label.text = ""
	var recent: Dictionary = await lobby.recent_matches(8)
	recent_label.text = format_recent(recent) if recent.ok else LobbyClient.describe(recent)
	var board: Dictionary = await lobby.leaderboard(8)
	board_label.text = format_board(board) if board.ok else LobbyClient.describe(board)

static func format_recent(reply: Dictionary) -> String:
	var lines: PackedStringArray = []
	for m in reply.body.get("items", []):
		var names := ["?", "?"]
		for p in m.get("players", []):
			names[clampi(int(p.team), 0, 1)] = str(p.nickname)
		var reason := "" if m.reason == "full_time" else "  (%s)" % m.reason
		lines.append("%s  %d - %d  %s%s" % [names[0], int(m.score[0]), int(m.score[1]), names[1], reason])
	return "\n".join(lines) if not lines.is_empty() else "No matches yet."

static func format_board(reply: Dictionary) -> String:
	var lines: PackedStringArray = []
	for r in reply.body.get("items", []):
		lines.append("%d. %s   %d pts   %d-%d-%d   GD %+d" % [int(r.rank), str(r.nickname), int(r.points),
				int(r.wins), int(r.draws), int(r.losses), int(r.goal_diff)])
	return "\n".join(lines) if not lines.is_empty() else "No players ranked yet."

func _checked_nickname() -> String:
	var nick := nickname_edit.text.strip_edges()
	if _nickname_re.search(nick) == null:
		_show_status("Nickname: 1-16 letters, digits, space, _ . -", true)
		nickname_edit.grab_focus()
		return ""
	return nick

func _half_length() -> int:
	for i in _half_buttons.size():
		if _half_buttons[i].button_pressed:
			return HALF_LENGTHS[i]
	return HALF_LENGTHS[1]

func _remember(grant: Dictionary) -> void:
	settings.online_nickname = str(grant.nickname)
	settings.online_player_id = str(grant.player_id)
	settings.online_half_length = _half_length()
	settings.save()

func _still_here(expected_page: String) -> bool:
	return controller.game_state == GameConfig.GameState.ONLINE and page == expected_page

func _begin(text: String) -> void:
	_set_busy(true)
	_show_status(text, false)

func _fail(reply: Dictionary) -> void:
	print("[online] lobby error %s: %s" % [reply.error, reply.message])
	_show_status(LobbyClient.describe(reply), true)

func _show_status(text: String, is_error: bool) -> void:
	status_label.text = text
	status_label.add_theme_color_override("font_color", ERROR_COLOR if is_error else INFO_COLOR)

func _set_busy(busy: bool) -> void:
	for b in _action_buttons:
		b.disabled = busy

func _on_code_changed(text: String) -> void:
	var upper := text.to_upper()
	if upper != text:
		var caret := code_edit.caret_column
		code_edit.text = upper
		code_edit.caret_column = caret

func _page_box(page_name: String) -> VBoxContainer:
	var holder := Control.new()
	holder.name = page_name
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(holder)
	_pages[page_name] = holder
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_CENTER)
	vb.grow_horizontal = Control.GROW_DIRECTION_BOTH
	vb.grow_vertical = Control.GROW_DIRECTION_BOTH
	vb.add_theme_constant_override("separation", 12)
	holder.add_child(vb)
	return vb

func _title(parent: Control, text: String, size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color(1.0, 0.93, 0.55))
	parent.add_child(label)
	return label

func _text_block(parent: Control) -> Label:
	var label := Label.new()
	label.custom_minimum_size = Vector2(620, 0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 19)
	parent.add_child(label)
	return label

func _button(parent: Control, text: String, handler: Callable, ui_id: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(320, 48)
	button.add_theme_font_size_override("font_size", 24)
	button.pressed.connect(handler)
	button.set_meta("ui_id", ui_id)
	parent.add_child(button)
	return button

func _line_edit(placeholder: String, max_length: int) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.max_length = max_length
	edit.custom_minimum_size = Vector2(300, 40)
	edit.add_theme_font_size_override("font_size", 22)
	return edit

func _row(vb: VBoxContainer, label_text: String, control: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(160, 0)
	label.add_theme_font_size_override("font_size", 22)
	row.add_child(label)
	row.add_child(control)
	vb.add_child(row)
