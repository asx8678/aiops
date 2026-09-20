# Optional operator OIDC (offline implementation)

OIDC is **off by default**. Existing single-use token sign-in remains available.
No real identity provider was contacted, credentials acquired, registration created,
or deployment performed for this slice. JOSE **1.11.12** is pinned in `mix.exs`
and checksum-locked in `mix.lock`; JWT signing/verification is not hand-written.
Req **0.7.4** is the existing locked HTTP client.

## Security boundary and setup

A human identity administrator must review the exact issuer, authorization, token,
JWKS and application callback URLs, client registration, and subject mappings.
Only authorization code / query response mode, `openid` scope, S256 PKCE and
RS256 signed ID tokens are supported. There is no discovery, UserInfo, dynamic
registration, refresh, group synchronization, email linking, or auto-membership.
The authorization URL is the sole intentional browser redirect; server HTTP
redirects (including same-host redirects) and retries are disabled.

Runtime config `:ops_brain, :oidc` stores environment **names**, not secret values.
`OPS_BRAIN_OIDC_ENABLED` is read at boot; all other values are resolved when used.
Set these only after review (the names below are literal configuration keys):

| Environment key | Requirement |
| --- | --- |
| `OPS_BRAIN_OIDC_ENABLED` | Exact `true` to enable; unset otherwise |
| `OPS_BRAIN_OIDC_REVIEWED` | Exact `true`, documenting completed human review |
| `OPS_BRAIN_OIDC_ISSUER` | Exact issuer claim, including tenant/path/trailing slash |
| `OPS_BRAIN_OIDC_AUTHORIZATION_ENDPOINT` | Reviewed authorization URL |
| `OPS_BRAIN_OIDC_TOKEN_ENDPOINT` | Reviewed token URL |
| `OPS_BRAIN_OIDC_JWKS_URI` | Reviewed public signing-key URL |
| `OPS_BRAIN_OIDC_REDIRECT_URI` | Exact `https://<app-host>/auth/oidc/callback`, also registered at IdP |
| `OPS_BRAIN_OIDC_CLIENT_ID` | Reviewed client ID |
| `OPS_BRAIN_OIDC_AUTH_METHOD` | Explicit `none` (public PKCE client) or `client_secret_post` |
| `OPS_BRAIN_OIDC_CLIENT_SECRET` | Required only for `client_secret_post`; inject through secret manager |
| `OPS_BRAIN_OIDC_SUBJECTS` | JSON object mapping exact case-sensitive `sub` to existing operator UUID |

Synthetic mapping shape (not a real operator):

```json
{"approved-subject":"00000000-0000-4000-8000-000000000001"}
```

An enabled existing local operator is necessary; memberships remain entirely local
and must already be approved. Provider email, tenant, roles and groups never create
an operator or confer company authority. Sessions use the existing eight-hour,
revocable token mechanism; every use rechecks enabled status and company membership.
The runtime needs only SELECT on operators, not permission to update operators.

All configured URLs must be canonical HTTPS on implicit port 443, lowercase DNS
hosts, and plain ASCII unreserved paths. Userinfo, explicit ports, queries,
fragments, percent encoding, dot-dot paths and control characters are rejected.
An incomplete/unreviewed configuration hides the OIDC button and denies its routes.
The request's effective HTTPS scheme, host and port must match the callback origin.
Configure trusted proxy/TLS handling with the deployment owner; do not trust arbitrary
forwarded headers. Production already enables secure session cookies.

Use firewall/egress policy for the reviewed identity destinations. This module
verifies TLS hostname/certificate chains but **does not pin DNS/IPs**. Endpoints
cannot come from browser parameters, JWT `jku`/`jwk`/`x5u`, or discovery responses.
The trusted-code `:oidc_http_plug` test seam must be absent in deployment; it has
no environment or browser configuration surface.

## Flow and sensitive data

- CSRF-protected `POST /auth/oidc` generates independent 256-bit state, nonce and
  PKCE verifier. Authorization requests contain no client secret or verifier.
- A five-minute encrypted `__Host-ops_brain_oidc` cookie is Secure, HttpOnly,
  host-only, path `/`, SameSite=Lax. This is separate from the existing Strict
  session cookie. It binds the flow to the browser and remembers the previous
  local session for revocation after success.
- `oidc_attempts` stores only SHA-256 state hashes and integer expiry timestamps.
  Atomic DELETE consumes a valid pending state **before HTTP**, even on a bad-state,
  provider-error, token-validation or configuration-change failure. A copied old
  encrypted cookie cannot revive it. Expired rows are purged on initiation.
- `GET /auth/oidc/callback` checks cookie, single-use state, configuration fingerprint,
  callback state/optional issuer, PKCE token exchange, exact signed issuer/audience,
  `azp` for multiple audiences, expiry, issued-at, optional not-before, nonce,
  bounded nonempty subject and preapproval. JOSE uses a strict RS256 allowlist and
  a unique matching `kid` from the reviewed JWKS; ambiguous/invalid/unknown keys fail.
- Success renews/clears the session and renders a local **Continue to Constellation**
  link. The intentional full document + user navigation ends the cross-site chain
  before sending the Strict session cookie. Failure deletes the OIDC cookie and
  returns a generic 401, without echoing provider/user parameters.
- HTTP responses are limited to 128 KiB, ID tokens to 32 KiB and JWKS to 32 keys.
  Requests use verified TLS, 5s connection/receive and 10s request timeouts, no
  decompression, no retries, no redirects; only HTTP 200 JSON objects are accepted.
- Tokens, provider bodies, claims, nonce and verifier are not persisted in DB or
  jobs. Access/refresh tokens are discarded. Client secrets stay in runtime memory
  and the token POST body, never authorization URLs or JWKS requests.
- OIDC route parameter logging is disabled. Phoenix parameter filters also include
  code/state/nonce/error_description and existing token/password/secret filters.
  Do not enable HTTP body/headers, cookie or query-string logging in proxies/APM;
  application filtering cannot protect independently configured infrastructure logs.

## Migration and integration

New migration: `priv/repo/migrations/20260919152711_add_oidc_attempts.exs`, generated
with `mix ecto.gen.migration add_oidc_attempts --no-compile`. No old migration changed.
Apply it using the migration role, then have the grant-file owner/DBA add:

```sql
GRANT SELECT, INSERT, DELETE ON oidc_attempts TO ops_brain_runtime;
```

No UPDATE privilege or company RLS is needed for this global authentication table:
it contains no operational/company data. Existing grants for operator/session reads
and token insertion/deletion are reused. The migration itself intentionally contains
no environment-specific role provisioning. This migration and both runtime grant contracts were applied and tested against the dedicated local PostgreSQL instance.

## Acceptance ledger and commands

Run from `/home/adam/projects/aiops/ops_brain` with the existing toolchain:

```sh
# Offline, no Repo/application start and no database test_helper:
MIX_ENV=test mise exec elixir@1.20.4-otp-27 erlang@27.3.4.16 -- \
  mix run --no-start test/oidc/offline_helper.exs

MIX_ENV=test mise exec elixir@1.20.4-otp-27 erlang@27.3.4.16 -- \
  mix compile --warnings-as-errors

# Main/test owner only, after migration and grants; no concurrent DB suite:
MIX_ENV=test mise exec elixir@1.20.4-otp-27 erlang@27.3.4.16 -- \
  mix test test/oidc/database_test.exs test/ops_brain/accounts_test.exs \
  test/ops_brain_web/authorization_test.exs test/ops_brain_web/operations_live_test.exs
```

The integrated application suite now runs the offline and real PostgreSQL OIDC tests alongside tenant/LiveView regressions. See `../../ops_command_center_v2/PREPARATION_STATUS.md` for final counts, multi-connection probes and release checks. Formatting and production compilation pass.

Offline assertions cover actual JOSE signatures, forged/symmetric/malformed tokens,
issuer/audience/time/nonce/JWKS denial, fresh PKCE, real Req form/body contracts,
no redirect/retry, response limits, explicit secret transport, log non-reflection,
disabled/missing config, route/CSRF registration, UI and replay denial (including
provider failure and old ID-token nonce). The pure replay store is an atomic Agent
fixture, **not evidence of PostgreSQL concurrency behavior**.

`test/oidc/database_test.exs` adds actual PostgreSQL uniqueness/one-winner
consumption/expiry, existing-membership-only authorization, disabled/missing
operators, encrypted callback cookies, session rotation/revocation and copied-cookie
HTTP replay tests. Those tests passed in the integrated serial database suite. The OIDC test uses four concurrent callers with the ordinary pool1; it is not a multi-connection contention test. The separate `scripts/concurrency_check.exs` uses pool4/client concurrency8 for tenant grouping/isolation and source-budget checks only, not OIDC. Multi-connection/multi-node OIDC contention remains untested.

Run `mix precommit` only against disposable databases, not concurrently with another DB suite/drill.

## Disable/recovery and remaining limits

Unset `OPS_BRAIN_OIDC_ENABLED` (or set false) and restart to disable. Existing token
sign-in works without any OIDC setting. Existing sessions remain valid until their
normal expiry/revocation; disable an operator or revoke its sessions for immediate
local removal. Removing a subject mapping prevents new OIDC sessions, not existing
sessions. Configuration rotation invalidates pending flows; start again. A failed
exchange is deliberately not retryable with the same cookie/code.

Remaining gates: real provider registration/contract verification, trusted HTTPS
proxy and browser cookie round-trip, egress/DNS controls and reviewed ingress rate limits. `LoginLimiter` admits at most30 requests per peer/minute and200 total/minute across sign-in/OIDC initiation/callback, bounding peer-map cardinality to200; it is node-local and does not trust arbitrary X-Forwarded-For. Behind a proxy its peers may share a bucket, so review trusted ingress limits rather than assuming per-user protection. Explicit disabled-by-default maintenance bounds expired-attempt cleanup. No JWKS cache,
clock-skew allowance, multi-issuer federation, token introspection, provider logout,
back-channel logout, MFA/acr policy or provider account-disable synchronization is
implemented. A fresh JWKS read is required on every exchange. This is not a claim
of production readiness or live integration success.
