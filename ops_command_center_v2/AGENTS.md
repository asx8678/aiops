# Agent working agreement — Constellation

## Mission and authority
Build the currently assigned slice of a supplementary, read-only, no-AI operations command center. Preserve the existing repository and its conventions. This brief provides direction, not authorization to implement every layer or touch live infrastructure.

Read IMPLEMENTATION_BRIEF.md, SOURCE_ACCESS.md, and the assigned task first. Identify any earlier instructions that conflict with this v2 specification. Do not silently retain future remediation or runtime LLM functionality from the old plan.

No live production writes, cloud provisioning, source-hook creation, notification-route changes, pipeline edits, broad credential creation, production fault injection, or deployment without explicit human authorization. Never probe read-only safety by attempting a write to production: validate policies and use controlled test resources under a separately authorized test plan.

## Permanent product constraints
1. Observation adapters expose only approved read operations. No trigger, rerun, cancel, patch, exec, restart, rollback, scale, silence, annotation-write, ticket-write, or source administration methods.
2. No runtime models, embeddings, agent loops, provider SDKs for AI, or AI credit dependency. No hidden AI fallback. Explanations are structured templates over stored evidence.
3. Writes are confined to the application's database and explicitly authorized notification sinks. The notification role never receives source mutation permission.
4. Source administrators perform necessary one-time setup. The runtime application must not grant itself access or install exporters.
5. Every operational record, query, job, cache entry, UI subscription, and notification is bound to an authenticated company/source scope.
6. No missing telemetry, disconnected source, or unconfigured detector is displayed as healthy.

## Architecture
One Phoenix application; Ecto/PostgreSQL for durable state; Oban for jobs; LiveView for UI. Use ordinary modules and pure functions for business rules. Use processes for actual runtime work such as watches—not each noun in the domain.

Do not add Kafka, Redis, ClickHouse, graph databases, Rust services, microservices, or a generic rule DSL without a measured bottleneck and approved decision. Do not require paid library extensions for basic scheduling or ingestion. Check dependency APIs against the selected, locked versions.

Adapters translate transport and source semantics. Workers coordinate bounded operations. Domain functions receive explicit input, policy versions, evidence, and time. UI code presents persisted domain results rather than recalculating different conclusions.

## Correctness
- Persist accepted input and its processing work before acknowledging or advancing the completed collection checkpoint.
- Checkpoints advance only after all relevant pages/chunks are durably accounted for. Resume partial work and expose collection gaps.
- Separate delivery IDs, immutable observations, mutable source-run snapshots, alert episodes, failure occurrences, fingerprints, and issue groups.
- Use database constraints and idempotent upserts. Oban uniqueness is not a substitute for domain uniqueness or collection ownership.
- Preserve run, timeline record, job/stage, and attempt identities. A retried step is not another pipeline run.
- Fetch broad completed results when computing failure-rate denominators; failed-only retrieval cannot establish a total-run denominator.
- Keep canceled, partially successful, failed, and successful results separate. Unknown environment is not production.
- Store source occurrence, collection, receipt, and evaluation time distinctly. Inject clocks in tests.
- A same-text error group is not a confirmed shared root cause. Facts, symptoms, candidate explanations, counterevidence, and human review remain separate.
- Fixed, overlapping observation windows must not double-count log occurrences or rates. Never sum overlapping rolling-window counts into a total.
- Counts derived from samples or truncated retrieval must be labeled as such. Preserve legitimate repeated identical log entries.
- Reprocessing uses stored versions. Replay performs no network queries or notification delivery and cannot overwrite human review.

## Security and limits
Use approved source endpoints and query profiles. Never accept arbitrary URLs, tenant headers, cloud resource scopes, PromQL/LogQL, executable code, or shell commands from incoming data. Validate redirects and block unapproved egress.

Read-only is about API semantics, not HTTP verb alone: an allowlisted query POST or token exchange can be permitted; a mutation must not be. Incoming POST receivers do not grant outbound write authority.

Credentials are separate per trust boundary and preferably per company/source/environment. Never store them in event payloads, fixtures, logs, job arguments, UI messages, or export files.

Parse structured errors first. Bound bytes, lines, multiline length, regex complexity, pages, time range, concurrency, retries, and storage. Redact before persistence and display. Source masking is not proof that logs contain no secrets.

Authorize HTTP, LiveView mount/reconnect/navigation/events, exports, and source links. Topic names include company identity. Subscription authorization is checked before subscribing. User-supplied company IDs are never authority.

Provider and database permissions, an operation allowlist, negative tests, and egress restrictions provide layered controls; none alone justifies claiming perfect security.

## Working loop
Before code: inspect relevant files and dependency locks; restate the single behavior, non-goals, acceptance tests, security boundary, and failure cases. Split independent changes into separate tasks. Do not create all future tables or placeholder modules.

Write tests that enforce behavior rather than mirror the implementation. Use real PostgreSQL for uniqueness, locking, tenant isolation, and RLS tests. Use sanitized, labeled fixtures and HTTP-boundary stubs for sources. Never ship mocks or fabricated healthy states in production paths.

Run the assigned checks and relevant regressions. Never delete tests, weaken assertions, swallow exceptions, or claim unrun tests passed. A reviewer inspects the diff and attempts adversarial cases independently.

One agent owns shared schema/core interfaces at a time. Parallel work must not overlap migrations or files. Do not auto-merge or auto-advance.

## Completion report
State the behavior delivered; files/interfaces/migrations changed; commands actually run and outcomes; acceptance tests proven; tests not run and why; live contract verification still pending; data sensitivity; limits; disable and recovery procedure; known limitations. Suggest the next task without implementing it.

Do not claim production readiness, calibrated prediction, benchmark results, perfect delivery, or live integration success without matching evidence.
