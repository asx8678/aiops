# Task 001 — company-scoped foundation

Status: implemented and locally verified; independent review and real deployment/source approvals remain pending. The user authorized task 001 after discovery and allowed unavailable external prerequisites to be deferred. The full product is **not complete** and no task 002 collector has been implemented.

## Delivered behavior
Application: [`../ops_brain/`](../ops_brain/README.md). Phoenix/LiveView, Ecto/PostgreSQL and Oban are configured and dependencies are resolved in `ops_brain/mix.lock`. `ops_brain/mise.toml` pins the tested Elixir/OTP pair. No runtime AI, external source client, source mutation, notification sink, job worker or broad dashboard scaffold was added.

- Minimal operators/companies/memberships, dev/staging/prod environments and source identities. No future detector/pipeline/service schemas.
- Authenticated entry with offline-issued, expiring, single-use random login capabilities; hashed storage, encrypted/revocable eight-hour sessions, no default accounts or public registration. SSO remains deferred, not bypassed.
- `OpsBrain.Tenancy.authorize/2`, `with_scope/2`, `list_companies/1`, `overview/1`, `get_source/2`, `create_source/2`, `create_environment/2` provide scoped access. Identity is bound by session/membership, never incoming company fields.
- Short transaction-local PostgreSQL scope, forced RLS on operational `sources`/`environments`, composite company/environment foreign key, scoped uniqueness. Runtime cannot administer the identity directory; it cannot own/bypass protected tables. `OpsBrain.DatabaseSafety` refuses unsafe startup.
- Authenticated portfolio/company/source pages show **unknown/not configured**, not fake health. CI-only mapping remains unresolved; classic releases explicitly unsupported. LiveView mount, reconnect, navigation and refresh events reauthorize.
- `OpsBrain.Accounts` handles token exchange/session lookup/revocation. `Mix.Tasks.OpsBrain.Bootstrap` provisions approved local operator/company identities offline, using a distinct migration role.
- Database migration: `ops_brain/priv/repo/migrations/20260919135154_create_tenancy_foundation.exs` (including Oban schema v14). Runtime grants: `ops_brain/priv/repo/runtime_grants.sql`. No queue UI or source jobs; Oban queues/plugins/peer election disabled.

## Acceptance ledger
- [x] Minimal application compiles with locked dependencies and documented local setup.
- [x] Typed IDs, company-scoped uniqueness and composite relationships on implemented operational identities.
- [x] Authenticated entry without production seed passwords or auth bypass.
- [x] Missing/invalid scope, cross-company direct/guessed-ID access and client-forged source bindings denied.
- [x] HTTP and LiveView lifecycle authorization; revoked memberships/sessions rejected on subsequent requests/actions/reconnects.
- [x] Two synthetic companies with identical source display names; test-only fixtures, empty production seeds.
- [x] Real PostgreSQL scope reset after commit, rollback and exception on the same physical pooled connection.
- [x] Forced RLS exercised by a non-owner/non-BYPASSRLS runtime role; identity writes/DDL denied; owner runtime startup rejected.
- [x] Full application suite and direct HTTP/provisioning probes pass; migration rollback/reapply verified.
- [x] Public routes, config/Oban registrations, scoped API call sites and lock inspected.
- [ ] Independent review, real-company authorization/network assessment, production TLS/SSO/MFA policy and infrastructure approval.
- [ ] Live source contract verification (not applicable to foundation; no approved source supplied).

## Actual tooling and checks

Discovery's PATH-only check was incomplete: `mise ls --installed` found Elixir `1.20.4-otp-27` and Erlang `27.3.4.16`, used through explicit `mise exec ... --` invocations. PostgreSQL 16.15 packages were downloaded with `apt-get download` and extracted under `/tmp/ops-brain-pg/`; no packages/system services were installed, no cloud resources provisioned. A disposable local cluster used Unix-socket authentication and rejected TCP database authentication. Separate `ops_brain_migrator` and `ops_brain_runtime` logins were used. No production/cloud source or credential was accessed.

Commands actually run (inside `ops_brain/`, with scoped local database URLs where needed):

| Check | Outcome |
|---|---|
| `mix deps.get` | Passed; real Hex resolution and generated `mix.lock` |
| `mix ecto.gen.migration create_tenancy_foundation` | Created timestamped migration |
| `mix ecto.migrate` + `psql ... -f priv/repo/runtime_grants.sql` | Passed on PostgreSQL 16.15 |
| `mix precommit` | Passed: application compile with `--warnings-as-errors`, dependency cleanup check, format, **25 tests passed**, zero failures |
| Targeted tenancy/HTTP modules during iteration | Failures inspected and corrected, not suppressed |
| `MIX_ENV=prod mix compile --warnings-as-errors` | Passed; dependency cold-build deprecation warnings remain (not application compile failures) |
| `DATABASE_URL=<migration-owner> mix run -e ':ok'` | **Expected exit 1** from `OpsBrain.DatabaseSafety`: unsafe owner identity rejected before endpoint startup |
| `mix ops_brain.bootstrap --operator synthetic-smoke --company synthetic-smoke --name 'Synthetic Smoke'` | Passed using migration identity; generated login capability redacted from report |
| Temporary local `mix phx.server` on `127.0.0.1:4101` + bounded curl probes | Passed: anonymous redirect, sign-in form, valid-CSRF token exchange, company-only portfolio, honest coverage, three local vendor JS assets, missing-CSRF HTTP 403 |
| `mix ecto.rollback --quiet` then `mix ecto.migrate --quiet` and runtime grants | Passed for final Oban-v14 foundation on disposable database; destructive rollback drops local state |
| `mix format --check-formatted`, `mix phx.routes`, static contract probe | Passed: formatting, 6 application routes, 7 scoped API exports, disabled job settings, all 14 original pack manifest hashes unchanged |
| Restricted-role startup after rollback/reapply | Passed: recovered schema boots and missing scope is denied |

The full suite covers `test/ops_brain/tenancy_test.exs`, `test/ops_brain/accounts_test.exs`, `test/ops_brain_web/authorization_test.exs`, entry and generated error-rendering tests. Earlier failures were an import ambiguity, Oban schema v12 versus required v14, controller form assigns, nested transaction rollback and a DOM root-filter assertion; all were fixed without removing tests or weakening authorization. No real source/SSO/TLS/load tests are claimed.

## Safety, sensitivity and limitations

Only synthetic identities and ephemeral local tokens were used. Operational names, memberships and session hashes are sensitive application state. Login capabilities must be delivered privately and never logged; inspected HTTP logs showed token/CSRF filtering. Production cookies are secure; source credentials are not modeled yet. The identity directory is intentionally global internal authorization metadata; operational RLS is not a claim of hard customer isolation. No exports or tenant PubSub subscriptions exist yet; later tasks must carry the same boundary into them.

There are no polling jobs, external effects, fabricated measurements or live integrations. Stopping the web/worker process leaves upstream systems unchanged. For disable/recovery, separate-role setup and destructive local rollback instructions see `ops_brain/README.md`. Rollback is not a substitute for backups. The temporary HTTP process and disposable PostgreSQL cluster were stopped after probing. Local PostgreSQL binaries/data remain under `/tmp/ops-brain-pg/`, outside the repository; they contain no real source data. Optional `inotify-tools` live reload is unavailable; regular HTTP/LiveView tests and serving work. Automatic session-token cleanup, source budgets, SSO/MFA, deployment hardening and external egress policy remain future/review work.

## Single next task
After independent review: **task 002 — durable Azure DevOps run polling**, against the synthetic contract first. Live access stays disabled pending explicitly approved source scope, credentials, egress and budgets. Do not treat this foundation as a completed command center.
