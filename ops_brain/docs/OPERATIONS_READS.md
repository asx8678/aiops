# R21 / R22 — operations reads and investigation UI

## Acceptance ledger

- **Page before aggregate:** `OpsBrain.Issues.list/1` materializes the latest 100 tenant-visible groups with deterministic `last_seen, id` ordering, then computes exact retained occurrence/run/attempt counts with a correlated lateral aggregate. The zero-occurrence case remains zero. The restricted runtime role still authorizes every transaction and enforces RLS.
- **Read access paths:** `priv/repo/migrations/20260920110735_add_operations_read_indexes.exs` adds company-prefixed issue-page, occurrence-count, pipeline-page, notification-state and deployment-evidence indexes. No new tables or grants. Apply with the migration role, not the runtime role, before releasing this slice. Normal index builds can lock writes: schedule production migration review; this run migrated only the approved disposable database.
- **Route-specific loaders:** pipelines load run projections with up to 20 retained explicit deployment mappings per run; investigations load issue groups; services/capacity load service identities and windows; source-health loads source state. No route loads all five datasets. Refreshes retain authorization checks.
- **Investigation UI:** renders scope, count basis, first/last timestamps, owner, snooze, lifecycle status and revision. Local assignment/unassignment, review and snooze failures are visible. Evidence includes current/historical revision labels, occurrence/receipt/expiry timestamps, persisted correlation candidates, counterevidence and missing prerequisites. Diagnostic JSON remains in expandable details.
- **Mapping honesty:** successful CI is not runtime health. Only unexpired, same-company/source deployment evidence joined to explicit service/environment identity produces a mapped target. Otherwise the run is explicitly unresolved. Reported deployments are not labeled runtime-confirmed.
- **Notification privacy:** `OpsBrain.Notifications.status/2` returns at most 20 scoped local outbox records, ordered by update time and ID. It exposes no provider credentials, payloads or global Oban arguments/errors. DOM identifiers use unique outbox IDs, not destination/status combinations.
- **Evidence lifecycle:** selection is cleared on refresh/navigation (including company changes). Reopening reauthorizes and rechecks expiry. Expired payloads are replaced with the existing expiry marker. Revoked membership redirects before further pushes or actions.

## Verification (local, synthetic)

- `mix precommit`: **203 passed**, including all new tests; compile/format checks passed.
- Targeted operations, read-plan, evidence-revision and authorization modules: **29 passed** before the final candidate-presentation assertions; the full precommit includes those final assertions.
- `OperationsReadTest`: 151 groups, exact non-duplicate counts, deterministic top 100, other-company exclusion. Captures the actual production SQL and runs `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` as the restricted role. Asserts a 100-row limit and exactly 100 aggregate loops; confirms new indexes exist.
- `OperationsLiveTest`: actual query telemetry checks route load isolation; exercises local actions/errors, scoped/capped notification reads, duplicate destination/status records, evidence revisions/expiry, explicit deployment mapping/expiry, candidate/counterevidence presentation, cross-company navigation and membership revocation.
- `git diff --check`: passed.

Artifacts:
- `/tmp/ops-brain-r21-r22-migration.log`
- `/tmp/ops-brain-r21-r22-targeted.log`
- `/tmp/ops-brain-r21-r22-explain.json`
- `/tmp/ops-brain-r21-r22-precommit.log`

An initial migration invocation used TestAdminRepo's default migration directory; corrected with `--migrations-path priv/repo/migrations`. An expiry fixture initially mixed database and application clocks; corrected to use the injected application clock. No safety gates were weakened.

## Limits and remaining gates

The 100-group page limits aggregate scope, not a constant number of occurrence rows. Exact counts still scale with retained occurrences in those groups; this synthetic plan is not a production-load benchmark. Evidence, revision, mapping and notification lists are capped samples, not complete history. Automatic refresh closes evidence details intentionally to avoid stale retained snapshots. No new source requests, notification sends, upstream actions or runtime AI were added.

Interactive browser/accessibility review, production-scale timing, deployment and container validation were not performed. R08's audit/optimistic-concurrency work is separate. No commit, push, PR or deployment was created. To roll back this UI slice, redeploy the preceding code; the added indexes are additive and may remain until separately approved removal.
