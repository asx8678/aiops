# Operations console UI redesign

## Delivered

- Local, dependency-free CSS design system and SVG icons: navy/slate navigation with blue accents, a cool-neutral light workspace, consistent spacing, badges, cards, tables, and accessible focus states. Green is reserved for semantic success badges; amber warnings and red errors are unchanged.
- Responsive sign-in and SSO completion screens; token/CSRF/session behavior unchanged.
- Searchable authorized company directory and a company overview with explicit environment/source identities, operational navigation, and source-setup guidance.
- Redesigned Pipelines, Services, Investigations, Capacity, and Source health views, including populated and empty states.
- Summary cards count already-loaded retained records **before search**; they are neither full-history metrics nor inferred runtime health.
- Bounded, server-side search over already-authorized records. Queries are limited to 100 characters, persist on refresh, and reset on navigation/company changes.
- Existing local owner, snooze, acknowledgment, closure, and evidence workflows retained. Evidence can be explicitly closed and is still cleared on refresh.
- Visible selected-company identity via `OpsBrain.Tenancy.company/1`, using the existing authorization transaction. Operational refreshes still query only their route's datasets.
- Skip link, labeled forms, current-page navigation, table headers, keyboard focus, reduced-motion styling, connection interruption notice, and mobile-accessible sign-out.

## Acceptance ledger

| Check | Evidence / result |
| --- | --- |
| Existing workflow and authorization regressions | Final `mise exec -- mix precommit`: **216 passed**, 0 failed |
| New UI behavior | Complete `test/ops_brain_web/console_ui_test.exs`, including company search, revoked-session search, route navigation, source details, missing-data labels, retained-set summaries, and cross-company context |
| Existing issue controls and evidence | Complete `test/ops_brain_web/operations_live_test.exs`, extended with evidence close/reopen |
| Format / compile | `mix format --check-formatted` and `mix compile --warnings-as-errors` passed |
| Routes | `mix phx.routes` confirmed existing authentication and all company routes; no new public routes |
| Stylesheet delivery | `mix phx.digest`; gzip and digested CSS compare byte-for-byte with `priv/static/assets/css/app.css` |
| Browser, empty states | Authenticated company picker, overview, and pipelines; LiveView connected at 1440px and 390px |
| Browser, populated states | All five operational routes at 1440px and 390px; page width equals viewport, including a 320px check |
| Browser interactions | Real form search filtered four runs to one while retaining the four-run summary; owner assignment and evidence open/close passed |
| Diff hygiene | `git diff --check` passed; no dependency, schema, collector, or production configuration changes |

Full tests used only the newly created, explicitly disposable local database `ops_brain_test_ui_20260920`, with separate migrator/runtime identities on PostgreSQL 18. Test fixtures were not seeded into `ops_brain_dev`. The temporary populated preview on port 4003 was stopped after browser checks. The development application remains on port 4000.

## Local verification artifacts

These are temporary local artifacts, not checked-in production data:

- `/tmp/ops-brain-ui-precommit-final.log`
- `/tmp/ops-brain-ui-browser-checks.json`
- `/tmp/ops-brain-sign-in-desktop.png`
- `/tmp/ops-brain-overview-desktop.png`
- `/tmp/ops-brain-overview-mobile.png`
- `/tmp/ops-brain-populated-pipelines-desktop.png`
- `/tmp/ops-brain-populated-investigations-mobile.png`
- `/tmp/ops-brain-populated-evidence-desktop.png`

## Navy theme follow-up

Replaced green branding with navy/slate surfaces (`#141a29` sidebar) and blue actions (`#315ed7`, hover `#2448ad`). Renamed `--green*` to `--brand*`, updated browser theme metadata, and regenerated fingerprinted/gzipped CSS. All selectors, layout rules, and interactions are unchanged. Success, warning, danger, and information badge rules are preserved exactly.

Verification for this color-only change: all **23 tests** in the complete console UI, authorization, operations LiveView, and entry-controller modules passed. Format, warnings-as-errors compilation, and diff checks passed. Source, served, fingerprinted, and gzipped CSS match. Primary text contrast is **5.66:1** (hover **8.06:1**). Desktop (1440px) and mobile (390px) overview/sign-in checks passed with no horizontal overflow or browser exceptions; the overview remained LiveView-connected. The full suite results above belong to the original redesign, not a new full-suite run for this palette change.

- `/tmp/ops-brain-navy-theme-checks.json`
- `/tmp/ops-brain-navy-browser-checks.json`
- `/tmp/ops-brain-navy-overview-desktop.png`
- `/tmp/ops-brain-navy-overview-mobile.png`
- `/tmp/ops-brain-navy-sign-in-desktop.png`
- `/tmp/ops-brain-navy-sign-in-mobile.png`

## Constellation branding

The product is now named **Constellation** throughout the sidebar, browser title, sign-in (including error responses), SSO completion, accessible home-link labels, footers, runtime configuration error text, and product documentation. The longer wordmark fits the existing desktop/tablet sidebar; on mobile the company switcher occupies its own row so it cannot overlap the brand. The navy/blue palette and all operational behavior are unchanged.

Compatibility identifiers remain unchanged: `OpsBrain` / `OpsBrainWeb`, `:ops_brain`, `OPS_BRAIN_*`, the `ops_brain/` directory, database names/roles/GUCs, cookies, and deployment commands. This is a product-brand rename, not an infrastructure migration.

Rename acceptance ledger:

| Check | Result |
| --- | --- |
| Full `mise exec -- mix precommit` | **218 passed**, 0 failed, using the approved disposable `ops_brain_test_ui_20260920` database |
| New brand regressions | Login/error/SSO branding plus portfolio, company, source-detail, and all five operations routes |
| Compile / format | Warnings-as-errors compilation and formatting passed |
| Actual browser rendering | Login and authenticated overview at 1440, 768, 390, and 320px; no horizontal overflow, wordmark clipping, switcher overlap, or JS exceptions; overview LiveView remained connected |
| Active product-name scan | No old spaced name, split wordmark, or legacy `brand-light` class in active source/prose |

Artifacts: `/tmp/constellation-rename-tests.log`, `/tmp/constellation-brand-browser-checks.json`, `/tmp/constellation-overview-1440.png`, `/tmp/constellation-overview-390.png`, `/tmp/constellation-sign-in-1440.png`, `/tmp/constellation-sign-in-390.png`.

## Boundaries and remaining work

No live provider, production deployment, or live OIDC-provider validation was performed. Collection, delivery, and source permissions are unchanged. No synthetic charts, invented healthy states, or runtime AI were introduced. Source onboarding still requires the existing administrator-approved configuration workflow. The repository's pre-existing operational-readiness limitations remain; the redesign does not claim production readiness.

Fovea/Contour extension calls were unavailable in the execution kernel; source-path tracing, manual diff review, full tests, and real-browser checks supplied the review evidence instead. No commit or PR was created.
