# Repair status — September 20, 2026

## Latest continuation — R19 / R23 / R24 / R25, native-only

No Docker used. Current authoritative handoff for this slice:
`ops_brain/docs/ACCEPTANCE_HARNESS.md`. Earlier entries remain historical.

- **R19 native alternative verified:** `ops_brain/scripts/release-native-verify.sh`
  checks lock stability, assembles production release, validates packaged helpers,
  migrations/assets and runs the actual release VM probe without app/Repo startup.
  Toolchain, lock and release file SHA256 manifests are retained in
  `/tmp/ops-brain-release.22fPhN`. No image or cross-host byte-reproducibility claim.
- **R23 expanded, not exhaustive:** new composed workflow tests run concurrent
  evidence writes on a four-connection pool, company isolation and a real Oban
  collector queue through synthetic HTTP to persisted checkpoint. The hard-crash
  harness kills the actual BEAM with SIGKILL after lease claim; a separate VM checks
  busy-before-expiry, takeover, stale rejection, fresh commit and duplicate rejection.
  `/tmp/ops-brain-crash.0d8ZO9`. Whole-node notification/maintenance crash boundaries
  remain unverified; existing process-kill and Lifeline tests are not relabeled as
  whole-node tests.
- **R24 local preparation complete; external acceptance BLOCKED:** no approved live
  provider credentials/endpoints or deployment target. Owner/evidence checklist in
  the acceptance document; no synthetic check is represented as live acceptance.
- **R25 handoff updated:** root `README.md`, acceptance ledger, exact artifacts,
  deployment/rollback guidance and explicit remaining limits.

Final local gate: `mise exec -- mix ci`, **208 passed**, seed **564594**,
`/tmp/ops-r19-r25-ci.log`; includes formatting and warnings-as-errors. Both deployment
JSON files validate with no credential/network checks. Native release probe passed.
Shell syntax, 12 release contract tests and `git diff --check` passed. Disposable DB
`ops_brain_test_r10` at `/tmp/ops-brain-pg/socket:55432`, database approval checked,
separate restricted runtime and migrator identities. No migrations needed in this
slice. No commit, push, PR or deployment. HEAD remains
`8e8099e9cd2a8ddce90a5051556de5d1ef53d578`.

Inherited broken harnesses were corrected before verification: no swallowed failed
checks, no `kill 0` cleanup, actual BEAM PID killed rather than a launcher, synthetic
configuration transferred between VMs, and fresh commit behavior asserted. Do not
use the earlier transcript scripts as the operational version.


## R10 continuation — durable disabled/retired-source retention

Completed the scoped R10 implementation, not R11/R12 or the full repair program. The inherited unfinished throughput/precise-guard changes were removed; existing conservative nonterminal-job protection and R09 five-minute worker timeout callbacks remain.

Acceptance ledger:
- Durable source policy: migration `ops_brain/priv/repo/migrations/20260920130000_add_source_retention_policy_columns.exs` adds nullable bounded retention days, policy format version and retirement timestamp. No guessed historical default.
- Configuration-independent cleanup: `Retention.sync_from_config/1`, `targets/0` and `sweep/3` retain policies for disabled/removed sources, validate source/company/kind identity, and operate under scoped runtime RLS. Current reviewed policy takes precedence; mismatched sync entries cannot overwrite it. Unknown historical policy returns `policy_unknown` without deletion.
- End-to-end registration: `Scheduler.handle_info/2` synchronizes policies and schedules durable known-policy IDs; `MaintenanceWorker.perform/1` handles unknown/missing identities. Collection eligibility and provider access remain unchanged. Queue arguments accept only a source ID.
- Regression coverage: `ops_brain/test/ops_brain/retention_policy_test.exs` covers disabled and removed cleanup, unknown-policy preservation, retained conservative job guard, retired scheduler/worker execution, wrong-company policy denial, tenant-isolated cleanup and cleared transaction scope. Existing replay dependency protection and orphan recovery run in the full suite.

Verification: created new local `ops_brain_test_r10`, explicitly marked disposable, via `/tmp/ops-brain-pg/socket`; applied migrations as migrator and tested with separate restricted runtime role. Initial inherited compile failed on unsupported Oban `timeout` option; fixed using the existing callback contract. TCP attempts failed because PostgreSQL is socket-only. An attempted start correctly refused the running server; no restart occurred. Initial migrations/grants also ran on inherited `ops_brain_test`, but fixture execution was denied by its missing disposable approval; no tests truncated that database. All executed fixtures then used the newly created approved database.

- Complete retention-policy + replay-retention modules: **21 passed**, seed **533824**; `/tmp/ops-brain-r10-tests.log`.
- `mise exec -- mix precommit`: **190 passed**, seed **29325**, including warnings-as-errors compilation and formatting; `/tmp/ops-brain-r10-precommit.log`.
- `mise exec -- mix format --check-formatted`, production warnings-as-errors compilation, and `git diff --check`: passed. `mix.lock` unchanged.
- Migration/grant artifacts: `/tmp/ops-brain-r10-migration.log`, `/tmp/ops-brain-r10-grants.log`.

Operational limits and migration/disable instructions: `ops_brain/docs/REPLAY_RETENTION.md`. Seed a reviewed policy before removing a source configuration; never-snapshotted historical sources require review. Catalog scans and directory cleanup throughput remain R11; precise dependency/race protection remains R12. No sustained-load, real-provider, deployment or remote CI acceptance is claimed. No commit, PR or push; HEAD remains `8e8099e9cd2a8ddce90a5051556de5d1ef53d578`. Earlier entries below are historical.

## R09 continuation — rescue enabled, crash acceptance partial

Configured locked Oban 2.24.1 `Oban.Lifeline` with ten-minute rescue age, one-minute interval and `Oban.Peers.Database` leadership in `ops_brain/config/config.exs`. No framework Pruner is enabled; directory maintenance remains its owner. All six application workers now enforce a five-minute Oban timeout, below the rescue threshold. Existing source leases/fencing and durable notification claim logic are unchanged.

`ops_brain/test/ops_brain/orphan_recovery_test.exs` verifies configuration and worker bounds, invokes the real Lifeline callback/Basic engine on an isolated non-testing Oban instance with PostgreSQL (old executing jobs become available; exhausted jobs discarded; younger jobs unchanged), and kills a delivery process after its simulated sink POST. Re-entry through NotificationWorker marks the durable in-flight row ambiguous without a second send. The plug is synthetic, not an external endpoint. These are not whole-node crash tests or a complete real-queue crash matrix. Exhausted jobs are discarded by Lifeline; an exhausted in-flight outbox row can remain delivering until separately reconciled, and must not be manually re-POSTed.

Verification used the previously approved disposable `ops_brain_test_repair_continuation_20260920` via `/tmp/ops-brain-pg/socket`, with separate runtime/migrator roles and safety guards enabled:
- Initial inherited module: 2 passed.
- Expanded targeted check: 7/8 passed initially; fixed callback annotations and test timestamp construction (DB clock differed from the BEAM clock used by Lifeline).
- Final `mise exec -- mix ci`: **183 passed**, seed **685988**, including format and warnings-as-errors compilation.
- `MIX_ENV=prod mise exec -- mix compile --warnings-as-errors`: passed.
- `git diff --check`: passed.

No commit, PR, push, deployment, dependency or schema changes in this slice. Collection/delivery remain disabled by default. R09's whole-node/collector crash acceptance and exhausted-outbox reconciliation are still unfinished; R10–R12 remain the next independent implementation slice. Earlier entries below are historical results, not newer verification.

**Partial repair, not completion of R01–R25 and not production acceptance.**

## Checkout and safety

HEAD and reviewed baseline: `8e8099e9cd2a8ddce90a5051556de5d1ef53d578` (`main`). Initial worktree was clean. The inherited handoff contained only the redactor patch and its new test module; both were preserved and strengthened. No commits, pushes, schema/grant changes, dependency changes, or external-provider actions were performed.

The earlier part of this session ran the existing database suite and reported 142 passed (seed 932856, 16.4 s), then 16 targeted tests passed (seed 396852). These are actual inherited execution outputs, **not results for the final patch**. Their shell commands piped through `tail` without `pipefail`, so the shell status alone is not authoritative. More importantly, the existing `ops_brain_test` database was reused based on its name and prior setup without establishing new explicit database-specific disposable approval. That does not meet this prompt's safety standard. That earlier continuation did not run further destructive fixtures. The latest continuation below instead created a new explicitly disposable database.

## Task ledger

| Task | Baseline finding | Reproduction/status | Fix and files | Regression/check | Executed result | Remaining limitation |
| --- | --- | --- | --- | --- | --- | --- |
| R01 | Quoted assignment tails survive redaction | Confirmed; core repair verified locally | `ops_brain/lib/ops_brain/redactor.ex`; `ops_brain/test/ops_brain/redactor_test.exs` | Full RedactorTest and DetectorsTest modules, including dangling escape regression | 15 passed, seed 460521 | Persisted evidence / authorized UI / notification canary integration not added; current full DB suite passed (see latest continuation) |
| R02 | Historical Azure reconciliation can delay discovery | Partial core repair verified locally | `collection.ex`, `scheduling_test.exs` | 100-ID backlog yields HTTP discovery; 429; legacy recent failure retains IDs | Full suite 167 passed | Active pagination can still delay discovery; inventory-wide fairness, deletion disposition and durable independent lanes outstanding |
| R03 | Telemetry catch-up cadence may not converge | Partial core repair verified locally | `telemetry_collection.ex`, `scheduling_test.exs` | 600/3600-second Prometheus backlog converges through CollectionWorker with advancing fake clock | Full suite 167 passed | Real queue/scheduler, Loki overload/fairness, historical delivery policy and distinct progress display outstanding |
| R04 | Existing group severity not updated | Core fix verified locally; task partial | `issues.ex`, `lifecycle.ex` | `LifecycleDbTest`: escalation, older warning, duplicate critical, human decisions | Passed in 162-test suite | Pending/in-flight notification matrix still outstanding; severity represents episode peak |
| R05 | Capacity recovery absent; sample-time hypothesis | Scoped repair verified locally | `evaluations.ex`, `recovery.ex`, `lifecycle.ex`, `capacity_recovery_test.exs` | Warning/critical recovery, real timestamps, missing/partial inputs, profile/policy isolation, replay/closure | Full suite 178 passed | Legacy unversioned findings require review; live-provider acceptance not run |
| R06 | Duplicate occurrence rejects improved evidence | Scoped repair verified locally | `issues.ex`, occurrence-evidence migration, grants, safety, evidence UI, `evidence_revision_test.exs` | Immutable revisions, reclassification/history, stale replay, two-connection race, tenant/source boundaries, populated backfill | Full suite 178 passed | Full crash/in-flight delivery matrix remains R23; no remote/deployment validation |
| R07 | Episode query uses processing time | Core fix verified locally; task partial | `issues.ex`, `lifecycle.ex` | Reverse event order, first/last times, distant reverse gap, closed group | Passed in 162-test suite | Bridge/closure boundary policy and investigation symptom selection still need completion |
| R08 | Status review clears owner; audit absent | Assignment fix verified locally; task partial | `issues.ex`, `operations_live.ex` | Assign, acknowledge preserves owner, explicit unassign | Passed in 162-test suite | No audit table or optimistic concurrency; UI error handling added but dedicated new UI regression pending |
| R09 | Orphan rescue not configured | Scoped implementation verified; crash acceptance partial | `config/config.exs`, all six workers, `orphan_recovery_test.exs` | Real Lifeline DB rescue/discard/age boundaries; process kill after simulated POST; no resend | Full suite 183 passed | Whole-node crash and composed collector lease/fencing matrix remain unrun |
| R10 | Disabled/removed sources may lose maintenance | Scoped implementation verified locally | Retention, Scheduler, MaintenanceWorker, source-policy migration | Disabled/retired/unknown policy, scheduler-worker, tenant boundaries | Full suite 190 passed | Historical unknown policy requires review; R11 catalog/throughput and R12 precise guards remain |
| R11 | Cleanup throughput ceiling | Not investigated | None | Sustained ingress/load tests unrun | Not run | Repair remains outstanding |
| R12 | Source-wide retention protection | Not investigated | None | Dependency/race tests unrun | Not run | Repair remains outstanding |
| R13 | Ambiguous worker outcomes | Partial contract implemented | `outcome.ex`, `collection_worker.ex`, `collection.ex`, `telemetry_collection.ex` | `OutcomeTest`, existing collector modules | Passed in 162-test suite | Other workers, sanitized telemetry and full outcome matrix outstanding |
| R14 | Distributed lifecycle rules | Partial pure contract implemented | `lifecycle.ex`, `issues.ex` | `LifecycleTest`, `LifecycleDbTest` | Passed in 162-test suite | Evidence/recovery/audit transitions not consolidated |
| R15 | Competing Kubernetes engines | Not investigated | None | Compatibility/watch matrix unrun | Not run | Repair remains outstanding |
| R16 | Destructive replay entry point | Not investigated | None | Replay/cleanup authorization matrix unrun | Not run | Repair remains outstanding |
| R17 | Non-mutating CI and disposable setup missing | Partial implementation; local checks verified | `.github/workflows/ci.yml`, `mix.exs`, `test/support/fixtures.ex`, `test/test_helper.exs` | `mix ci`; new disposable DB; denied missing approval | 162 passed; opt-out rejected exit 1 | Remote CI, action SHA pinning, egress isolation, packaged grants, clean-checkout/release/container matrix outstanding |
| R18 | Native/container configuration divergence | Not investigated | None | Packaged/native/proxy equivalence unrun | Not run | Repair remains outstanding |
| R19 | Container reproducibility unproved | Docker CLI absent in inherited probe | None | Image build/boot/scanning unrun | Not run | Docker unavailable; other release work also outstanding |
| R20 | Reporter not wired | Not investigated | None | Real telemetry event/export tests unrun | Not run | Repair remains outstanding |
| R21 | Aggregate work precedes page limit | Scoped implementation verified locally | `issues.ex`, route loaders, read-index migration; `ops_brain/docs/OPERATIONS_READS.md` | Stable 100-group page, exact counts, restricted-role EXPLAIN, route SQL capture | 203-test precommit passed | Counts still scale with retained occurrences within selected groups; production-scale benchmark unrun |
| R22 | Investigation UI incomplete | Investigation and mapping UI verified in LiveView tests | `operations_live.ex`, `Notifications.status/2`; `ops_brain/docs/OPERATIONS_READS.md` | Owner/review/snooze, explicit mappings/expiry, revisions, candidates/counterevidence, scoped notification state, company switch and revocation | 203-test precommit passed | Interactive browser/accessibility review unrun; broader R08 audit/concurrency work remains separate |
| R23 | Composed concurrency/crash coverage | Lifecycle regression coverage added; task partial | `lifecycle_db_test.exs`, pure tests | Full ordinary restricted-role suite | 162 passed | No new multi-connection, real-queue or VM-crash evidence |
| R24 | Live-provider/deployment gates | External acceptance blocked | Existing runbooks unchanged | No external tests authorized | Not run | New local harness outstanding; owners must approve real credentials/endpoints/recipients/proxy/restore/second company |
| R25 | Traceable handoff | Partial documentation delivered | This ledger; README repair link | Source diff/format checks | Passed | Broad implementation/documentation consolidation remains outstanding |

Unimplemented local tasks above are **not blocked by missing live credentials**. They remain unfinished in this run, not silently accepted or disproved.

## R01 policy and compatibility

Quoted assignments are consumed before unquoted values, including both quote styles, escaped quotes, newlines and trailing backslashes. An unterminated quote consumes the remaining input conservatively. Possessive repetition avoids repeated quote-body backtracking. The pipeline rejects invalid UTF-8 before regex work, rejects inputs over 1 MiB rather than truncating a secret mid-value, and bounds error markers as well as normal output. Invalid/negative byte-limit arguments return empty output. Existing authorization, JSON, private-key, URL, JWT, email and ANSI behavior has regression coverage; arbitrary-secret detection is not guaranteed.

This changes future redaction only. **Previously persisted evidence, logs and backups are not retroactively sanitized.** Inspection/remediation of real stored data requires separate authorization and a bounded migration/backup policy. No such action occurred.

## Exact continuation checks

From `ops_brain/`, using mise Elixir 1.20.4 / OTP 27 and existing locked dependencies:

1. `mise exec -- elixir -r lib/ops_brain/redactor.ex -e 'ExUnit.start(); Code.require_file("test/ops_brain/redactor_test.exs")'` — **failed as intended before repair**, exit 2, seed 359447: 5/6 passed. Revealed a trailing-backslash leak in the inherited patch.
2. `mise exec -- mix format lib/ops_brain/redactor.ex test/ops_brain/redactor_test.exs` — passed; intentionally formatted only changed code.
3. `mise exec -- mix compile --warnings-as-errors` — passed.
4. `mise exec -- mix run --no-start -e 'ExUnit.start(); Code.require_file("test/ops_brain/redactor_test.exs"); Code.require_file("test/ops_brain/detectors_test.exs")'` — **15 passed**, seed 460521, reported 0.2 s. Complete two test modules; no app/DB startup and no fixture cleanup.
5. `mise exec -- mix format --check-formatted` — passed repository-wide.
6. `MIX_ENV=prod mise exec -- mix compile --warnings-as-errors` — passed; not a release/container boot.
7. `git diff --check` — passed.

These checks describe the earlier redaction-only continuation. See the subsequent execution record below for the current patch.

## Latest continuation — foundational slice

Still **not all tasks complete**. The inherited multi-file patch contained two Elixir syntax errors, an invalid outcome fallback, malformed workflow YAML and migrations configured under the runtime role. Those were corrected before verification. No commits/pushes, dependency updates or new application schema/grants were made. The redactor work was preserved.

A new database `ops_brain_test_repair_continuation_20260920` was created (creation fails if it exists), locally on the dedicated PostgreSQL 16 socket, owned by `ops_brain_migrator`. It was explicitly marked `ops_brain.disposable_test=approved`. The existing separate runtime/migrator roles were verified non-superuser/non-BYPASSRLS. Existing migrations and development grants ran under migrator; the complete test suite ran under runtime with only fixture administration under TestAdminRepo. No previous DB was dropped/truncated for this continuation.

Every test run now checks explicit `OPS_BRAIN_DISPOSABLE_TEST=true`, database approval marker, matching live database/server identity and distinct role names before test modules run. Cleanup repeats that guard. Startup's existing runtime ownership/RLS checks remain enabled. The guard supplements, not replaces, the requirement to provision a fresh authorized database.

Current commands (Elixir 1.20.4 / OTP 27, PostgreSQL 16.15, locked dependencies):
- `mise exec -- mix ci`: exit 0, **162 passed**, final seed 218080, 18.3 s (prior seed 49410 also passed).  Runs non-mutating formatting, warnings-as-errors compilation, full suite. Earlier intermediate run: 160 passed, seed 879465.
- `MIX_ENV=prod mise exec -- mix compile --warnings-as-errors`: exit 0.
- `python3 -m unittest discover -s rel/tests -p 'test_*.py'`: exit 0, **12 passed**. Static/shell release contracts, not container execution.
- `OPS_BRAIN_DISPOSABLE_TEST=false mise exec -- mix test test/ops_brain/lifecycle_db_test.exs`: expected exit 1 before fixtures, explicit approval error.
- `git diff --check`: exit 0.
- Both `mix ops_brain.validate_config config/sources.example.json` and `config/sources.prepared.json`: exit 0, static validation only. Workflow YAML parsed successfully; this is not remote execution.

Behavior: episode severity is monotonic peak severity, preserving acknowledgment/owner/snooze; episode selection uses event-time bounds in both directions and first_seen moves backward. Implausible events more than five minutes ahead are rejected, not timestamp-rewritten. Closed/recovered groups are excluded; existing episodes are not merged. Historical notification eligibility and closure/bridge semantics still need the full R07 design. Legacy review/4 accepts a string owner; omitted/nil owner preserves assignment; explicit unassignment uses `Issues.unassign/2`. Review transitions are validated against a pure table. No audit/conflict guarantees are claimed.

Azure recorded failures now carry `{:source_failure, reason}` and complete intentionally for periodic retry. Telemetry source errors no longer advance the contiguous checkpoint or masquerade as a successful observation; the worker distinguishes nested recorded failures. Remaining workers still require R13 consolidation.

CI is added but **has not run remotely**. It uses a disposable PostgreSQL service, separate identities, migrator-only migrations, runtime grants, locked mise configuration, non-mutating checks and a tracked-diff gate. It is not yet the complete R17 acceptance pipeline. No image digest, scanner, deployment or external acceptance is claimed.

## Scheduling continuation — local partial R02/R03

HEAD remains `8e8099e9cd2a8ddce90a5051556de5d1ef53d578`; earlier work preserved. No migration/grant/dependency changes, commits, pushes or external-provider actions in this continuation. Tests reused the newly created, explicitly approved and database-marked `ops_brain_test_repair_continuation_20260920` described above; the runtime/migrator identity guard ran before fixtures.

Azure now performs one retained-run reconciliation between completed/active discovery phases, preserving the remaining inventory across phases. Existing `recent` checkpoints are accepted without migration. Failed historical IDs rotate rather than being discarded, and processing returns to discovery. Historical inventory is refreshed only after the current list drains. The old 100-ID inventory bound remains. HTTP completion checks use the completion clock for fencing. This does not yet guarantee discovery fairness against unbounded active-list pagination, or provide a complete deleted-ID/tombstone policy.

Telemetry executes ONE fixed window per job invocation, not the inherited four-window HTTP loop under a single lease. Successful lagging work returns `{:snooze, 5}`, which existing worker mapping forwards to Oban; the shared request admission remains authoritative. Missing/partial metric observations do not advance the contiguous checkpoint. Caught-up collection retains prior-window reconciliation. Failures retain the prior nested recorded-error API for compatibility; Outcome maps it deliberately. Final lease release results are checked, source error distinctions preserved. A one-hour synthetic backlog converges with five-second steps and 60 requests/minute admission while the fake clock advances; this is worker invocation, NOT real-queue or multi-source proof. Faster catch-up is feasible only when admitted window throughput exceeds one minute of incoming history per minute (ratio/Loki windows cost multiple requests). Historical delivery burst policy remains outstanding: keep delivery disabled.

Tests/checks (mise Elixir 1.20.4 / OTP 27, existing locked deps, local PostgreSQL 16):
- Complete scheduling/collection/telemetry modules initially passed: 13 tests, seed 651095 (before additional regressions).
- First full check failed: 161/166 passed. Fixed preserved error-result compatibility and an unrelated existing capacity export test's module-loading-order dependence using `Code.ensure_loaded`, retaining all assertions.
- Next full check failed: 166/167 passed. Fixed generic finalization overwriting the precise `workload_unavailable` source error.
- Final `mise exec -- mix ci`: exit 0, **167 passed**, seed **135141**, 20.3 s; includes format check and warnings-as-errors compilation.
- `MIX_ENV=prod mise exec -- mix compile --warnings-as-errors`: exit 0.
- `git diff --check`: exit 0.

New `SchedulingTest` covers phase interleaving, legacy `recent` failure rotation without ID loss, actual HTTP discovery with 100 historical IDs, Retry-After preservation, and 600/3600-second catch-up via the real worker return mapping. No real Oban scheduling/crash, new Loki catch-up, workload inventory fairness, external/provider/container or remote CI validation occurred. R05/R06, R09–R12, R18/R20–R22, R15/R16, R23–R25 and other previously incomplete acceptance criteria remain unfinished; this continuation does not claim to complete the requested full sequence.

Remaining execution order: finish R17 safety/CI coverage and R13/R14 contracts; implement R02/R03; complete R04–R08 (audit/revisions/recovery); R09 then R10–R12; R15/R16; R18/R19; R20–R22; R23 integration matrix; R24 local harness/external gates and R25 handoff. Keep collection/delivery disabled; unfinished local work is not excused by missing live credentials.

## R05/R06 continuation — locally verified scoped implementation

HEAD remains `8e8099e9cd2a8ddce90a5051556de5d1ef53d578`. No commit, push, PR, deployment, live-provider access or notification delivery was performed. Earlier repairs remain in the worktree. This completes the scoped capacity/revision implementation, not the full R01–R25 program.

Acceptance ledger:
- **R05 timestamps/coverage:** evaluations use actual Prometheus sample timestamps, receipt-time bounds and complete coverage. Missing timestamps are unknown, including legacy rows; window boundaries no longer manufacture sample freshness. History is bounded to 60 windows and isolated by source, service and profile version.
- **R05 recovery:** `Lifecycle.capacity_recoverable?/3` admits only fresh normal evaluations. Recovery matches source/service/profile/version and exact retained policy digest, requires a newer sample event than the finding, preserves peak severity/owner, respects reviewer closure and is idempotent. Warning and critical recovery after a stable cleanup segment are tested. Recovery evidence is exposed in the authenticated evidence view. Changed policy or profile does not silently recover old findings. Existing unversioned capacity fingerprints are deliberately not auto-closed: review them explicitly. Flat/no-growth input remains unknown under the existing conservative detector.
- **R06 revisions:** one occurrence identity, append-only evidence/classification links, current evidence pointer, parser version and former-group provenance. Newer receipt-time evidence may improve/reclassify; unseen older evidence is retained as `stale_ignored`, with repeat replay deduplicated. Equal receipt times use transaction order. Reclassification does not duplicate counts or overwrite the previous group's reviewer state. Empty former groups retain history and mark classification revised; their pending notifications are coalesced. Already in-flight messages cannot be recalled.
- **R06 concurrency/security:** absent occurrences are serialized before lookup; fingerprint locks retain episode serialization. A two-connection test verifies distinct PostgreSQL backend PIDs, one occurrence, two revisions and newest evidence selection. Tests cover other-tenant reads, same-company cross-source link rejection, runtime UPDATE denial and expired payload suppression. Revision history is available through `Issues.revisions/3` and the existing authenticated evidence UI.
- **Schema/permissions:** forward migration `ops_brain/priv/repo/migrations/20260920120000_add_occurrence_evidence_revisions.exs` adds `occurrence_evidence` and scoped foreign keys/indexes. Runtime has SELECT/INSERT/DELETE, not UPDATE; deletion remains available for retention. Both `priv/repo/runtime_grants.sql` and `rel/runtime-grants.sql` plus `DatabaseSafety.protected_tables/0` include the new table. Owner backfill runs inside transactional DDL locks with forced RLS restored before commit.

Verification used the existing explicitly approved disposable `ops_brain_test_repair_continuation_20260920`, PostgreSQL 16 via `/tmp/ops-brain-pg/socket`, distinct migrator/runtime roles, Elixir 1.20.4/OTP 27 and locked dependencies. Initial TCP attempts failed because this server is Unix-socket-only; it was not restarted. Initial migration failed on a missing referenced unique key; corrected before successful application. The initial inherited tests also did not cover the races and policy mismatch now covered here.

Commands/results:
- Complete new R05/R06 modules: **11 passed**, seed **759906**.
- `mise exec -- mix ci`: **175 passed**, seed **434470**, before the final three regressions.
- `mise exec -- mix precommit`: **178 passed**, seed **620421**, including warnings-as-errors compilation and formatting. `mix.lock` unchanged.
- `mise exec -- mix format --check-formatted`: passed.
- `MIX_ENV=prod mise exec -- mix compile --warnings-as-errors`: passed.
- `python3 -m unittest discover -s rel/tests -p 'test_*.py'`: **12 passed** (static/shell release contracts, not a container boot).
- New migration rollback/reapply on populated synthetic fixtures: passed. Direct SQL probe verified one populated occurrence backfilled, forced RLS restored and UPDATE denied. Local artifacts: `/tmp/ops-brain-r05-r06-backfill.sql`, `/tmp/ops-brain-r05-r06-migration.log`.
- Final diff check initially found an extra blank EOF line in runtime grants; removed and rechecked.

Deployment requires applying the migration as owner, then the appropriate reviewed grants before starting the new runtime. Do not roll back the new table merely to disable collection: that discards revision history. Keep collection/delivery disabled until deployment authorization and remaining acceptance gates are satisfied. Existing archived evidence is not retroactively reclassified or redacted.

Remaining: R09 is the next independent slice (orphan-job recovery), followed by R10–R12 maintenance/retention. Earlier partial R02/R03/R04/R07/R08/R13/R14/R17 and other ledger tasks remain; audit/optimistic review concurrency, full crash/in-flight notification matrix, release/container/live-provider validation are not claimed complete. This continuation did not auto-advance into those independent changes.
