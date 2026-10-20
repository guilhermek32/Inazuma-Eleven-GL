"""Room creation and joining: provisioning before credentials, idempotency by
request_id, validation, provisioning failures and concurrent joins."""

import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest

from app import credentials as cr
from app.errors import Conflict

from .conftest import SECRET


def rid() -> str:
    return uuid.uuid4().hex


def create(client, nickname="Ana", half=30, request_id=None):
    return client.post("/v1/rooms", json={"nickname": nickname, "half_length_s": half, "request_id": request_id or rid()})


def test_create_provisions_the_runtime_before_returning_a_credential(client, fake_runtime):
    r = create(client)
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["team"] == 0 and len(body["room_code"]) == 6 and body["ws_url"] == f"/ws/game/{body['match_id']}"
    assert body["play_url"] == f"/?match={body['match_id']}&token={body['token']}"
    claims = cr.verify(body["token"], SECRET, int(time.time()))
    assert (claims.match_id, claims.team, claims.player_id, claims.reservation_id) == \
        (body["match_id"], 0, body["player_id"], body["reservation_id"])
    match = fake_runtime.matches[body["match_id"]]
    assert match["config"]["half_length_s"] == 30.0 and match["expires_at"] == claims.exp
    assert match["res"][0] == {"reservation_id": body["reservation_id"], "player_id": body["player_id"], "nickname": "Ana"}
    assert client.get(f"/v1/rooms/{body['room_code']}").json()["status"] == "waiting"


def test_create_is_idempotent_by_request_id(client, fake_runtime):
    request_id = rid()
    a = create(client, request_id=request_id).json()
    b = create(client, request_id=request_id).json()
    assert (a["room_code"], a["match_id"], a["reservation_id"], a["player_id"]) == \
        (b["room_code"], b["match_id"], b["reservation_id"], b["player_id"])
    assert len(fake_runtime.matches) == 1
    assert create(client, nickname="Other", request_id=request_id).status_code == 409


@pytest.mark.parametrize("payload", [
    {"nickname": "", "half_length_s": 60},
    {"nickname": "x" * 17, "half_length_s": 60},
    {"nickname": "bad<script>", "half_length_s": 60},
    {"nickname": "Ana", "half_length_s": 29},
    {"nickname": "Ana", "half_length_s": 901},
    {"nickname": "Ana", "half_length_s": 60, "mode": "bot"},
    {"nickname": "Ana", "half_length_s": 60, "unexpected": 1},
])
def test_invalid_create_requests_are_rejected(client, payload):
    r = client.post("/v1/rooms", json={**payload, "request_id": rid()})
    assert r.status_code == 422 and r.json()["error"] == "invalid_request"
    assert client.post("/v1/rooms", json={"nickname": "Ana", "request_id": "short"}).status_code == 422


def test_provisioning_failure_returns_503_and_cleans_up(client, fake_runtime):
    fake_runtime.down = True
    request_id = rid()
    r = create(client, request_id=request_id)
    assert r.status_code == 503 and r.json()["error"] == "runtime_unavailable"
    with client.service.pool.connection() as conn:
        assert conn.execute("SELECT count(*) AS n FROM rooms").fetchone()["n"] == 0
    fake_runtime.down = False
    assert create(client, request_id=request_id).status_code == 201   # the same request can be retried


def test_reservation_failure_cancels_the_provisioned_match(client, fake_runtime):
    fake_runtime.fail_reserve = True
    assert create(client).status_code == 503
    assert ("DELETE",) == tuple(m for m, _ in fake_runtime.calls if m == "DELETE")
    assert list(fake_runtime.terminal.values()) == ["cancelled"]
    with client.service.pool.connection() as conn:
        assert conn.execute("SELECT count(*) AS n FROM reservations").fetchone()["n"] == 0


def test_join_reserves_team_one(client, fake_runtime):
    room = create(client).json()
    r = client.post(f"/v1/rooms/{room['room_code'].lower()}/join", json={"nickname": "Bia", "request_id": rid()})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["team"] == 1 and body["match_id"] == room["match_id"] and body["player_id"] != room["player_id"]
    assert cr.verify(body["token"], SECRET, int(time.time())).team == 1
    assert fake_runtime.matches[room["match_id"]]["res"][1]["nickname"] == "Bia"
    status = client.get(f"/v1/rooms/{room['room_code']}").json()
    assert [p["nickname"] for p in status["players"]] == ["Ana", "Bia"]


def test_join_rules(client):
    room = create(client).json()
    code = room["room_code"]
    request_id = rid()
    first = client.post(f"/v1/rooms/{code}/join", json={"nickname": "Bia", "request_id": request_id}).json()
    again = client.post(f"/v1/rooms/{code}/join", json={"nickname": "Bia", "request_id": request_id}).json()
    assert first["reservation_id"] == again["reservation_id"]
    full = client.post(f"/v1/rooms/{code}/join", json={"nickname": "Cy", "request_id": rid()})
    assert full.status_code == 409 and full.json()["error"] == "room_full"
    assert client.post("/v1/rooms/ZZZZZZ/join", json={"nickname": "Cy", "request_id": rid()}).status_code == 404
    other = create(client).json()
    reuse = client.post(f"/v1/rooms/{other['room_code']}/join", json={"nickname": "Bia", "request_id": request_id})
    assert reuse.status_code == 409 and reuse.json()["error"] == "request_conflict"


def test_returning_guest_keeps_its_player_id(client):
    first = create(client, nickname="Ana").json()
    second = client.post("/v1/rooms", json={"nickname": "Ana2", "half_length_s": 60, "request_id": rid(),
                                            "player_id": first["player_id"]}).json()
    assert second["player_id"] == first["player_id"]
    unknown = client.post("/v1/rooms", json={"nickname": "Ana", "request_id": rid(), "player_id": str(uuid.uuid4())})
    assert unknown.status_code == 404


def test_joining_your_own_room_as_the_same_guest_gets_a_fresh_guest_id(client, fake_runtime):
    # Two tabs of one browser profile share the stored player_id.
    room = create(client).json()
    r = client.post(f"/v1/rooms/{room['room_code']}/join",
                    json={"nickname": "Bia", "request_id": rid(), "player_id": room["player_id"]})
    assert r.status_code == 200, r.text
    joined = r.json()
    assert joined["team"] == 1 and joined["player_id"] != room["player_id"]
    assert cr.verify(joined["token"], SECRET, int(time.time())).player_id == joined["player_id"]
    reserved = fake_runtime.matches[room["match_id"]]["res"]
    assert reserved[0]["player_id"] != reserved[1]["player_id"]


def test_concurrent_joins_exactly_one_wins_service_level(client):
    code = create(client).json()["room_code"]
    barrier = threading.Barrier(8)

    def attempt(i):
        barrier.wait()
        try:
            return client.service.join_room(code, f"P{i}", rid())["team"]
        except Conflict as e:
            return e.error

    with ThreadPoolExecutor(8) as pool:
        results = list(pool.map(attempt, range(8)))
    assert results.count(1) == 1 and results.count("room_full") == 7, results


def test_concurrent_joins_exactly_one_wins_over_http(client):
    code = create(client).json()["room_code"]
    with ThreadPoolExecutor(6) as pool:
        codes = list(pool.map(lambda i: client.post(f"/v1/rooms/{code}/join",
                                                    json={"nickname": f"P{i}", "request_id": rid()}).status_code, range(6)))
    assert sorted(codes) == [200, 409, 409, 409, 409, 409]


def test_concurrent_duplicate_join_requests_share_one_seat(client):
    # A double click / client retry while the first transaction holds the room lock.
    code = create(client).json()["room_code"]
    request_id = rid()
    barrier = threading.Barrier(4)

    def attempt(_):
        barrier.wait()
        return client.post(f"/v1/rooms/{code}/join", json={"nickname": "Bia", "request_id": request_id})

    with ThreadPoolExecutor(4) as pool:
        replies = list(pool.map(attempt, range(4)))
    assert [r.status_code for r in replies] == [200] * 4, [r.text for r in replies]
    assert len({r.json()["reservation_id"] for r in replies}) == 1


def test_bot_player_ids_are_never_given_to_a_guest(client, fake_runtime):
    from app.bot_client import bot_player
    bot_id = str(bot_player("hard")[0])
    room = client.post("/v1/rooms", json={"nickname": "Ana", "request_id": rid(), "player_id": bot_id}).json()
    assert room["player_id"] != bot_id
    joined = client.post(f"/v1/rooms/{room['room_code']}/join",
                         json={"nickname": "Bia", "request_id": rid(), "player_id": bot_id}).json()
    assert joined["player_id"] != bot_id


def test_a_late_create_retry_for_a_closed_room_gets_no_credential(client):
    request_id = rid()
    room = create(client, request_id=request_id).json()
    with client.service.pool.connection() as conn:
        conn.execute("UPDATE rooms SET status = 'cancelled' WHERE room_code = %s", (room["room_code"],))
    r = create(client, request_id=request_id)
    assert r.status_code == 409 and r.json()["error"] == "room_closed", r.text
