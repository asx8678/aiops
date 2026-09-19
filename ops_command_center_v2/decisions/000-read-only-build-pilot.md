# ADR 000 — Read-only, no-AI runtime and first Build API pilot

Status: proposed implementation decision, awaiting independent review and source-owner approval. The read-only/no-AI constraints are binding requirements, not optional proposals. No live source has been selected or accessed.

Related: [current state](../CURRENT_STATE.md), [source access](../SOURCE_ACCESS.md), [fixture contract](../FIXTURE_CONTRACT.md), [task 000](../tasks/000-discovery.md).

## Context and reconciliation
The repository contains a specification pack, not an existing application. There are no tracked v1 modules to remove or migrate. The following earlier assumptions, if encountered later, are superseded by v2:

| Rejected assumption | Required replacement |
|---|---|
| One company/provider organization is the tenant | Internal company identity plus explicit provider namespace mappings |
| Pipeline deployment reporter is required | Outbound polling of approved Build scopes; no pipeline changes |
| Later AI explanation or autonomous remediation | Deterministic evidence templates; permanently no runtime AI or source mutation |
| Broad administrator credentials are acceptable | Separate least-privilege observation, migration, runtime, CI and optional delivery identities |
| Missing or unconfigured monitoring is healthy | Separate condition, coverage and connector status; unknown stays unknown |
| Failed CI means production is down | Delivery health independent of deployment attempts/runtime target evidence |

## Decision and consequences
Use one modular Phoenix/LiveView application with Ecto/PostgreSQL and Oban. Choose and lock compatible versions in task 001 after review; no dependency version is asserted here. PostgreSQL is the durable source of truth. Avoid a second telemetry warehouse, per-service actors and new brokers.

Adapters expose approved read operations only, never a generic arbitrary-URL client to operators or source payloads. Runtime AI libraries, model services, embeddings and AI egress are excluded. Local acknowledgment changes only application state. External delivery is off until separately approved and uses a distinct credential. Existing monitoring, deployments and paging must work with Ops Brain stopped.

Application-scoped query APIs and composite company relationships begin with task 001. Transaction-local scope must be reset on success, rollback and connection reuse. Tested PostgreSQL RLS with a non-owner, non-BYPASSRLS runtime role is mandatory before the second real company; application authorization is still required. No unauthenticated production bypass may substitute for pending SSO setup.

## First source: proposed scope, not an installed configuration
| Field | Known state / required owner decision |
|---|---|
| Real internal company and owner | Not supplied; must explicitly approve the pilot |
| Installation | Unknown: Azure DevOps Services or Server and installed version |
| Pipeline kind | Propose selected Build/YAML definitions; actual kind unconfirmed |
| Organization/collection, project ID, definition IDs | Not supplied; no organization-wide crawling |
| Environment/target mapping | None; runs remain CI-only/unresolved until explicit evidence maps targets |
| Identity and secret reference | None supplied; owner-managed build-read identity only |
| Network and limits | Exact source/identity endpoints, query/page/byte/time/concurrency/backlog budgets and retention await approval |
| Classic releases | Unsupported; separate adapter and permission review required |
| Optional test/artifact scope | Disabled; not part of the first pilot |

A company-approved Entra nonhuman identity is preferred where supported. It needs explicit Azure DevOps membership and project/resource permissions; Azure subscription Reader is not enough. Services guidance cannot establish Server authentication compatibility. Tenant boundaries require separate review. A short-lived, narrowly scoped PAT is an exception only with owner approval, rotation and secure storage. Do not create any identity or request administrator tokens in this task.

## Planned collection path and operation boundary
For the Services-shaped candidate API, the first operation family is:

- `GET /{organization}/{project}/_apis/build/builds?api-version=7.1`: list selected definitions with a fixed `maxTime`, overlapping `minTime`, `statusFilter=completed`, `queryOrder=finishTimeAscending`, bounded `$top` and opaque `continuationToken`. Omit `resultFilter` when establishing counts/rate denominators. API 7.1 is a documentation baseline, not an installed-version assertion.
- Refresh known active/queued and recent run IDs through selected-scope Build reads, independently of the completed window. Verify exact read-by-ID operation/version before task 002 ships.
- Task 003 later adds timeline and bounded individual-log reads. These are not implemented or live validated by this record. No release, queue, cancel, rerun, definition-write or source administration operation is allowed.

Execution path: claim a bounded company/source collection lease -> read an approved page outside a database transaction -> validate scope/size and sanitize -> transactionally persist page facts, snapshot revisions and follow-up work -> record page progress -> continue under budget -> advance the completed-window checkpoint only when every relevant page is durable. Idempotency keys include company/source/project/run identity; a repeated page is not another run. A stale lease holder cannot advance progress over a newer worker.

A page failure retains durable progress and partial coverage. Retry with bounded provider-aware backoff/jitter; a successful response with `Retry-After` is persisted once and delays the next request rather than repeating success. Distinct result categories remain separate. Unknown/malformed results and incomplete coverage must qualify any denominator. Reconciliation must preserve changing attempts/history and runs queued before the window that finish inside it. No database lock spans external HTTP.

Endpoint/project/definition identity comes from authenticated configuration, not source text. Validate path segments, returned identities, response bounds and continuation-token limits. Follow no arbitrary payload links or redirects; never forward credentials to unapproved hosts. Require reviewed egress including identity endpoints; deny AI endpoints. Store minimal selected fields, redacted evidence and references, not credentials or indefinite raw payloads. Numeric query budgets are unset and collection remains disabled until approved.

## Public-document contract evidence
Public Microsoft pages were retrieved without credentials using bounded HTTPS `curl` requests. These checks do not contact an organization's Build API or prove installed compatibility.

- [Build list, REST 7.1](https://learn.microsoft.com/en-us/rest/api/azure/devops/build/builds/list?view=azure-devops-rest-7.1): GET list signature includes definition/status/result filters, `minTime`, `maxTime`, `$top`, `continuationToken` and `queryOrder`. The descriptions bind time filtering to the selected ordering and define `finishTimeAscending`/`finishTimeDescending`. Continuation tokens request the next set. The page documents `vso.build`; that scope name is not a substitute for selecting current authentication guidance.
- [Rate limits](https://learn.microsoft.com/en-us/azure/devops/integrate/concepts/rate-limits?view=azure-devops): `Retry-After` delays the next request even with HTTP 200; no retry of the successful request is required.
- [Service principal/managed identity guidance](https://learn.microsoft.com/en-us/azure/devops/integrate/get-started/authentication/service-principal-managed-identity?view=azure-devops): identities require explicit organization addition and granular Azure DevOps permissions. Tenant restrictions need review.

Still unverified: real installation/API/auth compatibility, continuation response extraction and termination behavior, time-bound edge behavior, actual response enums/fields, rate-limit headers, inherited source permissions, retention, network path, workload and cost. Task 002 must use HTTP-boundary fixtures and separately approved live validation, not infer these from a successful documentation fetch.

## Approval and live validation gate
1. Owner supplies the non-secret scope fields above and approves least-privilege permissions, egress, budgets and retention. Inspect policies; do not attempt production writes as a test.
2. After reviewed task 001, build task 002 against the [synthetic fixture contract](../FIXTURE_CONTRACT.md). No fake success or fabricated health in runtime paths.
3. With explicit read authorization, perform a small bounded pilot read and record requested scope, actual capabilities, pagination completeness, returned limitations and count semantics. Do not download logs in the initial metadata-only read.
4. Review redacted evidence and coverage before any production expansion. If authorization, limits or version compatibility are missing, stay disabled and report pending.

## Rejected alternatives / limits
No mandatory service hook, browser automation, pipeline extension or agent execution is needed. No all-company crawl, all-table scaffold, automated remediation, runtime LLM or speculative diagnosis. Public documentation and synthetic scenarios do not prove live source integration, tenant isolation, performance or production readiness.

Next code change is solely [task 001](../tasks/001-tenancy-foundation.md), after independent discovery review. This decision creates no runtime process or source configuration; disabling/reverting it requires only revising/removing the new discovery documents.
