# Constellation deep application review plan

## Objective and scope
Independently audit the current working-tree application, not only the latest diff. Deliver an honest overall score from 1–100, category scores, substantiated strengths, substantiated weaknesses, and an actionable improvement roadmap. Assess this as a read-only operations command center; do not penalize the deliberate absence of runtime AI, remediation, or upstream mutations. Distinguish useful local/demo functionality from production readiness and live-provider validation.

Primary scope: ops_brain/lib, config, priv/repo, assets/templates, test, scripts, rel, Docker/release configuration, mix.exs/mix.lock, .github/workflows/ci.yml. Use ops_command_center_v2 requirements/status documents as claims to verify, not evidence that functionality works. Existing review reports are leads, not findings to copy.

## Safety and baseline
- Review only. Do not fix code, format source, change dependencies/lockfiles, commit, push, deploy, enable collectors/delivery/OIDC, or contact real providers.
- Existing tracked modifications and untracked implementation files are user-owned. Include them in the reviewed snapshot, preserve them, record git HEAD and initial/final status. Explicitly identify any drift during review.
- Only write ops_brain/docs/DEEP_REVIEW_REPORT.md. Do not overwrite existing audits or this plan. Temporary local test artifacts are allowed only when isolated and non-destructive.
- Never expose environment secrets or credential values. Inspect configuration names and redacted metadata only.
- Database tests truncate tables. Run them only after independently verifying dedicated disposable local database identity, distinct runtime/migrator roles, and existing explicit disposable approval. Never approve/relabel an existing DB, bypass guards, or provision infrastructure without permission. If unavailable, report the blocker and continue safe static/non-DB checks.
- Do not run mix precommit: its format/deps.unlock aliases mutate the tree. Inspect every validation command and helper before executing it. Do not install missing dependencies or make external network calls without approval.

## Evidence method
Start with Fovea sketch/focus, then bounded source reads and searches. Fovea's Elixir/Bash import coverage is incomplete: explicitly trace function callers, authorization, database operations and job flow in source. Maintain an acceptance ledger with each review area marked inspected/tested/blocked/not applicable and linked evidence. Record commands, working directory, exit code, summarized results and limitations. A passing build is not behavioral proof. Do not claim a visual/runtime check from reading templates. Distinguish confirmed defects, credible risks, untested assumptions and intentional tradeoffs. Cite repository-relative path:line for material strengths and weaknesses; attach test/reproduction evidence when feasible.

## Review sequence
### 1. Inventory and product contract
Map boot/supervision, HTTP and LiveView routes, user roles, session/OIDC flows, workspace/company/environment selection, storage, background jobs, connectors, notification sinks, configuration and release tooling. Cross-check README and implementation/repair ledgers against reachable code. Identify stubbed, synthetic, disabled, or unreachable paths; separate current capabilities from planned features.

### 2. Trace critical user and data journeys end to end
For each journey record entry point, validation, authorization, data transformations, persistence, failure behavior and visible outcome:
1. Sign-in, sign-out, session expiry/revocation, OIDC callback, rate limiting, unauthorized HTTP and LiveView access.
2. Single-workspace landing, company/environment navigation, cross-company URL/ID tampering, membership changes after socket mount.
3. Source configuration -> admission/scheduling -> Azure Build/Prometheus/Loki/Kubernetes reads -> checkpoints -> evidence -> issues/investigations -> service/capacity views.
4. Evidence revision -> issue review/human decision -> audit event -> UI refresh; stale decisions and concurrent updates.
5. Issue evaluation -> local notice -> optionally approved HTTP delivery -> ambiguous/failure outcome -> recovery; no accidental replay.
6. Retention -> tombstones -> replay/recovery; expired or incomplete evidence remains honestly unavailable.
7. Offline synthetic demo setup/navigation vs real operations; synthetic data cannot leak into genuine health claims.

Exercise representative happy paths plus unauthorized, empty, stale, malformed, oversized, timeout, duplicate, restart and concurrent-event paths. Use safe existing tests/probes where possible; document unexercised branches.

### 3. Security and privacy deep review
Check HTTP/LiveView authorization and tenant/company boundaries, forced RLS and runtime grants, query scoping and SQL transaction context, secure cookies/CSRF/cache/security headers, OIDC state/nonce/PKCE/signature/issuer/audience/expiry handling where applicable, session storage and revocation. Trace SSRF defenses including URL/IP/DNS validation, redirects, original-host TLS, endpoint allowlists and response bounds. Inspect secret references, logging, stored evidence, UI rendering and redaction (malformed quotes, UTF-8, large inputs). Verify all collection/delivery gates fail closed, upstream operations stay read-only, and admin/test/release helpers cannot quietly bypass database safety. Inspect locked dependency risk without asserting an online vulnerability audit occurred.

### 4. Correctness, durability and reliability
Review domain invariants, issue lifecycle, grouping/fingerprints, evaluation/correlation accuracy and uncertainty, capacity assumptions, evidence lineage and replay determinism. Trace Ecto constraints/migrations/transactions, idempotency, fences/leases/checkpoints, job uniqueness, retries/backoff, restart recovery, out-of-order events, watch gaps, partial failures and ambiguous delivery. Evaluate scheduler fairness, bounded budgets, backpressure, cleanup/retention and stale-health semantics. Confirm database grant copies and migration/schema consumers remain consistent.

### 5. UX and accessibility
Inspect portfolio/company/demo/pipelines/services/investigations/capacity/source-health/source detail journeys. Evaluate useful information hierarchy, operator actions, navigation, loading/empty/error/stale/permission states, evidence links and audit visibility. Check labels, keyboard/focus behavior, semantic markup, status conveyed without color, responsive layout and escaping. If a safe local running instance/browser is available, perform runtime checks; otherwise clearly mark visual/accessibility behavior unverified rather than inventing observations.

### 6. Performance and operability
Inspect query limits/indexes/N+1 patterns, aggregation cost, LiveView assigns/render/update behavior, collection concurrency, response/evidence size limits, memory bounds and queue growth. Separate measured performance from static risk. Review telemetry, health/readiness, redacted actionable diagnostics, alerts, configuration validation, least privilege, TLS, Docker/release startup, migration/grant ordering, backup/restore safeguards, rollback and recovery documentation. No live load tests or external traffic.

### 7. Architecture, maintainability and tests
Assess boundaries, duplication, hidden coupling, large modules, error contracts, explicit configuration and readability. Map tests to critical invariants, not file counts. Look for overly mocked assertions, missing negative/concurrency/restart cases, flaky clocks, DB isolation and gaps between CI and docs. Examine recent uncommitted issue_review, redactor, evaluations, notifications, database_safety, services, OperationsLive and audit migration work alongside unchanged callers. Revalidate old reported fixes rather than assuming they passed.

### 8. Validation matrix
After checking prerequisites, run safe applicable project commands: format --check-formatted, warnings-as-errors compilation, targeted tests, then full suite if disposable DB is verified; production compilation, route listing and both example/prepared configuration validators where safe. Inspect release contract tests and synthetic capacity backtest before running; execute non-DB checks that do not need live credentials. Use toolchain specified by mise.toml. Do not rerun unchanged passing checks. Missing runtime/dependencies/database are explicit blockers, not passes and not automatically product defects. Report pre-existing configured check failures honestly.

## Weighted scoring rubric
Assign each category an integer 1–100 and show weight, score, weighted contribution, evidence and confidence:
- Functional correctness and product completeness: 20%
- Security, privacy and company isolation: 20%
- Reliability, data integrity and recovery: 15%
- UX and accessibility: 10%
- Architecture and maintainability: 10%
- Test quality and verification coverage: 10%
- Performance and resource efficiency: 5%
- Deployment, observability and operational readiness: 10%
Overall = round(sum(category score * weight / 100)); clamp to 1–100. Show arithmetic. Do not double-deduct one root cause without explaining distinct impacts. Score bands: 90–100 excellent with strong evidence; 75–89 solid with meaningful gaps; 60–74 usable with substantial risks; 40–59 fragile/incomplete; 1–39 severe foundational problems. Scores are judgment, not a certification. Missing evidence lowers confidence; missing required safeguards lowers scores. Provide a separate production readiness verdict (ready / conditional / not ready) and blockers; a high aggregate cannot cancel a critical security flaw. Acknowledge repository documentation already disclaims production/live validation.

## Final report format
1. Executive summary: overall N/100, readiness verdict, confidence, top 5 strengths, top 5 weaknesses.
2. Scope/baseline and evidence coverage ledger, including snapshot identity and drift.
3. Weighted score table with short rationale per category and transparent arithmetic.
4. Architecture and end-to-end journey matrix.
5. Confirmed findings ranked Critical/High/Medium/Low; unique ID, title, path:line, evidence, reproducible steps or source trace, expected vs actual, operator/business impact, likelihood/preconditions, recommended fix, regression test, rough effort S/M/L and confidence. Keep hypotheses in a separate risk section.
6. Strengths worth preserving with concrete citations; no generic praise.
7. Test/probe command results and what they do/do not prove; blocked/skipped checks.
8. Prioritized remediation roadmap: immediate blockers, next iteration, later improvements; identify quick wins and architectural investments. Recommendations only, no implementation.
9. Unresolved questions, environmental limitations and specific evidence needed to raise confidence/score.

## Acceptance ledger for Main review
- All eight scoring categories covered and weighted arithmetic correct.
- App-specific critical journeys traced in actual code, including auth/company isolation, ingestion/checkpoints, review/audit, delivery and retention/replay.
- Findings and positive claims have verifiable evidence; severity is justified; no copied unverified audit claims.
- Actual checks and blockers are reported, with no fabricated execution, live validation or visual observations.
- Existing dirty tree preserved; only the designated report is added.
- Overall score and production readiness distinguish product quality from verification confidence.
- Report is actionable and understandable to the owner; no secrets included.
