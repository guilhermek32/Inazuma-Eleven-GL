"""Ingestion idempotency, validation, history and leaderboard read models."""

import json
import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest

from .conftest import AUTH, result

A, B, C, D = (str(uuid.UUID(int=i)) for i in (1, 2, 3, 4))


def post(client, doc, headers=AUTH):
    return client.post("/internal/v1/matches", content=json.dumps(doc), headers=headers)


def test_ingest_requires_the_bearer_token(client):
    doc = result(A, B, 1, 0)
    assert post(client, doc, headers={}).status_code == 401
    assert post(client, doc, headers={"Authorization": "Bearer nope"}).status_code == 401
    assert client.get("/v1/matches/recent").json()["items"] == []


def test_identical_duplicate_is_acknowledged_and_conflicting_one_rejected(client):
    doc = result(A, B, 2, 1)
    assert post(client, doc).status_code == 201
    # Same content, different key order and whitespace: still identical.
    reordered = json.dumps(dict(reversed(list(doc.items()))), indent=2)
    r = client.post("/internal/v1/matches", content=reordered, headers=AUTH)
    assert r.status_code == 200 and r.json()["status"] == "duplicate"
    changed = {**doc, "score_left": 3, "winner": 0}
    r = post(client, changed)
    assert r.status_code == 409 and r.json()["error"] == "conflict"
    items = client.get("/v1/matches/recent").json()["items"]
    assert len(items) == 1 and items[0]["score"] == [2, 1]


def test_concurrent_duplicates_store_exactly_one_record(client):
    doc = result(A, B, 1, 1)
    with ThreadPoolExecutor(6) as pool:
        codes = sorted(pool.map(lambda _: post(client, doc).status_code, range(6)))
    assert codes == [200, 200, 200, 200, 200, 201]
    assert len(client.get("/v1/matches/recent").json()["items"]) == 1


@pytest.mark.parametrize("mutate", [
    lambda d: d.pop("finished_at"),
    lambda d: d.update(reason="extra_time"),
    lambda d: d.update(winner=1),                                   # full-time winner contradicts score
    lambda d: d.update(players=d["players"][:1]),
    lambda d: d["players"][1].update(team=0),
    lambda d: d["players"][1].update(player_id=d["players"][0]["player_id"]),
    lambda d: d.update(match_id="not-a-uuid"),
    lambda d: d.update(score_left=-1),
    lambda d: d.update(reason="cancelled"),                          # cancelled with a winner
    lambda d: d.update(started_at="2030-01-01T00:00:00Z"),          # finished before started
    lambda d: d.update(surprise=True),
])
def test_invalid_results_are_rejected(client, mutate):
    doc = result(A, B, 2, 0)
    mutate(doc)
    r = post(client, doc)
    assert r.status_code == 422 and r.json()["error"] == "invalid_result"


def test_malformed_json_and_oversized_bodies(client):
    assert client.post("/internal/v1/matches", content="{nope", headers=AUTH).status_code == 422
    big = result(A, B, 1, 0)
    big["stats"] = [{"pad": "x" * 70000}, {}]
    assert post(client, big).status_code == 413


def test_recent_is_newest_first_and_paginates_without_gaps(client):
    ids = []
    for minute in range(7):
        doc = result(A, B, minute % 3, 1, minute=minute)
        ids.append(doc["match_id"])
        assert post(client, doc).status_code == 201
    seen, cursor = [], None
    while True:
        page = client.get("/v1/matches/recent", params={"limit": 3, **({"cursor": cursor} if cursor else {})}).json()
        seen += [m["match_id"] for m in page["items"]]
        cursor = page["next_cursor"]
        if not cursor:
            break
    assert seen == list(reversed(ids))
    first = client.get("/v1/matches/recent", params={"limit": 1}).json()["items"][0]
    assert first["players"][0]["nickname"].startswith("P-") and first["stats"][0]["shots"] == 4
    assert client.get("/v1/matches/recent", params={"cursor": "garbage!"}).status_code == 400
    assert client.get("/v1/matches/recent", params={"limit": 0}).status_code == 422


def test_leaderboard_orders_by_points_then_goal_difference_then_goals_for(client):
    # A: win 1-0, win 5-4                     -> 6 pts, GD +2, GF 6
    # D: loss 0-3, draw 2-2, forfeit win 0-1   -> 4 pts
    # C: win 3-0, loss 4-5, forfeit loss 1-0   -> 3 pts
    # B: loss 0-1, draw 2-2                    -> 1 pt
    games = [result(A, B, 1, 0, minute=1), result(C, D, 3, 0, minute=2), result(A, C, 5, 4, minute=3),
             result(B, D, 2, 2, minute=4)]
    # Not counted: cancelled and aborted matches, and a forfeit without a winner.
    games += [result(B, A, 0, 0, reason="cancelled", winner=None, minute=5),
              result(D, B, 9, 0, reason="aborted", winner=None, minute=6),
              result(D, C, 0, 0, reason="forfeit", winner=None, minute=7)]
    # A forfeit with a winner counts: D wins against C whatever the score.
    games.append(result(C, D, 1, 0, reason="forfeit", winner=1, minute=8))
    for g in games:
        assert post(client, g).status_code == 201, post(client, g).text
    board = client.get("/v1/leaderboard").json()["items"]
    order = [row["player_id"] for row in board]
    assert order == [A, D, C, B], board
    a = board[0]
    assert (a["points"], a["goal_diff"], a["goals_for"], a["played"], a["wins"], a["rank"]) == (6, 2, 6, 2, 2, 1)
    assert board[3]["points"] == 1 and board[3]["draws"] == 1 and board[3]["losses"] == 1


def test_leaderboard_ties_break_on_goal_difference_then_goals_for_and_paginate(client):
    # Everyone 3 points; GD/GF differ.
    E, F = str(uuid.UUID(int=5)), str(uuid.UUID(int=6))
    for i, (w, l, gl, gr) in enumerate([(A, B, 3, 0), (C, D, 4, 2), (E, F, 2, 0)]):
        post(client, result(w, l, gl, gr, minute=i))
    order = []
    cursor = None
    while True:
        page = client.get("/v1/leaderboard", params={"limit": 2, **({"cursor": cursor} if cursor else {})}).json()
        order += [row["player_id"] for row in page["items"]]
        cursor = page["next_cursor"]
        if not cursor:
            break
    # A (GD+3, GF3), C (GD+2, GF4), E (GD+2, GF2); then 0 pts: D (GD-2, GF2), F (GD-2, GF0), B (GD-3).
    assert order == [A, C, E, D, F, B]


def test_health(client):
    assert client.get("/health").json() == {"status": "ok"}
