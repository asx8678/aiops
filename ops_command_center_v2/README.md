# Ops Brain v2 — Read-Only Operations Command Center

Status: proposed engineering specification. No application, live integration, security audit, load test, or benchmark is supplied by this pack.
Validated against primary integration documentation on September 19, 2026. Installed company versions, entitlements, source coverage, and network access still require validation.

## Product in one sentence
A supplementary Elixir/Phoenix application that continuously checks authorized companies' development, staging, and production systems, groups operational failures, correlates evidence, and produces actionable notices using deterministic code and statistics—without runtime AI or source-system changes.

## Binding requirements
- All runtime observation access to monitored systems is read-only.
- No LLM, model inference, embeddings, local model, AI agent, paid AI API, or AI credit is required or called at runtime.
- AI agents may implement and review the code. They are not production components.
- Existing Grafana, Prometheus, log storage, deployment, and paging paths remain independent.
- Multiple companies and environments are first-class security and identity boundaries, not dashboard-only filters.
- Internal storage, configuration, review, and acknowledgment are permitted. External notifications are a separately authorized delivery capability, not permission to change monitored systems.
- Polling is a first-class implementation strategy. Webhooks are optional accelerators, not a deployment prerequisite.

## What changes from the previous pack
This specification supersedes conflicting directions in the earlier Ops Brain pack. Do not run both briefs as competing instructions.

1. The product is broader than change-to-incident correlation: pipeline failures, log bursts, workload problems, capacity risks, and monitoring gaps deliver independent value.
2. Multi-company scope is included from the first schema and authorization work. Still connect sources incrementally.
3. Start Azure DevOps integration by reading existing run results, timelines, and bounded logs. No pipeline edits or deployment-reporting step is required.
4. Remove all later autonomous action, remediation, and LLM phases. Read-only/no-AI is a product invariant, not an MVP limitation.
5. Do not write Grafana annotations, alert rules, silences, Azure work items, pipeline comments, or workload configuration.
6. Prefer existing telemetry backends; do not introduce a duplicate raw telemetry warehouse.
7. Change correlation remains useful, but a failed build is not evidence of production degradation or deployment.

## Reading order
Read AGENTS.md, IMPLEMENTATION_BRIEF.md, SOURCE_ACCESS.md, ROADMAP.md, and the assigned task. DETECTOR_CATALOG.md and ACCEPTANCE_TESTS.md define later behavior; they are not permission to build every feature now.

Start with START_HERE.md. Implement one task, report actual results, get an independent review, and stop.

## Scope of validation
The reference APIs support the necessary reads and statistical primitives. That validates the design's feasibility, not its eventual accuracy or your specific installations. No source credentials were used in preparing this pack. Every live integration and every detector must have explicit coverage and acceptance evidence before being described as operational.
