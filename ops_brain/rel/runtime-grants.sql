-- Run as ops_brain_migrator AFTER all migrations, on the approved database.
-- Fixed current-schema contract; new tables require a fresh privilege review.
\set ON_ERROR_STOP on
\if :{?approved_database}
\else
  \echo 'Pass -v approved_database=EXACT_DEDICATED_DATABASE after approval'
  \quit 3
\endif
SELECT current_database() = :'approved_database'
  AND current_user = 'ops_brain_migrator' AS approved \gset
\if :approved
\else
  \echo 'Wrong database or migration identity; refusing'
  \quit 3
\endif
BEGIN;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM ops_brain_runtime;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM ops_brain_runtime;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, ops_brain_runtime;
GRANT SELECT ON public.companies, public.operators, public.memberships,
  public.schema_migrations TO ops_brain_runtime;
GRANT SELECT, INSERT, DELETE ON public.operator_tokens, public.oidc_attempts TO ops_brain_runtime;
-- OIDC rechecks enabled status on every session use; no identity UPDATE grant.
GRANT SELECT, INSERT, UPDATE, DELETE ON
  public.environments, public.sources, public.collection_states,
  public.pipeline_runs, public.run_snapshots, public.evidence_items,
  public.error_fingerprints, public.issue_groups, public.failure_occurrences,
  public.service_instances, public.observation_windows, public.source_budgets,
  public.notification_outbox, public.kubernetes_cursors,
  public.oban_jobs, public.oban_peers
  TO ops_brain_runtime;
GRANT SELECT, INSERT, DELETE ON public.observation_revisions TO ops_brain_runtime;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ops_brain_runtime;
GRANT USAGE ON TYPE public.oban_job_state TO ops_brain_runtime;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ops_brain_backup;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO ops_brain_backup;
-- No CREATE, TRUNCATE, REFERENCES, TRIGGER, ownership, membership or BYPASSRLS.
-- Oban v14 has removed its notify trigger; pg_notify is a pg_catalog function.
COMMIT;
