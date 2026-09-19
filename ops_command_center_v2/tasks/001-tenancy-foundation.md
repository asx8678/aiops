# Task 001 — company-scoped application foundation

## Prerequisite
Reviewed task 000. Preserve existing repository structure; create Phoenix/PostgreSQL baseline only if absent.

## Behavior
Introduce the smallest useful company/membership and source identity foundation, authenticated operator entry, and explicit company-scoped query API. Add dev/staging/prod identity representation without generating all detector schemas.

Use two synthetic companies with the same service/source display names. Bind source identities to configured companies rather than client-supplied company fields. Define tested transaction-local scoping for the planned RLS boundary; no insecure production auth bypass if SSO setup is pending.

## Tests
Cross-company direct fetch denied; missing scope rejected; guessed source identity cannot escape; database pooled scope resets; existing repository tests continue to run.

## Out of scope
Live source onboarding, correlation, logs/metrics, a comprehensive permissions framework, broad generated dashboards, all future tables.

## Deliverable
Small migration/API change, tests, local-only seed fixtures, actual verification report, recovery instructions. RLS hardening must be completed before a second real company is connected even if it requires a separately reviewed follow-up task.

Stop after this task.
