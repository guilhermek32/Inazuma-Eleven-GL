"""The rating and recommendation rules (engine.py), without I/O."""

from __future__ import annotations

import uuid

import pytest

from app import engine
from app.bots import BOT_IDS
from tests.conftest import pid


def match(a: str, b: str, left: int, right: int, n: int) -> engine.Match:
    winner = 0 if left > right else (1 if right > left else None)
    return engine.Match(f"m{n}", f"2026-10-01T12:{n:02d}:00+00:00", a, b, "", "", left, right, winner)


def test_bot_ids_match_the_lobby():
    # services/lobby/app/bot_client.py: uuid5(namespace, "ai-bot:<difficulty>")
    ns = uuid.UUID("6f1c3a52-9d4e-4c1b-8a57-2f0e8b7d4c21")
    assert BOT_IDS == {d: str(uuid.uuid5(ns, f"ai-bot:{d}")) for d in ("easy", "normal", "hard")}


def test_expected_score_is_symmetric_and_rating_ordered():
    assert engine.expected_score(1000, 1000) == pytest.approx(0.5)
    assert engine.expected_score(1200, 1000) == pytest.approx(1 - engine.expected_score(1000, 1200))
    assert engine.expected_score(1400, 1000) == pytest.approx(10 / 11)


def test_goal_index_follows_world_football_elo():
    assert [engine.goal_index(n) for n in (0, 1, -1, 2, 3, 5)] == [1.0, 1.0, 1.0, 1.5, 14 / 8, 16 / 8]


def test_rating_update_is_zero_sum_between_new_players():
    a, b = pid("a"), pid("b")
    players = engine.rate([match(a, b, 2, 1, 1)])
    assert players[a].rating == pytest.approx(1000 + engine.K_NEW * 0.5)
    assert players[a].rating + players[b].rating == pytest.approx(2000)
    assert (players[a].wins, players[b].losses, players[a].form, players[b].form) == (1, 1, ["W"], ["L"])


def test_bigger_wins_move_ratings_more():
    a, b = pid("a"), pid("b")
    narrow = engine.rate([match(a, b, 1, 0, 1)])[a].rating
    wide = engine.rate([match(a, b, 5, 0, 1)])[a].rating
    assert wide > narrow > 1000


def test_draw_between_equals_changes_nothing():
    a, b = pid("a"), pid("b")
    players = engine.rate([match(a, b, 1, 1, 1)])
    assert players[a].rating == pytest.approx(1000) and players[a].draws == 1


def test_k_factor_drops_after_provisional_games():
    a, b = pid("a"), pid("b")
    history = [match(a, b, 1, 1, n) for n in range(engine.PROVISIONAL_GAMES)]
    p = engine.rate(history)[a]
    assert p.played == engine.PROVISIONAL_GAMES and engine.k_factor(p) == engine.K_SETTLED


def test_bots_start_at_their_priors_and_are_rated_like_players():
    players = engine.rate([])
    assert [players[BOT_IDS[d]].rating for d in ("easy", "normal", "hard")] == [900, 1050, 1200]
    a = pid("a")
    players = engine.rate([match(a, BOT_IDS["hard"], 3, 0, 1)])
    assert players[BOT_IDS["hard"]].rating < 1200 and players[a].rating > 1000


def test_new_player_is_recommended_easy():
    rec = engine.recommend(None, engine.rate([]))
    assert rec["ai_level"]["level"] == "easy" and rec["ai_level"]["reason"] == "first_match"
    assert rec["player"]["rating"] == 1000 and rec["player"]["provisional"]
    assert [o["level"] for o in rec["ai_level"]["options"]] == ["easy", "normal", "hard"]


def test_winning_streak_moves_the_recommendation_up():
    a = pid("a")
    history, n = [], 0
    for level in ("easy", "easy", "normal", "normal", "hard", "hard"):
        n += 1
        history.append(match(a, BOT_IDS[level], 4, 0, n))
    levels = []
    for k in range(len(history) + 1):
        levels.append(engine.recommend(a, engine.rate(history[:k]))["ai_level"]["level"])
    assert levels[0] == "easy" and levels[-1] == "hard"
    order = {"easy": 0, "normal": 1, "hard": 2}
    assert all(order[x] <= order[y] for x, y in zip(levels, levels[1:]))


def test_losing_streak_moves_the_recommendation_down():
    a = pid("a")
    history = [match(a, BOT_IDS["easy"], 0, 3, n) for n in range(1, 4)]
    players = engine.rate(history)
    rec = engine.recommend(a, players)
    assert rec["ai_level"]["level"] == "easy" and rec["ai_level"]["reason"] == "build_confidence"
    assert rec["player"]["form"] == "LLL"


def test_recommended_level_is_closest_to_the_target():
    a = pid("a")
    players = engine.rate([match(a, pid("b"), 3, 0, n) for n in range(1, 4)])
    rec = engine.recommend(a, players)["ai_level"]
    best = min(abs(o["win_probability"] - engine.TARGET_SCORE) for o in rec["options"])
    assert abs(rec["win_probability"] - engine.TARGET_SCORE) == pytest.approx(best)


def test_rivals_are_the_closest_humans_excluding_self_and_bots():
    me, near, mid, far = pid("me"), pid("near"), pid("mid"), pid("far")
    other = pid("other")
    history = [match(near, other, 1, 0, 1), match(mid, other, 2, 0, 2), match(far, other, 6, 0, 3),
               match(me, BOT_IDS["easy"], 1, 0, 4), match(far, other, 6, 0, 5)]
    rivals = engine.recommend(me, engine.rate(history))["rivals"]
    ids = [r["player_id"] for r in rivals]
    assert me not in ids and not set(ids) & set(BOT_IDS.values())
    assert len(rivals) == engine.MAX_RIVALS
    diffs = [abs(r["rating"] - engine.rate(history)[me].rating) for r in rivals]
    assert diffs == sorted(diffs)
    assert all(0 < r["win_probability"] < 1 for r in rivals)


def test_malformed_player_id_is_rejected():
    with pytest.raises(ValueError):
        engine.recommend("not-a-uuid", engine.rate([]))


def test_unknown_player_id_is_a_new_player():
    rec = engine.recommend(pid("nobody"), engine.rate([]))
    assert rec["player"]["player_id"] == pid("nobody") and rec["player"]["played"] == 0
