# Review fixes — plan and acceptance ledger

Scope: repair the three independently reproduced review findings. No live-provider access, source mutation, deployment, historical secret cleanup, or automatic resend of terminal notifications. Collection and delivery remain disabled by default.

## F1 — credential redaction

- Use one reviewed sensitive-key vocabulary for ordinary assignments and quoted JSON fields, including OAuth access/refresh/ID tokens and client secrets (case-insensitive, underscore/hyphen/camel-case spellings).
- Consume malformed quoted JSON tails conservatively, preserving existing UTF-8, byte-limit, quoted-assignment, and idempotency guarantees.
- Prove synthetic canaries do not survive source timeline parsing, persisted evidence, operator rendering, or notification payloads. Never include real credentials in tests.
- Historical evidence/backups are not rewritten by this patch. Any remediation or credential rotation needs an owner-approved procedure.

## F2 — pending notification loss after local updates

- Keep issue revisions and delivery identities. A newer issue revision alone is not evidence that another notification replaces a pending one.
- Coalesce only when a newer outbox entry actually exists for the same group/destination; otherwise claim the current issue revision using the existing outbox ID.
- Serialize short database claims in group-then-outbox lock order. Do not hold locks across HTTP.
- Preserve Retry-After, digest/snooze deadlines, attempts, idempotency keys, and terminal/ambiguous outcomes. Local edits must never create an automatic resend of a previously terminal notification.
- Cover assignment, unassignment, local review, in-flight rate limiting, true replacement, and company isolation.

## F3 — stored capacity forecasts absent from the Capacity page

- Store explicit service identity with new capacity evidence. Read bounded, unexpired capacity evaluations under authenticated company scope.
- Resolve legacy service mappings only from retained explicit identities/input windows; leave unresolved evidence labeled unmapped. Filter environments before limiting forecasts.
- Render stored conditions, threshold estimates, reasons/prerequisites, evaluation times, and diagnostic evidence. Do not recalculate forecasts in the UI or imply that historical results are current health.
- Make capacity summary cards count evaluations, not raw gauge-window conditions. Keep supporting service/window views and source data unchanged.
- Cover real evaluator-to-LiveView behavior, normal/unknown/critical results, expiry, legacy evidence, environment/search refresh, revoked access, and company isolation.

## Acceptance ledger

| Check | Status |
| --- | --- |
| Redaction unit and persisted/UI/delivery canaries | Passed: `RedactorTest`, `RedactionFlowTest`; original persisted-secret probe also passes |
| Notification revision/identity/retry/replacement regressions | Passed: `NotificationRevisionTest`; original assignment-loss probe also passes |
| Capacity evaluation retrieval/UI/isolation/expiry regressions | Passed: `CapacityLiveTest`; original real-evaluator/normal-gauge probe also passes |
| Formatting and warnings-as-errors compilation | Passed: `mix precommit`; production `mix compile --warnings-as-errors` |
| Full suite on a newly provisioned, explicitly disposable local database | Passed: 249 tests, seed 881224, PostgreSQL 18, separate restricted runtime/migrator roles |
| Final patch review and configuration/route verification | Manual source review and `git diff --check` passed; API, route and default-off switches confirmed; Contour cannot assess Elixir |

## Implementation and verification

- **Redaction:** `lib/ops_brain/redactor.ex` shares OAuth key spellings between assignment/JSON rules and consumes truncated quoted JSON tails. Existing limits and benign-text behavior remain covered.
- **Delivery:** `lib/ops_brain/notifications.ex` serializes short group/outbox claims, checks for a real replacement, and updates the pending payload revision without changing its delivery identity or retry budget. No local edit resurrects delivered, rejected, ambiguous or already-coalesced records.
- **Capacity:** `Services.capacity_evaluations/3` is the authenticated bounded reader; `Evaluations.capacity/3` adds explicit service identity to new evidence. `OperationsLive` streams stored evaluations and `UI.summaries/2` counts forecast results separately from supporting gauge windows.
- No schema, migration, dependency, lockfile or configuration changes. Existing capacity routes and disabled-by-default collection/delivery switches are unchanged.

Commands actually run from `ops_brain/` via `mise exec --` and the isolated database harness:

1. `mix test test/ops_brain/redactor_test.exs test/ops_brain/notification_revision_test.exs test/ops_brain_web/redaction_flow_test.exs test/ops_brain_web/capacity_live_test.exs`: **24 passed**, seed 341019. An unused test alias warning was removed.
2. The first full precommit run caught a shared-search regression: pipeline `result` values are strings, not forecast maps. Removed the unnecessary map-specific search code; retained the original search contract rather than weakening tests.
3. Affected console/demo/operations LiveView modules plus the three original independent review probes: **25 passed**, seed 259922.
4. Final `mix precommit`: **249 passed**, seed 881224; formatting, warnings-as-errors compilation and dependency-lock hygiene passed.
5. `MIX_ENV=prod mix compile --warnings-as-errors`: passed. Final `git diff --check`: passed. Public reader, route wiring and default-off configuration were mechanically checked.

Test evidence: `/tmp/aiops-fixes-1790402389226/check.log`; temporary setup/runner in the same directory. The newly created `ops_brain_test_fixes` database was explicitly approved as disposable before fixtures ran, and its private PostgreSQL instance was stopped afterward. No live provider or notification endpoint was contacted; HTTP sinks were synthetic stubs. Contour reported unsupported-language coverage gaps, not a correctness approval.

## Limits, disable and recovery

- Historical stored credentials/backups are **not** rewritten or declared clean. Any affected credential rotation or retained-data cleanup requires separate owner approval.
- Existing terminal/coalesced notices are **not** automatically resent. Review historical delivery gaps manually before authorizing any resend.
- Capacity lists contain at most 100 unexpired retained evaluations, not a current-health verdict or calibrated forecast. Missing legacy identities/results stay explicit; no backfill or new measurements are invented.
- To disable collection/delivery, retain the existing false switches or stop the application. Rollback is a code redeploy; the additive JSON `service_id` field requires no migration and is harmless to prior readers. Do not remove existing retention/security controls.
- Real-provider, browser-visual/accessibility, container/release and deployment acceptance were not run in this slice. No production readiness is claimed, and no commit, push or deployment was performed.
