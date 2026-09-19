defmodule OpsBrain.WorkloadsTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{Workloads, TelemetryCollection, SourceConfig, Store, Services, Issues}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    Map.put(f, :now, DateTime.from_unix!(div(DateTime.to_unix(DateTime.utc_now()), 60) * 60))
  end

  defp object(kind, uid, rv, owners \\ []) do
    %{
      "kind" => kind,
      "metadata" => %{
        "uid" => uid,
        "name" => "same-name",
        "namespace" => "test",
        "resourceVersion" => rv,
        "ownerReferences" => owners,
        "generation" => 1
      },
      "spec" => %{"secret" => "FAKE_CANARY"},
      "status" => %{}
    }
  end

  defp pod(rv, n, reason \\ nil, finished \\ nil) do
    object("Pod", "pod", rv, [%{"kind" => "ReplicaSet", "uid" => "rs"}])
    |> Map.put("status", %{
      "containerStatuses" => [
        %{
          "name" => "app",
          "restartCount" => n,
          "ready" => true,
          "lastState" => %{"terminated" => %{"reason" => reason, "finishedAt" => finished}}
        }
      ]
    })
  end

  defp list(items, rv \\ "opaque:rv", token \\ ""),
    do: %{"metadata" => %{"resourceVersion" => rv, "continue" => token}, "items" => items}

  test "bounded pages resume without initial events and preserve UID chain, not names" do
    {:ok, s} =
      Workloads.list_page(Workloads.empty("pods", "test"), list([pod("p1", 4)], "rv", "next"), 2)

    assert s["coverage"] == "partial" and s["changes"] == []
    {:ok, s} = Workloads.list_page(s, list([], "rv"), 2)

    {:ok, rs} =
      Workloads.list_page(
        Workloads.empty("replicasets", "test"),
        list([object("ReplicaSet", "rs", "r1", [%{"kind" => "Deployment", "uid" => "dep"}])]),
        2
      )

    {:ok, dep} =
      Workloads.list_page(
        Workloads.empty("deployments", "test"),
        list([object("Deployment", "dep", "d1")]),
        2
      )

    states =
      Map.new(%{"pods" => s, "replicasets" => rs, "deployments" => dep}, fn {k, v} ->
        {k, Map.put(v, "observed_at", 100)}
      end)

    summary = Workloads.summary(states, Map.keys(states), 100, 60)
    assert summary["owner_chains"]["pod"] == %{"uids" => ["pod", "rs", "dep"], "complete" => true}
    refute Jason.encode!(states) =~ "FAKE_CANARY"

    replacement =
      put_in(states, ["deployments", "objects"], %{
        "other-uid" => object("Deployment", "other-uid", "d2")
      })

    refute Workloads.summary(replacement, Map.keys(states), 100, 60)["owner_chains"]["pod"][
             "complete"
           ]

    assert {:error, _} =
             Workloads.list_page(s, list([object("Pod", "new", "p2")], "changed-rv"), 2)

    assert {:error, :inventory_cap} =
             Workloads.list_page(
               Workloads.empty("pods", "test"),
               list([pod("p1", 0), object("Pod", "new", "p2")]),
               1
             )
  end

  test "only new OOM restart and Event count increments produce observations" do
    {:ok, s} = Workloads.list_page(Workloads.empty("pods", "test"), list([pod("p1", 1)]), 5)

    update = fn s, p ->
      Workloads.watch(s, Jason.encode!(%{"type" => "MODIFIED", "object" => p}), 5)
    end

    {:ok, s2} = update.(s, pod("p2", 2, "OOMKilled", "2025-01-01T00:00:00Z"))
    assert [%{"oom" => true, "restart_delta" => 1}] = s2["changes"]
    {:ok, s3} = update.(s2, pod("p3", 2, "OOMKilled", "2025-01-01T00:00:00Z"))
    assert s3["changes"] == []
    {:ok, s4} = update.(s3, pod("p4", 3, "OOMKilled", "2025-01-01T00:00:00Z"))
    assert [%{"oom" => false}] = s4["changes"]

    event =
      Map.merge(object("Event", "e", "e1"), %{
        "type" => "Warning",
        "count" => 3,
        "reason" => "BackOff",
        "involvedObject" => %{"uid" => "pod"}
      })

    {:ok, e} = Workloads.list_page(Workloads.empty("events", "test"), list([event]), 5)

    {:ok, e2} =
      Workloads.watch(
        e,
        Jason.encode!(%{
          type: "MODIFIED",
          object: event |> Map.put("count", 5) |> put_in(["metadata", "resourceVersion"], "e2")
        }),
        5
      )

    assert [%{"count_delta" => 2}] = e2["changes"]

    assert {:error, :expired} =
             Workloads.watch(e2, Jason.encode!(%{type: "ERROR", object: %{code: 410}}), 5)
  end

  test "disconnect reconnects from retained RV; scope changes relist; oversized changes do not checkpoint",
       f do
    {:ok, source} = Tenancy.create_source(f.scope_a, %{name: "watch", kind: :kubernetes})

    c =
      config(%{f | source_a: source}, :a, %{
        kind: "kubernetes",
        namespace: "test",
        resources: ["pods"]
      })

    parent = self()

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, {conn.request_path, conn.query_params})
      Plug.Conn.send_resp(conn, 200, Jason.encode!(list([pod("p1", 0)])))
    end)

    Application.put_env(:ops_brain, :clock, fn -> f.now end)
    assert {:ok, _} = TelemetryCollection.tick(c.id, f.now)
    Application.put_env(:ops_brain, :http_plug, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
    t1 = DateTime.add(f.now, 31)
    Application.put_env(:ops_brain, :clock, fn -> t1 end)
    assert {:ok, _} = TelemetryCollection.tick(c.id, t1)

    assert {:ok, %{"error" => "workload_unavailable", "last_success_at" => success}} =
             SourceConfig.transaction(c.id, fn _ ->
               Store.one("SELECT error,last_success_at FROM collection_states")
             end)

    assert DateTime.compare(success, f.now) == :eq

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, {conn.request_path, conn.query_params})
      # More than the per-tick transition budget, not more than the transport cap.
      events =
        Enum.map(1..101, fn i ->
          Jason.encode!(%{type: "MODIFIED", object: pod("p#{i + 1}", i)})
        end)

      Plug.Conn.send_resp(conn, 200, Enum.join(events, "\n"))
    end)

    t2 = DateTime.add(f.now, 62)
    Application.put_env(:ops_brain, :clock, fn -> t2 end)
    assert {:ok, _} = TelemetryCollection.tick(c.id, t2)

    assert_receive {"/api/v1/namespaces/test/pods",
                    %{"watch" => "true", "resourceVersion" => "opaque:rv"}}

    assert {:ok, %{"data" => %{"resource_version" => "opaque:rv"}}} =
             SourceConfig.transaction(c.id, fn _ ->
               Store.one("SELECT data FROM kubernetes_cursors")
             end)

    assert {:ok, %{"error" => "workload_transition_budget_exceeded", "coverage" => "partial"}} =
             SourceConfig.transaction(c.id, fn _ ->
               Store.one("SELECT error,coverage FROM collection_states")
             end)

    changed = %{c | namespace: "new-namespace"}
    Application.put_env(:ops_brain, :sources, %{c.id => changed})

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, {conn.request_path, conn.query_params})
      Plug.Conn.send_resp(conn, 200, Jason.encode!(list([], "new-rv")))
    end)

    t3 = DateTime.add(f.now, 93)
    Application.put_env(:ops_brain, :clock, fn -> t3 end)
    assert {:ok, _} = TelemetryCollection.tick(c.id, t3)
    assert_receive {"/api/v1/namespaces/new-namespace/pods", %{"limit" => "100"}}

    assert {:ok,
            %{"data" => %{"namespace" => "new-namespace", "objects" => empty, "gap" => true}}} =
             SourceConfig.transaction(c.id, fn _ ->
               Store.one("SELECT data FROM kubernetes_cursors")
             end)

    assert empty == %{}
  end

  test "cursor writes roll back with observations and deleted final increments are retained", f do
    {:ok, source} = Tenancy.create_source(f.scope_a, %{name: "atomic", kind: :kubernetes})

    c =
      config(%{f | source_a: source}, :a, %{
        kind: "kubernetes",
        namespace: "test",
        resources: ["pods"]
      })

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      Plug.Conn.send_resp(conn, 200, Jason.encode!(list([pod("p1", 0)])))
    end)

    {:ok, pending} = OpsBrain.WorkloadCollection.reconcile(c, f.now, nil)

    assert {:error, :simulated_crash} =
             SourceConfig.transaction(c.id, fn cfg ->
               OpsBrain.WorkloadCollection.persist(cfg, pending, f.now, nil)
               Repo.rollback(:simulated_crash)
             end)

    assert {:ok, []} =
             SourceConfig.transaction(c.id, fn _ ->
               Store.rows("SELECT * FROM kubernetes_cursors")
             end)

    {:ok, s} = Workloads.list_page(Workloads.empty("pods", "test"), list([pod("p1", 0)]), 10)

    {:ok, deleted} =
      Workloads.watch(s, Jason.encode!(%{type: "DELETED", object: pod("p2", 1)}), 10)

    assert [%{"restart_delta" => 1}] = deleted["changes"]
    assert deleted["objects"] == %{}

    event =
      Map.merge(object("Event", "e", "e1"), %{
        "count" => 3,
        "type" => "Warning",
        "reason" => "BackOff"
      })

    {:ok, s} = Workloads.list_page(Workloads.empty("events", "test"), list([event]), 10)
    final = event |> Map.put("count", 5) |> put_in(["metadata", "resourceVersion"], "e2")
    body = Jason.encode!(%{type: "DELETED", object: final})
    {:ok, deleted} = Workloads.watch(s, body, 10)
    assert [%{"count_delta" => 2}] = deleted["changes"]
    assert deleted["objects"] == %{}
    {:ok, unknown} = Workloads.watch(deleted, body, 10)
    assert unknown["changes"] == []
  end

  test "byte-only summary overflow cannot advance cursor or discard transition evidence", f do
    {:ok, source} = Tenancy.create_source(f.scope_a, %{name: "byte-budget", kind: :kubernetes})
    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    {:ok, service} =
      Services.create(f.scope_a, %{
        source_id: source.id,
        environment_id: env.id,
        service_key: "budget",
        target: "test/shared"
      })

    c =
      config(%{f | source_a: source}, :a, %{
        kind: "kubernetes",
        namespace: "test",
        resources: ["pods"],
        service_id: service["id"]
      })

    Application.put_env(:ops_brain, :clock, fn -> f.now end)

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      Plug.Conn.send_resp(conn, 200, Jason.encode!(list([pod("p1", 0)])))
    end)

    assert {:ok, _} = TelemetryCollection.tick(c.id, f.now)

    snapshot = fn ->
      SourceConfig.transaction(c.id, fn _ ->
        {Store.one("SELECT revision,data FROM kubernetes_cursors"),
         Store.rows("SELECT id,revision,data FROM observation_windows ORDER BY id"),
         Store.rows("SELECT id,data FROM evidence_items ORDER BY id"),
         Store.rows("SELECT id FROM failure_occurrences ORDER BY id")}
      end)
    end

    assert {:ok, before} = snapshot.()

    events =
      Enum.map(1..90, fn n ->
        %{type: "MODIFIED", object: pod(String.duplicate("r", 500) <> Integer.to_string(n), n)}
      end)

    body = Enum.map_join(events, "\n", &Jason.encode!/1)
    assert byte_size(body) < c.max_bytes
    {:ok, state} = Workloads.list_page(Workloads.empty("pods", "test"), list([pod("p1", 0)]), 200)
    {:ok, watched} = Workloads.watch(state, body, 200)

    summary =
      Workloads.summary(
        %{"pods" => Map.put(watched, "observed_at", DateTime.to_unix(f.now))},
        ["pods"],
        DateTime.to_unix(f.now),
        90
      )

    assert length(summary["changes"]) == 90
    assert byte_size(Jason.encode!(summary)) > 60_000

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["resourceVersion"] == "opaque:rv"
      Plug.Conn.send_resp(conn, 200, body)
    end)

    rejected_at = DateTime.add(f.now, 31)
    Application.put_env(:ops_brain, :clock, fn -> rejected_at end)
    assert {:ok, _} = TelemetryCollection.tick(c.id, rejected_at)
    assert {:ok, ^before} = snapshot.()

    assert {:ok,
            %{
              "error" => "workload_transition_budget_exceeded",
              "coverage" => "partial",
              "lease_until" => nil
            }} =
             SourceConfig.transaction(c.id, fn _ ->
               Store.one("SELECT error,coverage,lease_until FROM collection_states")
             end)

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["resourceVersion"] == "opaque:rv"
      Plug.Conn.send_resp(conn, 200, Jason.encode!(hd(events)))
    end)

    recovered_at = DateTime.add(f.now, 62)
    Application.put_env(:ops_brain, :clock, fn -> recovered_at end)
    assert {:ok, _} = TelemetryCollection.tick(c.id, recovered_at)
    assert {:ok, [%{"occurrences" => 1}]} = Issues.list(f.scope_a)

    assert {:ok, %{"error" => nil, "last_success_at" => success}} =
             SourceConfig.transaction(c.id, fn _ ->
               Store.one("SELECT error,last_success_at FROM collection_states")
             end)

    assert DateTime.compare(success, recovered_at) == :eq
  end

  test "endpoint rotation relists and cannot refresh old-cluster inventory", f do
    {:ok, source} =
      Tenancy.create_source(f.scope_a, %{name: "cluster-rotation", kind: :kubernetes})

    c =
      config(%{f | source_a: source}, :a, %{
        kind: "kubernetes",
        namespace: "test",
        resources: ["pods"]
      })

    Application.put_env(:ops_brain, :clock, fn -> f.now end)

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      Plug.Conn.send_resp(conn, 200, Jason.encode!(list([pod("p1", 0)])))
    end)

    assert {:ok, _} = TelemetryCollection.tick(c.id, f.now)

    assert {:ok, %{"data" => old}} =
             SourceConfig.transaction(c.id, fn _ ->
               Store.one("SELECT data FROM kubernetes_cursors")
             end)

    changed = %{
      c
      | endpoint: "https://other-cluster.invalid",
        approved_origins: ["https://other-cluster.invalid"]
    }

    Application.put_env(:ops_brain, :sources, %{c.id => changed})

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.host == "192.0.2.1"
      assert Plug.Conn.get_req_header(conn, "host") == ["other-cluster.invalid"]
      assert conn.query_params == %{"limit" => "100"}
      Plug.Conn.send_resp(conn, 200, Jason.encode!(list([], "other-rv")))
    end)

    now = DateTime.add(f.now, 31)
    Application.put_env(:ops_brain, :clock, fn -> now end)
    assert {:ok, _} = TelemetryCollection.tick(c.id, now)

    assert {:ok, %{"data" => current}} =
             SourceConfig.transaction(c.id, fn _ ->
               Store.one("SELECT data FROM kubernetes_cursors")
             end)

    refute current["scope"] == old["scope"]
    assert current["objects"] == %{}
    assert current["resource_version"] == "other-rv"
    assert current["initial_snapshot"] == true
    assert current["gap"] == true
    assert current["changes"] == []
  end

  test "multi-resource collection paginates durably and denies wrong-company cursors", f do
    {:ok, source} = Tenancy.create_source(f.scope_a, %{name: "workload", kind: :kubernetes})
    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    {:ok, svc} =
      Services.create(f.scope_a, %{
        source_id: source.id,
        environment_id: env.id,
        service_key: "api",
        target: "test/api"
      })

    c =
      config(%{f | source_a: source}, :a, %{
        kind: "kubernetes",
        namespace: "test",
        resources: ["pods", "deployments", "replicasets", "events"],
        service_id: svc["id"],
        page_size: 1
      })

    parent = self()

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      resource = List.last(String.split(conn.request_path, "/"))
      send(parent, {resource, conn.query_params})

      data =
        cond do
          conn.query_params["watch"] == "true" ->
            Jason.encode!(%{
              type: "MODIFIED",
              object: pod("p2", 1, "OOMKilled", "2025-01-01T00:00:00Z")
            })

          resource == "pods" and conn.query_params["continue"] == nil ->
            Jason.encode!(list([pod("p1", 0)], "rv", "next"))

          true ->
            Jason.encode!(list([], "rv"))
        end

      Plug.Conn.send_resp(conn, 200, data)
    end)

    for i <- 0..8 do
      now = DateTime.add(f.now, 31 * i)
      Application.put_env(:ops_brain, :clock, fn -> now end)
      assert {:ok, _} = TelemetryCollection.tick(c.id, now)
    end

    assert_receive {"pods", %{"continue" => "next"}}
    assert_receive {"pods", %{"watch" => "true", "resourceVersion" => "rv"}}
    assert {:ok, [%{"severity" => "critical"}]} = Issues.list(f.scope_a)

    assert {:ok, []} =
             Tenancy.with_scope(f.scope_b, fn ->
               Store.rows("SELECT * FROM kubernetes_cursors")
             end)

    assert {:ok, %{"n" => 4}} =
             SourceConfig.transaction(c.id, fn _ ->
               Store.one("SELECT count(*)::integer AS n FROM kubernetes_cursors")
             end)
  end
end
