"""Lobby configuration, read once from the environment.

    DATABASE_URL            PostgreSQL URL of the lobby-owned database
    MATCH_SECRET            HMAC key shared with the match runtime (credentials)
    RUNTIME_CONTROL_URL     match runtime control API, e.g. http://match-runtime:8911
    RUNTIME_CONTROL_TOKEN   bearer token for that API
    TOKEN_TTL_S             credential lifetime (default 7200 s)
    RECONCILE_INTERVAL_S    background reconciliation period (default 30 s)
    BOT_SERVICE_URL         ai-bot job API, e.g. http://ai-bot:8920 (optional:
                            unset = "vs_ai" rooms are refused with 503)
    BOT_CONTROL_TOKEN       bearer token for that API
    BOT_RUNTIME_WS_URL      match runtime WebSocket base the bot connects to
                            (internal, default ws://match-runtime:8910)
    BOT_JOIN_TIMEOUT_S      how long a vs-AI creation waits for the bot to join (default 12 s)
"""

from __future__ import annotations

import os
from dataclasses import dataclass

REQUIRED = ("DATABASE_URL", "MATCH_SECRET", "RUNTIME_CONTROL_URL", "RUNTIME_CONTROL_TOKEN")


@dataclass(frozen=True)
class Settings:
    database_url: str
    match_secret: bytes
    runtime_control_url: str
    runtime_control_token: str
    token_ttl_s: int = 7200
    runtime_timeout_s: float = 3.0
    reconcile_interval_s: float = 30.0
    # An unconfirmed join older than this, unknown to the runtime, is released.
    pending_reservation_ttl_s: int = 60
    # A room still "provisioning" after this long (lobby crashed mid-create) is cleaned up.
    stale_provisioning_s: int = 120
    bot_service_url: str = ""
    bot_control_token: str = ""
    bot_runtime_ws_url: str = "ws://match-runtime:8910"
    bot_join_timeout_s: float = 12.0
    bot_poll_interval_s: float = 0.2
    bot_timeout_s: float = 3.0

    @classmethod
    def from_env(cls, env: dict | None = None) -> "Settings":
        env = dict(os.environ if env is None else env)
        missing = [k for k in REQUIRED if not env.get(k)]
        if missing:
            raise RuntimeError("missing required environment: " + ", ".join(missing))
        return cls(database_url=env["DATABASE_URL"], match_secret=env["MATCH_SECRET"].encode("utf-8"),
                   runtime_control_url=env["RUNTIME_CONTROL_URL"].rstrip("/"),
                   runtime_control_token=env["RUNTIME_CONTROL_TOKEN"],
                   token_ttl_s=int(env.get("TOKEN_TTL_S", 7200)),
                   reconcile_interval_s=float(env.get("RECONCILE_INTERVAL_S", 30)),
                   bot_service_url=env.get("BOT_SERVICE_URL", "").rstrip("/"),
                   bot_control_token=env.get("BOT_CONTROL_TOKEN", ""),
                   bot_runtime_ws_url=env.get("BOT_RUNTIME_WS_URL", "ws://match-runtime:8910").rstrip("/"),
                   bot_join_timeout_s=float(env.get("BOT_JOIN_TIMEOUT_S", 12)))
