defmodule OpsBrain.OperationsTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures

  alias OpsBrain.{
    SourceConfig,
    Store,
    Evidence,
    Issues,
    Services,
    TelemetryCollection,
    Notifications,
    Replay,
    Collection,
    EvidenceWorker
  }

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    now = DateTime.utc_now()
    Map.merge(f, %{c: config(f), now: now})
  end

  defp failure(c, key, run, now) do
    SourceConfig.transaction(c.id, fn trusted ->
      Evidence.failure(
        trusted,
        key,
        %{
          "issues" => ["HTTP 401 api.example.test token=[REDACTED]"],
          "tool" => "compiler",
          "attempt" => 1,
          "occurred_at" => Store.iso(now)
        },
        run,
        now
      )
    end)
  end

  test "exact episode groups distinct run counts, retries, evidence and local review", f do
    assert {:ok, _} = failure(f.c, "run1:task1:1", 1, f.now)
    assert {:ok, _} = failure(f.c, "run1:task1:1", 1, f.now)
    assert {:ok, _} = failure(f.c, "run1:task2:1", 1, f.now)
    assert {:ok, _} = failure(f.c, "run2:task1:1", 2, f.now)
    assert {:ok, [group]} = Issues.list(f.scope_a)
    assert group["occurrences"] == 3 and group["distinct_runs"] == 2
    assert {:ok, [_, _, _]} = Issues.evidence(f.scope_a, group["id"])
    assert {:ok, []} = Issues.evidence(f.scope_b, group["id"])
    assert {:ok, nil} = Issues.review(f.scope_b, group["id"], "locally_acknowledged")

    assert {:ok, %{"status" => "locally_acknowledged"}} =
             Issues.review(f.scope_a, group["id"], "locally_acknowledged")

    assert {:ok, _} = failure(f.c, "run3:task1:1", 3, DateTime.add(f.now, 30))
    assert {:ok, [%{"status" => "locally_acknowledged"}]} = Issues.list(f.scope_a)
    assert {:ok, _} = failure(f.c, "next-episode", 4, DateTime.add(f.now, 7200))
    assert {:ok, [_, _]} = Issues.list(f.scope_a)
    assert {:ok, []} = Issues.list(f.scope_b)
  end

  test "timeline worker stores structured sanitized evidence without fetching unnecessary logs",
       f do
    {:ok, {:claimed, s}} = Collection.claim(f.c.id, f.now)
    {:ok, r} = OpsBrain.AzureBuild.normalize(f.c, run(f.c, 101))
    Collection.persist(f.c, s, [r], nil, 100, f.now, 30)
    parent = self()

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      send(parent, conn.request_path)

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          records: [
            %{id: "job", result: "failed"},
            %{
              id: "step",
              parentId: "job",
              result: "failed",
              attempt: 2,
              issues: [%{message: "HTTP 403 token=FAKE_CANARY"}]
            }
          ]
        })
      )
    end)

    assert :ok =
             EvidenceWorker.perform(%Oban.Job{args: %{"source_id" => f.c.id, "run_id" => 101}})

    assert_receive path
    assert String.ends_with?(path, "/101/timeline")
    refute_receive _
    assert {:ok, [g]} = Issues.list(f.scope_a)
    assert g["distinct_runs"] == 1
    assert {:ok, items} = Issues.evidence(f.scope_a, g["id"])
    refute Jason.encode!(items) =~ "FAKE_CANARY"
  end

  test "service identities reject cross-company environment references", f do
    env_b = Enum.find(f.envs, &(&1.company_id == f.b.id))

    assert {:error, :invalid_relationship} =
             Services.create(f.scope_a, %{
               source_id: f.source_a.id,
               environment_id: env_b.id,
               service_key: "checkout",
               target: "ns/api"
             })

    assert {:ok, []} = Services.overview(f.scope_b)
  end

  defp telemetry_source(f, kind, profile) do
    {:ok, source} =
      Tenancy.create_source(f.scope_a, %{name: kind, kind: String.to_existing_atom(kind)})

    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    {:ok, service} =
      Services.create(f.scope_a, %{
        source_id: source.id,
        environment_id: env.id,
        service_key: "checkout",
        target: "namespace/api"
      })

    c =
      config(%{f | source_a: source}, :a, %{
        kind: kind,
        service_id: service["id"],
        profile: profile
      })

    c
  end

  test "late log window revisions do not inflate sampled signatures or authoritative totals", f do
    c =
      telemetry_source(f, "loki", %{
        id: "errors",
        version: 1,
        reviewed: true,
        selector: "{app=\"synthetic\"}"
      })

    start = DateTime.add(f.now, -60)

    data = %{
      "count" => 4000,
      "samples" => List.duplicate(%{"message" => "HTTP 401"}, 200),
      "condition" => "watch",
      "coverage" => "complete"
    }

    for d <- [data, data, %{data | "count" => 4100}] do
      assert {:ok, _} =
               SourceConfig.transaction(c.id, fn trusted ->
                 TelemetryCollection.persist(trusted, start, f.now, d, f.now)
               end)
    end

    assert {:ok, [window]} = Services.windows(f.scope_a)
    assert window["revision"] == 2 and window["data"]["count"] == 4100
    assert {:ok, [group]} = Issues.list(f.scope_a)
    assert group["occurrences"] == 1
    assert group["data"]["count_basis"] =~ "NOT log entry total"
    assert {:ok, [sample]} = Issues.evidence(f.scope_a, group["id"])
    assert sample["data"]["sample_count"] == 200
    assert {:ok, []} = Services.windows(f.scope_b)
  end

  test "Prometheus worker reaches real adapter boundary and stores scoped window", f do
    now = DateTime.from_unix!(div(DateTime.to_unix(f.now), 60) * 60)
    Application.put_env(:ops_brain, :clock, fn -> now end)

    c =
      telemetry_source(f, "prometheus", %{
        id: "usage",
        version: 1,
        reviewed: true,
        query: "synthetic_usage_bytes",
        unit: "bytes",
        semantics: "gauge",
        threshold: 900
      })

    parent = self()

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, {conn.method, conn.request_path, conn.query_params})

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          status: "success",
          data: %{
            resultType: "vector",
            result: [%{metric: %{device: "synthetic"}, value: [DateTime.to_unix(now), "950"]}]
          }
        })
      )
    end)

    assert {:ok, _} = TelemetryCollection.tick(c.id, now)
    assert_receive {"GET", "/api/v1/query", %{"query" => "synthetic_usage_bytes"}}
    assert {:ok, [w]} = Services.windows(f.scope_a)
    assert w["data"]["condition"] == "warning"
    # one window is not sustained
    assert {:ok, []} = Issues.list(f.scope_a)
    assert {:snooze, 30} = TelemetryCollection.tick(c.id, now)
  end

  test "outbox deduplication destination isolation disabled delivery and quiet-hour policy", f do
    sink = %{
      approved: true,
      enabled: true,
      company_id: f.a.id,
      url: "https://sink.invalid/notice",
      approved_urls: ["https://sink.invalid/notice"],
      approved_ip: "192.0.2.2",
      credential_env: "OPS_BRAIN_TEST_DELIVERY",
      digest_seconds: 0
    }

    Application.put_env(:ops_brain, :notification_sinks, %{
      "a" => sink,
      "b" => %{sink | company_id: f.b.id}
    })

    failure(f.c, "one", 1, f.now)
    failure(f.c, "one", 1, f.now)

    assert {:ok, [out]} =
             Tenancy.with_scope(f.scope_a, fn ->
               Store.rows("SELECT id::text,destination,status FROM notification_outbox")
             end)

    assert out["destination"] == "a" and out["status"] == "pending"
    assert {:error, :delivery_disabled} = Notifications.deliver(f.c.id, out["id"])
    assert Repo.query!("SELECT * FROM notification_outbox").rows == []

    assert {:ok, []} =
             Tenancy.with_scope(f.scope_b, fn ->
               Store.rows("SELECT * FROM notification_outbox")
             end)

    assert Notifications.due(~U[2025-01-01 02:00:00Z], nil, %{
             quiet_utc_hours: [2, 3],
             digest_seconds: 0
           }) == ~U[2025-01-01 04:00:00Z]
  end

  test "approved sink HTTP boundary and changed recipient approval is rechecked", f do
    sink = %{
      approved: true,
      enabled: true,
      company_id: f.a.id,
      url: "https://sink.invalid/notice",
      approved_urls: ["https://sink.invalid/notice"],
      approved_ip: "192.0.2.2",
      credential_env: "OPS_BRAIN_TEST_DELIVERY",
      digest_seconds: 0
    }

    Application.put_env(:ops_brain, :notification_sinks, %{"a" => sink})
    System.put_env("OPS_BRAIN_TEST_DELIVERY", "nonfunctional-test-sentinel")
    on_exit(fn -> System.delete_env("OPS_BRAIN_TEST_DELIVERY") end)
    failure(f.c, "one", 1, f.now)

    {:ok, [out]} =
      Tenancy.with_scope(f.scope_a, fn ->
        Store.rows("SELECT id::text FROM notification_outbox")
      end)

    parent = self()

    Application.put_env(:ops_brain, :notification_plug, fn conn ->
      send(
        parent,
        {:sent, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "idempotency-key")}
      )

      Plug.Conn.send_resp(conn, 202, "")
    end)

    Application.put_env(:ops_brain, :delivery_enabled, true)
    Application.put_env(:ops_brain, :notification_sinks, %{"a" => %{sink | company_id: f.b.id}})
    assert {:error, :destination_not_approved} = Notifications.deliver(f.c.id, out["id"], f.now)
    refute_receive {:sent, _, _, _}
    Application.put_env(:ops_brain, :notification_sinks, %{"a" => sink})
    assert {:ok, _} = Notifications.deliver(f.c.id, out["id"], f.now)
    assert_receive {:sent, "POST", "/notice", [_]}
    assert {:error, :not_pending} = Notifications.deliver(f.c.id, out["id"], f.now)
    refute_receive {:sent, _, _, _}
  end

  test "replay has no HTTP/delivery effects and retention tombstones evidence without losing occurrence basis",
       f do
    failure(f.c, "one", 1, f.now)
    {:ok, [g]} = Issues.list(f.scope_a)
    Issues.review(f.scope_a, g["id"], "locally_acknowledged")
    Application.put_env(:ops_brain, :http_plug, fn _ -> raise "replay performed network" end)
    Application.put_env(:ops_brain, :notification_plug, fn _ -> raise "replay delivered" end)
    assert {:ok, [_]} = Replay.fingerprints(f.scope_a, DateTime.add(f.now, 1))
    assert {:error, :parser_version_unavailable} = Replay.fingerprints(f.scope_a, f.now, 999)
    assert {:ok, 1} = OpsBrain.Retention.expire_evidence(f.scope_a, DateTime.add(f.now, 8, :day))

    assert {:ok, [%{status: "expired: exact replay unavailable"}]} =
             Replay.fingerprints(f.scope_a, DateTime.add(f.now, 1))

    assert {:ok, [after_group]} = Issues.list(f.scope_a)
    assert after_group["status"] == "locally_acknowledged" and after_group["occurrences"] == 1
  end
end
