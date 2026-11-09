"""Results-owned PostgreSQL schema and connection pool.

matches        one row per match_id (the runtime's UUID), with the exact
               submitted document and its canonical hash for duplicate checks
match_players  one row per (match, team): the read model behind history and
               the leaderboard; counted = the match decides points
"""

from __future__ import annotations

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

SCHEMA = """
CREATE TABLE IF NOT EXISTS matches (
    match_id        UUID PRIMARY KEY,
    payload_hash    TEXT NOT NULL,
    payload         JSONB NOT NULL,
    config_version  INTEGER NOT NULL,
    reason          TEXT NOT NULL,
    score_left      INTEGER NOT NULL,
    score_right     INTEGER NOT NULL,
    winner          SMALLINT,
    started_at      TIMESTAMPTZ,
    finished_at     TIMESTAMPTZ NOT NULL,
    received_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS matches_recent_idx ON matches (finished_at DESC, match_id DESC);
CREATE TABLE IF NOT EXISTS match_players (
    match_id       UUID NOT NULL REFERENCES matches (match_id) ON DELETE CASCADE,
    team           SMALLINT NOT NULL CHECK (team IN (0, 1)),
    player_id      UUID NOT NULL,
    nickname       TEXT NOT NULL,
    goals_for      INTEGER NOT NULL,
    goals_against  INTEGER NOT NULL,
    points         INTEGER NOT NULL,
    outcome        TEXT NOT NULL CHECK (outcome IN ('win', 'draw', 'loss')),
    counted        BOOLEAN NOT NULL,
    finished_at    TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (match_id, team)
);
CREATE INDEX IF NOT EXISTS match_players_player_idx ON match_players (player_id, finished_at DESC);
"""


def make_pool(database_url: str, max_size: int = 10) -> ConnectionPool:
    pool = ConnectionPool(database_url, min_size=1, max_size=max_size, open=True,
                          kwargs={"row_factory": dict_row})
    pool.wait(timeout=30)
    return pool


def init_schema(pool: ConnectionPool) -> None:
    with pool.connection() as conn:
        conn.execute("SELECT pg_advisory_xact_lock(4712)")
        conn.execute(SCHEMA)
