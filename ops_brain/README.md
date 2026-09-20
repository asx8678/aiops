# Constellation — read-only operations command center

Constellation is the product name. Internal `OpsBrain`/`OpsBrainWeb` modules, `ops_brain` application/directory/database identifiers, and `OPS_BRAIN_*` configuration names remain unchanged for compatibility; the commands below still apply.

Phoenix/LiveView, Ecto/PostgreSQL and Oban. Local functionality includes authenticated company isolation, durable Azure Build polling, bounded failure evidence, exact grouping/local notices, configurable Prometheus/Loki reads, explicit service identities, namespace Deployment/ReplicaSet/Pod/Event watches, conditional capacity evaluation, evidence-linked change candidates, optional approved HTTP delivery, retention and replay.

**Not production-ready or live-validated.** Collection and delivery are disabled by default. No runtime AI, remediation, source mutation or fabricated healthy data. Precise task/gap ledger: [`../ops_command_center_v2/IMPLEMENTATION_STATUS.md`](../ops_command_center_v2/IMPLEMENTATION_STATUS.md). The user explicitly requested all remaining local slices; original safety gates remain binding.

## Single-workspace home

Open **http://localhost:4000/** for the “A clearer view of operations” home, with direct operations navigation and Development / Staging / Production cards. No company selection is needed. Local development selects the seeded demo; deployments use `OPS_BRAIN_WORKSPACE_COMPANY_ID` for an approved company. Membership checks remain intact. See [`docs/SINGLE_WORKSPACE.md`](docs/SINGLE_WORKSPACE.md) for setup, environment filtering, and monochrome logo assets.

## Offline demo — no cluster access required

A separate **Demo · Northwind Retail** workspace contains two simulated Kubernetes clusters, 210 pods, databases, pipeline history, and evidence-linked investigations. All demo pages are explicitly labeled synthetic. See [`docs/DEMO.md`](docs/DEMO.md) for provisioning, the guided tour, reset/removal, and verification. No live connector configuration is changed.

## September 20 repair status

The current repair pass is **partial**. See [`REPAIR_STATUS.md`](../ops_command_center_v2/REPAIR_STATUS.md) for R01–R25 status and actual checks. Quoted-assignment redaction now consumes malformed quoted tails, validates UTF-8 before regex processing, and rejects inputs over 1 MiB. This does not sanitize previously stored evidence or backups; any such remediation requires separate authorization. Lifecycle, scheduling, retention, CI and composed acceptance work remain outstanding.

## Ready-to-fill preparation

Start with [`docs/CREDENTIALS.md`](docs/CREDENTIALS.md), [`config/sources.prepared.json`](config/sources.prepared.json), and `.env.example`. All connectors, notifications, OIDC and scheduled maintenance default off. Untouched source/sink placeholders are rejected if enabled. Supply secret references through private environment or mounted secret files, never chat or tracked configuration.

Release/Docker/Compose, separate-role SQL, preflight and guarded backup/restore helpers: [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md). Container execution and live-provider validation still require your approved environment; no infrastructure is automatically provisioned. Current evidence/gaps: [`../ops_command_center_v2/PREPARATION_STATUS.md`](../ops_command_center_v2/PREPARATION_STATUS.md).

## Local setup

Tested: Elixir 1.20.4 / Erlang OTP 27.3.4.16, PostgreSQL 16.15. `mise.toml` selects the runtime. `mix.lock` genuinely resolves Phoenix1.8.14, LiveView1.2.12, Ecto3.14.2, Oban2.24.1, Postgrex0.22.4 and Req0.7.4. JS is served locally from locked dependencies; no Node/CDN.

```sh
mise exec elixir@1.20.4-otp-27 erlang@27.3.4.16 -- mix setup
```

`mix setup` resolves/compiles only. An administrator must create distinct identities and **dedicated disposable local databases**, not use monitored application databases:

```sql
CREATE ROLE ops_brain_migrator LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
CREATE ROLE ops_brain_runtime LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
CREATE DATABASE ops_brain_dev OWNER ops_brain_migrator;
CREATE DATABASE ops_brain_test OWNER ops_brain_migrator;
```

Use local authentication or secret-managed passwords, not fixed examples. Set `MIGRATION_DATABASE_URL` to the owner connection and `DATABASE_URL` to the runtime connection for the same database. PostgreSQL-format URLs also work with `psql`. Never track secrets.

```sh
DATABASE_URL="$MIGRATION_DATABASE_URL" mix ecto.migrate
psql "$MIGRATION_DATABASE_URL" -v ON_ERROR_STOP=1 -f priv/repo/runtime_grants.sql
```

All migrations are required. Startup verifies forced RLS/non-ownership on 15 operational tables and refuses superuser/BYPASSRLS/owner identities. The company/operator/membership/session directory remains internal authorization metadata, not a global operator data API. Runtime cannot administer identities.

## Authentication and use

**Temporary local mode:** development now opens directly at `http://localhost:4000` as the existing `adam` operator, without a login form or token entry. Development page GETs skip login regardless of host/proxy headers; keep the development listener private because anyone who can reach it can act as that operator. Production/test authentication is unchanged. See [`docs/LOCAL_DEVELOPMENT.md`](docs/LOCAL_DEVELOPMENT.md) for configuration, restrictions, tests, and how to restore normal login. The following token/SSO workflow applies outside that local mode.

Optional OIDC SSO is implemented and disabled until configured; see [`docs/OIDC.md`](docs/OIDC.md). MFA policy is enforced by the approved identity provider, not inferred by this app. Offline-issued 256-bit single-use capabilities remain available, stored hashed. No public registration, default password or production bypass:

```sh
DATABASE_URL="$MIGRATION_DATABASE_URL" mix ops_brain.bootstrap \
  --operator your-approved-operator --company your-approved-slug --name 'Your Company'
mix phx.server
```

Bootstrap does not start the web app. It explicitly grants membership and prints a **secret** 15-minute token: distribute privately, never capture stdout in CI/chat/tickets. It creates dev/staging/prod identities, not monitored targets. Re-running grants membership/another token; disabled operators stay disabled.

Open `http://localhost:4000/sign-in`. Exchange for an encrypted/revocable eight-hour session; logout revokes it. Disabling an operator/deleting membership invalidates later requests/navigation/events/refreshes. Already delivered browser content cannot be erased retroactively.

Company pages: `/companies/:company_id` and its `/pipelines`, `/services`, `/investigations`, `/capacity`, `/source-health` routes. Operational pages refresh every10 seconds, reauthorizing before reads. Lists cap at100; evidence panels at25. Acknowledgment, closure, assignment API and UI snooze affect this application only. No page exposes global Oban arguments/errors. Exports/data caches are not implemented.

## Source approval and configuration

See [`docs/ONBOARDING.md`](docs/ONBOARDING.md) and [`docs/SECOND_COMPANY_GATE.md`](docs/SECOND_COMPANY_GATE.md). `OPS_BRAIN_CONFIG_FILE` selects a deployment-owned JSON file (max64KiB). The example has **no sources/destinations** and both switches off:

```sh
mix ops_brain.validate_config config/sources.example.json
```

Offline validation does not prove permissions, real metric names or network access. Source identities must already exist in the company. Credentials are environment references, never JSON token values. Source HTTP uses fixed approved IPs, verified original-host TLS, allowlisted reads, bounded responses and no redirect forwarding. A reviewed egress firewall remains required.

Jobs perform one bounded collection step with durable checkpoints/snapshots and fenced ownership. Shared source request admission also covers enrichment. The supervised bounded workload watches persist per-resource positions atomically with evidence and report gaps. See [`docs/WORKLOADS.md`](docs/WORKLOADS.md). Classic releases, Kubernetes Secrets/exec and upstream writes are unsupported. External delivery uses a separately approved fixed HTTP sink; ambiguous outcomes require review, never automatic replay.

## Verification

Tests require newly provisioned disposable `ops_brain_test...` databases and **both** URLs pointing to the same local server/database with distinct runtime/migrator identities. Fixtures truncate local tables between serial DB cases. Never point tests at valuable data.

Before testing, explicitly approve only the newly created disposable database as administrator with `ALTER DATABASE <exact_new_test_database> SET ops_brain.disposable_test='approved';`, then export `OPS_BRAIN_DISPOSABLE_TEST=true`. Never mark an existing valuable database. The test helper checks approval and live connection identity before any test module runs. Use `mise exec -- mix ci` for non-mutating checks; `mix precommit` remains an auto-formatting developer command. The added GitHub workflow has not been remotely verified and does not yet cover all release/container acceptance gates. OpenSSL creates ephemeral local TLS test certificates; tests remove them. No real provider is contacted.

```sh
mix precommit
mix format --check-formatted
MIX_ENV=prod mix compile --warnings-as-errors
mix phx.routes
mise exec elixir@1.20.4-otp-27 erlang@27.3.4.16 -- elixir \
  -r lib/ops_brain/capacity.ex scripts/capacity_backtest.exs --run
```

The synthetic backtest reports false/missed warnings, not calibrated prediction. Actual commands/load methodology are in the ledger.

## Disable, production controls and recovery

Production requires `DATABASE_URL`, `DATABASE_CA_FILE`, `PHX_HOST`, `SECRET_KEY_BASE`; optional `PORT`/`POOL_SIZE`. `PHX_SERVER=true` serves. Cookies are Secure/HttpOnly/SameSite=Strict; DB TLS verifies peers; HTTPS is forced; development binds loopback. Proxy trust, identity policy, network, permissions, budgets and deployment approvals remain external gates.

Disable a source in trusted JSON and restart; jobs re-resolve configuration. Set `collection_enabled`/`delivery_enabled` false and restart to disable scheduling/delivery, or stop the app unconditionally. Existing upstream monitoring/paging stays unchanged. Partial checkpoints resume boundedly; never clear them merely to display green.

Back up only this app's DB using a separately approved backup role able to read protected rows: forced RLS means migration ownership alone may be insufficient. Encrypt/restrict backups, which include identities/session hashes/evidence. Restore first into an isolated DB with collectors off, verify data/runtime grants/RLS, then approve enabling access. A local `pg_dump -Fc`/`pg_restore --exit-on-error` round trip and new-migration rollback/reapply were tested on synthetic data, not production.

`DATABASE_URL="$MIGRATION_DATABASE_URL" mix ecto.rollback` is destructive and for disposable schema testing only. Reapply all migrations/grants and restore backup if state is needed. Retention tombstones evidence and deletes bounded old windows/snapshots. Exact replay then expires. Versioned replay covers retained pipeline, metric, log, workload, capacity and correlation detector inputs without HTTP, delivery or human-review changes. Pre-upgrade output-only/missing/expired inputs remain explicitly unreplayable; replay does not rewrite issue lifecycle or human decisions. See [`docs/REPLAY_RETENTION.md`](docs/REPLAY_RETENTION.md).
