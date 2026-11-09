#!/usr/bin/env bash
# Milestone 5 checks against the running main stack (docker compose up -d):
#   1. one browser plays a vs-AI match to full time through the Play Online
#      menu (vs_ai_menu.mjs), and the ai-bot logged sampled decisions for it;
#   2. ai-bot stopped: vs-AI creation fails cleanly, PvP still works;
#   3. ai-bot started again: vs-AI works again.
# Run from the repo root (Git Bash or Linux): bash tests/e2e/run_bot_checks.sh
# Exits 0 when every check passes.

set -u
cd "$(dirname "$0")/../.."
E2E="$(pwd -W 2>/dev/null || pwd)/tests/e2e"
export MSYS_NO_PATHCONV=1
# COMPOSE_PROJECT_NAME selects a stack started under another project name.
PROJECT="${COMPOSE_PROJECT_NAME:-inazuma-online}"
GATEWAY="$PROJECT-gateway-1"
IMAGE=mcr.microsoft.com/playwright:v1.63.0-noble
fail=0

phase() {
  docker run --rm --network "container:$GATEWAY" -v "$E2E:/e2e" -w /e2e "$IMAGE" node bot_checks.mjs http://localhost "$@"
}

echo "== 1. a browser plays the AI bot through the menu"
out="$(bash tests/e2e/run.sh vs_ai_menu.mjs)" || fail=1
echo "$out"
match_id="$(echo "$out" | sed -n 's/^MATCH_ID=//p')"
decisions="$(docker compose logs --no-color ai-bot 2>/dev/null | grep '"bot_decision"' | grep -c "$match_id")"
if [ -n "$match_id" ] && [ "$decisions" -gt 0 ]; then
  echo "PASS  the ai-bot logged $decisions sampled decisions for $match_id"
  docker compose logs --no-color ai-bot | grep '"bot_decision"' | grep "$match_id" | head -3 | sed 's/^[^{]*//'
else
  echo "FAIL  no bot_decision log lines for '$match_id'"; fail=1
fi

echo "== 2. ai-bot stopped"
docker compose stop ai-bot
phase down || fail=1

echo "== 3. ai-bot started again"
docker compose start ai-bot
for _ in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$PROJECT-ai-bot-1" 2>/dev/null)" = healthy ] && break
  sleep 2
done
phase back || fail=1

if [ "$fail" -eq 0 ]; then echo "BOT CHECKS PASSED"; else echo "BOT CHECKS FAILED"; fi
exit "$fail"
