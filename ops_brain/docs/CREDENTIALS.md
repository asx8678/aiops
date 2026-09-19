# Credential and endpoint approval handoff

**Preparation only. No live credential has been requested, created, fetched, stored or validated against a live endpoint.** No source reads, notification sends, cloud provisioning or OIDC provider contact are authorized here. Source administrators, not the runtime app, perform setup. See `DEPLOYMENT.md`, existing `ONBOARDING.md` and `../../ops_command_center_v2/SOURCE_ACCESS.md` for boundaries.

## Ownership and required approvals

Record each approval in the organization's existing protected process (not these files): owner, exact company/source/environment, endpoints/IPs/ports/CA, permitted operations/resources, inherited permissions, expiry/rotation and revocation owner, query/load/cost budget, sensitive-data retention, review evidence and rollback/disable plan. A filled template is not approval.

| Boundary | Required later handoff | Exclusions / treatment |
| --- | --- | --- |
| Build/release publisher | Approved registry/build-host access, dependency mirrors, platform and scanned resolved image digest | No source observation, runtime DB or production deploy credential in builds; no automatic deployment permission |
| Runtime PostgreSQL | `ops_brain_runtime` URL secret, exact TLS hostname/database, mounted trusted CA, connection budget | No schema/table/database ownership, superuser, BYPASSRLS, CREATE, owner-role membership or role administration |
| Migration/bootstrap | Separate short-lived `ops_brain_migrator` connection on a controlled maintenance host/container | Schema owner only in dedicated app DB; never mounted into runtime; no source credentials; no runtime startup |
| Backup/restore | Normally-disabled `ops_brain_backup` read identity with BYPASSRLS; independent storage encryption/key custody; disposable restore identity/profile | Cross-company access requires explicit approval/audit. Runtime must never receive it. No live restore shell path |
| Phoenix session protection | Cryptographically generated `SECRET_KEY_BASE` (at least 64 bytes), approved secret distribution | No default value; no token in logs/argv/build layers. Same key on a replacement instance until an approved rotation |
| Source observation | Per-company/source/environment bearer secret referenced by JSON `credential_env`; approved origin/IP and optional CA mounts | Read-only operation scopes, no mutation/admin rights; no sharing notification identity; never arbitrary user URLs |
| Optional notification sink | Separate send-only credential, exact HTTPS URL/IP, fixed destination/company and content approval | Disabled by default. No source mutation, broad channel history, routing administration or dynamic recipients |
| Optional OIDC | Auth owner's approved issuer/client/redirect/subject mapping and exact authorization/token/JWKS endpoints; optional client secret | Independent from source/notification identities; off in this Compose template; no automatic enrollment/membership |
| TLS proxy/network | Approved internal DNS, certificate/key chain, renewal owner, trusted host proxy and network allowlist | No automatic ACME, public exposure or claimed egress isolation from Compose host mode |

No default passwords/accounts or example usable tokens exist. An administrator must approve authentication method and enable the NOLOGIN database roles using their established secret mechanism; do not paste `ALTER ROLE ... PASSWORD` commands into tickets/history. Keep connection credentials in externally owned secret files and private libpq service/pass files, not the path-only Compose environment file. URL-encode reserved characters in DB URL credentials. Certificate material and endpoints may be nonsecret but are security-sensitive configuration.

Use `config/sources.prepared.json` as the complete **disabled** source/sink handoff example, or `config/sources.example.json` for an empty deployment. Reserved hostnames/IPs and replacement markers are intentionally rejected by the loader if enabled. Neither file grants access or provisions the referenced identities. Copy privately outside the repo and replace/review all scope and endpoint placeholders before activation.

## Source credentials: current implementation, not aspirational access

The actual source transport reads `credential_env` with `System.get_env` and sends `Authorization: Bearer ...`. It does not mint/refresh cloud tokens or implement PAT Basic authentication; a PAT cannot be assumed to work by putting it in the bearer slot. Arrange an approved token lifecycle externally or coordinate a separate adapter change. Do not copy a personal administrator's token.

Approve only adapters/resources actually implemented at the reviewed revision: Azure Build/YAML read paths and approved project/definitions, approved Prometheus query profiles, scoped Loki tenant/selector profiles, namespace-specific Kubernetes resources explicitly covered by the current workload slice. Review concurrent workload changes and its onboarding instructions before expanding RBAC; never infer full cluster coverage from a Kubernetes credential. Deny Secrets/exec/attach/proxy, source administration, pipeline trigger/rerun/cancel, config writes, log ingestion/deletion and unimplemented APIs. Policy inspection and controlled disposable negative tests are required; **never attempt a production write to prove it fails**.

Use fixed approved HTTPS origins and pinned IPs from deployment-owned JSON. Approve provider TLS, actual metric/log semantics and query budget before enabling a source. `network_reviewed` and application allowlists do not install firewall rules. Backend tenant headers alone do not establish authorization. Cloud query charges and workload impacts remain real even though no paid service is provisioned by these templates.

Compose mounts only database/session/CA inputs. Source/sink credentials must be explicitly injected by a reviewed secret-manager integration or external override, under the exact referenced env name; `_FILE` is **not** a generic application convention. Only the release wrapper translates `DATABASE_URL_FILE` and `SECRET_KEY_BASE_FILE`. Never add broad `env_file` injection of unrelated administrative secrets. Do not mount the Docker socket, host kubeconfig or cloud administrator home directory.

## Optional OIDC configuration

The implemented flow registers `POST /auth/oidc` and `GET /auth/oidc/callback`; see `OIDC.md` for tested behavior and limits. This handoff grants no live IdP approval. `.env.example` lists the current runtime names; Compose forces `OPS_BRAIN_OIDC_ENABLED=false` and does not forward provider settings. Enable only with a separately reviewed override and the authentication owner's test evidence:

- `OPS_BRAIN_OIDC_ENABLED=true` **and** `OPS_BRAIN_OIDC_REVIEWED=true`.
- `OPS_BRAIN_OIDC_ISSUER`, `OPS_BRAIN_OIDC_AUTHORIZATION_ENDPOINT`, `OPS_BRAIN_OIDC_TOKEN_ENDPOINT`, `OPS_BRAIN_OIDC_JWKS_URI`: exact reviewed HTTPS endpoints; no auto-discovery assumption. Approve DNS/egress separately for server token/JWKS requests and browser authorization navigation.
- `OPS_BRAIN_OIDC_REDIRECT_URI`: exact canonical HTTPS origin on port 443 with `/auth/oidc/callback`; register precisely with the provider. Verify proxy Host/protocol/port forwarding and browser secure-cookie behavior; never use arbitrary return URLs.
- `OPS_BRAIN_OIDC_CLIENT_ID`, `OPS_BRAIN_OIDC_AUTH_METHOD`: current methods `none` (public client) or `client_secret_post` (confidential client); the latter requires `OPS_BRAIN_OIDC_CLIENT_SECRET`. Choose per IdP policy, never downgrade silently. There is no client-secret `_FILE` loader in this handoff.
- `OPS_BRAIN_OIDC_SUBJECTS`: deployment-owned bounded JSON mapping exact immutable provider subject to an **existing** approved operator UUID. Provider email/domain/groups/tenant claims do not automatically create operators or company memberships. Protect this mapping as access-control configuration; review changes with the membership owner.
- Current flow requests fixed `openid`, uses PKCE, and verifies RS256; `OPS_BRAIN_OIDC_SCOPES` is not supported. Validate provider compatibility, clocks, logout/session revocation, callback replay handling, failure paths and key rotation with the auth owner; these are not live-tested by release tests.

The OIDC attempt table is included in both grant files. `Accounts.issue_oidc_session` uses SELECT-only operator checks and every session use rechecks operator enablement. Runtime has no operator UPDATE privilege or company/membership administration.

Token sign-in remains the offline fallback: `mix ops_brain.bootstrap` in a controlled matching source checkout emits a single-use 15-minute login capability on **secret stdout**, not in the release image. Follow authentication-owner session revocation instructions; never put capabilities in URLs, monitoring probes, screenshots or exports.

## Handling, rotation and incident response

- Store secrets outside this repository and image. Local `.env*` files (except `.env.example`), secret directories, private key files, dumps and local source configs are ignored as defense in depth, not permission to store secrets in this checkout. Compose file-backed secrets are host bind mounts, not encrypted at rest. Require least-privilege file ownership, private directories, audited access and independent encryption/backups. Process environment is readable to host/container administrators; nonroot runtime does not protect against them.
- Keep sensitive source text out of credentials/config identifiers. Never persist credentials in DB records, Oban arguments, fixtures, metrics labels, notification bodies, stack traces or UI. Redaction is a layer, not proof that captured logs/dumps contain no secrets. Disable proxy access/query logging for login/OIDC callbacks or approve sanitization first.
- Record expiry and rotate per boundary, not as one shared key. DB/session file updates require container recreation/restart to refresh exported environment; atomically replaced bind-mounted files may require recreation even if their host path is unchanged. Test new database CA chains and endpoint hostname verification before removing old trust. Source credentials are env references, not dynamically refreshed secret-manager clients.
- Signing-key rotation invalidates browser cookies; it does not delete server-side token hashes or prove complete incident revocation. Auth owner must approve server token revocation too. Source/sink revocation belongs to their owners. For suspected leakage stop application/egress immediately, revoke affected identities, preserve sanitized audit evidence and review downstream access.
- Backups include operator/token metadata, company membership, observations and notification/job state across companies. Encrypt, restrict and retain accordingly. Restore may resurrect valid sessions or queued delivery; never start a restored instance against real sinks without an approved invalidation/queue review.

## Required before first live pilot

Human sign-off on dedicated host/network/TLS, database roles/RLS/backup drill, release build/boot and vulnerabilities, operator/company mapping, one bounded source identity/query budget, actual endpoint/read contract and retention is still required. OIDC and external delivery have independent gates and can remain off. A second company requires the existing multi-company security gate. No paid/live infrastructure, source credentials, default accounts, production deployments or live integration success are implied by this handoff.
