defmodule OpsBrain.PreparationTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{Configuration, Metrics, Workloads}

  setup do
    on_exit(&cleanup/0)
    fixture()
  end

  test "prepared config validates disabled but untouched activation fails closed" do
    path = Path.expand("config/sources.prepared.json")
    cfg = Configuration.read!(path)
    assert map_size(cfg.sources) == 4
    refute cfg.collection_enabled
    refute cfg.delivery_enabled
    assert Enum.all?(cfg.sources, fn {_, s} -> s.enabled == false end)
    input = File.read!(path) |> Jason.decode!()
    file = Path.join(System.tmp_dir!(), "ops-prepared-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(file) end)

    input =
      update_in(input, ["sources"], fn rows -> Enum.map(rows, &Map.put(&1, "enabled", true)) end)

    File.write!(file, Jason.encode!(input))
    assert_raise RuntimeError, "invalid source configuration", fn -> Configuration.read!(file) end
  end

  test "ratio profile reads matching counts at identical time and does not average pod percentages",
       f do
    {:ok, s} = Tenancy.create_source(f.scope_a, %{name: "ingress", kind: :prometheus})

    c =
      config(%{f | source_a: s}, :a, %{
        kind: "prometheus",
        profile: %{
          id: "5xx",
          version: 1,
          reviewed: true,
          semantics: "ratio",
          unit: "ratio",
          numerator_query: "synthetic_errors",
          denominator_query: "synthetic_requests",
          minimum_traffic: 50,
          threshold: 0.1
        }
      })

    now = DateTime.utc_now()
    Application.put_env(:ops_brain, :clock, fn -> now end)
    parent = self()

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, conn.query_params)

      values =
        if conn.query_params["query"] == "synthetic_errors",
          do: [{"a", "5"}, {"b", "0"}],
          else: [{"a", "10"}, {"b", "90"}]

      rows =
        Enum.map(values, fn {pod, v} ->
          %{
            metric: %{pod: pod, __name__: conn.query_params["query"]},
            value: [
              DateTime.to_unix(now) -
                if(conn.query_params["query"] == "synthetic_errors", do: 30, else: 34),
              v
            ]
          }
        end)

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{status: "success", data: %{resultType: "vector", result: rows}})
      )
    end)

    assert {:ok,
            %{
              "samples" => [%{"value" => 0.05, "timestamp" => timestamp}],
              "condition" => "normal"
            }} =
             Metrics.collect(c, now)

    assert timestamp == DateTime.to_unix(now) - 34

    assert_receive %{"time" => t, "query" => "synthetic_errors"}
    assert_receive %{"time" => ^t, "query" => "synthetic_requests"}
    no_traffic = %{c | profile: %{c.profile | minimum_traffic: 1000}}
    Application.put_env(:ops_brain, :sources, %{c.id => no_traffic})
    assert {:ok, %{"condition" => "unknown"}} = Metrics.collect(no_traffic, now)

    Application.put_env(:ops_brain, :sources, %{c.id => c})

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      {age, value} =
        if conn.query_params["query"] == "synthetic_errors", do: {120, "5"}, else: {0, "100"}

      row = %{metric: %{pod: "a"}, value: [DateTime.to_unix(now) - age, value]}

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{status: "success", data: %{resultType: "vector", result: [row]}})
      )
    end)

    assert {:ok,
            %{"samples" => [], "condition" => "unknown", "missing" => "unaligned_timestamps"}} =
             Metrics.collect(c, now)
  end

  test "kill switches discard queued network and cleanup work", f do
    c = config(f)
    Application.put_env(:ops_brain, :collection_enabled, false)

    Application.put_env(:ops_brain, :http_plug, fn _ ->
      flunk("disabled worker requested network")
    end)

    assert :discard = OpsBrain.CollectionWorker.perform(%Oban.Job{args: %{"source_id" => c.id}})

    assert :discard =
             OpsBrain.EvidenceWorker.perform(%Oban.Job{
               args: %{"source_id" => c.id, "run_id" => 101}
             })

    assert {:stop, :normal, _} = OpsBrain.KubernetesWatcher.handle_info(:watch, c.id)
    assert :discard = OpsBrain.MaintenanceWorker.perform(%Oban.Job{args: %{"source_id" => c.id}})
    assert :discard = OpsBrain.DirectoryMaintenanceWorker.perform(%Oban.Job{args: %{}})
  end

  test "expired directory tokens prune boundedly without changing live membership or session",
       f do
    now = DateTime.utc_now()
    for _ <- 1..3, do: OpsBrain.Accounts.issue_token(f.alice.id, "login", DateTime.add(now, -60))
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    :ok = OpsBrain.OIDC.Attempts.insert(state, DateTime.to_unix(now) - 1)

    assert {:ok, %{expired_tokens: 1, expired_attempts: 1}} =
             OpsBrain.DirectoryMaintenanceWorker.sweep(now, 1)

    assert OpsBrain.Accounts.operator_for_session(f.token_a).id == f.alice.id
    assert {:ok, _} = Tenancy.authorize(f.token_a, f.a.id)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE observation_revisions SET detector_version=99")
      end

    assert error.postgres.code == :insufficient_privilege
  end

  test "login limits are bounded per peer and globally and expire" do
    state = %{window: nil, total: 0, peers: %{}}

    state =
      Enum.reduce(1..30, state, fn _, s ->
        assert {:ok, n} = OpsBrainWeb.LoginLimiter.admit(s, {1, 2, 3, 4}, 120)
        n
      end)

    assert {:limited, ^state} = OpsBrainWeb.LoginLimiter.admit(state, {1, 2, 3, 4}, 120)
    assert {:ok, _} = OpsBrainWeb.LoginLimiter.admit(state, {1, 2, 3, 5}, 120)
    assert {:ok, %{total: 1}} = OpsBrainWeb.LoginLimiter.admit(state, {1, 2, 3, 4}, 180)

    state =
      Enum.reduce(1..200, %{window: nil, total: 0, peers: %{}}, fn n, s ->
        {:ok, next} = OpsBrainWeb.LoginLimiter.admit(s, {10, 0, 0, n}, 120)
        next
      end)

    assert {:limited, _} = OpsBrainWeb.LoginLimiter.admit(state, {2, 2, 2, 2}, 120)
    assert map_size(state.peers) == 200
  end

  test "malformed metric freshness and unaligned ratios never evaluate healthy", f do
    body = Jason.encode!(%{status: "success", data: %{resultType: "vector", result: [1]}})
    assert {:error, _} = Metrics.decode(body, DateTime.utc_now(), 120)
    assert {:error, _} = Metrics.decode(body, DateTime.utc_now(), "120")

    c =
      config(f, :a, %{
        kind: "prometheus",
        profile: %{
          id: "freshness",
          version: 1,
          reviewed: true,
          semantics: "gauge",
          unit: "count",
          query: "synthetic"
        }
      })

    for invalid <- ["120", nil, false, 0, -1, 3601, 120.0] do
      refute OpsBrain.SourceConfig.validate(put_in(c, [:profile, :freshness_seconds], invalid)) ==
               :ok
    end

    for valid <- [1, 120, 3600] do
      assert OpsBrain.SourceConfig.validate(put_in(c, [:profile, :freshness_seconds], valid)) ==
               :ok
    end

    refute Metrics.aligned?([%{"series" => "a", "timestamp" => 880}], [
             %{"series" => "a", "timestamp" => 1000}
           ])

    malformed = %{
      "metadata" => %{"uid" => "x", "namespace" => "test", "resourceVersion" => "rv"},
      "status" => %{"containerStatuses" => [%{"lastState" => false}]}
    }

    assert {:error, _} = Workloads.sanitize(malformed, "pods", "test")
  end

  test "malformed HTTP telemetry records errors and releases leases", f do
    now = DateTime.utc_now()
    Application.put_env(:ops_brain, :clock, fn -> now end)

    for kind <- [:prometheus, :kubernetes] do
      {:ok, source} = Tenancy.create_source(f.scope_a, %{name: Atom.to_string(kind), kind: kind})

      extra =
        if kind == :prometheus do
          %{
            kind: "prometheus",
            profile: %{
              id: "malformed",
              version: 1,
              reviewed: true,
              semantics: "gauge",
              unit: "count",
              query: "synthetic"
            }
          }
        else
          %{kind: "kubernetes", namespace: "test", resources: ["pods"]}
        end

      c = config(%{f | source_a: source}, :a, extra)

      data =
        if kind == :prometheus do
          %{status: "success", data: %{resultType: "vector", result: [1]}}
        else
          %{
            metadata: %{resourceVersion: "rv"},
            items: [
              %{
                metadata: %{uid: "p", resourceVersion: "p1", namespace: "test"},
                status: %{containerStatuses: [%{lastState: false}]}
              }
            ]
          }
        end

      Application.put_env(:ops_brain, :http_plug, fn conn ->
        Plug.Conn.send_resp(conn, 200, Jason.encode!(data))
      end)

      assert {:ok, _} = OpsBrain.TelemetryCollection.tick(c.id, now)

      assert {:ok,
              %{
                "lease_until" => nil,
                "last_success_at" => nil,
                "coverage" => "partial",
                "error" => error
              }} =
               OpsBrain.SourceConfig.transaction(c.id, fn _ ->
                 OpsBrain.Store.one(
                   "SELECT lease_until,last_success_at,coverage,error FROM collection_states WHERE source_id=$1::text::uuid",
                   [c.id]
                 )
               end)

      assert is_binary(error)

      if kind == :kubernetes do
        assert {:ok, %{"data" => %{"resource_version" => nil, "phase" => "list"}}} =
                 OpsBrain.SourceConfig.transaction(c.id, fn _ ->
                   OpsBrain.Store.one(
                     "SELECT data FROM kubernetes_cursors WHERE source_id=$1::text::uuid",
                     [c.id]
                   )
                 end)
      end
    end
  end

  test "malformed resource status cannot crash parsing or retain specs" do
    object = %{
      "metadata" => %{"uid" => "pod", "resourceVersion" => "rv", "namespace" => "test"},
      "status" => "malformed"
    }

    assert {:error, _} = Workloads.sanitize(object, "pods", "test")

    assert {:error, _} =
             Workloads.sanitize(
               %{object | "status" => %{"containerStatuses" => "not-list"}},
               "pods",
               "test"
             )

    assert {:error, _} =
             Workloads.sanitize(
               %{object | "status" => %{"containerStatuses" => [%{"lastState" => "bad"}]}},
               "pods",
               "test"
             )

    assert {:error, _} =
             Workloads.list_page(
               Workloads.empty("pods", "test"),
               %{"metadata" => [], "items" => []},
               10
             )
  end
end
