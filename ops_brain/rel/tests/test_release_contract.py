"""Release-only tests: never starts Mix, Docker, PostgreSQL or the application.
Run: python3 -m unittest discover -s rel/tests -p 'test_*.py' -v
PyYAML is a check-time dependency, not an application dependency.
"""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]


class ReleaseContract(unittest.TestCase):
    def test_disabled_nonroot_compose_and_secret_separation(self):
        cfg = yaml.safe_load((ROOT / 'compose.example.yml').read_text())
        for name, service in cfg['services'].items():
            self.assertTrue(service['profiles'], name)
            self.assertEqual(service['user'], '10001:10001')
            self.assertTrue(service['read_only'])
            self.assertEqual(service['restart'], 'no')
            self.assertEqual(service['cap_drop'], ['ALL'])
            self.assertIn('no-new-privileges:true', service['security_opt'])
            self.assertEqual(service['network_mode'], 'host')
            self.assertNotIn('ports', service)
            self.assertNotIn('build', service)
            self.assertEqual(service['environment']['OPS_BRAIN_OIDC_ENABLED'], 'false')
        app, migration = (cfg['services'][n] for n in ('app', 'migrate'))
        self.assertNotIn('migration_database_url', app['secrets'])
        self.assertNotIn('runtime_database_url', migration['secrets'])
        self.assertEqual(migration['command'], ['disabled'])
        self.assertEqual(migration['environment']['OPS_BRAIN_MIGRATION_APPROVED'], 'false')
        self.assertIn(':-false}', app['environment']['OPS_BRAIN_START_APPROVED'])
        for spec in cfg['secrets'].values():
            self.assertIn('/UNCONFIGURED/', spec['file'])

    def test_docker_release_inputs_and_no_secret_baking(self):
        docker = (ROOT / 'Dockerfile').read_text()
        self.assertIn('elixir:1.20.4-otp-27-slim', docker)
        self.assertEqual(docker.count('FROM base AS'), 2)
        for command in ['mix deps.get --only prod', 'mix compile --warnings-as-errors',
                        'mix phx.digest', 'mix release', 'USER 10001:10001', 'CMD ["disabled"]']:
            self.assertIn(command, docker)
        self.assertNotRegex(docker, r'(?m)^COPY\s+\.\s')
        self.assertNotRegex(docker, r'(?m)^(?:ARG|ENV)\s+(?:DATABASE_URL|SECRET_KEY_BASE|.*PASSWORD)')
        ignore = (ROOT / '.dockerignore').read_text().splitlines()
        self.assertIn('**', ignore)
        self.assertNotIn('!config/**', ignore)
        self.assertNotIn('!rel/**', ignore)
        for path in ['!.env', '!deps/**', '!_build/**', '!priv/repo/seeds.exs']:
            self.assertNotIn(path, ignore)

    def test_source_defaults_and_optional_oidc_names(self):
        cfg = json.loads((ROOT / 'config/sources.example.json').read_text())
        self.assertFalse(cfg['collection_enabled'])
        self.assertFalse(cfg['delivery_enabled'])
        self.assertEqual(cfg['sources'], [])
        self.assertEqual(cfg['notification_sinks'], {})
        prepared = json.loads((ROOT / 'config/sources.prepared.json').read_text())
        self.assertFalse(prepared['collection_enabled'])
        self.assertFalse(prepared['delivery_enabled'])
        self.assertTrue(prepared['sources'])
        self.assertTrue(prepared['notification_sinks'])
        self.assertTrue(all(s['enabled'] is False for s in prepared['sources']))
        self.assertTrue(all(s['enabled'] is False for s in prepared['notification_sinks'].values()))
        for doc in ['DEPLOYMENT.md', 'CREDENTIALS.md']:
            self.assertIn('config/sources.prepared.json', (ROOT / 'docs' / doc).read_text())
        runtime = (ROOT / 'config/runtime.exs').read_text()
        example = (ROOT / '.env.example').read_text()
        for key in set(re.findall(r'"(OPS_BRAIN_OIDC_[A-Z_]+)"', runtime)):
            self.assertIn(key + '=', example)
        self.assertNotIn('OPS_BRAIN_OIDC_SCOPES=', example)
        self.assertNotRegex(example, r'(?im)^[^#\n]*(?:PASSWORD|SECRET|DATABASE_URL)=[^\n]+')

    def test_grants_cover_actual_tables_without_runtime_ddl(self):
        migrations = '\n'.join(p.read_text() for p in (ROOT / 'priv/repo/migrations').glob('*.exs'))
        tables = set(re.findall(r'create table\(:(\w+)', migrations))
        grants = (ROOT / 'rel/runtime-grants.sql').read_text()
        for name in tables | {'schema_migrations', 'oban_jobs', 'oban_peers'}:
            self.assertIn('public.' + name, grants, name)
        roles = (ROOT / 'rel/roles.sql').read_text()
        runtime = re.search(r'CREATE ROLE ops_brain_runtime ([^;]+);', roles).group(1)
        for flag in ['NOLOGIN', 'NOSUPERUSER', 'NOBYPASSRLS', 'NOCREATEDB', 'NOCREATEROLE', 'NOINHERIT']:
            self.assertIn(flag, runtime)
        self.assertIn('ALTER SCHEMA public OWNER TO ops_brain_migrator;', roles)
        self.assertNotRegex(roles + grants, r'OWNER TO ops_brain_runtime|GRANT ops_brain_migrator TO')
        statements = re.sub(r'--[^\n]*', '', roles + grants)
        self.assertNotRegex(statements, r'GRANT (?:ALL|CREATE|TRUNCATE)[^;]*TO ops_brain_runtime')
        self.assertNotRegex(statements, r'GRANT\s+[^;]*UPDATE[^;]*ON\s+public\.operators')
        self.assertIn('GRANT SELECT, INSERT, DELETE ON public.observation_revisions', grants)
        self.assertNotIn('GRANT UPDATE (enabled)', grants)
        self.assertIn('GRANT SELECT ON public.companies, public.operators, public.memberships,\n  public.schema_migrations', grants)

    def test_release_scripts_do_not_start_workers_or_rollback(self):
        for name in ['migrate', 'preflight']:
            script = (ROOT / f'rel/overlays/ops/{name}.exs').read_text()
            executable = re.sub(r'#[^\n]*', '', script)
            self.assertNotIn('ensure_all_started(:ops_brain)', executable)
            self.assertIn('Ecto.Migrator.with_repo', executable)
            self.assertNotIn(':down', executable)
        preflight = (ROOT / 'rel/overlays/ops/preflight.exs').read_text()
        self.assertIn('MapSet.equal?(applied, expected)', preflight)
        self.assertIn('has_schema_privilege', preflight)
        self.assertIn('pg_has_role', preflight)
        self.assertIn('DatabaseSafety.verify!()', preflight)

    def test_shell_syntax(self):
        paths = list((ROOT / 'rel/overlays/bin').iterdir()) + [ROOT / 'rel/env.sh.eex']
        paths += list((ROOT / 'scripts').glob('release-*.sh'))
        for path in paths:
            with self.subTest(path=path.name):
                self.assertEqual(subprocess.run(['sh', '-n', str(path)], capture_output=True).returncode, 0)


class ShellBehavior(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ops-brain-release-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls'
        self.env = {'PATH': f'{self.bin}:/usr/bin:/bin', 'HOME': str(self.root)}
        # Every DB executable is stubbed; env -i still uses this controlled PATH.
        self.stub('psql', 't')
        self.stub('pg_restore', '')
        self.stub('pg_dump', 'FAKE_ARCHIVE')
        self.secret = self.root / 'test-only-value'
        self.secret.write_text('x' * 64)
        self.secret.chmod(0o600)

    def stub(self, name, output, code=0):
        path = self.bin / name
        path.write_text(f'#!/bin/sh\nprintf "%s\\n" "{name}:$*" >> "{self.log}"\nprintf "%s" "{output}"\nexit {code}\n')
        path.chmod(0o700)

    def run_script(self, path, *args, env=None):
        return subprocess.run(['sh', str(ROOT / path), *map(str, args)],
                              env=self.env | (env or {}), capture_output=True, text=True, timeout=5)

    def database_env(self):
        return {'PGSERVICEFILE': str(self.secret), 'PGPASSFILE': str(self.secret),
                'PGSSLROOTCERT': str(self.secret)}

    def test_disabled_commands_fail_before_any_credentials_or_database(self):
        for command in [None, 'disabled', 'start', 'migrate', 'eval', 'sh']:
            args = [] if command is None else [command]
            result = self.run_script('rel/overlays/bin/release-command', *args)
            self.assertEqual(result.returncode, 64, (command, result.stderr))
        self.assertFalse(self.log.exists())

    def test_release_dispatch_loads_file_secrets_without_printing_them(self):
        shutil.copy(ROOT / 'rel/overlays/bin/release-command', self.bin / 'release-command')
        self.stub('ops_brain', 'RELEASE_STUB')
        env = self.env | {'OPS_BRAIN_START_APPROVED': 'true',
                          'DATABASE_URL_FILE': str(self.secret), 'SECRET_KEY_BASE_FILE': str(self.secret),
                          'DATABASE_CA_FILE': str(self.secret), 'OPS_BRAIN_CONFIG_FILE': str(self.secret),
                          'PHX_HOST': 'unit.invalid'}
        result = subprocess.run(['sh', str(self.bin / 'release-command'), 'start'], env=env,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertIn('ops_brain:eval Code.eval_file("ops/preflight.exs")', calls)
        self.assertLess(calls.index('ops_brain:eval'), calls.index('ops_brain:start'))
        self.assertNotIn('x' * 64, result.stdout + result.stderr + self.log.read_text())
        self.log.unlink()
        self.stub('ops_brain', '', 9)
        refused = subprocess.run(['sh', str(self.bin / 'release-command'), 'start'], env=env,
                                 capture_output=True, text=True, timeout=5)
        self.assertEqual(refused.returncode, 9)
        self.assertNotIn('ops_brain:start', self.log.read_text())

    def test_liveness_requires_exact_200_not_redirect_or_error(self):
        for status, code, expected in [('200', 0, 0), ('301', 0, 1), ('503', 0, 1), ('000', 7, 7)]:
            self.stub('curl', status, code)
            result = self.run_script('rel/overlays/bin/healthcheck', env={'PHX_HOST': 'unit.invalid'})
            self.assertEqual(result.returncode, expected)
        calls = self.log.read_text()
        self.assertIn('/sign-in', calls)
        self.assertIn('X-Forwarded-Proto: https', calls)
        self.assertNotIn('--location', calls)

    def test_backup_approval_identity_and_no_overwrite(self):
        output = self.root / 'dump'
        env = self.database_env() | {'PGSERVICE': 'ops_brain_backup', 'OPS_BRAIN_BACKUP_APPROVED': 'true'}
        self.assertEqual(self.run_script('scripts/release-backup.sh', output).returncode, 64)
        self.assertFalse(self.log.exists())
        self.stub('psql', 'f')
        self.assertEqual(self.run_script('scripts/release-backup.sh', output, env=env).returncode, 64)
        self.assertFalse(output.exists())
        self.stub('psql', 't')
        result = self.run_script('scripts/release-backup.sh', output, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text(), 'FAKE_ARCHIVE')
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertNotEqual(self.run_script('scripts/release-backup.sh', output, env=env).returncode, 0)
        self.assertEqual(output.read_text(), 'FAKE_ARCHIVE')
        self.assertIn('sslmode=verify-full', self.log.read_text())

    def test_restore_toc_filter_preserves_tables_and_other_schema_entries(self):
        archive = self.root / 'archive'
        archive.write_text('FAKE_ARCHIVE')
        capture = self.root / 'filtered'
        restore = self.bin / 'pg_restore'
        restore.write_text(
            '#!/bin/sh\n'
            'if [ "$1" = --list ]; then\n'
            "  printf '%s\\n' '1; 2615 2200 SCHEMA - public owner' '2; 2615 2201 SCHEMA - other owner' '3; 1259 2202 TABLE public sources owner'\n"
            'else\n'
            f'  for arg do case "$arg" in --use-list=*) cat "${{arg#--use-list=}}" > "{capture}" ;; esac; done\n'
            'fi\n')
        env = self.database_env() | {'PGSERVICE': 'ops_brain_disposable_restore',
              'OPS_BRAIN_DISPOSABLE_RESTORE': 'I_CONFIRM_DEDICATED_DISPOSABLE',
              'RESTORE_DATABASE': 'ops_brain_restore_unit', 'RESTORE_CONFIRM_DATABASE': 'ops_brain_restore_unit'}
        result = self.run_script('scripts/release-restore-disposable.sh', archive, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(capture.read_text().splitlines(), [
            ';1; 2615 2200 SCHEMA - public owner',
            '2; 2615 2201 SCHEMA - other owner',
            '3; 1259 2202 TABLE public sources owner'])

    def test_restore_all_guards_and_single_transaction_without_clean(self):
        archive = self.root / 'archive'
        archive.write_text('FAKE_ARCHIVE')
        env = self.database_env() | {'PGSERVICE': 'ops_brain_disposable_restore',
              'OPS_BRAIN_DISPOSABLE_RESTORE': 'I_CONFIRM_DEDICATED_DISPOSABLE',
              'RESTORE_DATABASE': 'ops_brain_restore_unit', 'RESTORE_CONFIRM_DATABASE': 'ops_brain_restore_unit'}
        for bad in [{'OPS_BRAIN_DISPOSABLE_RESTORE': ''}, {'RESTORE_DATABASE': 'production'},
                    {'RESTORE_DATABASE': 'ops_brain_restore_'}, {'RESTORE_CONFIRM_DATABASE': 'other'},
                    {'PGSERVICE': 'live'}, {'RESTORE_DATABASE': "ops_brain_restore_x'; DROP DATABASE x;--"}]:
            result = self.run_script('scripts/release-restore-disposable.sh', archive, env=env | bad)
            self.assertEqual(result.returncode, 64)
        self.assertFalse(self.log.exists())
        self.stub('psql', 'f')
        result = self.run_script('scripts/release-restore-disposable.sh', archive, env=env)
        self.assertEqual(result.returncode, 64)
        self.assertNotIn('pg_restore:', self.log.read_text())
        self.stub('psql', 't')
        result = self.run_script('scripts/release-restore-disposable.sh', archive, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertIn('ops_brain.disposable_restore', calls)
        self.assertIn('pg_class', calls)
        self.assertIn('--single-transaction', calls)
        self.assertIn('--use-list=', calls)
        self.assertIn('--exit-on-error', calls)
        self.assertIn('sslmode=verify-full', calls)
        self.assertNotIn('--clean', calls)
        self.assertNotIn('--create', calls)
        self.stub('pg_restore', '', 9)
        self.assertEqual(self.run_script('scripts/release-restore-disposable.sh', archive, env=env).returncode, 9)


if __name__ == '__main__':
    unittest.main()
