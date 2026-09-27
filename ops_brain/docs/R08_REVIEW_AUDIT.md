# R08 — local review audit history and revision conflicts

Status: implemented and verified locally on disposable PostgreSQL 18. No production rollout or historical backfill performed.

## Scope and contracts

Audited optimistic concurrency now covers assignment, explicit unassignment, local lifecycle review (including closure/reopening), and snooze. The existing read-only-source boundary, company authorization, notification identity/retry behavior, and prior review fixes are preserved. No upstream action or live provider access was authorized.

- Each mutation requires an integer `expected_revision:` from the operator's displayed snapshot. Missing/malformed revisions fail closed; stale requests return `{:error, :stale_revision}` without changing state, scheduling work, or adding audit rows.
- Successful mutations increment the group revision, including snooze, and insert exactly one audit event in the same PostgreSQL transaction. No-op values still represent an intentional successful action; retrying the same old revision conflicts.
- After locking the finding, the action rechecks current authorization and resolves the actor from the authenticated session, never request parameters. Events record bounded redacted actor name, action, server time, before/after revision, and only local status/owner/snooze values. No token, credential, full evidence payload or free-form audit note is stored.
- Forced-RLS `issue_audit_events` rows have company/source/group relationship constraints and an operator reference. Runtime gets SELECT/INSERT only, never direct UPDATE/DELETE/TRUNCATE. Startup rejects missing protection or unsafe audit-write grants.
- Audit lifetime follows the finding: deliberate parent retention/deletion cascades also delete its history. Operator references prevent physical operator deletion while referenced history remains; ordinary disabling/revocation still works. This is operational history, not a tamper-proof compliance archive.
- `Issues.audit_history/2` returns at most 50 newest events for an authorized finding. Other-company and nonexistent IDs remain indistinguishable. Read-only replay does not generate operator events.
- LiveView sends the displayed revision, reports conflicts and reloads authorized current state without silently retrying. A successful explicit retry clears obsolete failure feedback. The evidence panel displays bounded audit history and closes on refresh/navigation; company switching clears its stream.

## Implementation plan and completed steps

1. Add the constrained tenant-scoped audit migration and least-privilege grants.
2. Centralize local actions in `lib/ops_brain/issue_review.ex`: validate options, lock, reauthorize, compare revision, update, append audit atomically.
3. Delegate the public `Issues` APIs, propagate rendered revisions through LiveView, and expose local history.
4. Update all repository callers and add database/concurrency/LiveView regressions without weakening previous notification or lifecycle assertions.
5. Verify migrations, grants, public APIs, full regressions and production compilation; reconcile status documents.

## Acceptance ledger

| Check | Evidence and result |
| --- | --- |
| Forward migration, company/source/actor constraints, grant files, startup protected inventory | Passed. Migration `20260926061350_add_issue_audit_events.exs`; both grant files and `DatabaseSafety` inventory updated; constrained-insert negative tests |
| Assignment/unassignment/review/snooze, actual actor, server time and redaction | Passed. `IssueReviewTest`; before/after snapshots, closure/reopen, intentional no-op events, byte-bounded UTF-8 actor snapshots and identity renames |
| Invalid/stale/unauthorized actions leave state and audit unchanged | Passed. Strict revision/options checks, forged actor rejection, cross-company attempts and revoked membership |
| Real two-connection race | Passed. Distinct PostgreSQL backend PIDs, shared start barrier, one winner, one stale conflict, one audit event |
| Authorization revoked while waiting on a row lock | Passed. Observe the blocked backend in `pg_locks`, revoke membership, release lock, verify unauthorized/no update/no event |
| Audit-write failure rolls back state and revision | Passed. Synthetic failing INSERT trigger; original state/revision retained and no audit row |
| RLS, append-only runtime grants, bounded reads and parent retention | Passed. Unscoped rows hidden, direct UPDATE/DELETE/TRUNCATE denied, unsafe grant rejected by startup, 55 actions/50-row read, deliberate parent-delete cascade |
| LiveView revision propagation, conflict feedback/history, company switch and revocation | Passed. Four `IssueReviewLiveTest` cases including two independently mounted operator views; existing UI regressions preserved |
| Notification and full-suite regression | Passed. Final `mix precommit`: **263 tests**, including **14 new R08 tests**; format and warnings-as-errors compile included |
| Production compilation | Passed. `MIX_ENV=prod mix compile --warnings-as-errors` |
| Migration down/re-up and both grant paths | Passed on disposable data. Table/index removed on down; missing-schema preflight refuses startup; re-up and development/packaged grants each pass read-only preflight |
| Public contract probes | Passed. Exported action/history arities checked; legacy missing-revision calls and malformed revisions rejected before database access |

Commands ran through `mise exec --` using the repository's configured toolchain. Local verification harnesses were `/tmp/aiops-fixes-1790402389226/check.sh precommit` and `/tmp/aiops-r08.UVjKVM/schema-check.sh`; the latter also runs packaged read-only preflight source and direct PostgreSQL privilege/RLS checks. Disposable PostgreSQL was stopped after verification. No harness is a production runbook.

A structural review checkpoint was invoked, but Contour does not analyze Elixir/SQL; its zero findings are **not** approval. The action/lock/authorization/audit path, schema/grants and UI refresh paths were manually inspected and exercised by the tests/probes above.

## API transition

`Issues.assign/4`, `unassign/3`, and `review/4` accept keyword options containing `expected_revision:`. `review/4` retains optional `owner:` (nil preserves owner); the old string-owner shortcut is rejected. `snooze/4` accepts revision options; `snooze/5` permits a trusted injected validation clock. Old calls without revisions no longer perform unchecked writes. Repository callers are updated; external internal-API callers must supply their observed revision too.

For example: `Issues.assign(scope, group["id"], "on-call", expected_revision: group["revision"])`. On `:stale_revision`, reload authorized state and ask the operator to reconsider; do not automatically replay their action against the new revision.

## Deployment, disable and recovery

This is a handoff, not permission to deploy:

1. Approve backup/retention and migration timing. Drain old application writers before upgrading: mixed old/new versions can still make unaudited writes from old code.
2. Apply the migration using the migration identity, then the applicable reviewed grant path (`priv/repo/runtime_grants.sql` for local environments or `rel/runtime-grants.sql` for packaged deployment). New code must not start before these steps; missing schema/unsafe privileges fail closed.
3. Run the deployment's runtime-role preflight, then start the updated code. Update any separate internal API consumers to pass revisions. No dependency or source configuration changes are required.
4. If review writes must be disabled, keep the application/write UI offline through the approved operating procedure. Prefer a forward fix while retaining audit data. A code rollback to pre-R08 re-enables unchecked/unaudited actions; it is not a safe way to preserve this contract.
5. The tested migration `down` **deletes audit history**. Do not use it operationally without separately approved export/restore and data-retention decisions. Do not fabricate audit events for pre-upgrade actions.

No production migration, credential use, upstream request, external notification, commit, push or deployment occurred. Full packaged-release build/boot, browser/accessibility review, live-provider acceptance, sustained/multi-node load and whole-node crash gates were not run for this slice. They remain separate work, as do R02/R03 collection fairness/backlog hardening and broader release/CI tasks. The next suggested local implementation is R02/R03 fairness/backlog work; it was not started here.
