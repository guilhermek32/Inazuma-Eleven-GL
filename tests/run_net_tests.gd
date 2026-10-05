extends SceneTree

## Headless network tests: runs the match runtime's WebSocket listener and
## real WebSocketPeer clients inside one process over loopback.
##
## Run: godot-4 --headless --path . --script res://tests/run_net_tests.gd
## Exits 0 when every check passes, 1 otherwise.

const PORT := 18910

var failures := 0
var runtime: MatchRuntime

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_test_bootstrap_dispatch()
	_test_match_id_parsing()
	runtime = MatchRuntime.new()
	root.add_child(runtime)
	_check(runtime.start(PORT, "127.0.0.1") == OK, "runtime listens on loopback")
	await _test_probe_round_trip()
	await _test_bad_path_rejected()
	await _test_bad_message_closes()
	runtime.stop()
	if failures == 0:
		print("ALL TESTS PASSED")
	else:
		print("%d TEST(S) FAILED" % failures)
	quit(1 if failures > 0 else 0)

func _check(cond: bool, test_name: String) -> void:
	if cond:
		print("PASS  %s" % test_name)
	else:
		failures += 1
		print("FAIL  %s" % test_name)

## Polls `client` (the runtime polls itself every frame) until it reaches
## `state` or `max_frames` pass. Returns whether the state was reached.
func _await_state(client: WebSocketPeer, state: int, max_frames := 300) -> bool:
	for i in max_frames:
		client.poll()
		if client.get_ready_state() == state:
			return true
		await process_frame
	return false

func _await_text(client: WebSocketPeer, max_frames := 300) -> String:
	for i in max_frames:
		client.poll()
		if client.get_available_packet_count() > 0:
			return client.get_packet().get_string_from_utf8()
		if client.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			return ""
		await process_frame
	return ""

func _url(path: String) -> String:
	return "ws://127.0.0.1:%d%s" % [PORT, path]

func _test_bootstrap_dispatch() -> void:
	var boot := preload("res://scripts/bootstrap.gd")
	_check(boot.choose_scene(PackedStringArray(), false, "") == boot.GAME_SCENE, "no flags boots the 3D game")
	_check(boot.choose_scene(PackedStringArray(["--server"]), false, "") == boot.SERVER_SCENE, "--server boots the match runtime")
	_check(boot.choose_scene(PackedStringArray(), true, "") == boot.SERVER_SCENE, "a dedicated-server export boots the match runtime")
	_check(boot.choose_scene(PackedStringArray(["--bot"]), true, "") == boot.BOT_SCENE, "--bot wins over the dedicated-server feature")
	_check(boot.choose_scene(PackedStringArray(), false, "?netprobe") == boot.NET_PROBE_SCENE, "?netprobe opens the connectivity probe")

func _test_match_id_parsing() -> void:
	_check(MatchRuntime.match_id_from_url("ws://h:1/ws/game/abc-123") == "abc-123", "match id parsed from the URL path")
	_check(MatchRuntime.match_id_from_url("/ws/game/abc?x=1") == "abc", "query string ignored")
	var rejected := ["ws://h/ws/game/", "ws://h/other/abc", "ws://h/ws/game/a/b", "ws://h/ws/game/%2e%2e", "ws://h/ws/game/" + "x".repeat(65)]
	var all_rejected := true
	for url in rejected:
		if MatchRuntime.match_id_from_url(url) != "":
			all_rejected = false
	_check(all_rejected, "malformed or foreign paths are rejected")

func _test_probe_round_trip() -> void:
	var client := WebSocketPeer.new()
	client.connect_to_url(_url("/ws/game/probe"))
	_check(await _await_state(client, WebSocketPeer.STATE_OPEN), "client completes the WebSocket handshake")
	client.send_text("ping")
	_check(await _await_text(client) == "pong", "runtime answers the probe")
	client.close()
	await _await_state(client, WebSocketPeer.STATE_CLOSED)
	for i in 30:
		await process_frame
	_check(runtime.connection_count() == 0, "closed connections are released")

func _test_bad_path_rejected() -> void:
	var client := WebSocketPeer.new()
	client.connect_to_url(_url("/elsewhere"))
	await _await_state(client, WebSocketPeer.STATE_CLOSED)
	_check(client.get_ready_state() == WebSocketPeer.STATE_CLOSED and client.get_close_code() == MatchRuntime.CLOSE_BAD_PATH, "a connection outside /ws/game/<id> is closed with 4404")

func _test_bad_message_closes() -> void:
	var client := WebSocketPeer.new()
	client.connect_to_url(_url("/ws/game/probe"))
	await _await_state(client, WebSocketPeer.STATE_OPEN)
	client.send_text("not a protocol message")
	await _await_state(client, WebSocketPeer.STATE_CLOSED)
	_check(client.get_close_code() == MatchRuntime.CLOSE_BAD_MESSAGE, "an unexpected message closes the connection with 4400")
