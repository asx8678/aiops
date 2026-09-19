# Offline replay and bounded retention

## Replay APIs

```elixir
{:ok, page} = OpsBrain.Replay.page(scope,
  stream: :observations, # or :evidence
  source_id: source_id,  # optional; authenticated company RLS still applies
  occurred_before: event_cutoff,
  received_before: knowledge_cutoff,
  limit: 100)
# Request subsequent pages with the identical scope/cutoffs and returned continuation.
OpsBrain.Replay.one(scope, window_id, occurred_before: event_cutoff)
OpsBrain.Replay.one(scope, evidence_id, stream: :evidence, occurred_before: event_cutoff)
OpsBrain.Replay.correlate(scope, symptom_id, change_ids, topology,
  occurred_before: event_cutoff, received_before: knowledge_cutoff)
```

Read APIs perform SELECTs and transaction-local scope/timeouts only. They do not invoke collectors/HTTP, enqueue jobs, deliver messages, alter current findings or overwrite human decisions. Missing scope and unauthorized IDs deny without revealing another company. Version-1 policies/data use fixed key allowlists, never input-derived atoms.

`observation_revisions` retains immutable per-window revisions and the policy used to evaluate them; runtime has no UPDATE privilege. Replay selects the latest revision known by **both event and receipt cutoff**. Mutable current windows are never a historical fallback. Embedded metric timestamps must also satisfy the event cutoff. Results include independent status (`ok`, `expired`, `missing_inputs`, `unsupported_version`, etc.), not a fabricated healthy result. Evidence expiry is checked at the current clock, not the simulated historical time. Retention cannot remove an expiry-bearing tombstone while its revision remains.

Supported retained evaluations:
- Pipeline classification/fingerprints, including sanitized snippet fallback.
- Prometheus gauge thresholds and matched-volume ratio profiles; ratios are recomputed from timestamp-aligned numerator/denominator samples, never copied from stored output.
- Loki backend-total thresholds and bounded sample fingerprint memberships; legitimate repeated samples retain multiplicity. Sample groups are not exact per-signature totals.
- Workload changes: restart/OOM/Event deltas and unknown initial inventory. This is replay of sanitized observations, not a reconstruction of unavailable raw watch history.
- Capacity using recorded input samples, policy, detector version and evaluation time; no future event/receipt inputs.
- Correlation using newly recorded symptom/change/topology inputs. Old output-only correlations remain unreplayable. The explicit-ID correlation API is a new evaluation of those supplied facts/topology, not a historical-configuration claim.

Adjacent-window sustained eligibility is recalculated using the same receipt cutoff and stored profile. Replay does not reconstruct mutable issue episodes or human review. Old inputs without required fields, missing revisions from before this upgrade, purged history and unsupported parser versions remain unavailable.

Pages read <=101 selected rows, return <=100, and have a five-second SQL timeout. Continuation binds company, stream, optional source, both cutoffs and `(occurred_at,id)` position. It grants no authority. These are keyset pages, not a cross-request database snapshot: concurrent retention or backdated insertion can change selection. Use an isolated/quiesced snapshot for reproducible exports. Empty pages mean no retained matching inputs, not healthy/complete historical monitoring. `fingerprints/3` is the older 1,000-row compatibility API; prefer pages.

**`Replay.expire/2` is a legacy explicit destructive maintenance API, not read-only replay.** It tombstones expired evidence, never sends messages, and is not used by replay or automatic maintenance.

## Maintenance and retention

`maintenance_enabled` is a deployment-owned JSON switch, **false by default** in both examples. When enabled, Scheduler rotates <=20 configured sources every five minutes into `MaintenanceWorker` on queue `maintenance` (concurrency1), plus one `DirectoryMaintenanceWorker`. Queued workers recheck the switch; disabling it and restarting stops cleanup. Collection no longer implicitly performs cleanup. Direct `Retention.sweep(source_id, now, batch_size)` is an internal maintenance API, not an operator-configurable query.

Source sweeps use trusted `retention_days`, scoped transactions/RLS, one-second lock timeout, five-second statement timeout and materialized row batches (default100, max500 per category). Live source leases/requests/nonterminal work defer the sweep. Open findings and delivery/evidence references protect dependencies. A category reaching the batch bound requests another bounded pass; this is not an exact remaining count.

Covered categories: expired evidence payload tombstones; old window revisions/projections and run snapshots; old terminal outbox records without live jobs; old closed/recovered occurrences, then unreferenced groups and fingerprints; old terminal pipeline identities without snapshots/occurrences/reconciliation/jobs; expired unreferenced tombstones after an additional retention period. Linked revision expiry markers are preserved. No unbounded cascading finding deletion is used. Protected live dependencies can retain data longer; monitor maintenance job age/database growth and review stuck collection work rather than force-delete it. Company/service/source configuration identities and latest durable cursors are intentionally retained while configured.

Directory maintenance deletes <=100 expired login/session tokens, <=100 expired OIDC attempts and <=100 terminal Oban jobs older than30 days per pass. It does not create/delete operators, memberships or companies, and requires no directory UPDATE grant. Global queue metadata remains private, never operator-visible. Tombstones/archives and backups may still contain sensitive identifiers; expiry/deletion is irreversible without backup.

## Checks and recovery

`test/ops_brain/replay_retention_test.exs` is included in ordinary `mix test`/`mix precommit`; it tests recorded policy, independent knowledge cutoffs, cursor binding, wrong-company IDs, forbidden network/jobs/outbox effects, bounds, expiry dependencies, and the expired-revision regression. `preparation_test.exs` covers directory expiry and kill switches. `scripts/concurrency_check.exs` is an additional guarded pool4/concurrency8 synthetic probe; it truncates only explicitly opted-in `ops_brain_test...` fixtures. See the preparation status report for actual results.

Stop the application to stop all local work. Disable maintenance independently for investigation. Failed transactions roll back; successful retention cannot be reversed without a backup. Use the separately guarded backup/restore procedures in `DEPLOYMENT.md`, keep collection/delivery off on restored databases, and approve session/queue disposition before starting them. No replay should fetch missing data from a live source.
