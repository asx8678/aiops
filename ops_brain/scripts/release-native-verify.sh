#!/bin/sh
# R19: Native release reproducibility and packaging check. NO Docker required.
set -eu
[ "${OPS_BRAIN_RELEASE_VERIFY:-}" = "true" ] || { echo 'Set OPS_BRAIN_RELEASE_VERIFY=true' >&2; exit 64; }
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"
work=$(mktemp -d /tmp/ops-brain-release.XXXXXX 2>/dev/null || mktemp -d /tmp/ops-brain-release.XXXXXX)
trap 'echo "Release artifacts: $work"' EXIT

cp mix.lock "$work/mix.lock.before"
mise exec -- mix deps.get >"$work/deps.log" 2>&1
cmp -s mix.lock "$work/mix.lock.before" || { echo 'FAIL: mix.lock changed during deps.get' >&2; exit 1; }

MIX_ENV=prod mise exec -- mix release --overwrite >"$work/release.log" 2>&1
rel=_build/prod/rel/ops_brain
for f in bin/ops_brain bin/release-command bin/healthcheck; do
  [ -x "$rel/$f" ] || { echo "FAIL: missing packaged $f" >&2; exit 1; }
done
test -d "$rel/lib/ops_brain-0.1.0/priv/repo/migrations"
test -d "$rel/lib/ops_brain-0.1.0/priv/static"
root=$(pwd)
mise exec -- elixir --version >"$work/toolchain.txt"
sha256sum mix.lock >"$work/lock.sha256"
(cd "$rel" && find . -type f -print0 | sort -z | xargs -0 sha256sum) >"$work/release.sha256"
export RELEASE_SOURCE_ROOT="$root"
export DATABASE_URL='ecto://ops_brain_runtime@localhost/unused'
export DATABASE_CA_FILE=/etc/ssl/certs/ca-certificates.crt
export PHX_HOST=unit.invalid
export SECRET_KEY_BASE=synthetic-release-probe-key-not-for-deployment-000000000000000000000000
(cd "$rel" && bin/ops_brain eval 'Code.eval_file(Path.join(System.fetch_env!("RELEASE_SOURCE_ROOT"), "rel/tests/release_probe.exs"))') >"$work/probe.log" 2>&1
cat "$work/probe.log"
# Preserve evidence, including failures, rather than deleting the only build logs.
trap - EXIT HUP INT TERM
echo "NATIVE_RELEASE_OK artifacts=$work"

