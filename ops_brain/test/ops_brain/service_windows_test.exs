defmodule OpsBrain.ServiceWindowsTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures

  alias OpsBrain.{Insights, Repo, Services, Tenancy}

  setup do
    on_exit(&cleanup/0)
    f = fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))
    {:ok, source} = Tenancy.create_source(f.scope_a, %{name: "metrics", kind: :prometheus})

    selected = service!(f, source, env, "orders-db", "east/data/orders-db")
    capacity_only = service!(f, source, env, "billing-api", "east/data/billing-api")
    other = service!(f, source, env, "noise", "east/data/noise")

    Map.merge(f, %{
      now: now,
      source: source,
      selected: selected,
      capacity_only: capacity_only,
      other: other
    })
  end

  test "newer unrelated windows cannot hide selected metric or capacity telemetry", f do
    insert_window(f, f.selected["id"], "metric", -7200, %{
      "condition" => "warning",
      "cpu_percent" => 17,
      "memory_percent" => 40,
      "p95_latency_ms" => 80
    })

    insert_window(f, f.selected["id"], "capacity", -7100, %{
      "condition" => "critical",
      "used_gib" => 12
    })

    insert_window(f, f.capacity_only["id"], "capacity", -7000, %{"condition" => "warning"})

    for n <- 1..101 do
      insert_window(f, f.other["id"], "metric", -n, %{
        "condition" => "critical",
        "cpu_percent" => 99
      })
    end

    assert {:ok, global} = Services.windows(f.scope_a)
    assert length(global) == 100
    refute Enum.any?(global, &(&1["service_id"] in [f.selected["id"], f.capacity_only["id"]]))

    assert {:ok, scoped} = Services.service_windows(f.scope_a, f.selected["id"])
    assert length(scoped) == 2
    assert Enum.map(scoped, & &1["kind"]) |> Enum.sort() == ["capacity", "metric"]
    assert Enum.all?(scoped, &(&1["service_id"] == f.selected["id"]))

    assert {:ok, []} = Services.service_windows(f.scope_b, f.selected["id"])
    assert {:error, :not_found} = Services.service_windows(f.scope_a, "not-a-uuid")

    assert {:ok, page} = Insights.service(f.scope_a, "orders-db", "prod", f.now)
    assert page.metric["cpu_percent"] == 17
    assert page.condition == "warning"

    assert {:ok, capacity_page} = Insights.service(f.scope_a, "billing-api", "prod", f.now)
    assert capacity_page.metric == nil
    assert capacity_page.condition == "warning"
  end

  defp service!(f, source, env, key, target) do
    {:ok, service} =
      Services.create(f.scope_a, %{
        source_id: source.id,
        environment_id: env.id,
        service_key: key,
        target: target
      })

    service
  end

  defp insert_window(f, service_id, kind, offset, data) do
    at = DateTime.add(f.now, offset, :second)

    Tenancy.with_scope(f.scope_a, fn ->
      Repo.query!(
        "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,$5,$6,$7,$7,$8)",
        [
          f.a.id,
          f.source.id,
          service_id,
          "profile:" <> kind <> ":" <> Integer.to_string(offset),
          kind,
          DateTime.add(at, -60, :second),
          at,
          data
        ]
      )
    end)
  end
end
