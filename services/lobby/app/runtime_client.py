"""Client of the match runtime's internal control API (see
scripts/server/runtime_control_api.gd for the contract).

Errors are mapped to exceptions the lobby can act on:
  RuntimeUnavailable  network error, timeout, 5xx, or 401/403 (misconfiguration)
  RuntimeConflict     409: conflicting provisioning/reservation or terminal match
  RuntimeNotFound     404: the runtime doesn't know the match
  RuntimeRejected     400: the runtime refused our request as invalid
"""

from __future__ import annotations

import httpx


class RuntimeError_(Exception):
    def __init__(self, message: str, body: dict | None = None):
        super().__init__(message)
        self.body = body or {}


class RuntimeUnavailable(RuntimeError_):
    pass


class RuntimeConflict(RuntimeError_):
    pass


class RuntimeNotFound(RuntimeError_):
    pass


class RuntimeRejected(RuntimeError_):
    pass


class RuntimeClient:
    def __init__(self, base_url: str, token: str, timeout_s: float = 3.0,
                 transport: httpx.BaseTransport | None = None):
        self._http = httpx.Client(base_url=base_url, timeout=timeout_s, transport=transport,
                                  headers={"Authorization": f"Bearer {token}"})

    def close(self) -> None:
        self._http.close()

    def _call(self, method: str, path: str, json: dict | None = None) -> tuple[int, dict]:
        try:
            r = self._http.request(method, path, json=json)
        except httpx.HTTPError as e:
            raise RuntimeUnavailable(f"{type(e).__name__}: {e}") from None
        try:
            body = r.json()
        except ValueError:
            body = {}
        if not isinstance(body, dict):
            body = {}
        code = r.status_code
        if code >= 500 or code in (401, 403):
            raise RuntimeUnavailable(f"runtime answered {code}", body)
        if code == 409:
            raise RuntimeConflict(str(body.get("error", "conflict")), body)
        if code == 404:
            raise RuntimeNotFound(str(body.get("error", "not found")), body)
        if code >= 400:
            raise RuntimeRejected(str(body.get("error", f"status {code}")), body)
        return code, body

    def provision(self, match_id: str, config: dict, expires_at: int) -> dict:
        return self._call("PUT", f"/internal/v1/matches/{match_id}",
                          {"config": config, "expires_at": expires_at})[1]

    def reserve(self, match_id: str, team: int, reservation_id: str, player_id: str, nickname: str) -> dict:
        return self._call("PUT", f"/internal/v1/matches/{match_id}/reservations/{team}",
                          {"reservation_id": reservation_id, "player_id": player_id, "nickname": nickname})[1]

    def status(self, match_id: str) -> dict | None:
        """The match's runtime status, or None when the runtime doesn't know it."""
        try:
            return self._call("GET", f"/internal/v1/matches/{match_id}")[1]
        except RuntimeNotFound:
            return None

    def cancel(self, match_id: str) -> dict:
        return self._call("DELETE", f"/internal/v1/matches/{match_id}")[1]
