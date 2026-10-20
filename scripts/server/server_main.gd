extends Node

## Root of the headless match-runtime process (scenes/server.tscn). Loads no
## presentation: it only reads its configuration from the environment and runs
## the WebSocket listener (which ticks the match rooms), the internal control
## API and the result spool.
##
## Environment:
##   MATCH_RUNTIME_PORT     player WebSocket port (default 8910)
##   RUNTIME_CONTROL_PORT   internal control API port (default 8911)
##   RUNTIME_CONTROL_TOKEN  bearer token the lobby presents to the control API;
##                          unset = every control request is refused
##   MATCH_SECRET           HMAC key of the lobby-signed match credentials;
##                          unset = signed credentials are refused
##   RESULTS_URL            results service base URL (e.g. http://results:8000);
##                          unset = results are spooled but not delivered
##   RESULTS_INGEST_TOKEN   bearer token for the results service's ingestion
##   RUNTIME_DATA_DIR       durable state: terminal registry + result spool
##                          (default user://runtime)
##   RUNTIME_MAX_CONNECTIONS  open player connections accepted (default 64)
##   RUNTIME_MAX_ROOMS        live matches hosted (default 32)
##   DEV_NO_AUTH=1          also accept "dev:<team>" tokens and create rooms on
##                          first use. Honoured only by debug builds (the editor
##                          binary), never by the exported release server.

const DEFAULT_CONTROL_PORT := 8911
const DEFAULT_DATA_DIR := "user://runtime"

func _ready() -> void:
	var port := _env_int("MATCH_RUNTIME_PORT", MatchRuntime.DEFAULT_PORT)
	var runtime := MatchRuntime.new()
	runtime.name = "MatchRuntime"
	runtime.allow_dev_tokens = OS.get_environment("DEV_NO_AUTH") == "1" and OS.is_debug_build()
	runtime.max_connections = _env_limit("RUNTIME_MAX_CONNECTIONS", MatchRuntime.MAX_CONNECTIONS)
	runtime.max_rooms = _env_limit("RUNTIME_MAX_ROOMS", MatchRuntime.MAX_ROOMS)
	runtime.match_secret = OS.get_environment("MATCH_SECRET").to_utf8_buffer()
	if runtime.match_secret.is_empty():
		MatchRuntime.log_event("config_warning", {"reason": "MATCH_SECRET unset: signed credentials are refused"})
	var data_dir := OS.get_environment("RUNTIME_DATA_DIR")
	if runtime.open_storage(data_dir if data_dir != "" else DEFAULT_DATA_DIR) != OK:
		# No durable storage = finished results would be lost: refuse to serve.
		get_tree().quit(1)
		return
	runtime.spool.configure(OS.get_environment("RESULTS_URL"), OS.get_environment("RESULTS_INGEST_TOKEN"))
	add_child(runtime)
	MatchRuntime.log_event("runtime_started", {"boot_id": runtime.boot_id,
			"max_connections": runtime.max_connections, "max_rooms": runtime.max_rooms})
	if runtime.start(port) != OK:
		get_tree().quit(1)
		return
	var control_token := OS.get_environment("RUNTIME_CONTROL_TOKEN")
	if runtime.start_control(_env_int("RUNTIME_CONTROL_PORT", DEFAULT_CONTROL_PORT), "*", control_token) != OK:
		get_tree().quit(1)

static func _env_int(name: String, fallback: int) -> int:
	return int(OS.get_environment(name)) if OS.has_environment(name) else fallback

## A positive integer limit from the environment; unset or invalid (not a
## positive integer) keeps `fallback`, the latter with a config_warning.
static func _env_limit(name: String, fallback: int) -> int:
	var raw := OS.get_environment(name).strip_edges()
	if raw == "":
		return fallback
	if not raw.is_valid_int() or int(raw) <= 0:
		MatchRuntime.log_event("config_warning", {"reason": "%s must be a positive integer" % name, "value": raw, "using": fallback})
		return fallback
	return int(raw)
