extends Node

## Root of the headless ai-bot process (scenes/bot.tscn, started with
## `-- --bot`; the same dedicated-server export as the match runtime). Loads
## no presentation: it reads its configuration from the environment and runs
## the BotService (job API + bot sessions).
##
## Environment:
##   BOT_CONTROL_PORT    internal job API port (default 8920)
##   BOT_CONTROL_TOKEN   bearer token the lobby presents to the job API;
##                       unset = every job request is refused
##   BOT_MAX_SESSIONS    concurrent bot sessions hosted (default 8)
##   BOT_DECISION_LOG=0  silences the sampled bot_decision log lines

func _ready() -> void:
	var service := BotService.new()
	service.name = "BotService"
	service.max_sessions = _env_limit("BOT_MAX_SESSIONS", BotService.MAX_SESSIONS)
	service.log_decisions = OS.get_environment("BOT_DECISION_LOG") != "0"
	add_child(service)
	var token := OS.get_environment("BOT_CONTROL_TOKEN")
	if token == "":
		BotService.log_event("config_warning", {"reason": "BOT_CONTROL_TOKEN unset: every job request is refused"})
	BotService.log_event("bot_service_started", {"boot_id": service.boot_id, "max_sessions": service.max_sessions})
	var port := int(OS.get_environment("BOT_CONTROL_PORT")) if OS.has_environment("BOT_CONTROL_PORT") else BotService.DEFAULT_CONTROL_PORT
	if service.start_control(port, "*", token) != OK:
		get_tree().quit(1)

## A positive integer from the environment; unset or invalid keeps `fallback`.
static func _env_limit(name: String, fallback: int) -> int:
	var raw := OS.get_environment(name).strip_edges()
	if raw == "":
		return fallback
	if not raw.is_valid_int() or int(raw) <= 0:
		BotService.log_event("config_warning", {"reason": "%s must be a positive integer" % name, "value": raw, "using": fallback})
		return fallback
	return int(raw)
