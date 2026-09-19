# Run ONLY with `bin/ops_brain eval` on an assembled release. No DB or app start.
root = System.fetch_env!("RELEASE_SOURCE_ROOT")

for {module, function, arity} <- [
      {OpsBrain.Configuration, :read!, 1},
      {OpsBrain.DatabaseSafety, :verify!, 0},
      {Ecto.Migrator, :with_repo, 2},
      {Ecto.Migrator, :run, 3}
    ] do
  Code.ensure_loaded!(module)
  unless function_exported?(module, function, arity), do: raise("Missing release API")
end

for file <- ["sources.example.json", "sources.prepared.json"] do
  cfg = OpsBrain.Configuration.read!(Path.join([root, "config", file]))
  false = cfg.collection_enabled
  false = cfg.delivery_enabled
  true = Enum.all?(cfg.sources, fn {_, source} -> source[:enabled] == false end)
  true = Enum.all?(cfg.notification_sinks, fn {_, sink} -> sink[:enabled] == false end)
end

for {app, asset} <- [
      {:ops_brain, "priv/static/assets/js/app.js"},
      {:ops_brain, "priv/static/cache_manifest.json"},
      {:phoenix, "priv/static/phoenix.js"},
      {:phoenix_live_view, "priv/static/phoenix_live_view.js"},
      {:phoenix_html, "priv/static/phoenix_html.js"}
    ] do
  true = File.regular?(Application.app_dir(app, asset))
end

expected =
  Path.wildcard(Path.join(root, "priv/repo/migrations/*.exs"))
  |> Enum.map(&Path.basename/1)
  |> Enum.sort()

packaged =
  Path.wildcard(Application.app_dir(:ops_brain, "priv/repo/migrations/*.exs"))
  |> Enum.map(&Path.basename/1)
  |> Enum.sort()

true = expected != [] and expected == packaged

for file <- ["ops/migrate.exs", "ops/preflight.exs", "bin/release-command", "bin/healthcheck"] do
  true = File.regular?(file)
end

# Actual locked Plug semantics: trusted forwarding must yield canonical HTTPS/443.
opts = Plug.SSL.init(hsts: true, rewrite_on: [:x_forwarded_proto])
conn = Plug.Test.conn(:get, "http://unit.invalid/sign-in")
forwarded = conn |> Plug.Conn.put_req_header("x-forwarded-proto", "https") |> Plug.SSL.call(opts)
:https = forwarded.scheme
443 = forwarded.port
false = forwarded.halted
true = conn |> Plug.SSL.call(opts) |> Map.fetch!(:halted)

nil = Process.whereis(OpsBrain.Repo)
false = Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :ops_brain end)

IO.puts(
  "Release probe passed: APIs, disabled configs, complete migration/assets/overlays, HTTPS forwarding; no app/Repo started"
)
