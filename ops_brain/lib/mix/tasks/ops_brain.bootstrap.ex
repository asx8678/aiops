defmodule Mix.Tasks.OpsBrain.Bootstrap do
  use Mix.Task
  @shortdoc "Offline operator/company provisioning using the migration identity"
  @moduledoc """
  mix ops_brain.bootstrap --operator NAME --company SLUG --name COMPANY_NAME

  Uses DATABASE_URL with the migration identity; does not start the web application.
  Prints one 15-minute, single-use login token. Treat stdout as a secret; do not put
  it in logs, tickets or shell history. Deliver it to the operator through an approved
  secret channel. Re-running explicitly adds the operator's company membership.
  """
  import Ecto.Query
  alias OpsBrain.{Accounts, Repo}
  alias OpsBrain.Accounts.Operator
  alias OpsBrain.Tenancy.{Company, Environment, Membership}

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [operator: :string, company: :string, name: :string])

    unless rest == [] and invalid == [] and
             Enum.all?(
               [:operator, :company, :name],
               &(is_binary(opts[&1]) and byte_size(opts[&1]) in 1..100)
             ) do
      Mix.raise("Expected --operator NAME --company SLUG --name COMPANY_NAME")
    end

    unless Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,62}\z/, opts[:company]),
      do: Mix.raise("Invalid company slug")

    Mix.Task.run("app.config")

    {:ok, {:ok, token}, _} =
      Ecto.Migrator.with_repo(
        Repo,
        fn _ ->
          Repo.transaction(fn ->
            operator =
              Repo.one(from o in Operator, where: o.name == ^opts[:operator]) ||
                Repo.insert!(%Operator{name: opts[:operator]})

            unless operator.enabled, do: Repo.rollback(:disabled_operator)

            company =
              Repo.one(from c in Company, where: c.slug == ^opts[:company]) ||
                Repo.insert!(%Company{name: opts[:name], slug: opts[:company]})

            Repo.insert!(%Membership{operator_id: operator.id, company_id: company.id},
              on_conflict: :nothing
            )

            Repo.query!("SELECT set_config('ops_brain.company_id', $1, true)", [company.id])

            for name <- [:dev, :staging, :prod] do
              Repo.insert!(%Environment{company_id: company.id, name: name},
                on_conflict: :nothing
              )
            end

            Accounts.issue_token(
              operator.id,
              "login",
              DateTime.add(DateTime.utc_now(), 15, :minute)
            )
          end)
        end,
        log: false
      )

    Mix.shell().info("Single-use login token (expires in 15 minutes):\n" <> token)
  end
end
