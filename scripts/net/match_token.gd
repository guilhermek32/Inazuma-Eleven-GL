class_name MatchToken
extends RefCounted

## Signed match credential, version 1: the lobby issues one per team
## reservation and the match runtime verifies it locally on HELLO.
## services/lobby/app/credentials.py implements the same contract; the shared
## vectors in tests/vectors/token_vectors.json keep the two byte-identical.
##
## Claims: {v, match_id, reservation_id, team, player_id, aud, exp}.
##
## Payload bytes (all integers little-endian, like NetProtocol):
##   u8   v               = 1
##   str8 match_id        1..255 bytes of UTF-8
##   str8 reservation_id  1..255 bytes
##   u8   team            0 or 1
##   str8 player_id       1..255 bytes
##   str8 aud             1..255 bytes ("match-ws" for the player WebSocket)
##   u64  exp             unix seconds, < 2^63
## str8 = u8 byte length + UTF-8 bytes. Nothing may follow exp.
##
## Token = base64url(payload) "." base64url(HMAC-SHA256(secret, payload)),
## unpadded, at most MAX_TOKEN_CHARS characters. The secret is the UTF-8 bytes
## of MATCH_SECRET.
##
## verify() checks, in this order, and reports the first failure:
##   "malformed"            not two base64url parts, too long, bad encoding
##   "bad_signature"        HMAC mismatch (constant-time compare)
##   "unsupported_version"  first payload byte is not VERSION
##   "malformed"            payload doesn't parse exactly (lengths, team, exp, UTF-8)
##   "wrong_audience"       aud differs from the expected audience
##   "expired"              now >= exp

const VERSION := 1
const AUDIENCE := "match-ws"
const MAX_TOKEN_CHARS := 1024
const MAX_FIELD_BYTES := 255
const SIG_BYTES := 32

const ERR_MALFORMED := "malformed"
const ERR_BAD_SIGNATURE := "bad_signature"
const ERR_UNSUPPORTED_VERSION := "unsupported_version"
const ERR_WRONG_AUDIENCE := "wrong_audience"
const ERR_EXPIRED := "expired"

static var _b64url_re: RegEx

## Returns the token for `claims` (keys as above; "v" and "aud" default to
## VERSION and AUDIENCE), or "" if a claim can't be encoded.
static func sign(claims: Dictionary, secret: PackedByteArray) -> String:
	var payload := encode_payload(claims)
	if payload.is_empty() or secret.is_empty():
		return ""
	return b64url_encode(payload) + "." + b64url_encode(_hmac(secret, payload))

static func encode_payload(claims: Dictionary) -> PackedByteArray:
	var w := StreamPeerBuffer.new()
	w.big_endian = false
	var team := int(claims.get("team", -1))
	var exp := int(claims.get("exp", -1))
	if team < 0 or team > 1 or exp < 0:
		return PackedByteArray()
	w.put_u8(int(claims.get("v", VERSION)))
	if not _put_str8(w, str(claims.get("match_id", ""))) or not _put_str8(w, str(claims.get("reservation_id", ""))):
		return PackedByteArray()
	w.put_u8(team)
	if not _put_str8(w, str(claims.get("player_id", ""))) or not _put_str8(w, str(claims.get("aud", AUDIENCE))):
		return PackedByteArray()
	w.put_u64(exp)
	return w.data_array

## Returns {"ok": true, "claims": {...}} or {"ok": false, "error": ERR_*}.
static func verify(token: String, secret: PackedByteArray, now_unix: int, audience := AUDIENCE) -> Dictionary:
	if token.length() > MAX_TOKEN_CHARS:
		return _fail(ERR_MALFORMED)
	var parts := token.split(".")
	if parts.size() != 2:
		return _fail(ERR_MALFORMED)
	var payload := b64url_decode(parts[0])
	var sig := b64url_decode(parts[1])
	if payload.is_empty() or sig.is_empty():
		return _fail(ERR_MALFORMED)
	if secret.is_empty() or not Crypto.new().constant_time_compare(_hmac(secret, payload), sig):
		return _fail(ERR_BAD_SIGNATURE)
	if payload[0] != VERSION:
		return _fail(ERR_UNSUPPORTED_VERSION)
	var claims := decode_payload(payload)
	if claims.is_empty():
		return _fail(ERR_MALFORMED)
	if claims.aud != audience:
		return _fail(ERR_WRONG_AUDIENCE)
	if now_unix >= int(claims.exp):
		return _fail(ERR_EXPIRED)
	return {"ok": true, "claims": claims}

## Strict parse of a version-1 payload; {} if anything is off.
static func decode_payload(b: PackedByteArray) -> Dictionary:
	var at := [1]   # read cursor, boxed so the helper can advance it
	if b.size() < 1 or b[0] != VERSION:
		return {}
	var match_id := _get_str8(b, at)
	var reservation_id := _get_str8(b, at)
	if match_id == "" or reservation_id == "" or at[0] >= b.size():
		return {}
	var team: int = b[at[0]]
	at[0] += 1
	var player_id := _get_str8(b, at)
	var aud := _get_str8(b, at)
	if player_id == "" or aud == "" or team > 1 or at[0] + 8 != b.size():
		return {}
	var exp := b.decode_u64(at[0])
	if exp < 0:   # >= 2^63 reads back negative
		return {}
	return {"v": VERSION, "match_id": match_id, "reservation_id": reservation_id, "team": team,
			"player_id": player_id, "aud": aud, "exp": exp}

static func b64url_encode(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").replace("=", "")

## Unpadded base64url -> bytes; empty on any invalid input.
static func b64url_decode(s: String) -> PackedByteArray:
	if _b64url_re == null:
		_b64url_re = RegEx.create_from_string("^[A-Za-z0-9_-]+$")
	if s.is_empty() or s.length() % 4 == 1 or _b64url_re.search(s) == null:
		return PackedByteArray()
	var std := s.replace("-", "+").replace("_", "/")
	std += "=".repeat((4 - std.length() % 4) % 4)
	var out := Marshalls.base64_to_raw(std)
	if out.size() != s.length() * 3 / 4:
		return PackedByteArray()
	return out

static func _hmac(secret: PackedByteArray, msg: PackedByteArray) -> PackedByteArray:
	return Crypto.new().hmac_digest(HashingContext.HASH_SHA256, secret, msg)

static func _put_str8(w: StreamPeerBuffer, s: String) -> bool:
	var bytes := s.to_utf8_buffer()
	if bytes.is_empty() or bytes.size() > MAX_FIELD_BYTES:
		return false
	w.put_u8(bytes.size())
	w.put_data(bytes)
	return true

## Reads a str8 at at[0] and advances it; "" when short, empty or not valid UTF-8.
static func _get_str8(b: PackedByteArray, at: Array) -> String:
	var i: int = at[0]
	if i >= b.size():
		return ""
	var n: int = b[i]
	if n == 0 or i + 1 + n > b.size():
		return ""
	var raw := b.slice(i + 1, i + 1 + n)
	var s := raw.get_string_from_utf8()
	if s.to_utf8_buffer() != raw:
		return ""
	at[0] = i + 1 + n
	return s

static func _fail(code: String) -> Dictionary:
	return {"ok": false, "error": code}
