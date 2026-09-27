defmodule OpsBrainWeb.CapacityLiveTest do
  use OpsBrainWeb.ConnCase, async: false
  import OpsBrain.SourceFixtures

  alias OpsBrain.{
    Accounts,
    Evaluations,
    Evidence,
    Issues,
    Repo,
    Services,
    SourceConfig,
    Store,
    Tenancy
  }

  alias OpsBrainWeb.UI

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Application.put_env(:ops_brain, :clock, fn -> now end)
    {:ok, prom} = Tenancy.create_source(f.scope_a, %{name: "storage-metrics", kind: :prometheus})

    services =
      Map.new([:prod, :staging], fn name ->
        env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == name))

        {:ok, service} =
          Services.create(f.scope_a, %{
            source_id: prom.id,
            environment_id: env.id,
            service_key: "storage-#{name}",
            target: "synthetic/#{name}"
          })

        {name, service["id"]}
      end)

    policy = %{
      unit: "bytes",
      limits_verified: true,
      freshness_seconds: 600,
      max_gap_seconds: 120,
      min_history_seconds: 240,
      effective_threshold: 1000,
      min_growth_bytes_per_second: 0.001,
      warning_horizon_seconds: 600,
      version: 1
    }

    profile = %{
      id: "storage",
      version: 1,
      reviewed: true,
      semantics: "gauge",
      unit: "bytes",
      query: "synthetic",
      threshold: 10000,
      freshness_seconds: 600,
      capacity_policy: policy
    }

    c =
      config(%{f | source_a: prom}, :a, %{
        kind: "prometheus",
        service_id: services.prod,
        profile: profile
      })

    Map.merge(f, %{
      c: c,
      now: now,
      services: services,
      conn: init_test_session(build_conn(), operator_token: f.token_a)
    })
  end

  defp data(service, condition \\ "warning") do
    %{
      "service_id" => service,
      "profile" => "storage:v1",
      "result" => %{
        "condition" => condition,
        "seconds_to_threshold" => 300,
        "reason" => "conditional recorded estimate"
      }
    }
  end

  defp retain(f, key, data, received \\ nil) do
    at = received || f.now

    {:ok, id} =
      SourceConfig.transaction(f.c.id, fn c ->
        Evidence.save(
          c,
          key,
          "capacity_evaluation",
          Map.put_new(data, "as_of", Store.iso(at)),
          at,
          at
        )
      end)

    id
  end

  defp seed_windows(f) do
    {:ok, ids} =
      SourceConfig.transaction(f.c.id, fn c ->
        Enum.map(Enum.with_index([100, 200, 300, 400, 500]), fn {value, i} ->
          ts = DateTime.add(f.now, (i - 4) * 60)
          id = Ecto.UUID.generate()

          data = %{
            "samples" => [
              %{"value" => value, "series" => "storage-a", "timestamp" => DateTime.to_unix(ts)}
            ],
            "unit" => "bytes",
            "capacity_segment" => "stable",
            "coverage" => "complete",
            "condition" => "normal"
          }

          Repo.query!(
            "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,'storage:v1','prometheus',$5,$6,$6,$7)",
            [id, c.company_id, c.id, f.services.prod, DateTime.add(ts, -60), ts, data]
          )

          id
        end)
      end)

    ids
  end

  test "real evaluator warning appears even when every supporting gauge window is normal", f do
    seed_windows(f)

    assert {:ok, %{condition: "warning", seconds_to_threshold: seconds}} =
             SourceConfig.transaction(f.c.id, fn c -> Evaluations.capacity(c, f.now, f.now) end)

    assert_in_delta seconds, 300, 0.01
    assert {:ok, [forecast]} = Services.capacity_evaluations(f.scope_a, "prod", f.now)
    assert forecast["data"]["service_id"] == f.services.prod
    assert {:ok, [%{"severity" => "warning"}]} = Issues.list(f.scope_a)
    assert {:ok, view, _} = live(f.conn, "/companies/#{f.a.id}/capacity?environment=prod")
    selector = "#forecasts-#{forecast["id"]}"
    assert has_element?(view, selector <> " .badge-warning", "Warning")
    assert has_element?(view, selector <> " .forecast-estimate", "5.0 minutes")
    assert has_element?(view, selector <> " .forecast-reason", "conditional estimate")
    assert has_element?(view, "#operations-stats", "Capacity evaluations")
    assert has_element?(view, "#capacity-evaluations", "not current health")
    assert {:ok, services} = Services.overview(f.scope_a)

    assert [{_, _, _, _}, {"Capacity evaluations", 1, _, _}, {"Warning / critical", 1, _, _} | _] =
             UI.summaries(:capacity, {services, [forecast]})
  end

  test "normal, critical, unknown and legacy output-only records preserve their meanings", f do
    normal = retain(f, "normal", data(f.services.prod, "normal"))

    critical =
      retain(
        f,
        "critical",
        put_in(data(f.services.prod, "critical"), ["result", "seconds_to_threshold"], 0)
      )

    unknown_data = %{
      "service_id" => f.services.prod,
      "result" => %{
        "condition" => "unknown",
        "reason" => "insufficient history",
        "seconds_to_threshold" => nil
      }
    }

    unknown = retain(f, "unknown", unknown_data)

    legacy =
      retain(f, "legacy-output", %{
        "service_id" => f.services.prod,
        "summary" => "legacy output only"
      })

    assert {:ok, view, _} = live(f.conn, "/companies/#{f.a.id}/capacity?environment=prod")
    assert has_element?(view, "#forecasts-#{normal} .badge-success", "Normal")
    assert has_element?(view, "#forecasts-#{critical} .badge-danger", "Critical")
    assert has_element?(view, "#forecasts-#{critical} .forecast-estimate", "0.0 minutes")
    assert has_element?(view, "#forecasts-#{unknown} .forecast-reason", "insufficient history")
    refute has_element?(view, "#forecasts-#{unknown} .forecast-estimate")
    assert has_element?(view, "#forecasts-#{legacy} .badge-neutral", "Unknown")
    refute has_element?(view, "#forecasts-#{legacy} .forecast-estimate")
  end

  test "legacy input identities resolve only while retained and unmapped data remains explicit",
       f do
    ids = seed_windows(f)

    legacy_data =
      data(f.services.prod) |> Map.delete("service_id") |> Map.put("input_window_ids", ids)

    mapped = retain(f, "legacy-mapped", legacy_data)

    unmapped =
      retain(
        f,
        "legacy-unmapped",
        Map.put(legacy_data, "input_window_ids", [Ecto.UUID.generate()])
      )

    assert {:ok, [forecast]} = Services.capacity_evaluations(f.scope_a, "prod", f.now)
    assert forecast["id"] == mapped and forecast["service_id"] == f.services.prod
    assert {:ok, all} = Services.capacity_evaluations(f.scope_a, "", f.now)
    assert Enum.find(all, &(&1["id"] == unmapped))["service_id"] == nil
    assert {:ok, view, _} = live(f.conn, "/companies/#{f.a.id}/capacity")
    assert has_element?(view, "#forecasts-#{unmapped}", "Unmapped service")
    assert {:error, :invalid_environment} = Services.capacity_evaluations(f.scope_a, "arbitrary")
  end

  test "environment selection precedes the forecast limit", f do
    prod = retain(f, "older-prod", data(f.services.prod), DateTime.add(f.now, -60))
    for n <- 1..101, do: retain(f, "staging-#{n}", data(f.services.staging))
    assert {:ok, all} = Services.capacity_evaluations(f.scope_a, "", f.now)
    assert length(all) == 100
    refute Enum.any?(all, &(&1["id"] == prod))
    assert {:ok, [%{"id" => ^prod}]} = Services.capacity_evaluations(f.scope_a, "prod", f.now)
  end

  test "search, environment switching and refresh reset streams and remove expired evidence", f do
    prod = retain(f, "prod", data(f.services.prod))
    staging = retain(f, "staging", data(f.services.staging))
    expired = retain(f, "expired", data(f.services.prod), DateTime.add(f.now, -8, :day))
    tombstone = retain(f, "tombstone", %{"service_id" => f.services.prod, "expired" => true})
    assert {:ok, view, _} = live(f.conn, "/companies/#{f.a.id}/capacity?environment=prod")
    assert has_element?(view, "#forecasts-#{prod}")
    for id <- [staging, expired, tombstone], do: refute(has_element?(view, "#forecasts-#{id}"))

    form(view, "#operations-filter", %{query: "unmatched", environment: "prod"})
    |> render_change()

    refute has_element?(view, "#forecasts-#{prod}")
    assert has_element?(view, "#capacity-evaluations", "No matching capacity evaluations")

    form(view, "#operations-filter", %{query: "conditional", environment: "staging"})
    |> render_change()

    element(view, "#refresh-operations") |> render_click()
    assert has_element?(view, "#forecasts-#{staging}")
    refute has_element?(view, "#forecasts-#{prod}")
    assert has_element?(view, "#operations-environment option[value=staging][selected]")
    Application.put_env(:ops_brain, :clock, fn -> DateTime.add(f.now, 8, :day) end)
    element(view, "#refresh-operations") |> render_click()
    refute has_element?(view, "#capacity-results article")
  end

  test "forecast reads and navigation enforce company scope and revocation", f do
    id = retain(f, "private-company-a", data(f.services.prod))
    assert {:ok, []} = Services.capacity_evaluations(f.scope_b)
    conn = init_test_session(build_conn(), operator_token: f.token_dual)
    assert {:ok, view, _} = live(conn, "/companies/#{f.a.id}/capacity")
    assert has_element?(view, "#forecasts-#{id}")
    render_patch(view, "/companies/#{f.b.id}/capacity")
    refute has_element?(view, "#forecasts-#{id}")
    Accounts.revoke_session(f.token_dual)
    send(view.pid, :refresh)
    assert_redirect(view, "/sign-in")
    Accounts.revoke_session(f.token_a)
    assert {:error, :unauthorized} = Services.capacity_evaluations(f.scope_a)
  end
end
