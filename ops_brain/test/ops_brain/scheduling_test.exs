defmodule OpsBrain.SchedulingTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{Collection, SourceConfig, Store, TelemetryCollection, Tenancy, Repo}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    Map.merge(f, %{now: ~U[2025-01-02 01:00:00Z]})
  end

  defp in_source(c, fun) do
    {:ok, value} = SourceConfig.transaction(c.id, fun)
    value
  end

  defp state(c), do: in_source(c, fn _ -> Store.one("SELECT * FROM collection_states") end)

  test "azure current discovery is not blocked by the reconciliation backlog", f do
    c = config(f)

    in_source(c, fn t ->
      Repo.query!(
        "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,received_at,revision,data)
         SELECT gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,g,7,'completed','failed',$4,1,'{}'::jsonb FROM generate_series(1,100) g",
        [t.company_id, t.id, t.project_id, f.now]
      )
    end)

    {:ok, {:claimed, s0}} = Collection.claim(c.id, f.now)
    assert {:ok, :persisted} = Collection.persist(c, s0, [], nil, 0, f.now, 30)

    t1 = DateTime.add(f.now, 31)
    {:ok, {:claimed, s1}} = Collection.claim(c.id, t1)
    assert {:ok, :persisted} = Collection.persist(c, s1, [], nil, 0, t1, 30)
    st = state(c)
    assert st["mode"] == "reconcile"
    assert length(st["reconcile_ids"]) == 100

    t2 = DateTime.add(t1, 31)
    {:ok, {:claimed, s2}} = Collection.claim(c.id, t2)
    assert {:ok, :persisted} = Collection.persist(c, s2, [], nil, 0, t2, 30)
    st2 = state(c)
    assert st2["mode"] == "completed"
    assert length(st2["reconcile_ids"]) == 99

    t3 = DateTime.add(t2, 31)
    {:ok, {:claimed, s3}} = Collection.claim(c.id, t3)
    assert {:ok, :persisted} = Collection.persist(c, s3, [], nil, 0, t3, 30)
    st3 = state(c)
    assert st3["mode"] == "active"
    assert length(st3["reconcile_ids"]) == 99
  end

  test "legacy recent failure yields discovery without losing historical IDs", f do
    c = config(f)
    Application.put_env(:ops_brain, :clock, fn -> f.now end)

    in_source(c, fn t ->
      Repo.query!(
        "INSERT INTO collection_states(company_id,source_id,mode,reconcile_ids) VALUES($1::text::uuid,$2::text::uuid,'recent',ARRAY[1,2]::bigint[])",
        [t.company_id, t.id]
      )
    end)

    Application.put_env(:ops_brain, :http_plug, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
    assert {:source_failure, _} = Collection.tick(c.id, f.now)
    assert state(c)["mode"] == "completed"
    assert state(c)["reconcile_ids"] == [2, 1]
    assert state(c)["coverage"] == "partial"
    assert state(c)["completed_at"] == nil
  end

  test "100 historical IDs yield to HTTP discovery and 429 retains retry budget", f do
    c = config(f)
    Application.put_env(:ops_brain, :clock, fn -> f.now end)

    in_source(c, fn t ->
      Repo.query!(
        "INSERT INTO collection_states(company_id,source_id,mode,reconcile_ids,completed_at) VALUES($1::text::uuid,$2::text::uuid,'recent',$3,$4)",
        [t.company_id, t.id, Enum.to_list(1..100), DateTime.add(f.now, -60)]
      )
    end)

    parent = self()

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, {:http, conn.request_path, conn.query_params})

      if String.ends_with?(conn.request_path, "/1") do
        Plug.Conn.send_resp(conn, 200, Jason.encode!(run(c, 1)))
      else
        Plug.Conn.send_resp(conn, 200, Jason.encode!(%{value: [run(c, 999)]}))
      end
    end)

    assert {:ok, :persisted} = Collection.tick(c.id, f.now)
    assert_receive {:http, _, %{}}
    now = DateTime.add(f.now, 31)
    Application.put_env(:ops_brain, :clock, fn -> now end)
    assert {:ok, :persisted} = Collection.tick(c.id, now)
    assert_receive {:http, _, %{"statusFilter" => "completed"}}

    assert in_source(c, fn _ -> Store.one("SELECT run_id FROM pipeline_runs WHERE run_id=999") end)[
             "run_id"
           ] == 999

    assert length(state(c)["reconcile_ids"]) == 99
    later = DateTime.add(now, 31)
    Application.put_env(:ops_brain, :clock, fn -> later end)

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "120") |> Plug.Conn.send_resp(429, "")
    end)

    checkpoint = state(c)["completed_at"]
    assert {:source_failure, _} = Collection.tick(c.id, later)
    assert state(c)["completed_at"] == checkpoint
    assert DateTime.diff(state(c)["next_at"], later) == 120
    assert {:snooze, 30} = Collection.tick(c.id, DateTime.add(later, 31))
  end

  for lag <- [600, 3600] do
    @lag lag
    test "telemetry catch-up converges from #{@lag} seconds behind through the worker", f do
      {:ok, s} = Tenancy.create_source(f.scope_a, %{name: "prometheus", kind: :prometheus})

      c =
        config(%{f | source_a: s}, :a, %{
          kind: "prometheus",
          profile: %{
            id: "metric",
            version: 1,
            reviewed: true,
            semantics: "gauge",
            unit: "bytes",
            query: "synthetic",
            freshness_seconds: 3600
          }
        })

      Application.put_env(:ops_brain, :http_plug, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        ts = String.to_integer(conn.query_params["time"])

        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!(%{
            "status" => "success",
            "data" => %{
              "resultType" => "vector",
              "result" => [%{"metric" => %{"job" => "synthetic"}, "value" => [ts, "100"]}]
            }
          })
        )
      end)

      closed = f.now
      behind = DateTime.add(closed, -@lag)

      in_source(c, fn t ->
        Repo.query!(
          "INSERT INTO collection_states(company_id,source_id,completed_at,coverage) VALUES($1::text::uuid,$2::text::uuid,$3,'partial') ON CONFLICT (source_id) DO UPDATE SET completed_at=$3",
          [t.company_id, t.id, behind]
        )
      end)

      Application.put_env(:ops_brain, :clock, fn -> closed end)
      assert {:snooze, 5} = TelemetryCollection.tick(c.id, closed)

      row = state(c)
      assert DateTime.compare(row["completed_at"], behind) == :gt
      assert row["coverage"] == "catching_up"

      result =
        Enum.reduce_while(1..90, nil, fn i, _acc ->
          now = DateTime.add(closed, i * 5, :second)
          Application.put_env(:ops_brain, :clock, fn -> now end)

          case OpsBrain.CollectionWorker.perform(%Oban.Job{args: %{"source_id" => c.id}}) do
            result when result == :ok or result == {:snooze, 5} ->
              st = state(c)
              if st["coverage"] == "complete", do: {:halt, st}, else: {:cont, st}

            _ ->
              {:halt, nil}
          end
        end)

      assert result != nil
      assert result["coverage"] == "complete"
      assert DateTime.compare(result["completed_at"], closed) != :lt
    end
  end
end
