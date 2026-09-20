# Acceptance and handoff — native deployment, no Docker

## Safety and invocation

Run from `ops_brain/` with mise (versions pinned in `mise.toml`). Tests truncate
fixtures. Supply **both** reviewed runtime and migrator URLs for the same isolated
`ops_brain_test*` database and `OPS_BRAIN_DISPOSABLE_TEST=true`. The database itself
must carry `ops_brain.disposable_test=approved`; naming alone is not approval.
Never use production credentials. Do not run these destructive suites in parallel.

```sh
export DATABASE_URL='<approved disposable runtime URL>'
export MIGRATION_DATABASE_URL='<approved disposable migrator URL>'
export OPS_BRAIN_DISPOSABLE_TEST=true
mise exec -- mix ci
mise exec -- mix ops_brain.validate_config config/sources.example.json
mise exec -- mix ops_brain.validate_config config/sources.prepared.json
OPS_BRAIN_RELEASE_VERIFY=true scripts/release-native-verify.sh
scripts/hard-crash-check.sh
```

All integration tests are included in `mix ci`; no optional environment flag or
hidden exclusion is required. External HTTP boundaries use synthetic plugs.

## Local acceptance ledger

| Request | Check / implementation | Acceptance boundary |
| --- | --- | --- |
| R19 | `scripts/release-native-verify.sh`: locked dependency resolution leaves `mix.lock` unchanged; native production release; packaged executable helpers, migrations and static assets; actual release VM evaluates `rel/tests/release_probe.exs`; toolchain/lock/file SHA256 manifests retained | Native packaging verified, not bit-identical builds across machines, image reproducibility, TLS database boot or production deployment |
| R23 concurrency | `test/ops_brain/integration/composed_workflow_test.exs`: four-connection pool, concurrent evidence revisions, one occurrence/current revision, cross-company denial, real non-testing Oban collection queue through synthetic HTTP and durable checkpoint | Real queue and database, not live source performance |
| R23 crash | `scripts/hard-crash-check.sh`: SIGKILL actual BEAM PID after durable lease claim; fresh VM verifies busy-before-expiry, fenced takeover, stale rejection, successful fresh commit and duplicate rejection | Controlled clock advancement; collector lease boundary only |
| R23 related boundaries | `evidence_revision_test.exs`, `orphan_recovery_test.exs`, `cleanup_throughput_test.exs`, `retention_policy_test.exs`: distinct backend PID race, notification process death after synthetic POST, real Lifeline callback, maintenance/retention protections | Notification test kills an Erlang process, not the entire VM; exhaustive whole-node notification/maintenance crash matrix remains open |
| R24 | Disabled deployment JSON validation and packaged runtime probe | Preparation only; external gates below remain blocked |
| R25 | This evidence ledger and root `README.md` navigation | Honest handoff, not certification that all R01–R25 acceptance is complete |

## Executed evidence (2026-09-20)

- `mix ci`: **208 passed**, seed **564594**, including format and warnings-as-errors.
  Log `/tmp/ops-r19-r25-ci.log`.
- Native release: `NATIVE_RELEASE_OK`; APIs, disabled config, migrations/assets,
  overlays, HTTPS forwarding verified without starting application/Repo.
  Artifacts `/tmp/ops-brain-release.22fPhN` (`toolchain.txt`, `lock.sha256`,
  `release.sha256`, `deps.log`, `release.log`, `probe.log`). Assembled release:
  `ops_brain/_build/prod/rel/ops_brain`.
- Hard crash: `CRASH_VERIFY_OK`; `/tmp/ops-brain-crash.0d8ZO9` retains synthetic
  marker and child log. Database: existing explicitly approved
  `ops_brain_test_r10`, local socket `/tmp/ops-brain-pg/socket`, port 55432,
  separate runtime/migrator identities.
- No Docker invocation, real provider access, real delivery, commit, push or deployment.

Artifacts under `/tmp` are local and ephemeral; copy to the reviewed evidence
store before deleting the workspace. Manifests identify this build; no assertion
of deterministic byte-for-byte rebuilding is made.

## R24 external gates — NOT completed

| Gate | Required evidence | Owner |
| --- | --- | --- |
| Azure Build | Approved endpoint, TLS/bearer scope, source read and pagination | Source admin |
| Prometheus/Loki | Reviewed tenant/selector/profile, bounded reads and freshness | Observability owner |
| Kubernetes | Namespace/RBAC/CA, list/watch expiry and gap behavior | Platform owner |
| Identity provider | Subject mapping, MFA and session revocation | Identity admin |
| Notification sink | Approved destination/recipients and ambiguous-delivery procedure | Service owner |
| Native deployment | Approved host, release SHA256 manifest, proxy/TLS trust, restricted database preflight and health | Infra/security |
| Restore/recovery | Reviewed backup role, isolated restore and job/session disposition | DBA |
| Second company | Independent onboarding/isolation proof | Security |

No live endpoints, authorization or deployment target were supplied for this
continuation. Each owner must record date, exact release hash, redacted output,
expected/actual outcome and approval. Never infer a pass from synthetic fixtures.

## Deployment and rollback handoff

Follow `DEPLOYMENT.md` and `REPLAY_RETENTION.md`: reviewed migration identity first,
then reviewed runtime grants and preflight before application startup. Keep
collection and delivery disabled until external acceptance is approved. Do not
roll back schema or drop revision history just to disable collection. To contain
an incident, disable collection/delivery/maintenance and restart, or stop the
application. Never blindly resend ambiguous notifications. A database restore
requires a separately approved isolated drill; this continuation did not run one.
