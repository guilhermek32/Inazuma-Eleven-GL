extends Node

## Root of the headless match-runtime process (scenes/server.tscn). Loads no
## presentation: it only reads its configuration from the environment and runs
## the WebSocket listener.
##
## Environment:
##   MATCH_RUNTIME_PORT   listen port (default 8910)

func _ready() -> void:
	var port := int(OS.get_environment("MATCH_RUNTIME_PORT")) if OS.has_environment("MATCH_RUNTIME_PORT") else MatchRuntime.DEFAULT_PORT
	var runtime := MatchRuntime.new()
	runtime.name = "MatchRuntime"
	add_child(runtime)
	if runtime.start(port) != OK:
		get_tree().quit(1)
