# Task <number> — <one observable behavior>

## Goal
One concrete behavior the operator or another domain module can verify.

## Prerequisites
Reviewed interfaces, verified versions, source capabilities and access. Separate confirmed from pending facts.

## Scope
Small modules/interfaces/migrations genuinely needed for this behavior.

## Explicit non-goals
Name adjacent features the agent must not build. Restate no source mutation and no runtime AI.

## Inputs and outputs
Source/sanitized fixture contract, company/environment identity, time semantics, durable outputs, versions and limitations.

## Failure behavior
Duplicates, late/missing/truncated inputs, source outage, DB restart, authorization failure, bounded retries and read load.

## Acceptance tests
Happy case and adversarial cases; real PostgreSQL tests where relevant; actual command list.

## Security and operations
Allowed read operations, secret/data minimization, query budgets, cross-company checks, retention and disable/recovery method.

## Completion report
What changed; commands actually run; proven scenarios; tests/live access still pending; limitations; one next task. Stop without implementing it.
