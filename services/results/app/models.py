"""The ingestion contract: one finished match as written by the match
runtime's result spool (scripts/server/match_runtime.gd, result_record()).

    {
      "match_id": UUID, "config_version": 1, "config": {MatchConfig}?,
      "players": [{"team": 0, "player_id": UUID, "nickname": str},
                  {"team": 1, ...}],
      "score_left": int, "score_right": int,      # team 0 / team 1 goals
      "winner": 0 | 1 | null,                     # null = draw / no winner
      "reason": "full_time" | "forfeit" | "cancelled" | "aborted",
      "stats": [{possession, shots, ...}, {...}],
      "started_at": ISO-8601 | null, "finished_at": ISO-8601,
      "runtime_boot_id": str?
    }

Consistency rules: two players on distinct teams with distinct ids; a
full-time winner must match the score; cancelled/aborted matches have no
winner; finished_at is not before started_at.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

REASONS = ("full_time", "forfeit", "cancelled", "aborted")


class PlayerResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    team: int = Field(ge=0, le=1)
    player_id: uuid.UUID
    nickname: str = Field(min_length=1, max_length=32)


class MatchResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    match_id: uuid.UUID
    config_version: int = Field(ge=1)
    config: dict | None = None
    players: list[PlayerResult] = Field(min_length=2, max_length=2)
    score_left: int = Field(ge=0, le=99)
    score_right: int = Field(ge=0, le=99)
    winner: int | None = Field(default=None, ge=0, le=1)
    reason: Literal["full_time", "forfeit", "cancelled", "aborted"]
    stats: list[dict] = Field(default_factory=list, max_length=2)
    started_at: datetime | None = None
    finished_at: datetime
    runtime_boot_id: str | None = Field(default=None, max_length=64)

    @model_validator(mode="after")
    def consistent(self) -> "MatchResult":
        if sorted(p.team for p in self.players) != [0, 1]:
            raise ValueError("players must be one per team (0 and 1)")
        if self.players[0].player_id == self.players[1].player_id:
            raise ValueError("the two players must be different")
        if self.reason == "full_time":
            expected = 0 if self.score_left > self.score_right else (1 if self.score_right > self.score_left else None)
            if self.winner != expected:
                raise ValueError("a full-time winner must match the score")
        if self.reason in ("cancelled", "aborted") and self.winner is not None:
            raise ValueError("cancelled or aborted matches have no winner")
        if self.started_at and self.finished_at < self.started_at:
            raise ValueError("finished_at is before started_at")
        return self

    def player(self, team: int) -> PlayerResult:
        return next(p for p in self.players if p.team == team)

    def counted(self) -> bool:
        """Whether the match awards leaderboard points."""
        return self.reason == "full_time" or (self.reason == "forfeit" and self.winner is not None)
