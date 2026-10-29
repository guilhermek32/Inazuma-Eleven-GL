"""Recommendation HTTP API.

Public (gateway: /api/recommendations/v1/... with the /api/recommendations
prefix stripped; read-only, no credentials):
  GET /v1/recommendations?player_id=<uuid>   player_id optional (absent or
        unknown = a new player). 200:
        {"player":   {player_id, nickname, rating, played, wins, draws, losses,
                      form ("WDL..", newest last), provisional},
         "ai_level": {level: easy|normal|hard, win_probability, reason:
                      first_match|build_confidence|matched_to_rating|top_level,
                      options: [{level, bot_rating, win_probability}] x3},
         "rivals":   [{player_id, nickname, rating, played, win_probability}] (<= 3),
         "model":    {matches, players, stale, updated_at}}
        400 invalid_player_id; 503 results_unavailable (no history read yet).
  GET /v1/ratings?limit=   the Elo ranking (bots included): {"items": [...]}
  GET /health              {"status": "ok", "model": {...}}; 200 even while
                           results is down (this service itself is up).
The model and its refresh policy: model.py; the algorithm: engine.py.

Environment: RESULTS_URL (required, e.g. http://results:8000).
Run: uvicorn app.main:create_app --factory --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import os
import time
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Query, Request
from fastapi.responses import JSONResponse

from . import engine, logs
from .logs import log_event
from .model import FeedError, ModelUnavailable, RecommendationModel


class ResultsFeed:
    """Reads the results service's public match history."""

    def __init__(self, base_url: str, timeout_s: float = 3.0, transport: httpx.BaseTransport | None = None):
        self._http = httpx.Client(base_url=base_url, timeout=timeout_s, transport=transport)

    def page(self, limit: int, cursor: str | None) -> dict:
        params = {"limit": limit} | ({"cursor": cursor} if cursor else {})
        try:
            r = self._http.get("/v1/matches/recent", params=params)
        except httpx.HTTPError as e:
            raise FeedError(f"{type(e).__name__}: {e}") from None
        if r.status_code != 200:
            raise FeedError(f"results answered {r.status_code}")
        try:
            body = r.json()
        except ValueError:
            raise FeedError("results answered non-JSON") from None
        if not isinstance(body, dict) or not isinstance(body.get("items"), list):
            raise FeedError("unexpected results page")
        return body

    def close(self) -> None:
        self._http.close()


def create_app(results_url: str | None = None, transport: httpx.BaseTransport | None = None,
               model: RecommendationModel | None = None) -> FastAPI:
    logs.setup("recommendation")
    results_url = results_url or os.environ.get("RESULTS_URL", "")
    if not results_url and model is None:
        raise RuntimeError("RESULTS_URL is required")
    feed = ResultsFeed(results_url or "http://results.invalid", transport=transport)
    model = model or RecommendationModel(feed.page)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        log_event("recommendation_started", results_url=results_url)
        yield
        feed.close()

    app = FastAPI(title="Inazuma recommendation", version="1", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.model = model

    @app.middleware("http")
    async def access_log(request: Request, call_next):
        t0 = time.perf_counter()
        response = await call_next(request)
        if request.url.path != "/health":
            log_event("request", method=request.method, path=request.url.path, status=response.status_code,
                      ms=round((time.perf_counter() - t0) * 1000, 1))
        return response

    @app.exception_handler(ModelUnavailable)
    async def unavailable(_request: Request, exc: ModelUnavailable):
        return JSONResponse({"error": "results_unavailable", "detail": str(exc)}, status_code=503)

    @app.get("/health")
    def health():
        return {"status": "ok", "model": model.info()}

    @app.get("/v1/recommendations")
    def recommendations(player_id: str | None = Query(None, max_length=64)):
        model.refresh()
        players = model.players()
        try:
            reply = engine.recommend(player_id or None, players)
        except ValueError:
            return JSONResponse({"error": "invalid_player_id", "detail": "player_id must be a UUID"},
                                status_code=400)
        return reply | {"model": model.info()}

    @app.get("/v1/ratings")
    def ratings(limit: int = Query(20, ge=1, le=100)):
        model.refresh()
        ranked = sorted(model.players().values(), key=lambda p: (-p.rating, p.player_id))[:limit]
        return {"items": [{"rank": i + 1, "player_id": p.player_id, "nickname": p.nickname,
                           "rating": round(p.rating), "played": p.played, "bot": p.is_bot}
                          for i, p in enumerate(ranked)], "model": model.info()}

    return app
