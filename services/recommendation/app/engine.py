"""The recommendation model: pure functions, no I/O.

Input is the counted match history (full time, or a forfeit with a winner)
in chronological order; output is a skill rating per player and, for one
player, the recommended online AI level and the closest human rivals.

Rating (Elo, as adapted for football by the World Football Elo Ratings):
  expected  E_a = 1 / (1 + 10 ** ((R_b - R_a) / 400))
  update    R_a' = R_a + K * G * (S_a - E_a)
            S = 1 win, 0.5 draw, 0 loss
            K = K_NEW for a player's first PROVISIONAL_GAMES matches, then K_SETTLED
            G = goal-difference index: 1 (0 or 1 goal), 1.5 (2), (11 + N) / 8 (N >= 3)
Every player starts at INITIAL_RATING. The three AI bots (one stable guest id
per difficulty, see bots.py) start at BOT_PRIOR, ordered by measured strength
(docs/measurements.md: the harder bot wins every decided bot-vs-bot match),
and are rated from their real results like any player.

AI level: the level whose bot gives the player the expected score closest to
TARGET_SCORE: a match the player is a little more likely to win than lose,
challenging without being discouraging (dynamic difficulty adjustment). Ties
go to the easier level.

Rivals: human players other than the player, closest in rating (then most
matches played, then player_id), with the player's expected score against each.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field

from .bots import BOT_IDS, DIFFICULTIES

INITIAL_RATING = 1000.0
BOT_PRIOR = {"easy": 900.0, "normal": 1050.0, "hard": 1200.0}
K_NEW = 40.0
K_SETTLED = 24.0
PROVISIONAL_GAMES = 10
TARGET_SCORE = 0.6
MAX_RIVALS = 3
FORM_LENGTH = 5


@dataclass(frozen=True)
class Match:
    """One counted match: team 0 is `left`, team 1 is `right`."""
    match_id: str
    finished_at: str
    left: str            # player_id
    right: str
    left_nickname: str
    right_nickname: str
    score_left: int
    score_right: int
    winner: int | None   # 0, 1 or None (draw)


@dataclass
class Player:
    player_id: str
    nickname: str = ""
    rating: float = INITIAL_RATING
    played: int = 0
    wins: int = 0
    draws: int = 0
    losses: int = 0
    form: list[str] = field(default_factory=list)   # newest last: "W" / "D" / "L"

    @property
    def is_bot(self) -> bool:
        return self.player_id in BOT_IDS.values()


def expected_score(rating: float, opponent: float) -> float:
    return 1.0 / (1.0 + 10.0 ** ((opponent - rating) / 400.0))


def goal_index(goal_difference: int) -> float:
    n = abs(goal_difference)
    if n <= 1:
        return 1.0
    if n == 2:
        return 1.5
    return (11.0 + n) / 8.0


def k_factor(player: Player) -> float:
    return K_NEW if player.played < PROVISIONAL_GAMES else K_SETTLED


def new_player(player_id: str, nickname: str = "") -> Player:
    for level, bot_id in BOT_IDS.items():
        if bot_id == player_id:
            return Player(player_id, nickname or f"AI ({level.title()})", BOT_PRIOR[level])
    return Player(player_id, nickname)


def rate(history: list[Match]) -> dict[str, Player]:
    """Ratings after replaying `history` (oldest first). Bots are always present."""
    players = {bot_id: new_player(bot_id) for bot_id in BOT_IDS.values()}
    for m in history:
        a = players.setdefault(m.left, new_player(m.left))
        b = players.setdefault(m.right, new_player(m.right))
        a.nickname, b.nickname = m.left_nickname or a.nickname, m.right_nickname or b.nickname
        s_a = 0.5 if m.winner is None else (1.0 if m.winner == 0 else 0.0)
        e_a = expected_score(a.rating, b.rating)
        g = goal_index(m.score_left - m.score_right)
        delta_a = k_factor(a) * g * (s_a - e_a)
        delta_b = k_factor(b) * g * ((1.0 - s_a) - (1.0 - e_a))
        a.rating += delta_a
        b.rating += delta_b
        for p, s in ((a, s_a), (b, 1.0 - s_a)):
            p.played += 1
            outcome = "W" if s == 1.0 else ("D" if s == 0.5 else "L")
            p.wins += outcome == "W"
            p.draws += outcome == "D"
            p.losses += outcome == "L"
            p.form = (p.form + [outcome])[-FORM_LENGTH:]
    return players


def recommend_level(player: Player, players: dict[str, Player]) -> dict:
    """The AI level for `player` (see the module doc), with every level's odds."""
    options = []
    for level in DIFFICULTIES:
        bot = players[BOT_IDS[level]]
        options.append({"level": level, "bot_rating": round(bot.rating),
                         "win_probability": round(expected_score(player.rating, bot.rating), 3)})
    # DIFFICULTIES is ordered easy -> hard and min() keeps the first minimum: ties go easier.
    best = min(options, key=lambda o: abs(o["win_probability"] - TARGET_SCORE))
    if player.played == 0:
        reason = "first_match"
    elif best["level"] == "easy" and best["win_probability"] < TARGET_SCORE:
        reason = "build_confidence"      # even the easiest bot is a challenge right now
    elif best["level"] == "hard" and best["win_probability"] > TARGET_SCORE:
        reason = "top_level"             # stronger than every bot
    else:
        reason = "matched_to_rating"
    return {"level": best["level"], "win_probability": best["win_probability"], "reason": reason,
            "options": options}


def recommend_rivals(player: Player, players: dict[str, Player], limit: int = MAX_RIVALS) -> list[dict]:
    candidates = [p for p in players.values()
                  if not p.is_bot and p.player_id != player.player_id and p.played > 0]
    candidates.sort(key=lambda p: (abs(p.rating - player.rating), -p.played, p.player_id))
    return [{"player_id": p.player_id, "nickname": p.nickname, "rating": round(p.rating), "played": p.played,
             "win_probability": round(expected_score(player.rating, p.rating), 3)} for p in candidates[:limit]]


def recommend(player_id: str | None, players: dict[str, Player]) -> dict:
    """The full recommendation for `player_id` (None or unknown = a new player)."""
    if player_id is not None:
        player_id = str(uuid.UUID(player_id))   # ValueError on a malformed id
    player = players.get(player_id) if player_id else None
    if player is None:
        player = Player(player_id or "")
    return {
        "player": {"player_id": player.player_id or None, "nickname": player.nickname or None,
                   "rating": round(player.rating), "played": player.played, "wins": player.wins,
                   "draws": player.draws, "losses": player.losses, "form": "".join(player.form),
                   "provisional": player.played < PROVISIONAL_GAMES},
        "ai_level": recommend_level(player, players),
        "rivals": recommend_rivals(player, players),
    }
