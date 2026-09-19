#!/bin/sh
# Synthetic local-only drill. Never use release/production credentials here.
set -eu
[ "${OPS_BRAIN_DISPOSABLE_TEST:-}" = true ] || { echo 'Requires explicit disposable test approval' >&2; exit 64; }
[ "${PGDATABASE:-}" = ops_brain_test ] || { echo 'Source must be dedicated ops_brain_test' >&2; exit 64; }
case "${PGHOST:-}" in /tmp/ops-brain-pg/socket) ;; *) echo 'Only dedicated local test socket allowed' >&2; exit 64;; esac
[ "${PGPORT:-}" = 55432 ] || exit 64
[ -n "${PGUSER:-}" ] || exit 64
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d /tmp/ops-brain-recovery.XXXXXX)
target="ops_brain_test_restore_$(date +%s)_$$"
# createdb must fail if the unique target already exists. No drop, clean or overwrite.
createdb --owner=ops_brain_migrator "$target"
pg_dump --format=custom --no-owner --no-privileges --file="$work/data.dump"
pg_restore --list "$work/data.dump" > "$work/raw.list"
sed '/^[0-9][0-9]*; [0-9][0-9]* [0-9][0-9]* SCHEMA - public /s/^/;/' "$work/raw.list" > "$work/restore.list"
PGUSER=ops_brain_migrator pg_restore --exit-on-error --single-transaction --no-owner --no-privileges \
  --use-list="$work/restore.list" --dbname="$target" "$work/data.dump"
PGUSER=ops_brain_migrator PGDATABASE="$target" psql -X -v ON_ERROR_STOP=1 -f "$root/priv/repo/runtime_grants.sql" > /dev/null
# Exact row counts across every application table, including synthetic identities/history.
query="SELECT string_agg(format('SELECT %L AS relation, count(*) AS rows FROM %I;',tablename,tablename),' ') FROM pg_tables WHERE schemaname='public'"
counts=$(psql -X -A -t -v ON_ERROR_STOP=1 -c "$query")
printf '%s\n' "$counts" | psql -X -A -t -v ON_ERROR_STOP=1 > "$work/before.txt"
printf '%s\n' "$counts" | PGDATABASE="$target" psql -X -A -t -v ON_ERROR_STOP=1 > "$work/after.txt"
cmp "$work/before.txt" "$work/after.txt"
restricted=$(PGDATABASE="$target" PGUSER=ops_brain_runtime psql -X -A -t -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM sources")
[ "$restricted" = 0 ] || { echo 'Missing-scope RLS failed' >&2; exit 1; }
protected=$(PGDATABASE="$target" psql -X -A -t -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relrowsecurity AND c.relforcerowsecurity")
[ "$protected" = 15 ] || { echo 'Expected forced RLS tables missing' >&2; exit 1; }
printf 'RESTORE_PASSED database=%s artifact=%s protected_tables=%s\n' "$target" "$work/data.dump" "$protected"
printf 'Restored database is retained for inspection; collectors were never started. Remove only this named disposable copy after review.\n'
