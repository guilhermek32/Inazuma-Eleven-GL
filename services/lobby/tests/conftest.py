"""Fixtures: a throwaway PostgreSQL database (TEST_DATABASE_URL points at a
server where we may create databases) and an in-memory fake of the match
runtime's control API, plugged into the lobby through httpx.MockTransport."""

from __future__ import annotations

import json
import os
import re
import threading
import uuid

import httpx
import psycopg
import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

SECRET = b"lobby-test-secret"
CONTROL_TOKEN = "control-token"
TEST_DB = "lobby_test"


@pytest.fixture(scope="session")
def database_url() -> str:
    admin = os.environ.get("TEST_DATABASE_URL", "postgresql://postgres:test@localhost:5432/postgres")
    with psycopg.connect(admin, autocommit=True) as conn:
        conn.execute(f"DROP DATABASE IF EXISTS {TEST_DB} WITH (FORCE)")
        conn.execute(f"CREATE DATABASE {TEST_DB}")
    return re.sub(r"/[^/]*$", "/" + TEST_DB, admin)


class FakeRuntime:
    """The runtime control API's semantics, in memory and thread-safe."""

    def __init__(self):
        self.lock = threading.Lock()
        self.boot_id = str(uuid.uuid4())
        self.matches: dict[str, dict] = {}
        self.terminal: dict[str, str] = {}
        self.down = False
        self.fail_reserve = False
        self.calls: list[tuple[str, str]] = []

    def restart(self) -> None:
        with self.lock:
            self.boot_id = str(uuid.uuid4())
            self.matches.clear()

    def set_state(self, match_id: str, state: str) -> None:
        with self.lock:
            if state in ("completed", "cancelled"):
                self.terminal[match_id] = state
                self.matches.pop(match_id, None)
            else:
                self.matches[match_id]["state"] = state

    def _status(self, match_id: str, m: dict) -> dict:
        return {"match_id": match_id, "state": m["state"], "boot_id": self.boot_id,
                "connected": [False, False], "reserved": [r is not None for r in m["res"]],
                "reservations": [r["reservation_id"] if r else None for r in m["res"]], "score": [0, 0]}

    def handle(self, request: httpx.Request) -> httpx.Response:
        if self.down:
            raise httpx.ConnectError("runtime down", request=request)
        assert request.headers["authorization"] == f"Bearer {CONTROL_TOKEN}"
        path, method = request.url.path, request.method
        body = json.loads(request.content) if request.content else None
        with self.lock:
            self.calls.append((method, path))
            m = re.fullmatch(r"/internal/v1/matches/([^/]+)/reservations/(\d)", path)
            if m:
                match_id, team = m.group(1), int(m.group(2))
                if self.fail_reserve:
                    return httpx.Response(503, json={"error": "boom"})
                if match_id in self.terminal:
                    return httpx.Response(409, json={"error": "match is terminal"})
                match = self.matches.get(match_id)
                if match is None:
                    return httpx.Response(404, json={"error": "unknown match", "boot_id": self.boot_id})
                if match["res"][team] == body:
                    return httpx.Response(200, json=self._status(match_id, match))
                if match["res"][team] is not None or match["state"] != "waiting":
                    return httpx.Response(409, json={"error": "team already reserved"})
                match["res"][team] = body
                return httpx.Response(201, json=self._status(match_id, match))
            match_id = path.rsplit("/", 1)[-1]
            match = self.matches.get(match_id)
            if method == "PUT":
                if match_id in self.terminal:
                    return httpx.Response(409, json={"error": "match is terminal"})
                if match is not None:
                    same = match["config"] == body["config"] and match["expires_at"] == body["expires_at"]
                    return httpx.Response(200 if same else 409, json=self._status(match_id, match))
                self.matches[match_id] = {"config": body["config"], "expires_at": body["expires_at"],
                                          "state": "waiting", "res": [None, None]}
                return httpx.Response(201, json=self._status(match_id, self.matches[match_id]))
            if method == "GET":
                if match is not None:
                    return httpx.Response(200, json=self._status(match_id, match))
                if match_id in self.terminal:
                    return httpx.Response(200, json={"match_id": match_id, "state": self.terminal[match_id],
                                                     "boot_id": self.boot_id, "connected": [False, False]})
                return httpx.Response(404, json={"error": "unknown match", "boot_id": self.boot_id})
            if method == "DELETE":
                if match is None:
                    return httpx.Response(404, json={"error": "unknown match"})
                if match["state"] != "waiting":
                    return httpx.Response(409, json={"error": "match is running"})
                del self.matches[match_id]
                self.terminal[match_id] = "cancelled"
                return httpx.Response(200, json={"state": "cancelled"})
        return httpx.Response(405)


@pytest.fixture
def fake_runtime() -> FakeRuntime:
    return FakeRuntime()


@pytest.fixture
def settings(database_url) -> Settings:
    return Settings(database_url=database_url, match_secret=SECRET, runtime_control_url="http://runtime",
                    runtime_control_token=CONTROL_TOKEN)


@pytest.fixture
def client(settings, fake_runtime):
    app = create_app(settings, runtime_transport=httpx.MockTransport(fake_runtime.handle), background=False)
    with app.state.service.pool.connection() as conn:
        conn.execute("TRUNCATE reservations, rooms, players")
    with TestClient(app) as c:
        c.service = app.state.service
        yield c
