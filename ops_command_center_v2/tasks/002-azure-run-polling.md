# Task 002 — durable read-only Azure DevOps run collection

## Prerequisites
Company/source identity foundation and approved endpoint/credential reference. Required library/provider APIs verified against chosen versions.

## Behavior
Read run metadata for one configured project/pipeline scope through the Build list/read APIs. Collect completed results with explicit completion-time ordering, overlapping bounds, fixed upper window and pagination. Retain active-run followup work and document broader reconciliation for changed attempts.

Persist observations/snapshots and jobs transactionally per bounded page. Mark coverage complete only when the selected window is accounted for. Use company/source/project/run identity for unique projections. Expose distinct run counts by result and honest incomplete-history status in a minimal view/API.

## Tests
Multiple pages; duplicate overlap; failure mid-collection; crash/restart; long-running run finishing now; failed versus canceled versus partial; unknown environment; throttling and Retry-After including successful response; company isolation.

## Out of scope
Task logs, parsing causes, rerunning/canceling, source hooks, modifying YAML, prediction, polished dashboards.

## Deliverable
One adapter/read operation family, durable collection flow, sanitized fixtures, tested counts, source coverage state, actual test report. No claim to cover classic release APIs.

Stop after this task.
