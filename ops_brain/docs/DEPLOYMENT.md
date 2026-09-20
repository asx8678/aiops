# Release/deployment handoff — disabled preparation only

No infrastructure, endpoint, credential, recipient or deployment is approved by these files. No CI deployment job, database container, automatic migration, seed, restart policy or production rollout is provided. Run one application instance only. Existing operations must continue independently if Constellation is stopped.

## Single-workspace entry

Set `OPS_BRAIN_WORKSPACE_COMPANY_ID` to the approved company UUID to pin the home dashboard for this deployment. The setting does not grant membership. Without it, exactly one authorized membership resolves automatically; ambiguity or missing access shows a setup state rather than a company chooser. Invalid/blank configured values never fall back to another workspace. Compose requires an explicit reviewed environment override for this optional setting. See [`SINGLE_WORKSPACE.md`](SINGLE_WORKSPACE.md).

## Actual release contract

- `mix.exs` targets Elixir `~> 1.17`; `mise.toml` selects Elixir 1.20.4 / OTP 27. The Docker template uses the real Docker Hub tag `elixir:1.20.4-otp-27-slim` (tag existence checked, not a fabricated digest). Resolve, scan and record the platform-specific digest before an approved build; this mutable tag is not a reproducibility guarantee. The same base is used in build/runtime to avoid OTP/OpenSSL/libc incompatibility. It intentionally retains the upstream Elixir/OTP tooling; no app source, build tool additions or credentials are copied from the build stage into runtime.
- Locked Phoenix/Bandit, LiveView, Ecto/Postgrex, Oban, Req/Finch and the concurrent OIDC slice's JOSE run in a single OTP release. PostgreSQL is the only durable service dependency. No Redis, Node asset toolchain, AI runtime, broker or paid service is required. Existing assets are in `priv/static`; Phoenix/LiveView/HTML vendor scripts are served from dependency `priv/static` directories. `mix phx.digest` precedes `mix release`; there is no `assets.deploy` alias to call.
- Use a DBA-approved supported PostgreSQL major (16 is a reasonable handoff baseline, **not compatibility-certified here**), TLS server certificate matching the URL hostname, and a mounted CA. This Compose file does not provision PostgreSQL or silently substitute a plaintext local database. Budget connections for runtime pool 10, Oban/listeners and separate maintenance connections; measure before changing limits.
- Application startup loads deployment JSON, Repo, `DatabaseSafety`, telemetry, PubSub, Oban, endpoint, watchers and scheduler. It does **not** migrate. The existing startup gate verifies protected-table FORCE RLS and non-owner/non-BYPASSRLS identity. The release preflight additionally checks schema/database/all-public-relation ownership and DDL/role privileges plus exact migration versions.
- Production config requires `DATABASE_URL`, `DATABASE_CA_FILE`, `PHX_HOST`, `SECRET_KEY_BASE`; `PHX_SERVER` must be exactly `true` to listen. The wrapper loads URL/signing secret from files before runtime config evaluation. Plain `bin/ops_brain` bypasses wrapper approval gates; container/operator control is a trusted administrative boundary, not adversarial sandboxing.

## Build and prepare (not authorization to execute against a live system)

From `ops_brain/`, after code review and build-network approval:

```sh
python3 -m unittest discover -s rel/tests -p 'test_*.py' -v
mise exec -- elixir rel/tests/runtime_contract_test.exs
docker build --pull --tag ops-brain:handoff .
```

The build needs approved Debian package, Hex/Rebar and dependency registry access. `.dockerignore` is an allowlist; local `deps`, `_build`, `.env`, backups, tests, SQL administration files and secret files are excluded. Do not put sensitive data under allowlisted source/static/overlay paths. No secrets are build arguments. Independently inspect/scan the resulting image and inventory its packages; neither tag existence nor a build is a security attestation.

Native and container releases use the same `config/prod.exs` and `config/runtime.exs`; Docker no longer concatenates config fragments. Shared compile-time `force_ssl` enables HSTS and `rewrite_on: [:x_forwarded_proto]`. Shared `HTTP_BIND` accepts exactly `127.0.0.1` (default) or `0.0.0.0`; others fail closed. Compose fixes loopback. Only an approved TLS proxy may reach the listener: forwarded headers are trusted, so a reviewed wildcard override MUST restrict direct ingress. Verified database TLS remains required.

### Internal operational metrics

Set `OPS_BRAIN_METRICS_CONSOLE=true` to supervise console export of sanitized application events; unset it or set `false` and restart to disable (default off). Pass it explicitly through the container environment when using Docker. Export covers queue/outcome counts, exceptions, Lifeline rescued/discarded totals, queue age/database size, terminal-job backlog and cleanup counts. These measure Constellation itself, not monitored-service health. Queue/state dimensions are allowlisted. Raw Oban, Repo and Phoenix events are NOT exported: the stock reporter prints all metadata. No source IDs, job arguments, SQL parameters or errors are exported.

Console output is per event, not a durable time-series store or rate-limited exporter. Route stdout to approved log collection and size retention/throughput before enabling. Backlog polling is every ten seconds; large-table query-cost/load validation and alert thresholds remain deployment gates.

Have the owner prepare private files **outside this repository** and a path-only environment file based on `.env.example`. Existing `.gitignore` does not ignore `.env`; never create a populated `.env` here. Requirements:

- `PHX_HOST`: approved bare hostname, canonical HTTPS port 443.
- Absolute `RUNTIME_DATABASE_URL_FILE`, `MIGRATION_DATABASE_URL_FILE`, `SECRET_KEY_BASE_FILE`, `DATABASE_CA_HOST_FILE`, `SOURCE_CONFIG_HOST_FILE` host paths. No placeholder path may exist as a substitute for real reviewed configuration.
- URL/signing secret readable by container UID/GID `10001:10001`; e.g. directory mode 0750 and files 0440 with a dedicated group. Docker Compose file-backed secrets are read-only **bind mounts**, not encrypted secret storage; file permissions must be enforced on the host. Do not rely on Compose `uid`/`mode` remapping for file sources.
- Start with an external copy of `config/sources.example.json` for no sources/sinks, or `config/sources.prepared.json` for complete disabled source/sink onboarding examples. Both keep collection/delivery false. The prepared file contains reserved `.invalid`/documentation IPs and replacement markers, not real endpoints/identities; the loader rejects placeholders when enabled. Replace every placeholder and approve the scope before activation, not just the enable switches. JSON is bounded to 64 KiB. `collection_enabled`/`delivery_enabled` are JSON keys, not environment toggles. Mount any later per-source CAs explicitly in a reviewed override.

```sh
# Nonsecret paths only. Treat rendered config as sensitive if later overrides add env secrets.
docker compose --env-file /etc/ops-brain/handoff.env -f compose.example.yml config --quiet
```

All services have profiles; plain `up` has no enabled service. Even explicitly selecting `app` bypasses profiles but still requires `OPS_BRAIN_START_APPROVED=true`; the migration service defaults to `disabled`. Missing files or empty values fail closed. There is no `build:` in Compose and no auto-production-deploy path.

## Role provisioning, migrations and grants — separate administrative actions

1. DBA creates an **empty, dedicated** database; database owner stays with DBA. Review `rel/roles.sql` and run it manually using `psql -X -v ON_ERROR_STOP=1 -v approved_database=EXACT_NAME -f rel/roles.sql` on a private approved DBA connection. It refuses a mismatched/nonempty public database, existing role names, or missing approval variable. Role names are cluster-global: provision a separate boundary or review an explicit adaptation for multiple deployments; do not silently reuse existing roles.
2. It creates NOLOGIN identities with **no passwords**. DBA later enables only approved authentication, restricts `pg_hba.conf`/network access and installs credentials through the secret channel. `ops_brain_migrator` owns public schema and migration objects, without superuser/BYPASSRLS. `ops_brain_runtime` has no ownership, CREATE, role membership, role administration, database creation or RLS bypass. `ops_brain_backup` is a separate normally-disabled BYPASSRLS boundary, never available to the app. NOINHERIT alone is not sufficient: runtime must have **no owner-role membership**, including indirect membership or SET ROLE ability.
3. Record backup/recovery approval, stop app/collectors and confirm the exact intended database. Use the migration URL file **only** in the maintenance container. No web server, scheduler, watcher or Oban is started by release `eval`:

```sh
docker compose --env-file /etc/ops-brain/handoff.env -f compose.example.yml \
  --profile maintenance run --rm -e OPS_BRAIN_MIGRATION_APPROVED=true migrate migrate
```

4. Review/apply `rel/runtime-grants.sql` **as `ops_brain_migrator`** to that same database, using `psql -X -v ON_ERROR_STOP=1 -v approved_database=EXACT_NAME -f rel/runtime-grants.sql`. Current application tables receive explicit DML, sequences USAGE/SELECT, Oban enum USAGE. Schema versions and authorization identity/membership tables are SELECT-only, token/OIDC attempt tables SELECT/INSERT/DELETE. OIDC session issuance uses SELECT-only operator checks and rechecks enabled status on every session use; no operator UPDATE is granted. Observation revisions permit INSERT/SELECT/retention DELETE, not UPDATE. Review these grants with the authentication owner; runtime has no company/membership provisioning privileges. No default DML on future tables: update the reviewed grant contract when schema changes.
5. Preflight under the runtime URL (read-only checks; **no DB creation or source HTTP**):

```sh
docker compose --env-file /etc/ops-brain/handoff.env -f compose.example.yml \
  --profile handoff run --rm app preflight
```

Preflight fails on wrong role, ownership/DDL privilege, missing RLS gate, missing/extra migration versions or invalid JSON. It does not prove all SQL privileges, cross-company isolation, source contracts, provider permissions, application behavior or restore fidelity. DBA must audit PUBLIC grants, functions, inherited roles and all FORCE RLS policies; perform the real database/authorization acceptance tests in an explicitly approved disposable environment later. These templates neither replace nor run that DB suite.

Offline operator/company provisioning currently exists as `mix ops_brain.bootstrap`, **not a release command**. Use a reviewed matching source checkout/toolchain with `MIX_ENV=prod`, migration identity, verified CA and required runtime variables to invoke the documented task after migrations. It uses `app.config`/Repo only, not application startup. Its 15-minute single-use token is secret stdout: no CI capture, logs, tickets or shell history. Deliver through the approved secret channel. There is no seed/default operator/password. Do not install Mix source into the runtime image to bootstrap it. See `CREDENTIALS.md` and the existing onboarding procedure for approval ownership.

## Host TLS proxy and network limits

This template targets a **dedicated Linux host**: `network_mode: host` preserves the existing `127.0.0.1:4000` listener. It is not a portable bridge-network recipe; publishing container ports will not fix a loopback-only listener. Docker Desktop, shared hosts, Kubernetes or bridge-network deployment require a separately reviewed topology/config change.

`rel/Caddyfile.example` is an optional host-proxy configuration, not an installed service. Validate it with an approved Caddy 2 installation (`caddy validate --config rel/Caddyfile.example --adapter caddyfile`) after supplying the hostname/certificate paths. Supply an approved certificate/key for the canonical hostname; automatic HTTPS/ACME and admin API are disabled. The proxy terminates HTTPS on 443, preserves Host, handles LiveView WebSockets and overwrites `X-Forwarded-Proto: https`. Restrict ingress to approved internal users/VPN. Test redirects, secure cookies, sign-in, locally served vendor assets and LiveView upgrade/reconnect through the real proxy before enabling collection. No blanket forwarded-header trust from arbitrary upstreams.

**Host networking supplies no container egress isolation.** Root filesystem read-only, dropped capabilities, nonroot UID, resource caps and URL/IP validation are not firewalls. The host, network team or platform must enforce and test ingress/egress: database hostname/IP/port, reviewed source IPs/origins, required DNS resolver, independently approved notification sink, and optional OIDC token/JWKS endpoints. Deny metadata endpoints, other internal services, AI endpoints and general Internet by default. Host-local processes can reach/spoof the trusted proxy listener; use a dedicated trusted host, not a multi-tenant machine. Keep Docker socket and host files out of the container. Build-time Internet access must not become runtime Internet access. DNS changes/source IP pinning need reapproval, not a permissive fallback.

## Start, health, stop and rollback

Only after the preceding approvals and preflight, set the path-only file's `OPS_BRAIN_START_APPROVED=true`, then explicitly start:

```sh
docker compose --env-file /etc/ops-brain/handoff.env -f compose.example.yml --profile handoff up -d app
```

The guarded `start` command first runs the same read-only release preflight with HTTP off, then starts the application only on success; it never migrates. Runtime is UID 10001, read-only root, no capabilities/new privileges, no distributed Erlang/epmd, with bounded writable `/tmp` for release config/crash files. Logs are bounded but can contain sensitive operational data; restrict access and do not collect crash dumps unreviewed. No persistent writable app volume is needed: PostgreSQL holds observations, sessions and jobs. Resource values (1 GiB, 2 CPUs, 256 PIDs) are pilot ceilings, not measured capacity or availability promises.

- Image healthcheck calls existing `/sign-in` on loopback with trusted HTTPS indication and requires **exactly 200**. It does not follow redirects, log in, or claim source/database readiness. A dead DB after startup can still yield a green liveness check.
- Invoke `app preflight` separately for DB readiness after migration/rotation/recovery. It creates a short-lived BEAM/Repo connection pool; do not run it on every request.
- Use the existing monitor for TLS expiry, HTTP/LiveView, job age/backlog, database capacity, collection freshness/lag/errors, unresolved mappings and notification ambiguity. Existing telemetry is not an automatically deployed metrics exporter or alert receiver. Missing/unconfigured telemetry is never healthy.
- Disable in an emergency by stopping the application first (`docker compose ... stop app`), then revoke source/sink access and set JSON collection/delivery false and startup approval false. Runtime JSON is loaded at startup; editing a mounted file is **not** a hot reload. Oban starts independently of scheduling; restored/persisted jobs may remain, so flags alone are not an air gap. Keep restored systems stopped and deny egress.
- Roll back an image only after verifying its schema compatibility; preflight rejects extra versions intentionally. There is no automated down migration. Prefer a reviewed forward fix or DBA-managed recovery to a new database followed by an explicitly approved cutover. Never use the disposable restore helper against production.

## Backup and isolated restore drill

Agree RPO/RTO, retention, encryption/key custody, off-host storage, restore frequency and budget **before rollout**. Logical dumps are not continuous PITR; arrange DBA-owned snapshots/WAL archiving if the required RPO needs them. Quiesce workers for a coordinated application snapshot; a `pg_dump` MVCC snapshot alone cannot prevent replay/delivery ambiguity after recovery. Back up reviewed configuration/version manifests and secret references separately; do not bundle secrets with data dumps.

Use host PostgreSQL clients matching the server major (dump client must not be older; use a compatible restore client), a private `PGSERVICEFILE` and 0600 `PGPASSFILE`, and an approved `PGSSLROOTCERT`. Service sections contain the exact hostname/port/dbname/user, TLS CA and no alternate/load-balanced target. Scripts strip other libpq environment options and force `sslmode=verify-full` in connection arguments; they never put passwords/URLs on argv. Backup service must be named `ops_brain_backup` with that user:

```sh
# Export only reviewed client-file paths/service, not a password in this command.
OPS_BRAIN_BACKUP_APPROVED=true PGSERVICE=ops_brain_backup \
  sh scripts/release-backup.sh /approved-private-backup-dir/new-archive.dump
```

The backup role needs SELECT on every current table/sequence and BYPASSRLS because FORCE RLS would make a normal owner/runtime dump fail or be incomplete. It is cross-company sensitive, read-only and separate from migration/runtime. Disable it outside approved backup windows. Dump files are created 0600 without overwrite; an error leaves a partial file that must be marked invalid, not accepted as a backup. Encrypt immediately using approved tooling, checksum the encrypted archive, and verify a real isolated restore; no encryption key or cloud storage is supplied here.

For a drill, DBA provisions a **new dedicated isolated PostgreSQL instance/database**, named `ops_brain_restore_<unique_suffix>`, with corresponding roles/schema. The database must be empty. The DBA explicitly sets database parameter `ops_brain.disposable_restore` to `dedicated-disposable` for that disposable target only. Do not add this setting to live/shared databases or connection profile options. Use `ops_brain_disposable_restore` service pointing directly to it as `ops_brain_migrator`; remove routing/DNS failover to live systems. With verified archive provenance and egress denied:

```sh
OPS_BRAIN_DISPOSABLE_RESTORE=I_CONFIRM_DEDICATED_DISPOSABLE \
  RESTORE_DATABASE=ops_brain_restore_reviewed_drill \
  RESTORE_CONFIRM_DATABASE=ops_brain_restore_reviewed_drill \
  PGSERVICE=ops_brain_disposable_restore \
  sh scripts/release-restore-disposable.sh /approved-private-backup-dir/verified.dump
```

The helper checks confirmation, dedicated prefix/service, actual database/user, server marker and absence of user relations before `pg_restore`. It requires the existing public schema to be owned by the migrator. It comments out only the archive TOC entry that would re-create that empty public schema (avoiding duplicate-schema errors), retaining table/data/policy entries. It restores in one transaction with `--exit-on-error --no-owner --no-privileges`; never `--clean`, `--create`, DROP or database deletion. Temporary TOC files are removed on exit. A trusted archive can execute SQL: never restore an untrusted dump. The marker is an administrative guard, not proof that an operator labeled a host correctly. Use an isolated host and scoped credentials; a mutable service/DNS between check and restore is outside this shell guard's protection.

Keep app/workers OFF. Reapply reviewed runtime grants, compare migration versions/row counts/constraints and all FORCE RLS policies, and run explicitly authorized tenant/session/job recovery checks. Restored login/session tokens and pending notifications are sensitive: DBA/auth owner must approve their invalidation and queue disposition before any app startup; the helper does not silently delete them. Only a successful timed drill establishes recoverability. Production cutover/restoration is a separate DBA procedure, not provided by this script.

## Verification boundaries

`rel/tests/` contains standalone release-only checks and client stubs. Run them separately from the application `mix test`/`mix precommit` suite; the application suite requires explicitly disposable databases and must not run concurrently with other database drills. YAML/SQL text contracts and shell tests are not Docker Compose validation or PostgreSQL privilege execution. A standalone Config.Reader test verifies production loopback/TLS/HTTPS behavior without starting the application. Report container build/boot, proxy validation, SQL application, migration execution and restore drills separately; never infer these from passing offline tests.
