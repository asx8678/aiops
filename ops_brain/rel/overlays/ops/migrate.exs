# Invoked by release eval: NEVER Application.ensure_all_started(:ops_brain).
unless System.get_env("OPS_BRAIN_MIGRATION_APPROVED") == "true" do
  raise "Migration requires explicit approval"
end

case Application.load(:ops_brain) do
  :ok -> :ok
  {:error, {:already_loaded, :ops_brain}} -> :ok
  error -> raise "Cannot load release application: #{inspect(error)}"
end

{:ok, _, _} =
  Ecto.Migrator.with_repo(OpsBrain.Repo, fn repo ->
    %{rows: [[role, unsafe]]} =
      repo.query!(
        "SELECT current_user, rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user"
      )

    unless role == "ops_brain_migrator" and not unsafe do
      raise "Use the dedicated non-superuser, non-BYPASSRLS migration identity"
    end

    Ecto.Migrator.run(repo, :up, all: true, log: false)
  end)

IO.puts("Migrations complete; apply reviewed runtime grants before startup")
