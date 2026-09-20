# Required acceptance scenarios

Status: test requirements, not executed test results. Use real PostgreSQL for database behavior; fixtures and controlled HTTP servers for source contracts. Live validation is separately authorized. No production fault injection or mutation tests.

## Company/environment isolation
- Same service, pipeline ID and fingerprint exist in two companies: no cross-company joins, cache collisions, topics or notices.
- User authorized for company A cannot read B via direct object URL, export, search, LiveView reconnect/action or guessed source ID.
- An authenticated company-A source cannot submit company-B observations by modifying JSON or headers.
- A queued job cannot process an unrelated company's record by changing a record ID; relationships have company constraints.
- A reused database connection does not retain prior tenant context; absent scope denies data access.
- Portfolio aggregation includes only authorized companies; group counts do not leak others' existence.
- Development deployment plus production symptom does not correlate merely because names match.
- One pipeline with dev/staging/prod stages preserves each target and attempt; CI-only runs remain unmapped to runtime health.

## Read-only/no-AI contract
- Source adapter interfaces and network operation allowlists contain no mutation/remediation functions.
- Approved test identities demonstrate least privilege; production is not used for write attempts.
- Incoming text/URL cannot become shell execution, arbitrary fetch, query template, tenant override or notification destination.
- Runtime works with AI credentials absent and AI egress denied; dependency/network review finds no model calls.
- Local acknowledgment does not call upstream alert/silence APIs or modify a source.
- Notification identity cannot act as the observation/deployment identity.
- Stopping Constellation leaves existing deployment, scrape, alert evaluation and paging paths unchanged.

## Azure DevOps collection
- More than one result page is returned; all pages are persisted before complete-window checkpoint.
- Crash after page persistence but before checkpoint update produces idempotent recovery.
- Crash after checkpoint page progress but before domain processing resumes durable jobs correctly.
- Fixed-window polling with overlap does not duplicate run counts.
- Run queued before lower collection bound but finishing now is found using completion semantics or active-run reconciliation.
- Active/queued states transition correctly; subsequent attempts/reruns revise projections without erasing observed history.
- API throttling/Retry-After, including on 200 responses, delays next work appropriately without falsely reprocessing success.
- Failed, successful, canceled and partially successful results remain separate.
- Failure percentage is unavailable or qualified when denominator/history coverage is incomplete.
- Failed parent/job/task records do not become three failed pipeline runs.
- Multiple failed tasks in one run can contribute multiple signature memberships without claiming their sum equals failed runs.
- Logs absent, truncated, redacted, delayed or expired produce honest evidence status.
- A successful build is not recorded as a production deployment without target evidence.

## Error normalization
- Same semantic error with different timestamps/request IDs groups consistently.
- HTTP 401 and 403, distinct SQLSTATE/tool codes, and different dependency hosts remain distinguishable.
- Redacted secrets do not appear in fingerprints, titles, evidence, notification payloads, jobs or telemetry.
- Generic exit-code failures remain unclassified unless another observation supports a mechanism.
- Multiline exceptions, ANSI output, malformed encoding and oversized lines are bounded safely.
- Normalizer-version change triggers explicit revision/reprocessing rather than silently rewriting past grouping.
- One fail then pass can be shown as recovery after retry; it is not automatically labeled a flaky test.

## Logs and metric evidence
- Five-minute windows queried every minute are not summed as if disjoint.
- Late-arriving data revises a fixed window without duplicating totals or external messages.
- Identical legitimate repeated log entries retain multiplicity; message hashing does not collapse a real burst.
- Backend count of 4,000 and sample of 200 are displayed distinctly; per-fingerprint totals are not extrapolated as facts.
- Result/page limits and timestamp collisions cannot silently produce complete coverage.
- No stream, parse failure, backend timeout and genuinely zero counted errors are distinguishable where source evidence permits.
- Missing metric, stale samples, NaN, counter reset, low traffic and changed labels are handled explicitly.
- Percentages use matched numerators/denominators; total p95 is not an average of per-pod p95 values.
- Provider-specific profile validation prevents fabricated metrics/labels from silently evaluating healthy.

## Kubernetes
- Initial list of an existing Deployment is not treated as a new deployment at collector startup.
- Pods map through correct owner UIDs, including delete/recreate name reuse.
- Watch reconnect reuses a valid position; expired position triggers relist and visible gap.
- ResourceVersion is treated as an opaque source token, not a numeric timestamp or globally ordered ID.
- Repeated Event/object updates do not inflate independent occurrence counts.
- Old termination reason does not become a new OOM on every unrelated Pod update.
- Secret-bearing spec fields are not persisted; namespace scope does not silently become cluster-wide access.

## Capacity and early warning
- Positive sustained growth with verified headroom yields a conditional threshold estimate.
- Flat/negative growth never generates a finite exhaustion deadline by dividing incorrectly.
- Capacity resize, reset, autoscaling, cleanup cycle and irregular samples qualify or suspend prediction.
- Missing maximum quota/auto-growth semantics are disclosed; logical size is not substituted for actual free space.
- Too little history yields insufficient evidence; no fabricated confidence band/probability.
- Backtest uses only evidence known at evaluation time and reports false warnings as well as useful lead time.

## Correlation and issue lifecycle
- Alert before deployment arrival converges to same final candidates as chronological arrival.
- Symptom predating a deployment is counterevidence against it as the initiating change.
- Two plausible deployments remain alternatives unless evidence supports stronger discrimination.
- Shared-error text with no dependency evidence is a similarity group, not a confirmed common-cause incident.
- Stale source does not resolve an active issue; quiet observation is not asserted healthy.
- Resolution before older firing update remains resolved; a later distinct activation is a new episode.
- Replay uses retained inputs/versions; no live queries/messages and no overwriting human review.

## Notifications and operations
- A thousand matching events update one issue group rather than a thousand messages.
- Escalation, cooldown, digest and recovery follow deterministic company/environment policy.
- Destination/recipient authorization is enforced at send time; one company's group never goes to another's channel.
- Provider timeout after possible acceptance is recorded as ambiguous; no unsupported exactly-once guarantee.
- Collection backlog drains within defined limits without starving other companies/UI.
- Database outage does not falsely acknowledge input or advance checkpoints.
- Retention expires evidence predictably and indicates replay limits.
- Noisy log source, query failures and unavailable credentials appear in source health with last known coverage.
- Actual load measurements report data volume, hardware, configuration and percentile definitions.
