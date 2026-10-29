"""The AI bot's stable guest identities, one per difficulty.

Same derivation as the lobby (services/lobby/app/bot_client.py, bot_player):
uuid5(BOT_PLAYER_NAMESPACE, "ai-bot:<difficulty>"). Both services must agree;
tests/test_engine.py pins the ids.
"""

from __future__ import annotations

import uuid

DIFFICULTIES = ("easy", "normal", "hard")
BOT_PLAYER_NAMESPACE = uuid.UUID("6f1c3a52-9d4e-4c1b-8a57-2f0e8b7d4c21")
BOT_IDS = {level: str(uuid.uuid5(BOT_PLAYER_NAMESPACE, f"ai-bot:{level}")) for level in DIFFICULTIES}
