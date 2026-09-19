# Task 003 — failed-step evidence without AI

## Prerequisite
Reviewed durable run collection.

## Behavior
For a selected failed/partially successful run, retrieve its timeline. Preserve stage/job/task hierarchy and attempt IDs. Select failed operations, retain structured issues/result codes, and fetch bounded relevant log sections only when needed. Redact before persistence; save source run/step/log/line provenance.

Output structured observed failure evidence or unclassified/unavailable with reason. Begin with a tiny reviewed parser fixture set. Do not implement broad fuzzy clustering in this task.

## Tests
Failed parent+child yields one failed-run identity; two task attempts remain distinct; generic exit code remains unknown; logs unavailable/delayed/truncated; secret-bearing line is not persisted; oversized/multiline data bounded; no cross-company reads.

## Out of scope
Full-log mirroring, model summarization, root-cause claims, arbitrary execution, reruns, external notifications.

## Deliverable
Bounded timeline/log adapter operations, normalized evidence, parser tests, source traceability, actual verification report. Later grouping receives this stable contract.

Stop after this task.
