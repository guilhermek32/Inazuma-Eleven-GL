"""Fixtures: a throwaway PostgreSQL database and a TestClient per test."""

from __future__ import annotations

import os
import re
import uuid
from datetime import datetime, timedelta, timezone

import psycopg
import pytest
from fastapi.testclient import TestClient

from app.main import create_app

INGEST_TOKEN = "ingest-token"
AUTH = {"Authorization": f"Bearer {INGEST_TOKEN}"}
TEST_DB = "results_test"
T0 = datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc)


@pytest.fixture(scope="session")
def database_url() -> str:
    admin = os.environ.get("TEST_DATABASE_URL", "postgresql://postgres:test@localhost:5432/postgres")
    with psycopg.connect(admin, autocommit=True) as conn:
        conn.execute(f"DROP DATABASE IF EXISTS {TEST_DB} WITH (FORCE)")
        conn.execute(f"CREATE DATABASE {TEST_DB}")
    return re.sub(r"/[^/]*$", "/" + TEST_DB, admin)


@pytest.fixture
def client(database_url):
    app = create_app(database_url, INGEST_TOKEN)
    with app.state.service.pool.connection() as conn:
        conn.execute("TRUNCATE match_players, matches")
    with TestClient(app) as c:
        yield c


def result(p0: str, p1: str, left: int, right: int, reason: str = "full_time", minute: int = 0,
           winner: int | None | str = "auto", match_id: str | None = None) -> dict:
    """A runtime-shaped result document; `minute` orders finish times."""
    if winner == "auto":
        winner = 0 if left > right else (1 if right > left else None)
    finished = T0 + timedelta(minutes=minute)
    return {
        "match_id": match_id or str(uuid.uuid4()), "config_version": 1,
        "config": {"version": 1, "half_length_s": 30.0},
        "players": [{"team": 0, "player_id": p0, "nickname": "P-" + p0[:4]},
                    {"team": 1, "player_id": p1, "nickname": "P-" + p1[:4]}],
        "score_left": left, "score_right": right, "winner": winner, "reason": reason,
        "stats": [{"possession": 31.5, "shots": 4}, {"possession": 28.5, "shots": 2}],
        "started_at": (finished - timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "finished_at": finished.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "runtime_boot_id": "boot-1",
    }
