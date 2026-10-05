extends Control

## Connectivity probe for the deployment spike: opens a WebSocket to the match
## runtime through the same origin (so it exercises the gateway's TLS and
## /ws/game proxy), sends "ping" and reports whether "pong" came back.
## Reached by opening the web build with ?netprobe in the URL.

const TIMEOUT_MS := 8000

var _ws := WebSocketPeer.new()
var _label := Label.new()
var _started := 0
var _done := false

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.set_anchors_preset(Control.PRESET_CENTER)
	_label.add_theme_font_size_override("font_size", 28)
	add_child(_label)
	var url := probe_url()
	_report("Connecting to %s ..." % url)
	_started = Time.get_ticks_msec()
	var err := _ws.connect_to_url(url)
	if err != OK:
		_finish(false, "connect_to_url failed: %s" % error_string(err))

var _last_state := -1

func _process(_delta: float) -> void:
	if _done:
		return
	_ws.poll()
	if _ws.get_ready_state() != _last_state:
		_last_state = _ws.get_ready_state()
		print("probe state %d at %d ms" % [_last_state, Time.get_ticks_msec() - _started])
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			while _ws.get_available_packet_count() > 0:
				if _ws.get_packet().get_string_from_utf8() == "pong":
					_finish(true, "NET PROBE OK (%d ms)" % (Time.get_ticks_msec() - _started))
					return
			if not has_meta("sent"):
				set_meta("sent", true)
				_ws.send_text("ping")
		WebSocketPeer.STATE_CLOSED:
			_finish(false, "NET PROBE FAILED: closed (%d)" % _ws.get_close_code())
			return
	if Time.get_ticks_msec() - _started > TIMEOUT_MS:
		_finish(false, "NET PROBE FAILED: timeout")

## Same-origin ws(s)://host/ws/game/probe on the web; the local runtime otherwise.
static func probe_url() -> String:
	if OS.has_feature("web"):
		var proto := str(JavaScriptBridge.eval("window.location.protocol", true))
		var host := str(JavaScriptBridge.eval("window.location.host", true))
		return "%s//%s/ws/game/probe" % ["wss:" if proto == "https:" else "ws:", host]
	return "ws://127.0.0.1:%d/ws/game/probe" % MatchRuntime.DEFAULT_PORT

func _finish(ok: bool, text: String) -> void:
	_done = true
	_report(text)
	_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5) if ok else Color(1.0, 0.4, 0.4))
	_ws.close()

func _report(text: String) -> void:
	_label.text = text
	print(text)
