defmodule OpsBrain.FinalReviewTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures

  alias OpsBrain.{
    Store,
    SourceConfig,
    Services,
    TelemetryCollection,
    Issues,
    Collection,
    AzureBuild,
    EvidenceWorker,
    Evidence,
    Notifications
  }

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    now = DateTime.from_unix!(div(DateTime.to_unix(DateTime.utc_now()), 60) * 60)
    Application.put_env(:ops_brain, :clock, fn -> now end)
    Map.merge(f, %{now: now})
  end

  defp metric(f) do
    {:ok, s} = Tenancy.create_source(f.scope_a, %{name: "metric", kind: :prometheus})
    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    {:ok, service} =
      Services.create(f.scope_a, %{
        source_id: s.id,
        environment_id: env.id,
        service_key: "api",
        target: "ns/api"
      })

    config(%{f | source_a: s}, :a, %{
      kind: "prometheus",
      interval_seconds: 60,
      service_id: service["id"],
      profile: %{
        id: "metric",
        version: 1,
        reviewed: true,
        query: "synthetic_gauge",
        unit: "bytes",
        semantics: "gauge",
        threshold: 9
      }
    })
  end

  test "one-minute schedule retains every adjacent closed window", f do
    c = metric(f)

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      ts = String.to_integer(conn.query_params["time"])

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          status: "success",
          data: %{resultType: "vector", result: [%{metric: %{}, value: [ts, "10"]}]}
        })
      )
    end)

    for i <- 0..3 do
      now = DateTime.add(f.now, i * 60)
      Application.put_env(:ops_brain, :clock, fn -> now end)
      assert {:ok, _} = TelemetryCollection.tick(c.id, now)
    end

    assert {:ok, windows} = Services.windows(f.scope_a)

    assert Enum.sort(Enum.map(windows, &DateTime.diff(&1["window_end"], f.now))) == [
             0,
             60,
             120,
             180
           ]

    assert {:ok, [_]} = Issues.list(f.scope_a)
  end

  test "historical normal reconciliation cannot recover a newer incident", f do
    c = metric(f)

    for {offset, condition} <- [
          {-60, "warning"},
          {0, "warning"},
          {-180, "normal"},
          {-120, "normal"}
        ] do
      finish = DateTime.add(f.now, offset)

      assert {:ok, _} =
               SourceConfig.transaction(c.id, fn cfg ->
                 TelemetryCollection.persist(
                   cfg,
                   DateTime.add(finish, -60),
                   finish,
                   %{"condition" => condition, "coverage" => "complete"},
                   f.now
                 )
               end)
    end

    assert {:ok, [g]} = Issues.list(f.scope_a)
    assert g["status"] == "new"

    for offset <- [60, 120] do
      finish = DateTime.add(f.now, offset)

      SourceConfig.transaction(c.id, fn cfg ->
        TelemetryCollection.persist(
          cfg,
          DateTime.add(finish, -60),
          finish,
          %{"condition" => "normal", "coverage" => "complete"},
          finish
        )
      end)
    end

    assert {:ok, [%{"status" => "recovered"}]} = Issues.list(f.scope_a)
  end

  test "in-flight old timeline cannot create an incident after success projection", f do
    c = config(f)
    {:ok, {:claimed, s}} = Collection.claim(c.id, f.now)
    {:ok, r} = AzureBuild.normalize(c, run(c, 101))
    Collection.persist(c, s, [r], nil, 1, f.now, 30)

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      later = DateTime.add(f.now, 31)
      {:ok, {:claimed, next}} = Collection.claim(c.id, later)
      {:ok, success} = AzureBuild.normalize(c, run(c, 101, "succeeded"))
      {:ok, _} = Collection.persist(c, next, [success], nil, 1, later, 30)

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          records: [%{id: "old", result: "failed", attempt: 1, issues: [%{message: "HTTP 401"}]}]
        })
      )
    end)

    assert {:error, :evidence_not_persisted} =
             EvidenceWorker.perform(%Oban.Job{
               args: %{"source_id" => c.id, "run_id" => 101, "revision" => 1}
             })

    assert {:ok, []} = Issues.list(f.scope_a)
  end

  test "coalescing cannot shorten Retry-After and new revision does not inherit exhausted retry budget",
       f do
    c = config(f)

    sink = %{
      approved: true,
      enabled: true,
      company_id: f.a.id,
      url: "https://sink.invalid/notice",
      approved_urls: ["https://sink.invalid/notice"],
      approved_ip: "192.0.2.2",
      credential_env: "TEST_FINAL_SINK",
      digest_seconds: 0
    }

    System.put_env("TEST_FINAL_SINK", "synthetic")
    on_exit(fn -> System.delete_env("TEST_FINAL_SINK") end)
    Application.put_env(:ops_brain, :notification_sinks, %{"a" => sink})
    Application.put_env(:ops_brain, :delivery_enabled, true)

    Application.put_env(:ops_brain, :notification_plug, fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "120") |> Plug.Conn.send_resp(429, "")
    end)

    insert = fn key, now ->
      SourceConfig.transaction(c.id, fn cfg ->
        Evidence.failure(
          cfg,
          key,
          %{"issues" => ["HTTP 401"], "tool" => "tool", "attempt" => 1},
          1,
          now
        )
      end)
    end

    insert.("one", f.now)

    {:ok, [out]} =
      SourceConfig.transaction(c.id, fn _ ->
        Store.rows("SELECT id::text FROM notification_outbox")
      end)

    assert {:snooze, 120} = Notifications.deliver(c.id, out["id"], f.now)
    insert.("two", DateTime.add(f.now, 1))
    assert {:error, :not_due} = Notifications.deliver(c.id, out["id"], DateTime.add(f.now, 1))

    SourceConfig.transaction(c.id, fn _ ->
      Repo.query!("UPDATE notification_outbox SET attempts=3 WHERE id=$1::text::uuid", [out["id"]])
    end)

    insert.("three", DateTime.add(f.now, 2))

    assert {:ok, rows} =
             SourceConfig.transaction(c.id, fn _ ->
               Store.rows(
                 "SELECT status,attempts,next_at FROM notification_outbox ORDER BY revision"
               )
             end)

    assert [%{"status" => "retry_exhausted"}, %{"status" => "pending", "attempts" => 0} = fresh] =
             rows

    assert DateTime.diff(fresh["next_at"], f.now) == 120
  end
end
