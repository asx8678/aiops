# Command Center & Troubleshoot — Implementation Plan

Handoff plan for finishing the "one place" operations view. Written 2026-09-27.
Work the phases in order; each task lists files, what to build, and how to verify it.

---

## 0. Current state (already done — read before starting)

| Piece | File | Status |
|---|---|---|
| Analysis + reads | `lib/ops_brain/insights.ex` | Done. Pure analysis (`analyze_storage/1`, `pipeline_health/1`, `attention/6`, `checks/6`, `blind_spots/1`) + scoped reads (`command/2`, `service/4`). |
| Command center page | `lib/ops_brain_web/live/command_live.ex` → `/companies/:id/command` | Done. Attention list, storage forecast, pipeline health, blind spots, service chips. |
| Troubleshoot page | `lib/ops_brain_web/live/troubleshoot_live.ex` → `/companies/:id/troubleshoot?service=&environment=` | Done. Next checks, timeline, metrics, DB/storage, findings, runtime objects, pipeline runs, coverage. |
| Nav / home CTA / CSS | `components/ui.ex` (`areas/0`), `live/portfolio_live.ex`, `priv/static/assets/css/app.css` (`.cc-*` classes at the end) | Done. |
| Demo data | `lib/ops_brain/demo/dataset.ex` | Adds `data.storage` (24h history) on capacity windows; search-indexer pipeline keeps failing. |
| Unit tests | `test/ops_brain/insights_test.exs` | Done (pure functions only). |

**The gap:** the new pages only get storage history, Kubernetes objects and pipeline→service
mapping from **demo-shaped data** (`evidence_items.kind='demo_resource'`,
`observation_windows.data.storage`, `pipeline_runs.data.service`). Real collectors store
this data in different shapes. Phase 1 closes that gap. Phases 2–4 make it production-grade.

### Rules every task must follow (from the codebase)

- All DB reads go through `Tenancy.with_scope(scope, fn -> ... end)`. **Never nest** `with_scope`
  (it rolls back with `:nested_scope`). Call scoped context functions sequentially, or put several
  `Store.rows` calls inside one scope as `Insights.service_rows/4` does.
- Every query is bounded (`LIMIT`, usually ≤ 100–500). Filter in SQL, not after loading everything.
- Missing data is `unknown`, never `normal`/healthy. Do not fabricate values.
- Read-only product: no remediation and no writes to sources.
- Keep analysis functions **pure** (no DB) so they can be unit-tested; put DB access in separate read functions.

### Commands

```sh
cd ops_brain
# compile
mise exec -- mix compile --warnings-as-errors
# tests (disposable DB only)
OPS_BRAIN_DISPOSABLE_TEST=true MIX_ENV=test \
  DATABASE_URL="ecto://ops_brain_runtime@localhost:5432/ops_brain_test_ui_20260920" \
  MIGRATION_DATABASE_URL="ecto://ops_brain_migrator@localhost:5432/ops_brain_test_ui_20260920" \
  mise exec -- mix test
# if you add a migration: migrate the test DB with the migrator URL, then re-apply priv/repo/runtime_grants.sql
# dev server
DATABASE_URL="ecto://ops_brain_runtime@localhost:5432/ops_brain_dev" mise exec -- mix phx.server
# reseed demo after changing dataset.ex (clears demo review state)
DATABASE_URL="ecto://ops_brain_migrator@localhost:5432/ops_brain_dev" mise exec -- mix ops_brain.demo --operator adam --confirm --reset
```

Baseline: 269 tests passing. Finish every task with the full suite green and `mix format`.

---

## Phase 1 — Real data adapters (highest value)

Goal: `Insights` consumes one **normalized shape** per signal. Real collectors and the demo both feed
it through adapters. Create `lib/ops_brain/insights/sources.ex` (`OpsBrain.Insights.Sources`) to
hold the adapters. `Insights` calls the adapters instead of querying demo tables directly.

### Normalized shapes (contract)

```elixir
# Storage series, one per volume
%{"volume" => "orders-postgres", "service_id" => uuid, "size_gib" => number,
  "history" => [%{"hours_ago" => number, "used_gib" => number}]}   # newest hours_ago = 0

# Runtime object
%{"kind" => "Pod" | "Deployment" | "ReplicaSet" | "Event" | "Service" | "Node" | "Database",
  "name" => str, "cluster" => str, "environment" => str, "namespace" => str,
  "status" => str,            # e.g. Running, OOMKilled, ImagePullBackOff, ReadinessFailed, Degraded, Warning, Ready
  "service" => str | nil,     # service_key it belongs to
  "details" => map}           # same keys the Troubleshoot page reads (restartCount, node, readyReplicas, replicas, image, reason, count, connections, max_connections ...)
```

### Task 1.1 — Storage history from Prometheus windows

> **Status: implemented and verified (three review revisions applied).**
> `OpsBrain.Insights.Sources.storage_series/1` (plus the scope-filtered `storage_series/2`
> clause used by `Insights.service/4`) normalizes real bytes windows and demo `data.storage`
> maps into one shape. It is scope-internal like the existing row readers: it runs inside the
> caller's `Tenancy.with_scope` and never opens or nests its own scope. No new config key was
> introduced: the volume is named after the profile id.
>
> Verified semantics:
> - **Series/source identity**: an entry is built only from samples sharing one
>   `(source, series digest)` identity with a binary digest. A service/profile group holding
>   more than one identity (several vector series, a digest change, or two sources scraping
>   the same profile), or samples that are not attributable (missing/non-binary digest), is
>   conservatively emitted with `"mixed_identities" => true`, empty history and no trusted
>   limit — rendered as unknown, never a spliced trajectory or a coalesced nil-digest identity.
> - **Limits**: trusted only from the source config of the identity that produced the samples,
>   when it matches company, bound service and exact profile version with a verified bytes
>   `capacity_policy`. Limits are never resolved across sources (a verified source cannot lend
>   its threshold to another source's samples). Otherwise `size_gib: nil` and
>   `analyze_storage/1` returns `level: "unknown"` with the reason "volume size not verified".
> - **hours_ago / freshness**: `hours_ago` is relative to the newest retained sample (the
>   newest point is always 0, satisfying the contract above); the newest sample's age relative
>   to `now` is carried separately as `"fresh_hours"`. A history older than 6 h, or without
>   at least two distinct times in the recent (6 h) window, supports no growth forecast:
>   rates and `hours_to_full` are withheld and low usage becomes "unknown" with an explicit
>   reason — never a healthy zero-rate claim. Observed usage warnings (percent used) remain
>   factual.
> - **Measured rates only**: a recent or baseline rate is claimed only from at least two
>   distinct times in that window. A missing baseline stays nil (not measured): it can neither
>   trigger an abnormal-jump claim against a fabricated flat baseline nor a "normal growth"
>   verdict (level stays "unknown" unless measured usage already warrants warning/critical).
>   A genuinely measured flat baseline still flags jumps, and nullable projections no longer
>   crash the level computation (boolean-safe `is_number` guards replace `hours && ...` in
>   `or` chains).
> - **Demo passthrough**: demo entries keep `fresh_hours: 0` (an offline snapshot's history is
>   relative to its own window), so the scripted demo output is preserved: reporting-postgres
>   stays critical at ~16.7 h.
> - **Views**: both LiveViews, the sparkline and `checks/6` were audited for nil numbers and
>   minimally fixed; unknown storage renders as "unknown" (badge, size, percent), never healthy.
>
> Verified with: pure tests (unknown size, mixed/unattributable identities, sparse recent
> window, two-point missing-baseline, flat low, declining, insufficient and stale histories,
> ranking) and DB integration through the real `Insights.command/2` / `Insights.service/4`
> paths: 24-hour growth jump, tenancy isolation, missing/unverified/mismatched limits, hourly
> downsampling with future/malformed samples, two series at one timestamp, a series digest
> change, missing series digests, two sources sharing a profile with differing verification,
> re-based `hours_ago` with a 2 h-old latest sample, an 8 h-old stale history, and the demo
> regression. Direct probes of the reported crash inputs return unknown/ok without
> BadBooleanError. Full suite 294 passed; `mix compile --warnings-as-errors` and
> `mix format` clean. No blockers. (Known conservative trade-off: a cleanly relabeled volume
> is treated as mixed unknown rather than splicing or selecting one identity.)

- Real data: `observation_windows` with `kind='prometheus'`, `profile="<profile.id>:v<version>"`,
  `data.samples=[%{"value" => bytes, "timestamp" => unix, "series" => ...}]`, `data.unit="bytes"`,
  `service_id` set. See `OpsBrain.Evaluations.capacity/3` for how it is read today.
- Build `Sources.storage_series(now)`: for windows with `data.unit == "bytes"` in the last 24 h
  (SQL: `window_end > now - interval '24 hours'`, `LIMIT 2000`), group by `(service_id, profile)`,
  downsample to one point per hour (last value in each hour), and convert bytes→GiB.
- `size_gib`: use the matching `capacity_policy.effective_threshold` (bytes) from the source config
  (`OpsBrain.SourceConfig`). If the limit is missing or `limits_verified != true`, set `size_gib: nil`.
  In that case `analyze_storage/1` must return `level: "unknown"` with the reason "volume size not verified".
  Add that clause and a unit test for it.
- `volume` name: the profile id, or a new optional `profile.volume_name` config key. If you add the
  key, document it in `config/sources.prepared.json` and `docs/ONBOARDING.md`.
- Demo adapter: `Sources.storage_series/1` also returns the existing `observation_windows.data.storage` maps.
- Change `Insights.storage_risks/3` and the storage part of `service/4` to use `storage_series`.
- **Accept when:** a test inserts 24 hourly Prometheus windows with a growth jump for a scoped
  company, and `Insights.command/2` returns one storage risk with `abnormal: true` and the correct
  `hours_to_full`. Demo output is unchanged (reporting-postgres critical, ~16.7 h).

### Task 1.2 — Kubernetes objects from `kubernetes_cursors`

> **Status: implemented and verified (revised after adapter review).**
> `OpsBrain.Insights.Sources.resources/2` normalizes real `kubernetes_cursors` objects and
> the retained demo evidence into the contract shape, and `Insights.resource_rows/2`
> delegates to it. Scope-internal like the other reads: it runs inside the caller's
> `Tenancy.with_scope` and never opens one.
>
> Verified semantics:
> - **Cursor trust**: a cursor is used only when the trusted config matches kind
>   "kubernetes" and the cursor's company, the stored scope digest still matches
>   (endpoint/namespace/approved IPs/credential), `observed_at` is neither in the future
>   nor older than the collector's freshness bound (interval x resources x 3), and the
>   inventory is `coverage == "complete"` with no gap or error. Stale, gapped, errored,
>   partial, future-dated and scope-mismatched cursors are omitted, never rendered as
>   health (missing parents therefore cannot aggravate misattribution).
> - **Attribution is evidence-driven only**: the trusted `service_id` binding pins the
>   environment and cluster for Deployment-name matches; Pods resolve through the single
>   owner UID chain Pod→ReplicaSet→Deployment, Events via `target_uid`. Unresolved,
>   ambiguous or foreign references stay unattributed — never silently re-attributed to
>   the bound service — and without a bound instance no location is inferred from
>   whichever candidate happens to be unique. Known limitation (documented in the
>   adapter): collectors configured for pods only, or objects without a resolvable owner
>   chain, remain unattributed and surface in command attention without a service link.
> - **Identity end to end**: every real object carries its uid and collector source id;
>   unattributed objects keep the trusted binding's cluster/environment as their location
>   (without claiming a service). Real objects are never deduplicated against each other —
>   distinct sources, environments and UIDs are distinct observations even with identical
>   display names; demo fixtures step aside only for a real object with the same explicitly
>   scoped identity (kind/name/cluster/environment/namespace), via a linear map set.
> - **Attention scopes**: runtime attention groups attributed objects per service and
>   environment, and unattributed ones per trusted location (cluster/environment) plus
>   collector source — never a global nil bucket — so unrelated sources neither merge nor
>   suppress each other's items.
> - **Not-ready pods**: a reported Running phase with explicitly not-ready containers
>   renders NotReady (covered in command attention and troubleshoot), never healthy Running.
> - **Instance-exact service views**: `Insights.service_rows` filters runtime objects by
>   cluster AND environment AND (for real objects) the exact attributed instance id, so
>   prod/staging namesakes on one cluster never leak across troubleshoot pages.
> - **Real anomalies reach attention**: unhealthy pods (status outside Running/Succeeded;
>   OOMKilled critical, others warning), Warning events and degraded workloads are wired
>   into `attention` grouped per service/environment (one incident = one item; degraded
>   workloads are suppressed when their pods are already flagged). Command-center read
>   and the demo SQL both stay bounded to node/database health plus abnormal runtime
>   signals; demo fixtures materialize their declared service (workload label / event
>   involved object) so their attention items link correctly.
> - **Coverage note**: the Command center states node and database health is not collected
>   (appearing only from stored evidence), accurate for both real and demo data.
>
> Verified with DB tests (OOMKilled pod + Warning event via the real `Insights.service/4`
> path with the OOM suggestion; command attention items with service/environment metadata;
> shared-namespace attribution; same-cluster prod/staging namesakes with IDENTICAL object
> names, cluster and namespace (different UIDs) each retaining exactly their own objects;
> two sources/clusters with same-named unattributed anomalies neither vanishing nor
> cross-suppressing each other's degraded workloads; explicitly not-ready pods rendering
> NotReady in attention and troubleshoot; tenant isolation; broken/ambiguous owner chains
> and missing bound instance staying unattributed while still surfacing unattributed
> anomalies with retained location in command attention; missing config, stale, gapped,
> errored, partial, future-dated and scope-mismatched cursors omitted; demo regression
> incl. Node/DiskPressure, Database 492/500, inventory-api OOMKilled pod and Warning event
> attention items with no duplicate workload spam) plus LiveView render tests (OOMKilled
> pod, Warning event and suggestion on Troubleshoot; the attention item with troubleshoot
> link and the coverage note on the Command center). Full suite 307 passed;
> `mix compile --warnings-as-errors` and `mix format` clean. No blockers.

- Real data: `kubernetes_cursors.data["objects"]` (map uid → object), one row per `(source_id, resource)`.
  Object shapes come from `OpsBrain.Workloads.sanitize/3`:
  - Pod: `containers[].restarts/ready/termination.reason`, `phase`, `ready`, `owners`.
  - Deployment/ReplicaSet: `replicas`, `ready_replicas`, `available_replicas`.
  - Event: `reason`, `type`, `count`, `target_uid`, `target_kind`, `last_seen`.
- Build `Sources.resources(now, service_key \\ nil)`:
  - Pod `status`: first container `termination.reason` if restarts > 0 (e.g. `OOMKilled`), else
    `Running` if `ready`, else `phase` (or `NotReady`). `details.restartCount` = sum of restarts.
  - Deployment `status`: `Available` if `ready_replicas == replicas`, else `Degraded`.
  - Event `status`: its `type` (`Normal`/`Warning`); `details.reason`, `details.count`.
  - `service`: map the source's `service_id` (from source config) → `service_instances.service_key`.
    Where a namespace holds many services, match Deployment name == service_key and follow
    `owners` Pod→ReplicaSet→Deployment. Map events via `target_uid`.
  - `cluster`/`environment`: from the service instance `target` prefix and its environment.
- Keep the demo adapter (`evidence_items.kind='demo_resource'`) and concatenate both.
- Change `Insights.resource_rows/2` to call `Sources.resources/2`.
- Note: real collectors do not collect Nodes or Databases yet. The attention list must simply
  omit those items, not claim they are healthy. Add a coverage note on the Command center:
  "Node and database health not collected".
- **Accept when:** a test seeds `kubernetes_cursors` with one OOMKilled pod and one Warning event for a
  mapped service. The Troubleshoot page shows both, and `checks` includes the OOMKilled suggestion.

### Task 1.3 — Pipeline → service/environment mapping from deployment evidence

> **Status: implemented and verified (two review revisions applied).**
> `Insights.pipeline_rows/3` maps each run through its deployment evidence
> (`kind='deployment'`, matched by company, source and `data.run_id`, unexpired AND
> received_at <= now AND occurred_at <= now — future-received or future-occurred evidence
> cannot map a run) to the targeted service instance: service group = evidence
> service_key, fallback `data.service` (demo-shaped) only when NO valid deployment
> mapping exists at all (a run deployed to other services never falls back to its name),
> last `"definition <id>"`. Runs received or finished in the future are excluded
> (finish_at IS NULL unfinished runs are retained). Each run carries `environment`
> (latest deployed environment) and `environments` (all deployed environments of the
> mapped service).
>
> Selection semantics: the troubleshoot (service) query aggregates ONLY the requested
> service (no pre-filter target cap — a run with more than 20 deployment targets still
> maps to its selected service; regression proves a 25-target run maps to the
> oldest-evidence service that any first-20 cap would drop) and applies service AND
> environment selection in SQL BEFORE the bounded LIMIT 300. Regressions: 320 newer
> unrelated runs and 320 newer staging-deployed runs of the SAME service cannot hide the
> selected older prod run. The command query keeps a bounded global read (300-run
> materialized CTE, received/finish time guards, final LIMIT 500) with a documented
> deterministic per-run display cap (latest received_at, then service_key) that is never
> applied to the service query.
>
> Labels: the Troubleshoot pipeline runs table shows the deployed environment(s) per run,
> or an explicit "environment unknown" badge for runs without evidence (LiveView test).
> Unmapped CI-only runs group under `"definition <id>"` with an explicit "CI-only" badge on
> the Command center (LiveView test). Fully unattributed runs are NOT placed on service
> pages (that would fabricate attribution — a deliberate deviation from the plan's literal
> parenthetical, as accepted in review); they stay visible in the command panel only.
>
> Verified with DB tests: prod/staging deployments land only on their own pages;
> `data.service` fallback with "environment unknown" only when truly unmapped; unmapped
> run groups under "definition 7" with `ci_only: true` and never reaches a service page;
> tenant isolation across two companies; 320-run and 320-staging-run regressions;
> expired / cross-source / future-received / future-occurred evidence never map a run;
> future-finished runs excluded while unfinished (NULL finish) runs stay; a 25-target
> run maps to the service sorting after any first-20 cap; one run deployed to two
> services appears once per service group; one run deployed to prod+staging of one
> service stays a single row visible on both pages without double-counting; demo
> regression keeps all groups, predicted == 4, 84066 staging-only and 84063 everywhere.
> LiveView tests cover prod/staging separation, environment/unknown labeling and the
> CI-only badge. Full suite 321 passed; `mix compile --warnings-as-errors` and
> `mix format` clean. No blockers.

- Today `pipeline_rows/1` groups by `data->>'service'` (demo only). Real runs are linked to services
  through `evidence_items.kind='deployment'` (`data.run_id`, `data.target_id` → `service_instances.id`).
  See the query in `OperationsLive.pipeline_runs/1`.
- New grouping key: the service_key from deployment evidence. Fallback: `data.service`. Last
  fallback: `"definition <id>"`.
- Carry `environment` on each run so the Troubleshoot page shows only runs for the selected
  environment (plus unmapped CI-only runs, labelled as such).
- **Accept when:** a test with two runs deployed to staging and prod shows each on the correct
  Troubleshoot page, and a run with no deployment evidence groups under `definition <id>`.

---

## Phase 2 — Prediction quality

### Task 2.1 — Configurable thresholds

> **Status: implemented and verified.** `OpsBrain.Insights.thresholds/0` returns the
> effective prediction thresholds: a `@default_thresholds` module attribute map merged
> with `config :ops_brain, OpsBrain.Insights` at read time. All ten listed values are
> configurable with defaults preserved exactly — storage: warn_pct 85, crit_pct 95,
> warn_hours 72, crit_hours 24, abnormal_factor 3, recent_window_hours 6,
> min_abnormal_rate_gib_h 0.25; pipelines: window 10, streak_critical 2,
> last5_critical 3. Every storage/pipeline comparison (levels, hours-to-full,
> abnormal-jump factor and minimum rate, recent-window, pipeline window/streak/last5,
> and the checks resize suggestion) reads from the threshold map. The accessor is
> hardened: malformed top-level config (booleans, numbers, strings, tuples) and
> non-keyword lists never raise — they simply yield defaults; group and value lookups
> accept maps and keyword lists with atom or string keys at both levels. Missing,
> non-numeric or out-of-range values fall back per key (percentages within (0, 100],
> hours positive, abnormal_factor > 1, integer run windows) and unknown keys are
> ignored. A failing streak below the configured critical threshold is always a
> warning (streak > 0), never 'recovered'; the previous-five baseline comparison is
> capped at five runs even when the window grows. Boundary tests cover every default
> comparison including exact representable equality (85.0/95.0 at size 100), hours
> exactly at 24/72, ratio exactly 3.0 vs 2.9, minimum rate exactly 0.25 vs 0.26,
> recent-window edge at hours_ago 6/7, pipeline window at exactly 10 runs,
> streak/last5 boundaries, raised-threshold no-false-recovery and the >10-window
> prior-five cap. Sync override tests (restoring prior env) verify every configurable
> value flips an input whose default decision differs, map/string-key and malformed
> configs, and full fallback on invalid values. Full suite 338 passed on three
> consecutive runs with complete output retained (the earlier unexplained single
> failure never recurred across five subsequent runs); `mix compile --warnings-as-errors`
> and `mix format` clean. No blockers.

Move the magic numbers in `Insights` into one module attribute map, overridable with
`config :ops_brain, OpsBrain.Insights, ...`:
storage `warn_pct 85`, `crit_pct 95`, `warn_hours 72`, `crit_hours 24`, `abnormal_factor 3`,
`recent_window_hours 6`, `min_abnormal_rate_gib_h 0.25`; pipelines `window 10`, `streak_critical 2`,
`last5_critical 3`. Add unit tests for the boundary values.

### Task 2.2 — Growth-rate robustness

> **Status: implemented and verified (revised after review).** `slope/2` now fits a
> least-squares (OLS) slope over the window's actual time points (x = negative
> hours_ago, y = used_gib): every sample weighs in equally, which reduces the influence
> of a single glitchy endpoint compared with a two-point difference — OLS is not an
> outlier-resistant estimator, only less endpoint-sensitive here; with two points it
> degenerates to the exact endpoint rate and identical times still yield 0.0. Segment
> reset: a RELATIVE drop in used space greater than 5% between consecutive samples
> (prev > 0 and prev - curr > 0.05 * prev, measured against the previous used value,
> never against the configured volume size) marks a cleanup/resize — the analysis
> (rates, projectability, unprojected fallback) uses only samples after the LAST such
> drop and prepends the exact reason "usage dropped (cleanup/resize) — history reset",
> while the sparkline keeps the full retained history. Unknown handling, measured-rate
> requirements (>= 2 distinct times), stale/insufficient semantics and all Task 1.1/2.1
> source-identity safeguards are untouched. Tests: outlier endpoint (LSQ reads 178/28
> ~ 6.36 GiB/h where the two-point difference would read 9.33), cleanup drop (post-drop
> segment rate 1.0 GiB/h, reset reason present, full sparkline), the exact relative
> boundary (100 -> 95 is exactly 5%: no reset; 100 -> 94.9 resets), the review's probe
> case (size 1000 with a 6% used drop at low utilization: reset with post-cleanup rate
> 1.0), identical history under different capacities (size 1000 vs 200: identical reset
> reasons and rate — cleanup detection is capacity-independent), multiple drops (only
> the segment after the LAST drop feeds the rate), flat series (exact 0.0 rates) and
> sparse two-point windows (exact endpoint rate). Demo behavior is numerically
> unchanged: the demo histories are piecewise linear (LSQ equals the endpoint slope)
> and contain no drops — reporting-postgres stays critical at ~16.7 h and the full demo
> regression passes. Root-caused and fixed the previously unexplained suite flake: the two new LiveView test files called SourceFixtures.config/3 (which sets :collection_enabled and :sources globally) without registering on_exit(&cleanup/0), so under some test orders demo_live_test saw collection_enabled true; reproduced with --seed 960057 (344/345, demo no-live-side-effects refute failed), fixed by registering the cleanup in both setups, and the same seed plus normal runs pass 345/345. Full suite 345 passed with complete output retained;
> `mix compile --warnings-as-errors` and `mix format` clean. No blockers.


`slope/1` uses only the endpoints, so one outlier can skew it. Replace it with a least-squares slope over
the window. Treat a drop in used space (cleanup/resize) as a segment reset: analyze only the samples
after the last drop greater than 5%, and add the reason "usage dropped (cleanup/resize) — history reset".
Tests: outlier sample, cleanup drop, flat series.

### Task 2.3 — Pipeline flakiness & duration

> **Status: implemented and verified (revised after review).** `pipeline_health/1` adds `flaky: true` when the
> results alternate — at least 3 adjacent result changes between two RECOGNIZED completed
> outcomes (succeeded/failed/partiallySucceeded/canceled) inside the configured window;
> nil, arbitrary strings or any run whose explicit status is non-completed
> (notStarted/inProgress/postponed/cancelling) never count — with the exact reason
> "flaky: alternating results". The flaky clause sits after the failure clauses (critical
> streaks, last5-critical, latest-failed, failing-more-often) and before the ok fallback:
> failure reasons are never masked, but an alternating pipeline whose latest run succeeded
> — which would otherwise read "recovered" — is always a warning. Outcome honesty: every
> run's outcome is normalized from BOTH status and result (run_outcome/1: an explicit
> non-completed status is unknown even when a residual result string is present; runs
> without a status keep the legacy result-only behavior, documented for pure fixtures).
> A missing, unrecognized or non-completed LATEST outcome yields level "unknown" ("latest
> run result unknown"), a degraded latest result (partiallySucceeded/canceled) yields a warning
> ("latest run <result>") — never success — while concrete historical failure evidence
> (streaks, last5-critical) still wins. The Command center shows a "flaky" badge and the
> Troubleshoot "Last pipeline" card shows the result badge, the flaky badge and the
> reason, so flakiness stays visible even when the failure reason wins.
>
> Duration trend: the `pipeline_runs` table has a `finish_at` column and the Azure
> collector retains `start_at` (normalized from `startTime`) inside the run `data` — so
> durations ARE available and the trend is implemented rather than skipped:
> `pipeline_rows` extracts `duration_seconds` in Elixir from the retained start (only a
> COMPLETED run with a parseable start before its finish; missing, malformed,
> non-completed-status or inverted starts stay unknown, never fabricated), and `pipeline_health` compares the
> median of the last five runs against the median of the previous five — a half with
> fewer than two timed runs has no median. When the last-five median is at least 1.5x the
> previous five, the reason gains "run durations up 1.5x (median last 5 vs previous 5)"
> (one decimal — never inflated to 2x), the group map carries usable fields
> (`last5_median_seconds`, `prev5_median_seconds`, `duration_ratio`), and an otherwise
> passing pipeline is a warning, never healthy; failure levels are never lowered.
>
> Tests: flaky boundaries at exactly three changes and at four (exact reason, warning,
> latest-succeeded never healthy), critical priority, unknown/malformed outcomes never
> counting as changes, missing/unrecognized/in-progress latest never healthy with
> historical failure evidence preserved, contradictory non-completed status + residual
> succeeded/failed (no false streak, no false failure, no flakiness, evidence still
> visible), degraded latest never implying success, the 1.5x median boundary and one-decimal display with usable fields, DB integration through
> the real Insights.command/service read (retained data.start_at durations reaching the
> trend at 2.0x; malformed/missing/unfinished/inverted starts yielding nil durations with
> no fabricated trend), and LiveView assertions for the flaky badge and duration reason on
> the Command center plus the flaky badge beside the winning failure reason on
> Troubleshoot. Demo change (documented, honest): demo groups whose latest run is
> partiallySucceeded/canceled now read warning instead of ok, so the verified demo
> predicted count grew from 4 to 12 — no demo group is flaky and no CI-only labels changed.
> Full suite 362 passed with complete output retained
> (mix test --warnings-as-errors: the two reported unused-variable warnings in test files
> are removed); `mix compile --warnings-as-errors`
> and `mix format` clean. No blockers.

- Add `flaky: true` when the results alternate (≥ 3 result changes in the last 10 runs), with the reason
  "flaky: alternating results".
- If `pipeline_runs` has start/finish times, add a duration trend (last 5 vs previous 5 median, flag ≥ 1.5×).
  Check the schema first. If there is no start time, skip this and note it here.

### Task 2.4 — Other saturation signals (only where data exists)

> **Status: implemented and verified (two review revisions applied).** The approved storage
> analysis is extracted into the shared pure `analyze_growth(series, limit, unit)/3`:
> series is `{"history" => [{"hours_ago", "value"}], "fresh_hours", "mixed_identities"}`,
> limit is the verified limit in the value's own unit (or nil), unit is the label interpolated
> into every reason. ALL semantics are the growth helper's — mixed identities unknown,
> unverified limit unknown ("verified limit unavailable"; storage keeps its pinned "volume size
> not verified" wording over the same result), measured-rate and stale/insufficient rules,
> relative >5% drop segment reset, OLS slope, threshold map. `analyze_storage/1` is a
> compatibility wrapper (verified by a dedicated equivalence test and the whole existing
> storage suite).
>
> Signal attribution (trusted config, not unit inference): the optional reviewed key
> `saturation_signal` (prometheus profiles only) requires a COMPATIBLE profile shape —
> connections => gauge + unit "count", memory_working_set => gauge + unit "bytes" — and
> incompatible markers are REJECTED by validation (never silently relabeled: a bytes gauge
> tagged connections cannot be routed as storage, a count tagged memory cannot yield pod-memory
> guidance). Validation is wired through the actual loader key list, the JSON loader and
> SourceConfig; config/sources.prepared.json carries a safe disabled illustrative
> connections-classified example (nothing enabled, limits_verified false, no fabricated limits)
> and docs/ONBOARDING.md documents the contract. Profile names are never parsed for meaning.
> Without the marker a verified count limit analyzes as a GENERIC "count" saturation (no
> connection wording, no pool guidance — queue-depth negative regression); with
> `memory_working_set` a bytes profile is read by `Sources.memory_series/1`
> (bytes->GiB like storage, EXCLUDED from the storage series so it is never double-labeled a
> volume, deduplicated to the freshest profile version like storage/count) and analyzed by
> `Insights.memory_risks/2` through the shared helper with its own pod-memory check.
>
> Identity safeguards: signal classification resolves ONLY when every trusted identity
> contributing samples to a group agrees (validated configs make unit disagreement impossible,
> so a conflict requires a unit/classification mismatch between a valid config and its retained
> windows — regression included: such a group renders the shared unattributable unknown with no
> signal and no guidance, regardless of row order). Count limits resolve only from the
> identity-matching verified COUNT policy (bytes policies never lend); mixed digests stay
> unattributable; fresh_hours staleness and measured-rate rules unchanged.
>
> Views: Troubleshoot Database & storage panel renders each saturation risk nil-safely (level
> badge, fmt value / fmt_size limit, fmt_percent; LiveView regressions for unverified and mixed
> signals prove no crash and no NaN). The Command center has a Saturation panel
> (id=saturation-risks) with level badge, meter only for numeric percent, nil-safe value /
> limit / percent / rate / hours, reasons and a Troubleshoot link when service+environment are
> known; a count-only LiveView regression seeds classified connections critical (480/500, meter,
> link) plus an unverified queue-depth unknown row ("verified limit unavailable", no meter).
> Memory evidence distinction recorded: the Kubernetes collector retains no memory samples, but
> the Prometheus collector CAN collect memory bytes gauges — memory is supported via the
> classified path, previously it was supported-but-unconfigured rather than uncollectable.
>
> Tests: pure `analyze_growth/3` (unverified limit, measured count growth in its own unit,
> mixed identities, storage-compatibility equivalence); DB integration (verified classified
> connections critical end to end with pool-size check; unverified/no-config/bytes-policy
> unknown with no check; generic unclassified count; classified memory separately from storage
> with its own check; conflicting classifications unattributable; memory version dedupe to the
> freshest; mixed digests; tenant isolation; invalid marker AND incompatible unit/semantics
> rejected by validation; prepared JSON loader reads the marker with the disabled illustrative
> source); LiveView (troubleshoot verified/unverified/mixed; command count-only critical +
> unknown). Demo unchanged (no count windows; predicted count still 12). Full suite 381 passed
> with `mix test --warnings-as-errors` and complete output retained;
> `mix compile --warnings-as-errors` and `mix format` clean. No blockers.

Using the same "recent vs baseline" helper, generalize `analyze_storage` into
`analyze_growth(series, limit, unit)` and use it for:
- DB connections vs max (Prometheus profile with `unit: "count"` + limit),
- pod memory working set vs limit (restarts approaching OOM).
Every signal needs a verified limit; without one, return `unknown`.

---

## Phase 3 — Make predictions actionable

### Task 3.1 — Persist predictions as findings (opt-in)

> **Status: implemented and verified (four review revisions applied).** `OpsBrain.PredictionWorker` persists critical
> storage, saturation and pipeline predictions as findings through the existing pipeline
> (`Evidence.save` + `Issues.record`). Pipeline predictions read from a persistence-specific SQL that retains each run's
> ACTUAL deployment targets (instance id, environment, service) from the deployment evidence, and partition by exactly
> (source, definition, environment, target instance) BEFORE computing health — never name-aggregated, never re-resolved by
> name/environment lookups. Prod-only failures with a healthy staging history persist only the prod finding; a staging
> recovery freezes the staging group while the still-critical prod group keeps refreshing; same-name/same-env instances in
> distinct clusters (eu vs eu-west prefix collision) partition to their own actual targets; identical definition ids from two
> sources stay distinct groups with per-source evidence provenance. CI-only/unmapped runs persist under their own explicitly
> unscoped (source, definition) identity with a nil structured target and never appear on any service page. Fingerprint AND
> occurrence identities are the SAME canonical tuple — storage `{:storage, source, instance, environment, volume}`,
> saturation `{:saturation, source, instance, environment, volume, signal}`,
> pipelines `{:pipeline, source, definition, environment, instance}` — and occurrence keys digest that tuple
> (`Store.digest/1`), never concatenated delimiter strings. `service_instance_id` is carried through the storage/count/memory
> risk maps and the pipeline partitions (no name re-resolution), and the structured `prediction_target`
> (service_instance_id/environment/target) is persisted in BOTH the evidence data AND the issue group data
> (`Issues.upsert_group` writes it whenever the record identity carries the key), so `Insights.service/4` matches
> worker-created predictions by exact instance+environment — the same-cluster prod/staging case and cluster-prefix collisions
> cannot leak, and other findings keep the legacy scope filter untouched. Reads run under the smallest VALID trusted config;
> each prediction persists in the contributing source's transaction (series identity source for storage/saturation, partition
> source for pipelines), verified by per-source evidence provenance. Unexpected persistence failures surface for Oban retry;
> the switch requires the literal `true` in run, perform and scheduler (malformed truthy values fail closed, tested). Worker
> tests now number 16 — including critical saturation persistence (previously untested end to end), same-env two-cluster
> partitioning with exact stored/read identity, identical definitions across two sources, per-target pipeline recovery
> (frozen staging group while prod refreshes), and same-cluster staging/prod read isolation. Full suite 397 passed with
> `mix test --warnings-as-errors`; `mix compile --warnings-as-errors` and `mix format --check-formatted` clean. No blockers.

When a storage or pipeline risk reaches `critical`, record it through the existing pipeline so it shows
in Investigations and can notify: `Evidence.save` + `Issues.record` with fingerprint
`prediction:storage:<volume>` / `prediction:pipeline:<name>`. Run it from a new Oban worker,
`OpsBrain.PredictionWorker`, every 5 min, disabled by default behind a config switch like the other
workers (see `scheduler.ex`, `maintenance_worker.ex`). The worker must be idempotent: the same risk
updates the same group.
- **Accept when:** a worker test shows that two runs create one issue group, and a recovered risk stops refreshing `last_seen`.

### Task 3.2 — Link attention items to their investigation

> **Status: implemented and verified.** Finding-derived attention items now carry `group_id`, and the Command center
> renders an Investigate link plus the Troubleshoot link; every finding card on a Troubleshoot page links to its
> focused investigation. Both link to `/companies/:id/investigations?focus=<group_id>#groups-<group_id>` — the query
> opens the finding's evidence workspace and the fragment is the streamed finding card's own id, so a full page load
> scrolls straight to it. `OperationsLive` accepts the focus only when the id belongs to a finding in the current
> authorized, filtered, bounded (first 100) set: nonexistent ids, another company's group ids, and groups pushed off
> the loaded page are silently ignored without a query, never leaking whether any other group exists; a malformed or
> over-long value is dropped before any lookup. The focus is one-shot, so the existing "evidence closes on refresh"
> semantics are unchanged. Navigation tests cover the actual opened evidence and anchor target from a focus deep link,
> both new page links, nonexistent and foreign-company focus ids, and the bounded-page case. Full suite 403 passed
> with `mix test --warnings-as-errors`; compile and format clean. No blockers.

Attention items built from findings should carry `group_id`. Add
`/companies/:id/investigations?focus=<group_id>` handling in `OperationsLive` (scroll to and open that
finding's evidence), and link to it from both new pages.

### Task 3.3 — Environment filter on the Command center

> **Status: implemented and verified (revised twice after review).** `?environment=prod|staging|dev` (default all) drives the same
> select as `OperationsLive`; changing it patches the URL and the 30 s auto-refresh preserves the selection. The
> selection is applied IN SQL BEFORE every bounded read — services and windows (`Services.overview/windows`),
> capacity evaluations (before the record limit), the storage/count/memory series INCLUDING demo snapshots
> (`Sources.*_series` and `demo_series`, before the 2000-window and demo caps; demo snapshots carry their service
> instance, so the same identity join applies and only truly unmapped snapshots stay outside selected views) and the
> deployment runs behind pipeline health (`command_pipeline_rows`: both the EXISTS run filter AND the per-service
> lateral mappings are env-filtered, so a mixed-service multi-environment run groups only under its actual
> environment's service; All keeps the shared aggregate read unchanged). Regressions pin 301 newer staging runs and
> 2000+2000 newer staging windows against prod (the prod view keeps its full pipeline health and 24-point
> histories), the mixed-service run (prod view shows only the prod-deployed service's group, staging only the
> staging-deployed one), and the Demo seed (prod view keeps the reporting-postgres critical volume, staging does
> not, All unchanged — asserted at the read level and on the rendered command page). Kubernetes cursors attribute
> each object's environment in Elixir — the one bounded read where the selection cannot precede the cap — so the
> filter applies to the attributed objects. Finding provenance resolves against the FULL authorized identity set
> (never the environment-filtered one): a worker prediction's structured `prediction_target` must match an existing
> instance whose real environment agrees with the claim; an explicit nil target (CI-only) or a disagreement stays
> unknown. Legacy scopes match by EXACT cluster segment — substring inference cannot resolve cluster-prefix
> collisions — and an ambiguous or missing mapping stays unknown in every selected view (appearing only under All,
> unassigned). Invalid URL values fall back to All in the LiveView; an invalid read-level argument fails closed with
> `{:error, :invalid_environment}`. Full suite 416 passed with `mix test --warnings-as-errors`; compile and format
> clean. No blockers.

Add `?environment=prod|staging|dev` (default all) with the same select used in `OperationsLive`.
Filter attention, storage and pipelines by it.

---

## Phase 4 — Tests, docs, cleanup

### Task 4.1 — LiveView tests

> **Status: implemented and verified.** All five cases have passing behavioral assertions in the two page test files,
> reusing the existing fixtures and demo seed rather than duplicating them: (1) membership — a member renders each
> page (`#attention`, `#service-picker`) while a non-member operator is redirected to `/sign-in` at mount for both
> routes; (2) no data — a data-free company renders every designed empty state (attention "Nothing flagged right
> now" with "missing data is not the same as healthy", "No storage history", "No pipeline runs", troubleshoot "No
> service selected") with zero fabricated rows and no healthy claims ("Everything is healthy", "All systems
> operational", "all clear" refuted); (3) demo data — the seeded demo company's command page shows
> reporting-postgres as a critical storage item flagged "abnormal growth", the search-indexer pipeline as a
> critical failing pipeline, and the stale `DEMO · nw-eu-staging · loki` source in Blind spots ("All sources
> reporting" refuted); (4) the troubleshoot service picker `phx-change="pick"` patches the URL (assert_patch to
> `?environment=staging&service=storage-prod`) and the page then renders the picked instance; (5) unknown
> `service`/`environment` params fall back to the first production service without crashing, and the bogus value
> never renders. No regressions found — no product changes were needed. Full suite 423 passed with
> `mix test --warnings-as-errors`; compile and formatting clean. No blockers.

`test/ops_brain_web/command_live_test.exs` and `troubleshoot_live_test.exs`. Follow
`demo_live_test.exs` / `operations_live_test.exs` for auth + fixtures (`test/support/fixtures.ex`).
Cover these cases:
- the page renders for a member, and a non-member is redirected;
- no data → empty states (no crash, no "healthy" wording);
- demo data → reporting-postgres flagged abnormal, search-indexer critical, the stale loki source listed as a blind spot;
- troubleshoot service picker `phx-change="pick"` patches the URL;
- an unknown `service`/`environment` param falls back to the default service.

### Task 4.2 — Make the Command center the landing page

> **Status: implemented and verified.** `PortfolioLive.load/1` redirects a resolved workspace straight to
> `/companies/:id/command`; only the workspace-error state renders on `/` (misconfigured or ambiguous membership, or a
> revoked workspace), with the sign-in redirect for invalid sessions and the OperatorAuth event hooks rechecking
> membership and session on every event, both unchanged. The unreachable home-workspace markup (stats, environment
> cards, demo/explore CTAs, module grid) was removed; the header, refresh button, intro art and the workspace-error
> panel remain. Related navigation/auth tests were updated to the new landing behavior while preserving their security
> intent: an explicit (demo) or single-membership workspace redirects to its own command center with no chooser ever
> rendered; ambiguous/empty membership and invalid workspace configuration still render `#workspace-unavailable`
> without another company's data; forged company parameters change nothing; membership revocation is rejected at the
> destination's mount and session revocation redirects to `/sign-in` (including via a refresh event on the error
> page); the command destination renders the authorized workspace identity and branding across navigation; logout
> remains available. Full suite 423 passed with `mix test --warnings-as-errors`; compile and formatting clean. No
> blockers.

After Phase 1, change `PortfolioLive` so a resolved workspace goes straight to `/companies/:id/command`
(keep the workspace-error branch). Update `test/ops_brain_web/workspace_home_test.exs`.

### Task 4.3 — Docs

> **Status: implemented and verified.** README gained a top **Start here: Command center** section with the two
> day-to-day URLs (`/companies/:id/command` and `/companies/:id/troubleshoot?service=&environment=`) and their actual
> behavior — Investigate links that open the focused finding and its evidence, the `?environment=prod|staging|dev`
> filter (default all), 30-second refreshes, picker URL patching, first-production-service fallback and the
> unknown-never-healthy rule — and its outdated home description was replaced with the new landing behavior. The linked
> `docs/SINGLE_WORKSPACE.md` was inspected and its stale landing claims (former home stats and Explore resources /
> Follow the evidence cards, the Home environment cards, and "Home always returns to the dashboard") were corrected to
> the redirect landing; its historical acceptance ledger was left untouched.
> DEMO.md's "Open it" paragraph now states the landing goes straight to the demo Command center, and the guided tour
> starts at step 0: Command center → reporting-postgres (critical, abnormal growth) → the storage item's Troubleshoot
> link to the `reporting` service page, with attention findings' Investigate links noted. ONBOARDING.md gained "Which
> source configuration feeds which panel" (Prometheus bytes profile + verified capacity policy → storage forecast,
> with explicitly classified memory bytes profiles excluded from it; connection-count profiles and memory bytes profiles
> → saturation as two distinct shapes; Azure Build runs + stage_targets deployment evidence → pipeline health, CI-only
> runs never implying runtime health; Kubernetes pods → runtime) and "Command center behavior and new defaults"
> (environment filter applied in SQL before the service/window/evaluation/series/run bounds with the accepted Kubernetes
> object-attribution exception, and unknown-provenance only under All; opt-in prediction persistence with
> `:prediction_enabled` literal-true, default false, 5-minute passes starting ~5 s after boot, per-source provenance,
> recovery stops refreshing). Every documented URL, config key, symbol and default was mechanically checked against the
> router, CommandLive's environment/1, scheduler.ex (5 s first pass, 300_000 ms interval), config.exs (prediction_enabled
> false) and a rendered-page probe: the demo Command center's storage item href is exactly
> `troubleshoot?environment=prod&service=reporting` and attention findings carry `investigations?focus=…#groups-…`
> links — both now pinned as assertions in the demo anomalies LiveView test. Historical acceptance-ledger entries were
> left untouched. Full suite 423 passed with `mix test --warnings-as-errors`; compile and formatting clean. No
> blockers.

- `README.md`: add a "Start here: Command center" section at the top, with the two URLs.
- `docs/DEMO.md` guided tour: step 0 = Command center → reporting-postgres → Troubleshoot.
- `docs/ONBOARDING.md`: which source configs feed which panel (Prometheus bytes profile → storage
  forecast; Kubernetes → runtime; Azure Build + deployment evidence → pipeline health).

### Task 4.4 — Performance check

> **Status: implemented and verified; plan complete (benchmark validated after review).** Both LiveViews re-arm
> `Process.send_after(self(), :refresh, 30_000)` on mount and after every refresh (verified in `command_live.ex` /
> `troubleshoot_live.ex`; refresh behavior itself is covered by the existing LiveView refresh tests). Measured on the
> full offline demo workload (210 pods, 72 pipeline runs, 96 observation windows, 464 resource snapshots, 5 findings)
> in the disposable test database with validated responses: every timed HTTP request is captured and asserted — HTTP
> 200 with the Command center markers (attention list, reporting-postgres storage, search-indexer pipelines, no empty
> state) and the selected `checkout-api` service identity (`nw-eu-prod/checkout/checkout-api`) on Troubleshoot — and
> the read results are asserted to contain the same nonempty demo data, so a redirect or an empty fallback cannot pass
> as a page load. Timing wraps the request/read only; assertions run afterwards. Warm-up hits the exact measured URLs
> and reads. Measured (printed on every run by the permanent regression test
> `test/ops_brain_web/command_center_performance_test.exs`): command read ~9.9 ms, service read ~8.1 ms, Command
> center HTTP page load ~11.4 ms, Troubleshoot ~10.3 ms — all far under the 150 ms target (>13× headroom); the hottest
> query's server execution (the pipeline deployment-evidence lateral, EXPLAIN ANALYZE retained executably in the test)
> measured 3.7 ms, with the planner observed using either the existing `deployment_run_read_index` partial index or an
> equivalent nested-loop plan — so the test pins the execution time, not a plan shape. Cold first-use statement
> preparation (~55–140 ms observed, still under target) and LiveViewTest full-render harness overhead (not the
> page-load measure) are disclosed rather than hidden. Indexes were inspected (`20260920110735`) and **no migration
> was needed**. Final acceptance accounting: Tasks 1.1, 1.2, 1.3, 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 3.3, 4.1, 4.2 and 4.3
> are implemented, verified and Main-approved at their checkpoints (each with its own status block above); Task 4.4
> completes here. Remaining limitations, stated honestly: performance is measured on the demo workload, not real
> collector datasets at the 300-run/2000-window caps; the Kubernetes cursor attribution filter remains post-bound
> (accepted in Task 3.3); prediction persistence stays opt-in/disabled with real-source forecast usefulness unvalidated;
> pipeline duration stays excluded per the plan's start-time exception. Full suite 425 passed with
> `mix test --warnings-as-errors`; compile and formatting clean. No blockers.

Both pages refresh every 30 s. Log query times on the demo (`:telemetry` or `EXPLAIN ANALYZE`) and keep
each page load under 150 ms locally. If `pipeline_rows` or `resources` is slow, add indexes in a
migration (`evidence_items (company_id, kind, expires_at)` probably exists already, so check
`20260920110735_add_operations_read_indexes.exs`).

---

## Suggested split between agents

| Agent | Tasks | Touches |
|---|---|---|
| A | 1.1, 2.2, 2.4 | `insights.ex` (storage), `insights/sources.ex` (storage), tests |
| B | 1.2 | `insights/sources.ex` (resources), tests |
| C | 1.3, 2.3 | `insights.ex` (pipelines), tests |
| D | 3.2, 3.3, 4.1, 4.2 | LiveViews, router, web tests |
| E (after A–C) | 3.1, 4.3, 4.4 | new worker, docs, migration |

A, B and C all edit `insights/sources.ex`. Agree on one function per signal (`storage_series/1`,
`resources/2`, `pipeline_rows/2`) up front to avoid merge conflicts.

## Definition of done

- Command center and Troubleshoot show real collector data when sources are enabled, and demo data offline.
- Missing inputs show as `unknown` / blind spot, never healthy.
- Full test suite green, `mix format` clean, `mix compile --warnings-as-errors` clean.
- Docs updated.
