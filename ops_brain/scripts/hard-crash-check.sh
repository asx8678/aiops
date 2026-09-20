#!/bin/sh
set -eu
[ "${OPS_BRAIN_DISPOSABLE_TEST:-}" = true ] || exit 64
: "${DATABASE_URL:?}" "${MIGRATION_DATABASE_URL:?}"
cd "$(dirname "$0")/.."
export MIX_ENV=test
work=$(mktemp -d /tmp/ops-brain-crash.XXXXXX)
export OPS_BRAIN_MARKER="$work/marker"
cleanup() {
  if [ -f "$work/marker.pid" ]; then kill -9 "$(cat "$work/marker.pid")" 2>/dev/null || true; fi
}
trap cleanup EXIT HUP INT TERM
mise exec -- mix run --no-start scripts/hard_crash_claim.exs >"$work/child.log" 2>&1 &
child=$!
for i in $(seq 1 60); do [ -s "$work/marker.pid" ] && break; sleep 1; done
[ -s "$work/marker.pid" ] || { cat "$work/child.log"; exit 1; }
kill -9 "$(cat "$work/marker.pid")"
wait "$child" 2>/dev/null || true
rm "$work/marker.pid"
mise exec -- mix run --no-start scripts/hard_crash_verify.exs
echo "Crash artifacts: $work"
