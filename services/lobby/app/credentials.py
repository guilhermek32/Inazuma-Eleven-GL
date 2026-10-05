"""Signed match credentials, version 1.

The lobby signs one credential per confirmed team reservation; the match
runtime verifies it locally on HELLO (scripts/net/match_token.gd implements the
same contract). tests/vectors/token_vectors.json holds shared vectors that both
implementations must reproduce byte for byte.

Payload bytes (integers little-endian, like the game's NetProtocol):

    u8   v               = 1
    str8 match_id        1..255 bytes of UTF-8
    str8 reservation_id  1..255 bytes
    u8   team            0 or 1
    str8 player_id       1..255 bytes
    str8 aud             1..255 bytes ("match-ws" for the player WebSocket)
    u64  exp             unix seconds, < 2**63

str8 is a u8 byte length followed by that many UTF-8 bytes; nothing may follow
exp. The token is ``base64url(payload) + "." + base64url(HMAC-SHA256(secret,
payload))``, unpadded, at most MAX_TOKEN_CHARS characters.

verify() checks in this order and raises TokenError with the first failure:
malformed (shape/encoding) -> bad_signature -> unsupported_version ->
malformed (payload structure) -> wrong_audience -> expired (now >= exp).
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import re
import struct
from dataclasses import dataclass

VERSION = 1
AUDIENCE = "match-ws"
MAX_TOKEN_CHARS = 1024
MAX_FIELD_BYTES = 255

MALFORMED = "malformed"
BAD_SIGNATURE = "bad_signature"
UNSUPPORTED_VERSION = "unsupported_version"
WRONG_AUDIENCE = "wrong_audience"
EXPIRED = "expired"

_B64URL = re.compile(r"^[A-Za-z0-9_-]+$")


class TokenError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class Claims:
    match_id: str
    reservation_id: str
    team: int
    player_id: str
    exp: int
    aud: str = AUDIENCE
    v: int = VERSION

    def as_dict(self) -> dict:
        return {"v": self.v, "match_id": self.match_id, "reservation_id": self.reservation_id,
                "team": self.team, "player_id": self.player_id, "aud": self.aud, "exp": self.exp}


def _str8(value: str) -> bytes:
    raw = value.encode("utf-8")
    if not 1 <= len(raw) <= MAX_FIELD_BYTES:
        raise ValueError("claim strings must be 1..255 UTF-8 bytes")
    return bytes([len(raw)]) + raw


def encode_payload(claims: Claims) -> bytes:
    if claims.team not in (0, 1):
        raise ValueError("team must be 0 or 1")
    if not 0 <= claims.exp < 2**63:
        raise ValueError("exp out of range")
    return (bytes([claims.v]) + _str8(claims.match_id) + _str8(claims.reservation_id)
            + bytes([claims.team]) + _str8(claims.player_id) + _str8(claims.aud)
            + struct.pack("<Q", claims.exp))


def b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def b64url_decode(text: str) -> bytes:
    if not text or len(text) % 4 == 1 or not _B64URL.match(text):
        raise TokenError(MALFORMED)
    std = text.replace("-", "+").replace("_", "/")
    try:
        return base64.b64decode(std + "=" * (-len(std) % 4), validate=True)
    except (binascii.Error, ValueError):
        raise TokenError(MALFORMED) from None


def _mac(secret: bytes, payload: bytes) -> bytes:
    return hmac.new(secret, payload, hashlib.sha256).digest()


def sign(claims: Claims, secret: bytes) -> str:
    if not secret:
        raise ValueError("empty secret")
    payload = encode_payload(claims)
    return b64url_encode(payload) + "." + b64url_encode(_mac(secret, payload))


def decode_payload(payload: bytes) -> Claims:
    """Strict parse of a version-1 payload; raises TokenError(MALFORMED)."""
    at = 1

    def str8() -> str:
        nonlocal at
        if at >= len(payload):
            raise TokenError(MALFORMED)
        n = payload[at]
        if n == 0 or at + 1 + n > len(payload):
            raise TokenError(MALFORMED)
        raw = payload[at + 1:at + 1 + n]
        at += 1 + n
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError:
            raise TokenError(MALFORMED) from None

    if not payload or payload[0] != VERSION:
        raise TokenError(MALFORMED)
    match_id = str8()
    reservation_id = str8()
    if at >= len(payload):
        raise TokenError(MALFORMED)
    team = payload[at]
    at += 1
    player_id = str8()
    aud = str8()
    if team > 1 or at + 8 != len(payload):
        raise TokenError(MALFORMED)
    (exp,) = struct.unpack_from("<Q", payload, at)
    if exp >= 2**63:
        raise TokenError(MALFORMED)
    return Claims(match_id=match_id, reservation_id=reservation_id, team=team,
                  player_id=player_id, exp=exp, aud=aud)


def verify(token: str, secret: bytes, now: int, audience: str = AUDIENCE) -> Claims:
    if not isinstance(token, str) or len(token) > MAX_TOKEN_CHARS:
        raise TokenError(MALFORMED)
    parts = token.split(".")
    if len(parts) != 2:
        raise TokenError(MALFORMED)
    payload = b64url_decode(parts[0])
    sig = b64url_decode(parts[1])
    if not secret or not hmac.compare_digest(_mac(secret, payload), sig):
        raise TokenError(BAD_SIGNATURE)
    if payload[0] != VERSION:
        raise TokenError(UNSUPPORTED_VERSION)
    claims = decode_payload(payload)
    if claims.aud != audience:
        raise TokenError(WRONG_AUDIENCE)
    if now >= claims.exp:
        raise TokenError(EXPIRED)
    return claims
