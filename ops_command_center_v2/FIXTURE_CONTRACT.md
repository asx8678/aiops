# Discovery fixture contract — synthetic-build-v1

Status: proposed fixture definition for independent review; not executable test results, captured source data, live configuration or source-owner approval. No fixture payload files or production seed data are installed by task 000. Implement the relevant fixtures with tests in tasks 001–003 rather than scaffolding later features now.

Related: [ADR 000](decisions/000-read-only-build-pilot.md), [acceptance scenarios](ACCEPTANCE_TESTS.md), [next task](tasks/001-tenancy-foundation.md).

## Provenance, scope and sanitization
This set is entirely synthetic. It may be used only with local test data/HTTP-boundary stubs and must be explicitly labeled synthetic in each future fixture manifest. The source owner has approved no real company or source. Services-shaped REST 7.1 is the proposed documentation baseline; Server/version compatibility remains unknown.

| Local identity | Company A | Company B |
|---|---|---|
| Internal company UUID | `00000000-0000-4000-8000-000000000001` | `00000000-0000-4000-8000-000000000002` |
| Company alias | `synthetic-a` | `synthetic-b` |
| Source UUID | `00000000-0000-4000-8000-000000000011` | `00000000-0000-4000-8000-000000000012` |
| Source display name (intentional collision) | `delivery` | `delivery` |
| Service display name (identity test only) | `checkout` | `checkout` |
| Project ID (intentional collision) | `00000000-0000-4000-8000-000000000020` | `00000000-0000-4000-8000-000000000020` |
| Definition ID / run IDs | `7` / `101`–`104` | `7` / `101`–`104` |
| Stub origin (must never resolve externally) | `https://ado-a.invalid` | `https://ado-b.invalid` |
| Environment names | `dev`, `staging`, `prod` | `dev`, `staging`, `prod` |
| Run environment mapping | `null` / unresolved, not production | `null` / unresolved, not production |

These UUIDs are proposed local test identifiers, not public application interfaces or approved source configuration. Do not build runtime service tables merely for a display-name fixture; introduce service entities when their task requires them. Configure each stub with its company/source identity on the trusted side. A payload's company ID, hostname or source URL must never override that binding. No credentials are included. Stub authentication values, if needed by tests, are obvious nonfunctional sentinels and never logged.

Future source fixtures use allowlisted IDs, UTC timestamps, result/status fields, hierarchy/attempt references and deliberately synthetic issue text only. Strip real tokens, cookies, authorization headers, signed URLs, emails and sensitive paths before importing any later owner-approved capture. Record origin, adapter/schema version, sanitization review and expected limitations. Secret-redaction tests use unmistakably fake canaries, assert their absence across persistence/jobs/UI/telemetry, and keep HTTP 401/403 and tool/SQLSTATE/dependency distinctions. Redaction and fingerprint normalization are separate.

## Task 001: local authorization fixture assertions
- An operator with membership only in A cannot fetch B's company/source via direct ID, guessed source ID, HTTP entry or LiveView mount/reconnect/event. No membership or missing authenticated scope denies access.
- A second operator belongs only to B; an explicitly dual-member operator may aggregate only those memberships. Equal display names do not confer access or merge records.
- A company-A trusted source cannot claim B through request fields or headers. Composite relationships reject cross-company references, independently of UI filters.
- On a real PostgreSQL pool, establish transaction-local A scope, commit or roll back, reuse the connection and prove no A scope remains. Missing scope denies operational queries; B scope cannot access A. Exercise the runtime role rather than treating a superuser test as proof of RLS.
- Use local-only seeds; production has no default user/password or authentication bypass. Unknown external SSO configuration fails closed. Auth mechanism/version choices remain task 001 decisions.

## Task 002: deterministic metadata collection scenarios
Use an injected evaluation clock, not wall time. Proposed completed window: `2025-01-01T00:00:00Z` through `2025-01-01T01:00:00Z`, with an explicitly tested overlap. Source event time, receipt time and evaluation time remain distinct. Test time-bound edge semantics rather than presuming inclusive provider behavior.

| Scenario | Synthetic arrangement | Required assertion when implemented |
|---|---|---|
| Two result pages | Page 1: runs 101 failed, 102 succeeded and opaque continuation; page 2: 103 canceled, 104 partiallySucceeded and terminal pagination | Checkpoint stays incomplete after page 1. After both pages, four distinct runs, one per result category; failed percentage is 1/4 only under an explicitly all-completed denominator policy and full coverage |
| Company collision | Repeat identical project/definition/run IDs under B | Four A runs and four B runs, no cross-company joins/counts; no unapproved portfolio visibility |
| Duplicate/overlap | Replay page 1 and repeat the fixed window | Still four distinct A runs, not six/eight; unchanged facts/work deduplicated |
| Interrupted collection | Fail after persisted page/work but before progress; separately after progress but before processing | Durable retry/work resumes, incomplete collection visible, no early completed checkpoint |
| Slow stale worker | First lease expires during read; second owner advances | Old worker cannot overwrite newer progress; no DB lock held during HTTP |
| Old queued run | 101 queued `2024-12-31T23:00:00Z`, finished `2025-01-01T00:10:00Z` | Found by finish-time collection or active reconciliation; not lost to queue-time bounds |
| Revised outcome | Later comparable snapshot changes 101 from failed to succeeded | Current result updated without deleting history or adding another distinct run; reconciliation beyond overlap tested |
| Successful throttling | Page 1 HTTP 200, continuation and `Retry-After: 3` | Persist page once; next request at/after allowed time under fake clock; do not retry success solely for the header |
| Error throttling/outage | 429/503, timeout, malformed response or unavailable credentials | Bounded backoff/jitter/work; visible error/partial coverage; no checkpoint advance or credential leak |
| Pagination/size limits | Repeated/oversized token, capped work, oversized body or unexpected scope | Reject/quarantine or pause with explicit limitation, never infer completion; tokens cannot become URLs |
| Empty versus unavailable | Successful fully covered empty window versus failed/unconfigured collection | Zero runs only for covered empty window; rate with zero denominator unavailable; missing data is unknown |
| Partial/unknown results | Only page 1 retained, or unknown enum returned | Coverage-qualified counts, no silently complete denominator; retain unknown rather than recoding as success |
| Malicious redirects/links | Off-origin redirect, payload URL, path/query injection or forged company | No arbitrary fetch, credential forwarding, scope override, source mutation or notification |

Stub envelopes must include explicit response status, sanitized headers, body and completeness expectations. The exact provider response shape and continuation extraction must be checked against the selected API before writing adapter contract tests; these scenarios are not vendor payload samples. Failed/succeeded/canceled/partiallySucceeded are proposed Build categories for test design, not measurements from a pilot.

## Task 003: later evidence cases in the same set
Define a failed parent/job with a failed leaf task and two attempts: preserve hierarchy/attempt IDs, one failed-run identity, distinct task attempts. Include structured 401 versus 403 issues, a generic exit code (unclassified), delayed/deleted/truncated logs, multiline/oversized lines and fake-secret canaries. Bounded log reads must retain line/provenance references and missing-evidence reasons. One fail/pass sequence is recovered-after-retry history, not proof of flakiness. These fixtures and tests are not implemented in discovery.

## Approval and use gate
Independent review must accept this synthetic fixture definition before implementation relies on it. It does not authorize external requests or make an `.invalid` origin an egress exception. Live source scope and any captured fixture sanitization require separate owner approval under [SOURCE_ACCESS.md](SOURCE_ACCESS.md). No fixture, passing local test or public documentation lookup establishes live integration success.
