class_name OnlineMenu
extends Node

## The "Play Online" screens (GameState.ONLINE), one panel in MenuManager's
## menu layer with three pages:
##   home     nickname, half length, Create room; room code + Join room;
##            AI level + Play vs AI (online); Recent matches & leaderboard;
##            Back. One status line shows progress and errors
##            (LobbyClient.describe()).
##   waiting  the created room's code, "waiting for opponent", Cancel.
##   stats    recent matches and the leaderboard from the results service.
## Beside every page, `services` (ServiceStatusPanel) shows each microservice
## live; hovering or focusing an action lights up the services it uses
## (ACTION_SERVICES), and the waiting/stats pages light up theirs. The home
## page also shows "Recommended for you" from the recommendation service:
## the player's Elo rating and form, the AI level to play next (one click
## selects it) and rivals at their level. Those reads go through `reads`, a
## second LobbyClient, so they never make a Create/Join answer "busy".
## Create/join go through `lobby` (LobbyClient), then hand the grant to
## controller.start_online_from_lobby(); the controller enters the match on
## WELCOME (joiner) or on the kickoff event (creator, from the waiting page).
## Play vs AI creates a "vs_ai" room: the lobby answers once the ai-bot
## service's bot holds team 1, so the player goes straight into the match
## (no waiting page) and kicks off on connecting.
## A reply that arrives after the player left the page is ignored (the room
## then expires on the runtime's waiting deadline).
##
## Console lines for automation: "[online] room created <code> (match <id>)",
## "[online] joined room <code> (match <id>)", "[online] vs AI room created
## <code> (match <id>, <level>)", "[online] lobby error <code>:
## <message>", "[online] recommendation level=<level> rating=<n>
## rivals=<n>", ServiceStatusPanel's "[services] ..." and
## MenuManager.log_layout()'s "[ui] online_<page> ..." line.

const HALF_LENGTHS := [30, 120, 300, 600]
const HALF_LABELS := ["30 s", "2 min", "5 min", "10 min"]
const AI_LEVELS := ["easy", "normal", "hard"]
const AI_LABELS := ["Easy", "Normal", "Hard"]
const NICKNAME_PATTERN := "^[A-Za-z0-9_.\\- ]{1,16}$"   # the lobby's own rule
const CODE_LENGTH := 6
const ERROR_COLOR := Color(1.0, 0.45, 0.4)
const INFO_COLOR := Color(0.8, 0.9, 1.0)
const DIM_COLOR := Color(0.62, 0.68, 0.78)
## Microservices behind each action / page (ServiceStatusPanel ids).
const ACTION_SERVICES := {
	"create": ["gateway", "lobby", "match-runtime"],
	"join": ["gateway", "lobby", "match-runtime"],
	"vs_ai": ["gateway", "lobby", "match-runtime", "ai-bot"],
	"stats": ["gateway", "results"],
	"use_level": ["gateway", "recommendation", "results"],
	"waiting": ["gateway", "lobby", "match-runtime"],
	"refresh": ["gateway", "results"],
}
const REASON_TEXT := {
	"first_match": "Your first online match: start here and get a feel for the game.",
	"build_confidence": "Even this level is a challenge right now: a few wins here will raise your rating.",
	"matched_to_rating": "The level closest to a 60% expected score: challenging but winnable.",
	"top_level": "You out-rate every bot: Hard is the best test left.",
}

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
var services: ServiceStatusPanel
var reads: LobbyClient           # background reads (recommendations): never blocks `lobby`
var rec_player_label: Label
var rec_level_label: Label
var rec_reason_label: Label
var rec_rivals_label: Label
var use_level_button: Button
var _rec_level := ""
var _pages := {}
var _half_buttons: Array[Button] = []
var _ai_buttons: Array[Button] = []
var _action_buttons: Array[Button] = []
var _nickname_re := RegEx.create_from_string(NICKNAME_PATTERN)

func build(layer: CanvasLayer) -> void:
	lobby = LobbyClient.new()
	lobby.name = "LobbyClient"
	add_child(lobby)
	reads = LobbyClient.new()
	reads.name = "ReadsClient"
	add_child(reads)
	panel = Control.new()
	panel.name = "online"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.visible = false
	layer.add_child(panel)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.05, 0.10, 1.0)
	panel.add_child(bg)
	services = ServiceStatusPanel.new()
	services.name = "services"
	_build_home()
	_build_waiting()
	_build_stats()
	services.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	services.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	services.grow_vertical = Control.GROW_DIRECTION_BOTH
	services.offset_left = -40
	services.offset_right = -40
	panel.add_child(services)

## Shows `page_name` ("home", "waiting", "stats") and logs its layout.
func show_page(page_name: String) -> void:
	page = page_name
	for key in _pages:
		(_pages[key] as Control).visible = key == page_name
	services.highlight(ACTION_SERVICES.get(page_name, []))
	if page_name == "home":
		_load_recommendations()
		_show_status("", false)
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
	_row(vb, "AI level", _toggle_row(AI_LABELS, AI_LEVELS.find(settings.online_ai_difficulty), "ai_", AI_LEVELS, _ai_buttons))
	_action_buttons.append(_button(vb, "Play vs AI (online)", _on_vs_ai, "vs_ai"))
	_action_buttons.append(_button(vb, "Recent Matches & Leaderboard", func() -> void: show_page("stats"), "stats"))
	_button(vb, "Back", back, "back")
	status_label = Label.new()
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.custom_minimum_size = Vector2(560, 32)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_font_size_override("font_size", 20)
	vb.add_child(status_label)
	_build_recommendations(_pages["home"])

## "Recommended for you": left of the home page (see the class doc).
func _build_recommendations(holder: Control) -> void:
	var box := PanelContainer.new()
	box.name = "recommendations"
	box.add_theme_stylebox_override("panel", ServiceStatusPanel.panel_style())
	box.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	box.grow_horizontal = Control.GROW_DIRECTION_END
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.offset_left = 40
	box.offset_right = 40
	holder.add_child(box)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	box.add_child(vb)
	_side_label(vb, "RECOMMENDED FOR YOU", 22, Color(1.0, 0.93, 0.55))
	_side_label(vb, "Recommendation microservice (Elo rating)", 14, DIM_COLOR)
	rec_player_label = _side_label(vb, "Loading...", 18, INFO_COLOR)
	_side_label(vb, "AI LEVEL TO PLAY NEXT", 16, DIM_COLOR)
	rec_level_label = _side_label(vb, "-", 22, Color.WHITE)
	rec_reason_label = _side_label(vb, "", 15, INFO_COLOR)
	use_level_button = Button.new()
	use_level_button.text = "Use this AI level"
	use_level_button.custom_minimum_size = Vector2(300, 40)
	use_level_button.add_theme_font_size_override("font_size", 20)
	use_level_button.disabled = true
	use_level_button.pressed.connect(_on_use_level)
	use_level_button.set_meta("ui_id", "use_level")
	_light_services(use_level_button, "use_level")
	vb.add_child(use_level_button)
	_side_label(vb, "RIVALS AT YOUR LEVEL", 16, DIM_COLOR)
	rec_rivals_label = _side_label(vb, "", 16, INFO_COLOR)

func _side_label(parent: Control, text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(320, 0)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label

func _load_recommendations() -> void:
	if reads.is_busy():
		return
	var reply: Dictionary = await reads.recommendations(settings.online_player_id)
	if reply.error == "invalid_player_id":   # a corrupted saved id: ask as a new player
		reply = await reads.recommendations()
	if not reply.ok:
		_rec_level = ""
		use_level_button.disabled = true
		rec_player_label.text = "Recommendations unavailable right now."
		rec_level_label.text = "-"
		rec_reason_label.text = "The recommendation service is down; everything else still works."
		rec_rivals_label.text = ""
		return
	var text := format_recommendation(reply.body)
	rec_player_label.text = text.player
	rec_level_label.text = text.level
	rec_reason_label.text = text.reason
	rec_rivals_label.text = text.rivals
	_rec_level = str(reply.body.ai_level.level)
	use_level_button.disabled = false
	print("[online] recommendation level=%s rating=%d rivals=%d" % [_rec_level, int(reply.body.player.rating),
			reply.body.get("rivals", []).size()])
	if page == "home":   # the panel grew: log the controls' new positions
		MenuManager.log_layout(_pages["home"], "online_home")

## The recommendation reply as the panel's texts: {player, level, reason, rivals}.
static func format_recommendation(body: Dictionary) -> Dictionary:
	var p: Dictionary = body.get("player", {})
	var played := int(p.get("played", 0))
	var player := "Rating %d%s\n%d played (%d-%d-%d)" % [int(p.get("rating", 1000)),
			"  (provisional)" if p.get("provisional", true) else "", played, int(p.get("wins", 0)),
			int(p.get("draws", 0)), int(p.get("losses", 0))]
	if str(p.get("form", "")) != "":
		player += "   form %s" % p.form
	var ai: Dictionary = body.get("ai_level", {})
	var level := "%s   %d%% expected score" % [str(ai.get("level", "normal")).to_upper(),
			roundi(float(ai.get("win_probability", 0.5)) * 100.0)]
	var reason: String = REASON_TEXT.get(str(ai.get("reason", "")), "")
	var lines: PackedStringArray = []
	for r in body.get("rivals", []):
		lines.append("%s   %d   (%d%%)" % [str(r.nickname), int(r.rating), roundi(float(r.win_probability) * 100.0)])
	var rivals := "\n".join(lines) if not lines.is_empty() else "No rated rivals yet: play a friend online."
	return {"player": player, "level": level, "reason": reason, "rivals": rivals}

func _on_use_level() -> void:
	var i := AI_LEVELS.find(_rec_level)
	if i >= 0:
		_ai_buttons[i].button_pressed = true
		_show_status("AI level set to %s (recommended)." % AI_LABELS[i], false)

## Hovering or focusing `control` lights up the services of ACTION_SERVICES[action].
func _light_services(control: Control, action: String) -> void:
	var on := func() -> void: services.highlight(ACTION_SERVICES[action])
	var off := func() -> void: services.highlight(ACTION_SERVICES.get(page, []))
	control.mouse_entered.connect(on)
	control.focus_entered.connect(on)
	control.mouse_exited.connect(off)
	control.focus_exited.connect(off)

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
	_subtitle(vb, "from the Results microservice")
	recent_label = _text_block(vb)
	_title(vb, "LEADERBOARD", 36)
	_subtitle(vb, "from the Results microservice (3 / 1 / 0 points)")
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

func _on_vs_ai() -> void:
	var nick := _checked_nickname()
	if nick == "" or lobby.is_busy():
		return
	var level := _ai_level()
	_begin("Starting a match against the AI (%s)..." % level)
	var reply: Dictionary = await lobby.create_room(nick, _half_length(), settings.online_player_id, level)
	if reply.error == "player_not_found":
		settings.online_player_id = ""
		reply = await lobby.create_room(nick, _half_length(), "", level)
	_set_busy(false)
	if not _still_here("home"):
		return
	if not reply.ok:
		_fail(reply)
		return
	settings.online_ai_difficulty = level
	_remember(reply.body)
	print("[online] vs AI room created %s (match %s, %s)" % [reply.body.room_code, reply.body.match_id, level])
	_show_status("Connecting to the match...", false)
	_set_busy(true)   # until the match starts or the connection fails
	controller.start_online_from_lobby(lobby.ws_url(reply.body.ws_url), reply.body.token, false)

func _ai_level() -> String:
	for i in _ai_buttons.size():
		if _ai_buttons[i].button_pressed:
			return AI_LEVELS[i]
	return "normal"

## A row of mutually exclusive toggle buttons; `pressed` (or the middle one
## when out of range) starts pressed. Their ui ids are id_prefix + ids[i].
func _toggle_row(labels: Array, pressed: int, id_prefix: String, ids: Array, into: Array[Button]) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var group := ButtonGroup.new()
	for i in labels.size():
		var b := Button.new()
		b.text = labels[i]
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(96, 36)
		b.add_theme_font_size_override("font_size", 18)
		b.button_pressed = i == (pressed if pressed >= 0 and pressed < labels.size() else labels.size() / 2)
		b.set_meta("ui_id", "%s%s" % [id_prefix, ids[i]])
		row.add_child(b)
		into.append(b)
	return row

func _load_stats() -> void:
	if lobby.is_busy():
		return
	recent_label.text = "Loading..."
	board_label.text = ""
	var recent: Dictionary = await lobby.recent_matches(8)
	recent_label.text = format_recent(recent) if recent.ok else LobbyClient.describe(recent)
	var board: Dictionary = await lobby.leaderboard(8)
	board_label.text = format_board(board) if board.ok else LobbyClient.describe(board)
	# The player may have gone Back meanwhile: the home buttons were disabled
	# while these requests were in flight.
	if page == "home":
		_set_busy(false)
	elif page == "stats":   # the lists grew: log the buttons' new positions
		MenuManager.log_layout(_pages["stats"], "online_stats")

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

func _subtitle(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", DIM_COLOR)
	parent.add_child(label)

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
	if ACTION_SERVICES.has(ui_id):
		_light_services(button, ui_id)
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
