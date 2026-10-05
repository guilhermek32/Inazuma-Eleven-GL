"""Lobby HTTP API. Behind the gateway these routes are public under
/api/lobby (the gateway strips that prefix):

  POST /v1/rooms               {nickname, half_length_s, request_id, mode?, player_id?}
                               -> 201 {room_code, match_id, team: 0, token, ws_url, play_url, player_id, ...}
  POST /v1/rooms/{code}/join   {nickname, request_id, player_id?} -> 200 {... team: 1 ...}
  GET  /v1/rooms/{code}        -> 200 {room_code, match_id, status, players, ...}
  GET  /health                 -> 200 {status: "ok"} when the database answers

Errors are {"error": code, "detail": text}: 404 unknown room/player, 409
room full/closed or request_id reused differently, 422 invalid input, 503
runtime unavailable. Create and join are idempotent by request_id.

Run: uvicorn app.main:create_app --factory --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import re
import threading
import time
import uuid
from contextlib import asynccontextmanager
from typing import Literal

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator

from . import logs
from .config import Settings
from .db import init_schema, make_pool
from .errors import LobbyError
from .logs import log_event
from .runtime_client import RuntimeClient
from .service import LobbyService

NICKNAME_RE = re.compile(r"^[A-Za-z0-9_.\- ]{1,16}$")
REQUEST_ID_PATTERN = r"^[A-Za-z0-9_-]{8,64}$"
MIN_HALF_LENGTH_S = 30    # MatchConfig.MIN_HALF_LENGTH_S
MAX_HALF_LENGTH_S = 900   # MatchConfig.MAX_HALF_LENGTH_S


def _nickname(v: str) -> str:
    v = v.strip()
    if not NICKNAME_RE.match(v):
        raise ValueError("nickname must be 1-16 characters: letters, digits, space, _ . -")
    return v


class CreateRoom(BaseModel):
    model_config = ConfigDict(extra="forbid")
    nickname: str
    half_length_s: int = Field(default=120, ge=MIN_HALF_LENGTH_S, le=MAX_HALF_LENGTH_S)
    request_id: str = Field(pattern=REQUEST_ID_PATTERN)
    mode: Literal["pvp"] = "pvp"
    player_id: uuid.UUID | None = None

    @field_validator("nickname")
    @classmethod
    def check_nickname(cls, v: str) -> str:
        return _nickname(v)


class JoinRoom(BaseModel):
    model_config = ConfigDict(extra="forbid")
    nickname: str
    request_id: str = Field(pattern=REQUEST_ID_PATTERN)
    player_id: uuid.UUID | None = None

    @field_validator("nickname")
    @classmethod
    def check_nickname(cls, v: str) -> str:
        return _nickname(v)


def create_app(settings: Settings | None = None, runtime_transport=None, background: bool = True) -> FastAPI:
    logs.setup("lobby")
    settings = settings or Settings.from_env()
    pool = make_pool(settings.database_url)
    init_schema(pool)
    runtime = RuntimeClient(settings.runtime_control_url, settings.runtime_control_token,
                            settings.runtime_timeout_s, transport=runtime_transport)
    service = LobbyService(pool, runtime, settings)
    stop = threading.Event()

    def reconciler() -> None:
        while not stop.is_set():
            try:
                n = service.reconcile_all()
                if n:
                    log_event("reconciled", rooms=n)
            except Exception:   # keep the loop alive whatever happens
                log_event("reconcile_loop_error", level=40, exc_info=True)
            stop.wait(settings.reconcile_interval_s)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        worker = threading.Thread(target=reconciler, name="reconciler", daemon=True) if background else None
        if worker:
            worker.start()   # first pass right away: a restarted lobby converges at once
        log_event("lobby_started", runtime=settings.runtime_control_url)
        yield
        stop.set()
        if worker:
            worker.join(timeout=5)
        runtime.close()
        pool.close()

    app = FastAPI(title="Inazuma lobby", version="1", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.service = service

    @app.middleware("http")
    async def access_log(request: Request, call_next):
        t0 = time.perf_counter()
        response = await call_next(request)
        if request.url.path != "/health":
            log_event("request", method=request.method, path=request.url.path, status=response.status_code,
                      ms=round((time.perf_counter() - t0) * 1000, 1))
        return response

    @app.exception_handler(LobbyError)
    async def lobby_error(_request: Request, exc: LobbyError):
        return JSONResponse({"error": exc.error, "detail": exc.detail}, status_code=exc.status)

    @app.exception_handler(RequestValidationError)
    async def invalid(_request: Request, exc: RequestValidationError):
        problems = [{"field": ".".join(str(p) for p in e["loc"][1:]), "message": e["msg"]} for e in exc.errors()]
        return JSONResponse({"error": "invalid_request", "detail": problems}, status_code=422)

    @app.get("/health")
    def health():
        try:
            with pool.connection(timeout=2) as conn:
                conn.execute("SELECT 1")
        except Exception as e:
            return JSONResponse({"status": "unhealthy", "detail": str(e)}, status_code=503)
        return {"status": "ok"}

    @app.post("/v1/rooms", status_code=201)
    def create_room(body: CreateRoom):
        return service.create_room(body.nickname, body.half_length_s, body.request_id,
                                   str(body.player_id) if body.player_id else None)

    @app.post("/v1/rooms/{code}/join")
    def join_room(code: str, body: JoinRoom):
        return service.join_room(code, body.nickname, body.request_id,
                                 str(body.player_id) if body.player_id else None)

    @app.get("/v1/rooms/{code}")
    def room_status(code: str):
        return service.room_status(code)

    return app
