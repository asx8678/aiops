defmodule OpsBrain.TelemetrySourcesTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures

  alias OpsBrain.{
    SourceConfig,
    TelemetryCollection,
    Services,
    Store,
    Issues,
    Collection,
    AzureBuild,
    Evidence
  }

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    now = DateTime.from_unix!(div(DateTime.to_unix(DateTime.utc_now()), 60) * 60)
    Application.put_env(:ops_brain, :clock, fn -> now end)
    Map.merge(f, %{now: now})
  end

  defp source(f, kind, extra) do
    {:ok, s} =
      Tenancy.create_source(f.scope_a, %{name: kind, kind: String.to_existing_atom(kind)})

    config(%{f | source_a: s}, :a, Map.merge(%{kind: kind}, extra))
  end

  test "Loki adapter queries aligned closed windows and persists backend counts separately from samples",
       f do
    c =
      source(f, "loki", %{
        profile: %{
          id: "logs",
          version: 1,
          reviewed: true,
          selector: "{app=\"synthetic\"}",
          minimum_count: 10
        }
      })

    parent = self()

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, {conn.request_path, conn.query_params})

      body =
        case conn.request_path do
          "/loki/api/v1/query" ->
            %{
              status: "success",
              data: %{resultType: "vector", result: [%{value: [DateTime.to_unix(f.now), "4000"]}]}
            }

          "/loki/api/v1/query_range" ->
            %{
              status: "success",
              data: %{
                resultType: "streams",
                result: [
                  %{
                    stream: %{app: "synthetic"},
                    values: List.duplicate(["123", "HTTP 401 token=FAKE_CANARY"], 200)
                  }
                ]
              }
            }
        end

      Plug.Conn.send_resp(conn, 200, Jason.encode!(body))
    end)

    assert {:ok, _} = TelemetryCollection.tick(c.id, f.now)
    assert_receive {"/loki/api/v1/query", q}
    assert q["query"] == "sum(count_over_time({app=\"synthetic\"}[60s]))"
    assert_receive {"/loki/api/v1/query_range", sample}
    assert q["time"] == sample["end"]
    assert sample["limit"] == "200"
    assert {:ok, [w]} = Services.windows(f.scope_a)
    assert w["data"]["count"] == 4000
    assert length(w["data"]["samples"]) == 200
    refute Jason.encode!(w) =~ "FAKE_CANARY"
    assert w["data"]["sample_coverage"] == "capped_or_saturated"
  end

  test "Kubernetes uses saved opaque position; HTTP 410 relists and exposes gap", f do
    c = source(f, "kubernetes", %{namespace: "synthetic"})
    parent = self()

    pod = %{
      metadata: %{uid: "uid", name: "api", namespace: "synthetic", resourceVersion: "pod-rv"},
      status: %{containerStatuses: [%{ready: true, restartCount: 0}]}
    }

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, conn.query_params)

      if conn.query_params["watch"] == "true" do
        Plug.Conn.send_resp(conn, 410, Jason.encode!(%{code: 410}))
      else
        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!(%{metadata: %{resourceVersion: "opaque:not-a-number"}, items: [pod]})
        )
      end
    end)

    assert {:ok, _} = TelemetryCollection.tick(c.id, f.now)
    assert_receive %{"limit" => "100"}
    later = DateTime.add(f.now, 31)
    Application.put_env(:ops_brain, :clock, fn -> later end)
    assert {:ok, _} = TelemetryCollection.tick(c.id, later)
    assert_receive %{"watch" => "true", "resourceVersion" => "opaque:not-a-number"}
    # One bounded request per tick: expired watch records a gap, then relists next tick.
    refute_receive %{"limit" => _}
    relist_at = DateTime.add(later, 31)
    Application.put_env(:ops_brain, :clock, fn -> relist_at end)
    assert {:ok, _} = TelemetryCollection.tick(c.id, relist_at)
    assert_receive %{"limit" => "100"}
    assert {:ok, windows} = Services.windows(f.scope_a)
    assert Enum.any?(windows, &(&1["data"]["gap"] == true))
  end

  test "successful comparable rerun recovers delivery episode; quiet alone does not", f do
    c = config(f)
    {:ok, {:claimed, s}} = Collection.claim(c.id, f.now)
    {:ok, r} = AzureBuild.normalize(c, run(c, 101))
    Collection.persist(c, s, [r], nil, 1, f.now, 30)

    SourceConfig.transaction(c.id, fn cfg ->
      Evidence.failure(
        cfg,
        "attempt",
        %{"issues" => ["HTTP 401"], "tool" => "tool", "attempt" => 1},
        101,
        f.now
      )
    end)

    {:ok, [g]} = Issues.list(f.scope_a)
    assert {:ok, %{"status" => "quiet"}} = Issues.review(f.scope_a, g["id"], "quiet")
    assert {:ok, _} = Issues.snooze(f.scope_a, g["id"], DateTime.add(f.now, 3600), f.now)
    assert {:ok, nil} = Issues.snooze(f.scope_b, g["id"], DateTime.add(f.now, 3600), f.now)
    now = DateTime.add(f.now, 31)
    {:ok, {:claimed, s2}} = Collection.claim(c.id, now)
    {:ok, success} = AzureBuild.normalize(c, run(c, 101, "succeeded"))
    assert {:ok, _} = Collection.persist(c, s2, [success], nil, 1, now, 30)
    assert {:ok, [recovered]} = Issues.list(f.scope_a)
    assert recovered["status"] == "recovered"
    assert is_binary(recovered["data"]["recovery_evidence_id"])
  end

  test "oversized retained telemetry becomes partial unknown rather than falsely complete", f do
    c =
      source(f, "prometheus", %{
        profile: %{
          id: "metric",
          version: 1,
          reviewed: true,
          semantics: "gauge",
          unit: "bytes",
          query: "synthetic"
        }
      })

    assert {:ok, %{"coverage" => "partial"}} =
             SourceConfig.transaction(c.id, fn cfg ->
               TelemetryCollection.persist(
                 cfg,
                 DateTime.add(f.now, -60),
                 f.now,
                 %{
                   "coverage" => "complete",
                   "condition" => "normal",
                   "padding" => String.duplicate("x", 61_000)
                 },
                 f.now
               )
             end)

    assert {:ok, [w]} = Services.windows(f.scope_a)
    assert w["data"]["condition"] == "unknown"
    assert byte_size(Jason.encode!(w["data"])) < 1000

    assert {:ok, %{"n" => 0}} =
             SourceConfig.transaction(c.id, fn _ ->
               Store.one("SELECT count(*)::integer AS n FROM issue_groups")
             end)
  end
end
