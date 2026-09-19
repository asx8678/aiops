#!/bin/sh
# Read-only logical dump. Requires a separately approved cross-company backup role.
set -eu
umask 077
fail() { printf '%s\n' "$1" >&2; exit 64; }
[ "${OPS_BRAIN_BACKUP_APPROVED:-false}" = true ] || fail 'Backup requires explicit approval'
[ "$#" -eq 1 ] || fail 'Usage: release-backup.sh NEW_ARCHIVE_PATH'
[ "${PGSERVICE:-}" = ops_brain_backup ] || fail 'Use the dedicated ops_brain_backup service'
[ -r "${PGSERVICEFILE:-}" ] || fail 'Reviewed PGSERVICEFILE required'
[ -r "${PGPASSFILE:-}" ] || fail 'Private PGPASSFILE required'
[ -r "${PGSSLROOTCERT:-}" ] || fail 'Database CA required'
# Connection profiles, not URLs in argv. Strip unrelated inherited libpq settings.
pg() { env -i PATH="$PATH" PGSERVICE="$PGSERVICE" PGSERVICEFILE="$PGSERVICEFILE" \
  PGPASSFILE="$PGPASSFILE" PGSSLMODE=verify-full PGSSLROOTCERT="$PGSSLROOTCERT" \
  PGCONNECT_TIMEOUT=10 "$@"; }
identity=$(pg psql --dbname="service=$PGSERVICE sslmode=verify-full" -X -w -A -t -v ON_ERROR_STOP=1 -c \
  "SELECT current_user = 'ops_brain_backup' AND NOT rolsuper AND rolbypassrls FROM pg_roles WHERE rolname=current_user")
[ "$identity" = t ] || fail 'Unexpected backup identity'
# noclobber prevents overwriting an existing archive; failure leaves a partial file.
set -C
pg pg_dump --dbname="service=$PGSERVICE sslmode=verify-full" --no-password --format=custom --no-owner --no-privileges > "$1"
printf '%s\n' 'Dump complete; encrypt, checksum and verify an isolated restore before accepting it'
