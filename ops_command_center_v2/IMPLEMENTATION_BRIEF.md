# Ops Brain v2 — implementation brief

Status: a proposed design. Targets, intervals, thresholds, table names, and examples are engineering proposals, not measurements or installed configuration.

## 1. Product definition
Build an internal operations command center across explicitly authorized companies, projects, services, and development/staging/production environments. It supplements the existing stack and runs ordinary scheduled/event-driven code without AI.

It answers four questions:
- What is currently failing or showing a sustained risk?
- How many distinct failures are occurring, where, and with which shared signatures?
- What evidence supports a candidate explanation or a common dependency problem?
- What evidence is missing, stale, truncated, or inaccessible?

It does not promise a diagnosis for every error. Unknown is a legitimate result. It must not present all systems as monitored merely because an Azure DevOps organization or Grafana instance has been added.

## 2. Scope and permanent exclusions
Observe external systems; write only application state. Reading logs, checking metrics, retrieving run outcomes, maintaining a resource watch, and calculating a forecast are allowed. Changing deployments, rerunning/canceling pipelines, executing commands in pods, altering databases, modifying Grafana dashboards/rules/annotations, silencing source alerts, or creating source work items are excluded.

Local acknowledgment/assignment/snoozing affects only this application's notice, never upstream paging. External messages require a separate, explicitly approved notification sink with minimal permission. The application remains fully functional with dashboard-only notifications.

No runtime LLM, model, inference server, embedding, AI agent, or AI API. No requirement for paid AI-powered monitoring features. Development agents may help implement the application, but their tooling and cost are outside the runtime architecture.

No-AI does not mean zero infrastructure cost. Budget the web/worker process, PostgreSQL, storage, source query load, network traffic, and any applicable platform licensing/query charges. Azure Monitor table plans can affect query charging. [S17]

## 3. Architecture
Use a modular Phoenix application, Ecto/PostgreSQL, Oban, and LiveView. PostgreSQL is the durable source of truth for selected observations, run snapshots, findings, evidence, and checkpoints. Oban can participate in Ecto transactions. [S12]

```text
Authorized Azure DevOps projects -- periodic result/timeline/log reads --Prometheus endpoints ------------ bounded metric queries --------------|
Actual log backends ------------- aggregate counts + scoped samples ---|--> durable collection
Kubernetes APIs ----------------- list/watch/reconcile ----------------|    + normalization
Existing optional alert feeds --- authenticated inbound events -------/             |
                                                                                    v
                                                                         identity resolution
                                                                                    |
                                                                         detectors + grouping
                                                                                    |
                                                                         evidence correlations
                                                                                    |
                                                              saved notices + LiveView command center
                                                                                    |
                                                              optional approved message delivery
```

Start with a single application deployment and PostgreSQL. Do not introduce per-service actors, distributed Erlang, brokers, or a separate telemetry warehouse just to look scalable. Long-lived watchers are supervised runtime processes; short collection jobs are durable work. Kubernetes watches need reconnect, expired-resource-version relist, and visible coverage-gap handling; their limited history is not an eternal event journal. [S15]

At larger scale, web and workers may use the same image with separate roles. Before multiple collector replicas, implement one active lease per source/scope, fencing or equivalent stale-worker protection, cross-instance notification delivery, and idempotent persistence. An Oban concurrency setting alone is not multi-company fairness or an upstream rate limiter.

If companies cannot share a network or trust boundary, deploy company-local read-only collectors that send sanitized observations to a central receiver. This is a later topology decision, not a prerequisite for the first pilot. Such collectors receive no remote command-execution channel.

## 4. Company, environment, and service identity
Treat internal company identity separately from Azure DevOps organization, Entra tenant, Azure subscription, Grafana organization, Loki tenant, and Kubernetes cluster. These are different namespaces and cannot be assumed one-to-one.

Minimum service-instance identity:
`company + stable service + environment + runtime source/cluster + namespace or other target`.

An Azure pipeline run may have no deployment target or may deploy into several environments. Model runs independently from deployment attempts; assign an environment only from an explicit stage/target mapping and source evidence. Do not label every failed CI run as a production incident.

Make all operational rows company-scoped, with composite relationship constraints preventing cross-company references. Source identity is assigned from authenticated configuration, not trusted payload fields. Unknown service/environment mappings go into a visible unresolved queue.

The portfolio view only aggregates companies the signed-in person may access. Drilldowns, exports, caches, PubSub topics, worker jobs, and notification recipient lists use the same authorization boundary. Identical names and fingerprints in different companies must not merge by default.

For the shared-database internal deployment, implement application-scoped query APIs and tested PostgreSQL row-level security on operational data before connecting a second real company. The runtime role must not own protected tables or have BYPASSRLS; pooled connections need transaction-local scope that resets reliably. RLS does not replace application authorization or isolate a compromised superuser. [S14]

Keep globally scheduled work metadata minimal. Resolve each source job into an authorized company-scoped data transaction; never expose the global queue's arguments/errors through ordinary operator pages. For unrelated customers requiring hard isolation, approve separate database/deployment boundaries before onboarding instead of marketing a shared database as equivalent isolation.

## 5. Data model, created incrementally
- Companies and memberships: authorization scope and allowed portfolio access.
- Environments and service instances: dev/staging/prod plus actual target identity.
- Source instances and access profiles: endpoint, company, approved read operations, credential reference, budgets, health.
- Collection runs/pages/checkpoints: bounded query scope, schedule, lease, durable progress, completeness, gaps.
- Observations: normalized facts, source keys, schema version, occurrence/receipt time, provenance.
- Pipeline runs: project/definition/run identity, branch, commit, status/result, observed revisions.
- Pipeline task attempts: timeline record and attempt identity, hierarchy, result, sanitized issue and log references.
- Failure occurrences: a classified failed operation and evidence, independent of line count.
- Error fingerprints: versioned templates and semantic attributes used to recognize repetition.
- Log windows: fixed aggregation interval, selectors/profile version, backend count, sample coverage, revisions.
- Deployment attempts and workload observations: reported versus runtime-observed state.
- Alert episodes: source fingerprint plus activation identity, transitions, resolution.
- Detector evaluations: input snapshot, version, result, freshness, missing inputs.
- Findings/issue groups: internal episode, severity, grouping reason, lifecycle, evidence links.
- Evidence items: bounded redacted snippets, metric snapshots, line/time references and expiry.
- Reviews/acknowledgments: local operator decisions separate from source facts.
- Notification outbox/delivery: group/revision/destination idempotency keys and attempts.

Use typed identifiers/timestamps for access paths; bounded JSONB for source-specific attributes. Do not store all source payloads indefinitely or generate this entire schema in the first task.

## 6. Durable collection and lifecycle
Polling flow:
`claim bounded collection -> read page -> sanitize -> transaction(store page facts + work) -> persist page progress -> next page -> mark covered window complete`.

Never advance the completed window checkpoint after only the first page. An incomplete collection is visible and resumes; duplicated pages do not duplicate facts. On restart, catch up with a bounded backlog rather than flooding sources.

Webhook flow, when explicitly enabled:
`authenticate exact bytes -> validate/bound -> sanitize -> transaction(inbox + job) -> acknowledge`.

Source read success is not proof of complete data. Store returned truncation/errors, unavailable logs, retention gaps, and partial results. Define provider-specific retry behavior, backoff, jitter, quotas, and maximum work per tick. Azure DevOps documents throttling hints including Retry-After on successful responses. Respect them before the next request; do not repeat a successful request solely because that header exists. [S4]

Never hold a database transaction/row lock while waiting for an external HTTP response. Collection leases and fencing must permit slow or failed requests without stale workers overwriting newer checkpoints.

Observations should be append-only facts where feasible. Mutable source results are versioned snapshots or reconciled projections, not immutable events with silent overwrites. A run with another attempt may need its previously observed final status refreshed.

## 7. Azure DevOps integration — pipeline health first
Use the Build REST APIs for selected YAML/build runs. The documented list operation supports time/order/status filtering and continuation tokens. Timeline records expose hierarchy, attempts, results, issue details, and log references. Individual logs support start/end-line bounds. [S1, S2, S3]

Start with periodic outbound reads: no browser automation, service hook, pipeline step, extension, or build-agent execution is required. A source administrator configures a read-only identity. Managed identities/service principals require explicit Azure DevOps membership and its own project/resource permissions; Azure subscription Reader alone is not sufficient. Do not assume one identity works across unrelated Entra tenants. [S5]

### Collection contract
1. Resolve approved projects and pipeline definitions from configuration/read-only discovery. Do not crawl every accessible organization automatically.
2. Select a fixed upper time boundary per completed-run collection and an overlapping lower boundary. Use finish-time ordering when using completion-time bounds. Paginate until the selected window is accounted for.
3. Collect all completed result categories when computing counts/rates. A failed-only view can be derived locally; it cannot supply its own total-run denominator.
4. Maintain and refresh a set of known active/queued runs separately. A run queued yesterday that finishes now must not be missed. Periodically reconcile recent run IDs/attempts because reruns can change observed outcomes beyond a small overlap.
5. Fetch timelines for runs requiring failure analysis. Read failed leaf operations and attempt hierarchy; a failed parent and failed child do not represent two failed runs.
6. Prefer structured timeline issues and result codes. Fetch only bounded relevant log sections when more context is needed. Logs may be absent, delayed, retained elsewhere, or deleted; retry boundedly and label unavailable evidence.
7. Sanitize, classify, fingerprint, and persist occurrences with references back to source runs/steps.
8. Maintain separate failed-run counts, failed-task counts, retry counts, pipeline-definition counts, and signature counts. Do not add these together.

Classic release pipelines use a separate adapter and permission review. Until implemented, the coverage page must say they are unsupported; never call Build API coverage 'all pipeline types'.

### Deterministic classification
Begin with a small reviewed catalog: explicit compiler/tool error codes, structured test failures, authentication rejection, authorization denial, DNS resolution, connection timeout/refusal, dependency restore, disk space, and agent/job abandonment.

An HTTP 401 is evidence of an authentication rejection, not proof of which credential expired. A generic exit code is not a full explanation. Preserve `unclassified` with the best sanitized evidence instead of guessing.

Structured test-result reads are a separate optional read scope. Claims about flaky tests require repeated comparable attempts and test identity; one fail/pass sequence is not proof. Distinguish recovered-after-retry history from current run outcome and runtime service health.

## 8. Error fingerprints and issue grouping
A fingerprint recognizes similar occurrences; an issue group is a time-bounded operational episode. They must not be the same table/key.

Pipeline example fields:
`company + task/tool kind + error code/class + dependency host/resource identity + normalized message + parser version`.

Log fingerprint fields are service/source-specific and include exception type, selected relevant stack frames, stable message template, and semantic error codes. Keep tenant/service scope in the grouping key even when templates are shared.

Normalize clearly volatile request IDs, timestamps, safe path prefixes, pod suffixes, and line offsets. Preserve useful discriminators: HTTP 401 versus 403/404, SQLSTATE, tool error codes, dependency hostname, package names, and target resources. Redaction and normalization are distinct; do not retain sensitive values solely to improve grouping.

First implement exact matches of normalized templates. A later bounded string-similarity matcher can suggest nearby groups but must not silently merge them. Store why records matched and permit local split/review. A parser-version change requires explicit reprocessing, not silently changing old group counts.

Group across several pipelines in one company only when a meaningful shared fingerprint/dependency supports it. Cross-environment similarities may be shown as linked evidence with separate environment impacts; do not merge away production versus development scope. Cross-company grouping is disabled by default.

A group stores first/last seen, distinct run/service/attempt counts, occurrence count basis, affected environments, sample evidence, owner, local status, and notification revision. A quiet period alone does not prove recovery; show `quiet` or `not recently observed` unless successful comparable activity/fresh healthy measurements support recovery.

## 9. Grafana, log backends, and metrics
Grafana is the visualization/data-source integration layer, not necessarily where logs are stored. Connect to the actual backend configured for each source—Loki, Azure Monitor, Elasticsearch, or another approved system. Implement one real backend first. A Grafana login or token does not automatically grant direct backend access. [S6]

### Log observation pipeline
Prefer bounded aggregate-first collection:
1. For approved service/environment selectors, query error/critical counts or rates over fixed windows.
2. Compare with a minimum count, sustained threshold, and service baseline/traffic where available.
3. On a breach or a limited discovery sample, retrieve bounded contextual log entries.
4. Parse producer-specific structured levels and exception blocks, redact, fingerprint, and attach representative evidence.
5. Update one issue group rather than producing a notification per line.

Loki has range query APIs and LogQL count/rate functions. Use these to obtain backend counts rather than claiming the number of downloaded lines is the total error count. [S7, S8]

If total critical count is 4,000 but only 200 entries are sampled, exact counts per discovered fingerprint are unknown unless separately counted with validated backend predicates. Label groups `observed in sample` or lower-bound counts. Some backends have no universally stable per-log ID; do not deduplicate legitimate identical entries merely by message hash. Use fixed window revisions for authoritative counts, and keep sample identity/multiplicity separate.

Use overlap/late-window reconciliation to account for delayed ingestion. Never sum rolling five-minute counts sampled every minute. A saturated timestamp, page/result cap, parse failure, or skipped range becomes a visible coverage limitation.

An ERROR/CRITICAL label is a producer's severity, not proof of customer impact. Check context, rate, volume, service criticality, multiple replicas, known benign signatures, and correlated symptoms. A single severe data-integrity/storage error may justify immediate notice; not every detector requires a burst.

Existing access/query policies matter. Loki's tenant header is not itself authentication; use a trusted authenticated gateway and source-bound tenant configuration. [S18]

### Metrics
Reuse existing Prometheus/compatible queries and recording rules. Query bounded instant/range profiles rather than copy all samples. Profile validation checks real metric names, labels, units, counter/gauge semantics, sampling and exporter availability. [S9]

Configure profiles for NGINX/ingress/controller implementations actually installed; do not assume one vendor/controller metric schema works for all. Prefer actual 5xx rate divided by matching request volume, with a minimum traffic condition. Do not average per-pod percentages or latency quantiles into a fictitious fleet percentile.

Database checks start with existing exporter/cloud metrics, not application table reads or broad database credentials. Separate logical database size, allocated storage, effective free space, maximum quota, auto-growth behavior, and filesystem headroom. Missing one necessary signal disables that forecast rather than inventing it.

## 10. Detectors and evidence-backed diagnosis
Each detector declares required inputs, scope, input freshness, minimum sample/traffic coverage, evaluation interval, version, thresholds, persistence period, clear condition, grouping key, severity logic, and explanation template.

Keep current observation status separate from evidence availability and connector status. Suggested states:
- Condition: normal / watch / warning / critical / unknown / not applicable.
- Coverage: complete for configured window / partial / stale / disabled / not configured.
- Issue: new / active / locally acknowledged / quiet / recovered / closed by reviewer.

Do not translate no-data into zero. Dev/staging/prod use independently configurable evaluation/routing policies; collecting dev does not require paging as loudly as prod. Shared production-serving resources can be operationally important regardless of their own label.

Correlation requires explicit identity/topology and temporal evidence. Link shared dependencies only when documented mappings or observed relationships exist. Temporal proximity suggests an investigation candidate, not causal proof. Keep alternatives and counterevidence.

Template output contains: observed facts, known failure mechanism, candidate contributing change/dependency, missing evidence, and an approved runbook/source link. Do not execute runbooks. Every sentence asserting a source fact should trace to an evidence record.

A deterministic diagnostic tree for ingress errors might check controller status, ready service backends, recent workload changes, restarts, upstream latency, and an explicitly mapped database's connection pressure. It can report `upstream timeouts coincided with exhausted database connections`; it cannot declare the database caused the outage solely from that coincidence.

## 11. Early warnings without AI
Implement trend and threshold methods before advanced baselines. Prometheus provides gauge-based linear prediction and rate/absence functions; these are statistical/metric primitives, not an AI-credit dependency. [S10]

Capacity estimate:
`time_to_threshold = (effective_threshold - current_usage) / sustained_positive_growth_rate`.

Require adequate, recent samples; meaningful positive growth; a stable operating segment; and consistent units/series identity. Suppress or qualify forecasts across capacity changes, restarts, garbage-collection cycles, planned retention jobs, and unknown auto-growth limits. Do not divide by zero/negative growth and manufacture a deadline.

Output a conditional threshold estimate, not an exact outage time. A hypothetical 80 GB of effective headroom at a sustained 5 GB/hour implies about 16 hours to exhaustion only while those assumptions hold. Memory headroom can trigger warning, but a straight line does not establish an exact future OOM time.

Useful first predictions include storage headroom, known certificate expiry from existing telemetry, growing queue backlog, and sustained connection saturation. Arbitrary incident prediction is not a promised capability. Historical evaluation must use only evidence known at the simulated evaluation time.

## 12. Notification policy and main page
The homepage prioritizes company/environment impact, active incidents, repeated pipeline failures, capacity risks, and coverage gaps. Suggested top-level areas: Overview, Pipelines, Services, Investigations, Capacity, Sources.

Show a company-by-environment matrix with distinct operational and freshness states. Unsupported checks remain explicitly unconfigured. Failed CI runs have a delivery-health area; they do not automatically make production service health red.

An issue card includes scope, severity reason, first/last seen, distinct affected entities, selected time window, count basis, evidence, candidate explanation, missing evidence, owner, and source links. Timeline views use occurred and received timestamps.

Use local durable notices by default. External delivery is off until a company approves a recipient/channel and sink credentials. Implement deduplication by issue + revision + destination, coalescing, cooldown, escalation, recovery, and quiet-hours policy. Critical policy may bypass digest delay. Do not allow source text to choose recipients or URLs.

Reuse upstream paging for its existing responsibility. Alertmanager already supports grouping/inhibition/deduplication; the added value is cross-source context and coverage, not claiming those features were absent. [S16]

The outbox gives durable retry but does not guarantee exactly-once delivery to a provider without idempotency support. Record ambiguous delivery outcomes and prefer stable message IDs/updates when supported. A replay must never send notifications.

## 13. Security, cost, and operational safety
Source permission matrix is in SOURCE_ACCESS.md. Read-only permission does not mean zero impact: log queries can be expensive and broad metadata/log reads can expose secrets.

Apply authenticated user access and all LiveView lifecycle authorization checks. [S13] Bind identities to source scopes. Prevent SSRF/query injection and credential forwarding on redirects. Use a reviewed egress allowlist including required identity endpoints; AI endpoints are not allowed. Review dependencies for unexpected network behavior.

Separate CI deployment identity, database migration identity, runtime database role, observation credentials, and notification credentials. Restrict worker resources so a log burst or one noisy company does not starve other companies or the UI.

Default workload is configurable, staggered collection. Proposed starting intervals: pipeline changes 60–120 seconds, active metric checks 30–60 seconds where sampling supports it, log aggregation 60–120 seconds for chosen production profiles and slower for low-priority sources, capacity evaluation about 5 minutes, inventory around 15–60 minutes. These are tunable pilot defaults, not throughput promises; budgets may require slower rates.

Per source/company enforce requests/minute, bytes/time range, pages/tick, concurrency, catch-up budget, retention, and maximum queued work. Keep expensive enrichment behind lightweight detection. Expose query volume and bytes examined when supplied by the source.

Persist bounded examples, references, metric windows and detector outputs—not every raw log line. Set retention per sensitivity and value. Expired evidence makes exact replay unavailable; record that rather than claiming eternal reproducibility.

Monitor the command center using the existing monitoring system: ingestion errors, job age, source lag, freshness, unresolved mappings, rate-limit responses, dropped/quarantined work, database growth, and notification failures. Existing operations continue if this app is stopped. Hosting it only inside the monitored failure domain reduces availability during cluster outages; approve a separate management location before claiming a resilient company-wide command center.

## 14. Readiness gates
Every feature must pass fixtures/unit tests, real PostgreSQL behavior tests where relevant, source-contract tests, and explicit live validation when access is available. ROADMAP.md defines the order; ACCEPTANCE_TESTS.md defines adversarial scenarios.

Before the second real company: authorization and cross-company tests pass. Before production read access: source permission and query-budget reviews pass. Before external notifications: grouping/cooldown/delivery tests and recipient approval pass. Before forecasts: demonstrate required data and backtest warning usefulness/false warnings without future data.

Do not report implementation completion from this document alone. Agent progress reports must name actual tests, remaining gaps, and the single next task.
