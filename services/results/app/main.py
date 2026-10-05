"""Results HTTP API.

Internal (match runtime only; never routed by the gateway):
  POST /internal/v1/matches     "Authorization: Bearer <RESULTS_INGEST_TOKEN>",
                                body: see models.py. 201 created, 200 identical
                                duplicate, 409 conflicting duplicate, 401, 413,
                                422 invalid.
Public (gateway: /api/stats/v1/... with the /api/stats prefix stripped):
  GET /v1/matches/recent?limit=&cursor=   newest first
  GET /v1/leaderboard?limit=&cursor=      ranking documented in service.py
  -> {"items": [...], "next_cursor": str | null}
  GET /health

Environment: DATABASE_URL, RESULTS_INGEST_TOKEN (both required).
Run: uvicorn app.main:create_app --factory --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import hmac
import json
import os
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Query, Request
from fastapi.responses import JSONResponse
from pydantic import ValidationError
from starlette.concurrency import run_in_threadpool

from . import logs
from .db import init_schema, make_pool
from .logs import log_event
from .models import MatchResult
from .service import BadCursor, ResultsService

MAX_BODY_BYTES = 65536


def create_app(database_url: str | None = None, ingest_token: str | None = None) -> FastAPI:
    logs.setup("results")
    database_url = database_url or os.environ.get("DATABASE_URL", "")
    ingest_token = ingest_token if ingest_token is not None else os.environ.get("RESULTS_INGEST_TOKEN", "")
    if not database_url or not ingest_token:
        raise RuntimeError("DATABASE_URL and RESULTS_INGEST_TOKEN are required")
    pool = make_pool(database_url)
    init_schema(pool)
    service = ResultsService(pool)
    expected_auth = f"Bearer {ingest_token}".encode()

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        log_event("results_started")
        yield
        pool.close()

    app = FastAPI(title="Inazuma results", version="1", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.service = service

    @app.middleware("http")
    async def access_log(request: Request, call_next):
        t0 = time.perf_counter()
        response = await call_next(request)
        if request.url.path != "/health":
            log_event("request", method=request.method, path=request.url.path, status=response.status_code,
                      ms=round((time.perf_counter() - t0) * 1000, 1))
        return response

    @app.exception_handler(BadCursor)
    async def bad_cursor(_request: Request, exc: BadCursor):
        return JSONResponse({"error": "invalid_cursor", "detail": str(exc)}, status_code=400)

    @app.get("/health")
    def health():
        try:
            with pool.connection(timeout=2) as conn:
                conn.execute("SELECT 1")
        except Exception as e:
            return JSONResponse({"status": "unhealthy", "detail": str(e)}, status_code=503)
        return {"status": "ok"}

    @app.post("/internal/v1/matches")
    async def ingest(request: Request):
        if not hmac.compare_digest(request.headers.get("authorization", "").encode(), expected_auth):
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        body = await request.body()
        if len(body) > MAX_BODY_BYTES:
            return JSONResponse({"error": "too_large"}, status_code=413)
        try:
            document = json.loads(body)
            result = MatchResult.model_validate(document)
        except ValueError as e:   # JSON errors and ValidationError alike
            detail = e.errors(include_url=False, include_context=False) if isinstance(e, ValidationError) else str(e)
            log_event("result_invalid", detail=str(detail)[:300])
            return JSONResponse({"error": "invalid_result", "detail": json.loads(json.dumps(detail, default=str))},
                                status_code=422)
        status, reply = await run_in_threadpool(service.ingest, document, result)
        log_event({201: "result_recorded", 200: "result_duplicate"}.get(status, "result_conflict"),
                  match_id=str(result.match_id), reason=result.reason, status=status)
        return JSONResponse(reply, status_code=status)

    @app.get("/v1/matches/recent")
    def recent(limit: int = Query(20, ge=1, le=100), cursor: str | None = Query(None, max_length=512)):
        return service.recent(limit, cursor)

    @app.get("/v1/leaderboard")
    def leaderboard(limit: int = Query(20, ge=1, le=100), cursor: str | None = Query(None, max_length=512)):
        return service.leaderboard(limit, cursor)

    return app
