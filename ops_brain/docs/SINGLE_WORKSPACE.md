# Single-workspace home and monochrome identity

## Open the app

**http://localhost:4000/** resolves the configured workspace and goes straight to its **Command center** (`/companies/:company_id/command`). Only the workspace-error state renders on `/` — that frame keeps the “A clearer view of operations.” headline and the orbital illustration. There is no company grid, company search, or company switcher. The sidebar name is a static identity label; the Home link returns to the landing, i.e. the Command center.

The local development configuration selects the existing **Demo · Northwind Retail** workspace (`c057e110-0000-4000-8000-000000000001`). The former home-page stats and the **Explore resources** / **Follow the evidence** cards were removed with the landing change; their destinations (demo explorer, Investigations) and all operational views remain in the sidebar navigation, and the Command center links straight into Troubleshoot and focused findings. Nothing is seeded, reset, enabled or connected by visiting the landing. The synthetic banner remains visible on the demo's pages.

The original `Local Dev` company and all stored data are untouched. Legacy `/companies/:company_id/...` URLs remain valid and authorize exactly as before; company IDs remain internal scoping, not a navigation step.

## Deployment configuration

Set `OPS_BRAIN_WORKSPACE_COMPANY_ID` to the UUID of your approved company and restart. Configuration selects a home, not a permission: the current operator still requires enabled status, an unexpired session, and membership. When unset outside local dev, a sole authorized membership resolves automatically. Multiple/no memberships show a setup state; the app never guesses the first company or lists choices. Invalid or blank configured values fail closed without fallback. The local dev default is intentionally the demo; override it to use another existing company.

Changing this setting does not delete other companies or restrict their previously authorized legacy URLs. Tenant authorization and RLS remain enforced. Normal production authentication is unchanged. The temporary no-login mode is still strictly local development; see [LOCAL_DEVELOPMENT.md](LOCAL_DEVELOPMENT.md).

## Three environments

The former Home environment cards were removed with the landing change. The **Command center** now carries a `?environment=prod|staging|dev` filter (default all) applied in SQL before its bounded reads, with the accepted Kubernetes object-attribution exception. Services and Capacity keep their explicit-mapping filter, which persists through in-view refresh and text search; their summaries describe the bounded loaded set within that environment, before text search. Unmapped observation windows appear only under **All environments**; an environment name does not infer ownership or health.

The current offline dataset has 24 staging and 24 production service targets. Development is a configured identity with no mapped targets, so it is displayed honestly as empty/unknown. This change does not fabricate a third cluster or alter the seeded data. Pipelines, Investigations and Source health retain their existing workspace-wide scopes.

## Capacity evaluations

Capacity now shows stored `capacity_evaluation` evidence separately from supporting metric windows. Its summary cards count those evaluations, not raw gauge conditions. Forecast cards show the stored condition, conditional time to threshold, explanation and evaluation/receipt/expiry times; they never recompute a forecast or claim current health.

Only unexpired, non-tombstoned records appear. Environment filtering happens before the 100-evaluation limit. New evidence records explicit service identity; legacy evidence can use retained target/input-window identity within the same company. Unresolved mappings appear only under **All environments**. Legacy output-only evidence stays **Unknown**, not an invented estimate. Supporting service/window lists retain their existing bounded-set filtering.

Review plan, regressions and historical-data limits: [REVIEW_FIXES.md](REVIEW_FIXES.md).

## Universal logo

A local connected-node Constellation mark replaces the generic stacked-layer icon in the upper-left wordmark, sign-in, SSO completion, and home illustration. The inherited workspace contained only the stock Phoenix `logo.svg`, not a separate supplied logo attachment. This is a new local vector mark, not a claim to reproduce an unavailable original image.

- `priv/static/images/constellation.svg`: transparent, one-color `currentColor` vector, shared by `OpsBrainWeb.UI.brand_logo/1`.
- `priv/static/images/constellation-black.svg`: black artwork for white/light backgrounds.
- `priv/static/images/constellation-white.svg`: white artwork for black/dark backgrounds.

The inline logo inherits its parent’s text color, so its silhouette is identical in either treatment. It has no color-dependent details, gradients, remote fonts, or external requests. Home’s orbital motion/glow is decorative, never a connection-status indicator. `prefers-reduced-motion: reduce` disables both animations.

## Acceptance ledger

- Targeted affected UI/auth modules: **38 passed**, `/tmp/constellation-single-workspace-tests.log`.
- Browser: connected direct entry, no selector, three environment cards, and no horizontal page overflow at 1440, 900, 768, 390, and 320px. Production navigation shows 24 mapped targets / 48 windows; Development filtering is empty; Home → resources shows 464 snapshots. No browser exceptions in these checks.
- Both full-motion and reduced-motion modes verified in Chromium.
- `mix precommit`: **233 tests passed**, `/tmp/constellation-single-workspace-precommit.log`.
- Production `mix compile --warnings-as-errors` passed; release runtime configuration contract: **7 passed**, `/tmp/constellation-single-workspace-prod.log`.
- Black/white rendering checked from the same inline SVG: inherited pure black on white and pure white on black. Preview: `/tmp/constellation-logo-monochrome.png`.
- Final affected home/branding modules: **16 passed**, `/tmp/constellation-single-workspace-final-ui.log`.
- All eight workspace routes checked at desktop and 320px (**16 route/viewport checks**). A 3–5px breadcrumb overflow on Configuration/Investigations was fixed and both failed cases rechecked successfully. No browser exceptions. Final evidence: `/tmp/constellation-single-workspace-browser-final.json`.
- `mix phx.digest` completed. Served CSS plus all four logo SVGs match raw, fingerprinted and decompressed gzip versions byte-for-byte. Root returns HTTP 200 with the demo selected and no chooser. The favicon uses the same mark with browser light/dark adaptation.

Artifacts: `/tmp/constellation-single-workspace-1440.png`, `/tmp/constellation-single-workspace-320.png`, `/tmp/constellation-single-workspace-browser.json`.

No production deployment, real provider validation, notification delivery, dependency changes, database migration or data reset was performed. No commit or PR created.
