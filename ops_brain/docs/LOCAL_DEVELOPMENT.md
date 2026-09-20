# Temporary local no-login mode

Constellation now opens directly at **http://localhost:4000** in local development,
without pasting an access token. The existing operator `adam` is selected explicitly.
The top bar displays **LOCAL · NO LOGIN**; sign-out controls are hidden in this mode.
Visiting `/sign-in` also creates a session automatically and redirects to `/`, even
for a fresh browser without cookies.

This is a development convenience, not anonymous production access. Every browser
still receives a normal encrypted-cookie, revocable eight-hour session. The token
schema, offline bootstrap and OIDC remain intact for normal authentication. No
operators, memberships, source credentials or data are deleted or auto-created.

## Boundaries

- Session issuance code is compiled **only in `MIX_ENV=dev`**. Test/production
  builds remain authenticated even if `dev_auto_login` is set true at runtime.
- Page GETs skip login regardless of listener address, peer, host, forwarding
  headers or cross-site browser headers. POSTs, auth callbacks and logout do not
  create sessions automatically. The default listener still binds loopback.
- **Keep the development server private.** Anyone who can reach it, including
  through a proxy or tunnel, can act as the configured operator without a token.
  Disable this mode before sharing/exposing the server; use a production build
  for deployment.
- `OPS_BRAIN_DEV_OPERATOR` must name an existing enabled operator (default `adam`).
  A missing/disabled operator never falls back to the first user or gains membership.
- Existing valid sessions are preserved. Membership checks and database RLS still
  apply on all routes, LiveView events and operational reads. Collectors stay off.
- Anyone able to access this local mode can act as the configured operator. Revoking
  a browser session alone does **not** block local reentry while this mode is on;
  disable the mode/operator or remove membership to revoke that access.

## Restore login

Restart the development server with `OPS_BRAIN_DEV_AUTOLOGIN=false`. Normal token
or approved OIDC login is then used. Existing sessions still expire normally; use
Sign out to revoke the current browser session. These environment settings are
read by `config/dev.exs`, so changing them requires a restart/recompile.

## Checks

Latest verification after removing the host/proxy gate:

- `mix precommit`: **233 tests passed** (including the normal-auth regression
  module), with compilation/formatting completed.
- Actual `MIX_ENV=dev` script: **9 tests passed**. Fresh requests work across
  peer/host/proxy combinations; disabling the flag prevents issuance; existing
  sessions and tenant authorization remain enforced.
- Production compilation with warnings-as-errors passed. A loaded production BEAM
  probe kept auto-login disabled even with the runtime flag forced true; no DB
  was started. An initial CLI glob-quoting error was corrected for the probe.
- **10 cookie-free HTTP checks passed** for home, demo, services, investigations
  and sign-in, both normally and with foreign-host/forwarded/cross-site headers.
- **3 isolated-browser checks passed**: fresh `/sign-in` entry redirects to a
  connected workspace, LiveView navigation reaches services, and reload stays
  authenticated without a form. The temporary browser context was disposed.
- The dev server was restarted after Phoenix required a config reload. The
  default listener remains `127.0.0.1:4000`; no public bind was enabled.

Latest artifacts:
- `/tmp/constellation-skip-login-precommit.log`
- `/tmp/constellation-skip-login-dev.log`
- `/tmp/constellation-skip-login-prod.log`
- `/tmp/constellation-skip-login-browser.json`
- `/tmp/ops_brain_server.log`

Historical verification of the initial loopback-restricted mode (before the
host/proxy restriction was removed):

| Acceptance check | Result |
| --- | --- |
| Full `MIX_ENV=test mix ci` (format, compile, tests) | **220 passed**, no failures |
| Actual development-build issuance checks | **8 passed** after fixing the probe repo lifecycle |
| Production build and forced-true runtime flag probe | Compile passed; auto-login remained disabled without starting a DB |
| Cookie-free HTTP/browser entry through `/` and `/sign-in` | Workspace opened automatically; no login form or sign-out controls |
| Fresh-browser LiveView company/pipeline navigation | Passed |
| Desktop/mobile layout at 1440, 390, 320 pixels | Visible mode marker; no horizontal overflow or browser exceptions |
| Gzip, active digest and live stylesheet delivery | Byte-identical to source |
| Diff and format hygiene | Passed |

Tests used only the previously approved disposable `ops_brain_test_ui_20260920`
database. The local app remains on `ops_brain_dev`; no synthetic fixtures were
inserted there. No production service/provider was contacted. Initial inherited
compile errors and the standalone test repo lifecycle failure were fixed.

Local artifacts:
- `/tmp/constellation-no-login-tests.log`
- `/tmp/constellation-no-login-dev-checks.log`
- `/tmp/constellation-no-login-prod.log`
- `/tmp/constellation-no-login-browser-checks.json`
- `/tmp/constellation-no-login-1440.png`
- `/tmp/constellation-no-login-320.png`
- `/tmp/constellation-server.log`

Normal auth regression module: `test/ops_brain_web/dev_auto_login_test.exs`.

The development-only issuance path has a separate executable test script because
it is deliberately absent from the test build. Run it only against a previously
approved disposable `ops_brain_test...` database, with both URLs naming that same
DB and separate runtime/migrator roles (see the README's database safety rules):

```sh
MIX_ENV=dev OPS_BRAIN_DISPOSABLE_TEST=true PHX_SERVER=false \
  DATABASE_URL="$DISPOSABLE_RUNTIME_URL" \
  MIGRATION_DATABASE_URL="$DISPOSABLE_MIGRATOR_URL" \
  mise exec -- mix run --no-start scripts/dev_auto_login_check.exs
```

The script checks database approval and live identities before truncating any
fixtures. Never point it at `ops_brain_dev` or other valuable data.
