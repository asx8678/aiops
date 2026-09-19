# Deterministic detector catalog

All items are proposed capabilities, not implemented rules. Build only detectors whose inputs have been verified. Threshold examples must be tuned to each company/service/environment; no universal 'healthy' defaults.

## Standard detector contract
Each detector specifies: ID/version, company/target scope, required inputs/profile versions, sample/traffic minimum, source freshness, evaluation clock/window, threshold and persistence, clear/recovery criteria, grouping key, severity reasoning, missing-data behavior, and template fields. Pure evaluation returns data; workers persist and notify separately.

### D01 — Failed pipeline runs
Inputs: selected project/definition run snapshots covering a known time range.
Method: count distinct run identities by result; calculate failure percentage only with a declared denominator and complete enough coverage.
Output: failed runs, partially successful, canceled, successful, in-progress/queued, uncovered history.
Guardrails: task failures and retries do not inflate run count; generic CI health does not imply production downtime. A multi-stage run is not forced into one environment.

### D02 — Repeated pipeline error signature
Inputs: failed task attempts, structured issues, bounded redacted logs.
Method: reviewed exact normalized fingerprint; group by company and meaningful shared tool/code/dependency.
Output: affected distinct runs/pipelines, first/last observed, best failure mechanism, representative steps, unknown details.
Guardrails: normalize UUID/timestamp noise but retain HTTP and tool codes, package/resource identity. Same text is not proven same root cause. Canceled tasks do not create invented failure mechanisms.

### D03 — Queue or duration degradation
Inputs: queued/start/finish times for comparable runs, approved agent/pool identity where available, minimum historical sample.
Method: sustained queue-age threshold or duration departure from comparable branch/pipeline baseline.
Output: delivery bottleneck with affected runs and time basis.
Guardrails: long approved waits/manual gates are not necessarily slow agents. No cancellation or rerun. Mark agent-capacity details unknown unless observed.

### D04 — Application error/critical burst
Inputs: bounded log-backend counts by mapped service/environment and optional request volume; representative samples.
Method: minimum count plus sustained change/baseline/traffic condition, or a reviewed single-occurrence severe signature.
Output: aggregate count for exact window, baseline, affected replicas/services, sampled signatures, redacted examples.
Guardrails: log severity is not impact; parser failure/missing stream is not zero. Sample counts are not total signature counts. Fixed-window revisions prevent overlap double counting.

### D05 — New recurring error pattern
Inputs: fingerprint observations and retained baseline coverage.
Method: signature not previously observed in retained complete-enough history, with minimum recurrence.
Output: 'first observed in retained history', not 'never happened before'.
Guardrails: versioned normalization, retention boundary, sampling blind spots, and changed log formats must be disclosed.

### D06 — Ingress/NGINX/controller degradation
Inputs: actual installed controller's request/status counters, latency histogram if present, readiness/backends, relevant logs.
Method: sustained 5xx proportion and volume; distinguish 502/503/504 patterns and upstream versus controller evidence.
Output: affected host/service/environment, count/rate/traffic, backend availability and candidate dependency/workload evidence.
Guardrails: use matched denominator and correct counter handling; low traffic and health-check traffic require policy. Do not assume all NGINX products/controllers expose the same metrics. A controller error is not proof of application defect.

### D07 — Workload instability
Inputs: watched pod status/termination information, readiness, workload identity, restart series.
Method: restart delta/rate, explicit OOM termination, unavailable replica or rollout timeout conditions.
Output: observed cause/reason from source plus affected workload/version and missing context.
Guardrails: distinguish explicit OOMKilled from inferred memory pressure. A restart spike is not a diagnosis. Startup list snapshots are not new rollouts; watch gaps remain visible. No exec/restart/remediation.

### D08 — Database/storage headroom
Inputs: effective capacity or warning threshold, current storage use/free space, enough historical gauge samples, known growth limits where needed.
Method: sustained positive trend with conditional threshold extrapolation; require freshness and stability.
Output: measured capacity/use, growth over stated window, conditional time-to-threshold, assumptions and missing limit data.
Guardrails: logical DB size is not volume utilization; allocated bytes are not always usable headroom. Account for auto-growth ceilings, resize events, compaction/retention, nonlinear writes, and max quotas. No exact outage promise.

### D09 — Database connection pressure / replication lag
Inputs: exporter/cloud gauges, configured limit, lag/age and freshness.
Method: sustained high utilization or lag above service policy; correlate only to explicitly mapped callers.
Output: measured condition with possible upstream impact and source links.
Guardrails: no direct app table reads. Limits/time units must be verified. High connections can be normal pooling, not a leak.

### D10 — Queue backlog / consumer lag
Inputs: backlog, age of oldest message or lag, enqueue/dequeue rates where available.
Method: sustained backlog/age increase; conditional draining/exhaustion estimate only with relevant rates/capacity.
Output: growth/age, active consumers when observed, mapped dependent services.
Guardrails: avoid a drain-time calculation when net drain is zero/negative. Burst schedules and paused maintenance require context.

### D11 — Expiry and scheduled-work freshness
Inputs: existing certificate-expiry metrics or approved public certificate evidence; expected CronJob/backup schedule and last-success metadata.
Method: explicit expiry horizon or missed expected success plus grace period.
Output: deadline/last success, schedule basis, owner and evidence.
Guardrails: no Secret reads. Do not execute probes, backups, jobs, or restore tests; prefer existing observations. Last successful backup metadata does not prove recoverability. Expected schedules/time zones and suspension state must be known.

### D12 — Monitoring gap
Inputs: configured expected checks, successful query timestamps, source lag, exporter target availability, rejected credentials.
Method: evaluate freshness against expected cadence/grace period and backend responses.
Output: what cannot currently be assessed, affected scope, last known state, and source error.
Guardrails: quiet logs/webhooks are not themselves proof of failure. Distinguish query success with absent series from unreachable endpoint. Do not clear existing critical incidents solely because data vanished.

### D13 — Change-to-symptom correlation
Inputs: observed deployments/config-version metadata, independently detected symptom onset, source/target identity.
Method: versioned temporal/topology rules with multiple candidates and counterevidence.
Output: candidate initiating change, supporting/contradicting facts, unresolved alternatives.
Guardrails: build completion is not deployment; after does not mean because; delayed events recompute final findings. No confidence percentage without a validated calibration model (not planned here).

### D14 — Shared dependency incident candidate
Inputs: several scoped symptoms and an explicitly mapped common dependency plus dependency evidence.
Method: form a parent candidate linking individual issue groups without erasing their scopes.
Output: suspected common dependency, affected services, evidence and alternatives.
Guardrails: similar text/timing alone is insufficient. Never join across companies by default. Do not suppress original upstream paging.

## First implementation selection
Deliver D01 then D02 and local notices. Next add D12 freshness with every source, one D06/D07 basic metric profile, D04 for one backend, D08 for one measured capacity target, and D13. Other detectors require a separate approved task and input validation.
