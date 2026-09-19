#!/bin/sh
# ONLY restore into a DBA-marked, dedicated disposable, EMPTY database.
# No dropdb, --clean, --create, overwrite or automatic runtime startup.
set -eu
umask 077
fail() { printf '%s\n' "$1" >&2; exit 64; }
[ "${OPS_BRAIN_DISPOSABLE_RESTORE:-}" = I_CONFIRM_DEDICATED_DISPOSABLE ] || fail 'Dedicated-disposable restore approval required'
case "${RESTORE_DATABASE:-}" in
  ops_brain_restore_?*) ;;
  *) fail 'Target must have the ops_brain_restore_ prefix and a nonempty suffix' ;;
esac
case "$RESTORE_DATABASE" in *[!a-z0-9_]*) fail 'Invalid disposable database name' ;; esac
[ "${RESTORE_CONFIRM_DATABASE:-}" = "$RESTORE_DATABASE" ] || fail 'Repeat the exact disposable database name'
[ "${PGSERVICE:-}" = ops_brain_disposable_restore ] || fail 'Dedicated disposable connection service required'
[ "$#" -eq 1 ] && [ -f "$1" ] && [ ! -L "$1" ] || fail 'One regular trusted archive required'
[ -r "${PGSERVICEFILE:-}" ] || fail 'Reviewed PGSERVICEFILE required'
[ -r "${PGPASSFILE:-}" ] || fail 'Private PGPASSFILE required'
[ -r "${PGSSLROOTCERT:-}" ] || fail 'Database CA required'
pg() { env -i PATH="$PATH" PGSERVICE="$PGSERVICE" PGSERVICEFILE="$PGSERVICEFILE" \
  PGPASSFILE="$PGPASSFILE" PGSSLMODE=verify-full PGSSLROOTCERT="$PGSSLROOTCERT" \
  PGCONNECT_TIMEOUT=10 "$@"; }
# Names are restricted above. The marker must be installed by a DBA beforehand.
# Never set this marker on an existing shared/live database.
safe=$(pg psql --dbname="service=$PGSERVICE sslmode=verify-full" -X -w -A -t -v ON_ERROR_STOP=1 -c "
  SELECT current_database() = '$RESTORE_DATABASE'
    AND current_user = 'ops_brain_migrator'
    AND EXISTS (SELECT 1 FROM pg_namespace WHERE nspname='public' AND nspowner=current_user::regrole)
    AND current_setting('ops_brain.disposable_restore', true) = 'dedicated-disposable'
    AND NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=current_user AND (rolsuper OR rolbypassrls))
    AND NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname NOT IN ('pg_catalog','information_schema')
        AND n.nspname NOT LIKE 'pg_toast%' AND c.relkind IN ('r','p','v','m','S'))")
[ "$safe" = t ] || fail 'Target identity, disposable marker or empty-database guard failed'
# pg_dump can include CREATE SCHEMA public when its owner was customized.
# Preserve the already-reviewed empty schema/owner, skipping ONLY that TOC entry.
work=$(mktemp -d)
trap 'rm -f "$work/raw.list" "$work/restore.list"; rmdir "$work"' EXIT
trap 'exit 130' HUP INT TERM
pg pg_restore --list "$1" > "$work/raw.list"
sed '/^[0-9][0-9]*; [0-9][0-9]* [0-9][0-9]* SCHEMA - public /s/^/;/' \
  "$work/raw.list" > "$work/restore.list"
pg pg_restore --no-password --exit-on-error --single-transaction --no-owner \
  --no-privileges --use-list="$work/restore.list" \
  --dbname="service=$PGSERVICE sslmode=verify-full" "$1"
printf '%s\n' 'Disposable restore complete. Keep workers OFF; apply grants and validate before any further use'
