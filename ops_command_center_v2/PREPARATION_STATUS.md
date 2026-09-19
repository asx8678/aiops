# Credential-free completion and deployment preparation

Updated2026-09-19. The requested code/preparation pass is complete for the documented Ops Brain v2 contracts. This is **not** an assertion that all17 roadmap tasks have passed production acceptance: task016 still requires a real second company, and live-provider/hosting/security gates remain open. No production system, source configuration or external notification was changed.

The application in `../ops_brain/` contains executable adapters, domain logic, persistence, workers, authentication, UI, maintenance, replay and tests—not empty placeholder modules. Placeholders are confined to disabled installation/credential configuration. The previous93-test baseline grew to **142 passing application tests**, plus **18 passing standalone deployment-contract tests**.

## Completed acceptance ledger

- [x] Audit remaining roadmap/local execution paths against original source/read-only/tenant requirements; preserve original specification and distinguish implementation from live acceptance. Current task-by-task boundaries are in `IMPLEMENTATION_STATUS.md`.
- [x] Deployment/ReplicaSet/Pod/Event namespace adapters, list pagination, opaque per-resource durable RVs, restart/disconnect/410/scope-change handling, UID ownership/name reuse, initial-inventory semantics, Event increments and restart/OOM evidence. Cursor and evidence persistence are atomic; oversize/malformed/capped/stale state never becomes complete healthy coverage. Failed watches preserve the real last-success timestamp.
- [x] Immutable versioned observation history and bounded paged offline replay for implemented pipeline/metric/log/workload/capacity/correlation evaluations. Independent occurrence and receipt cutoffs, sample timestamps, stored policies, expiry/version/missing states and company/cursor binding are tested. No HTTP, messages, jobs, lifecycle mutation or human-review overwrite. Missing pre-upgrade inputs remain unavailable.
- [x] Bounded dependency-aware retention for evidence, window revisions, run snapshots, closed findings/occurrences/groups/fingerprints, terminal outbox and unreferenced pipeline identities; expiry tombstones cannot disappear before referenced history. Separate bounded auth/OIDC/terminal-job cleanup. Explicit maintenance switch defaults off and queued workers recheck it; no runtime identity-administration privileges.
- [x] Optional OIDC: locked JOSE, RS256/code flow, PKCE/state/nonce/issuer/audience/expiry/JWKS checks, single-use durable attempts, encrypted browser flow cookie, exact approved local subject mapping and session revocation. No claim-based auto-enrollment. Bounded node-local login admission and existing capability fallback. MFA remains an IdP policy/approval, not a fabricated app guarantee.
- [x] Complete disabled Azure/Prometheus/Loki/Kubernetes/HTTP sink template, OIDC/DB/session environment-reference template, namespace RBAC example and credential/endpoint approval guide. Examples use reserved addresses and fail closed if enabled unchanged. `.env`, local source configuration, secret directories/private keys and dumps excluded from Git; Docker context is allowlisted. Real secrets still belong outside the checkout.
- [x] Native release, nonroot Dockerfile/disabled Compose template, migration/runtime/backup role SQL, guarded migrate/preflight/health and backup/disposable-restore scripts; TLS/proxy/egress/disable/bootstrap procedures. Production compile and packaged-release behavior passed; container build/boot itself was not available and is not claimed.
- [x] Adversarial/local contract and real PostgreSQL tests: RLS, wrong-company references/IDs, pooled rollback/scope cleanliness, lease/request fencing, watch bounds, duplicate/late/revision semantics, authentication callback replay, retention dependencies and replay transport/job/outbox isolation.
- [x] Reproducible opt-in synthetic multi-connection load probe (pool4/concurrency8,4 physical backends), and noisy/quiet budget independence passed. OIDC one-winner behavior is tested separately with concurrent callers on the ordinary pool1; no multi-connection OIDC claim is made. Isolated dump/transactional restore drill passed table counts/runtime grants/15 forced-RLS tables/missing-scope checks with no collectors started.
- [x] Independent scoped review findings addressed and regression-tested; final `mix precommit`142/142,12 Python deployment tests and6 standalone Elixir runtime tests pass. Routes, workers, grant contracts, configuration defaults, release APIs/assets/migrations and secret-ignore/restore guards mechanically verified.
- [x] README and current implementation/credential/deployment/OIDC/workload/replay handoff updated with actual artifacts, measurements and remaining limitations, rather than describing local fixtures as a real onboarding/deployment.

## Where to start

Paths below are relative to `../ops_brain/`:

| Purpose | Files |
| --- | --- |
| Private installation values and approval checklist | `docs/CREDENTIALS.md`, `.env.example` |
| All four read adapters plus optional delivery, disabled | `config/sources.prepared.json` |
| Empty source deployment | `config/sources.example.json` |
| Workload RBAC and actual collection bounds | `config/kubernetes-role.example.yaml`, `docs/WORKLOADS.md` |
| Authentication/identity setup | `docs/OIDC.md`, existing `mix ops_brain.bootstrap` |
| Release/build, DB identities, TLS/proxy and recovery | `Dockerfile`, `compose.example.yml`, `rel/`, `scripts/release-*.sh`, `docs/DEPLOYMENT.md` |
| Retained offline evaluation/maintenance policy | `docs/REPLAY_RETENTION.md` |
| Disposable concurrency/restore probes | `scripts/concurrency_check.exs`, `scripts/local-recovery-check.sh` |

Offline syntax validation (no HTTP/DB/credential reads):

```sh
cd ops_brain
mise exec elixir@1.20.4-otp-27 erlang@27.3.4.16 -- \
  mix ops_brain.validate_config config/sources.prepared.json
```

Actual result:4 sources,1 notification destination, all disabled. Syntax validation does not approve endpoints, rights, query semantics or live compatibility.

## Reproducing verification safely

Use the separately provisioned disposable migration/runtime database URLs with the exact local toolchain. Never use production URLs: tests truncate fixtures. Do not run DB suites and destructive drills concurrently.

```sh
# DATABASE_URL and MIGRATION_DATABASE_URL must name dedicated ops_brain_test... DBs.
mise exec elixir@1.20.4-otp-27 erlang@27.3.4.16 -- mix precommit
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s rel/tests -p 'test_*.py' -v
mise exec elixir@1.20.4-otp-27 erlang@27.3.4.16 -- elixir rel/tests/runtime_contract_test.exs
OPS_BRAIN_DISPOSABLE_TEST=true MIX_ENV=test \
  mise exec elixir@1.20.4-otp-27 erlang@27.3.4.16 -- \
  mix run --no-start scripts/concurrency_check.exs --disposable
```

The local recovery script additionally requires explicit local socket/port/database/admin environment guards; it creates a new uniquely named restore DB, never drops/cleans/overwrites an existing database, and retains the copy/artifact for inspection. `docs/DEPLOYMENT.md` supplies different, explicitly approved release backup/restore procedures. Never confuse the synthetic admin drill with certification of a live backup identity.

Exact counts, latency methodology/results, probe output and retained restore artifact are recorded in `IMPLEMENTATION_STATUS.md`. Final full application run:142 passed in19.5s (seed766324). The late collector audit and remaining ratio-timestamp fix are reconciled in `DELAYED_REVIEW_STATUS.md`. Native release + packaged API/assets/migration/disabled-default probe passed without app/Repo start. No Docker engine/container boot, real HTTPS proxy/browser IdP round trip, multi-node test or live source/sink validation was performed.

## What is still required from owners

1. **Installation/scope facts:** exact source endpoints/IPs/CA, Azure installation/API/project/definitions and bearer-token lifecycle, metrics/units/queries/limits, Loki tenant/selectors/parser, Kubernetes namespace/resource scope and service/environment mapping. PAT Basic is not implemented; do not put a PAT into a bearer slot and assume compatibility.
2. **Secret references, not secrets in chat:** least-privilege runtime DB, separate controlled migration/backup identities, session key, per-source read credentials and optional separate send-only notification identity. Use the documented private environment/mounted-secret mechanism.
3. **Independent optional approvals:** real OIDC issuer/client/redirect/subjects and provider MFA policy; approved notification endpoint/destination/content/idempotency semantics. They can remain disabled.
4. **Deployment validation:** selected host/image/dependency security review, TLS/trusted proxy/DNS/egress, container boot, ingress login limits, backup-role/restore/session/queue recovery review and realistic sustained load.
5. **Live onboarding:** controlled first-company contract/read-only/query-budget tests, then separately authorized second-company isolation/onboarding. Existing monitoring/paging remains unchanged.

## Deliberate implementation bounds (not credential promises)

Classic releases, arbitrary additional providers, runtime AI/remediation, automatic topology and universal historical reconstruction are not supported. UI uses bounded recent lists and scoped APIs, not unrestricted exports/full-history pagination. Workload inventory has documented caps and maps a configured namespace source to one service target. Notification integration is a generic approved HTTP sink, not every provider's proprietary API. OIDC supports explicit single-issuer RS256 registration/subject mapping, not discovery/group sync/provider logout. Replay cannot invent purged/pre-upgrade facts or rewrite human history. Further features need a separate implementation request; they are not silently promised merely by supplying credentials.

Collection, delivery, OIDC and scheduled maintenance stay off by default. Stop the application to stop all local work. Never enable placeholders or treat a completed local test as authorization for a live action.
