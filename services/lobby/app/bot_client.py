"""Client of the ai-bot service's internal job API (see
scripts/bot/bot_job_api.gd for the contract), plus the bot's stable guest
identity per difficulty.

Errors are mapped to exceptions the lobby can act on:
  BotUnavailable  not configured, network error, timeout, 5xx (incl. 503 at
                  capacity), or 401/403 (misconfiguration)
  BotRejected     4xx: the bot service refused the job (409 conflicting job, 400)
"""

from __future__ import annotations

import uuid

import httpx

DIFFICULTIES = ("easy", "normal", "hard")
# MatchConfig.team_difficulty index of each difficulty (0 Easy, 1 Normal, 2 Hard).
DIFFICULTY_INDEX = {"easy": 0, "normal": 1, "hard": 2}
# Fixed namespace: the bot's guest player_id is uuid5(namespace, "ai-bot:<difficulty>"),
# the same in every deployment, so each difficulty is one stable leaderboard entry.
BOT_PLAYER_NAMESPACE = uuid.UUID("6f1c3a52-9d4e-4c1b-8a57-2f0e8b7d4c21")

JOINED_STATES = ("joined", "playing")
FAILED_STATES = ("stopped", "failed")


def bot_player(difficulty: str) -> tuple[uuid.UUID, str]:
    """(player_id, display name) of the AI opponent at `difficulty`."""
    return uuid.uuid5(BOT_PLAYER_NAMESPACE, f"ai-bot:{difficulty}"), f"AI ({difficulty.title()})"


class BotError(Exception):
    def __init__(self, message: str, body: dict | None = None):
        super().__init__(message)
        self.body = body or {}


class BotUnavailable(BotError):
    pass


class BotRejected(BotError):
    pass


class BotClient:
    def __init__(self, base_url: str, token: str, timeout_s: float = 3.0,
                 transport: httpx.BaseTransport | None = None):
        self.configured = bool(base_url)
        self._http = httpx.Client(base_url=base_url or "http://ai-bot.invalid", timeout=timeout_s,
                                  transport=transport, headers={"Authorization": f"Bearer {token}"})

    def close(self) -> None:
        self._http.close()

    def _call(self, method: str, path: str, json: dict | None = None) -> tuple[int, dict]:
        if not self.configured:
            raise BotUnavailable("the bot service is not configured")
        try:
            r = self._http.request(method, path, json=json)
        except httpx.HTTPError as e:
            raise BotUnavailable(f"{type(e).__name__}: {e}") from None
        try:
            body = r.json()
        except ValueError:
            body = {}
        if not isinstance(body, dict):
            body = {}
        code = r.status_code
        if code >= 500 or code in (401, 403):
            raise BotUnavailable(f"bot service answered {code}", body)
        if code >= 400 and code != 404:
            raise BotRejected(str(body.get("error", f"status {code}")), body)
        return code, body

    def submit(self, match_id: str, token: str, ws_url: str, difficulty: str) -> dict:
        code, body = self._call("POST", "/internal/v1/bots",
                                {"match_id": match_id, "token": token, "ws_url": ws_url, "difficulty": difficulty})
        if code == 404:
            raise BotUnavailable("bot service has no job API", body)
        return body

    def status(self, match_id: str) -> dict | None:
        """The job's state, or None when the bot service doesn't know it."""
        code, body = self._call("GET", f"/internal/v1/bots/{match_id}")
        return None if code == 404 else body

    def stop(self, match_id: str) -> None:
        self._call("DELETE", f"/internal/v1/bots/{match_id}")
