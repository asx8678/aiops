defmodule OpsBrain.Demo do
  @moduledoc "Offline demo provisioning and scoped reads. Never installs or enables a source adapter."
  alias OpsBrain.{Store, Tenancy}
  alias OpsBrain.Demo.Dataset
  @seed_build Mix.env() in [:dev, :test]

  def company_id, do: Dataset.company_id()
  def company?(id), do: id == company_id()

  def seed!(repo, operator_name, opts \\ []) do
    verify_local!(repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    result =
      repo.transaction(
        fn ->
          repo.query!("SELECT pg_advisory_xact_lock(7409132026)")

          [[operator_id]] =
            repo.query!("SELECT id::text FROM operators WHERE name=$1 AND enabled=true", [
              operator_name
            ]).rows

          existing = reserved_company!(repo)
          scope!(repo)
          if existing and Keyword.get(opts, :reset, false), do: delete_records!(repo)

          unless existing do
            repo.query!(
              "INSERT INTO companies(id,name,slug,inserted_at,updated_at) VALUES($1::text::uuid,$2,$3,$4,$4)",
              [company_id(), Dataset.name(), Dataset.slug(), now]
            )
          end

          repo.query!(
            "INSERT INTO memberships(operator_id,company_id) VALUES($1::text::uuid,$2::text::uuid) ON CONFLICT DO NOTHING",
            [operator_id, company_id()]
          )

          if not existing or Keyword.get(opts, :reset, false) do
            for {table, row} <- Dataset.build(now), do: insert!(repo, table, row)
          end

          %{
            company_id: company_id(),
            created: not existing,
            reset: Keyword.get(opts, :reset, false)
          }
        end,
        timeout: 60_000
      )

    case result do
      {:ok, value} -> value
      {:error, reason} -> raise "Demo transaction rolled back: #{inspect(reason)}"
    end
  end

  def remove!(repo) do
    verify_local!(repo)

    repo.transaction(fn ->
      repo.query!("SELECT pg_advisory_xact_lock(7409132026)")

      if reserved_company!(repo) do
        scope!(repo)
        delete_records!(repo)
        repo.query!("DELETE FROM companies WHERE id=$1::text::uuid", [company_id()])
      end

      :removed
    end)
  end

  def verify_local!(repo) do
    unless @seed_build, do: raise("Demo provisioning is unavailable in production builds")
    config = repo.config()
    uri = URI.parse(Keyword.get(config, :url, ""))
    hostname = config[:hostname] || uri.host
    database = config[:database] || String.trim_leading(uri.path || "", "/")

    [[db, host, approval, superuser]] =
      repo.query!("""
      SELECT current_database(), COALESCE(inet_server_addr()::text,'local'),
        current_setting('ops_brain.disposable_test',true),
        (SELECT rolsuper FROM pg_roles WHERE rolname=current_user)
      """).rows

    local_url = hostname in ["localhost", "127.0.0.1", "::1"]

    disposable =
      String.starts_with?(db, "ops_brain_test") and approval == "approved" and
        System.get_env("OPS_BRAIN_DISPOSABLE_TEST") == "true"

    unless local_url and host in ["local", "127.0.0.1/32", "::1/128", "127.0.0.1", "::1"] and
             database == db and not superuser and (db == "ops_brain_dev" or disposable),
           do:
             raise(
               "Demo requires local ops_brain_dev or an approved disposable test DB, using the non-superuser migrator"
             )

    :ok
  end

  # Exact identity AND name guard. Never overwrite a similarly named user workspace.
  defp reserved_company!(repo) do
    case repo.query!(
           "SELECT id::text,name,slug FROM companies WHERE id=$1::text::uuid OR slug=$2",
           [company_id(), Dataset.slug()]
         ).rows do
      [] ->
        false

      [[id, name, slug]] ->
        if id == company_id() and name == Dataset.name() and slug == Dataset.slug(),
          do: true,
          else: raise("Reserved demo identity collision; refusing to modify it")

      _ ->
        raise "Reserved demo identity collision; refusing to modify it"
    end
  end

  defp scope!(repo),
    do: repo.query!("SELECT set_config('ops_brain.company_id',$1,true)", [company_id()])

  defp delete_records!(repo) do
    repo.query!("DELETE FROM sources WHERE company_id=$1::text::uuid", [company_id()])
    repo.query!("DELETE FROM environments WHERE company_id=$1::text::uuid", [company_id()])
  end

  defp insert!(repo, table, row) do
    {keys, values} = row |> Enum.sort_by(fn {k, _} -> k end) |> Enum.unzip()

    placeholders =
      Enum.with_index(keys, 1)
      |> Enum.map_join(",", fn {key, n} ->
        if key in [
             :id,
             :company_id,
             :source_id,
             :environment_id,
             :project_id,
             :service_id,
             :group_id,
             :evidence_id,
             :occurrence_id
           ], do: "$#{n}::text::uuid", else: "$#{n}"
      end)

    # Identifiers come exclusively from Dataset.build/1, never browser input.
    repo.query!("INSERT INTO #{table}(#{Enum.join(keys, ",")}) VALUES(#{placeholders})", values)
  end

  def summary(scope, now \\ Store.now()) do
    if company?(scope.company_id) do
      Tenancy.with_scope(scope, fn ->
        row =
          Store.one(
            "SELECT data FROM evidence_items WHERE kind='demo_manifest' AND evidence_key='manifest' AND expires_at > $1 LIMIT 1",
            [now]
          )

        row && row["data"]
      end)
    else
      {:error, :not_found}
    end
  end

  def snapshot(scope, now \\ Store.now()) do
    if company?(scope.company_id) do
      Tenancy.with_scope(scope, fn ->
        manifest =
          Store.one(
            "SELECT data,expires_at FROM evidence_items WHERE kind='demo_manifest' AND evidence_key='manifest' AND expires_at > $1 LIMIT 1",
            [now]
          )

        resources =
          if manifest do
            Store.rows(
              "SELECT id::text,data FROM evidence_items WHERE kind='demo_resource' AND expires_at > $1 ORDER BY data->>'cluster',data->>'kind',data->>'name',id LIMIT 1000",
              [now]
            )
          else
            []
          end

        %{manifest: manifest && manifest["data"], resources: resources}
      end)
    else
      {:error, :not_found}
    end
  end
end
