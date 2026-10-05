"""Results storage and read models.

Ingestion is idempotent by match_id: the first submission is stored (201);
a later one whose canonical JSON (sorted keys, compact) hashes the same is an
identical duplicate (200); anything else for that match_id conflicts (409).

Leaderboard ranking (documented contract): over counted matches (full time,
or a forfeit with a winner), a win is 3 points, a draw 1, a loss 0. Players
are ordered by points, then goal difference, then goals for (all
descending), then player_id ascending as a stable tie-break. Both read models
use keyset pagination with an opaque cursor.
"""

from __future__ import annotations

import base64
import hashlib
import json

from .models import MatchResult

POINTS = {"win": 3, "draw": 1, "loss": 0}


class BadCursor(ValueError):
    pass


def canonical_hash(document: dict) -> str:
    canonical = json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def encode_cursor(values: list) -> str:
    return base64.urlsafe_b64encode(json.dumps(values, default=str).encode()).decode().rstrip("=")


def decode_cursor(cursor: str, arity: int) -> list:
    try:
        values = json.loads(base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)))
    except (ValueError, TypeError):
        raise BadCursor("invalid cursor") from None
    if not isinstance(values, list) or len(values) != arity:
        raise BadCursor("invalid cursor")
    return values


class ResultsService:
    def __init__(self, pool):
        self.pool = pool

    def ingest(self, document: dict, result: MatchResult) -> tuple[int, dict]:
        digest = canonical_hash(document)
        match_id = str(result.match_id)
        with self.pool.connection() as conn, conn.transaction():
            inserted = conn.execute(
                "INSERT INTO matches (match_id, payload_hash, payload, config_version, reason, score_left, score_right, "
                "winner, started_at, finished_at) VALUES (%s, %s, %s::jsonb, %s, %s, %s, %s, %s, %s, %s) "
                "ON CONFLICT (match_id) DO NOTHING RETURNING match_id",
                (match_id, digest, json.dumps(document), result.config_version, result.reason, result.score_left,
                 result.score_right, result.winner, result.started_at, result.finished_at)).fetchone()
            if inserted is None:
                existing = conn.execute("SELECT payload_hash FROM matches WHERE match_id = %s", (match_id,)).fetchone()
                if existing["payload_hash"] == digest:
                    return 200, {"status": "duplicate", "match_id": match_id}
                return 409, {"error": "conflict", "detail": "a different result is already recorded for this match"}
            scores = (result.score_left, result.score_right)
            for team in (0, 1):
                p = result.player(team)
                outcome = "draw" if result.winner is None else ("win" if result.winner == team else "loss")
                conn.execute(
                    "INSERT INTO match_players (match_id, team, player_id, nickname, goals_for, goals_against, points, "
                    "outcome, counted, finished_at) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
                    (match_id, team, p.player_id, p.nickname, scores[team], scores[1 - team], POINTS[outcome],
                     outcome, result.counted(), result.finished_at))
        return 201, {"status": "created", "match_id": match_id}

    def recent(self, limit: int, cursor: str | None) -> dict:
        where, params = "", []
        if cursor:
            finished_at, match_id = decode_cursor(cursor, 2)
            where, params = "WHERE (finished_at, match_id) < (%s::timestamptz, %s::uuid)", [finished_at, match_id]
        with self.pool.connection() as conn:
            rows = conn.execute(
                "SELECT match_id, reason, score_left, score_right, winner, started_at, finished_at, "
                f"payload->'stats' AS stats FROM matches {where} ORDER BY finished_at DESC, match_id DESC LIMIT %s",
                (*params, limit + 1)).fetchall()
            page = rows[:limit]
            players = conn.execute(
                "SELECT match_id, team, player_id, nickname FROM match_players WHERE match_id = ANY(%s) ORDER BY team",
                ([r["match_id"] for r in page],)).fetchall()
        by_match: dict = {}
        for p in players:
            by_match.setdefault(p["match_id"], []).append(
                {"team": p["team"], "player_id": str(p["player_id"]), "nickname": p["nickname"]})
        items = [{"match_id": str(r["match_id"]), "reason": r["reason"], "score": [r["score_left"], r["score_right"]],
                  "winner": r["winner"], "players": by_match.get(r["match_id"], []), "stats": r["stats"] or [],
                  "started_at": r["started_at"].isoformat() if r["started_at"] else None,
                  "finished_at": r["finished_at"].isoformat()} for r in page]
        next_cursor = encode_cursor([page[-1]["finished_at"].isoformat(), str(page[-1]["match_id"])]) \
            if len(rows) > limit else None
        return {"items": items, "next_cursor": next_cursor}

    def leaderboard(self, limit: int, cursor: str | None) -> dict:
        where, params = "", []
        if cursor:
            points, gd, gf, player_id = decode_cursor(cursor, 4)
            try:
                key = (-int(points), -int(gd), -int(gf), str(player_id))
            except (TypeError, ValueError):
                raise BadCursor("invalid cursor") from None
            where, params = "WHERE (-points, -goal_diff, -goals_for, player_id) > (%s, %s, %s, %s::uuid)", list(key)
        sql = f"""
            WITH agg AS (
                SELECT player_id, SUM(points)::int AS points, SUM(goals_for - goals_against)::int AS goal_diff,
                       SUM(goals_for)::int AS goals_for, SUM(goals_against)::int AS goals_against,
                       COUNT(*)::int AS played, COUNT(*) FILTER (WHERE outcome = 'win')::int AS wins,
                       COUNT(*) FILTER (WHERE outcome = 'draw')::int AS draws,
                       COUNT(*) FILTER (WHERE outcome = 'loss')::int AS losses
                FROM match_players WHERE counted GROUP BY player_id
            ), ranked AS (
                SELECT agg.*, RANK() OVER (ORDER BY points DESC, goal_diff DESC, goals_for DESC) AS rank,
                       (SELECT nickname FROM match_players mp WHERE mp.player_id = agg.player_id
                        ORDER BY finished_at DESC LIMIT 1) AS nickname
                FROM agg
            )
            SELECT * FROM ranked {where}
            ORDER BY points DESC, goal_diff DESC, goals_for DESC, player_id ASC LIMIT %s"""
        with self.pool.connection() as conn:
            rows = conn.execute(sql, (*params, limit + 1)).fetchall()
        page = rows[:limit]
        items = [{**r, "player_id": str(r["player_id"])} for r in page]
        next_cursor = encode_cursor([page[-1]["points"], page[-1]["goal_diff"], page[-1]["goals_for"],
                                     str(page[-1]["player_id"])]) if len(rows) > limit else None
        return {"items": items, "next_cursor": next_cursor}
