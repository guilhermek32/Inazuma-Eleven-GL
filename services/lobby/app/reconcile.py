"""Room status and reconciliation with the match runtime (mixed into
LobbyService). The runtime is the authority on live matches; the lobby
stores the last status it observed:

  runtime GET 200, live state, same boot_id   -> waiting / running / paused
  runtime GET 200, completed / cancelled      -> that terminal status
  runtime GET 200, live state, other boot_id  -> aborted
  runtime GET 404                             -> aborted (a restart lost it)
  runtime unreachable                         -> "unavailable" (reported, not stored)

Reconciliation also settles pending (unconfirmed) joins: confirmed when the
runtime holds that reservation, released when the runtime never saw it within
pending_reservation_ttl_s; and it cleans up rooms stuck in "provisioning"
(lobby crashed mid-create) after stale_provisioning_s. reconcile_all() runs at
startup and periodically, so a restarted lobby converges on its own.
"""

from __future__ import annotations

from .errors import NotFound
from .logs import log_event
from .runtime_client import RuntimeError_, RuntimeUnavailable

LIVE = ("waiting", "running", "paused")
TERMINAL = ("completed", "cancelled", "aborted")
ACTIVE = ("provisioning",) + LIVE


class ReconcileMixin:
    def room_status(self, code: str) -> dict:
        code = code.strip().upper()
        with self.pool.connection() as conn:
            room = conn.execute("SELECT * FROM rooms WHERE room_code = %s", (code,)).fetchone()
        if room is None:
            raise NotFound("room_not_found", "no room with that code")
        status, info = self.reconcile_room(room)
        with self.pool.connection() as conn:
            players = conn.execute("SELECT team, nickname FROM reservations WHERE room_code = %s AND confirmed "
                                   "ORDER BY team", (code,)).fetchall()
        out = {"room_code": code, "match_id": str(room["match_id"]), "mode": room["mode"], "status": status,
               "half_length_s": room["half_length_s"], "players": players,
               "created_at": room["created_at"].isoformat()}
        if info:
            out["connected"] = info.get("connected", [False, False])
            if "score" in info:
                out["score"] = info["score"]
        return out

    def reconcile_room(self, room: dict) -> tuple[str, dict | None]:
        """Returns (status, runtime info or None), persisting status changes."""
        stored = room["status"]
        if stored in TERMINAL:
            return stored, None
        if stored == "provisioning":
            age = self._age_s(room["created_at"])
            if age > self.settings.stale_provisioning_s:
                log_event("stale_provisioning_cleanup", match_id=str(room["match_id"]), room_code=room["room_code"])
                self._abandon(room)
                return "cancelled", None
            return "provisioning", None
        match_id = str(room["match_id"])
        try:
            info = self.runtime.status(match_id)
        except RuntimeUnavailable:
            return "unavailable", None
        if info is None:
            new = "aborted"
        elif info.get("state") in ("completed", "cancelled"):
            new = info["state"]
        elif info.get("boot_id") != room["runtime_boot_id"]:
            new = "aborted"
        elif info.get("state") in LIVE:
            new = info["state"]
        else:
            new = stored
        if info is not None and "reservations" in info:
            self._settle_pending(room, info["reservations"])
        if new != stored:
            with self.pool.connection() as conn:
                conn.execute("UPDATE rooms SET status = %s, updated_at = now() WHERE room_code = %s AND status = %s",
                             (new, room["room_code"], stored))
            log_event("room_status_changed", match_id=match_id, room_code=room["room_code"], old=stored, new=new,
                      boot_id=(info or {}).get("boot_id"))
        return new, info

    def _settle_pending(self, room: dict, runtime_reservations: list) -> None:
        with self.pool.connection() as conn:
            pending = conn.execute("SELECT reservation_id, team, created_at FROM reservations "
                                   "WHERE room_code = %s AND NOT confirmed", (room["room_code"],)).fetchall()
            for p in pending:
                held = runtime_reservations[p["team"]] if p["team"] < len(runtime_reservations) else None
                if held == str(p["reservation_id"]):
                    conn.execute("UPDATE reservations SET confirmed = TRUE WHERE reservation_id = %s", (p["reservation_id"],))
                elif self._age_s(p["created_at"]) > self.settings.pending_reservation_ttl_s:
                    conn.execute("DELETE FROM reservations WHERE reservation_id = %s", (p["reservation_id"],))
                    log_event("pending_reservation_released", match_id=str(room["match_id"]), team=p["team"])

    def reconcile_all(self) -> int:
        """Reconciles every non-terminal room; returns how many were checked."""
        with self.pool.connection() as conn:
            rooms = conn.execute("SELECT * FROM rooms WHERE status = ANY(%s)", (list(ACTIVE),)).fetchall()
        for room in rooms:
            try:
                self.reconcile_room(room)
            except (RuntimeError_, OSError) as e:
                log_event("reconcile_failed", match_id=str(room["match_id"]), error=str(e))
        return len(rooms)

    def _age_s(self, ts) -> float:
        return self.clock() - ts.timestamp()
