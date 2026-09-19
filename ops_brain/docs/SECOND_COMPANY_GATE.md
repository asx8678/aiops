# Task 016 — second real company readiness gate

Status: **blocked, not completed**. No second real company, identity, network scope or approval was supplied. Two synthetic companies are tests, not onboarding.

Before a second real company:
- Review application ownership/trust boundary; unrelated customers may require separate databases/deployments.
- Verify approved company memberships and every operator route/action/reconnect/refresh; revoked memberships must fail closed.
- Run all real-PostgreSQL RLS and composite relationship tests as non-owner/non-BYPASSRLS runtime. Scope must reset after commit/rollback/exception. Restore grants must preserve this role separation.
- Review independently bound source/project/tenant/namespace credentials, static IP/host egress and query/retention budgets; no inherited source mutation permission.
- Verify run/evidence/group/window/job identities cannot cross companies; colliding names/templates never confer authority. Global queue arguments/errors are not operator UI.
- Review notification company authorization at send time, fixed recipients, separate secret references and ambiguous outcomes. Delivery stays off without approval.
- Any future exports, tenant caches, PubSub topics or new worker types need equivalent tests before exposure. Current pages use reauthorized local polling, not global data subscriptions; exports are absent.
- Validate actual APIs/profile names/units, missing/truncated data, provider quotas and real workload cost with a bounded authorized read.
- Review backup access/encryption, isolated restore, management hosting failure domain and command-center self-monitoring.
- Record owners, approval evidence, installed versions and actual live checks. A JSON `multi_company_reviewed` switch is not itself independent approval.

Implemented local evidence is listed in `../../ops_command_center_v2/IMPLEMENTATION_STATUS.md`. Passing fixtures/local TLS/load checks does not grant live access, prove a production security audit, or satisfy this gate.
