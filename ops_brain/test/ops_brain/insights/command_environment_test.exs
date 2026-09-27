defmodule OpsBrain.Insights.CommandEnvironmentTest do
  # Task 3.3: the command-center environment selection narrows services and
  # windows, runtime resources, capacity evaluations, the storage/saturation
  # series and the deployment runs behind pipeline health (recomputed from
  # the filtered runs). Unmapped provenance never inherits the selected
  # environment; prediction findings are attributed by their exact
  # prediction_target identity, not the scope-substring guess.
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures

  alias OpsBrain.{Insights, Repo, Services, Tenancy}

  @gib 1_073_741_824.0

  setup do
    on_exit(&cleanup/0)
    f = fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    env_prod = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))
    env_staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))

    # same service key and same cluster in both environments: only the actual
    # instance identity separates them
    {:ok, prom_prod} =
      Tenancy.create_source(f.scope_a, %{name: "metrics-prod", kind: :prometheus})

    {:ok, service_prod} =
      Services.create(f.scope_a, %{
        source_id: prom_prod.id,
        environment_id: env_prod.id,
        service_key: "orders-db",
        target: "nw-eu/data/orders-db"
      })

    {:ok, prom_staging} =
      Tenancy.create_source(f.scope_a, %{name: "metrics-staging", kind: :prometheus})

    {:ok, service_staging} =
      Services.create(f.scope_a, %{
        source_id: prom_staging.id,
        environment_id: env_staging.id,
        service_key: "orders-db",
        target: "nw-eu/data/orders-db"
      })

    for {source, service_id} <- [
          {prom_prod, service_prod["id"]},
          {prom_staging, service_staging["id"]}
        ] do
      config(Map.put(f, :source_a, source), :a, %{
        kind: "prometheus",
        service_id: service_id,
        profile: %{
          id: "storage",
          version: 1,
          reviewed: true,
          semantics: "gauge",
          unit: "bytes",
          query: "synthetic",
          capacity_policy: %{
            unit: "bytes",
            limits_verified: true,
            effective_threshold: 250 * 1_073_741_824
          }
        }
      })

      Tenancy.with_scope(f.scope_a, fn ->
        for h <- 23..0//-1 do
          used = 215.0 - 2.1 * min(h, 6) - 0.15 * max(h - 6, 0)
          at = DateTime.add(now, -h * 3600, :second)

          Repo.query!(
            "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$6,$7)",
            [
              f.a.id,
              source.id,
              service_id,
              "storage:v1",
              DateTime.add(at, -3600, :second),
              at,
              %{
                "samples" => [
                  %{
                    "value" => round(used * @gib),
                    "timestamp" => DateTime.to_unix(at),
                    "series" => "storage"
                  }
                ],
                "unit" => "bytes"
              }
            ]
          )
        end
      end)
    end

    # a verified count series on the PROD instance only: saturation must
    # filter with the same selection
    {:ok, prom_counts} =
      Tenancy.create_source(f.scope_a, %{name: "metrics-counts", kind: :prometheus})

    config(Map.put(f, :source_a, prom_counts), :a, %{
      kind: "prometheus",
      service_id: service_prod["id"],
      profile: %{
        id: "db-connections",
        version: 1,
        reviewed: true,
        semantics: "gauge",
        unit: "count",
        query: "pg_stat_activity_count",
        freshness_seconds: 600,
        capacity_policy: %{
          unit: "count",
          limits_verified: true,
          freshness_seconds: 600,
          max_gap_seconds: 120,
          min_history_seconds: 240,
          effective_threshold: 500,
          min_growth_bytes_per_second: 0.001,
          warning_horizon_seconds: 600,
          version: 1
        }
      }
    })

    Tenancy.with_scope(f.scope_a, fn ->
      for h <- 23..0//-1 do
        value = 480 - 10 * min(h, 6) - 1 * max(h - 6, 0)
        at = DateTime.add(now, -h * 3600, :second)

        Repo.query!(
          "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$7,$8)",
          [
            f.a.id,
            prom_counts.id,
            service_prod["id"],
            "db-connections:v1",
            DateTime.add(at, -3600, :second),
            at,
            at,
            %{
              "samples" => [
                %{
                  "value" => value,
                  "timestamp" => DateTime.to_unix(at),
                  "series" => "connections"
                }
              ],
              "unit" => "count"
            }
          ]
        )
      end
    end)

    # pipeline runs: two failed prod deploys, two succeeded staging deploys and
    # two unmapped CI-only failures
    {:ok, ado} = Tenancy.create_source(f.scope_a, %{name: "azure", kind: :azure_build})

    Tenancy.with_scope(f.scope_a, fn ->
      for {run_id, result, target_id} <- [
            {9501, "failed", service_prod["id"]},
            {9502, "failed", service_prod["id"]},
            {9503, "succeeded", service_staging["id"]},
            {9504, "succeeded", service_staging["id"]},
            {9505, "failed", nil},
            {9506, "failed", nil}
          ] do
        at = DateTime.add(now, -(run_id - 9500) * 600, :second)

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,7,'completed',$5,$6,$6,1,$7)",
          [
            f.a.id,
            ado.id,
            "00000000-0000-4000-8000-000000000020",
            run_id,
            result,
            at,
            %{"branch" => "main", "service" => "orders-db"}
          ]
        )

        if target_id do
          Repo.query!(
            "INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3,'deployment',$4,$4,$5,$6)",
            [
              f.a.id,
              ado.id,
              "deploy:#{run_id}",
              at,
              DateTime.add(at, 1, :day),
              %{
                "run_id" => run_id,
                "target_id" => target_id,
                "attempt" => 1,
                "reported_result" => "succeeded"
              }
            ]
          )
        end
      end

      # a worker-prediction-shaped finding on the staging instance: same scope
      # string as the prod namesake, distinct prediction_target identity
      Repo.query!(
        "INSERT INTO error_fingerprints(company_id,source_id,fingerprint,parser_version,data) VALUES($1::text::uuid,$2::text::uuid,$3,1,$4)",
        [
          f.a.id,
          ado.id,
          "env-test-fingerprint",
          %{
            "classification" => "prediction",
            "template" => "prediction:storage",
            "reason" => "forecast"
          }
        ]
      )

      Repo.query!(
        "INSERT INTO issue_groups(id,company_id,source_id,fingerprint,parser_version,first_seen,last_seen,severity,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,1,$5,$5,$6,$7)",
        [
          Ecto.UUID.generate(),
          f.a.id,
          ado.id,
          "env-test-fingerprint",
          DateTime.add(now, -300, :second),
          "critical",
          %{
            "template" => "prediction:storage:storage on nw-eu/data/orders-db",
            "scope" => "nw-eu/data/orders-db",
            "reason" => "storage growth forecast",
            "missing" => "No confirmed root cause",
            "count_basis" => "distinct forecast evaluations; conditional estimate",
            "prediction_target" => %{
              "service_instance_id" => service_staging["id"],
              "environment" => "staging",
              "target" => "nw-eu/data/orders-db"
            }
          }
        ]
      )
    end)

    Map.merge(f, %{
      now: now,
      ado: ado,
      prom_staging: prom_staging,
      service_prod_id: service_prod["id"],
      service_staging_id: service_staging["id"]
    })
  end

  test "prod filters storage and pipelines to the prod instances only", f do
    {:ok, data} = Insights.command(f.scope_a, "prod", f.now)

    # same service key, same cluster, same volume: only the actual prod
    # instance's series remains
    assert [%{} = prod] = data.storage
    assert prod.environment == "prod"
    assert prod.service_instance_id == f.service_prod_id

    # pipeline health is recomputed from the prod-deployed runs: two failed
    # runs are a critical streak; the unmapped CI-only failures never inherit
    # the selected environment
    assert [%{level: "critical", name: "orders-db", streak: 2}] = data.pipelines

    # the staging-targeted prediction finding is absent: its exact
    # prediction_target identity is not prod
    finding_items = Enum.filter(data.attention, &(&1.kind == "Finding"))
    assert finding_items == []

    # the pipeline attention item carries the selected environment
    assert [%{kind: "Pipeline", environment: "prod"}] =
             Enum.filter(data.attention, &(&1.kind == "Pipeline"))

    # saturation narrows with the same selection
    assert [%{} = saturation] = data.saturation
    assert saturation.environment == "prod"
  end

  test "staging filters storage and pipelines to the staging instance and its finding", f do
    {:ok, data} = Insights.command(f.scope_a, "staging", f.now)

    assert [%{} = staging] = data.storage
    assert staging.environment == "staging"
    assert staging.service_instance_id == f.service_staging_id

    # staging runs succeeded: the recomputed group is not critical
    assert [%{name: "orders-db"} = pipeline] = data.pipelines
    assert pipeline.level != "critical"

    # the prod-only count series is not staging's
    assert data.saturation == []

    # the finding appears with its exact staging identity — the scope string
    # matches both namesakes, prediction_target must win
    assert [%{kind: "Finding", environment: "staging", service: "orders-db"}] =
             Enum.filter(data.attention, &(&1.kind == "Finding"))
  end

  test "all keeps every environment and the name-level aggregate", f do
    {:ok, data} = Insights.command(f.scope_a, "", f.now)

    assert length(data.storage) == 2
    assert Enum.sort(Enum.map(data.storage, & &1.environment)) == ["prod", "staging"]

    # the command aggregate groups by name: one merged group across both
    # environments (pre-existing semantics untouched)
    assert [%{name: "orders-db"}] = data.pipelines

    assert [%{kind: "Finding", environment: "staging"}] =
             Enum.filter(data.attention, &(&1.kind == "Finding"))
  end

  test "dev has no services, series, runs or findings", f do
    {:ok, data} = Insights.command(f.scope_a, "dev", f.now)

    assert data.storage == []
    assert data.pipelines == []
    assert Enum.filter(data.attention, &(&1.kind == "Finding")) == []
    assert Enum.filter(data.attention, &(&1.kind == "Pipeline")) == []
  end

  test "newer staging runs beyond the run cap never hide prod pipeline health", f do
    # 301 staging-deployed runs, every one newer than the prod failures: a
    # globally bounded read would cap them out entirely
    Tenancy.with_scope(f.scope_a, fn ->
      for i <- 1..301 do
        run_id = 10000 + i
        at = DateTime.add(f.now, -i, :second)

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,7,'completed','succeeded',$5,$5,1,$6)",
          [
            f.a.id,
            f.ado.id,
            "00000000-0000-4000-8000-000000000020",
            run_id,
            at,
            %{"branch" => "main", "service" => "orders-db"}
          ]
        )

        Repo.query!(
          "INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3,'deployment',$4,$4,$5,$6)",
          [
            f.a.id,
            f.ado.id,
            "deploy:#{run_id}",
            at,
            DateTime.add(at, 1, :day),
            %{
              "run_id" => run_id,
              "target_id" => f.service_staging_id,
              "attempt" => 1,
              "reported_result" => "succeeded"
            }
          ]
        )
      end
    end)

    assert {:ok, data} = Insights.command(f.scope_a, "prod", f.now)

    # the prod environment's own bounded read still contains its failures
    assert [%{name: "orders-db", level: "critical", streak: 2}] = data.pipelines
  end

  test "newer other-environment windows beyond the read cap never hide prod history", f do
    # 2000 staging byte windows and 2000 staging count windows inside the
    # newest hour: globally bounded reads would keep almost none of prod's
    # history; the environment-selected reads keep all of it
    Tenancy.with_scope(f.scope_a, fn ->
      for i <- 1..2000 do
        at = DateTime.add(f.now, -(i * 1500), :millisecond)

        Repo.query!(
          "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$6,$7)",
          [
            f.a.id,
            f.prom_staging.id,
            f.service_staging_id,
            "storage:v1",
            DateTime.add(at, -60, :second),
            at,
            %{
              "samples" => [
                %{
                  "value" => 100 * @gib,
                  "timestamp" => DateTime.to_unix(at),
                  "series" => "storage"
                }
              ],
              "unit" => "bytes"
            }
          ]
        )

        Repo.query!(
          "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$6,$7)",
          [
            f.a.id,
            f.prom_staging.id,
            f.service_staging_id,
            "db-connections:v1",
            DateTime.add(at, -60, :second),
            at,
            %{
              "samples" => [
                %{"value" => 100, "timestamp" => DateTime.to_unix(at), "series" => "connections"}
              ],
              "unit" => "count"
            }
          ]
        )
      end
    end)

    assert {:ok, data} = Insights.command(f.scope_a, "prod", f.now)

    assert [%{} = storage] = data.storage
    assert length(storage.history) == 24

    assert [%{} = saturation] = data.saturation
    assert length(saturation.history) == 24
  end

  test "a mixed-service multi-environment run groups only under its actual environment",
       f do
    env_prod = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))
    env_staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))

    {:ok, s_checkout} =
      Services.create(f.scope_a, %{
        source_id: f.ado.id,
        environment_id: env_prod.id,
        service_key: "checkout-api",
        target: "nw-eu/data/checkout-api"
      })

    {:ok, s_billing} =
      Services.create(f.scope_a, %{
        source_id: f.ado.id,
        environment_id: env_staging.id,
        service_key: "billing-api",
        target: "nw-eu/data/billing-api"
      })

    # each failed run deploys to BOTH services: one prod target, one staging
    Tenancy.with_scope(f.scope_a, fn ->
      for run_id <- [9901, 9902] do
        at = DateTime.add(f.now, -(run_id - 9900) * 600, :second)

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,7,'completed','failed',$5,$5,1,$6)",
          [
            f.a.id,
            f.ado.id,
            "00000000-0000-4000-8000-000000000020",
            run_id,
            at,
            %{"branch" => "main", "service" => "checkout-api"}
          ]
        )

        for target_id <- [s_checkout["id"], s_billing["id"]] do
          Repo.query!(
            "INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3,'deployment',$4,$4,$5,$6)",
            [
              f.a.id,
              f.ado.id,
              "deploy:#{run_id}:#{target_id}",
              at,
              DateTime.add(at, 1, :day),
              %{
                "run_id" => run_id,
                "target_id" => target_id,
                "attempt" => 1,
                "reported_result" => "succeeded"
              }
            ]
          )
        end
      end
    end)

    assert {:ok, prod} = Insights.command(f.scope_a, "prod", f.now)

    # the prod view groups these runs only under the prod-deployed service;
    # their staging mappings never leak into a prod service group
    assert [%{name: "checkout-api", level: "critical", streak: 2}] =
             Enum.filter(prod.pipelines, &(&1.name in ["checkout-api", "billing-api"]))

    assert {:ok, staging} = Insights.command(f.scope_a, "staging", f.now)

    assert [%{name: "billing-api", level: "critical", streak: 2}] =
             Enum.filter(staging.pipelines, &(&1.name in ["checkout-api", "billing-api"]))

    # under All both real service groups keep the shared aggregate runs
    assert {:ok, all} = Insights.command(f.scope_a, "", f.now)

    assert ["billing-api", "checkout-api"] =
             all.pipelines
             |> Enum.filter(&(&1.name in ["checkout-api", "billing-api"]))
             |> Enum.map(& &1.name)
             |> Enum.sort()
  end

  test "an invalid environment fails closed instead of leaking everything", f do
    assert {:error, :invalid_environment} = Insights.command(f.scope_a, "production", f.now)
  end

  test "legacy scopes resolve exactly; ambiguity stays unknown", f do
    env_prod = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))
    env_staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))

    # cluster-prefix collision: eu and eu-west are distinct clusters with the
    # same service name in different environments
    {:ok, _s_eu} =
      Services.create(f.scope_a, %{
        source_id: f.ado.id,
        environment_id: env_prod.id,
        service_key: "orders-db",
        target: "eu/data/orders-db"
      })

    {:ok, _s_west} =
      Services.create(f.scope_a, %{
        source_id: f.ado.id,
        environment_id: env_staging.id,
        service_key: "orders-db",
        target: "eu-west/data/orders-db"
      })

    Tenancy.with_scope(f.scope_a, fn ->
      for {fp, scope} <- [
            {"fp-ambiguous", "nw-eu/data/orders-db"},
            {"fp-west", "eu-west/data/orders-db"},
            {"fp-eu", "eu/data/orders-db"}
          ] do
        Repo.query!(
          "INSERT INTO error_fingerprints(company_id,source_id,fingerprint,parser_version,data) VALUES($1::text::uuid,$2::text::uuid,$3,1,$4)",
          [
            f.a.id,
            f.ado.id,
            fp,
            %{"classification" => "legacy", "template" => scope, "reason" => "legacy finding"}
          ]
        )

        Repo.query!(
          "INSERT INTO issue_groups(id,company_id,source_id,fingerprint,parser_version,first_seen,last_seen,severity,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,1,$5,$5,$6,$7)",
          [
            Ecto.UUID.generate(),
            f.a.id,
            f.ado.id,
            fp,
            DateTime.add(f.now, -300, :second),
            "critical",
            %{"template" => "legacy #{scope}", "scope" => scope, "reason" => "legacy finding"}
          ]
        )
      end
    end)

    assert {:ok, prod} = Insights.command(f.scope_a, "prod", f.now)
    assert {:ok, staging} = Insights.command(f.scope_a, "staging", f.now)
    assert {:ok, all} = Insights.command(f.scope_a, "", f.now)

    titles = fn data ->
      data.attention |> Enum.filter(&(&1.kind == "Finding")) |> Enum.map(& &1.title)
    end

    # the eu-cluster legacy finding is prod's by exact cluster segment
    assert "legacy eu/data/orders-db" in titles.(prod)
    refute "legacy eu-west/data/orders-db" in titles.(prod)
    # the prefix-colliding eu-west scope is staging's, not inferred as prod's
    assert "legacy eu-west/data/orders-db" in titles.(staging)
    refute "legacy eu/data/orders-db" in titles.(staging)

    # the same-cluster nw-eu scope matches both environments: unassigned in
    # every selected view, never guessed from the selection
    refute "legacy nw-eu/data/orders-db" in titles.(prod)
    refute "legacy nw-eu/data/orders-db" in titles.(staging)

    # under All it appears with its unknown environment kept
    assert [%{environment: nil}] =
             Enum.filter(
               all.attention,
               &(&1.kind == "Finding" and &1.title == "legacy nw-eu/data/orders-db")
             )
  end
end
