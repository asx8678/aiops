# Layer-by-layer delivery roadmap

The product covers all authorized companies and dev/staging/prod. Rollout remains incremental. Synthetic fixtures should include two companies with colliding service names from the first tenancy work; do not connect every real company to an unvalidated prototype.

Each task is a separate reviewed change. Do not implement the whole roadmap in one agent session.

| Task | Deliverable | Mandatory gate |
|---|---|---|
| 000 | Inspect repository; reconcile v2 requirements; validate one source contract and pilot | Confirmed facts separated from unknowns; no source mutation or scaffolding spree |
| 001 | Phoenix/PostgreSQL baseline and company-scoped authorization foundation | Two-company collision/authorization tests; existing tests remain green |
| 002 | Durable Azure DevOps run polling | Pagination/restart/overlap tests; correct distinct counts and coverage |
| 003 | Failed timeline and bounded log evidence | Attempts/hierarchy preserved; redaction; absent logs handled |
| 004 | Exact normalized failure grouping | Positive/negative fingerprint fixtures; no count inflation or cross-company merging |
| 005 | Live local notices and pipeline overview | Actual stored data; issue lifecycle; no fabricated health; no source writes |
| 006 | Harden source health/query budgets and onboarding | Noisy source isolation, throttling, egress, stale/unknown states |
| 007 | One read-only metrics adapter/profile | Correct semantics/units; missing data and query limits proven |
| 008 | Dev/staging/prod portfolio/service views | Explicit target mapping; CI-only/unknown targets preserved; visibility rules tested |
| 009 | One log backend: aggregate-first counts | Fixed-window revisions, truncation, parser/late-data tests |
| 010 | Log signatures and error-burst notices | Sampling limits visible; overlapping reads don't inflate totals |
| 011 | Kubernetes list/watch corroboration | Reconnect/410/relist/UID/initial-state tests; narrow permissions |
| 012 | One capacity early-warning detector | Conditional forecast, insufficient-history, resize/no-growth tests |
| 013 | Evidence-linked change correlation | Reverse-arrival replay, competing changes, preexisting symptoms, no causal overclaim |
| 014 | Optional separately approved external digest delivery | Outbox/idempotency/cooldown/recipient-isolation tests; existing paging unchanged |
| 015 | Replay, retention, backup/recovery and realistic load gate | No external effects during replay; bounded backlog and storage; actual measurements |
| 016 | Second real company, then wider production coverage | RLS/application/topic/export isolation; independent credentials; scoped network review |
| 017+ | One additional detector per task | Verified required inputs; evidence of useful precision/lead time |

Security, data freshness, query budgets and source isolation start with the first live connector. Tasks 006/015/016 are expansion/hardening gates, not permission to defer basic safeguards.

## Acceptance milestones
A. One existing Azure project is read without pipeline changes; failed runs appear with evidence and honest coverage.
B. Similar failed attempts produce a useful local grouped notice with distinct-run counts.
C. One company has explicitly configured dev/staging/prod service visibility; no-data remains unknown.
D. Actual metric and log observations produce independent notices even without a deployment event.
E. A storage target yields a conditional, tested early warning from available telemetry.
F. Company isolation, source permissions, recovery and load behavior justify expanding real coverage.

## Environment rollout
Develop against fixtures/local dependencies, validate against selected dev or staging sources, and then add approved production reads. Production need not await every optional detector, but access/limits/freshness gates must pass. All environments remain part of the data model; different intervals and notification severity are explicit policy.

## Agent collaboration
Assign one implementer and an independent reviewer per task. Reviewers check actual diff and tests, including wrong-company, duplicate, late, missing and sensitive inputs. One agent owns shared migrations/interfaces at a time. Parallelize only independent leaf work after contracts are stable.
