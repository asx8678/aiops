defmodule OpsBrain.CapacityRecoveryTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{Evaluations, Services, SourceConfig, Repo, Issues, Tenancy}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    now = ~U[2025-01-02 01:00:00Z]
    {:ok, prom} = Tenancy.create_source(f.scope_a, %{name: "prom", kind: :prometheus})
    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    {:ok, service} =
      Services.create(f.scope_a, %{
        source_id: prom.id,
        environment_id: env.id,
        service_key: "api",
        target: "ns/api"
      })

    Map.merge(f, %{source_a: prom, now: now, service: service["id"], env: env})
  end

  defp base_profile do
    %{
      id: "metric",
      version: 1,
      reviewed: true,
      semantics: "gauge",
      unit: "bytes",
      query: "synthetic",
      freshness_seconds: 600
    }
  end

  defp capacity_policy(threshold) do
    %{
      unit: "bytes",
      limits_verified: true,
      freshness_seconds: 600,
      max_gap_seconds: 120,
      min_history_seconds: 240,
      effective_threshold: threshold,
      min_growth_bytes_per_second: 0.001,
      warning_horizon_seconds: 600,
      version: 1
    }
  end

  defp config_with_policy(f, threshold) do
    config(f, :a, %{
      kind: "prometheus",
      service_id: f.service,
      profile: Map.put(base_profile(), :capacity_policy, capacity_policy(threshold))
    })
  end

  defp seed_windows(f, base, values) do
    SourceConfig.transaction(f.source_a.id, fn c ->
      values
      |> Enum.with_index()
      |> Enum.each(fn {value, i} ->
        ts = DateTime.add(base, i * 60, :second)

        Repo.query!(
          "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$6,$7)",
          [
            c.company_id,
            c.id,
            f.service,
            "metric:v1",
            DateTime.add(ts, -60, :second),
            ts,
            %{
              "samples" => [
                %{
                  "value" => value,
                  "series" => "storage-a",
                  "timestamp" => DateTime.to_unix(ts)
                }
              ],
              "unit" => "bytes",
              "capacity_segment" => "stable",
              "coverage" => "complete",
              "condition" => "normal"
            }
          ]
        )
      end)
    end)
  end

  defp evaluate(_f, c, finish, now) do
    SourceConfig.transaction(c.id, fn trusted ->
      Evaluations.capacity(trusted, finish, now)
    end)
  end

  test "actual sample times, missing timestamps and partial coverage cannot become fresh recovery",
       f do
    c = config_with_policy(f, 1000)
    seed_windows(f, DateTime.add(f.now, -240), [100, 200, 300, 400, 500])
    assert {:ok, %{condition: "warning"}} = evaluate(f, c, f.now, f.now)

    for data_change <- [
          "jsonb_set(data, '{samples,0,timestamp}', to_jsonb((extract(epoch from window_end)-3600)::bigint))",
          "data #- '{samples,0,timestamp}'",
          "jsonb_set(data, '{coverage}', '\"partial\"'::jsonb)"
        ] do
      SourceConfig.transaction(c.id, fn _ ->
        Repo.query!(
          "UPDATE observation_windows SET data=jsonb_set(jsonb_set(data, '{samples,0,timestamp}', to_jsonb(extract(epoch from window_end)::bigint)), '{coverage}', '\"complete\"'::jsonb)"
        )

        Repo.query!("UPDATE observation_windows SET data=" <> data_change)
      end)

      assert {:ok, %{condition: "unknown"}} = evaluate(f, c, f.now, f.now)
      {:ok, [g]} = Issues.list(f.scope_a)
      refute g["status"] == "recovered"
    end
  end

  test "profile changes do not mix samples and policy changes do not recover old findings", f do
    c = config_with_policy(f, 1000)
    seed_windows(f, DateTime.add(f.now, -240), [100, 200, 300, 400, 500])
    assert {:ok, %{condition: "warning"}} = evaluate(f, c, f.now, f.now)
    changed = config_with_policy(f, 100_000)
    assert {:ok, %{condition: "normal"}} = evaluate(f, changed, f.now, f.now)
    {:ok, [g]} = Issues.list(f.scope_a)
    refute g["status"] == "recovered"

    changed =
      config(f, :a, %{
        kind: "prometheus",
        service_id: f.service,
        profile: %{c.profile | version: 2}
      })

    assert {:ok, %{condition: "unknown"}} = evaluate(f, changed, f.now, f.now)
    {:ok, [g]} = Issues.list(f.scope_a)
    refute g["status"] == "recovered"
  end

  test "critical findings recover once after a stable cleanup segment but reviewed closures stay closed",
       f do
    c = config_with_policy(f, 1000)
    seed_windows(f, DateTime.add(f.now, -240), [600, 700, 800, 900, 1000])
    assert {:ok, %{condition: "critical"}} = evaluate(f, c, f.now, f.now)
    {:ok, [g]} = Issues.list(f.scope_a)
    assert {:ok, _} = Issues.assign(f.scope_a, g["id"], "owner")
    base = DateTime.add(f.now, 60)
    seed_windows(f, base, Enum.to_list(701..760))
    at = DateTime.add(base, 59 * 60)

    SourceConfig.transaction(c.id, fn _ ->
      Repo.query!(
        "UPDATE observation_windows SET data=jsonb_set(data, '{capacity_segment}', '\"after-cleanup\"'::jsonb) WHERE window_end > $1",
        [f.now]
      )
    end)

    assert {:ok, %{condition: "normal"}} = evaluate(f, c, at, at)
    {:ok, [recovered]} = Issues.list(f.scope_a)
    assert recovered["status"] == "recovered"
    assert recovered["severity"] == "critical"
    assert recovered["owner"] == "owner"
    assert {:ok, %{condition: "normal"}} = evaluate(f, c, at, at)
    assert {:ok, [^recovered]} = Issues.list(f.scope_a)
    assert {:ok, _} = Issues.review(f.scope_a, g["id"], "closed_by_reviewer")
    assert {:ok, %{condition: "normal"}} = evaluate(f, c, at, at)
    {:ok, [closed]} = Issues.list(f.scope_a)
    assert closed["status"] == "closed_by_reviewer"
  end

  test "capacity warning recovers only with comparable fresh normal evidence", f do
    c = config_with_policy(f, 1000)
    base = DateTime.add(f.now, -360, :second)
    seed_windows(f, base, [100, 200, 300, 400, 500, 600, 700])

    {:ok, warning} =
      SourceConfig.transaction(c.id, fn trusted ->
        Evaluations.capacity(
          trusted,
          DateTime.add(base, 240, :second),
          DateTime.add(base, 240, :second)
        )
      end)

    assert warning.condition == "warning"
    {:ok, [group]} = Issues.list(f.scope_a)
    refute group["status"] == "recovered"

    c2 = c
    normal_base = DateTime.add(f.now, 60)
    seed_windows(f, normal_base, Enum.to_list(701..760))
    normal_at = DateTime.add(normal_base, 59 * 60)

    {:ok, normal} =
      SourceConfig.transaction(c2.id, fn trusted ->
        Evaluations.capacity(
          trusted,
          normal_at,
          normal_at
        )
      end)

    assert normal.condition == "normal"

    {:ok, [recovered]} = Issues.list(f.scope_a)
    assert recovered["status"] == "recovered"
    assert is_binary(recovered["data"]["recovery_evidence_id"])

    {:ok, revisions} = Issues.evidence(f.scope_a, recovered["id"], normal_at)
    assert Enum.any?(revisions, &(&1["kind"] == "capacity_recovery"))
  end
end
