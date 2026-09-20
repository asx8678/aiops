# Standalone release checks: no dependency code paths, app startup or DB suite.
ExUnit.start()

defmodule ReleaseTestEnv do
  def with_env(values, fun) do
    previous = Map.new(values, fn {key, _} -> {key, System.get_env(key)} end)
    put(values)

    try do
      fun.()
    after
      put(previous)
    end
  end

  defp put(values) do
    Enum.each(values, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end
end

defmodule ReleaseRuntimeContractTest do
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)

  defp config(extra \\ %{}) do
    env = %{
      "DATABASE_URL" => "ecto://unit@unit.invalid/unit",
      "DATABASE_CA_FILE" => "/unit/ca.pem",
      "SECRET_KEY_BASE" => String.duplicate("unit-test-only-", 8),
      "PHX_HOST" => "unit.invalid",
      "PHX_SERVER" => "true",
      "PORT" => "4000",
      "POOL_SIZE" => "10",
      "HTTP_BIND" => nil,
      "OPS_BRAIN_METRICS_CONSOLE" => nil,
      "OPS_BRAIN_OIDC_ENABLED" => nil
    }

    ReleaseTestEnv.with_env(Map.merge(env, extra), fn ->
      production = File.read!(Path.join(@root, "config/prod.exs"))
      runtime = File.read!(Path.join(@root, "config/runtime.exs"))

      temporary =
        Path.join(
          System.tmp_dir!(),
          "ops-brain-runtime-#{System.unique_integer([:positive])}.exs"
        )

      File.write!(temporary, Enum.join([production, runtime], "\n"), [:exclusive])

      try do
        Config.Reader.read!(temporary, env: :prod)
      after
        File.rm!(temporary)
      end
    end)
  end

  test "production defaults retain loopback, port, HTTPS proxy and verified DB TLS" do
    cfg = config()[:ops_brain]
    endpoint = cfg[OpsBrainWeb.Endpoint]
    assert endpoint[:server]
    assert endpoint[:http][:ip] == {127, 0, 0, 1}
    assert endpoint[:http][:port] == 4000
    assert endpoint[:force_ssl] == [hsts: true, rewrite_on: [:x_forwarded_proto]]
    assert endpoint[:url] == [host: "unit.invalid", port: 443, scheme: "https"]
    assert cfg[OpsBrain.Repo][:ssl] == [verify: :verify_peer, cacertfile: "/unit/ca.pem"]
    refute cfg[:metrics_console]
    assert cfg[:oidc][:enabled] == false
  end

  test "production binding supports reviewed wildcard and rejects arbitrary addresses" do
    cfg = config(%{"HTTP_BIND" => "0.0.0.0", "PORT" => "4010", "PHX_SERVER" => "false"})
    assert cfg[:ops_brain][OpsBrainWeb.Endpoint][:http] == [port: 4010, ip: {0, 0, 0, 0}]
    refute cfg[:ops_brain][OpsBrainWeb.Endpoint][:server]

    for bad <- ["", "localhost", "::", "192.0.2.1", "0.0.0.0;exec"] do
      assert_raise RuntimeError, ~r/HTTP_BIND/, fn -> config(%{"HTTP_BIND" => bad}) end
    end
  end

  test "metrics export requires explicit opt-in" do
    assert config(%{"OPS_BRAIN_METRICS_CONSOLE" => "true"})[:ops_brain][:metrics_console]
    refute config(%{"OPS_BRAIN_METRICS_CONSOLE" => "false"})[:ops_brain][:metrics_console]
  end

  test "release Elixir files parse without loading production application" do
    for path <- Path.wildcard(Path.join(@root, "rel/**/*.exs")) do
      assert {:ok, _} = path |> File.read!() |> Code.string_to_quoted(file: path)
    end

    refute Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :ops_brain end)
  end
end

# Minimal test-only doubles exercise the migration gate without PostgreSQL.
defmodule Ecto.Migrator do
  def with_repo(repo, fun), do: {:ok, fun.(repo), []}

  def run(_repo, direction, opts) do
    send(self(), {:migration, direction, opts})
    []
  end
end

defmodule OpsBrain.Repo do
  def query!(_sql), do: %{rows: [Process.get(:migration_role, ["ops_brain_migrator", false])]}
end

defmodule ReleaseMigrationGateTest do
  use ExUnit.Case, async: false
  @script Path.expand("../overlays/ops/migrate.exs", __DIR__)

  setup do
    :application.load(
      {:application, :ops_brain, [vsn: ~c"test", modules: [], applications: [:kernel, :stdlib]]}
    )

    :ok
  end

  test "migration refuses missing approval before repo access" do
    ReleaseTestEnv.with_env(%{"OPS_BRAIN_MIGRATION_APPROVED" => nil}, fn ->
      assert_raise RuntimeError, ~r/explicit approval/, fn -> Code.eval_file(@script) end
      refute_received {:migration, _, _}
    end)
  end

  test "wrong or privileged identity never migrates" do
    ReleaseTestEnv.with_env(%{"OPS_BRAIN_MIGRATION_APPROVED" => "true"}, fn ->
      for role <- [["ops_brain_runtime", false], ["postgres", true], ["ops_brain_migrator", true]] do
        Process.put(:migration_role, role)
        assert_raise RuntimeError, ~r/dedicated/, fn -> Code.eval_file(@script) end
        refute_received {:migration, _, _}
      end
    end)
  end

  test "approved migration identity runs only up, never starts the app" do
    ReleaseTestEnv.with_env(%{"OPS_BRAIN_MIGRATION_APPROVED" => "true"}, fn ->
      Code.eval_file(@script)
    end)

    assert_received {:migration, :up, [all: true, log: false]}
    refute Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :ops_brain end)
  end
end
