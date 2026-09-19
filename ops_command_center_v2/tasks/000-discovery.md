# Task 000 — reconcile the repository and choose the first read-only source

## Goal
Establish a verified implementation starting point without building the whole platform.

## Required work
Inspect the repository, existing instructions, dependency locks, schemas, tests, CI and deployment configuration. Identify which v1 assumptions conflict with v2: single-company schema, mandatory deployment reporters, future remediation/LLM code, broad source credentials, or optional monitoring gaps disguised as healthy.

Write a small CURRENT_STATE.md with confirmed facts, proposed decisions and unresolved external setup. Write one decision record for the read-only/no-AI contract and first Azure DevOps Build API adapter. Define one approved/sanitized fixture set and source scope. Record whether the real source is Azure DevOps Services, Server, YAML/build, or classic release; never invent it.

Specify one next code task and acceptance tests. Do not scaffold every future context or request production administrator tokens. Missing access does not block reading/testing existing code, but live contract validation remains pending.

## Out of scope
New infrastructure, real source mutation, pipeline edits, all-company onboarding, every detector, runtime AI, production deployment.

## Acceptance
A reviewer can identify the first company/source scope, auth/network unknowns, read-only invariant, repository baseline, and exact next change. Actual commands/results are recorded. No unperformed test is described as passing.

Stop after this task.
