defmodule OpsBrain.Insights.SourcesTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures

  alias OpsBrain.{Demo, Insights, Repo, Services, Tenancy, TestAdminRepo}
  alias OpsBrain.Demo.Dataset
  alias OpsBrain.Insights.Sources

  @gib 1_073_741_824.0
  @size_gib 250.0

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, prom_a} =
      Tenancy.create_source(f.scope_a, %{name: "storage-metrics", kind: :prometheus})

    {:ok, prom_b} =
      Tenancy.create_source(f.scope_b, %{name: "storage-metrics", kind: :prometheus})

    {:ok, prom_a2} =
      Tenancy.create_source(f.scope_a, %{name: "storage-metrics-b", kind: :prometheus})

    services =
      for {scope, source, key} <- [
            {f.scope_a, prom_a, "storage-prod"},
            {f.scope_b, prom_b, "billing-prod"}
          ] do
        env = Enum.find(f.envs, &(&1.company_id == scope.company_id and &1.name == :prod))

        {:ok, service} =
          Services.create(scope, %{
            source_id: source.id,
            environment_id: env.id,
            service_key: key,
            target: "synthetic/#{key}"
          })

        {key, service["id"]}
      end
      |> Map.new()

    Map.merge(f, %{
      now: now,
      prom_a: prom_a,
      prom_a2: prom_a2,
      prom_b: prom_b,
      services: services
    })
  end

  # Trusted config bound to one prometheus source, service and profile
  # version with a verified bytes policy.
  defp put_policy(f, source, service_id, profile_extra \\ %{}, policy_extra \\ %{}) do
    policy =
      Map.merge(
        %{
          unit: "bytes",
          limits_verified: true,
          freshness_seconds: 600,
          max_gap_seconds: 120,
          min_history_seconds: 240,
          effective_threshold: round(@size_gib * @gib),
          min_growth_bytes_per_second: 0.001,
          warning_horizon_seconds: 600,
          version: 1
        },
        policy_extra
      )

    profile =
      Map.merge(
        %{
          id: "storage",
          version: 1,
          reviewed: true,
          semantics: "gauge",
          unit: "bytes",
          query: "synthetic",
          freshness_seconds: 600,
          capacity_policy: policy
        },
        profile_extra
      )

    config(Map.put(f, :source_a, source), :a, %{
      kind: "prometheus",
      service_id: service_id,
      profile: profile
    })
  end

  defp insert_windows(scope, rows) do
    Tenancy.with_scope(scope, fn ->
      Enum.each(rows, fn {company_id, source_id, service_id, window_end, samples} ->
        Repo.query!(
          "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,'storage:v1','prometheus',$4,$5,$6,$7)",
          [
            company_id,
            source_id,
            service_id,
            DateTime.add(window_end, -3600, :second),
            window_end,
            window_end,
            %{"samples" => samples, "unit" => "bytes"}
          ]
        )
      end)
    end)
  end

  # 24 hourly samples with the same growth jump as the demo dataset: a sudden
  # 2.1 GiB/h rate on top of a flat 0.15 GiB/h baseline, 215 GiB used now.
  defp jump_windows(company_id, source_id, service_id, now) do
    for hours_ago <- 23..0//-1 do
      used = 215.0 - 2.1 * min(hours_ago, 6) - 0.15 * max(hours_ago - 6, 0)
      at = DateTime.add(now, -hours_ago * 3600, :second)

      {company_id, source_id, service_id, at,
       [
         %{
           "value" => round(used * @gib),
           "timestamp" => DateTime.to_unix(at),
           "series" => "storage"
         }
       ]}
    end
  end

  describe "real prometheus storage history" do
    test "24 hourly byte windows with a growth jump produce one abnormal risk through command/2 and service/4",
         f do
      put_policy(f, f.prom_a, f.services["storage-prod"])

      insert_windows(
        f.scope_a,
        jump_windows(f.a.id, f.prom_a.id, f.services["storage-prod"], f.now)
      )

      assert {:ok, data} = Insights.command(f.scope_a, f.now)
      assert [%{} = risk] = data.storage
      assert risk.volume == "storage"
      assert risk.level == "critical"
      assert risk.abnormal
      assert risk.service == "storage-prod"
      assert risk.environment == "prod"
      assert risk.target == "synthetic/storage-prod"
      assert_in_delta risk.size_gib, @size_gib, 0.001
      assert_in_delta risk.used_gib, 215.0, 0.001
      assert_in_delta risk.used_percent, 86.0, 0.001
      assert_in_delta risk.hours_to_full, 35 / 2.1, 0.01
      assert length(risk.history) == 24
      assert data.counts.predicted == 1

      assert {:ok, info} = Insights.service(f.scope_a, "storage-prod", "prod", f.now)
      assert info.storage.volume == "storage"
      assert info.storage.level == "critical"
      assert info.storage.abnormal
      assert_in_delta info.storage.hours_to_full, 35 / 2.1, 0.01
    end

    test "storage series stay tenant isolated", f do
      put_policy(f, f.prom_a, f.services["storage-prod"])
      put_policy(f, f.prom_b, f.services["billing-prod"])

      insert_windows(
        f.scope_a,
        jump_windows(f.a.id, f.prom_a.id, f.services["storage-prod"], f.now)
      )

      insert_windows(
        f.scope_b,
        jump_windows(f.b.id, f.prom_b.id, f.services["billing-prod"], f.now)
      )

      assert {:ok, %{storage: [a_risk]}} = Insights.command(f.scope_a, f.now)
      assert a_risk.service == "storage-prod"
      assert a_risk.volume == "storage"
      assert_in_delta a_risk.size_gib, @size_gib, 0.001

      assert {:ok, %{storage: [b_risk]}} = Insights.command(f.scope_b, f.now)
      assert b_risk.service == "billing-prod"
      assert b_risk.volume == "storage"
      assert_in_delta b_risk.size_gib, @size_gib, 0.001

      {:ok, [series]} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.storage_series(f.now) end)

      assert series["service_id"] == f.services["storage-prod"]
    end
  end

  describe "unverified limits stay unknown" do
    test "without any source config the risk is unknown, never healthy", f do
      insert_windows(
        f.scope_a,
        jump_windows(f.a.id, f.prom_a.id, f.services["storage-prod"], f.now)
      )

      assert {:ok, data} = Insights.command(f.scope_a, f.now)
      assert [%{} = risk] = data.storage
      assert risk.level == "unknown"
      assert risk.reasons == ["volume size not verified"]
      assert risk.size_gib == nil
      assert risk.used_percent == nil
      assert risk.hours_to_full == nil
      refute risk.abnormal
      assert_in_delta risk.used_gib, 215.0, 0.001
      assert risk.history != []
      assert data.counts.predicted == 0

      assert {:ok, info} = Insights.service(f.scope_a, "storage-prod", "prod", f.now)
      assert info.storage.level == "unknown"
      assert info.storage.reasons == ["volume size not verified"]
      assert info.storage.size_gib == nil
    end

    test "unverified policy, mismatched service and wrong profile version stay unknown",
         f do
      insert_windows(
        f.scope_a,
        jump_windows(f.a.id, f.prom_a.id, f.services["storage-prod"], f.now)
      )

      put_policy(f, f.prom_a, f.services["storage-prod"], %{}, %{limits_verified: false})

      assert {:ok, %{storage: [unverified]}} = Insights.command(f.scope_a, f.now)
      assert unverified.level == "unknown"
      assert unverified.size_gib == nil
      assert unverified.reasons == ["volume size not verified"]

      put_policy(f, f.prom_a, "00000000-0000-4000-8000-000000000099")

      assert {:ok, %{storage: [wrong_service]}} = Insights.command(f.scope_a, f.now)
      assert wrong_service.level == "unknown"
      assert wrong_service.size_gib == nil

      put_policy(f, f.prom_a, f.services["storage-prod"], %{version: 2})

      assert {:ok, %{storage: [wrong_version]}} = Insights.command(f.scope_a, f.now)
      assert wrong_version.level == "unknown"
      assert wrong_version.size_gib == nil
    end
  end

  describe "hourly downsampling" do
    test "last sample per hour wins; future and malformed samples are dropped", f do
      put_policy(f, f.prom_a, f.services["storage-prod"])

      samples =
        for minutes_ago <- 170..0//-10 do
          at = DateTime.add(f.now, -minutes_ago * 60, :second)

          %{
            "value" => round((100.0 + (170 - minutes_ago) * 0.1) * @gib),
            "timestamp" => DateTime.to_unix(at),
            "series" => "storage"
          }
        end

      # future-dated and malformed samples must never reach the series
      samples =
        samples ++
          [
            %{
              "value" => round(999.0 * @gib),
              "timestamp" => DateTime.to_unix(DateTime.add(f.now, 600, :second)),
              "series" => "storage"
            },
            %{"value" => nil, "timestamp" => DateTime.to_unix(f.now), "series" => "storage"},
            %{"timestamp" => DateTime.to_unix(f.now)},
            "garbage"
          ]

      insert_windows(f.scope_a, [
        {f.a.id, f.prom_a.id, f.services["storage-prod"], f.now, samples}
      ])

      # windows outside the last 24 hours, or ending in the future, are excluded
      old = DateTime.add(f.now, -25 * 3600, :second)

      insert_windows(f.scope_a, [
        {
          f.a.id,
          f.prom_a.id,
          f.services["storage-prod"],
          old,
          [%{"value" => round(5.0 * @gib), "timestamp" => DateTime.to_unix(old), "series" => "s"}]
        }
      ])

      future = DateTime.add(f.now, 3600, :second)

      insert_windows(f.scope_a, [
        {
          f.a.id,
          f.prom_a.id,
          f.services["storage-prod"],
          future,
          [
            %{
              "value" => round(7.0 * @gib),
              "timestamp" => DateTime.to_unix(future),
              "series" => "s"
            }
          ]
        }
      ])

      {:ok, [series]} =
        Tenancy.with_scope(f.scope_a, fn ->
          Sources.storage_series(f.now, f.services["storage-prod"])
        end)

      assert series["volume"] == "storage"
      assert series["service_id"] == f.services["storage-prod"]
      assert_in_delta series["size_gib"], @size_gib, 0.001

      assert [
               %{"hours_ago" => 2, "used_gib" => oldest},
               %{"hours_ago" => 1, "used_gib" => middle},
               %{"hours_ago" => 0, "used_gib" => newest}
             ] = series["history"]

      assert_in_delta oldest, 105.0, 0.001
      assert_in_delta middle, 111.0, 0.001
      assert_in_delta newest, 117.0, 0.001
    end
  end

  defp series_window(company_id, source_id, service_id, now, hours_ago, series, used_gib) do
    at = DateTime.add(now, -hours_ago * 3600, :second)

    {company_id, source_id, service_id, at,
     [
       %{
         "value" => round(used_gib * @gib),
         "timestamp" => DateTime.to_unix(at),
         "series" => series
       }
     ]}
  end

  describe "series and source identity" do
    test "two series at the same timestamp stay unknown, never a spliced trajectory", f do
      put_policy(f, f.prom_a, f.services["storage-prod"])
      at = DateTime.add(f.now, -3600, :second)

      insert_windows(f.scope_a, [
        {
          f.a.id,
          f.prom_a.id,
          f.services["storage-prod"],
          at,
          [
            %{
              "value" => round(100.0 * @gib),
              "timestamp" => DateTime.to_unix(at),
              "series" => "volume-a"
            },
            %{
              "value" => round(200.0 * @gib),
              "timestamp" => DateTime.to_unix(at),
              "series" => "volume-b"
            }
          ]
        }
      ])

      {:ok, [series]} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.storage_series(f.now) end)

      assert series["volume"] == "storage"
      assert series["mixed_identities"] == true
      assert series["history"] == []
      assert series["size_gib"] == nil

      assert {:ok, %{storage: [risk]}} = Insights.command(f.scope_a, f.now)
      assert risk.level == "unknown"

      assert risk.reasons == [
               "usage samples cannot be attributed to one series or source identity — no single volume history"
             ]

      assert risk.hours_to_full == nil
    end

    test "a series identity change over time is not silently spliced", f do
      put_policy(f, f.prom_a, f.services["storage-prod"])

      rows =
        for h <- 23..12//-1 do
          series_window(
            f.a.id,
            f.prom_a.id,
            f.services["storage-prod"],
            f.now,
            h,
            "old",
            100.0 + (23 - h)
          )
        end ++
          for h <- 11..0//-1 do
            series_window(
              f.a.id,
              f.prom_a.id,
              f.services["storage-prod"],
              f.now,
              h,
              "new",
              150.0 + (11 - h)
            )
          end

      insert_windows(f.scope_a, rows)

      {:ok, [series]} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.storage_series(f.now) end)

      assert series["mixed_identities"] == true
      assert series["history"] == []

      assert {:ok, %{storage: [risk]}} = Insights.command(f.scope_a, f.now)
      assert risk.level == "unknown"
      assert risk.hours_to_full == nil
    end

    test "a verified limit is not lent to another source's samples", f do
      # the samples come from prom_a, whose policy is unverified; prom_a2 has a
      # verified policy for the same service and profile and must not lend it.
      put_policy(f, f.prom_a, f.services["storage-prod"], %{}, %{limits_verified: false})
      put_policy(f, f.prom_a2, f.services["storage-prod"])

      insert_windows(
        f.scope_a,
        jump_windows(f.a.id, f.prom_a.id, f.services["storage-prod"], f.now)
      )

      assert {:ok, %{storage: [risk]}} = Insights.command(f.scope_a, f.now)
      assert risk.level == "unknown"
      assert risk.size_gib == nil
      assert risk.reasons == ["volume size not verified"]

      # a second source scraping the same service/profile makes the group mixed
      insert_windows(
        f.scope_a,
        jump_windows(f.a.id, f.prom_a2.id, f.services["storage-prod"], f.now)
      )

      assert {:ok, %{storage: [mixed]}} = Insights.command(f.scope_a, f.now)
      assert mixed.level == "unknown"

      assert mixed.reasons == [
               "usage samples cannot be attributed to one series or source identity — no single volume history"
             ]
    end

    test "samples without a series digest are unattributable, not a trusted forecast",
         f do
      put_policy(f, f.prom_a, f.services["storage-prod"])

      rows =
        for h <- 23..0//-1 do
          series_window(
            f.a.id,
            f.prom_a.id,
            f.services["storage-prod"],
            f.now,
            h,
            nil,
            40.0 + (23 - h) * 0.1
          )
        end

      insert_windows(f.scope_a, rows)

      {:ok, [series]} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.storage_series(f.now) end)

      assert series["mixed_identities"] == true
      assert series["history"] == []
      assert series["size_gib"] == nil

      assert {:ok, %{storage: [risk]}} = Insights.command(f.scope_a, f.now)
      assert risk.level == "unknown"
      assert risk.hours_to_full == nil

      assert risk.reasons == [
               "usage samples cannot be attributed to one series or source identity — no single volume history"
             ]
    end
  end

  describe "freshness" do
    test "hours_ago is relative to the newest sample; freshness is separate", f do
      put_policy(f, f.prom_a, f.services["storage-prod"])

      # 22 hourly samples ending 2 hours ago, growing 2.1 GiB/h throughout
      rows =
        for h <- 23..2//-1 do
          used = 215.0 - 2.1 * (h - 2)

          series_window(
            f.a.id,
            f.prom_a.id,
            f.services["storage-prod"],
            f.now,
            h,
            "storage",
            used
          )
        end

      insert_windows(f.scope_a, rows)

      {:ok, [series]} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.storage_series(f.now) end)

      assert_in_delta series["fresh_hours"], 2.0, 0.01
      assert List.first(series["history"])["hours_ago"] == 21
      assert List.last(series["history"])["hours_ago"] == 0
      assert length(series["history"]) == 22

      assert {:ok, %{storage: [risk]}} = Insights.command(f.scope_a, f.now)
      assert risk.level == "critical"
      assert_in_delta risk.hours_to_full, 35 / 2.1, 0.01
      assert_in_delta risk.used_gib, 215.0, 0.001
      assert_in_delta risk.fresh_hours, 2.0, 0.01
    end

    test "a stale history is never a healthy zero-rate claim", f do
      put_policy(f, f.prom_a, f.services["storage-prod"])

      # flat 40 GiB usage whose newest sample is 8 hours old
      rows =
        for h <- 23..8//-1 do
          series_window(
            f.a.id,
            f.prom_a.id,
            f.services["storage-prod"],
            f.now,
            h,
            "storage",
            40.0
          )
        end

      insert_windows(f.scope_a, rows)

      assert {:ok, %{storage: [risk]}} = Insights.command(f.scope_a, f.now)
      assert risk.level == "unknown"
      assert risk.hours_to_full == nil
      assert risk.recent_rate == nil
      refute risk.abnormal
      assert risk.reasons == ["usage history is 8.0 h old — growth not projected"]
      assert_in_delta risk.used_gib, 40.0, 0.001
      assert_in_delta risk.fresh_hours, 8.0, 0.01
    end
  end

  describe "demo storage passthrough" do
    test "reporting-postgres stays critical at about 16.7 h and duplicates deduplicate",
         f do
      Demo.seed!(TestAdminRepo, f.alice.name, now: f.now)
      {:ok, demo_scope} = Tenancy.authorize(f.token_a, Demo.company_id())

      assert {:ok, data} = Insights.command(demo_scope, f.now)
      risks = data.storage

      # one entry per volume and environment: 3 volumes x prod + staging
      assert length(risks) == 6
      assert [%{} = reporting | _] = risks
      assert reporting.volume == "reporting-postgres"
      assert reporting.level == "critical"
      assert reporting.abnormal
      assert reporting.service == "reporting"
      assert reporting.environment == "prod"
      assert_in_delta reporting.size_gib, 250.0, 0.01
      assert_in_delta reporting.used_gib, 215.0, 0.01
      assert_in_delta reporting.hours_to_full, 16.7, 0.05
      # the offline snapshot's history is relative to its own window: current
      assert reporting.fresh_hours == 0.0
      assert Enum.count(risks, &(&1.level == "critical")) == 1
      assert Enum.all?(risks, &(&1.size_gib == 250))
      # degraded latest demo runs are honest warnings now (Task 2.3),
      # so the verified predicted count grew from 4 to 12
      assert data.counts.predicted == 12

      assert {:ok, info} = Insights.service(demo_scope, "reporting", "prod", f.now)
      assert info.storage.volume == "reporting-postgres"
      assert info.storage.level == "critical"
      assert_in_delta info.storage.hours_to_full, 16.7, 0.05

      # an older duplicate capacity window for the same volume is ignored
      Tenancy.with_scope(demo_scope, fn ->
        Repo.query!(
          "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,'reporting:capacity','capacity',$4,$5,$6,$7)",
          [
            Demo.company_id(),
            Dataset.id("nw-eu-prod-kubernetes"),
            Dataset.id("service:nw-eu-prod:reporting"),
            DateTime.add(f.now, -3 * 3600, :second),
            DateTime.add(f.now, -2 * 3600, :second),
            DateTime.add(f.now, -2 * 3600, :second),
            %{
              "storage" => %{
                "volume" => "reporting-postgres",
                "size_gib" => 999,
                "history" => [%{"hours_ago" => 0, "used_gib" => 10.0}]
              }
            }
          ]
        )
      end)

      assert {:ok, data2} = Insights.command(demo_scope, f.now)
      # the duplicate window is deduplicated: one entry per volume and environment
      assert length(data2.storage) == 6
      assert Enum.count(data2.storage, &(&1.volume == "reporting-postgres")) == 2

      reporting2 =
        Enum.find(
          data2.storage,
          &(&1.volume == "reporting-postgres" and &1.environment == "prod")
        )

      assert_in_delta reporting2.size_gib, 250.0, 0.01
      assert reporting2.level == "critical"
      assert_in_delta reporting2.hours_to_full, 16.7, 0.05
    end
  end
end
