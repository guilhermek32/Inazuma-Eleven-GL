extends Node

## Root of the headless match-runtime process (scenes/server.tscn). Loads no
## presentation: it only reads its configuration from the environment and runs
## the WebSocket listener, which ticks the match rooms.
##
## Environment:
##   MATCH_RUNTIME_PORT   listen port (default 8910)
##   DEV_NO_AUTH=1        accept "dev:<team>" tokens and create rooms on first
##                        use. Honoured only by debug builds (the editor binary),
##                        never by the exported release server the images run.

func _ready() -> void:
	var port := int(OS.get_environment("MATCH_RUNTIME_PORT")) if OS.has_environment("MATCH_RUNTIME_PORT") else MatchRuntime.DEFAULT_PORT
	var runtime := MatchRuntime.new()
	runtime.name = "MatchRuntime"
	runtime.allow_dev_tokens = OS.get_environment("DEV_NO_AUTH") == "1" and OS.is_debug_build()
	add_child(runtime)
	if runtime.start(port) != OK:
		get_tree().quit(1)
