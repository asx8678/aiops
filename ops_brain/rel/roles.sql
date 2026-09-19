-- DBA-reviewed ONE-TIME provisioning, not a migration or container init hook.
-- Run against an approved, existing, EMPTY dedicated database as its DBA.
-- No passwords: login remains disabled until owner configures approved auth.
\set ON_ERROR_STOP on
\if :{?approved_database}
\else
  \echo 'Pass -v approved_database=EXACT_DEDICATED_DATABASE after approval'
  \quit 3
\endif
SELECT current_database() = :'approved_database'
  AND current_database() NOT IN ('postgres', 'template0', 'template1')
  AND NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                  WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S')) AS approved \gset
\if :approved
\else
  \echo 'Wrong database or public schema not empty; refusing'
  \quit 3
\endif
BEGIN;
-- Fails if roles already exist: do not silently reuse inherited privileges.
CREATE ROLE ops_brain_migrator NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
CREATE ROLE ops_brain_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
-- Separate privileged backup boundary; only DBA may enable this identity.
-- FORCE RLS means the ordinary owner/runtime cannot produce a complete dump.
CREATE ROLE ops_brain_backup NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION BYPASSRLS NOINHERIT;
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database()) \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO ops_brain_migrator, ops_brain_runtime, ops_brain_backup', current_database()) \gexec
REVOKE ALL ON SCHEMA public FROM PUBLIC;
ALTER SCHEMA public OWNER TO ops_brain_migrator;
GRANT USAGE ON SCHEMA public TO ops_brain_runtime, ops_brain_backup;
-- Database ownership stays with the DBA, never runtime. No role memberships.
ALTER DEFAULT PRIVILEGES FOR ROLE ops_brain_migrator IN SCHEMA public
  REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE ops_brain_migrator IN SCHEMA public
  GRANT SELECT ON TABLES TO ops_brain_backup;
ALTER DEFAULT PRIVILEGES FOR ROLE ops_brain_migrator IN SCHEMA public
  GRANT SELECT ON SEQUENCES TO ops_brain_backup;
ALTER DEFAULT PRIVILEGES FOR ROLE ops_brain_migrator IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
-- No default runtime DML: each schema revision needs reviewed explicit grants.
COMMIT;
