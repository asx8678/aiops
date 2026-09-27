defmodule OpsBrain.Insights.CountsTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures

  alias OpsBrain.{Insights, Repo, Services, Tenancy}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, prom} = Tenancy.create_source(f.scope_a, %{name: "metrics", kind: :prometheus})
    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    {:ok, service} =
      Services.create(f.scope_a, %{
        source_id: prom.id,
        environment_id: env.id,
        service_key: "orders-db",
        target: "nw-eu/data/orders-db"
      })

    Map.merge(f, %{now: now, prom: prom, service_id: service["id"]})
  end

  # A count-profile config whose capacity_policy is a verified COUNT policy.
  defp put_count_config(f, policy_extra \\ %{}, profile_extra \\ %{}) do
    policy =
      Map.merge(
        %{
          unit: "count",
          limits_verified: true,
          freshness_seconds: 600,
          max_gap_seconds: 120,
          min_history_seconds: 240,
          effective_threshold: 500,
          min_growth_bytes_per_second: 0.001,
          warning_horizon_seconds: 600,
          version: 1
        },
        policy_extra
      )

    profile =
      %{
        id: "db-connections",
        version: 1,
        reviewed: true,
        semantics: "gauge",
        unit: "count",
        query: "pg_stat_activity_count",
        freshness_seconds: 600,
        capacity_policy: policy
      }

    profile = Map.merge(profile, profile_extra)

    config(Map.put(f, :source_a, f.prom), :a, %{
      kind: "prometheus",
      service_id: f.service_id,
      profile: profile
    })
  end

  # 24 hourly count samples with a growth jump: 480 now, 10/h recent, 1/h baseline
  defp insert_count_windows(f, _c, series \\ "connections") do
    Tenancy.with_scope(f.scope_a, fn ->
      for h <- 23..0//-1 do
        value = 480 - 10 * min(h, 6) - 1 * max(h - 6, 0)
        at = DateTime.add(f.now, -h * 3600, :second)

        Repo.query!(
          "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$7,$8)",
          [
            f.a.id,
            f.prom.id,
            f.service_id,
            "db-connections:v1",
            DateTime.add(at, -3600, :second),
            at,
            at,
            %{
              "samples" => [
                %{"value" => value, "timestamp" => DateTime.to_unix(at), "series" => series}
              ],
              "unit" => "count"
            }
          ]
        )
      end
    end)
  end

  describe "signal classification gates semantics" do
    test "an unclassified count profile is a generic count signal, never connections", f do
      c = put_count_config(f)
      insert_count_windows(f, c)

      assert {:ok, page} = Insights.service(f.scope_a, "orders-db", "prod", f.now)
      assert [%{} = risk] = page.saturation

      # verified limit, so the analysis is real — but the label is generic
      assert risk.level == "critical"
      assert risk.unit == "count"
      assert risk.signal == nil
      refute Enum.any?(page.checks, &String.contains?(&1, "Connections at"))
      refute Enum.any?(page.checks, &String.contains?(&1, "pool size"))
    end

    test "a classified memory working set analyzes separately from storage", f do
      _c =
        put_count_config(
          f,
          %{unit: "bytes", effective_threshold: 512 * 1_073_741_824},
          %{saturation_signal: "memory_working_set", unit: "bytes"}
        )

      Tenancy.with_scope(f.scope_a, fn ->
        for h <- 23..0//-1 do
          gib = 480.0 - 10 * min(h, 6) - 1 * max(h - 6, 0)
          at = DateTime.add(f.now, -h * 3600, :second)

          Repo.query!(
            "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$6,$7)",
            [
              f.a.id,
              f.prom.id,
              f.service_id,
              "db-connections:v1",
              DateTime.add(at, -3600, :second),
              at,
              %{
                "samples" => [
                  %{
                    "value" => round(gib * 1_073_741_824),
                    "timestamp" => DateTime.to_unix(at),
                    "series" => "memory"
                  }
                ],
                "unit" => "bytes"
              }
            ]
          )
        end
      end)

      assert {:ok, data} = Insights.command(f.scope_a, f.now)

      assert [%{} = risk] = data.saturation
      assert risk.signal == "memory_working_set"
      assert risk.unit == "GiB"
      assert risk.level == "critical"
      assert_in_delta risk.value, 480.0, 0.001
      assert_in_delta risk.limit, 512.0, 0.001

      # classified memory is never double-labeled storage
      assert data.storage == []

      assert {:ok, page} = Insights.service(f.scope_a, "orders-db", "prod", f.now)
      assert [%{} = r] = page.saturation
      assert r.signal == "memory_working_set"

      assert Enum.any?(page.checks, &String.contains?(&1, "Pod memory working set"))
      refute Enum.any?(page.checks, &String.contains?(&1, "Connections at"))
    end

    test "an invalid saturation_signal is rejected by config validation", f do
      assert {:error, :invalid_source_configuration} =
               OpsBrain.SourceConfig.validate(%{
                 id: f.prom.id,
                 company_id: f.a.id,
                 kind: "prometheus",
                 endpoint: "https://prom.invalid",
                 approved_origins: ["https://prom.invalid"],
                 approved_ips: ["192.0.2.1"],
                 network_reviewed: true,
                 enabled: true,
                 interval_seconds: 30,
                 max_bytes: 200_000,
                 page_size: 100,
                 max_pages: 10,
                 max_window_seconds: 3600,
                 retention_days: 7,
                 service_id: f.service_id,
                 profile: %{
                   id: "db-connections",
                   version: 1,
                   reviewed: true,
                   semantics: "gauge",
                   unit: "count",
                   query: "pg_stat_activity_count",
                   saturation_signal: "queue_depth",
                   capacity_policy: %{
                     unit: "count",
                     limits_verified: true,
                     effective_threshold: 500
                   }
                 }
               })
    end
  end

  describe "signal configuration contract" do
    test "the prepared JSON loader reads the saturation_signal marker" do
      configs = OpsBrain.Configuration.read!("config/sources.prepared.json")

      classified =
        configs.sources
        |> Map.values()
        |> Enum.filter(fn s ->
          is_map(s[:profile]) and s[:profile][:saturation_signal] == "connections"
        end)

      assert length(classified) == 1
      assert hd(classified)[:enabled] == false
      assert get_in(hd(classified), [:profile, :unit]) == "count"
      assert get_in(hd(classified), [:profile, :capacity_policy, :limits_verified]) == false
    end

    test "saturation_signal requires a compatible unit and semantics" do
      base = %{
        id: Ecto.UUID.generate(),
        company_id: Ecto.UUID.generate(),
        kind: "prometheus",
        endpoint: "https://prom.invalid",
        approved_origins: ["https://prom.invalid"],
        approved_ips: ["192.0.2.1"],
        network_reviewed: true,
        enabled: true,
        interval_seconds: 30,
        max_bytes: 200_000,
        page_size: 100,
        max_pages: 10,
        max_window_seconds: 3600,
        retention_days: 7,
        service_id: Ecto.UUID.generate()
      }

      profile = fn unit, signal ->
        Map.merge(base, %{
          profile: %{
            id: "sig",
            version: 1,
            reviewed: true,
            semantics: "gauge",
            unit: unit,
            query: "q",
            saturation_signal: signal
          }
        })
      end

      # valid combinations
      assert :ok = OpsBrain.SourceConfig.validate(profile.("count", "connections"))
      assert :ok = OpsBrain.SourceConfig.validate(profile.("bytes", "memory_working_set"))

      # incompatible units are rejected, not silently relabeled (validate's
      # fallback error surfaces the rejected profile)
      assert {:error, :invalid_source_configuration} =
               OpsBrain.SourceConfig.validate(profile.("bytes", "connections"))

      assert {:error, :invalid_source_configuration} =
               OpsBrain.SourceConfig.validate(profile.("count", "memory_working_set"))

      # incompatible semantics rejected
      ratio = put_in(profile.("count", "connections"), [:profile, :semantics], "ratio")

      assert {:error, :invalid_source_configuration} = OpsBrain.SourceConfig.validate(ratio)
    end

    test "conflicting classifications across sources leave the group unattributable", f do
      # two sources scrape the same service/profile but disagree on the signal
      {:ok, prom_a} = Tenancy.create_source(f.scope_a, %{name: "metrics-a", kind: :prometheus})
      {:ok, prom_b} = Tenancy.create_source(f.scope_a, %{name: "metrics-b", kind: :prometheus})

      env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

      {:ok, service} =
        Services.create(f.scope_a, %{
          source_id: prom_a.id,
          environment_id: env.id,
          service_key: "orders-db",
          target: "nw-eu/data/orders-db"
        })

      profile = %{
        id: "db-connections",
        version: 1,
        reviewed: true,
        semantics: "gauge",
        unit: "count",
        query: "pg_stat_activity_count",
        capacity_policy: %{unit: "count", limits_verified: true, effective_threshold: 500}
      }

      config(Map.put(f, :source_a, prom_a), :a, %{
        kind: "prometheus",
        service_id: service["id"],
        profile: Map.put(profile, :saturation_signal, "connections")
      })

      # a VALID bytes-classified memory source whose retained windows carry a
      # mismatched count unit: the trusted identities then disagree over the
      # shared group, which must stay unattributable
      memory_profile = %{
        id: "db-connections",
        version: 1,
        reviewed: true,
        semantics: "gauge",
        unit: "bytes",
        query: "container_working_set",
        saturation_signal: "memory_working_set",
        capacity_policy: %{
          unit: "bytes",
          limits_verified: true,
          effective_threshold: 512 * 1_073_741_824
        }
      }

      config(Map.put(f, :source_a, prom_b), :a, %{
        kind: "prometheus",
        service_id: service["id"],
        profile: memory_profile
      })

      Tenancy.with_scope(f.scope_a, fn ->
        for h <- 23..0//-1 do
          at = DateTime.add(f.now, -h * 3600, :second)

          for {source, digest} <- [{prom_a, "series-a"}, {prom_b, "series-b"}] do
            Repo.query!(
              "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$6,$7)",
              [
                f.a.id,
                source.id,
                service["id"],
                "db-connections:v1",
                DateTime.add(at, -3600, :second),
                at,
                %{
                  "samples" => [
                    %{"value" => 100, "timestamp" => DateTime.to_unix(at), "series" => digest}
                  ],
                  "unit" => "count"
                }
              ]
            )
          end
        end
      end)

      # the disagreement is unattributable regardless of row order: no
      # connection labels, no pool guidance, mixed-identity unknown
      assert {:ok, data} = Insights.command(f.scope_a, f.now)
      assert [%{} = risk] = data.saturation
      assert risk.level == "unknown"
      assert risk.signal == nil

      assert risk.reasons == [
               "usage samples cannot be attributed to one series or source identity — no single volume history"
             ]
    end

    test "memory series dedupes to the freshest profile version", f do
      {:ok, prom} = Tenancy.create_source(f.scope_a, %{name: "memory-metrics", kind: :prometheus})
      env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

      {:ok, service} =
        Services.create(f.scope_a, %{
          source_id: prom.id,
          environment_id: env.id,
          service_key: "orders-db",
          target: "nw-eu/data/orders-db"
        })

      config(Map.put(f, :source_a, prom), :a, %{
        kind: "prometheus",
        service_id: service["id"],
        profile: %{
          id: "pod-memory",
          version: 1,
          reviewed: true,
          semantics: "gauge",
          unit: "bytes",
          query: "container_working_set",
          saturation_signal: "memory_working_set",
          capacity_policy: %{
            unit: "bytes",
            limits_verified: true,
            effective_threshold: 512 * 1_073_741_824
          }
        }
      })

      Tenancy.with_scope(f.scope_a, fn ->
        # an older v1 window and a newer v2 window for the same volume
        for {profile_key, hours_offset} <- [{"pod-memory:v1", 12}, {"pod-memory:v2", 2}] do
          at = DateTime.add(f.now, -hours_offset * 3600, :second)

          Repo.query!(
            "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$6,$7)",
            [
              f.a.id,
              prom.id,
              service["id"],
              profile_key,
              DateTime.add(at, -3600, :second),
              at,
              %{
                "samples" => [
                  %{
                    "value" => 400 * 1_073_741_824,
                    "timestamp" => DateTime.to_unix(at),
                    "series" => "memory"
                  }
                ],
                "unit" => "bytes"
              }
            ]
          )
        end
      end)

      assert {:ok, data} = Insights.command(f.scope_a, f.now)

      # one saturation risk from the freshest version only — no duplicates
      assert [%{} = risk] = data.saturation
      assert risk.volume == "pod-memory"
      assert risk.level == "unknown"
      assert_in_delta risk.value, 400.0, 0.001
    end
  end

  describe "verified count limits reach the views end to end" do
    test "a growing connection count surfaces as a critical saturation risk", f do
      c = put_count_config(f, %{}, %{saturation_signal: "connections"})
      insert_count_windows(f, c)

      assert {:ok, data} = Insights.command(f.scope_a, f.now)

      assert [%{} = risk] = data.saturation
      assert risk.volume == "db-connections"
      assert risk.service == "orders-db"
      assert risk.environment == "prod"
      assert risk.unit == "connections"
      assert risk.level == "critical"
      assert risk.abnormal
      assert_in_delta risk.value, 480.0, 0.001
      assert_in_delta risk.limit, 500.0, 0.001
      assert_in_delta risk.percent, 96.0, 0.001
      assert_in_delta risk.hours_to_full, 2.0, 0.01
      assert data.counts.predicted >= 1

      assert {:ok, page} = Insights.service(f.scope_a, "orders-db", "prod", f.now)

      assert [%{} = service_risk] = page.saturation
      assert service_risk.level == "critical"

      assert Enum.any?(page.checks, &String.contains?(&1, "Connections at 480/500"))
      assert Enum.any?(page.checks, &String.contains?(&1, "pool size"))
    end

    test "an unverified count limit stays unknown and suggests nothing", f do
      c = put_count_config(f, %{limits_verified: false})
      insert_count_windows(f, c)

      assert {:ok, data} = Insights.command(f.scope_a, f.now)
      assert [%{} = risk] = data.saturation
      assert risk.level == "unknown"
      assert risk.reasons == ["verified limit unavailable"]
      assert risk.limit == nil

      assert {:ok, page} = Insights.service(f.scope_a, "orders-db", "prod", f.now)
      assert [%{} = r] = page.saturation
      assert r.level == "unknown"
      refute Enum.any?(page.checks, &String.contains?(&1, "Connections at"))
    end

    test "no source config or a bytes-only policy never lends a limit", f do
      insert_count_windows(f, nil)

      assert {:ok, data} = Insights.command(f.scope_a, f.now)
      assert [%{} = risk] = data.saturation
      assert risk.level == "unknown"
      assert risk.reasons == ["verified limit unavailable"]

      # a verified BYTES policy must not lend a count limit
      put_count_config(f, %{unit: "bytes", effective_threshold: 500 * 1_073_741_824})

      assert {:ok, data2} = Insights.command(f.scope_a, f.now)
      assert [%{} = risk2] = data2.saturation
      assert risk2.level == "unknown"
      assert risk2.limit == nil
    end

    test "mixed series digests stay unattributable", f do
      put_count_config(f)

      Tenancy.with_scope(f.scope_a, fn ->
        for h <- 23..0//-1 do
          at = DateTime.add(f.now, -h * 3600, :second)
          series = if rem(h, 2) == 0, do: "digest-a", else: "digest-b"

          Repo.query!(
            "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$7,$8)",
            [
              f.a.id,
              f.prom.id,
              f.service_id,
              "db-connections:v1",
              DateTime.add(at, -3600, :second),
              at,
              at,
              %{
                "samples" => [
                  %{"value" => 100, "timestamp" => DateTime.to_unix(at), "series" => series}
                ],
                "unit" => "count"
              }
            ]
          )
        end
      end)

      assert {:ok, data} = Insights.command(f.scope_a, f.now)
      assert [%{} = risk] = data.saturation
      assert risk.level == "unknown"

      assert risk.reasons == [
               "usage samples cannot be attributed to one series or source identity — no single volume history"
             ]
    end

    test "count series stay tenant isolated", f do
      c = put_count_config(f)
      insert_count_windows(f, c)

      assert {:ok, other} = Insights.command(f.scope_b, f.now)
      assert other.saturation == []
    end
  end
end
