class_name MatchRuntime
extends Node

## WebSocket front of the headless match runtime: connections, authentication
## and routing into MatchRooms, which it ticks on the fixed physics step.
##
## Connection lifecycle (ws://<host>:<port>/ws/game/<match_id>, behind the
## gateway wss://<domain>/ws/game/<match_id>):
##   1. TCP accept (capped at `max_connections`), WebSocket handshake within
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
## Authentication: HELLO carries a signed credential (MatchToken) issued by
## the lobby. It must verify against `match_secret` (signature, expiry,
## audience), name the match in the URL path, and match the reservation the
## lobby made for its team when it provisioned the room through the control
## API (RuntimeControlApi). Unprovisioned matches are refused with 4404,
## finished ones (TerminalRegistry, survives restarts) with 4410, anything
## else with 4401. Development tokens "dev:<team>" are honoured only when
## `allow_dev_tokens` is set (DEV_NO_AUTH=1 on a debug build); they attach to
## any existing room or create one on first use from `dev_config`.
##
## Finished provisioned matches: the terminal state is recorded and the
## result written to the ResultSpool (both under `data_dir`) before the room
## is freed; the spool delivers it to the results service in the background.
## Development rooms record neither.
##
## Logs are one JSON object per line on stdout.

signal peer_opened(peer_id: int, match_id: String)
signal peer_closed(peer_id: int)

const DEFAULT_PORT := 8910
# Defaults of the capacity limits; server_main overrides them from the
# environment (RUNTIME_MAX_CONNECTIONS, RUNTIME_MAX_ROOMS).
const MAX_CONNECTIONS := 64
const MAX_ROOMS := 32
const HANDSHAKE_TIMEOUT_MS := 5000
# Generous: a browser may stall for seconds compiling shaders right after it connects.
const HELLO_TIMEOUT_MS := 15000
# Godot refuses to queue more than max_queued_packets or outbound_buffer_size:
# both sit well above OUTBOUND_SOFT_LIMIT so congestion is seen (and handled)
# before sends start failing.
const MAX_QUEUED_PACKETS := 2048
const OUTBOUND_BUFFER_BYTES := 512 * 1024
# Connections that have not sent a valid HELLO yet. Capped separately so idle
# sockets can't occupy the slots players (and reconnects) need.
const MAX_PENDING_PEERS := 16
# A dropped peer is polled this long so its ERROR + close frame are flushed
# (a FIN, not a reset that the client would see as 1006).
const CLOSING_LINGER_MS := 1000
const OUTBOUND_SOFT_LIMIT := 64 * 1024
const CONGESTION_LIMIT_MS := 5000
const PATH_PREFIX := "/ws/game/"
const CLOSE_BAD_PATH := NetProtocol.CLOSE_BAD_PATH
const CLOSE_BAD_MESSAGE := NetProtocol.CLOSE_BAD_MESSAGE

const TERMINAL_MIN_RETENTION_S := 3600
const PRUNE_INTERVAL_MS := 60000

## Open player connections (any state) and live rooms (provisioned or dev)
## this process accepts; over the limit a connection is closed on accept and
## a provisioning request is answered 503.
var max_connections := MAX_CONNECTIONS
var max_rooms := MAX_ROOMS
var allow_dev_tokens := false
var dev_config := MatchConfig.new()
var match_secret := PackedByteArray()
## Random UUID per process start: lets the lobby detect a restarted runtime.
var boot_id := ""
var data_dir := ""
var registry := TerminalRegistry.new()
var spool := ResultSpool.new()
var control: ControlServer
var control_api: RuntimeControlApi
var _last_prune_ms := 0

var _tcp := TCPServer.new()
var _next_id := 1
# peer_id -> {ws, since, open, match_id, team, congested_since}
var _peers := {}
# Dropped peers still flushing their close frame: [{ws, since}].
var _closing: Array = []
var _rooms := {}   # match_id -> MatchRoom

func _init() -> void:
	boot_id = new_uuid()

## Opens the durable state under `dir` (terminal registry + result spool) and
## queues any results a previous process left undelivered.
func open_storage(dir: String) -> Error:
	data_dir = dir
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err == OK:
		err = _probe_writable(dir)
	if err != OK:
		log_event("storage_failed", {"dir": dir, "error": error_string(err)})
		return err
	registry.open(dir.path_join("terminal_matches.json"), now_unix())
	err = spool.open(dir.path_join("spool"))
	log_event("storage_opened", {"dir": dir, "terminal": registry.size(), "pending_results": spool.pending_ids().size()})
	return err

## An existing but read-only directory (e.g. a volume left owned by root) must
## fail loudly here: otherwise results and terminal ids would be silently lost.
static func _probe_writable(dir: String) -> Error:
	var probe := dir.path_join(".write_probe")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.close()
	return DirAccess.remove_absolute(probe)

## Starts the internal control API (see RuntimeControlApi) on its own port.
func start_control(port: int, bind_address := "*", token := "") -> Error:
	control_api = RuntimeControlApi.new(self, token)
	control = ControlServer.new()
	control.handler = control_api.handle
	var err := control.listen(port, bind_address)
	log_event("control_listening" if err == OK else "control_listen_failed", {"port": port, "auth": token != ""})
	return err

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
	if control != null:
		control.stop()

func connection_count() -> int:
	return _peers.size()

func room(match_id: String) -> MatchRoom:
	return _rooms.get(match_id)

func rooms() -> Dictionary:
	return _rooms

## Control API and result delivery: serviced per frame, outside the physics tick.
func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if control != null:
		control.poll(now)
	spool.poll(now)
	if now - _last_prune_ms > PRUNE_INTERVAL_MS:
		_last_prune_ms = now
		registry.prune(now_unix())

func _physics_process(delta: float) -> void:
	poll()
	for match_id in _rooms.keys():
		var r: MatchRoom = _rooms[match_id]
		r.step(delta)
		if r.state == MatchRoom.State.FINISHED and not r.recorded:
			record_finished(r)
		if r.is_done():
			_close_room(match_id)

## Accepts new connections, advances handshakes and reads messages. Never blocks.
func poll() -> void:
	while _tcp.is_connection_available():
		var conn := _tcp.take_connection()
		if _peers.size() >= max_connections or _pending_count() >= MAX_PENDING_PEERS:
			conn.disconnect_from_host()
			log_event("connection_refused", {"reason": "capacity" if _peers.size() >= max_connections else "pending_capacity"})
			continue
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = NetProtocol.MAX_MESSAGE_BYTES
		ws.outbound_buffer_size = OUTBOUND_BUFFER_BYTES
		ws.max_queued_packets = MAX_QUEUED_PACKETS
		ws.accept_stream(conn)
		_peers[_next_id] = {"ws": ws, "since": Time.get_ticks_msec(), "open": false, "match_id": "", "team": -1, "congested_since": 0}
		_next_id += 1
	for id in _peers.keys():
		if _peers.has(id):
			_poll_peer(id)
	_poll_closing()

func _pending_count() -> int:
	var n := 0
	for entry in _peers.values():
		if entry.team < 0:
			n += 1
	return n

func _poll_closing() -> void:
	var now := Time.get_ticks_msec()
	var still: Array = []
	for c in _closing:
		var ws: WebSocketPeer = c.ws
		ws.poll()
		if ws.get_ready_state() != WebSocketPeer.STATE_CLOSED and now - int(c.since) < CLOSING_LINGER_MS:
			still.append(c)
	_closing = still

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
	var match_id: String = entry.match_id
	var auth := _authorize(token, match_id)
	if auth.has("close"):
		log_event("auth_failed", {"peer": id, "match_id": match_id, "reason": auth.reason})
		_drop(id, int(auth.close), str(auth.reason))
		return
	var r: MatchRoom = _rooms.get(match_id)
	if r == null:   # only dev tokens get here: create the room on first use
		if _rooms.size() >= max_rooms:
			_drop(id, NetProtocol.CLOSE_MATCH_OVER, "runtime at capacity")
			return
		r = MatchRoom.new(match_id, dev_config, randi(), send_to, close_peer)
		_rooms[match_id] = r
		log_event("room_created", {"match_id": match_id, "dev": true})
	if r.state == MatchRoom.State.FINISHED:
		_drop(id, NetProtocol.CLOSE_MATCH_OVER, "match is over")
		return
	entry.team = auth.team
	var epoch := r.attach(auth.team, id)
	log_event("peer_joined", {"peer": id, "match_id": match_id, "team": auth.team, "epoch": epoch})

## Returns {"team": int} when the credential may attach to `match_id`, else
## {"close": code, "reason": text}.
func _authorize(token: String, match_id: String) -> Dictionary:
	if allow_dev_tokens and token.begins_with("dev:"):
		var team_str := token.substr(4)
		if team_str != "0" and team_str != "1":
			return {"close": NetProtocol.CLOSE_UNAUTHORIZED, "reason": "invalid token"}
		if not registry.lookup(match_id).is_empty():
			return {"close": NetProtocol.CLOSE_MATCH_OVER, "reason": "match is over"}
		return {"team": int(team_str)}
	if match_secret.is_empty():
		return {"close": NetProtocol.CLOSE_UNAUTHORIZED, "reason": "invalid token"}
	var v := MatchToken.verify(token, match_secret, now_unix())
	if not v.ok:
		return {"close": NetProtocol.CLOSE_UNAUTHORIZED, "reason": "invalid token (%s)" % v.error}
	var claims: Dictionary = v.claims
	if claims.match_id != match_id:
		return {"close": NetProtocol.CLOSE_UNAUTHORIZED, "reason": "token is for another match"}
	if not registry.lookup(match_id).is_empty():
		return {"close": NetProtocol.CLOSE_MATCH_OVER, "reason": "match is over"}
	var r: MatchRoom = _rooms.get(match_id)
	if r == null or not r.provisioned:
		return {"close": NetProtocol.CLOSE_UNKNOWN_MATCH, "reason": "unknown match"}
	var res: Dictionary = r.reservations[int(claims.team)]
	if res.is_empty() or res.reservation_id != claims.reservation_id or res.player_id != claims.player_id:
		return {"close": NetProtocol.CLOSE_UNAUTHORIZED, "reason": "no such reservation"}
	if r.expires_at > 0 and int(claims.exp) > r.expires_at:
		return {"close": NetProtocol.CLOSE_UNAUTHORIZED, "reason": "token outlives the match"}
	return {"team": int(claims.team)}

# --- provisioning (called by RuntimeControlApi) --------------------------------------

## Creates a provisioned room. The caller has checked capacity and conflicts.
func provision(match_id: String, config: MatchConfig, p_expires_at: int) -> MatchRoom:
	var r := MatchRoom.new(match_id, config, randi(), send_to, close_peer)
	r.provisioned = true
	r.expires_at = p_expires_at
	_rooms[match_id] = r
	log_event("room_provisioned", {"match_id": match_id, "half_length_s": config.half_length_s, "expires_at": p_expires_at})
	return r

## Cancels a room that hasn't kicked off; false once it is running.
func cancel(match_id: String) -> bool:
	var r: MatchRoom = _rooms.get(match_id)
	if r == null or not r.cancel():
		return false
	record_finished(r)
	return true

## Durably records a finished room: result into the spool first (full time or
## forfeit of a provisioned match), then its terminal state. Runs once per
## room, before the room is freed.
func record_finished(r: MatchRoom) -> void:
	if r.recorded:
		return
	r.recorded = true
	var reason := str(r.result.get("reason", ""))
	log_event("match_finished", {"match_id": r.match_id, "reason": reason, "winner": r.result.get("winner", -1),
			"score": [r.result.get("score_left", 0), r.result.get("score_right", 0)], "provisioned": r.provisioned})
	if not r.provisioned:
		return
	if reason == "full_time" or reason == "forfeit":
		spool.write(result_record(r))
	var retain := maxi(r.expires_at, now_unix() + TERMINAL_MIN_RETENTION_S)
	registry.record(r.match_id, state_name(r), reason, retain, now_unix())

## The self-contained result document delivered to the results service.
func result_record(r: MatchRoom) -> Dictionary:
	var players := []
	for t in 2:
		var res: Dictionary = r.reservations[t]
		players.append({"team": t, "player_id": res.get("player_id", ""), "nickname": res.get("nickname", "")})
	var winner: int = r.result.get("winner", -1)
	return {
		"match_id": r.match_id,
		"config_version": r.config.version,
		"config": r.config.to_dict(),
		"players": players,
		"score_left": r.result.score_left,
		"score_right": r.result.score_right,
		"winner": winner if winner >= 0 else null,
		"reason": r.result.reason,
		"stats": r.result.stats,
		"started_at": iso_time(r.started_unix) if r.started_unix > 0 else null,
		"finished_at": iso_time(r.finished_unix),
		"runtime_boot_id": boot_id,
	}

## Lifecycle name used by the control API: waiting, running, paused,
## completed (full time / forfeit) or cancelled.
static func state_name(r: MatchRoom) -> String:
	match r.state:
		MatchRoom.State.WAITING:
			return "waiting"
		MatchRoom.State.RUNNING:
			return "running"
		MatchRoom.State.PAUSED:
			return "paused"
	return "cancelled" if str(r.result.get("reason", "")) == "cancelled" else "completed"

static func now_unix() -> int:
	return int(Time.get_unix_time_from_system())

static func iso_time(unix: int) -> String:
	return Time.get_datetime_string_from_unix_time(unix) + "Z"

## Random version-4 UUID.
static func new_uuid() -> String:
	var b := Crypto.new().generate_random_bytes(16)
	b[6] = (b[6] & 0x0F) | 0x40
	b[8] = (b[8] & 0x3F) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]

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
	if ws.send(bytes) != OK:
		# The queue is full even so: a snapshot can wait, but an event, WELCOME or
		# baseline that can't be queued would desync the client, so drop it.
		if droppable:
			if int(entry.congested_since) == 0:
				entry.congested_since = Time.get_ticks_msec()
			return
		log_event("peer_too_slow", {"peer": peer_id, "reason": "send_failed"})
		_drop(peer_id, NetProtocol.CLOSE_TOO_SLOW, "connection too slow")

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
		_closing.append({"ws": ws, "since": Time.get_ticks_msec()})
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
	record_finished(r)   # no-op when already recorded; never free an unrecorded result
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
