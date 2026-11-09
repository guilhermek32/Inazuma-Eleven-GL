"""The lobby's credential implementation against the shared interoperability
vectors (also verified by the Godot runtime in tests/run_runtime_tests.gd)."""

import json
import os
import pathlib

import pytest

from app import credentials as cr

# In the test container the vectors are mounted at $TOKEN_VECTORS; in a checkout
# they sit at <repo>/tests/vectors/.
VECTORS = pathlib.Path(os.environ.get("TOKEN_VECTORS")
                       or pathlib.Path(__file__).resolve().parents[3] / "tests" / "vectors" / "token_vectors.json")


@pytest.fixture(scope="module")
def vectors() -> dict:
    return json.loads(VECTORS.read_text(encoding="utf-8"))


def test_valid_vectors_sign_identically_and_verify(vectors):
    key = vectors["secret"].encode("utf-8")
    assert vectors["valid"]
    for v in vectors["valid"]:
        c = v["claims"]
        claims = cr.Claims(match_id=c["match_id"], reservation_id=c["reservation_id"], team=c["team"],
                           player_id=c["player_id"], exp=c["exp"], aud=c["aud"], v=c["v"])
        assert cr.sign(claims, key) == v["token"], v["name"]
        assert cr.verify(v["token"], key, vectors["now"], vectors["audience"]).as_dict() == c, v["name"]


def test_invalid_vectors_fail_with_the_listed_error(vectors):
    key = vectors["secret"].encode("utf-8")
    assert len(vectors["invalid"]) >= 10
    for v in vectors["invalid"]:
        with pytest.raises(cr.TokenError) as err:
            cr.verify(v["token"], key, vectors["now"], vectors["audience"])
        assert err.value.code == v["error"], v["name"]


def test_round_trip_and_expiry_boundary():
    key = b"k"
    claims = cr.Claims(match_id="m", reservation_id="r", team=0, player_id="p", exp=100)
    token = cr.sign(claims, key)
    assert cr.verify(token, key, 99) == claims
    with pytest.raises(cr.TokenError, match="expired"):
        cr.verify(token, key, 100)


def test_unencodable_claims_are_refused():
    with pytest.raises(ValueError):
        cr.encode_payload(cr.Claims(match_id="", reservation_id="r", team=0, player_id="p", exp=1))
    with pytest.raises(ValueError):
        cr.encode_payload(cr.Claims(match_id="m", reservation_id="r", team=2, player_id="p", exp=1))
    with pytest.raises(ValueError):
        cr.encode_payload(cr.Claims(match_id="x" * 256, reservation_id="r", team=0, player_id="p", exp=1))
