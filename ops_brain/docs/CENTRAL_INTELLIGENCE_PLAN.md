# Central intelligence and predictive health — implementation plan

Status: **proposed, adversarially reviewed; application implementation has not started in this task**.

This plan is based on the current working tree, including the in-progress issue-review, capacity-page, and single-workspace changes. Preserve those changes; do not reset to an older implementation ledger. Paths below are relative to `ops_brain/` unless stated otherwise. Bare filenames listed beside a full path refer to that same directory; test filenames in section 8 belong under `test/ops_brain/` or the explicitly identified `test/ops_brain_web/` directory.

## 1. Goal and boundaries

Add two connected workspace destinations:

1. **Central Intelligence:** what happened, what was affected, the sequence of events, failed pipelines/tasks, relevant logs and measurements, and evidence-backed explanations.
2. **Predictive Health:** what is under pressure or trending toward a threshold, why it deserves attention, which evidence supports the warning, and what is not being monitored.

Build on the existing Phoenix/LiveView, PostgreSQL/Ecto, and Oban application. Here, “intelligence” means deterministic correlation and diagnostic rules, not runtime AI. Preserve the repository's read-only-source/no-runtime-AI contract. No new message broker, graph database, telemetry warehouse, or remediation service is needed.

**Meaning of “everything”:** all authorized, retained facts for the selected scope/time range, with pagination and visible collection limits. The application must not claim to hold every upstream log line. Show sampled/truncated/missing/expired evidence and approved source links for additional investigation. Do not silently expand source permissions or retention.

### Adversarial review verdict

**The original plan was a good foundation, but not complete enough to implement safely unchanged.** The most important omissions were safe shadow-mode delivery, episode/correction semantics, inference feedback loops, actual customer impact, data-quality/order guarantees, and operation during an incident storm or failure of Constellation itself.

Sections **12–13 are mandatory design and acceptance requirements**, with work assigned back into CI-01–CI-09. They are not an invitation to add every possible integration before shipping. Start with one mapped service and a small approved detector set; show every other capability as unsupported/unconfigured. No monitoring tool can predict every failure, and these additions do not claim otherwise.

### Acceptance ledger for the eventual implementation

| ID | Observable acceptance check |
| --- | --- |
| A1 | An operator can open one incident and navigate its pipeline/task failures, related logs, workload changes, metrics, and source-coverage history without switching between unrelated lists. |
| A2 | Every factual explanation links to retained evidence; hypotheses, counterevidence, and unknown causes are visibly distinct. |
| A3 | Connections use explicit company/environment/resource identities and versioned rules; shared names, message text, or timing alone do not establish a cause. |
| A4 | Timeline pagination covers the selected retained history; duplicate deliveries and evidence improvements do not inflate logical failure counts. |
| A5 | Predictive Health includes low-memory, high-CPU, low-disk/inode, and warning/error-trend signals where approved telemetry exists. |
| A6 | Observed failures, present resource pressure, and conditional forecasts have different labels. CPU/memory warnings do not invent a future failure time. |
| A7 | Missing/stale/disabled/unmapped telemetry is unknown or unmonitored, never green; recovery requires comparable positive evidence. |
| A8 | Both pages preserve authentication, company RLS, redaction, expiry, bounded reads, and existing local-review concurrency safeguards. |
| A9 | Replay is reproducible with the versions/evidence known at the evaluation time, and makes no network calls, notifications, or review changes. |
| A10 | Collection, evaluation, and UI have independent measurable bounds; feature disablement and rollback preserve existing operation. |
| A11 | Priority reflects observed user impact and explicit service criticality, with an owner/runbook/next safe check; quiet CPU or absence of error logs cannot prove availability. |
| A12 | Late data, clock uncertainty, mapping corrections, concurrent workers and derived events cannot fabricate causal order, regress current results, loop indefinitely, or inflate supporting evidence. |
| A13 | Incident episodes have defined recovery/recurrence semantics and audited correction/rejection controls; missing telemetry does not silently close a previously critical incident. |
| A14 | New shadow/backfill/replay results cannot send external messages even when legacy delivery is enabled; incident/risk/source-finding notifications do not multiply the same episode. |
| A15 | Expected inventory, startup/warm-up, maintenance, policy changes and decommission are explicit; intentional lifecycle changes are distinguishable from failed collection. |
| A16 | Floods, corrupt input, cardinality spikes, backlog and database/application outages remain bounded and visible; an independent observer detects failure of Constellation. |
| A17 | Sensitive evidence, derived summaries and new review/configuration operations follow approved permissions, source expiry and redaction; copied inputs cannot extend retention indefinitely. |
| A18 | Useful warnings are validated against an agreed baseline and held-out history, including abstentions and lead time; unsupported detectors and unvalidated forecast horizons stay visibly untrusted. |

These are acceptance targets, not claims that the new features already exist.

## 2. What the code already provides

| Existing capability | Relevant implementation | Reuse / current limit |
| --- | --- | --- |
| Durable collection and run history | `lib/ops_brain/collection.ex`, `collection_worker.ex`, `telemetry_collection.ex`; `pipeline_runs`, `run_snapshots`, collection checkpoints | Reuse fenced ownership, transactional persistence, budgets, and replayable observations. |
| Pipeline evidence | `lib/ops_brain/evidence_worker.ex`, `evidence.ex`, `deployments.ex` | Keeps failed-leaf/attempt identities and explicit stage-to-target mappings. Enrichment currently reads at most one task log per tick, first 200 lines, and at most 40 failed leaves. Not comprehensive task-log context. |
| Metrics and logs | `lib/ops_brain/metrics.ex`, `logs.ex`, `telemetry_collection.ex` | Prometheus gauge/ratio queries and Loki fixed-window totals plus bounded samples. Metric threshold comparison is currently `value >= threshold`; there is no general low-watermark policy. |
| Workload evidence | `lib/ops_brain/workloads.ex`, `workload_collection.ex`, `kubernetes_watcher.ex` | Resource UIDs, ownership, restart/OOM and Kubernetes Warning transitions. Do not mistake namespace workload access for node telemetry access. |
| Findings and review | `lib/ops_brain/issues.ex`, `fingerprints.ex`, `issue_review.ex`, `recovery.ex` | Distinct occurrences, evidence revisions, local workflow/audit, and evidence-based recovery. Findings have a source ID; they are not a cross-source incident model. |
| Correlation | `lib/ops_brain/correlation.ex`, `investigation_worker.ex` | Pure evaluator supports explicit dependency pairs. Production worker currently selects deployment evidence for the exact service target, uses a one-hour neighborhood, and passes empty topology. It is not a general cross-source diagnostic engine. |
| Capacity forecasting | `lib/ops_brain/capacity.ex`, `evaluations.ex` | Conservative byte-usage forecast with verified limits, stable series/segment, freshness and knowledge-time checks. Capacity input query currently retains at most 60 selected windows per evaluation. Not a CPU/memory/pipeline prediction system. |
| UI and security | `lib/ops_brain_web/live/operations_live.ex`, `components/ui.ex`, `router.ex`, `operator_auth.ex`; `lib/ops_brain/tenancy.ex` | Existing Pipelines, Services, Investigations, Capacity and Source health pages. Investigations already shows candidates, counterevidence, revisions, and audit history; Capacity already shows stored evaluations. Extend rather than duplicate those capabilities. |
| Retention/replay/delivery | `lib/ops_brain/retention.ex`, `replay.ex`, `replay_detectors.ex`, `notifications.ex` | Reuse expiry, versioned replay, scoped local notices and separately approved delivery. |

### Important gaps to address explicitly

- **Cross-source identity:** `service_instances` includes `source_id`, and telemetry persistence verifies that the service belongs to the collecting source. A Prometheus target and a Loki target can represent the same service but have different IDs. Matching their display names is not a safe join.
- **Multiple telemetry profiles:** `SourceConfig` currently accepts one `profile` per Prometheus/Loki source, with a source-wide checkpoint. CPU, memory, disk and logs must not require cloning the same endpoint into fake independent sources that evade shared budgets.
- **Unified history:** current views expose bounded recent lists rather than a pageable, cross-source incident timeline. The rich embedded timeline in the evidence template is restricted to synthetic demo evidence.
- **Structured diagnosis:** current automatic correlation is mostly deployment proximity. There are no persisted, general diagnostic rules connecting pressure, workload symptoms, application errors and explicitly mapped dependencies.
- **Risk presentation:** a retained historical forecast is not necessarily a current warning. New risk reads need latest-result selection, detector eligibility, and evaluation freshness separate from evidence expiry.
- **Log context:** Loki samples currently retain a short sanitized message and stream digest; most structured severity/request/resource fields are not retained. Pipeline log head samples can miss the actual failure later in a log.
- **Shadow-mode leak path:** `Issues.record/6` reaches `finish_record/4`, which calls `Notifications.prepare/3`; `Notifications.deliver/3` is guarded by the global delivery switch. A new detector reusing this path can notify an already approved sink. A new page called “shadow” does not isolate it.
- **Self-health is not an independent watchdog:** `lib/ops_brain/health.ex` measures queue/database state from inside the application. It cannot report after the process/host is gone, and the new UI cannot depend on a working database to announce that database's outage.
- **Access tiers do not already exist:** the membership schema in `priv/repo/migrations/20260919135154_create_tenancy_foundation.exs` is operator/company membership, not separate reader/reviewer/policy-admin/raw-log roles. Do not promise permissions that are not implemented.

### Current execution paths to preserve

```text
CollectionWorker -> Collection -> pipeline run/snapshot + durable enrichment work
  -> EvidenceWorker -> Evidence / Deployments -> Issues
  -> InvestigationWorker -> Correlation -> stored correlation evidence

CollectionWorker -> TelemetryCollection -> Metrics / Logs / workload collection
  -> fixed observation window + immutable revision + evidence
  -> Issues / Recovery
  -> Evaluations.capacity -> Capacity -> stored capacity evidence + finding

Authenticated LiveView -> scoped context query -> Tenancy.with_scope -> RLS
```

## 3. Page design

### A. Central Intelligence

Proposed routes, inside the existing authenticated `:operators` live session:

- `/companies/:company_id/intelligence`
- `/companies/:company_id/intelligence/incidents/:incident_id`

Use a new `OpsBrainWeb.IntelligenceLive`, not additional large branches in `OperationsLive`.

**Overview**

- Summary: qualified active incidents, failed delivery activity, affected mapped entities, and coverage gaps. Keep preliminary finding wrappers separate from confirmed observed incidents. Counts state their time range and basis.
- Prioritize by observed user impact, service criticality, environment and urgency—not the number of log lines. Show the responsible team/runbook, next safe investigation step, and why the item ranks here. A busy resource is not automatically an outage.
- Two views within the destination: **Incidents** and **Event stream**. Informational and successful events remain available even when they have no incident.
- Filters: time range, environment, service/resource, source, event kind, severity, and lifecycle. Include explicit Unmapped/Unknown options.
- Each incident shows impact scope, first/last occurrence, most recent evidence, supported explanation or “cause not established,” and source freshness.
- Keep unmapped CI failures in delivery health. Do not turn production red simply because a build failed.

**Incident workspace**

1. **Summary:** observed symptom, affected resources, current versus historical condition, and missing coverage.
2. **Why / possible causes:** known failure mechanism, ranked candidate explanations with their rule and evidence strength, alternatives, and counterevidence. No fabricated probability or unsupported root-cause claim.
3. **Timeline:** deployment/run/task attempts, warnings/errors, restarts/OOM, pressure windows, collector gaps and recovery. Show occurrence and receipt times, including late arrivals and inferred timestamps.
4. **Logs:** structured error first, bounded before/after context, severity, source, task/container identity, sample status, and safe upstream reference. Preserve legitimate repeated identical entries.
5. **Metrics:** aligned time-series excerpts with units, limits, sampling gaps, and event markers. No smoothing across missing data.
6. **Related activity:** linked pipeline runs, affected tasks/attempts, dependencies, and relevant predictions before the incident.
7. **Review:** retain underlying finding ownership, acknowledgment, snooze and audit. Before automatic cross-source grouping ships, support authorized, audited correction of incident membership and candidate rejection with revision checks (section 12.4). These local decisions must not silently mutate all member findings or source systems; incident-wide acknowledgment/assignment remains separately scoped.

Default to readable summaries, not JSON. Keep sanitized raw diagnostic JSON under expandable details. Page reads use persisted state only; opening a page never queries providers.

Proposed illustration, not collected data:

```text
10:02 Deployment reported to checkout/prod
10:06 Container memory pressure observed
10:08 OOMKilled termination and restart recorded
10:09 Application error rate increases

Observed mechanism: container was terminated for OOM.
Possible contributor: deployment preceded the pressure increase on this target.
Not established: memory leak, exact trigger, or deployment as root cause.
Missing: comparable pre-deployment memory samples.
```

### B. Predictive Health

Proposed route: `/companies/:company_id/predictions`, handled by `OpsBrainWeb.PredictionsLive`.

- Separate **Current pressure**, **Conditional forecasts**, and **Monitoring gaps**. Warnings/errors are inputs, not automatically predictions.
- A row/card shows entity/environment, detector, condition/severity, current value and units, policy threshold, evaluated-at/valid-until times, trend window, supporting evidence, and suggested read-only investigation.
- Show a time-to-threshold only for an eligible forecast, with its assumptions. Otherwise display the actual reason, such as “limit unknown,” “growth unstable,” or “insufficient history.”
- Detail shows the input chart, warning history, related logs/deployments/incidents, and what would invalidate or clear the warning.
- Include a detector-coverage matrix: configured/fresh, partial, stale, disabled, unsupported, unmapped. Do not use an unexplained overall health score.
- Latest unknown/stale evaluations must not leave an older healthy or warning result looking current. Historical evaluations remain inspectable with their timestamps.

Keep current `/investigations` and `/capacity` URLs working during rollout. Add the two new destinations through `UI.areas/0` and the existing workspace navigation. Do not reintroduce the removed company chooser.

## 4. Shared backend design

```text
Existing approved collectors
  -> existing durable evidence / immutable revisions
  -> atomic enqueue of bounded intelligence processing
  -> explicit entity resolution + normalized event index
  -> deterministic incident association / diagnostic evaluation
  -> stored incident and risk read models
  -> authorized LiveViews
```

### 4.1 Identity before correlation

Add a small canonical entity mapping layer; preserve existing source-specific service IDs.

- Canonical identity: company + explicit environment + resource domain (cluster/account/region/namespace as applicable) + entity kind + stable native key/incarnation. Differentiate services, pods/containers, nodes/agents, volumes/filesystems and databases. Collector source ID and display name alone are not resource identity; two clusters can both contain `node-1`.
- Bind approved source-local identities to canonical entities. Start with service-instance bindings, then the resource/series identities needed by the delivered detectors.
- Persist directed relations such as `depends_on`, `runs_on`, and `uses_volume` only from reviewed mappings or retained ownership evidence. Store provenance, validity interval and mapping version.
- Environment must be explicit. Shared dependencies crossing environments require an explicit reviewed relationship and separate impact attribution.
- Ambiguous/unmapped input remains visible; it is not dropped or guessed. A renamed/recreated pod uses its UID, not its old name.
- Retain enough mapping history to replay what was known then; a mapping created today must not silently rewrite a historical diagnosis.
- Maintain an approved expected-resource/detector inventory with monitoring start/end, owner and capability status. Discovery is a suggestion, not monitoring approval. A missing expected resource is a coverage gap; explicit decommission is not a spontaneous recovery. See section 12.2.

### 4.2 Normalize facts without duplicating the telemetry warehouse

Proposed `OpsBrain.Events` projection produces a bounded common header:

```text
event_id, company_id, source_id, entity_id (nullable if unresolved)
kind, normalized_severity, source_severity, logical_occurrence_key
source_record_key, source_revision, schema_version, mapping_version
origin_class (raw/derived), input_lineage, projection_generation
occurred_at, received_at, collected_at when available, timestamp_basis
coverage, evidence_availability, typed_provenance_reference
```

Initial event kinds: pipeline completion/task failure, reported deployment, selected log sample/window, metric warning/recovery, workload transition, source-health transition, and detector evaluation.

- Reference existing immutable evidence/run snapshots/observation revisions; do not copy whole raw payloads into the event index.
- Preserve informational context and successes as well as errors. Index metric windows, not every raw sample as a separate incident.
- Distinguish delivery deduplication, logical failure identity, and a newer evidence revision. A better log sample updates evidence history, not failure counts.
- Use database uniqueness on scoped origin identity/version. Avoid unchecked polymorphic IDs: use typed references with composite company foreign keys and validity constraints.
- Preserve original sample multiplicity. When the backend lacks stable per-line IDs, identify samples within retained window revisions and label that limitation rather than claiming an exact globally deduplicated log total.
- Sanitize allowlisted structured fields before persistence. Do not retain arbitrary log labels, request headers, stack contents, or secrets simply to improve correlation.
- Backfill only retained records in bounded batches. Missing historical fields remain unknown; do not invent earlier event time, severity, or context.

### 4.3 Incident association and explanations

Keep `issue_groups` as source findings. Add an incident aggregate that can reference multiple source findings/events without rewriting their identities or counts.

Use typed, versioned rules, not a generic user-programmable rule language:

| Relationship | Minimum evidence | Interpretation |
| --- | --- | --- |
| Task belongs to run/attempt | Same scoped source/run/timeline/attempt identity | Direct structural fact. |
| Runtime signal belongs to resource | Approved binding or retained UID/ownership relation | Direct identity/ownership fact. |
| Deployment precedes regression | Mapped target, relevant time window, symptom; comparable before/after data when available | Candidate contributor, not proof. |
| Memory pressure with OOM | Same container/resource and segment, valid memory measurement plus OOM event | Observed termination mechanism; underlying cause may still be unknown. |
| Disk pressure with failed writes/build task | Same filesystem/agent mapping plus relevant failure code/log | Supported candidate; time proximity alone is insufficient. |
| Dependency pressure with upstream timeouts | Explicit dependency relation plus both measurements and symptoms | Candidate dependency problem; preserve alternatives. |

Rules return `facts`, `mechanisms`, `candidates`, `counterevidence`, `missing_inputs`, `rule_version`, `input_references`, `mapping_version`, and `evaluated_at`. Every factual item carries evidence references.

Separate structural links, symptom associations, and candidate explanations. Weak links may appear under Related activity without merging incidents. Prevent unlimited transitive grouping and unbounded time windows; record why membership was added. Same text or a shared one-hour window is not a merge rule.

Re-evaluate when relevant late evidence/mapping revisions arrive, using bounded neighborhoods and deterministic ordering. Persist an append-only evaluation revision; do not replace historical explanations or human review. Recovery is not “nothing arrived recently.”

**Required correctness contract:** section 12.3 defines knowledge-time snapshots, mapping corrections, monotonic latest-result updates, derivation-loop prevention, and evidence independence. These are CI-03/CI-05 requirements, not later optimization. Dependency topology may contain cycles; evidence derivation must not.

### 4.4 Multiple profiles under one real source

Extend configuration to a bounded `profiles` list for Prometheus/Loki, retaining backward compatibility by normalizing existing singular `profile` configurations to a one-item list.

- Each profile has ID/version, approved query/selector, target binding, units/semantics, required freshness, detector policy, and collection interval/bounds.
- Keep endpoint, credential, tenant and request budget at the source level. Profiles cannot override trust boundaries.
- Add per-profile progress/coverage. Preserve source-level lease/fencing and aggregate health; one failed profile must not advance its checkpoint because another succeeded.
- Share request admission across collection/enrichment and all profiles; bound fairness, concurrency and catch-up work.
- Retain series identity plus a minimal reviewed resource-label allowlist for per-node/container/filesystem diagnosis. Do not aggregate away the resource that is actually exhausted.
- Carry profile and policy versions into observations, jobs, detector inputs and replay. Validate unsafe/unknown keys and semantics before enabling collection.

This is a collection-contract change, not merely a config-array loop. Ship it with checkpoint, budget and partial-failure tests before adding multiple resource profiles.

## 5. Initial early-warning detectors

Reuse `Evaluations`, `Capacity`, `Issues`, and `Recovery`; introduce a small explicit detector registry and pure rule modules as required. Threshold examples below are **pilot policy proposals**, not installed defaults or universal failure boundaries. Source owners must approve the real metrics, units, limits and thresholds.

| Detector | Required evidence | Initial behavior / honest output |
| --- | --- | --- |
| High CPU | Correctly normalized CPU utilization per node/container; core/quota context; optional throttling/run queue | Example: sustained utilization >=85% for 10 minutes. Report pressure; distinguish busy-but-healthy from observed saturation. No exact failure ETA. |
| Low memory | Host available memory or container working set relative to a verified cgroup limit; resource/restart identity; optional pressure/OOM | Example: sustained >=85% usage of a known container limit for 5 minutes. Separate host available memory from container memory. Missing/unlimited limits disable ratio-based prediction. No straight-line “OOM at 14:32.” |
| Low disk / inodes | Available bytes and total/effective capacity per relevant filesystem; inode availability; filesystem identity | Example: <=15% available or an approved absolute headroom threshold, sustained. Separate disk-space and inode exhaustion; exclude explicitly irrelevant/ephemeral mounts. |
| Storage growth | Verified byte limit, stable series/segment and enough recent historical samples | Reuse `Capacity.evaluate/3`; show conditional time to threshold only while assumptions hold. Unknown auto-growth, cleanup, resize or restart invalidates the estimate. |
| Rising warnings/errors | Fixed-window backend counts by approved level/category/service; coverage; traffic denominator where applicable | Sustained/rising rate relative to comparable windows, with minimum volume. Treat producer severity as context, not proven user impact. Informational logs remain timeline context unless a specific rule uses them. |
| Delivery degradation | Comparable completed run history per definition/branch, distinct run IDs and result categories | Show repeated failures or rising failure share as delivery risk, not runtime outage. Failed/succeeded denominator is explicit; canceled/partial results are reported separately. Do not count retries as extra runs. |
| Collection blind spot | Per-source/profile freshness, gaps, admission failures and retained safe error categories | Monitoring reliability warning, separate from a claim that the monitored service is failing. Never expose global Oban arguments/errors. |

Implement the first four resource detectors and monitoring gaps first, alongside service-impact measurements where already approved. Do not call that complete service monitoring: section 12.5 assigns explicit capability/defer states to latency/availability, dependency saturation, stuck work and expiry checks. Warning/error and delivery-trend policies follow once identity and denominators are validated.

### Evaluation contract and lifecycle

Store: detector/version, policy/version, canonical entity, owning source/profile, input identities and knowledge times, condition, severity, explanation, missing prerequisites, evaluation window, `evaluated_at`, `valid_until`, and optional conditional threshold estimate.

- A detector evaluation is immutable evidence; a separate latest-result projection makes current reads cheap. Include normal and unknown results, not just warnings.
- For multi-source inputs, the configured evaluator has an explicit owning source/profile and validated same-company evidence references; do not invent a credential-bearing “central source.”
- Support high and low threshold directions, minimum history/sample count, sustained duration, separate raise/clear thresholds and recovery duration. Use elapsed event time, not number of worker retries. Critical source facts (for example explicit OOM or a verified hard disk breach) need a separately approved immediate path; forecast warm-up or a generic ten-minute warning delay must not hide an existing failure.
- Keep current breach detection independent from forecast eligibility: an observed low-disk condition can be important even when growth is flat and the forecast is unknown.
- Never apply the byte-growth algorithm to CPU percentages or arbitrary memory series. Changing semantics requires a new detector/policy version.
- For longer-horizon forecasts, validate the sampling window first. Increase bounded history or introduce reviewed rollups only when needed; 60 one-minute samples do not establish multi-day behavior. Limits/segment verification must be fresh and tied to resource incarnation and observed capacity/restart/cleanup changes; a static `capacity_segment` string or `limits_verified` flag is not evidence that nothing changed. See section 12.6.
- Deduplicate warning episodes by entity + detector + policy/profile identity. Suppress notification flapping, not retained evidence. No automatic external delivery during initial rollout.
- Existing capacity results remain readable through a compatibility adapter. Do not reinterpret v1 stored policies or replay them with a new algorithm silently.

## 6. Storage, modules, and registrations

Names below are **proposed**, not existing public interfaces. Add tables/modules only in the slice that uses them.

| Addition | Purpose / integration |
| --- | --- |
| `EntityMappings` plus canonical entity, binding and relation tables | Connect existing source-specific identities; retain mapping provenance/history. |
| `Events` plus `intelligence_events` | Indexed, immutable event headers pointing to existing retained evidence/revisions. |
| `Incidents` plus incident/member tables | Cross-source aggregate and explainable membership. Keep existing source findings/review intact. Store diagnostic revisions using the evidence/versioning pattern. |
| `Intelligence` and `IntelligenceWorker` | Bounded scoped read models and durable projection/correlation work. Use existing `:enrich` queue initially; measure before introducing another queue. |
| `Risks` plus a typed latest-evaluation read projection | Per-entity detector results/history, freshness and eligibility; durable evidence remains the source of truth. |
| `RiskWorker` and explicit detector registry | Event-driven evaluation plus scheduled freshness/gap evaluation, with injected clocks and bounded work. |
| `IntelligenceLive`, `PredictionsLive` | New UI boundaries using shared layout/components and authorized context APIs. |

For every new operational table: company-prefixed indexes, forced RLS, composite company foreign keys, idempotency constraints, explicit storage/JSON bounds, and retention behavior. Update both `priv/repo/runtime_grants.sql` and `rel/runtime-grants.sql`, database safety checks, disposable-test cleanup/fixtures and replay exports as appropriate. Mapping/incident state cannot be made tenant-safe by UI filtering alone. Section 12.8 also requires derived-content expiry to respect contributing sources and explicit permissions for new review/configuration/log access.

Required integration checklist:

- `lib/ops_brain_web/router.ex`: authenticated routes; `components/ui.ex`: navigation and labels; home links in the existing workspace UI.
- `lib/ops_brain/configuration.ex`, `source_config.ex`, `config/sources.example.json`: multi-profile contract and validated detector policies.
- Proposed `intelligence_enabled` and `predictions_enabled` switches: default off, registered through configuration and honored by producer/worker/scheduler paths. They grant no additional collection or delivery authority. Add a trusted per-detector `evaluation_mode` (`off`, `shadow`, `active`) with `shadow` as the enabled pilot default. Section 12.1 requires origin-aware notification gates at both preparation and delivery; the global delivery switch alone is insufficient.
- `collection.ex`, `evidence.ex`/`evidence_worker.ex`, `telemetry_collection.ex`, `deployments.ex`, `workload_collection.ex`: persist facts and enqueue projection work atomically at the appropriate durable boundary.
- `scheduler.ex`: bounded periodic evaluation of stale/missing inputs, not only evaluation on arriving healthy data.
- `evaluations.ex`, `correlation.ex`, `investigation_worker.ex`, `replay_detectors.ex`: explicit version dispatch and backward compatibility.
- `retention.ex`, maintenance/recovery paths: expire derived payloads and references consistently; no sensitive text survives in a copied summary after source evidence expires.
- `operational_metrics.ex`: queue age, projection lag, evaluation duration, stale results, mapping misses and bounded work counters without high-cardinality tenant data or log text.

### Query and worker behavior

- Filters run in SQL **before** pagination. Use a server-validated snapshot cutoff plus stable keyset cursors including timestamp/ID, company, filters and projection generation; late events must not move invisibly behind a cursor. Default page size 100 with an enforced maximum. Show new-arrival and incomplete-window indicators; restarting a snapshot is explicit. Authorization and evidence expiry are always checked at current time, even when viewing a frozen historical snapshot.
- Compute summaries for a documented bounded scope, not a silently truncated in-memory list. Cap graph neighbors, log context, chart points, processing range and total work.
- Insert work with accepted input in the same transaction; Oban uniqueness is only an optimization, not domain deduplication. Projection/backfill has durable progress and can safely retry after crashes.
- New facts and retry/replay must not duplicate incidents or notification episodes. Schedule relevant incident/risk re-evaluation for late evidence and material mapping changes.
- Refresh from persisted state using the existing polling approach initially. Preserve an open incident route/filters/scroll, but reauthorize and re-read expiry/freshness on every refresh. No stale authorized payload should be pushed after membership revocation.
- Use LiveView streams for pageable lists. Add accessible status text and keyboard/focus behavior; charts must have textual data summaries. Retain usable 320px layouts.

## 7. Ordered implementation slices

Do not implement this entire document in one change. Each slice gets its own acceptance tests and review; no placeholder schemas for later slices.

| Slice | Deliverable and main files | Exit check |
| --- | --- | --- |
| CI-01 | Freeze event/evaluation, state-machine, notification-origin/mode and permission contracts; define pilot inventory, impact signals, budgets and sanitized fixtures. Add scoped read-model/contract tests. | Inputs and missing capabilities are explicit; shadow-mode behavior, episode rules, prioritization and measurable pilot acceptance are agreed before schema work. |
| CI-02 | Canonical entities/bindings, resource domains/incarnations, expected inventory and reviewed relationships. Integrate `Services`, `Deployments`, telemetry identities and trusted configuration. | Same names across clusters/companies/environments never auto-join; mappings have history, owner and correction/decommission behavior. |
| CI-03 | Event projection, origin/lineage, monotonic result heads, atomic jobs, snapshot pagination and bounded backfill. Integrate durable collector/evidence boundaries and retention. | Duplicate/late/corrected inputs do not inflate counts; derived events cannot self-amplify; retries, stale workers and live/backfill races are safe. Shadow/backfill outputs cannot notify. |
| CI-04 | Central Intelligence overview/event stream and deep-linked workspace. Add incident/member tables as one-to-one preliminary finding wrappers, explicit lifecycle, impact/owner/coverage labels, and stable snapshot navigation. | Readable evidence drilldown works; preliminary findings are not inflated into confirmed incident totals; filters/auth/expiry work; old URLs remain valid. |
| CI-05 | Cross-source association and diagnostic v2 rules, evidence-strength/lineage, audited link/unlink/merge/split/candidate rejection and semantic incident revisions. Extend `Correlation`/investigation processing. | Wrong groupings can be corrected without losing original facts or review; exact rejected links do not reappear on replay; independent incidents stay separate and stale data cannot falsely recover/reopen them. |
| CI-06 | Multi-profile collection, structured resource/log context, profile-version checkpoints, malformed-input handling and bounded relevant task-log enrichment. Update configuration and admission. | Profiles share source budgets; cost estimates include multi-request queries; partial failure/version changes cannot skip history or create green gaps; cardinality and sample limits are visible. |
| CI-07 | Resource pressure, current hard breaches, service-impact context where supported, forecast integration and scheduled freshness. Add mode-gated results, segment/limit validation and baseline/maintenance semantics. | Current critical facts survive forecast ineligibility; unknown/stale signals do not clear incidents; shadow mode cannot reach delivery with existing sinks enabled. |
| CI-08 | Predictive Health with latest results, history/charts, coverage matrix, owner/next-check context and incident cross-links. Include cold-start/maintenance/stale/expired UI states. | Pressure, forecasts and impact remain separate; both pages stay useful with partial telemetry, late arrivals, failed enrichment and disabled features; permissions/accessibility pass. |
| CI-09 | Warning/error and delivery trends, held-out replay/backtest validation, operator pilot and scale/outage/restore exercises. Reconcile eligible scope against the detector catalog. | Correct denominators, false/missed warnings, abstentions and useful lead time are reported against a simple baseline; overload and independent watchdog gates pass before broader rollout or notification approval. |

Dependencies: CI-01 -> CI-02 -> CI-03 -> CI-04 -> CI-05; CI-06 can follow CI-03, then CI-07 -> CI-08; CI-09 follows both tracks. Keep schema/core ownership serial even if UI work is delegated. CI-08 incident cross-links also require CI-04/CI-05. Contracts for modes, episode lifecycle, versions and review permissions are agreed in CI-01, not invented independently by each track. Split a slice into smaller reviewed PRs when needed; the new safety gates must not all be deferred to CI-09.

**First useful checkpoint:** CI-04, a real diagnostic workspace using current retained evidence. **Two-page MVP:** through CI-08, including mapped cross-source incidents and resource warnings. **Full planned scope:** through CI-09, which adds warning/error and delivery trends and validates practical usefulness; production forecast claims still require its calibration gate. Passing the applicable section 13 adversarial cases is mandatory at each checkpoint. Broad auto-association requires local correction controls first; production paging requires separate explicit approval even after both pages exist.

## 8. Test plan

Use existing tests as regressions, not as proof of unimplemented behavior. New filenames below are suggestions.

The numbered adversarial scenarios in section 13 are required additions to this test plan, not optional examples. Each has an owning slice and must be checked before that slice is accepted.

### Pure domain tests

- `entity_mapping_test.exs`, `event_normalization_test.exs`: scoped identities, unresolved input, UID reuse, timestamps, information/warning/error mapping, revisions and sample multiplicity.
- `incident_correlation_test.exs`: strong versus weak relations, unrelated simultaneous failures, separate environments, dependency direction, clock skew, temporal counterevidence, late data and deterministic ordering.
- `resource_pressure_test.exs`: high/low comparisons, threshold boundaries, sustained duration, hysteresis, units, absent limits, container restarts, filesystem changes, stale/partial input and observed breach with ineligible forecast.
- `risk_evaluation_test.exs`: latest unknown overrides old normal/warning as current state, warnings expire, comparable recovery, policy changes and no fake probabilities/ETAs.
- Keep `capacity_acceptance_test.exs` and the synthetic capacity backtest unchanged as compatibility checks unless an explicitly versioned algorithm change is approved.

### Real PostgreSQL and worker tests

- Forced RLS/cross-company foreign keys on every new table, runtime grants and revoked membership.
- Concurrent duplicate projection/association, crash between stages, Oban retry, out-of-order evidence, resumable backfill and deterministic membership.
- Multi-profile partial failure, independent progress, shared admission, expired lease/stale worker fencing and bounded catch-up.
- Evidence expiry removes sensitive content from index/summary/history; retained metadata honestly says exact replay is unavailable.
- Read queries filter before limits, paginate without skips/duplicates, and use intended indexes. Use `EXPLAIN (ANALYZE, BUFFERS)` on realistic approved synthetic volumes as the restricted role.
- Replay uses both occurrence and receipt/knowledge cutoffs, historical mapping/policy versions, and never makes HTTP calls, sends notifications, or changes local review.

### LiveView and end-to-end fixtures

- `intelligence_live_test.exs`, `predictions_live_test.exs`: route registration/nav, URL filters, pagination, empty/unmapped/stale/expired states, source-safe links, accessible summaries, and stable detail navigation.
- Reauthorize mount, reconnect, navigation, refresh and events; reject cross-company IDs/cursors. Do not expose global job errors.
- End-to-end scenario: mapped deployment -> pressure -> OOM -> errors -> linked incident -> comparable recovery. Also test identical events with no mapping: related diagnosis must remain unknown.
- End-to-end disk scenario: steady fill -> conditional warning -> actual threshold breach -> cleanup/segment reset. The forecast must be invalidated after the reset, not carry forward its old deadline.
- Pipeline scenario: multiple failed tasks and a retry remain one run with distinct task/attempt history; absent/truncated logs are visible; an unmapped CI failure does not become a production outage.
- Regression set: `investigation_test.exs`, `evidence_revision_test.exs`, `telemetry_sources_test.exs`, `capacity_recovery_test.exs`, `replay_retention_test.exs`, `operations_read_test.exs`, `tenancy_test.exs`, `ops_brain_web/authorization_test.exs`, and current capacity/review/redaction LiveView tests.

Run targeted tests first, then `mise exec -- mix ci` on the explicitly approved disposable database and `mix phx.routes`. Follow `README.md` database safety requirements; tests must never point to valuable data. `mix precommit` is the developer's formatting/full-test gate when appropriate, but it mutates files and should not be run blindly over someone else's unfinished changes. A compile-only result is not acceptance.

## 9. Rollout, cost and recovery

1. Agree on one pilot company/environment/service and actual exporter/log capabilities. Run with collection/delivery disabled until existing source approvals permit them.
2. Apply additive migrations and least-privilege runtime grants. Backfill bounded retained evidence; measure row/storage growth, query plans and projection lag before enabling for the whole pilot.
3. Enable intelligence, then risk evaluation in **dashboard-only shadow mode** with section 12.1 delivery guards enforced, even if legacy notifications remain enabled. Label all fixture/demo data as synthetic. Do not alter upstream alerting.
4. Review false associations, unmapped percentage, coverage, warning usefulness, lead time and false/missed warnings. Backtest against actual threshold crossings, not the forecast's own output. Report unknown/abstained cases and avoid double-counting overlapping evaluations as independent incidents.
5. Agree on workload-specific latency/storage/query-budget targets and measure them before enabling collection profiles. Include live-versus-backfill contention, noisy-tenant fairness, retention throughput, restore/rebuild, and monitoring-platform outage exercises (sections 12.7 and 13). This plan provides no unmeasured production performance guarantee.
6. Enable any external notifications only under a separate recipient/sink approval, reusing outbox deduplication and cooldown policies. No automatic restart/rerun/scale/cleanup actions.

Disable `predictions_enabled` or `intelligence_enabled` and stop their scheduling/processing without changing source monitoring permissions. Historical pages must indicate disabled/stale evaluation. Existing collection/delivery switches retain their authority. For rollback, deploy the compatible previous code, stop new jobs, and retain additive data until reviewed cleanup; do not drop evidence or rewrite human review as a quick rollback. Test backup/restore and schema compatibility in the disposable environment first.

## 10. Decisions needed before the relevant slice

- Which real services/resources and environments form the pilot, and who approves their canonical mappings/dependencies?
- Which approved metrics provide node/container CPU, usable memory, filesystem bytes/inodes and effective storage limits? Namespace-only Kubernetes access is not enough to assume all are available.
- Which application-log fields/severity categories are safe and useful to retain? What bounded task-log context and source links are permitted?
- What source budgets, history windows, retention, hysteresis and forecast horizons are appropriate for that workload?
- Which reviewed runbooks should the UI link to? Remediation remains outside the application.
- What customer-facing success/error/latency measurements establish impact, and what does the owner consider an actionable warning?
- Who may inspect raw excerpts, change mappings/policies, or correct incident membership? Company membership alone currently provides no separate role tiers.
- What maintenance schedules, expected jobs/resources, cold-start periods and decommission rules apply?
- What projected source/series/event volumes, request costs, response-time targets, warning budgets, and recovery objectives must the pilot meet? Who monitors Constellation externally?

These are setup decisions, not reasons to build a runtime AI system or ingest unlimited logs. Start with CI-01 and one concrete multi-source incident scenario.

## 11. Verification history

### Original planning pass

- Inspected the current collectors -> evidence/issues -> investigation/capacity -> scoped UI execution paths, schema, configuration, review/retention/replay boundaries and relevant tests.
- Ran the existing pure capacity acceptance suite without application startup, database access or network calls: **22 passed**.

  ```sh
  cd ops_brain
  mise exec elixir@1.20.4-otp-27 erlang@27.3.4.16 -- elixir \
    -r lib/ops_brain/capacity.ex \
    -e 'ExUnit.start(); Code.require_file("test/ops_brain/capacity_acceptance_test.exs")'
  ```

- Ran a direct `Correlation.evaluate/4` probe: an unmapped dependency produced 0 candidates; supplying the explicit dependency produced 1; changing company produced 0. This checks the existing pure primitive, not a production topology implementation.
- No full database suite, browser acceptance, live-provider check, deployment, or new feature implementation was performed. No application files or existing working-tree changes were modified by this task; the deliverable is this plan.

### Adversarial review pass

- Re-read the entire original plan and traced the notification producer/consumer path, scheduler, self-health, metric guards, source budgets, membership schema and proposed detector catalog. The catalog is a roadmap, not evidence that every detector is implemented.
- Confirmed by source inspection that `Issues.record/6` can prepare notifications for approved sinks and that delivery uses the global switch. This motivates an additional origin/mode gate; no live notification was sent to test it.
- Ran a pure `Capacity.evaluate/3` probe with a fresh 1,100-byte usage sample and verified 1,000-byte threshold but insufficient history: the measurement was over threshold while the forecast returned `unknown` (`insufficient history`). This is expected forecast behavior and demonstrates why current-breach detection must be independent.
- The 22 capacity-test passes above are from the original planning pass; they were not rerun unchanged during this review. New design scenarios below are acceptance requirements, not tests already proven by the application.
- This pass changes only this plan. No new runtime feature, database test suite, provider call, delivery, migration, or deployment was performed.

## 12. Mandatory additions from the adversarial review

### 12.1 Shadow mode and notification ownership — blocking safety requirement

The actual existing path is `Issues.record -> finish_record -> Notifications.prepare -> outbox/NotificationWorker -> Notifications.deliver`. Reusing it without a mode gate can send new experimental warnings when existing delivery is already enabled.

- Persist a trusted origin and evaluation mode for new results. `off` schedules nothing new, `shadow` retains evaluations/local drafts without external delivery, and `active` is still subject to a separately approved notification policy. Do not take origin/mode from provider text or browser parameters.
- Enforce eligibility both when preparing a message and immediately before delivery, against current policy. Shadow processing must not call a notification-producing path without that protection. Do not disable legitimate existing notifications to make the new feature safe.
- Backfill, replay, mapping rebuilds and historical reclassification never page. Activating a detector does not flush historical shadow rows into the outbox; it requires a fresh eligible evaluation.
- Define one notification owner per new episode/destination: source finding, risk, or aggregate incident. Additional evidence updates the case; it does not generate three alerts. Preserve existing upstream paging and explicitly approved legacy behavior.
- Separate semantic notification revisions (new actionable condition, escalation, material impact, recovery) from row/evidence/review revisions. A chart refresh, owner edit or extra identical sample is not an escalation.
- Maintenance/quiet policies are local, scoped, time-bounded and auditable. They suppress eligible messages, not facts or incident visibility; show why a message was withheld. Existing ambiguous-delivery/idempotency safeguards remain in force.

**Owner slices:** contract in CI-01; guards before CI-03/CI-07 writes can reach existing findings; race/regression tests before any active delivery.

### 12.2 Coverage is a product contract, not just a source timestamp

- Keep an expected inventory of monitored entities and required checks, not just whatever series happened to arrive. Store owner, criticality, monitoring start/end, expected cadence, approved capabilities, profile/mapping versions and relevant dependency/resource domain.
- A valid empty query, disappeared expected series, disabled source, parser rejection, permission loss, unsupported resource type and an intentionally retired service are different outcomes. Quiet logs alone do not prove either availability or collection failure.
- Report completeness separately for collection, normalization, projection, enrichment and evaluation. A collector can be current while the investigation queue is hours behind. Selected/capped correlation inputs cannot justify “no candidate exists.”
- Normalizers have versioned required fields, units, timestamp precision, severity fallback, parser failure and truncation rules. Unsupported/new provider shapes are unknown or partially covered, not zero/normal. Persist only bounded redacted rejection metadata—not raw secret-bearing dead letters.
- Resource bindings include control-plane/cluster/namespace and incarnation where applicable. Pod recreation, filesystem remount, renamed host, rolling rollout and multiple containers must not accidentally splice unrelated histories. A pipeline deploying to several environments retains distinct deployment targets.
- Changes to selector, query, unit, resource labels, policy or profile version start the appropriate new collection/baseline epoch. A checkpoint proving coverage for the old query cannot prove coverage for the new query. Removing a profile records retirement rather than leaving an eternal stale warning.
- Approvals/mappings remain deployment-owned for the pilot; the UI needs a readable mapping/coverage inventory and unresolved queue, not an unreviewed source-admin wizard.

**Owner slices:** CI-01/CI-02 contracts; CI-03 completeness; CI-06 profile migration; CI-08 coverage presentation.

### 12.3 Time, corrections and inference feedback loops

**Knowledge and event time.** Keep occurrence time and receipt/knowledge time separate, preserve source precision/ordering identifiers, and inject the evaluation clock. Define bounded allowed lateness and future-clock skew per profile. Do not rewrite a suspicious source clock to make a timeline neat; expose timestamp uncertainty and withhold causal ordering when intervals overlap. Normalization must handle second/millisecond/nanosecond formats explicitly.

**Stable snapshots.** A timeline cursor binds company, filters, knowledge cutoff and projection generation as well as its sort position. It cannot silently combine two mapping generations. Show “new evidence available” and let the operator refresh a frozen snapshot; normal expiry and permission checks still apply immediately. Distinguish “what we knew then” from a current reconstruction including late evidence.

**Correction model.** Raw fact identity is immutable; identity resolution, membership and explanation are versioned projections. A corrected mapping/severity or improved log creates a superseding revision with reason/provenance, not a new failure and not an in-place rewrite of history. Support retraction/invalidated interpretations without erasing the original observation. Rebuild into a new projection generation with a durable watermark, catch up live changes, then switch the read head atomically; never show a half-backfilled view as complete.

**Concurrency.** Use a unique evaluation identity based on entity, detector/policy/profile version, closed evaluation window and selected input revision digest. A retry of the same inputs/window cannot make a new episode. Latest-result publication uses compare-and-set/ordered generation semantics: a slow historical worker finishing after a newer evaluation cannot become current or overwrite review. Time-dependent freshness evaluations use explicit slots/state changes rather than enqueueing an unlimited new history on every UI refresh.

**No inference loops.** Mark raw and derived origins and retain bounded acyclic input lineage. An incident or risk result may be shown as related context, but cannot become raw input to itself, repeatedly trigger the opposite worker, or strengthen its own hypothesis through a loop. Cyclic service dependencies are legitimate topology; traverse with visited sets and hop/fan-out caps. They are not permission for cyclic evidence derivation.

**No double-counted support.** A log sample, a counter derived from that same log, and the incident created from both are not three independent confirmations. Rank explanations with a documented versioned rule ordering and show which facts are direct, corroborating, contradictory or merely contextual. Count distinct source-qualified runs/tasks/resources—not raw IDs reused by another project/source. Shared timing remains weak evidence even when many duplicated signals agree.

**Owner slices:** CI-03 event/projection guarantees; CI-05 diagnostic/membership semantics; CI-07 latest risk heads; CI-09 replay parity.

### 12.4 Incident lifecycle and human correction

Condition, observation coverage and human workflow are separate axes. Decide the transition table before implementing aggregation:

| Situation | Required behavior |
| --- | --- |
| New source finding without corroborated impact | Visible preliminary finding/case; do not count it automatically as a confirmed service incident. |
| Current symptom with sufficient applicable evidence | Active episode with explicit impact scope; finding/task/event counts stay separate. |
| Telemetry disappears after a critical observation | Coverage becomes unknown/stale; preserve “last confirmed critical at …” and an unresolved episode. Do not infer recovery. |
| Comparable fresh recovery evidence arrives | Mark the applicable condition recovered with its evidence/time; member-specific recovery cannot recover unrelated affected services. |
| Same failure recurs after genuine recovery | Apply a documented bounded recurrence policy, normally a new linked episode. Do not append forever to one fingerprint or reopen because of late historical data. |
| Reviewer acknowledges, snoozes or closes | Change local workflow only. Active condition remains visible; new material evidence follows an explicit recurrence/review policy, not silent permanent suppression. |

Before broad auto-association, allow authorized link/unlink and bounded merge/split or an equivalent reviewed regrouping operation, plus candidate accept/reject with reason. Preserve stable old URLs via supersession links, original facts/counts and old review history. Use optimistic revisions and actor/time/reason audit. Repeated processing must respect an exact rejected membership/candidate; materially new supporting evidence may request fresh review rather than silently undoing the decision. Human confirmation records a review judgment, not upgraded source certainty.

An incident should answer **what happened, impact, best-supported explanation, what remains unknown, who owns it, and what safe read-only check comes next**. Prefer a reviewed runbook/source link over an invented fix. Do not treat reviewer feedback as automatic detector training or silently change thresholds.

**Owner slices:** CI-01 transition contract; CI-04 state display; CI-05 audited correction before automatic cross-source merging.

### 12.5 Infrastructure pressure is not the whole failure surface

CPU/memory/disk are useful, but a service can fail with low utilization and few logs. Add a capability matrix tied to `../ops_command_center_v2/DETECTOR_CATALOG.md`; that file explicitly describes proposed capabilities, not delivered adapters.

| Capability | Placement / minimum contract |
| --- | --- |
| User-facing error rate, traffic, latency and availability (D06) | Include in pilot impact context when approved metrics exist. Match error/traffic denominators and counter intervals; derive fleet quantiles from compatible histograms, never average pod p95 values. Use existing approved availability/probe data; do not silently introduce active probing. |
| Workload readiness, unavailable replicas, OOM/restarts (D07) | Reuse current workload evidence; distinguish reported deployment from runtime readiness. Startup inventory is not a new rollout. |
| Queued/stuck/long-running pipelines and tasks (D03) | Track queue/start/finish/last-progress history when retained. Manual approval gates and paused jobs require explicit policy; completed-run failures alone cannot detect work that never finishes. |
| Database/pool saturation, replication lag, queue oldest age/backlog (D09/D10) | Next small read-only detector slice when exporter inputs are approved. Pool pressure can fail an application despite spare CPU; backlog length without age/rates is insufficient. No direct application-table reads. |
| Certificate/token expiry and scheduled-work/backup freshness (D11) | Use safely available expiry/status metadata and expected schedule/grace/timezone. No secret reads, token contents, backup execution or restore action. Recent successful backup metadata does not prove restore capability. |
| DNS/TLS/network or third-party errors | Initially classify retained approved logs/status evidence and mapped dependencies. A source's network failure is not automatically the application network's failure. New probes/providers require separate scope approval. |
| Request/trace and deployment identity | Retain allowlisted request/trace IDs, commit/artifact/version and native run/task IDs when actually exported and approved, with scoped source links. No invented IDs, tracing-platform deployment, new tracing backend or automatic code instrumentation in the MVP. |

The resource-warning MVP must explicitly label unimplemented families as unsupported/unconfigured. They are not hidden implementation promises. Select follow-up work by pilot failure history and available evidence rather than implementing this entire matrix at once. Informational events are context; logging severity is not impact. Capacity warnings need not wait for customer-visible impact, but must say that impact is potential rather than observed.

**Owner slices:** CI-01 capability inventory; CI-04/CI-07 impact context; CI-06 identity fields; CI-09 scoped trend work. New integrations/families need separately approved follow-up slices.

### 12.6 Baselines, maintenance and forecast usefulness

- Define cold-start and warm-up behavior per detector, with minimum elapsed history/coverage and next eligible evaluation time. New services/profiles are not healthy merely because they lack a baseline.
- Compare like with like: entity/incarnation, environment, profile/units, branch/pipeline and relevant load/time window. Do not compare a quiet weekend with weekday peak traffic without labeling that limitation. Start with sustained thresholds; add seasonal baselines only with enough retained evidence.
- A source's hard failure fact or verified current threshold breach is separate from a growth forecast. The direct probe in section 11 shows an already-exceeded storage threshold can correctly have an unknown forecast because history is insufficient.
- Replace reliance on a permanently configured segment string with a tested segment/limit provenance contract: observed capacity changes, resource incarnation, restart/reset/cleanup evidence and a freshness deadline for effective limits. If the needed change signal is unavailable, qualify or disable the forecast. Evaluate only an eligible recent stable segment without hiding the earlier reset.
- Bound forecast horizon and extrapolation relative to observed history. Policy review must select these limits; one hour of samples does not justify an unqualified multi-day ETA. Preserve v1 behavior for old replay, and version any new eligibility/algorithm rules.
- Maintenance windows and planned rollout/cleanup context have owner, scope, UTC interval, reason, expiry and audit. Keep the actual facts and user impact visible; distinguish expected context from observed failure. Snoozing is not maintenance, and neither changes upstream alarms. Reset/warm up a baseline after a material resize/change instead of learning the outage as normal.
- Tune thresholds on one historical period and evaluate on a later withheld period. Compare with a simple static-threshold baseline. Report false warnings per entity-time, missed events, unknown/abstention rate, useful lead time and operator usefulness; score both per evaluation and deduplicated episode as appropriate. Stratify by resource/service, include quiet periods, and keep incomplete truth/horizons explicit.
- Never use later incident closure, a future deployment result or a mapping learned after the evaluation as historical input. Measure source-delay and evaluation-delay contributions to lead time. Human-reviewed candidate usefulness is not proof of causal accuracy.
- Before production warning delivery, agree an acceptable alert budget and minimum useful lead time with owners. No universal precision target or calibrated failure probability is claimed here.

**Owner slices:** CI-01 policy contract; CI-07 implementation; CI-08 explanations; CI-09 held-out validation and owner acceptance.

### 12.7 Incident storms and failure of the monitoring platform

- Size the pilot using expected sources, profiles, series, events/minute, evidence bytes, retention days and concurrent operators. Estimate worst-case request cost, including numerator/denominator queries, count/sample requests, retries and enrichment. For example, four two-request profiles every minute need eight requests/minute before retries; they cannot fit a six-request/minute source budget without slower sampling or separately approved budget changes.
- Keep source/company admission and queue work bounded under a noisy-service storm. Reserve capacity for live collection and freshness checks; throttle backfill/expensive enrichment before starving current facts. Backpressure and cap hits create explicit incomplete/deferred states, never fabricated completeness.
- Set cardinality/series, fan-out/hop, query-range, chart-point, log-context, DB statement-timeout and worker-time limits. One malformed/poison record cannot retry forever or monopolize a queue. A failed enrichment keeps the base failure visible. Persist redacted rejection reasons/counts and bounded recoverable work rather than swallowing errors.
- Measure the actual `:enrich` shared-queue contention. Keep it initially only if investigation/projection/risk work meets the approved lag bounds; split or reserve worker capacity when measured starvation appears. Register new queue names in configuration, supervision and `OperationalMetrics` only if a split is approved.
- Publish independent freshness for the app, collectors and projections. Add an **externally operated heartbeat/watchdog** through the existing approved monitoring stack. In-process `Health.measure/0` alone cannot detect a dead process/host. Protect self-metrics from tenant data leakage.
- Define behavior when PostgreSQL, Oban or the entire app is unavailable: no successful acknowledgement/checkpoint without durable persistence; safe resume/reconciliation after recovery; explicit upstream-retention gaps if data was lost. The browser shows unavailable/stale state or connection loss, not a last green snapshot presented as live.
- Agree recovery time/recovery point objectives and the monitoring plane's failure domain. Test restore and projection rebuild without re-sending historical notifications. Store recovery instructions outside the database/application they repair; approve a separate management location before claiming outage resilience.

**Owner slices:** bounds/admission in CI-03/CI-06; visible lag in CI-04/CI-08; load/outage/restore acceptance in CI-09. Watchdog provisioning is an external owner-approved gate.

### 12.8 Sensitive evidence, authority and retention inheritance

- Approve a permission matrix for summary viewing, raw log excerpts, finding review, membership correction and mapping/policy changes. The current company-membership model does not implement separate roles. Keep configuration changes deployment-owned in the pilot; if raw-log/review access must differ within a company, implement and test that capability check before enabling the feature, or narrow the pilot's membership. Do not fake RBAC in UI controls alone.
- Redaction and HTML escaping are different. Render log text safely; treat snippets, timestamps, identifiers and URLs as untrusted. Derive read-only source links from approved source configuration plus validated identifiers, never arbitrary provider/user URLs or credentials. Add source-link and rendered-error negative tests.
- A new evaluation may embed older evidence. Its content expiry must not silently restart every time it is evaluated: apply the most restrictive applicable contributing-source retention/sensitivity policy. Referencing rather than copying raw content is preferred. Expired/deleted inputs invalidate accessible excerpts and exact replay; only explicitly permitted minimal tombstone/aggregate metadata survives.
- Apply this to timeline/search projections, diagnostic summaries, cached LiveView assigns, snapshots, revisions, notification payloads and any future exports. Already delivered browser/notification content cannot be magically recalled; state that boundary. Backups and approved external sinks need their own retention/access policy.
- Do not add general exports, free-form remote queries, arbitrary runbook execution, source-admin actions or an unrestricted search backend as part of these two pages. A future sanitized incident export is a separate permission/retention feature.

**Owner slices:** CI-01 authority contract; CI-03 storage/expiry; CI-04/CI-05/CI-08 enforcement; CI-09 retention regression.

## 13. Adversarial scenarios and release gates

These scenarios expand section 8. They are **required future tests/probes**, not results already obtained. Keep fixtures deterministic, inject clocks, stub approved HTTP boundaries, and use the approved disposable PostgreSQL role pair for database/race tests.

| ID | Try to break it with | Required result | First owning slice |
| --- | --- | --- | --- |
| R01 | Legacy delivery on with an approved sink; new detector in shadow | New evaluation is visible locally; zero new external messages and no eligible historical backlog after activation. Existing approved alerts still work. | CI-03 / CI-07 |
| R02 | A raw metric creates a risk, which creates an incident, which schedules a risk again | Bounded lineage/input eligibility stops self-amplification; counts and confidence do not grow on retries. | CI-03 / CI-05 |
| R03 | A source clock in the future, nanosecond logs, and a deployment arriving late | Honest timestamp uncertainty, deterministic ordering and historical knowledge cutoffs; no invented causal precedence. | CI-03 |
| R04 | Read page 1; insert a late old event; change a mapping before page 2 | Snapshot generation/cutoff is respected or explicitly invalidated; no silent skips, duplicate logical facts or cross-company cursor reuse. | CI-03 / CI-04 |
| R05 | An old evaluation finishes after a newer unknown/critical result | Old work remains history but cannot move the current head backwards or overwrite human review. | CI-03 / CI-07 |
| R06 | The same resource name exists in two clusters; a pod is recreated | No name-based join or spliced memory history; explicit domain/incarnation/binding is required. | CI-02 / CI-06 |
| R07 | A reviewer splits/rejects a bad association, then collection retries and replay runs | Original facts and URLs survive; exact rejected links do not silently return; concurrent stale edits fail visibly. | CI-05 |
| R08 | A critical service stops emitting all telemetry, then a different member recovers | Last confirmed critical state and unresolved episode remain; unknown coverage and member-specific recovery cannot falsely recover the whole incident. | CI-04 / CI-07 |
| R09 | CPU is low during HTTP failures; CPU is high during successful traffic | Real impact is visible in the first case; the second is pressure/context rather than an invented outage. Unsupported impact checks remain unknown. | CI-04 / CI-07 |
| R10 | Disk is already over its verified threshold with one fresh sample | Current breach is visible immediately under policy even though the forecast is unknown for insufficient history. | CI-07 |
| R11 | Resize, cleanup, restart or effective-limit change happens during a forecast | Old ETA is invalidated; new segment/history requirements apply; replay still reproduces the old version. | CI-07 |
| R12 | Change selector/unit/profile version; one of several profiles repeatedly fails | Old coverage is not reused for the new contract; independent checkpoints, warm-up and shared source budgets remain correct. | CI-06 |
| R13 | Maintenance overlaps actual customer errors and then expires | Facts/impact remain visible; bounded local notification policy is explained; no permanent suppression or automatic healthy status. | CI-07 / CI-08 |
| R14 | Error storm, explosive metric labels, malformed record and slow enrichment | Resource/query/work caps hold, live work retains capacity, base failures remain visible, gaps/deferred work are counted and no raw poison payload leaks. | CI-03 / CI-06 |
| R15 | The same log fact arrives directly, through a log-derived counter, and through a finding | Logical occurrence counts and explanatory support are not tripled; source-qualified run/task IDs cannot collide. | CI-03 / CI-05 |
| R16 | A pipeline waits forever at an approved gate, then another hangs without progress | Policy distinguishes intentional wait from an eligible stuck-work warning, or explicitly reports that required progress evidence is unavailable. | CI-09 / approved D03 follow-up |
| R17 | Source evidence expires while a newer diagnostic summary still contains its text | Sensitive copied content is removed/masked consistently; no retention extension by reevaluation, search projection or cache. | CI-03 / CI-08 |
| R18 | Membership is revoked with an incident open; log text contains HTML/script or an unsafe URL | No further authorized data/action succeeds, rendering stays inert, source links remain approved, and expired/revoked content is not repushed. | CI-04 / CI-05 / CI-08 |
| R19 | Kill the app or database, restore, then resume backfill beside live ingestion | External watchdog alerts; UI cannot claim live health; durable work resumes without false current episodes or historical notification floods, and uncovered history is explicit. | CI-09 |
| R20 | Thresholds look excellent on their tuning period but fail on new workload/history | Held-out/baseline comparison exposes regressions, false/missed/unknown rates and insufficient useful lead time; no calibrated-prediction or paging approval is inferred. | CI-09 |

### Go / no-go checklist

- Before enabling a detector: approved real inputs/identity, correct units/limits, expected cadence, current-breach versus forecast contract, bounded source cost, cold-start/maintenance policy, replay version and clear owner.
- Before broad auto-grouping: deterministic membership rules, lineage/counterevidence, bounded impact, correction/rejection audit and preserved stable references.
- Before active notifications: shadow-isolation and dedup/race tests, useful owner-reviewed results, approved destination/alert budget and an explicit switch from fresh shadow evaluations—not old backlog delivery.
- Before wider production scope: all applicable adversarial cases, agreed query/worker/UI targets measured on the projected pilot volume, permission/retention checks, independent watchdog, and documented restore/rebuild procedure.
- If a prerequisite fails: ship the honest event/evidence workspace and mark that detector/association unknown or disabled. Do not relax safety/coverage criteria to make the dashboard look complete.

The plan is now substantially more complete, but implementation completeness is only established by these tests and owner-approved live contracts. Optional detector families, integrations and advanced baselines remain deliberately deferred until their evidence and value justify them.
