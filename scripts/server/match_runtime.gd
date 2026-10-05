class_name MatchRuntime
extends Node

## WebSocket front of the headless match runtime: connections, authentication
## and routing into MatchRooms, which it ticks on the fixed physics step.
##
## Connection lifecycle (ws://<host>:<port>/ws/game/<match_id>, behind the
## gateway wss://<domain>/ws/game/<match_id>):
##   1. TCP accept (capped at MAX_CONNECTIONS), WebSocket handshake within
##      HANDSHAKE_TIMEOUT_MS, path must be /ws/game/<id>.
##   2. The first message must be HELLO{token} within HELLO_TIMEOUT_MS. The
##      token must name this match and a team; the peer is then attached to
##      that room slot (replacing an older connection for the same slot).
##      Before HELLO a text "ping" is answered with "pong" (deployment probe).
##   3. INPUT goes to the room; PING is answered with PONG. Anything else, or
##      anything malformed or larger than NetProtocol.MAX_MESSAGE_BYTES,
##      closes the connection with an ERROR + close code.
## Outbound: snapshots are dropped while a peer's send buffer is over
## OUTBOUND_SOFT_LIMIT; a peer that stays congested for CONGESTION_LIMIT_MS
## is disconnected.
##
## Authentication: Milestone 2 accepts only development tokens "dev:<team>"
## and only when `allow_dev_tokens` is set (DEV_NO_AUTH=1 on a debug build);
## the room is then created on first use from `dev_config`. Signed lobby
## tokens and provisioned rooms replace this in Milestone 3.
##
## Logs are one JSON object per line on stdout.

signal peer_opened(peer_id: int, match_id: String)
signal peer_closed(peer_id: int)

const DEFAULT_PORT := 8910
const MAX_CONNECTIONS := 64
const MAX_ROOMS := 32
const HANDSHAKE_TIMEOUT_MS := 5000
# Generous: a browser may stall for seconds compiling shaders right after it connects.
const HELLO_TIMEOUT_MS := 15000
const MAX_QUEUED_PACKETS := 64
const OUTBOUND_SOFT_LIMIT := 64 * 1024
const CONGESTION_LIMIT_MS := 5000
const PATH_PREFIX := "/ws/game/"
const CLOSE_BAD_PATH := NetProtocol.CLOSE_BAD_PATH
const CLOSE_BAD_MESSAGE := NetProtocol.CLOSE_BAD_MESSAGE

var allow_dev_tokens := false
var dev_config := MatchConfig.new()

var _tcp := TCPServer.new()
var _next_id := 1
# peer_id -> {ws, since, open, match_id, team, congested_since}
var _peers := {}
var _rooms := {}   # match_id -> MatchRoom

func start(port := DEFAULT_PORT, bind_address := "*") -> Error:
	var err := _tcp.listen(port, bind_address)
	if err == OK:
		log_event("listening", {"port": port, "dev_tokens": allow_dev_tokens})
	else:
		log_event("listen_failed", {"port": port, "error": error_string(err)})
	return err

func stop() -> void:
	for id in _peers.keys():
		_drop(id, 1001, "shutting down")
	for room in _rooms.values():
		(room as MatchRoom).dispose()
	_rooms.clear()
	_tcp.stop()

func connection_count() -> int:
	return _peers.size()

func room(match_id: String) -> MatchRoom:
	return _rooms.get(match_id)

func _physics_process(delta: float) -> void:
	poll()
	for match_id in _rooms.keys():
		var r: MatchRoom = _rooms[match_id]
		r.step(delta)
		if r.is_done():
			_close_room(match_id)

## Accepts new connections, advances handshakes and reads messages. Never blocks.
func poll() -> void:
	while _tcp.is_connection_available():
		var conn := _tcp.take_connection()
		if _peers.size() >= MAX_CONNECTIONS:
			conn.disconnect_from_host()
			log_event("connection_refused", {"reason": "capacity"})
			continue
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = NetProtocol.MAX_MESSAGE_BYTES
		ws.max_queued_packets = MAX_QUEUED_PACKETS
		ws.accept_stream(conn)
		_peers[_next_id] = {"ws": ws, "since": Time.get_ticks_msec(), "open": false, "match_id": "", "team": -1, "congested_since": 0}
		_next_id += 1
	for id in _peers.keys():
		if _peers.has(id):
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
				entry.since = Time.get_ticks_msec()
				log_event("peer_open", {"peer": id, "match_id": match_id})
				peer_opened.emit(id, match_id)
			if entry.team < 0 and Time.get_ticks_msec() - int(entry.since) > HELLO_TIMEOUT_MS:
				_drop(id, NetProtocol.CLOSE_HELLO_TIMEOUT, "no HELLO received")
				return
			while ws.get_available_packet_count() > 0:
				var packet := ws.get_packet()
				_on_message(id, packet, ws.was_string_packet())
				if not _peers.has(id):
					return
		WebSocketPeer.STATE_CLOSED:
			_forget(id, ws.get_close_code())

func _on_message(id: int, packet: PackedByteArray, is_text: bool) -> void:
	var entry: Dictionary = _peers[id]
	if is_text:
		if entry.team < 0 and packet.get_string_from_utf8() == "ping":
			(entry.ws as WebSocketPeer).send_text("pong")
			return
		_reject(id, "unexpected text message")
		return
	if packet.size() > NetProtocol.MAX_MESSAGE_BYTES:
		_reject(id, "message too large")
		return
	var msg := NetProtocol.decode(packet)
	if msg.is_empty():
		_reject(id, "malformed message")
		return
	if entry.team < 0:
		if msg.type != NetProtocol.Type.HELLO:
			_reject(id, "expected HELLO")
			return
		_on_hello(id, msg.token)
		return
	var r: MatchRoom = _rooms.get(entry.match_id)
	match msg.type:
		NetProtocol.Type.INPUT:
			if r != null:
				r.on_input(id, msg)
		NetProtocol.Type.PING:
			send_to(id, NetProtocol.encode_pong(msg.client_ms, r.tick if r != null else 0), false)
		_:
			_reject(id, "unexpected message type %d" % msg.type)

func _on_hello(id: int, token: String) -> void:
	var entry: Dictionary = _peers[id]
	var claim := _authenticate(token, entry.match_id)
	if claim.is_empty():
		log_event("auth_failed", {"peer": id, "match_id": entry.match_id})
		_drop(id, NetProtocol.CLOSE_UNAUTHORIZED, "invalid token")
		return
	var r: MatchRoom = _rooms.get(entry.match_id)
	if r == null:
		if _rooms.size() >= MAX_ROOMS:
			_drop(id, NetProtocol.CLOSE_MATCH_OVER, "runtime at capacity")
			return
		r = MatchRoom.new(entry.match_id, dev_config, randi(), send_to, close_peer)
		_rooms[entry.match_id] = r
		log_event("room_created", {"match_id": entry.match_id})
	if r.state == MatchRoom.State.FINISHED:
		_drop(id, NetProtocol.CLOSE_MATCH_OVER, "match is over")
		return
	entry.team = claim.team
	var epoch := r.attach(claim.team, id)
	log_event("peer_joined", {"peer": id, "match_id": entry.match_id, "team": claim.team, "epoch": epoch})

## Returns {"team": int} for a valid token, {} otherwise.
func _authenticate(token: String, _match_id: String) -> Dictionary:
	if allow_dev_tokens and token.begins_with("dev:"):
		var team_str := token.substr(4)
		if team_str == "0" or team_str == "1":
			return {"team": int(team_str)}
	return {}

## Sends `bytes` to a peer. Droppable messages (snapshots) are skipped while
## the peer's outbound buffer is congested; a peer congested for too long is
## disconnected so one slow client can't make the runtime buffer without bound.
func send_to(peer_id: int, bytes: PackedByteArray, droppable: bool) -> void:
	if not _peers.has(peer_id):
		return
	var entry: Dictionary = _peers[peer_id]
	var ws: WebSocketPeer = entry.ws
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	if ws.get_current_outbound_buffered_amount() > OUTBOUND_SOFT_LIMIT:
		var now := Time.get_ticks_msec()
		if int(entry.congested_since) == 0:
			entry.congested_since = now
		elif now - int(entry.congested_since) > CONGESTION_LIMIT_MS:
			log_event("peer_too_slow", {"peer": peer_id})
			_drop(peer_id, NetProtocol.CLOSE_TOO_SLOW, "connection too slow")
			return
		if droppable:
			return
	else:
		entry.congested_since = 0
	ws.send(bytes)

func close_peer(peer_id: int, code: int, reason: String) -> void:
	_drop(peer_id, code, reason)

func _reject(id: int, reason: String) -> void:
	log_event("bad_message", {"peer": id, "reason": reason})
	_drop(id, CLOSE_BAD_MESSAGE, reason)

## Closes a connection (telling the client why with an ERROR message first)
## and detaches it from its room.
func _drop(id: int, code := 1000, reason := "") -> void:
	if not _peers.has(id):
		return
	var ws: WebSocketPeer = _peers[id].ws
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if code >= 4000:
			ws.send(NetProtocol.encode_error(code, reason))
		ws.close(code, reason)
	_forget(id, code)

func _forget(id: int, code: int) -> void:
	if not _peers.has(id):
		return
	var entry: Dictionary = _peers[id]
	_peers.erase(id)
	if entry.open:
		log_event("peer_closed", {"peer": id, "code": code})
		peer_closed.emit(id)
	var r: MatchRoom = _rooms.get(entry.match_id)
	if r != null and entry.team >= 0:
		r.detach(id)

func _close_room(match_id: String) -> void:
	var r: MatchRoom = _rooms[match_id]
	log_event("room_closed", {"match_id": match_id, "result": r.result})
	for t in 2:
		if r.is_attached(t):
			_drop(r.slots[t].peer, NetProtocol.CLOSE_MATCH_OVER, "match over")
	r.dispose()
	_rooms.erase(match_id)

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
