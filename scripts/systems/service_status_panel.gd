class_name ServiceStatusPanel
extends PanelContainer

## Live up/down list of the online microservices, probed through the
## gateway's GET /api/status/v1/<id> (one HTTPRequest per service, every
## POLL_S while the panel is visible). Two layouts:
##   full     (Play Online home) one row per service: status dot, name,
##            technology and role; highlight(ids) marks the services the
##            focused/hovered action uses.
##   compact  (main menu) one line of dots and names plus "n/6 online".
## A service turns "down" only after DOWN_AFTER failed probes in a row (one
## slow answer, e.g. a page rendering at a few frames per second, is not an
## outage); until its first answer it stays grey ("checking").
## Console line for automation: "[services] gateway=up lobby=up ..." whenever
## a probe round finishes with a different result.

const POLL_S := 5.0
const TIMEOUT_S := 10.0
const DOWN_AFTER := 2
const SERVICES := [
	{"id": "gateway", "name": "API Gateway", "tech": "Caddy", "role": "routes /api, /ws and the web build"},
	{"id": "lobby", "name": "Lobby", "tech": "Python FastAPI + PostgreSQL", "role": "rooms, guests, match credentials"},
	{"id": "match-runtime", "name": "Match Runtime", "tech": "Godot (headless)", "role": "authoritative live matches"},
	{"id": "ai-bot", "name": "AI Bot", "tech": "Godot (headless)", "role": "online AI opponent"},
	{"id": "results", "name": "Results", "tech": "Python FastAPI + PostgreSQL", "role": "match history, leaderboard"},
	{"id": "recommendation", "name": "Recommendation", "tech": "Python FastAPI", "role": "Elo rating, AI level, rivals"},
]
const UP_COLOR := Color(0.35, 0.9, 0.45)
const DOWN_COLOR := Color(1.0, 0.4, 0.35)
const UNKNOWN_COLOR := Color(0.6, 0.6, 0.65)
const NAME_COLOR := Color(0.92, 0.95, 1.0)
const HIGHLIGHT_COLOR := Color(1.0, 0.85, 0.3)
const DIM_COLOR := Color(0.62, 0.68, 0.78)

var compact := false
var status := {}            # id -> true (up) / false (down); absent = not probed yet
var _base_url := ""
var _requests := {}         # id -> HTTPRequest
var _dots := {}             # id -> Panel (a round status light)
var _names := {}            # id -> Label
var _details := {}          # id -> Label
var _summary: Label
var _highlighted: Array = []
var _timer := 0.0
var _pending := 0
var _fails := {}            # id -> consecutive failed probes
var _last_logged := ""

func _init(p_compact := false) -> void:
	compact = p_compact

func _ready() -> void:
	_base_url = LobbyClient.origin_of(LobbyClient.default_base_url()) + "/api/status/v1/"
	add_theme_stylebox_override("panel", panel_style())
	if compact:
		_build_compact()
	else:
		_build_full()
	for s in SERVICES:
		var http := HTTPRequest.new()
		http.timeout = TIMEOUT_S
		add_child(http)
		http.request_completed.connect(_on_probe.bind(s.id))
		_requests[s.id] = http
	visibility_changed.connect(func() -> void: _timer = 0.0)   # probe as soon as it is shown

static func panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.09, 0.16, 0.94)
	style.border_color = Color(0.32, 0.46, 0.72)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(14)
	return style

func _process(delta: float) -> void:
	if not is_visible_in_tree() or _pending > 0:
		return
	_timer -= delta
	if _timer <= 0.0:
		_timer = POLL_S
		probe()

## Starts one probe round (all services in parallel).
func probe() -> void:
	for id in _requests:
		var http: HTTPRequest = _requests[id]
		if http.request(_base_url + id) == OK:
			_pending += 1
		else:
			_record(id, false)

## Marks the rows of `ids` (service ids) as used by the current action; [] clears.
func highlight(ids: Array) -> void:
	_highlighted = ids
	_refresh_rows()

func up_count() -> int:
	return status.values().count(true)

func _on_probe(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray, id: String) -> void:
	_pending -= 1
	_record(id, result == HTTPRequest.RESULT_SUCCESS and code == 200)
	if _pending == 0:
		var parts: PackedStringArray = []
		for s in SERVICES:
			parts.append("%s=%s" % [s.id, "checking" if not status.has(s.id) else ("up" if status[s.id] else "down")])
		var line := " ".join(parts)
		if line != _last_logged:
			_last_logged = line
			print("[services] " + line)

## One probe answer: up at once, down only after DOWN_AFTER failures in a row.
func _record(id: String, up: bool) -> void:
	_fails[id] = 0 if up else int(_fails.get(id, 0)) + 1
	if up:
		status[id] = true
	elif _fails[id] >= DOWN_AFTER:
		status[id] = false
	_refresh_rows()

func _refresh_rows() -> void:
	for s in SERVICES:
		var dot: Panel = _dots[s.id]
		(dot.get_theme_stylebox("panel") as StyleBoxFlat).bg_color = UNKNOWN_COLOR if not status.has(s.id) 				else (UP_COLOR if status[s.id] else DOWN_COLOR)
		var lit: bool = s.id in _highlighted
		var name_label: Label = _names[s.id]
		name_label.text = ("> " if lit and not compact else "") + s.name
		name_label.add_theme_color_override("font_color", HIGHLIGHT_COLOR if lit else NAME_COLOR)
		if _details.has(s.id):
			(_details[s.id] as Label).add_theme_color_override("font_color", HIGHLIGHT_COLOR if lit else DIM_COLOR)
	if _summary != null:
		_summary.text = "%d/%d online" % [up_count(), SERVICES.size()] if not status.is_empty() else "checking..."

func _build_full() -> void:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	add_child(vb)
	vb.add_child(_label("MICROSERVICES", 26, Color(1.0, 0.93, 0.55)))
	_summary = _label("checking...", 16, DIM_COLOR)
	vb.add_child(_summary)
	for s in SERVICES:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var dot := _dot(16)
		dot.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(dot)
		var text := VBoxContainer.new()
		text.add_theme_constant_override("separation", 0)
		var name_label := _label(s.name, 20, NAME_COLOR)
		text.add_child(name_label)
		var detail := _label("%s\n%s" % [s.tech, s.role], 14, DIM_COLOR)
		text.add_child(detail)
		row.add_child(text)
		vb.add_child(row)
		_dots[s.id] = dot
		_names[s.id] = name_label
		_details[s.id] = detail
	var hint := _label("Hover an action: the services it uses light up.", 14, DIM_COLOR)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(300, 0)
	vb.add_child(hint)
	_refresh_rows()

func _build_compact() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	add_child(row)
	row.add_child(_label("Online microservices:", 16, DIM_COLOR))
	for s in SERVICES:
		var dot := _dot(12)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(dot)
		var name_label := _label(s.name, 16, NAME_COLOR)
		row.add_child(name_label)
		_dots[s.id] = dot
		_names[s.id] = name_label
	_summary = _label("checking...", 16, DIM_COLOR)
	row.add_child(_summary)
	_refresh_rows()

func _dot(diameter: int) -> Panel:
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(diameter, diameter)
	var style := StyleBoxFlat.new()
	style.bg_color = UNKNOWN_COLOR
	style.set_corner_radius_all(diameter / 2)
	dot.add_theme_stylebox_override("panel", style)
	return dot

func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label
