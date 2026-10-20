#!/usr/bin/env bash
# Runs one e2e script against the running main stack (docker compose up -d),
# in the Playwright image inside the gateway's network namespace, so the page
# is served from http://localhost (a secure context, as Godot web requires).
#
#   bash tests/e2e/run.sh online_menu.mjs [extra args...]
#
# Works from Linux and Git Bash. node_modules goes to a throwaway volume, so
# nothing is left in tests/e2e.
set -eu
cd "$(dirname "$0")"
here="$(pwd -W 2>/dev/null || pwd)"
export MSYS_NO_PATHCONV=1
script="$1"; shift
docker run --rm --network container:inazuma-online-gateway-1 \
  -v "$here:/e2e" -v inazuma-e2e-node-modules:/e2e/node_modules -w /e2e \
  mcr.microsoft.com/playwright:v1.63.0-noble \
  sh -c '[ -d node_modules/playwright ] || npm i --silent --no-save --no-package-lock playwright@1.63.0; node "$0" http://localhost "$@"' "$script" "$@"
