class_name MatchRuntime
extends Node

## WebSocket listener of the headless match runtime.
##
## Accepts browser/bot connections on ws://<host>:<port>/ws/game/<match_id>
## (behind the gateway, wss://<domain>/ws/game/<match_id>) with bounded
## resources: a connection cap, a handshake deadline and a maximum inbound
## message size. Milestone 0 answers the text probe "ping" with "pong" so the
## browser -> gateway -> runtime path can be verified end to end; the match
## protocol (HELLO/WELCOME/INPUT/SNAPSHOT, Milestone 2) plugs into
## _on_message() without changing the listener.
##
## Logs are one JSON object per line on stdout.

signal peer_opened(peer_id: int, match_id: String)
signal peer_closed(peer_id: int)

const DEFAULT_PORT := 8910
const MAX_CONNECTIONS := 64
const HANDSHAKE_TIMEOUT_MS := 5000
const MAX_INBOUND_BYTES := 4096
const MAX_QUEUED_PACKETS := 64
const PATH_PREFIX := "/ws/game/"
# Close codes in the 4000-4999 application range.
const CLOSE_BAD_PATH := 4404
const CLOSE_BAD_MESSAGE := 4400

var _tcp := TCPServer.new()
var _next_id := 1
# peer_id -> {"ws": WebSocketPeer, "since": int msec, "open": bool, "match_id": String}
var _peers := {}

func start(port := DEFAULT_PORT, bind_address := "*") -> Error:
	var err := _tcp.listen(port, bind_address)
	if err == OK:
		log_event("listening", {"port": port})
	else:
		log_event("listen_failed", {"port": port, "error": error_string(err)})
	return err

func stop() -> void:
	for id in _peers.keys():
		_drop(id, 1001, "shutting down")
	_tcp.stop()

func connection_count() -> int:
	return _peers.size()

func _process(_delta: float) -> void:
	poll()

## Accepts new connections, advances handshakes and reads messages. Called
## every frame; never blocks.
func poll() -> void:
	while _tcp.is_connection_available():
		var conn := _tcp.take_connection()
		if _peers.size() >= MAX_CONNECTIONS:
			conn.disconnect_from_host()
			log_event("connection_refused", {"reason": "capacity"})
			continue
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = MAX_INBOUND_BYTES
		ws.max_queued_packets = MAX_QUEUED_PACKETS
		ws.accept_stream(conn)
		_peers[_next_id] = {"ws": ws, "since": Time.get_ticks_msec(), "open": false, "match_id": ""}
		_next_id += 1
	for id in _peers.keys():
		_poll_peer(id)

func _poll_peer(id: int) -> void:
	var entry: Dictionary = _peers[id]
	var ws: WebSocketPeer = entry.ws
	ws.poll()
	match ws.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			if Time.get_ticks_msec() - int(entry.since) > HANDSHAKE_TIMEOUT_MS:
				log_event("handshake_timeout", {"peer": id})
				_drop(id)
		WebSocketPeer.STATE_OPEN:
			if not entry.open:
				var match_id := match_id_from_url(ws.get_requested_url())
				if match_id == "":
					log_event("bad_path", {"peer": id, "url": ws.get_requested_url()})
					_drop(id, CLOSE_BAD_PATH, "unknown path")
					return
				entry.open = true
				entry.match_id = match_id
				log_event("peer_open", {"peer": id, "match_id": match_id})
				peer_opened.emit(id, match_id)
			while ws.get_available_packet_count() > 0:
				var packet := ws.get_packet()
				_on_message(id, packet, ws.was_string_packet())
				if not _peers.has(id):
					return
		WebSocketPeer.STATE_CLOSED:
			if entry.open:
				log_event("peer_closed", {"peer": id, "code": ws.get_close_code()})
				peer_closed.emit(id)
			_peers.erase(id)

func _on_message(id: int, packet: PackedByteArray, is_text: bool) -> void:
	var ws: WebSocketPeer = _peers[id].ws
	if is_text and packet.get_string_from_utf8() == "ping":
		ws.send_text("pong")
		return
	log_event("bad_message", {"peer": id, "bytes": packet.size()})
	_drop(id, CLOSE_BAD_MESSAGE, "unexpected message")

func _drop(id: int, code := 1000, reason := "") -> void:
	if not _peers.has(id):
		return
	var entry: Dictionary = _peers[id]
	if entry.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		entry.ws.close(code, reason)
	if entry.open:
		peer_closed.emit(id)
	_peers.erase(id)

## "ws://host/ws/game/<id>" -> "<id>"; "" unless the path is exactly that shape
## with an id of 1-64 URL-safe characters.
static func match_id_from_url(url: String) -> String:
	var path := url
	var scheme := url.find("://")
	if scheme >= 0:
		var slash := url.find("/", scheme + 3)
		path = url.substr(slash) if slash >= 0 else "/"
	var query := path.find("?")
	if query >= 0:
		path = path.substr(0, query)
	if not path.begins_with(PATH_PREFIX):
		return ""
	var id := path.substr(PATH_PREFIX.length())
	var valid := RegEx.create_from_string("^[A-Za-z0-9_-]{1,64}$")
	return id if valid.search(id) != null else ""

static func log_event(event: String, fields := {}) -> void:
	var line := {"ts": Time.get_datetime_string_from_system(true), "svc": "match-runtime", "event": event}
	line.merge(fields)
	print(JSON.stringify(line))
