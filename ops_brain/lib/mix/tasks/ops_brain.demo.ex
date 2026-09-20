defmodule Mix.Tasks.OpsBrain.Demo do
  use Mix.Task
  @shortdoc "Seed a labeled offline demo workspace in the local development database"
  @moduledoc """
  DATABASE_URL=<local migrator URL> mix ops_brain.demo --operator adam --confirm

  Does not start the web application or contact providers. The named enabled
  operator must already exist. Rerunning preserves data and local review changes.
  --reset replaces ONLY the reserved demo workspace's observations; --remove
  deletes ONLY that workspace. Both require --confirm. Production builds and
  non-local/non-development databases are rejected. No credentials are printed.
  """
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [operator: :string, confirm: :boolean, reset: :boolean, remove: :boolean]
      )

    unless opts[:confirm] == true and rest == [] and invalid == [] and
             not (opts[:reset] == true and opts[:remove] == true) and
             (opts[:remove] == true or is_binary(opts[:operator])),
           do: Mix.raise("Use --operator NAME --confirm [--reset], or --remove --confirm")

    unless Mix.env() == :dev, do: Mix.raise("The demo task only runs in MIX_ENV=dev")
    Mix.Task.run("app.config")

    {:ok, result, _} =
      Ecto.Migrator.with_repo(
        OpsBrain.Repo,
        fn repo ->
          if opts[:remove],
            do: OpsBrain.Demo.remove!(repo),
            else: OpsBrain.Demo.seed!(repo, opts[:operator], reset: opts[:reset] || false)
        end,
        log: false
      )

    if opts[:remove] do
      Mix.shell().info("Demo workspace removed; other workspaces unchanged.")
    else
      Mix.shell().info(
        "Synthetic offline demo ready: /companies/#{result.company_id}/demo\nNo external connections, jobs, deliveries, or credentials created."
      )
    end
  end
end
