"""The HTTP API and the read model's sync policy, against a fake results service."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.bots import BOT_IDS
from app.main import ResultsFeed, create_app
from app.model import RecommendationModel
from tests.conftest import FakeResults, item, pid


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self) -> float:
        return self.t


def make(items=None, **model_kw):
    results = FakeResults(items)
    clock = Clock()
    feed = ResultsFeed("http://results", transport=results.transport())
    model = RecommendationModel(feed.page, clock=clock, **model_kw)
    client = TestClient(create_app("http://results", model=model))
    return client, results, clock, model


def test_health_answers_before_any_read():
    client, results, _, _ = make()
    r = client.get("/health")
    assert r.status_code == 200 and r.json()["status"] == "ok" and results.requests == 0


def test_recommendation_for_a_new_player():
    client, *_ = make()
    r = client.get("/v1/recommendations")
    assert r.status_code == 200
    body = r.json()
    assert body["ai_level"]["level"] == "easy" and body["rivals"] == []
    assert body["model"] == {**body["model"], "matches": 0, "stale": False}


def test_recommendation_uses_only_counted_matches():
    me, you = pid("me"), pid("you")
    items = [item(me, BOT_IDS["easy"], 5, 0, 1, nick0="OldName"),
             item(me, you, 0, 0, 2, reason="cancelled", winner=None),
             item(me, you, 3, 0, 3, reason="forfeit", winner=None),   # no winner: not counted
             item(you, me, 0, 2, 4, reason="forfeit", winner=1, nick1="Erick")]
    client, *_ = make(items)
    body = client.get("/v1/recommendations", params={"player_id": me}).json()
    # Counted matches only, and the nickname of the latest one.
    assert body["player"]["played"] == 2 and body["player"]["nickname"] == "Erick"
    assert body["player"]["form"] == "WW"
    assert [r["player_id"] for r in body["rivals"]] == [you]


def test_invalid_player_id_is_400():
    client, *_ = make()
    r = client.get("/v1/recommendations", params={"player_id": "x' OR 1=1"})
    assert r.status_code == 400 and r.json()["error"] == "invalid_player_id"


def test_results_down_before_first_read_is_503():
    client, results, *_ = make()
    results.down = True
    r = client.get("/v1/recommendations")
    assert r.status_code == 503 and r.json()["error"] == "results_unavailable"


def test_results_down_later_serves_the_stale_model():
    me = pid("me")
    client, results, clock, _ = make([item(me, BOT_IDS["easy"], 2, 0, 1)])
    assert client.get("/v1/recommendations", params={"player_id": me}).json()["player"]["played"] == 1
    results.down = True
    clock.t += 60
    body = client.get("/v1/recommendations", params={"player_id": me}).json()
    assert body["player"]["played"] == 1 and body["model"]["stale"] is True
    results.down = False
    clock.t += 60
    assert client.get("/v1/recommendations").json()["model"]["stale"] is False


def test_refresh_is_throttled():
    client, results, clock, _ = make([item(pid("a"), pid("b"), 1, 0, 1)])
    client.get("/v1/recommendations")
    n = results.requests
    client.get("/v1/recommendations")
    client.get("/v1/ratings")
    assert results.requests == n
    clock.t += 11
    client.get("/v1/recommendations")
    assert results.requests > n


def test_new_results_are_picked_up_incrementally():
    me = pid("me")
    client, results, clock, _ = make([item(me, BOT_IDS["easy"], 1, 0, 1)])
    client.get("/v1/recommendations")
    results.items.append(item(me, BOT_IDS["normal"], 2, 0, 2))
    clock.t += 11
    body = client.get("/v1/recommendations", params={"player_id": me}).json()
    assert body["player"]["played"] == 2 and body["model"]["matches"] == 2


def test_paginates_the_whole_history():
    a, b = pid("a"), pid("b")
    items = [item(a, b, 1, 0, n) for n in range(250)]
    client, results, *_ = make(items)
    body = client.get("/v1/recommendations", params={"player_id": a}).json()
    assert body["player"]["played"] == 250 and results.requests == 3


def test_full_sync_picks_up_a_late_result():
    me, you = pid("me"), pid("you")
    client, results, clock, _ = make([item(me, you, 1, 0, n) for n in range(1, 151)], full_sync_s=300)
    client.get("/v1/recommendations")
    # Finished before everything else but recorded later: beyond the first page,
    # so the incremental read (which stops at a page with known matches) misses it.
    results.items.append(item(me, BOT_IDS["easy"], 1, 0, 0))
    clock.t += 11
    assert client.get("/v1/recommendations", params={"player_id": me}).json()["player"]["played"] == 150
    clock.t += 300
    assert client.get("/v1/recommendations", params={"player_id": me}).json()["player"]["played"] == 151


def test_history_is_capped():
    a, b = pid("a"), pid("b")
    client, *_ = make([item(a, b, 1, 0, n) for n in range(30)], max_history=10)
    assert client.get("/v1/recommendations", params={"player_id": a}).json()["player"]["played"] == 10


def test_ratings_rank_players_and_bots():
    a = pid("a")
    client, *_ = make([item(a, BOT_IDS["hard"], 6, 0, n) for n in range(5)])
    items = client.get("/v1/ratings", params={"limit": 10}).json()["items"]
    assert items[0]["player_id"] == a and [i["rank"] for i in items] == [1, 2, 3, 4]
    assert sum(i["bot"] for i in items) == 3


@pytest.mark.parametrize("limit", [0, 101])
def test_ratings_limit_is_validated(limit):
    client, *_ = make()
    assert client.get("/v1/ratings", params={"limit": limit}).status_code == 422
