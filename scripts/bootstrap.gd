extends Node

## Process entry point (the project's main scene). Decides what this process
## is before any presentation resource loads, then switches to that scene:
##
##   -- --bot                       -> AI bot service      (scenes/bot.tscn)
##   -- --server, or an export with
##      the dedicated_server feature -> match runtime      (scenes/server.tscn)
##   web build opened with ?netprobe -> WebSocket probe    (scenes/net_probe.tscn)
##   otherwise                       -> the 3D game        (scenes/main_3d.tscn)
##
## --bot is checked first: the bot and the match runtime ship in the same
## dedicated-server export, so the feature tag alone can't tell them apart.

const BOT_SCENE := "res://scenes/bot.tscn"
const SERVER_SCENE := "res://scenes/server.tscn"
const NET_PROBE_SCENE := "res://scenes/net_probe.tscn"
const GAME_SCENE := "res://scenes/main_3d.tscn"

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	var path := choose_scene(args, OS.has_feature("dedicated_server"), _web_query())
	if not ResourceLoader.exists(path):
		push_error("bootstrap: %s is not part of this build" % path)
		get_tree().quit(2)
		return
	get_tree().change_scene_to_file.call_deferred(path)

static func choose_scene(args: PackedStringArray, dedicated_server: bool, web_query: String) -> String:
	if args.has("--bot"):
		return BOT_SCENE
	if args.has("--server") or dedicated_server:
		return SERVER_SCENE
	if web_query.contains("netprobe"):
		return NET_PROBE_SCENE
	return GAME_SCENE

static func _web_query() -> String:
	if not OS.has_feature("web"):
		return ""
	return str(JavaScriptBridge.eval("window.location.search", true))
