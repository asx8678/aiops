# Constellation offline demo

## Open it

With the local server running, open:

http://localhost:4000/companies/c057e110-0000-4000-8000-000000000001/demo

Or open **http://localhost:4000/**. The local home is pinned to the seeded demo, with direct **Explore resources** and **Follow the evidence** links. There is no company chooser. See [Single-workspace home](SINGLE_WORKSPACE.md).
The existing development auto-login remains unchanged. Other operators need explicit membership.

**This is an offline snapshot, not a real cluster, database server, or an HTTP API emulator.** Source connection states, request counts, errors, and operational evidence are simulated and labeled. No Kubernetes credentials, kubeconfig, cloud account, external network, provider APIs, live collection, or notification delivery is required or enabled. Only the application's own local PostgreSQL database is used.

## Dataset

| Synthetic resource / record | Count |
| --- | ---: |
| Clusters (`nw-eu-prod`, `nw-eu-staging`) | 2 |
| Nodes | 18 |
| Namespaces (12 per cluster) | 24 |
| Deployments / ReplicaSets / Services / Event samples | 48 each |
| Pods (including 18 database replicas) | 210 |
| Database identities (PostgreSQL + Redis) | 6 |
| StatefulSets / primary PVC samples | 6 each |
| Total browsable resource snapshots | 464 |
| Source identities (Kubernetes, Prometheus, Loki, Build/YAML) | 7 |
| Mapped application targets | 48 |
| Metric / capacity observation windows | 96 |
| Pipeline runs (success, failure, cancellation, partial success) | 72 |
| Findings with linked evidence and local notification records | 5 |

Resources include realistic cluster/namespace ownership, replica relationships, node assignments, private pod addresses, resource requests/limits, images, volumes, database connection counts, and failure conditions. Hostnames end in `.invalid` and are not contacted. Database connection counts and capacity estimates are fixture values, not measurements. The inventory is a curated snapshot (for example, only primary database PVCs are sampled), not a full Kubernetes API export.

## Guided tour

1. **Demo explorer:** filter by cluster, namespace, kind, or text; page through 40 rows at a time; expand **Inspect JSON**. Try `Database`, `checkout-api`, `OOMKilled`, and `ImagePullBackOff`.
2. **Investigations → Checkout latency → Evidence:** five observations connect a pool-size rollout, readiness failures, latency metrics, SQLSTATE 53300 logs, and PostgreSQL connections at 492/500. The timeline links actual retained evidence IDs. Staging provides counterevidence. The existing deterministic correlation function creates a candidate, **not proof of cause**; no AI runs.
3. Other findings demonstrate inventory OOM kills, conditional storage-capacity warnings, staging image-pull denial, and unavailable log coverage. Missing telemetry remains unknown. The storage and missing-telemetry scenarios do not invent a deployment cause.
4. Use existing assignment, local acknowledgment, snooze, and evidence controls. No upstream action or notification is sent. Plain reruns preserve those decisions.
5. **Pipelines / Services / Capacity / Source health:** see populated retained projections and inspect diagnostic JSON. Some pipelines deliberately lack explicit mappings. One log source has a simulated timeout and stale evidence.

All company pages show a **SYNTHETIC DEMO · OFFLINE** banner. The company/source names and all JSON payloads also carry demo provenance. The snapshot date is visible. Source freshness ages naturally; refresh reloads stored data and does not fabricate new observations. Evidence expires after 30 days. Reseed explicitly to refresh it. Existing operations views still cap each dataset at 100; this dataset stays below those limits. The explorer reads at most 1,000 resource snapshots (currently 464).

## Provision / reset / remove

Run from `ops_brain/` with the **local non-superuser migrator** connection, not the runtime connection. The existing operator must already be enabled; the task creates neither operators nor tokens.

```sh
DATABASE_URL="$MIGRATION_DATABASE_URL" mise exec -- mix ops_brain.demo --operator adam --confirm
```

On this local setup the migrator URL is `ecto://ops_brain_migrator@localhost:5432/ops_brain_dev` (local authentication; no password is embedded). The task supports only `MIX_ENV=dev` and a loopback `ops_brain_dev` database. Production builds reject the provisioner. Automated tests use the separately approved disposable `ops_brain_test_ui_20260920` database and its distinct migrator/runtime identities; never approve or test against valuable data.

Rerunning is idempotent and preserves the snapshot and local workflow decisions. To regenerate only the demo observations with a new time anchor (clears demo review changes):

```sh
DATABASE_URL="$MIGRATION_DATABASE_URL" mise exec -- mix ops_brain.demo --operator adam --confirm --reset
```

To remove only the demo workspace and its memberships/data:

```sh
DATABASE_URL="$MIGRATION_DATABASE_URL" mise exec -- mix ops_brain.demo --remove --confirm
```

The reserved UUID, slug `constellation-demo-northwind-v1`, and exact company name must match before reset/removal. A collision is refused. Seed/reset is one transaction under an advisory lock. No global truncate, RLS bypass, schema migration, source configuration, or existing workspace is altered. The normal runtime cannot administer companies/memberships.

## Acceptance ledger

- `test/ops_brain_web/demo_live_test.exs`: deterministic counts/provenance; no jobs or source enabling; RLS/authorization; pagination/filtering; readable linked evidence; populated existing views; expired snapshot behavior; idempotence; scoped reset/removal; identity collisions; command approval gates.
- Full suite after implementation: **227 passed**, logged in `/tmp/constellation-demo-tests.log`. Final `mix precommit` also passed **227 tests** (`/tmp/constellation-demo-precommit.log`); the final affected UI/auth modules passed **30 tests** (`/tmp/constellation-demo-ui-final.log`).
- Format check and production warnings-as-errors compilation passed. Direct production-BEAM probe rejects demo provisioning before any database access.
- Real browser checks: all seven company routes at **1440, 390, and 320px**, resource pagination/filtering, evidence open/close, and the five-step checkout timeline. No browser exceptions. A screenshot review caught a narrow-screen action row; it was fixed before final handoff.
- Existing `Local Dev` workspace and its original identity preserved; collectors/delivery remain disabled. No real provider integration or live detector/forecast accuracy was validated.

Artifacts: `/tmp/constellation-demo-browser-checks.json`, `/tmp/constellation-demo-1440.png`, `/tmp/constellation-demo-320.png`, `/tmp/constellation-demo-databases.png`, `/tmp/constellation-demo-evidence.png`.
