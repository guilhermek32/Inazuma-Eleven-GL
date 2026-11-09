"""Regenerates tests/vectors/token_vectors.json from the lobby's reference
implementation (services/lobby/app/credentials.py).

    python tests/vectors/generate_token_vectors.py

The output is deterministic. Both the lobby's pytest suite and the Godot
runtime tests (tests/run_runtime_tests.gd) verify every vector: valid cases
must sign to exactly the same token and verify back to the same claims;
invalid cases must fail with exactly the listed error code.

Godot parses every JSON number as a float, so the "exp" values written into
the JSON stay below 2**53; the 2**63 boundary is covered by a re-signed
invalid vector, whose number lives inside the token bytes.
"""

import json
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "services" / "lobby"))

from app import credentials as cr  # noqa: E402

SECRET = "inazuma-shared-test-secret-0123456789"
NOW = 1_790_000_000
KEY = SECRET.encode("utf-8")


def resign(payload: bytes, key: bytes = KEY) -> str:
    """Signs arbitrary payload bytes (even structurally invalid ones)."""
    return cr.b64url_encode(payload) + "." + cr.b64url_encode(cr._mac(key, payload))


def main() -> None:
    base = cr.Claims(match_id="5b0c7f7e-8f8a-4c1e-9a55-2f0d6c1e7a10",
                     reservation_id="0e7c2b1a-6d4f-4b6a-8c3e-9f1a2b3c4d5e",
                     team=1, player_id="a3f1c2d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d", exp=NOW + 3600)
    red = cr.Claims(match_id="m-1", reservation_id="r-0", team=0, player_id="p-0", exp=NOW + 1)
    unicode_ids = cr.Claims(match_id="sala-ação", reservation_id="r", team=0, player_id="jogador-ü", exp=4_102_444_800)
    valid = []
    for name, c in [("uuid claims, team 1", base), ("short ids, team 0, expires next second", red),
                    ("non-ASCII ids, far-future exp", unicode_ids)]:
        valid.append({"name": name, "claims": c.as_dict(), "token": cr.sign(c, KEY)})

    good = cr.sign(base, KEY)
    payload_b64, sig_b64 = good.split(".")
    payload = cr.encode_payload(base)
    tampered = bytearray(payload)
    tampered[-9] ^= 0x01   # flip a bit of the player_id/aud region
    other_aud = cr.Claims(**{**base.__dict__, "aud": "lobby"})
    v2 = bytearray(payload)
    v2[0] = 2

    def at_team(p: bytes) -> int:
        i = 1
        for _ in range(2):
            i += 1 + p[i]
        return i

    team2 = bytearray(payload)
    team2[at_team(payload)] = 2
    huge_exp = payload[:-8] + struct.pack("<Q", 2**63)
    empty_match = bytes([1, 0]) + payload[2 + payload[1]:]
    bad_utf8 = bytearray(payload)
    bad_utf8[2] = 0xFF   # first byte of match_id

    invalid = [
        ("expired: now == exp", cr.sign(cr.Claims(**{**base.__dict__, "exp": NOW}), KEY), cr.EXPIRED),
        ("expired: exp in the past", cr.sign(cr.Claims(**{**base.__dict__, "exp": NOW - 60}), KEY), cr.EXPIRED),
        ("wrong audience", cr.sign(other_aud, KEY), cr.WRONG_AUDIENCE),
        ("signed with another secret", cr.sign(base, b"some-other-secret"), cr.BAD_SIGNATURE),
        ("payload tampered after signing", cr.b64url_encode(bytes(tampered)) + "." + sig_b64, cr.BAD_SIGNATURE),
        ("signature truncated", payload_b64 + "." + sig_b64[:-4], cr.BAD_SIGNATURE),
        ("signature of another token", payload_b64 + "." + valid[1]["token"].split(".")[1], cr.BAD_SIGNATURE),
        ("unsupported version (re-signed)", resign(bytes(v2)), cr.UNSUPPORTED_VERSION),
        ("team 2 (re-signed)", resign(bytes(team2)), cr.MALFORMED),
        ("trailing byte (re-signed)", resign(payload + b"\x00"), cr.MALFORMED),
        ("truncated payload (re-signed)", resign(payload[:-3]), cr.MALFORMED),
        ("exp >= 2^63 (re-signed)", resign(huge_exp), cr.MALFORMED),
        ("empty match_id (re-signed)", resign(empty_match), cr.MALFORMED),
        ("invalid UTF-8 match_id (re-signed)", resign(bytes(bad_utf8)), cr.MALFORMED),
        ("no separator", payload_b64 + sig_b64, cr.MALFORMED),
        ("three parts", good + ".AAAA", cr.MALFORMED),
        ("standard base64 alphabet character", "+" + payload_b64[1:] + "." + sig_b64, cr.MALFORMED),
        ("padding characters", payload_b64 + "==." + sig_b64, cr.MALFORMED),
        ("empty token", "", cr.MALFORMED),
        ("dev token", "dev:0", cr.MALFORMED),
        ("too long", "A" * 1025 + "." + sig_b64, cr.MALFORMED),
    ]
    for name, token, err in invalid:
        try:
            cr.verify(token, KEY, NOW)
        except cr.TokenError as e:
            assert e.code == err, (name, e.code, err)
        else:
            raise AssertionError(f"{name} unexpectedly verified")
    for v in valid:
        assert cr.verify(v["token"], KEY, NOW).as_dict() == v["claims"]

    doc = {
        "description": "Match credential v1 interoperability vectors (see services/lobby/app/credentials.py and "
                       "scripts/net/match_token.gd). Key = UTF-8 bytes of 'secret'; verify with now = 'now' "
                       "and audience = 'audience'.",
        "secret": SECRET,
        "now": NOW,
        "audience": cr.AUDIENCE,
        "valid": valid,
        "invalid": [{"name": n, "token": t, "error": e} for n, t, e in invalid],
    }
    out = pathlib.Path(__file__).with_name("token_vectors.json")
    out.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {out} ({len(valid)} valid, {len(invalid)} invalid)")


if __name__ == "__main__":
    main()
