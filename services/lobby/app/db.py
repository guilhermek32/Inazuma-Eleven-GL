"""Lobby-owned PostgreSQL schema and connection pool.

players       guest identities (UUID) and their last display name
rooms         one per human-readable room code; match_id is an independent
              UUID; status mirrors the runtime (see service.py)
reservations  at most one per (room, team); request_id makes create/join
              idempotent; confirmed once the runtime acknowledged it
"""

from __future__ import annotations

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

SCHEMA = """
CREATE TABLE IF NOT EXISTS players (
    player_id    UUID PRIMARY KEY,
    nickname     TEXT NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS rooms (
    room_code         TEXT PRIMARY KEY,
    match_id          UUID NOT NULL UNIQUE,
    mode              TEXT NOT NULL,
    half_length_s     INTEGER NOT NULL,
    config            JSONB NOT NULL,
    status            TEXT NOT NULL,
    runtime_boot_id   TEXT,
    expires_at        BIGINT NOT NULL,
    create_request_id TEXT NOT NULL UNIQUE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS rooms_active_idx ON rooms (status)
    WHERE status IN ('provisioning', 'waiting', 'running', 'paused');
CREATE TABLE IF NOT EXISTS reservations (
    reservation_id UUID PRIMARY KEY,
    room_code      TEXT NOT NULL REFERENCES rooms (room_code) ON DELETE CASCADE,
    team           SMALLINT NOT NULL CHECK (team IN (0, 1)),
    player_id      UUID NOT NULL REFERENCES players (player_id),
    nickname       TEXT NOT NULL,
    request_id     TEXT NOT NULL UNIQUE,
    confirmed      BOOLEAN NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (room_code, team)
);
"""


def make_pool(database_url: str, max_size: int = 10) -> ConnectionPool:
    pool = ConnectionPool(database_url, min_size=1, max_size=max_size, open=True,
                          kwargs={"row_factory": dict_row})
    pool.wait(timeout=30)
    return pool


def init_schema(pool: ConnectionPool) -> None:
    with pool.connection() as conn:
        conn.execute("SELECT pg_advisory_xact_lock(4711)")
        conn.execute(SCHEMA)
