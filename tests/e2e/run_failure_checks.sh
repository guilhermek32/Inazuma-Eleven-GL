#!/usr/bin/env bash
# Service failure checks against the running main stack (docker compose up -d):
#   1. results stopped before full time: the match still completes, its result
#      waits in the runtime's spool, and once results is back it is recorded
#      exactly once and the spool empties;
#   2. match runtime restarted during a running match: the lobby reports the
#      room as aborted and the old credentials no longer attach.
# Run from the repo root (Git Bash or Linux): bash tests/e2e/run_failure_checks.sh
# Exits 0 when every check passes.

set -u
cd "$(dirname "$0")/../.."
E2E="$(pwd -W 2>/dev/null || pwd)/tests/e2e"
export MSYS_NO_PATHCONV=1
GATEWAY=inazuma-online-gateway-1
IMAGE=mcr.microsoft.com/playwright:v1.63.0-noble
fail=0

phase() {
  docker run --rm --network "container:$GATEWAY" -v "$E2E:/e2e" -w /e2e "$IMAGE" node service_failures.mjs http://localhost "$@"
}
spool_ls() { docker compose exec -T match-runtime ls /data/spool; }

echo "== 1. results down at full time"
docker compose stop results
out="$(phase spool-match)" || fail=1
echo "$out"
match_id="$(echo "$out" | sed -n 's/^MATCH_ID=//p')"
if [ -n "$match_id" ] && spool_ls | grep -qx "$match_id.json"; then
  echo "PASS  the result is waiting in the runtime spool ($match_id.json)"
else
  echo "FAIL  no spool file for '$match_id'"; fail=1
fi
docker compose start results
phase expect-result "$match_id" || fail=1
if spool_ls | grep -q "$match_id"; then
  echo "FAIL  the spool file is still there after delivery"; fail=1
else
  echo "PASS  the spool file is removed after delivery"
fi

echo "== 2. runtime restart during a running match"
log="$(mktemp)"
phase abort-match > "$log" 2>&1 &
pid=$!
for _ in $(seq 1 120); do
  grep -q READY_FOR_RESTART "$log" && break
  sleep 1
done
if grep -q READY_FOR_RESTART "$log"; then
  docker compose restart match-runtime
else
  echo "FAIL  the match never started"; fail=1
fi
wait "$pid" || fail=1
cat "$log"
rm -f "$log"

if [ "$fail" -eq 0 ]; then echo "FAILURE CHECKS PASSED"; else echo "FAILURE CHECKS FAILED"; fi
exit "$fail"
