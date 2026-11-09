#!/bin/sh
# Runs once, when the PostgreSQL volume is first initialized: one database
# and one login role per service, so the lobby and results services each own
# their data and can't read each other's tables (they talk through APIs).
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
     -v lobby_pw="$LOBBY_DB_PASSWORD" -v results_pw="$RESULTS_DB_PASSWORD" <<'EOSQL'
CREATE ROLE lobby LOGIN PASSWORD :'lobby_pw';
CREATE DATABASE lobby OWNER lobby;
REVOKE ALL ON DATABASE lobby FROM PUBLIC;

CREATE ROLE results LOGIN PASSWORD :'results_pw';
CREATE DATABASE results OWNER results;
REVOKE ALL ON DATABASE results FROM PUBLIC;
EOSQL
