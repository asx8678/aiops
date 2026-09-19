defmodule OpsBrain.ReviewRegressionsTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{SourceConfig, Store, Collection, Budgets, Evidence, Notifications}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    Map.merge(f, %{c: config(f), now: DateTime.utc_now()})
  end

  test "expired request cannot release successor reservation", f do
    assert {:ok, {:reserved, first}} = Budgets.reserve(f.c.id, f.now)
    later = DateTime.add(f.now, 21)
    assert {:ok, {:reserved, second}} = Budgets.reserve(f.c.id, later)
    Budgets.finish(f.c.id, first, {:ok, %{status: 200, bytes: 1, headers: %{}}}, later)
    assert {:error, :source_budget_exhausted} = Budgets.reserve(f.c.id, later)
    Budgets.finish(f.c.id, second, {:ok, %{status: 200, bytes: 1, headers: %{}}}, later)
    assert {:ok, {:reserved, _}} = Budgets.reserve(f.c.id, later)
  end

  test "more collection pages than per-tick budget resume instead of deadlocking", f do
    c = config(f, :a, %{max_pages: 1, max_window_seconds: 60})

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      token =
        case conn.query_params["continuationToken"] do
          nil -> "2"
          "2" -> "3"
          _ -> nil
        end

      conn =
        if token, do: Plug.Conn.put_resp_header(conn, "x-ms-continuationtoken", token), else: conn

      Plug.Conn.send_resp(conn, 200, Jason.encode!(%{value: []}))
    end)

    for i <- 0..2 do
      now = DateTime.add(f.now, i * 31)
      Application.put_env(:ops_brain, :clock, fn -> now end)
      assert {:ok, :persisted} = Collection.tick(c.id, now)
    end

    assert {:ok, state} =
             SourceConfig.transaction(c.id, fn _ ->
               Store.one("SELECT * FROM collection_states")
             end)

    assert state["completed_at"] != nil and state["cursor"] == nil
    assert DateTime.diff(state["window_end"], state["window_start"]) == 60
  end

  test "new failed projection revision enqueues distinct durable enrichment", f do
    for {result, i} <- [{"failed", 0}, {"partiallySucceeded", 1}] do
      now = DateTime.add(f.now, 31 * i)
      {:ok, {:claimed, s}} = Collection.claim(f.c.id, now)
      {:ok, r} = OpsBrain.AzureBuild.normalize(f.c, run(f.c, 101, result))
      Collection.persist(f.c, s, [r], nil, 100, now, 30)
      Repo.query!("UPDATE oban_jobs SET state='completed' WHERE worker='OpsBrain.EvidenceWorker'")
    end

    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM oban_jobs WHERE worker='OpsBrain.EvidenceWorker'")

    assert count == 2
  end

  test "continuous revisions preserve earliest digest deadline with one pending delivery", f do
    sink = %{
      approved: true,
      enabled: true,
      company_id: f.a.id,
      url: "https://sink.invalid",
      credential_env: "TEST_UNUSED",
      digest_seconds: 60
    }

    Application.put_env(:ops_brain, :notification_sinks, %{"a" => sink})

    for i <- 0..10 do
      now = DateTime.add(f.now, i * 10)

      assert {:ok, _} =
               SourceConfig.transaction(f.c.id, fn c ->
                 Evidence.failure(
                   c,
                   "event-#{i}",
                   %{"issues" => ["HTTP 401"], "tool" => "tool", "attempt" => 1},
                   i,
                   now
                 )
               end)
    end

    assert {:ok, [row]} =
             SourceConfig.transaction(f.c.id, fn _ ->
               Store.rows("SELECT id::text,next_at,revision FROM notification_outbox")
             end)

    assert row["revision"] == 11
    assert DateTime.diff(row["next_at"], f.now) == 60

    assert {:error, :delivery_disabled} =
             Notifications.deliver(f.c.id, row["id"], DateTime.add(f.now, 120))
  end
end
