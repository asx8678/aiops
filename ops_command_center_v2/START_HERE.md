# Starting prompt for implementation agents

Use this after placing the pack in the repository or providing its files as context. Do not overwrite existing repository instructions without reconciling conflicts.

```text
Read the Constellation AGENTS.md, IMPLEMENTATION_BRIEF.md,
SOURCE_ACCESS.md, ROADMAP.md and tasks/000-discovery.md.

We are building a supplementary operations command center across
explicitly authorized companies and development/staging/production.
Runtime source access is strictly read-only. Runtime functionality
must use deterministic code/statistics and no AI models, AI agents,
embeddings or AI credits. Existing monitoring and paging stay independent.

Complete ONLY task 000. Inspect the actual repository first.
Reconcile older directions about deployment reporters, runtime LLMs,
automated remediation and single-company identity against v2.

Do not implement the full roadmap or change live source systems.
Do not invent credentials, metric names, source payloads, service
mappings or successful tests. Missing live access means live validation
is pending, not that mocks constitute a live integration.

Report confirmed facts, proposed decisions, unresolved setup,
actual commands/results and the single next implementation task.
Then stop for independent review.
```

## Subsequent task prompt
```text
Read AGENTS.md and the reviewed task <number>. Implement only that
behavior, including failure, scope and security tests. Preserve the
existing repository and prior approved interfaces. Report actual test
results and unresolved live validation. Do not start another task.
```

## Independent review prompt
```text
Review task <number> against its specification and the actual diff.
Do not trust the implementation agent's completion claim. Run relevant
checks and inspect source permissions, no-AI behavior, company and
environment boundaries, duplicates, late events, missing evidence,
query limits, redaction, count semantics and recovery. Report concrete
findings and unverified assertions. Do not expand the feature scope.
```
