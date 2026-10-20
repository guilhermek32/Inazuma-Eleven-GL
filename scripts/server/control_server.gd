class_name ControlServer
extends RefCounted

## Minimal, bounded HTTP/1.1 listener: the match runtime's internal control
## API (lobby -> runtime) and, in tests, a fake results service.
##
## One request per connection, answered with `Connection: close` and a JSON
## body. Everything is nonblocking and polled by the owner (outside the
## physics tick); a misbehaving client can only hold one of MAX_CONNECTIONS
## slots for at most DEADLINE_MS:
##   - request line + headers + body together at most MAX_REQUEST_BYTES (413),
##   - Content-Length only (chunked / Transfer-Encoding -> 501),
##   - the whole request must arrive within DEADLINE_MS of accept (408),
##   - connections over MAX_CONNECTIONS are closed on accept.
## A request refused before it was fully read is answered, then its remaining
## input is drained for up to LINGER_MS before closing, so the client reads
## the error instead of a connection reset.
##
## `handler` is called as handler.call(method, path, headers, body) with the
## path stripped of its query string, header names lower-cased and the raw
## body bytes; it returns {"status": int, "body": Dictionary}.

const MAX_REQUEST_BYTES := 8192
const DEADLINE_MS := 2000
const MAX_CONNECTIONS := 16
const MAX_ACCEPT_PER_POLL := 32
const LINGER_MS := 500

const REASONS := {200: "OK", 201: "Created", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
		404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout", 409: "Conflict",
		413: "Payload Too Large", 422: "Unprocessable Entity", 500: "Internal Server Error",
		501: "Not Implemented", 503: "Service Unavailable"}

var handler: Callable
var port := 0

var _tcp := TCPServer.new()
# {tcp: StreamPeerTCP, data: PackedByteArray, out: PackedByteArray, sent: int,
#  deadline: int, linger_until: int (0 = close once sent)}
var _conns: Array[Dictionary] = []

func listen(p_port: int, bind_address := "*") -> Error:
	var err := _tcp.listen(p_port, bind_address)
	if err == OK:
		port = _tcp.get_local_port()
	return err

func is_listening() -> bool:
	return _tcp.is_listening()

func stop() -> void:
	for c in _conns:
		(c.tcp as StreamPeerTCP).disconnect_from_host()
	_conns.clear()
	_tcp.stop()

func connection_count() -> int:
	return _conns.size()

## Accepts, reads, dispatches and writes without ever blocking.
func poll(now_ms: int = Time.get_ticks_msec()) -> void:
	var accepted := 0
	while _tcp.is_connection_available() and accepted < MAX_ACCEPT_PER_POLL:
		accepted += 1
		var tcp := _tcp.take_connection()
		if _conns.size() >= MAX_CONNECTIONS:
			tcp.disconnect_from_host()
			continue
		_conns.append({"tcp": tcp, "data": PackedByteArray(), "out": PackedByteArray(), "sent": 0,
				"deadline": now_ms + DEADLINE_MS, "linger_until": 0})
	var keep: Array[Dictionary] = []
	for c in _conns:
		if _service(c, now_ms):
			keep.append(c)
	_conns = keep

## Returns false once the connection is finished and closed.
func _service(c: Dictionary, now_ms: int) -> bool:
	var tcp: StreamPeerTCP = c.tcp
	tcp.poll()
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false
	if not (c.out as PackedByteArray).is_empty():
		return _flush(c, now_ms)
	if now_ms > int(c.deadline):
		_respond(c, 408, {"error": "request timeout"})
		c.linger_until = now_ms + LINGER_MS
		return _flush(c, now_ms)
	var available := tcp.get_available_bytes()
	if available > 0:
		var room := MAX_REQUEST_BYTES + 1 - (c.data as PackedByteArray).size()
		var res := tcp.get_partial_data(mini(available, room))
		if res[0] == OK:
			var data: PackedByteArray = c.data   # packed arrays are values: copy, append, store back
			data.append_array(res[1])
			c.data = data
	var parsed := parse_request(c.data)
	if parsed.is_empty():
		return true   # incomplete, keep reading
	if parsed.has("error"):
		_respond(c, int(parsed.error), {"error": str(parsed.get("message", "bad request"))})
		c.linger_until = now_ms + LINGER_MS
	else:
		var reply: Dictionary = handler.call(parsed.method, parsed.path, parsed.headers, parsed.body)
		_respond(c, int(reply.get("status", 500)), reply.get("body", {}))
	return _flush(c, now_ms)

func _flush(c: Dictionary, now_ms: int) -> bool:
	var tcp: StreamPeerTCP = c.tcp
	var out: PackedByteArray = c.out
	if int(c.sent) < out.size():
		var res := tcp.put_partial_data(out.slice(int(c.sent)))
		if res[0] != OK:
			tcp.disconnect_from_host()
			return false
		c.sent = int(c.sent) + int(res[1])
	if now_ms > int(c.deadline) + DEADLINE_MS:
		tcp.disconnect_from_host()
		return false
	if int(c.sent) < out.size():
		return true
	if now_ms < int(c.linger_until):
		var n := tcp.get_available_bytes()
		if n > 0:
			tcp.get_partial_data(mini(n, 65536))   # discard the unread request
		return true
	tcp.disconnect_from_host()
	return false

func _respond(c: Dictionary, status: int, body: Dictionary) -> void:
	var payload := JSON.stringify(body).to_utf8_buffer()
	var head := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" \
			% [status, REASONS.get(status, "Status"), payload.size()]
	var out := head.to_utf8_buffer()
	out.append_array(payload)
	c.out = out
	c.sent = 0

## Parses a buffered request. Returns {} while it is incomplete,
## {"error": status, "message": ...} when it must be refused, or
## {method, path, headers, body} once complete.
static func parse_request(data: PackedByteArray) -> Dictionary:
	var end := _find_header_end(data)
	if end < 0:
		if data.size() > MAX_REQUEST_BYTES:
			return {"error": 413, "message": "request too large"}
		return {}
	var head := data.slice(0, end).get_string_from_ascii()
	var lines := head.split("\r\n")
	var request_line := lines[0].split(" ")
	if request_line.size() != 3 or not request_line[2].begins_with("HTTP/1."):
		return {"error": 400, "message": "bad request line"}
	var headers := {}
	for i in range(1, lines.size()):
		var colon := lines[i].find(":")
		if colon <= 0:
			return {"error": 400, "message": "bad header"}
		headers[lines[i].substr(0, colon).strip_edges().to_lower()] = lines[i].substr(colon + 1).strip_edges()
	if headers.has("transfer-encoding"):
		return {"error": 501, "message": "only Content-Length bodies are supported"}
	var length := 0
	if headers.has("content-length"):
		var cl: String = headers["content-length"]
		if not cl.is_valid_int() or int(cl) < 0:
			return {"error": 400, "message": "bad Content-Length"}
		# Checked before any arithmetic: a huge value would clamp to INT64_MAX and
		# wrap body_start + length negative, slipping past both checks below.
		if cl.length() > 7 or int(cl) > MAX_REQUEST_BYTES:
			return {"error": 413, "message": "request too large"}
		length = int(cl)
	var body_start := end + 4
	if body_start + length > MAX_REQUEST_BYTES:
		return {"error": 413, "message": "request too large"}
	if data.size() < body_start + length:
		return {}
	var path: String = request_line[1]
	var query := path.find("?")
	if query >= 0:
		path = path.substr(0, query)
	return {"method": request_line[0], "path": path, "headers": headers, "body": data.slice(body_start, body_start + length)}

static func _find_header_end(data: PackedByteArray) -> int:
	var i := data.find(13)
	while i >= 0 and i + 3 < data.size():
		if data[i + 1] == 10 and data[i + 2] == 13 and data[i + 3] == 10:
			return i
		i = data.find(13, i + 1)
	return -1
