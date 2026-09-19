# Ops Brain v2 — implementation ledger

Updated 2026-09-19 after the credential-free completion pass. The user authorized all17 roadmap tasks (000–016) and subsequent code/preparation work, superseding the original one-task stopping rule. Application: `../ops_brain/`. Original specifications and source safety boundaries are preserved.

**Local implementation/preparation is delivered; production acceptance is not.** Credentials are not required for the implemented code/tests, but approved installation details, live contracts, deployment/security validation and second-real-company onboarding remain required. No source was connected, external notification sent, cloud resource provisioned or production deployment performed. Configuration placeholders are intentionally disabled and rejected if enabled unchanged.

## Current task ledger

| Task | Delivered code/evidence | Remaining external gate or explicit scope limit |
| --- | --- | --- |
| 000 | Discovery, read-only ADR and fixture contract | Real pilot/installation approval |
| 001 | Hashed one-use capabilities, revocable sessions, membership-bound scopes, composite tenancy relationships, forced RLS and runtime safety checks. Optional OIDC with JOSE, PKCE/state/nonce/signature/issuer/audience checks and explicit local subject mappings; bounded login admission | Approved IdP/subjects/proxy/browser round trip; provider-enforced MFA policy is not inferred by app |
| 002 | Durable Azure Build fixed-bound polling, paginated opaque cursors, overlap, immutable snapshots, active/recent reconciliation, fenced leases/requests, Retry-After and honest distinct counts | Live Azure Services/Server contract. Recent reconciliation is not exhaustive ancient history; current auth is bearer, not PAT Basic |
| 003 | Bounded failed-leaf/attempt evidence, structured issues, redacted log fallback, references and missing/truncated context; enrichment revision checks | Real source format/permissions. One bounded log sample per step; historical references are not recursively fetched |
| 004 | Versioned exact failure fingerprints, preserved HTTP/SQLSTATE/tool distinctions, separate occurrences/episodes and grouping reasons | Exact matching is not root-cause proof; fuzzy/AI grouping is excluded |
| 005 | Authenticated pipeline/investigation UI, reauthorized refresh, evidence drilldown, local acknowledgment/closure/snooze, assignment API and evidence-backed recovery | UI deliberately shows bounded recent sets, not unrestricted export/full history navigation; quiet never means recovered |
| 006 | Trusted source config, operation allowlists, fixed reviewed-IP/verified-host TLS, redirect denial, shared admission/rate/queue/byte/time bounds, rotating scheduling and source-health views | Real read-only credentials/egress/query cost audit; runtime never provisions permissions |
| 007 | Prometheus gauge and ratio profiles, validated semantics/units/freshness/warnings/no-data, matched timestamp/volume operands and fixed windows | Installation metric/query mapping and threshold calibration |
| 008 | Explicit company/service/target/source/environment identities, unresolved CI retained, mapped reported deployment evidence | Owner-approved topology; CI deployment reports are not runtime health confirmation |
| 009 | Loki aggregate-first60-second windows, bounded samples and explicit truncation/unknown, late revisions and recent reconciliation | Real selectors/parser/tenant controls; bounded reconciliation horizon |
| 010 | Exact sample signatures, preserved repeated-sample multiplicity and sustained adjacent-window notices | Sample signature memberships are not backend per-signature total counts |
| 011 | Namespace Deployment/ReplicaSet/Pod/Event list/watch; bounded resumable pagination; durable per-resource opaque positions; disconnect/410/scope-change relists and gaps; UID owner chains/name reuse; initial inventory not change; restart/OOM/repeated-Event handling. Atomic cursor/evidence persistence, stale/capped coverage, source error/last-success truth and adversarial tests | Namespace/source maps to one configured service target; no topology discovery. Tested bounds are documented in `docs/WORKLOADS.md`; real RBAC/API validation still required |
| 012 | Conservative conditional stable-segment capacity forecasts and recorded-policy offline replay/backtest | Real limits/autogrowth/segment identities and utility calibration; synthetic false/missed warnings are explicitly reported |
| 013 | Explicit-identity/time correlation, durable investigation worker, alternative/counterevidence candidates, reverse-arrival revisions and recorded-input replay | Bounded candidates, not causality; old output-only correlations cannot become historical inputs |
| 014 | Optional company-approved fixed HTTP sink; separate identity; outbox coalescing/deadlines/quiet/cooldown/severity/recovery, bounded429 retry and explicit ambiguous delivery | Generic HTTP contract only; actual provider/recipient/idempotency approval; delivery remains off |
| 015 | Versioned immutable observation revisions and paged offline replay across all implemented detectors; event+receipt cutoffs; bounded dependency-aware operational retention and separate auth/job maintenance; pool4 concurrent tenant/source-budget probes and separate pool1 OIDC tests; guarded local restore drill; release/config/backup helpers | Missing/expired/pre-upgrade inputs cannot replay. No multi-node/production soak or production recovery certification. Container/proxy execution needs deployment environment |
| 016 | Expanded real-PostgreSQL tenant/composite/RLS/worker/UI/topic/recipient checks, pooled-scope isolation and second-company checklist | **Blocked external acceptance:** no second real company, independent approved credentials or live onboarding. Synthetic fixtures never complete this gate |

## Final measured verification

Toolchain: Elixir1.20.4/OTP27.3.4.16 (mise), locked dependencies, dedicated PostgreSQL16.15 at `/tmp/ops-brain-pg/socket:55432`; separate `ops_brain_runtime` and `ops_brain_migrator`. No live provider calls. Test cleanup is destructive: only explicitly disposable `ops_brain_test...` databases are permitted.

- **`mix precommit`:142 passed,0 failures**, final seed766324,19.5 seconds; warnings-as-errors/unused-dependency/format checks in the alias. Covers real RLS/transactions, local real TLS, authenticated LiveView, JOSE/provider stubs, source-contract fixtures, replay/retention and regressions.
- **12 Python release-contract/shell behavioral tests +6 standalone Elixir runtime-contract tests passed.** Docker/Compose image execution was not available; these are not container-boot results.
- `mix format --check-formatted`, `MIX_ENV=prod mix compile --warnings-as-errors`, `mix phx.digest` and `MIX_ENV=prod mix release --overwrite`: passed. Native release produced at `_build/prod/rel/ops_brain`.
- Packaged `rel/tests/release_probe.exs`: passed with synthetic nonconnecting environment values. Verified exported configuration/database/migrator APIs, disabled example configurations, complete packaged migrations/assets/overlays and locked Plug HTTPS-forwarding semantics; asserted no app/Repo start.
- `mix ops_brain.validate_config config/sources.prepared.json`: valid **4 sources/1 destination**, all disabled. Empty example also validated. This performs no credential/network/DB check. Tests reject enabled reserved-placeholder configurations.
- `mix phx.routes`: sign-in/out, OIDC POST/callback GET, authenticated portfolio/company/source/pipeline/service/investigation/capacity/source-health and LiveView routes verified. No remediation/source-admin/public enrollment route.
- Mechanical/runtime checks cover15 FORCE-RLS operational tables, immutable revision UPDATE denial, separate directory privileges, four source kinds, watch supervision, maintenance scheduling/kill switches and both grant contracts. Runtime cannot administer operators/companies/memberships.
- Secret-file ignore rules and local restore opt-in rejection/shell syntax verified. Docker build context is allowlisted; real credentials are never examples/build inputs.

### Multi-connection synthetic probe

`OPS_BRAIN_DISPOSABLE_TEST=true MIX_ENV=test mix run --no-start scripts/concurrency_check.exs --disposable` passed using runtime pool4,8 concurrent clients and **4 observed physical backend connections**. It verifies concurrent A/B grouping/isolation, clean pooled scopes after successful transactions, and quiet-source budget progress despite noisy-source saturation. Correction after delayed review: the script does not exercise rollback, composite constraints, OIDC contention or cursor/evidence atomicity. Those have separate ordinary-suite tests; OIDC one-winner callers share the ordinary pool1, not four physical connections. 240 grouping transactions completed in642.347ms; A200/B40, nearest-rank per-transaction latency:

| Synthetic company | p50 ms | p95 ms | p99 ms |
| --- | ---: | ---: | ---: |
| A |13.470|19.651|27.213|
| B |7.557|26.227|34.328|

The earlier seed390434 ordinary suite also measured200 serial grouping transactions: p50=3.434ms, p95=4.921ms, p99=6.363ms, summed721.893ms, pool1/concurrency1. Host previously recorded Linux6.17.0-1022-azure x86_64, i5-12600,12 logical CPUs,33,769MiB; shared/nonreserved environment. These numbers measure local synthetic DB work, **not** upstream throughput, fairness under realistic sustained traffic, sizing or production latency.

### Recovery and forecast probes

`scripts/local-recovery-check.sh` passed against the dedicated synthetic database: custom-format dump/transactional restore into **new** `ops_brain_test_restore_1789833970_494903`, exact row-count comparison for every public table, runtime grants,15 forced-RLS tables and missing-scope denial. Collectors were never started. Restricted artifact: `/tmp/ops-brain-recovery.E4Tog3/data.dump`; isolated copy retained for inspection. Earlier new-migration rollback/reapply and synthetic dump/restore also passed. Production/backup-role operation, session invalidation and queue disposition require separate approval/drills.

Earlier leakage-free capacity backtest remains valid:18 synthetic evaluations,10 unknown,3 warnings;2 useful/1 false,2 missed crossings; warning precision2/3, crossing recall1/2, false-warning rate1/14, mean useful lead450s. No claim of real forecast calibration.

## Delayed review follow-up

The late collector report was checked against the current tree. Most reported defects already had fixes; added byte-only cap/endpoint-rotation/lease-release regressions and strengthened deletion/freshness/privilege assertions. One remaining defect was reproduced and fixed: derived metric ratios now retain the oldest actual operand timestamp instead of collection time. Full suite142/142 and refreshed production release pass. Corrected earlier overstatements of the concurrency script's scope (above); it is not an OIDC or cursor-atomicity test. Full finding-by-finding evidence: [`DELAYED_REVIEW_STATUS.md`](DELAYED_REVIEW_STATUS.md).

## Review and limitations

Independent read-only reviewers inspected scoped auth, replay/retention and implementation changes. Findings fixed/tested include duplicate ratio timestamp bias, resumed pagination after watch disconnect, malformed resource retention, oversized workload output checkpointing, disabled/mapping configuration changes, source-health false success, forbidden operator UPDATE dependence, replay future embedded sample leakage, and retention reviving expired revisions. Earlier transport/fencing/deadline/reconciliation/recovery regressions remain covered. This is not a certified security audit.

No browser-driven accessibility/visual assessment, live IdP/source/sink integration, multi-node contention, real production load, image vulnerability approval or production disaster-recovery exercise was completed. Logs/evidence redaction is not proof of zero sensitive data. Restrict DB/backups and review retention; protected live dependencies may retain data longer than policy, and expired history is irrecoverable without backup. No unused placeholder code pretends to support classic releases, arbitrary providers, automatic topology, runtime AI or source remediation.

## Handoff

- Completion checklist and new artifact map: [`PREPARATION_STATUS.md`](PREPARATION_STATUS.md).
- Credentials/endpoints/secret references to supply privately: [`../ops_brain/docs/CREDENTIALS.md`](../ops_brain/docs/CREDENTIALS.md).
- Disabled templates: `../ops_brain/config/sources.prepared.json`, `../ops_brain/.env.example`, `../ops_brain/compose.example.yml`, `../ops_brain/config/kubernetes-role.example.yaml`.
- Deployment/disable/recovery: `../ops_brain/docs/DEPLOYMENT.md`; optional OIDC: `docs/OIDC.md`; workload/replay semantics: `docs/WORKLOADS.md`, `docs/REPLAY_RETENTION.md` under the app.
- One-company source approval: `../ops_brain/docs/ONBOARDING.md`; second company: `../ops_brain/docs/SECOND_COMPANY_GATE.md`.

Do not paste credentials into chat or tracked files. Collection, delivery, OIDC and scheduled maintenance are off by default. Stop the app to stop all work; change deployment-owned switches and restart for individual kill switches. No commit or production action was made.
