"""Helpers: results-shaped match items and a fake results service."""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timedelta, timezone

import httpx

T0 = datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc)


def pid(name: str) -> str:
    """A stable player UUID per test name."""
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, name))


def item(p0: str, p1: str, left: int, right: int, minute: int, reason: str = "full_time",
         winner: int | None | str = "auto", nick0: str | None = None, nick1: str | None = None) -> dict:
    """One GET /v1/matches/recent item, as the results service writes it."""
    if winner == "auto":
        winner = 0 if left > right else (1 if right > left else None)
    return {"match_id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"{p0}{p1}{minute}")), "reason": reason,
            "score": [left, right], "winner": winner,
            "players": [{"team": 0, "player_id": p0, "nickname": nick0 or p0[:6]},
                        {"team": 1, "player_id": p1, "nickname": nick1 or p1[:6]}],
            "stats": [], "started_at": None,
            "finished_at": (T0 + timedelta(minutes=minute)).isoformat()}


class FakeResults:
    """GET /v1/matches/recent over `items` (any order), newest first, cursor = offset."""

    def __init__(self, items: list[dict] | None = None):
        self.items = list(items or [])
        self.down = False
        self.requests = 0

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests += 1
        if self.down:
            raise httpx.ConnectError("results is down")
        if request.url.path != "/v1/matches/recent":
            return httpx.Response(404, json={"error": "not_found"})
        limit = int(request.url.params.get("limit", 20))
        offset = int(request.url.params.get("cursor", 0))
        ordered = sorted(self.items, key=lambda i: (i["finished_at"], i["match_id"]), reverse=True)
        page = ordered[offset:offset + limit]
        nxt = str(offset + limit) if offset + limit < len(ordered) else None
        return httpx.Response(200, content=json.dumps({"items": page, "next_cursor": nxt}))

    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handler)
