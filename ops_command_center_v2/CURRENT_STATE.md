# Current state — task 000 discovery

## Implementation update after discovery
Local implementation now spans roadmap tasks 000–016 in `../ops_brain/`; 142 application tests and18 standalone deployment-contract tests pass; see [credential-free completion and handoff](PREPARATION_STATUS.md). This does **not** mean all real-world acceptance gates are complete. See [the current full task ledger](IMPLEMENTATION_STATUS.md) for delivered behavior, measurements, limitations and blocked live integrations/second-company onboarding. [Task 001 status](TASK_001_STATUS.md) and the discovery record below are historical evidence, not the current application inventory. No live source is approved.

Status: task 000 documentation prepared for independent review; no application implemented, no live source validated. Review and real-pilot approval remain open gates, so task 000 is not represented as fully accepted.

Deliverables: [ADR 000](decisions/000-read-only-build-pilot.md) records the invariant, proposed first adapter, execution path, public-document evidence and approval gate. [Fixture contract](FIXTURE_CONTRACT.md) defines one versioned synthetic set with two colliding companies and task-specific expected results. No real scope or fixture capture is approved.

## Confirmed repository facts
- Repository root: `/home/adam/projects/aiops`; specification pack: `ops_command_center_v2/`.
- Initial `git status --short` returned no changes. `git ls-files` lists `.gitignore` and the specification documents/tasks only.
- No application source, dependency lock, schema, test suite, CI workflow or deployment configuration is tracked. No older v1 implementation was found in the tracked inventory.
- `elixir`, `mix`, `erl`, `psql`, `pg_isready` and `docker` are unavailable on the current PATH. This establishes command availability only, not that software cannot exist elsewhere.
- The pack explicitly requires task 000 and independent review before task 001. No future schema or connector is authorized by discovery alone.

## Binding decisions
- Phoenix, LiveView, Ecto/PostgreSQL and Oban are the prescribed architecture; exact compatible versions must be selected and locked in task 001.
- Observation is strictly read-only; runtime AI and remediation are permanently excluded. Application-local state changes are allowed. External delivery remains disabled pending separate approval.
- Company identity is distinct from provider namespaces. CI outcomes must not imply production runtime health. Missing telemetry remains unknown.
- First proposed adapter: selected Azure DevOps Build/YAML reads. Classic releases are unsupported. Actual Services versus Server installation and API compatibility are unknown.

## External setup and approvals still missing
No real company, organization, project, definition, endpoint, identity, credential reference, environment mapping, network allowlist or query budget has been supplied or approved. No credential search or authenticated source request has been performed. Do not put credentials in this report.

A source owner must identify the pilot, installation/API version, permitted project/definition IDs, authentication method, narrowly scoped build-read permission, approved egress/identity endpoints, retention and query budgets. Live contract validation is pending, not passed.

## Acceptance ledger
- [x] Inventory repository and existing implementation artifacts.
- [x] Identify read-only/no-AI and incremental review constraints.
- [x] Record unavailable local tools and missing live-source scope honestly.
- [x] Add decision record for the first adapter and security boundary.
- [x] Define labeled synthetic fixture contract; distinguish proposal from owner approval.
- [x] Check the public Build list, rate-limit and identity documentation; this is not live integration validation.
- [x] Verify all discovery links, original manifest integrity and change scope.
- [ ] Independently review discovery deliverables.
- [ ] Validate a bounded read against an explicitly approved real source (blocked on setup).

## Actual commands and results
- `pwd`: `/home/adam/projects/aiops`.
- `git rev-parse --show-toplevel`: `/home/adam/projects/aiops`.
- `git status --short`: empty before edits.
- `git ls-files`: specification pack and `.gitignore`; no executable application/test artifacts.
- `command -v` checks for the six tools above: unavailable on PATH.
- Directory listings and document reads confirmed the task order and acceptance requirements. Ancestor instruction-file checks found no additional `AGENTS.md` from repository root up to `/`.
- Public documentation requests used `curl --fail --silent --show-error --proto '=https' --connect-timeout 10 --max-time 30 '<public Microsoft URL>'` with bounded output filters. URLs and observed assertions are in ADR 000. Build list, rate-limit and identity documentation checks returned successfully; finish-time-bound filtering, continuation parameter, HTTP-200 Retry-After behavior and explicit identity membership/permissions were confirmed. Subsequent filtered checks used `set -o pipefail` to preserve request failures. No authenticated source was contacted.
- No application, PostgreSQL, HTTP-boundary source-contract or live tests executed: no implementation/toolchain or approved live source is available. Public documentation checks are not live source validation.
- `python3 -c '<inline documentation verification>'`: passed all checks. All 14 original manifest entries retained exact byte counts/SHA-256 hashes; exactly the three discovery Markdown documents were added; all 12 local links resolved within the pack; new-document trailing whitespace, terminal newlines and code fences passed; required discovery sections and two synthetic company IDs were present. This static check is not an application behavior or security test.
- That verification also ran `git diff --exit-code`, `git diff --cached --exit-code` and `git diff --check`: all passed; original tracked files were unchanged. `MANIFEST.json` remains the original specification-pack manifest, not a manifest of new deliverables. No commit, PR, deployment or infrastructure change was created.

## Single next code task
After discovery review: task 001, the smallest Phoenix/PostgreSQL company/membership/source foundation with authenticated operator entry, explicit dev/staging/prod identity and scoped query APIs. Select and lock dependencies; do not introduce all future contexts.

Required checks: two synthetic companies with colliding display names; unauthorized direct fetch and guessed source ID denied; absent scope denied; company relationships constrained; transaction-local scope resets on reused database connections; authenticated entry and LiveView lifecycle checks; no production auth bypass. Database behavior requires real PostgreSQL, not mocks. Live onboarding, metrics, logs, correlations and external notifications remain out of scope.

## Safety and recovery
Discovery changes documentation only, stores no source data or secrets, and starts no processes. Disable/recovery is removal or revision of the newly added discovery documents; existing monitoring and paging remain untouched. The whole product is not complete or production-ready.
