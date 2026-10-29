"""The service's read model: the counted match history, copied from the results
service's public API, and the ratings computed from it.

The recommendation service owns no database. It reads GET /v1/matches/recent
(newest first, keyset pages) from results and keeps the newest MAX_HISTORY
counted matches in memory; ratings are recomputed from that history (oldest
first) after every change. A restart simply re-reads the history.

Refresh policy, run lazily on a request (never more than one at a time; a
request that finds a refresh in progress uses the current model):
  incremental  at most every REFRESH_S: read pages until one holds a match
               already known (results are recorded about when they finish)
  full         every FULL_SYNC_S: re-read up to MAX_HISTORY, which also
               picks up a result the runtime's spool delivered late
If results is unreachable the last model is served, marked stale; before the
first successful read there is no model (ModelUnavailable -> 503).
"""

from __future__ import annotations

import threading
import time
from typing import Callable

from . import engine
from .logs import log_event

REFRESH_S = 10.0
FULL_SYNC_S = 300.0
MAX_HISTORY = 5000
PAGE_SIZE = 100


class FeedError(Exception):
    """The results service could not be read."""


class ModelUnavailable(Exception):
    """No history has been read yet."""


def counted(item: dict) -> bool:
    """Whether a results item decides points (the results service's own rule)."""
    return item.get("reason") == "full_time" or (item.get("reason") == "forfeit" and item.get("winner") is not None)


def to_match(item: dict) -> engine.Match | None:
    players = {int(p["team"]): p for p in item.get("players", [])}
    if 0 not in players or 1 not in players:
        return None
    score = item.get("score") or [0, 0]
    return engine.Match(match_id=str(item["match_id"]), finished_at=str(item["finished_at"]),
                        left=str(players[0]["player_id"]), right=str(players[1]["player_id"]),
                        left_nickname=str(players[0].get("nickname", "")),
                        right_nickname=str(players[1].get("nickname", "")),
                        score_left=int(score[0]), score_right=int(score[1]), winner=item.get("winner"))


class RecommendationModel:
    def __init__(self, fetch_page: Callable[[int, str | None], dict], refresh_s: float = REFRESH_S,
                 full_sync_s: float = FULL_SYNC_S, max_history: int = MAX_HISTORY,
                 clock: Callable[[], float] = time.monotonic):
        self._fetch_page = fetch_page
        self.refresh_s = refresh_s
        self.full_sync_s = full_sync_s
        self.max_history = max_history
        self._clock = clock
        self._lock = threading.Lock()
        self._matches: dict[str, engine.Match] = {}
        self._players: dict[str, engine.Player] | None = None
        self._last_refresh: float | None = None
        self._last_full: float | None = None
        self.stale = True
        self.updated_at: float | None = None   # wall clock of the last successful read

    def refresh(self) -> None:
        """Brings the history up to date if it is due (see the module doc)."""
        now = self._clock()
        # Throttled even while results is down, so an outage costs one timeout per REFRESH_S, not per request.
        if self._last_refresh is not None and now - self._last_refresh < self.refresh_s:
            return
        if not self._lock.acquire(blocking=False):
            return
        try:
            full = self._last_full is None or now - self._last_full >= self.full_sync_s
            self._last_refresh = now
            try:
                items = self._read(full)
            except FeedError as e:
                self.stale = True
                log_event("results_unreachable", detail=str(e)[:200])
                return
            if full:
                self._matches = {}
                self._last_full = now
            changed = full
            for item in items:
                if counted(item) and str(item["match_id"]) not in self._matches:
                    match = to_match(item)
                    if match is not None:
                        self._matches[match.match_id] = match
                        changed = True
            if changed or self._players is None:
                history = sorted(self._matches.values(), key=lambda m: (m.finished_at, m.match_id))
                history = history[-self.max_history:]
                self._matches = {m.match_id: m for m in history}
                self._players = engine.rate(history)
                log_event("model_rebuilt", matches=len(history), players=len(self._players), full=full)
            self.stale = False
            self.updated_at = time.time()
        finally:
            self._lock.release()

    def _read(self, full: bool) -> list[dict]:
        items: list[dict] = []
        cursor = None
        while len(items) < self.max_history:
            page = self._fetch_page(PAGE_SIZE, cursor)
            batch = page.get("items", [])
            items.extend(batch)
            if not full and any(str(i.get("match_id")) in self._matches for i in batch):
                break
            cursor = page.get("next_cursor")
            if not cursor or not batch:
                break
        return items

    def players(self) -> dict[str, engine.Player]:
        if self._players is None:
            raise ModelUnavailable("the match history has not been read yet")
        return self._players

    def info(self) -> dict:
        return {"matches": len(self._matches), "players": len(self._players or {}), "stale": self.stale,
                "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self.updated_at))
                if self.updated_at else None}
