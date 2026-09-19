# Source onboarding — approval before activation

No real company/source/recipient has been supplied or connected. This is a procedure, not approval. Begin with one explicitly authorized dev/staging pilot. Actual Azure DevOps Services/Server installation is unknown; the adapter uses documented REST7.1 Services-shaped paths, not validated Server compatibility.

1. Owner approves company/scope, API installation, read-only identity, inherited permissions, network/egress, query load and retention. Never attempt production writes as a permission test.
2. Use authenticated `OpsBrain.Tenancy.create_source/2`; company/record IDs are bound server-side. `OpsBrain.Services.create/2` adds an explicit service/environment/source/target identity. A source identity alone is not whole-company coverage.
3. Install deployment-owned JSON and an environment secret reference. `mix ops_brain.validate_config FILE` checks offline only. No source text may populate configuration.
4. Enable only that source and collection scheduling after explicit read authorization. Inspect returned limitations, query usage, actual coverage and evidence before expansion.
5. Keep external delivery disabled until a fixed recipient/HTTP sink, minimal message permission, provider semantics and separate credential are approved. Dashboard-only operation needs none.

## JSON source contract

Required common fields:
- `id`, `company_id`: existing UUID identities; `kind`: `azure_build`, `prometheus`, `loki`, `kubernetes`; `enabled`: explicit boolean.
- `endpoint`: HTTPS origin without credentials/path/query/fragment; `approved_origins`: exact reviewed origin list; `approved_ips`: 1–8 literal IPs (currently first used). Original-host TLS remains verified; DNS changes need configuration review. Optional deployment-owned `ca_file` supports private PKI without disabling verification. `network_reviewed` records an acknowledgment, not an automated firewall audit.
- `credential_env`: narrow bearer credential reference, rotated by the source owner. `anonymous_approved` is only for explicitly approved unauthenticated sources/test fixtures, never a missing-credential fallback. Optional Loki `tenant` is fixed trusted configuration behind authentication, not a client override.
- Budgets: `interval_seconds` >=30; `requests_per_minute` 1–60 (default6); `max_bytes` 1024–2000000; `page_size` 1–200; `max_pages` 1–100 (one page/job currently, within this ceiling); `max_window_seconds` 60–86400; `retention_days` 1–90. These are bounds, not performance promises.

Pilot configuration caps100 sources/10 per company; scheduling rotates20-source batches. Enrichment cap100/source produces explicit unavailable-evidence records. Request admission is shared across poll/enrichment reads and fenced against stale release. No automatic Azure organization crawl exists.

### Azure Build

`organization`: approved path identifier; `project_id`: project UUID; `definitions`: nonempty explicit numeric IDs. All completed categories use finish-time ordering/fixed bounds/overlap/pagination. Separate active polling and up to100 recently observed IDs reconcile reruns, not complete ancient history. Classic release/test-result/artifact adapters are unsupported.

Optional `stage_targets`: list with string keys `stage_identifier` and `service_id`. Each explicitly declares a deployment stage and an existing same-company target. Completed mapped stages yield **reported** deployment attempts, never runtime confirmation. Unmapped CI success does not imply production health. Evidence selects at most40 failed leaves/10 issues/10 prior-attempt references and one bounded log-head sample. Historical attempt timelines are not recursively fetched; limitations remain visible.

### Prometheus

One `profile`: `id`, numeric `version`, `reviewed: true`, actual approved `query`, `unit` (`bytes`, `ratio`, `seconds`, `count`), `semantics: "gauge"`, optional `threshold`/`freshness_seconds`. Check metric names/labels/units against the installation. Missing/stale/nonfinite samples/warnings do not become healthy. No incoming PromQL is accepted. Reviewed recording/query profiles may compute rates; there is no invented universal NGINX schema.

Optional `capacity_policy`: verified effective storage limits, units, sampling/growth/horizon settings; `capacity_segment`: stable capacity/reset/cleanup identity. Insufficient/nonpositive/unstable history disables prediction. Forecasts are conditional, not outage times. Real usefulness remains unvalidated; synthetic false/missed warnings are reported.

### Loki

`profile`: `id`, `version`, `reviewed`, approved `selector` with producer-specific severity filtering/parsing, optional `minimum_count`. Aggregate fixed60-second windows; prior-window reconciliation handles some delayed ingestion when no newer closed window is waiting. Each tick prioritizes the next uncovered minute; intervals above60 seconds or backlog can remain behind, with source freshness showing lag. Reconciliation never moves the completed position backward. Counts are backend totals, separate from max200 samples/message160 bytes. Saturation, caps and absence are visible. Signature membership counts sampled windows, never exact per-signature totals. Data later than the reconciliation horizon is not guaranteed complete. Severity is not proof of impact.

### Kubernetes

`namespace`: explicitly reviewed namespace. Currently **Pods get/list/watch status only**, max200 objects, no specs/Secrets/exec. Owner UIDs are retained; name reuse does not reuse identity. Expired opaque resourceVersion relists with a gap; initial inventory is not a deployment. Larger inventories remain partial. Deployment/ReplicaSet/Event adapters, complete owner-chain resolution and OOM-specific classification are not implemented coverage.

## Optional notification sink

A deployment-owned destination name maps to `company_id`, `enabled`, `approved`, exact HTTPS `url`, `approved_urls`, fixed `approved_ip`, separate `credential_env`, optional `digest_seconds`, `cooldown_seconds`, `quiet_utc_hours`. Same observation/sink credential references are rejected. The sink permits only the application's message operation, not source writes. Generic JSON POST contains stable notice/delivery identity, revision, local status, severity and a bounded redacted template; source text never selects the URL/recipient.

Pending revisions coalesce without extending the first digest deadline. Critical policy bypasses digest delay. HTTP429 retries are bounded to three sends and respect Retry-After. Timeout/5xx/possible acceptance is ambiguous and not automatically retried. An idempotency header does not prove provider support or exactly-once delivery. Restart mid-delivery also records ambiguity. Replay never calls delivery.
