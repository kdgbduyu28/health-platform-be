#!/bin/zsh
# Apply the migrations + seed to a throwaway Postgres cluster and run the
# behavioural checks in rls_test.sh.
#
# Needs a local Postgres 15+ (Postgres.app or `brew install postgresql@17`) but
# NOT Docker and NOT the Supabase CLI — the Supabase-managed pieces (the auth
# schema, auth.uid(), the anon/authenticated roles) are stubbed by
# supabase_shim.sql, which is test-only and never shipped to a real project.
#
#   ./supabase/tests/run.sh
#
# To run against `supabase start` instead of a throwaway cluster:
#   PGPORT=54322 PGDATABASE=postgres ./supabase/tests/rls_test.sh
set -e
setopt no_unset

HERE=${0:A:h}
SUPA=${HERE:h}
PORT=${PORT:-55432}
WORK=${TMPDIR:-/tmp}/health-platform-pgtest

# Locate the Postgres binaries.
if command -v initdb >/dev/null 2>&1; then
  PGBIN=$(dirname $(command -v initdb))
elif [[ -d /Applications/Postgres.app/Contents/Versions/latest/bin ]]; then
  PGBIN=/Applications/Postgres.app/Contents/Versions/latest/bin
else
  print -u2 "error: no Postgres binaries found (need initdb/psql on PATH, or Postgres.app)"
  exit 1
fi
export PATH="$PGBIN:$PATH"

cleanup() { pg_ctl -D "$WORK/data" stop -m immediate >/dev/null 2>&1 || true }
trap cleanup EXIT

print "── starting throwaway cluster on port $PORT ──"
cleanup
rm -rf "$WORK"; mkdir -p "$WORK"
initdb -D "$WORK/data" -U postgres --auth=trust >/dev/null
# Unix socket dir is /tmp because a long TMPDIR path overflows the 103-byte
# socket path limit; connections go over TCP loopback anyway.
pg_ctl -D "$WORK/data" -o "-p $PORT -k /tmp -h 127.0.0.1" -l "$WORK/pg.log" start >/dev/null
for i in {1..30}; do
  pg_isready -h 127.0.0.1 -p $PORT -q && break
  sleep 0.5
done

q() { psql -h 127.0.0.1 -p $PORT -U postgres -d hp -X -q -v ON_ERROR_STOP=1 "$@" }
createdb -h 127.0.0.1 -p $PORT -U postgres hp

print "── applying shim + migrations + seed ──"
q -f "$HERE/supabase_shim.sql"
for m in "$SUPA"/migrations/*.sql; do
  print "   ${m:t}"
  q -f "$m"
done
q -f "$SUPA/seed.sql"

# The seed advertises itself as re-runnable; hold it to that.
print "── re-applying seed (idempotency) ──"
q -f "$SUPA/seed.sql"

PGHOST=127.0.0.1 PGPORT=$PORT PGUSER=postgres PGDATABASE=hp "$HERE/rls_test.sh"
