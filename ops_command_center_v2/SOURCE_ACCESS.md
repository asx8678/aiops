# Source access and onboarding

This is an access specification, not authorization to provision resources. Human source owners perform setup. The runtime app does not grant access or alter source configuration.

## Read-only boundaries
| Source | Approved observation operations | Explicit exclusions |
|---|---|---|
| Azure DevOps build/YAML | List/read selected runs, timeline records, bounded task logs; optional explicitly approved test/artifact metadata reads | Queue, rerun, cancel, delete, update definitions, alter variables, change permissions, write repos/work items/comments |
| Kubernetes | Scoped get/list/watch of approved workload/status/event resources | Create/update/patch/delete, pods/exec, attach, port-forward, Secrets, arbitrary proxies, node shell |
| Prometheus/compatible | Approved instant/range queries and narrowly approved status/target reads | Administrative APIs, deletion, reload, remote write, rule/config changes |
| Log backend | Scoped read-only aggregate/search queries and bounded samples | Ingestion, index deletion, retention/rule changes, tenant administration |
| Grafana | Optional read metadata/dashboard links; receive existing authorized alerts | Dashboard/annotation/rule writes, source credential access, silences/contact-policy administration |
| Database/cloud metrics | Existing approved exporter metrics or resource-scoped metric/status reads | Application data access, SQL mutation, resizing, failover, maintenance execution |
| Ops Brain PostgreSQL | Internal observations, findings, checkpoint and local workflow writes | Sharing records with unauthorized companies |
| Optional notification destination | Send/update only the application's approved messages to an approved destination | Broad channel history/account access, task execution, source remediation |

An API query using POST can be read-only. Never rely solely on HTTP verbs. Every adapter operation needs an allowlisted endpoint/semantic purpose; there is no generic 'request any URL' tool.

## Azure DevOps identity
Prefer a company-approved nonhuman Entra identity with explicit Azure DevOps membership and narrowly assigned project/build read permissions. Azure DevOps uses its own permission model. Entra or Azure resource roles alone do not establish build access. Across companies/tenants, configure identities separately and validate supported auth paths. [S5]

The Build read capability is documented as vso.build in the API scope reference; this is not a reason to implement deprecated authentication examples copied from generic REST pages. Use the current authentication guidance for the selected identity type. [S1–S5]

A tightly scoped short-lived PAT can be a temporary pilot exception if company policy permits it, with rotation/expiry and secret storage; never use a personal administrator's token as the long-term service identity. Do not request queue/manage/execute privileges.

## Kubernetes
Use a dedicated service account and namespace Role/RoleBinding for the selected workloads. Begin with Deployments/ReplicaSets/Pods/Events. Add StatefulSets/Jobs/CronJobs, Services/EndpointSlices, or Ingress metadata only for detectors actually implemented.

Node reads are cluster-scoped and separately reviewed; do not silently broaden namespace permissions. Avoid wildcard resources/verbs. Exclude Secrets and execution/proxy subresources. RBAC supports these scoped rules. [S11]

Even permitted object reads can include sensitive annotations, environment values, and command arguments. Keep only allowlisted status/identity/owner fields. Do not persist whole specs. Use log-backend access rather than pods/log by default.

## Grafana and its actual backend
Inventory the actual backend URL/type, tenant/workspace boundary, query credentials, metric/label names and retention. A Grafana data source might use credentials the application cannot reuse. Do not extract hidden data-source credentials or assume dashboard access grants all source data. [S6]

For Loki, the source-bound tenant selection is enforced by trusted authentication/proxy configuration; a client-provided X-Scope-OrgID is not adequate isolation by itself. The app binds a fixed authorized tenant identity to each source and does not accept overrides from webhooks or users. [S18]

## Onboarding wizard
1. Add internal company and approved operator membership.
2. Define dev/staging/prod targets; list unknown or absent environments explicitly.
3. Add one source endpoint with a secret reference and allowed scope.
4. Test a small approved read; show capability and permission results, not just HTTP success.
5. Discover a bounded inventory and let an authorized operator approve monitoring scope inside Ops Brain.
6. Map services, workloads, pipeline stages, metrics, and log selectors. Unresolved items remain visible.
7. Preview proposed collection frequency, query limits, sample retention and unsupported checks.
8. Start bounded read-only collection, initially dashboard-only.
9. Check actual freshness, pagination coverage and detector eligibility.
10. Enable independently approved notification routing only after grouping validation.

## Provider-side changes
Granting credentials, exposing private query endpoints, adding exporters, or configuring an optional existing alert webhook may require source-owner changes. These are outside the runtime app and require separate approval. Poll-first operation is available without changing pipeline YAML, alert policies, or monitored application code.

## Negative validation
Use policy inspection and controlled test identities/resources to prove writes are absent/denied. Do not attempt a restart, pipeline trigger, or source write against production as a 'test'. Review inherited permissions and source-side audit records as well as application-level allowlists.
