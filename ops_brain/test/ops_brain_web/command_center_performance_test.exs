defmodule OpsBrainWeb.CommandCenterPerformanceTest do
  # Task 4.4: both pages stay under the 150 ms local page-load target on the
  # full offline demo workload (210 pods, 72 pipeline runs, 96 observation
  # windows, 464 resource snapshots, 5 findings) in the disposable test
  # database. Every timed request is CAPTURED and validated afterwards —
  # HTTP 200 with the expected page markers and the selected checkout-api
  # service identity — so a fast redirect or an empty fallback cannot pass
  # as a page load; the same validation applies to the read results (real
  # demo data must be present). Timing wraps the request/read only; the
  # assertions run afterwards. First-use statement preparation is absorbed
  # by warm-up calls to the exact same URLs and reads, so the measured cost
  # is the steady state a 30-second refresh pays. Measured locally
  # (printed on every run via PERF lines): command read ~9-10 ms, service
  # read ~11-15 ms, warm HTTP page loads ~9-14 ms.
  #
  # Index evidence for the hottest query (the pipeline_rows deployment-evidence
  # lateral): EXPLAIN ANALYZE under the demo scope executed it in ~2 ms (72
  # rows, ~1000 buffers), observed using the existing partial index
  # `deployment_run_read_index` from migration 20260920110735; the planner has
  # also been observed choosing an equivalent nested-loop plan at the same
  # cost, so the executable test below pins the measured server execution time
  # (with the exact EXPLAIN statement retained) rather than a specific plan
  # shape.
  use OpsBrainWeb.ConnCase, async: false

  setup do
    f = fixture()
    now = DateTime.utc_now()
    OpsBrain.Demo.seed!(OpsBrain.TestAdminRepo, f.alice.name, now: now)
    {:ok, scope} = OpsBrain.Tenancy.authorize(f.token_a, OpsBrain.Demo.company_id())

    command_path = "/companies/#{OpsBrain.Demo.company_id()}/command"

    troubleshoot_path =
      "/companies/#{OpsBrain.Demo.company_id()}/troubleshoot?service=checkout-api&environment=prod"

    conn = init_test_session(build_conn(), operator_token: f.token_a)

    # Warm-up: the exact reads and URLs measured below.
    {:ok, _} = OpsBrain.Insights.command(scope, "", now)
    {:ok, _} = OpsBrain.Insights.service(scope, "checkout-api", "prod", now)
    assert html_response(get(conn, command_path), 200) =~ "Needs attention now"

    assert html_response(get(conn, troubleshoot_path), 200) =~
             "nw-eu-prod/checkout/checkout-api"

    Map.merge(f, %{
      scope: scope,
      now: now,
      conn: conn,
      command_path: command_path,
      troubleshoot_path: troubleshoot_path
    })
  end

  test "both page reads and validated HTTP loads stay under the 150ms local target",
       f do
    # --- timed reads and requests only ---
    {command_us, command_result} =
      :timer.tc(fn -> OpsBrain.Insights.command(f.scope, "", f.now) end)

    {service_us, service_result} =
      :timer.tc(fn -> OpsBrain.Insights.service(f.scope, "checkout-api", "prod", f.now) end)

    {command_http_us, command_resp} = :timer.tc(fn -> get(f.conn, f.command_path) end)

    {troubleshoot_http_us, troubleshoot_resp} =
      :timer.tc(fn -> get(f.conn, f.troubleshoot_path) end)

    command_ms = Float.round(command_us / 1000, 2)
    service_ms = Float.round(service_us / 1000, 2)
    command_http_ms = Float.round(command_http_us / 1000, 2)
    troubleshoot_http_ms = Float.round(troubleshoot_http_us / 1000, 2)

    IO.puts(
      "PERF command_read=#{command_ms}ms service_read=#{service_ms}ms " <>
        "command_http=#{command_http_ms}ms troubleshoot_http=#{troubleshoot_http_ms}ms"
    )

    # --- validate the measured results afterwards ---
    assert command_ms < 150, "command center read took #{command_ms}ms"
    assert service_ms < 150, "troubleshoot read took #{service_ms}ms"
    assert command_http_ms < 150, "command center page load took #{command_http_ms}ms"

    assert troubleshoot_http_ms < 150,
           "troubleshoot page load took #{troubleshoot_http_ms}ms"

    # the reads measured real demo data, not an empty fallback
    assert {:ok, command_data} = command_result
    assert command_data.attention != []
    assert Enum.any?(command_data.storage, &(&1.volume == "reporting-postgres"))
    assert Enum.any?(command_data.pipelines, &(&1.name == "search-indexer"))

    assert {:ok, service_data} = service_result
    assert service_data.instance["service_key"] == "checkout-api"
    assert service_data.instance["environment"] == "prod"
    assert service_data.runs != []
    assert service_data.storage

    # the timed HTTP responses are real page loads, not redirects or errors
    command_html = html_response(command_resp, 200)
    assert command_html =~ "Needs attention now"
    assert command_html =~ "reporting-postgres"
    assert command_html =~ "search-indexer"
    refute command_html =~ "Nothing flagged right now"

    troubleshoot_html = html_response(troubleshoot_resp, 200)
    assert troubleshoot_html =~ "nw-eu-prod/checkout/checkout-api"
    assert troubleshoot_html =~ "checkout-api"
  end

  test "the pipeline deployment lateral executes well inside the page budget", f do
    # the EXPLAIN (ANALYZE, BUFFERS) statement whose ~2 ms / 72-row measurement
    # backs Task 4.4's performance claim, kept executable so the evidence stays
    # reproducible
    {:ok, plan} =
      OpsBrain.Tenancy.with_scope(f.scope, fn ->
        OpsBrain.Store.rows(
          """
          EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
          WITH runs AS MATERIALIZED (
            SELECT * FROM pipeline_runs
            WHERE received_at <= $1 AND (finish_at IS NULL OR finish_at <= $1)
            ORDER BY finish_at DESC NULLS LAST,id DESC LIMIT 300
          )
          SELECT r.id::text,r.source_id::text,r.run_id,r.definition_id,r.status,r.result,r.finish_at,r.received_at,
            COALESCE(dep.service, r.data->>'service', 'definition ' || r.definition_id::text) AS service,
            dep.environment AS environment,
            COALESCE(dep.environments, '[]'::jsonb) AS environments,
            r.data->>'branch' AS branch,
            r.data->>'start_at' AS start_at,
            (dep.service IS NULL AND r.data->>'service' IS NULL) AS ci_only
          FROM runs r
          LEFT JOIN LATERAL (
            SELECT s.service_key AS service,
              (array_agg(env.name ORDER BY e.received_at DESC, e.id::text DESC))[1] AS environment,
              jsonb_agg(DISTINCT env.name) AS environments,
              max(e.received_at) AS latest
            FROM evidence_items e
            JOIN service_instances s ON s.id::text=e.data->>'target_id' AND s.company_id=e.company_id
            JOIN environments env ON env.id=s.environment_id AND env.company_id=s.company_id
            WHERE e.company_id=r.company_id AND e.source_id=r.source_id AND e.kind='deployment'
              AND e.data->>'run_id'=r.run_id::text AND e.expires_at > $1
              AND e.received_at <= $1 AND e.occurred_at <= $1
            GROUP BY s.service_key
            ORDER BY latest DESC, s.service_key
            LIMIT 20
          ) dep ON true
          ORDER BY r.finish_at DESC NULLS LAST,r.id DESC
          LIMIT 500
          """,
          [f.now]
        )
      end)

    plan_text = plan |> Enum.map_join("\n", &Map.get(&1, "QUERY PLAN", ""))

    # server execution time for the full lateral query; observed ~2 ms
    [execution_ms] =
      Regex.run(~r/Execution Time: ([0-9.]+) ms/, plan_text) |> List.delete_at(0)

    execution_ms = String.to_float(execution_ms)
    IO.puts("PERF pipeline_lateral_execution=#{execution_ms}ms")
    assert execution_ms < 50, "pipeline lateral executed in #{execution_ms}ms"
  end
end
