"""vs-AI rooms: the lobby provisions both slots, starts a bot job with the
bot's own credential and the internal runtime URL, and only answers once the
bot has joined; every bot failure (refused, failed, never joined, service
down or unconfigured) is a clean 503 that leaves no room, reservation or live
match behind, while PvP keeps working."""

import time
import uuid

import pytest

from app import credentials as cr
from app.bot_client import BOT_PLAYER_NAMESPACE, bot_player

from .conftest import SECRET


def rid() -> str:
    return uuid.uuid4().hex


def create_vs_ai(client, difficulty="hard", nickname="Ana", half=30, request_id=None):
    body = {"nickname": nickname, "half_length_s": half, "request_id": request_id or rid(), "mode": "vs_ai"}
    if difficulty is not None:
        body["difficulty"] = difficulty
    return client.post("/v1/rooms", json=body)


def counts(client) -> tuple[int, int]:
    with client.service.pool.connection() as conn:
        rooms = conn.execute("SELECT count(*) AS n FROM rooms").fetchone()["n"]
        reservations = conn.execute("SELECT count(*) AS n FROM reservations").fetchone()["n"]
    return rooms, reservations


def assert_cleaned_up(client, fake_runtime):
    assert counts(client) == (0, 0)
    assert fake_runtime.matches == {} and list(fake_runtime.terminal.values()) == ["cancelled"]


def test_vs_ai_room_is_ready_once_the_bot_joined(client, fake_runtime, fake_bot):
    r = create_vs_ai(client, "hard")
    assert r.status_code == 201, r.text
    room = r.json()
    assert room["team"] == 0 and cr.verify(room["token"], SECRET, int(time.time())).team == 0
    match = fake_runtime.matches[room["match_id"]]
    assert match["config"]["team_difficulty"] == [1, 2]   # the bot's team-mates play Hard too
    bot_id, bot_name = bot_player("hard")
    assert bot_name == "AI (Hard)" and match["res"][1]["player_id"] == str(bot_id) and match["res"][1]["nickname"] == bot_name
    job = fake_bot.jobs[room["match_id"]]
    assert job["difficulty"] == "hard" and job["state"] == "joined" and job["polls"] >= 1
    assert job["ws_url"] == f"ws://match-runtime:8910/ws/game/{room['match_id']}"   # internal, not the public URL
    claims = cr.verify(job["token"], SECRET, int(time.time()))
    assert (claims.team, claims.match_id, claims.reservation_id, claims.player_id) == \
        (1, room["match_id"], match["res"][1]["reservation_id"], str(bot_id))
    status = client.get(f"/v1/rooms/{room['room_code']}").json()
    assert status["status"] == "waiting" and status["mode"] == "vs_ai" and status["difficulty"] == "hard"
    assert [p["nickname"] for p in status["players"]] == ["Ana", "AI (Hard)"]
    full = client.post(f"/v1/rooms/{room['room_code']}/join", json={"nickname": "Bia", "request_id": rid()})
    assert full.status_code == 409 and full.json()["error"] == "room_full"


def test_bot_identity_is_stable_per_difficulty(client, fake_runtime):
    a = create_vs_ai(client, "hard").json()
    b = create_vs_ai(client, "hard", nickname="Cy").json()
    c = create_vs_ai(client, "easy").json()
    ids = [fake_runtime.matches[m["match_id"]]["res"][1]["player_id"] for m in (a, b, c)]
    assert ids[0] == ids[1] != ids[2]
    assert ids[2] == str(uuid.uuid5(BOT_PLAYER_NAMESPACE, "ai-bot:easy"))
    assert fake_runtime.matches[c["match_id"]]["config"]["team_difficulty"] == [1, 0]


def test_vs_ai_defaults_to_normal_and_validates(client, fake_runtime):
    room = create_vs_ai(client, difficulty=None).json()
    assert fake_runtime.matches[room["match_id"]]["res"][1]["nickname"] == "AI (Normal)"
    assert create_vs_ai(client, "insane").status_code == 422
    pvp_with_difficulty = client.post("/v1/rooms", json={"nickname": "Ana", "request_id": rid(), "difficulty": "hard"})
    assert pvp_with_difficulty.status_code == 422
    pvp = client.post("/v1/rooms", json={"nickname": "Ana", "request_id": rid()}).json()
    assert fake_runtime.matches[pvp["match_id"]]["config"]["team_difficulty"] == [1, 1]


def test_vs_ai_create_is_idempotent_by_request_id(client, fake_bot):
    request_id = rid()
    first = create_vs_ai(client, "normal", request_id=request_id).json()
    again = create_vs_ai(client, "normal", request_id=request_id).json()
    assert again["match_id"] == first["match_id"] and again["token"] == first["token"]
    assert [c for c in fake_bot.calls if c[0] == "POST"] == [("POST", "/internal/v1/bots")]
    conflict = create_vs_ai(client, "hard", request_id=request_id)
    assert conflict.status_code == 409 and conflict.json()["error"] == "request_conflict"
    as_pvp = client.post("/v1/rooms", json={"nickname": "Ana", "half_length_s": 30, "request_id": request_id})
    assert as_pvp.status_code == 409


@pytest.mark.parametrize("behaviour", ["fail", "full"])
def test_bot_failure_returns_503_and_cancels_the_match(client, fake_runtime, fake_bot, behaviour):
    fake_bot.behaviour = behaviour
    r = create_vs_ai(client)
    assert r.status_code == 503 and r.json()["error"] == "bot_unavailable"
    assert_cleaned_up(client, fake_runtime)
    if behaviour == "fail":
        assert ("DELETE", f"/internal/v1/bots/{next(iter(fake_runtime.terminal))}") in fake_bot.calls


def test_bot_join_timeout_returns_503_and_cancels_the_match(client, fake_runtime, fake_bot, settings):
    fake_bot.behaviour = "never"
    t0 = time.monotonic()
    r = create_vs_ai(client)
    assert r.status_code == 503 and r.json()["error"] == "bot_unavailable"
    assert time.monotonic() - t0 >= settings.bot_join_timeout_s
    assert_cleaned_up(client, fake_runtime)
    assert [j["state"] for j in fake_bot.jobs.values()] == ["stopped"]   # the late job is stopped too
    fake_bot.behaviour = "join"
    assert create_vs_ai(client).status_code == 201   # nothing left over blocks a new attempt


def test_bot_service_down_fails_vs_ai_but_pvp_still_works(client, fake_runtime, fake_bot):
    fake_bot.down = True
    r = create_vs_ai(client)
    assert r.status_code == 503 and r.json()["error"] == "bot_unavailable"
    assert_cleaned_up(client, fake_runtime)
    room = client.post("/v1/rooms", json={"nickname": "Ana", "half_length_s": 30, "request_id": rid()})
    assert room.status_code == 201
    joined = client.post(f"/v1/rooms/{room.json()['room_code']}/join", json={"nickname": "Bia", "request_id": rid()})
    assert joined.status_code == 200 and joined.json()["team"] == 1


def test_unconfigured_bot_service_refuses_vs_ai_without_provisioning(client, fake_runtime):
    client.service.bot.configured = False
    r = create_vs_ai(client)
    assert r.status_code == 503 and r.json()["error"] == "bot_unavailable"
    assert fake_runtime.calls == [] and counts(client) == (0, 0)


def test_a_waiting_room_whose_bot_is_gone_is_cancelled(client, fake_runtime, fake_bot):
    room = create_vs_ai(client).json()
    assert client.get(f"/v1/rooms/{room['room_code']}").json()["status"] == "waiting"
    fake_bot.jobs[room["match_id"]]["state"] = "failed"   # e.g. the bot lost its connection for good
    assert client.get(f"/v1/rooms/{room['room_code']}").json()["status"] == "cancelled"
    assert fake_runtime.terminal[room["match_id"]] == "cancelled"
    other = create_vs_ai(client).json()
    fake_bot.down = True   # an unreachable bot service is not proof the bot is gone: keep the room
    assert client.get(f"/v1/rooms/{other['room_code']}").json()["status"] == "waiting"
