defmodule OpsBrain.CollectionTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{Collection, SourceConfig, Store, AzureBuild, Transport, Budgets}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    Map.merge(f, %{c: config(f), now: ~U[2025-01-02 01:00:00Z]})
  end

  defp in_source(c, fun) do
    assert {:ok, value} = SourceConfig.transaction(c.id, fun)
    value
  end

  test "two durable pages preserve checkpoint, idempotency, categories and tenant isolation", f do
    {:ok, {:claimed, s}} = Collection.claim(f.c.id, f.now)

    {:ok, rows, token} =
      AzureBuild.decode(f.c, page([run(f.c, 101), run(f.c, 102, "succeeded")], "next"))

    assert {:ok, :persisted} = Collection.persist(f.c, s, rows, token, 100, f.now, 30)
    state = in_source(f.c, fn _ -> Store.one("SELECT * FROM collection_states") end)
    assert state["completed_at"] == nil
    assert state["cursor"] == "next"
    assert {:error, :stale_lease} = Collection.persist(f.c, s, rows, token, 100, f.now, 30)
    now = DateTime.add(f.now, 31)
    {:ok, {:claimed, s2}} = Collection.claim(f.c.id, now)

    {:ok, rows2, nil} =
      AzureBuild.decode(
        f.c,
        page([run(f.c, 103, "canceled"), run(f.c, 104, "partiallySucceeded")])
      )

    assert {:ok, :persisted} = Collection.persist(f.c, s2, rows2, nil, 100, now, 30)
    assert {:ok, summary} = Collection.summary(f.scope_a, f.c.id)
    assert summary.coverage["completed_at"] == s["window_end"]
    assert Enum.sort(Enum.map(summary.counts, & &1["count"])) == [1, 1, 1, 1]
    assert {:ok, empty} = Collection.summary(f.scope_b, f.c.id)
    assert empty.counts == [] and empty.coverage == nil
    assert Repo.query!("SELECT * FROM pipeline_runs").rows == []

    assert in_source(f.c, fn _ ->
             Store.one("SELECT count(*)::integer AS n FROM run_snapshots")
           end)["n"] == 4
  end

  test "failed worker lease is fenced after takeover and resume retains progress", f do
    {:ok, {:claimed, old}} = Collection.claim(f.c.id, f.now)
    assert {:ok, :busy} = Collection.claim(f.c.id, DateTime.add(f.now, 1))
    now = DateTime.add(f.now, 46)
    {:ok, {:claimed, new}} = Collection.claim(f.c.id, now)
    assert new["fence"] > old["fence"]
    assert {:error, :stale_lease} = Collection.persist(f.c, old, [], nil, 0, now, 30)
    assert {:ok, :persisted} = Collection.persist(f.c, new, [], nil, 0, now, 30)
  end

  test "mutable run results append snapshots without inflating distinct runs", f do
    for {result, offset} <- [{"failed", 0}, {"succeeded", 31}, {"failed", 62}, {"failed", 93}] do
      {:ok, {:claimed, s}} = Collection.claim(f.c.id, DateTime.add(f.now, offset))
      {:ok, r} = AzureBuild.normalize(f.c, run(f.c, 101, result))

      assert {:ok, :persisted} =
               Collection.persist(f.c, s, [r], nil, 100, DateTime.add(f.now, offset), 30)
    end

    assert in_source(f.c, fn _ ->
             Store.one("SELECT count(*)::integer AS n FROM pipeline_runs")
           end)["n"] == 1

    assert in_source(f.c, fn _ ->
             Store.one("SELECT count(*)::integer AS n FROM run_snapshots")
           end)["n"] == 3
  end

  test "source binding cannot be overridden by job ID or payload", f do
    assert {:error, :source_disabled_or_invalid} =
             SourceConfig.transaction(f.source_b.id, fn _ -> :bad end)

    raw = run(f.c, 101) |> put_in(["project", "id"], Ecto.UUID.generate())
    assert {:error, _} = AzureBuild.normalize(f.c, raw)
    config(f, :b, %{company_id: f.a.id})

    assert {:error, :source_scope_mismatch} =
             SourceConfig.transaction(f.source_b.id, fn _ -> :bad end)
  end

  test "HTTP contract is GET finish-time bounded all-results no redirect and successful Retry-After",
       f do
    Application.put_env(:ops_brain, :clock, fn -> f.now end)
    parent = self()

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      send(
        parent,
        {:request, conn.method, conn.request_path, conn.query_params, Repo.in_transaction?()}
      )

      conn
      |> Plug.Conn.put_resp_header("retry-after", "90")
      |> Plug.Conn.put_resp_header("x-ms-continuationtoken", "p2")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{value: [run(f.c, 101)]}))
    end)

    assert {:ok, :persisted} = Collection.tick(f.c.id, f.now)
    assert_receive {:request, "GET", _, params, false}
    assert params["queryOrder"] == "finishTimeAscending"
    assert params["statusFilter"] == "completed"
    refute Map.has_key?(params, "resultFilter")
    assert {:snooze, 30} = Collection.tick(f.c.id, DateTime.add(f.now, 31))
    refute_receive {:request, _, _, _, _}
    state = in_source(f.c, fn _ -> Store.one("SELECT * FROM collection_states") end)
    assert state["cursor"] == "p2" and state["completed_at"] == nil
    assert DateTime.diff(state["next_at"], f.now) == 90

    assert Transport.retry_seconds(%{"retry-after" => ["Thu, 02 Jan 2025 01:01:00 GMT"]}, f.now) ==
             60
  end

  test "bounded source budgets are isolated and released; transport does not forward redirects",
       f do
    Application.put_env(:ops_brain, :clock, fn -> f.now end)
    b = config(f, :b)
    assert {:ok, {:reserved, reservation}} = Budgets.reserve(f.c.id, f.now)
    assert {:error, :source_budget_exhausted} = Budgets.reserve(f.c.id, f.now)
    assert {:ok, {:reserved, _}} = Budgets.reserve(b.id, f.now)
    Budgets.finish(f.c.id, reservation, {:ok, %{status: 200, bytes: 5, headers: %{}}}, f.now)
    parent = self()

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      send(parent, :once)

      conn
      |> Plug.Conn.put_resp_header("location", "https://evil.invalid")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:ok, %{status: 302}} =
             Transport.get(f.c, "/#{f.c.organization}/#{f.c.project_id}/_apis/build/builds", [])

    assert_receive :once
    refute_receive :once
  end

  test "oversized response and invalid endpoint fail closed", f do
    Application.put_env(:ops_brain, :http_plug, fn conn ->
      Plug.Conn.send_resp(conn, 200, String.duplicate("x", 200_001))
    end)

    assert {:error, :response_too_large} =
             Transport.get(f.c, "/#{f.c.organization}/#{f.c.project_id}/_apis/build/builds", [])

    assert {:error, _} = SourceConfig.validate(%{f.c | endpoint: "http://169.254.169.254"})
  end
end
