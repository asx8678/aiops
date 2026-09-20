-- Run against the application database as its migration/table owner after migrations.
-- The DBA must create ops_brain_runtime separately (LOGIN, NOSUPERUSER, NOBYPASSRLS,
-- NOCREATEDB, NOCREATEROLE, no membership in the owner role). Never use it for DDL.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO ops_brain_runtime;
GRANT SELECT ON operators, companies, memberships, schema_migrations TO ops_brain_runtime;
GRANT SELECT, INSERT, DELETE ON oidc_attempts TO ops_brain_runtime;
GRANT SELECT, INSERT, DELETE ON operator_tokens TO ops_brain_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON sources, environments, collection_states, pipeline_runs, run_snapshots, evidence_items, error_fingerprints, issue_groups, failure_occurrences, service_instances, observation_windows, source_budgets, notification_outbox, kubernetes_cursors TO ops_brain_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON oban_jobs, oban_peers TO ops_brain_runtime;
REVOKE UPDATE ON observation_revisions FROM ops_brain_runtime;
GRANT SELECT, INSERT, DELETE ON observation_revisions TO ops_brain_runtime;
-- Immutable occurrence history: append/expire only, never edit in place.
REVOKE UPDATE ON occurrence_evidence FROM ops_brain_runtime;
GRANT SELECT, INSERT, DELETE ON occurrence_evidence TO ops_brain_runtime;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ops_brain_runtime;
