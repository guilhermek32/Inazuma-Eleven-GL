"""Lobby business logic: rooms, guest players, reservations, credentials.

Room status: provisioning -> waiting -> running <-> paused -> completed, or
cancelled (runtime cancelled an unused room) / aborted (the runtime lost the
match: 404, or a different boot_id while it was live). Terminal statuses are
completed, cancelled and aborted. "unavailable" is reported, never stored,
when the runtime can't be reached.

Create:  record intent (room + team-0 reservation, status provisioning) ->
         runtime PUT match + PUT reservation 0 -> status waiting -> credential.
         On any runtime failure the room is cancelled at the runtime (best
         effort) and deleted here; the caller gets 503. Idempotent by request_id.
Join:    lock the room row, insert the team-1 reservation (unique per room and
         team, so exactly one concurrent joiner wins), then runtime PUT
         reservation 1 -> confirmed -> credential. If the runtime is
         unreachable the pending reservation stays (503; retry with the same
         request_id); reconciliation releases it if the runtime never saw it.
"""

from __future__ import annotations

import json
import secrets
import time
import uuid

from psycopg import errors

from . import credentials
from .errors import Conflict, NotFound, Unavailable
from .logs import log_event
from .reconcile import ReconcileMixin
from .runtime_client import RuntimeClient, RuntimeError_, RuntimeUnavailable

ROOM_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
ROOM_CODE_LENGTH = 6

def match_config(half_length_s: int) -> dict:
    """The MatchConfig (scripts/match/match_config.gd, version 1) of a PvP room."""
    return {"version": 1, "half_length_s": float(half_length_s), "formations": [1, 1],
            "kits": [{"shirt": 0, "shorts": 4, "boots": 5}, {"shirt": 1, "shorts": 4, "boots": 5}],
            "team_difficulty": [1, 1], "fouls_enabled": True, "offside_enabled": False, "weather": 0}


def new_room_code() -> str:
    return "".join(secrets.choice(ROOM_CODE_ALPHABET) for _ in range(ROOM_CODE_LENGTH))


class LobbyService(ReconcileMixin):
    def __init__(self, pool, runtime: RuntimeClient, settings, clock=time.time):
        self.pool = pool
        self.runtime = runtime
        self.settings = settings
        self.clock = clock

    # --- create / join ---------------------------------------------------------------

    def create_room(self, nickname: str, half_length_s: int, request_id: str, player_id: str | None = None) -> dict:
        for _ in range(3):   # a concurrent duplicate request_id loses the insert race: re-read
            try:
                row = self._record_creation(nickname, half_length_s, request_id, player_id)
                break
            except errors.UniqueViolation:
                continue
        else:
            raise Conflict("request_conflict", "request_id is being used concurrently")
        if row["status"] == "provisioning":
            self._provision(row)
            row["status"] = "waiting"
        return self._grant(row)

    def _record_creation(self, nickname, half_length_s, request_id, player_id) -> dict:
        with self.pool.connection() as conn, conn.transaction():
            row = conn.execute(
                "SELECT r.*, v.reservation_id, v.player_id, v.nickname, v.team FROM rooms r "
                "JOIN reservations v ON v.room_code = r.room_code AND v.team = 0 WHERE r.create_request_id = %s",
                (request_id,)).fetchone()
            if row is not None:
                if row["nickname"] != nickname or row["half_length_s"] != half_length_s \
                        or (player_id and str(row["player_id"]) != player_id):
                    raise Conflict("request_conflict", "request_id was used with different parameters")
                return row
            if conn.execute("SELECT 1 FROM reservations WHERE request_id = %s", (request_id,)).fetchone():
                raise Conflict("request_conflict", "request_id was already used to join a room")
            pid = self._player(conn, player_id, nickname)
            match_id = uuid.uuid4()
            expires_at = int(self.clock()) + self.settings.token_ttl_s
            for _ in range(10):
                code = new_room_code()
                try:
                    with conn.transaction():
                        conn.execute(
                            "INSERT INTO rooms (room_code, match_id, mode, half_length_s, config, status, expires_at, "
                            "create_request_id) VALUES (%s, %s, 'pvp', %s, %s::jsonb, 'provisioning', %s, %s)",
                            (code, match_id, half_length_s, _json(match_config(half_length_s)), expires_at, request_id))
                    break
                except errors.UniqueViolation as e:
                    if e.diag.constraint_name != "rooms_pkey":
                        raise
            else:
                raise Unavailable("no_room_code", "could not allocate a room code")
            conn.execute("INSERT INTO reservations (reservation_id, room_code, team, player_id, nickname, request_id) "
                         "VALUES (%s, %s, 0, %s, %s, %s)", (uuid.uuid4(), code, pid, nickname, request_id))
            return conn.execute(
                "SELECT r.*, v.reservation_id, v.player_id, v.nickname, v.team FROM rooms r "
                "JOIN reservations v ON v.room_code = r.room_code AND v.team = 0 WHERE r.room_code = %s",
                (code,)).fetchone()

    def _provision(self, row: dict) -> None:
        match_id = str(row["match_id"])
        try:
            status = self.runtime.provision(match_id, row["config"], row["expires_at"])
            self.runtime.reserve(match_id, 0, str(row["reservation_id"]), str(row["player_id"]), row["nickname"])
        except RuntimeError_ as e:
            log_event("provisioning_failed", match_id=match_id, room_code=row["room_code"], error=str(e))
            self._abandon(row)
            raise Unavailable("runtime_unavailable", "the match runtime is unavailable, try again") from None
        with self.pool.connection() as conn, conn.transaction():
            conn.execute("UPDATE rooms SET status = 'waiting', runtime_boot_id = %s, updated_at = now() "
                         "WHERE room_code = %s AND status = 'provisioning'", (status.get("boot_id"), row["room_code"]))
            conn.execute("UPDATE reservations SET confirmed = TRUE WHERE reservation_id = %s", (row["reservation_id"],))
        log_event("room_created", match_id=match_id, room_code=row["room_code"], boot_id=status.get("boot_id"))

    def _abandon(self, row: dict) -> None:
        """Undoes a failed creation: cancel at the runtime (best effort; an
        orphan is cancelled by the runtime's waiting deadline anyway) and
        delete the records so the request_id can be retried."""
        try:
            self.runtime.cancel(str(row["match_id"]))
        except RuntimeError_:
            pass
        with self.pool.connection() as conn:
            conn.execute("DELETE FROM rooms WHERE room_code = %s AND status = 'provisioning'", (row["room_code"],))

    def join_room(self, code: str, nickname: str, request_id: str, player_id: str | None = None) -> dict:
        code = code.strip().upper()
        with self.pool.connection() as conn, conn.transaction():
            row = conn.execute(
                "SELECT r.*, v.reservation_id, v.player_id, v.nickname, v.team, v.confirmed FROM reservations v "
                "JOIN rooms r ON r.room_code = v.room_code WHERE v.request_id = %s", (request_id,)).fetchone()
            if row is not None:
                if row["room_code"] != code or row["team"] != 1 or row["nickname"] != nickname:
                    raise Conflict("request_conflict", "request_id was used for a different request")
            else:
                room = conn.execute("SELECT * FROM rooms WHERE room_code = %s FOR UPDATE", (code,)).fetchone()
                if room is None:
                    raise NotFound("room_not_found", "no room with that code")
                if room["status"] != "waiting":
                    raise Conflict("room_closed", f"the room is not accepting players ({room['status']})")
                if conn.execute("SELECT 1 FROM reservations WHERE room_code = %s AND team = 1", (code,)).fetchone():
                    raise Conflict("room_full", "the room is full")
                pid = self._player(conn, player_id, nickname)
                conn.execute("INSERT INTO reservations (reservation_id, room_code, team, player_id, nickname, request_id) "
                             "VALUES (%s, %s, 1, %s, %s, %s)", (uuid.uuid4(), code, pid, nickname, request_id))
                row = conn.execute(
                    "SELECT r.*, v.reservation_id, v.player_id, v.nickname, v.team, v.confirmed FROM reservations v "
                    "JOIN rooms r ON r.room_code = v.room_code WHERE v.request_id = %s", (request_id,)).fetchone()
        if not row["confirmed"]:
            match_id = str(row["match_id"])
            try:
                self.runtime.reserve(match_id, 1, str(row["reservation_id"]), str(row["player_id"]), nickname)
            except RuntimeUnavailable as e:
                log_event("join_pending", match_id=match_id, room_code=code, error=str(e))
                raise Unavailable("runtime_unavailable", "the match runtime is unavailable; retry with the same request_id") from None
            except RuntimeError_ as e:
                with self.pool.connection() as conn:
                    conn.execute("DELETE FROM reservations WHERE reservation_id = %s", (row["reservation_id"],))
                log_event("join_refused_by_runtime", match_id=match_id, room_code=code, error=str(e))
                self.room_status(code)   # refresh the stored status
                raise Conflict("room_closed", "the room is no longer available") from None
            with self.pool.connection() as conn:
                conn.execute("UPDATE reservations SET confirmed = TRUE WHERE reservation_id = %s", (row["reservation_id"],))
            log_event("room_joined", match_id=match_id, room_code=code)
        return self._grant(row)

    def _player(self, conn, player_id: str | None, nickname: str) -> uuid.UUID:
        """A returning guest's id (must exist) or a new one; records the nickname."""
        if player_id:
            found = conn.execute("UPDATE players SET nickname = %s, last_seen_at = now() WHERE player_id = %s "
                                 "RETURNING player_id", (nickname, player_id)).fetchone()
            if found is None:
                raise NotFound("player_not_found", "unknown player_id")
            return found["player_id"]
        pid = uuid.uuid4()
        conn.execute("INSERT INTO players (player_id, nickname) VALUES (%s, %s)", (pid, nickname))
        return pid

    def _grant(self, row: dict) -> dict:
        match_id = str(row["match_id"])
        claims = credentials.Claims(match_id=match_id, reservation_id=str(row["reservation_id"]), team=row["team"],
                                    player_id=str(row["player_id"]), exp=int(row["expires_at"]))
        token = credentials.sign(claims, self.settings.match_secret)
        return {"room_code": row["room_code"], "match_id": match_id, "team": row["team"],
                "player_id": str(row["player_id"]), "reservation_id": str(row["reservation_id"]),
                "nickname": row["nickname"], "token": token, "expires_at": int(row["expires_at"]),
                "ws_url": f"/ws/game/{match_id}", "play_url": f"/?match={match_id}&token={token}"}


def _json(value) -> str:
    return json.dumps(value, separators=(",", ":"))
