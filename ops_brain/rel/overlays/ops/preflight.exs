# Read-only database readiness, separately invoked; does not start app/workers.
case Application.load(:ops_brain) do
  :ok -> :ok
  {:error, {:already_loaded, :ops_brain}} -> :ok
  error -> raise "Cannot load release application: #{inspect(error)}"
end

OpsBrain.Configuration.load!()

{:ok, :ok, _} =
  Ecto.Migrator.with_repo(OpsBrain.Repo, fn repo ->
    OpsBrain.DatabaseSafety.verify!()

    %{rows: [[unsafe]]} =
      repo.query!("""
      SELECT current_user <> 'ops_brain_runtime'
        OR has_schema_privilege(current_user, 'public', 'CREATE')
        OR has_database_privilege(current_user, current_database(), 'CREATE')
        OR EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'public'
                   AND pg_has_role(current_user, nspowner, 'MEMBER'))
        OR EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                   WHERE n.nspname='public' AND pg_has_role(current_user, c.relowner, 'MEMBER'))
        OR EXISTS (SELECT 1 FROM pg_database WHERE datname = current_database()
                   AND pg_has_role(current_user, datdba, 'MEMBER'))
        OR EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user
                   AND (rolcreaterole OR rolcreatedb OR rolreplication))
      """)

    if unsafe, do: raise("Unsafe runtime DDL/ownership/role privileges")

    # Do not call Ecto.Migrator.migrations: it may create schema_migrations.
    %{rows: rows} = repo.query!("SELECT version FROM public.schema_migrations ORDER BY version")
    applied = rows |> List.flatten() |> MapSet.new()

    expected =
      Application.app_dir(:ops_brain, "priv/repo/migrations/*.exs")
      |> Path.wildcard()
      |> Enum.map(fn path ->
        path |> Path.basename() |> String.split("_", parts: 2) |> hd() |> String.to_integer()
      end)
      |> MapSet.new()

    unless MapSet.equal?(applied, expected), do: raise("Database/image migration versions differ")
    :ok
  end)

IO.puts(
  "Runtime role, RLS, deployment JSON and migration versions verified; no source probe performed"
)
