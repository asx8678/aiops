defmodule OpsBrain.PredictionWorkerTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures

  alias OpsBrain.{Insights, Issues, Repo, Services, Store, Tenancy}
  alias OpsBrain.PredictionWorker

  @gib 1_073_741_824.0

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

    c =
      config(Map.put(f, :source_a, prom), :a, %{
        kind: "prometheus",
        service_id: service["id"],
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

    Map.merge(f, %{now: now, prom: prom, service_id: service["id"], c: c})
  end

  defp insert_history(f, source, service_id, growth) do
    Tenancy.with_scope(f.scope_a, fn ->
      for h <- 23..0//-1 do
        used =
          case growth do
            :jump -> 215.0 - 2.1 * min(h, 6) - 0.15 * max(h - 6, 0)
            :flat -> 100.0
          end

        at = DateTime.add(f.now, -h * 3600, :second)

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

  defp insert_history(f, growth), do: insert_history(f, f.prom, f.service_id, growth)

  test "the switch must be literally true; malformed values fail closed", f do
    insert_history(f, :jump)

    for bad <- ["false", "true", 0, 1, :on] do
      Application.put_env(:ops_brain, :prediction_enabled, bad)
      assert :disabled = PredictionWorker.run(f.now)
      assert :discard = PredictionWorker.perform(%Oban.Job{args: %{}})
    end

    Application.delete_env(:ops_brain, :prediction_enabled)
    assert :disabled = PredictionWorker.run(f.now)
    assert {:ok, []} = Issues.list(f.scope_a)
  end

  test "worker argument shape is bounded", _f do
    assert :discard = PredictionWorker.perform(%Oban.Job{args: %{"source_id" => "x"}})
  end

  test "a disabled lower-id config never skips the company or mislabels origin", f do
    # an unrelated DISABLED config with a lexicographically smaller id
    disabled =
      Map.merge(f.c, %{
        id: "00000000-0000-0000-0000-000000000001",
        kind: "azure_build",
        enabled: false,
        definitions: [7],
        organization: "synthetic",
        project_id: "00000000-0000-4000-8000-000000000020",
        service_id: nil,
        profile: nil
      })

    Application.put_env(
      :ops_brain,
      :sources,
      Map.put(OpsBrain.SourceConfig.all(), disabled.id, disabled)
    )

    Application.put_env(:ops_brain, :prediction_enabled, true)

    insert_history(f, :jump)
    assert :ok = PredictionWorker.run(f.now)

    assert {:ok, [%{} = group]} = Issues.list(f.scope_a)

    # evidence records under the source that actually produced the data
    assert group["data"]["template"] =~ "prediction:storage:storage on nw-eu/data/orders-db"

    # evidence_items are company-scoped (RLS): read under the authorized scope
    {:ok, [row]} =
      Tenancy.with_scope(f.scope_a, fn ->
        Store.rows(
          "SELECT DISTINCT source_id::text FROM evidence_items WHERE kind='prediction' LIMIT 1"
        )
      end)

    assert row["source_id"] == f.prom.id
  end

  test "two runs refresh one group while critical; recovery freezes last_seen", f do
    insert_history(f, :jump)
    Application.put_env(:ops_brain, :prediction_enabled, true)

    assert :ok = PredictionWorker.run(f.now)
    assert {:ok, [%{} = group]} = Issues.list(f.scope_a)
    assert group["severity"] == "critical"
    assert group["data"]["scope"] == "nw-eu/data/orders-db"
    first_seen = group["first_seen"]
    last_seen = group["last_seen"]

    # storage evidence carries the structured target identity as well
    {:ok, [ev]} =
      Tenancy.with_scope(f.scope_a, fn ->
        Store.rows("SELECT data FROM evidence_items WHERE kind='prediction' LIMIT 1")
      end)

    assert ev["data"]["service_instance_id"] == f.service_id

    assert ev["data"]["prediction_target"]["service_instance_id"] == f.service_id
    assert ev["data"]["prediction_target"]["environment"] == "prod"

    t2 = DateTime.add(f.now, 600, :second)
    assert :ok = PredictionWorker.run(t2)
    assert {:ok, [%{} = group2]} = Issues.list(f.scope_a)
    assert group2["id"] == group["id"]
    assert DateTime.compare(group2["first_seen"], first_seen) == :eq
    assert DateTime.compare(group2["last_seen"], last_seen) == :gt

    Tenancy.with_scope(f.scope_a, fn ->
      Repo.query!("DELETE FROM observation_windows WHERE company_id=$1::text::uuid", [f.a.id])
    end)

    insert_history(f, :flat)
    t3 = DateTime.add(f.now, 1200, :second)
    assert :ok = PredictionWorker.run(t3)
    assert {:ok, [%{} = group3]} = Issues.list(f.scope_a)
    assert group3["id"] == group["id"]
    assert DateTime.compare(group3["last_seen"], group2["last_seen"]) == :eq
  end

  test "same company, same names, two clusters never merge; per-target recovery", f do
    # second service instance on another cluster with the SAME service key,
    # environment and volume name, fed by its own source
    {:ok, prom_beta} =
      Tenancy.create_source(f.scope_a, %{name: "metrics-beta", kind: :prometheus})

    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    {:ok, service_beta} =
      Services.create(f.scope_a, %{
        source_id: prom_beta.id,
        environment_id: env.id,
        service_key: "orders-db",
        target: "beta-cluster/data/orders-db"
      })

    config(Map.put(f, :source_a, prom_beta), :a, %{
      kind: "prometheus",
      service_id: service_beta["id"],
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

    insert_history(f, :jump)
    insert_history(f, prom_beta, service_beta["id"], :jump)

    Application.put_env(:ops_brain, :prediction_enabled, true)
    assert :ok = PredictionWorker.run(f.now)

    assert {:ok, groups} = Issues.list(f.scope_a)
    assert length(groups) == 2
    targets = Enum.map(groups, & &1["data"]["scope"])
    assert "nw-eu/data/orders-db" in targets
    assert "beta-cluster/data/orders-db" in targets
    assert Enum.count(Enum.uniq(targets)) == 2

    # repeated run stays idempotent per target
    assert :ok = PredictionWorker.run(DateTime.add(f.now, 300, :second))
    assert {:ok, groups2} = Issues.list(f.scope_a)
    assert length(groups2) == 2

    # alpha recovers; beta stays critical: only beta refreshes
    Tenancy.with_scope(f.scope_a, fn ->
      Repo.query!(
        "DELETE FROM observation_windows WHERE company_id=$1::text::uuid AND source_id=$2::text::uuid",
        [f.a.id, f.prom.id]
      )
    end)

    insert_history(f, :flat)

    t3 = DateTime.add(f.now, 900, :second)
    assert :ok = PredictionWorker.run(t3)

    assert {:ok, groups3} = Issues.list(f.scope_a)
    assert length(groups3) == 2

    beta = Enum.find(groups3, &(&1["data"]["scope"] == "beta-cluster/data/orders-db"))
    alpha = Enum.find(groups3, &(&1["data"]["scope"] == "nw-eu/data/orders-db"))

    beta_before = Enum.find(groups2, &(&1["data"]["scope"] == "beta-cluster/data/orders-db"))
    assert DateTime.compare(beta["last_seen"], beta_before["last_seen"]) == :gt

    assert DateTime.compare(
             alpha["last_seen"],
             Enum.find(groups2, &(&1["data"]["scope"] == alpha["data"]["scope"]))["last_seen"]
           ) == :eq
  end

  test "prediction findings appear on their own troubleshoot page", f do
    insert_history(f, :jump)
    Application.put_env(:ops_brain, :prediction_enabled, true)
    assert :ok = PredictionWorker.run(f.now)

    assert {:ok, page} = Insights.service(f.scope_a, "orders-db", "prod", f.now)

    assert Enum.any?(
             page.findings,
             &String.contains?(get_in(&1, ["data", "template"]), "prediction:storage:")
           )

    # another service's page never shows the volume prediction
    {:ok, _other} =
      Services.create(f.scope_a, %{
        source_id: f.prom.id,
        environment_id: Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod)).id,
        service_key: "billing-api",
        target: "nw-eu/data/billing-api"
      })

    assert {:ok, billing} = Insights.service(f.scope_a, "billing-api", "prod", f.now)

    refute Enum.any?(
             billing.findings,
             &String.contains?(get_in(&1, ["data", "template"]), "prediction:")
           )
  end

  test "pipeline predictions persist per environment with distinct identity", f do
    staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))

    # the setup already maps orders-db prod; add the staging namesake
    {:ok, service_staging} =
      Services.create(f.scope_a, %{
        source_id: f.prom.id,
        environment_id: staging.id,
        service_key: "orders-db",
        target: "staging-eu/data/orders-db"
      })

    Tenancy.with_scope(f.scope_a, fn ->
      for {service, env_name} <- [{%{"id" => f.service_id}, "prod"}, {service_staging, "staging"}],
          {run_id, at} <- [
            {9201, DateTime.add(f.now, -1800, :second)},
            {9202, DateTime.add(f.now, -1200, :second)},
            {9203, DateTime.add(f.now, -600, :second)}
          ] do
        Repo.query!(
          "INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3,'deployment',$4,$4,$5,$6)",
          [
            f.a.id,
            f.prom.id,
            "deploy:orders:#{env_name}:#{run_id}",
            at,
            DateTime.add(at, 1, :day),
            %{
              "run_id" => run_id,
              "target_id" => service["id"],
              "attempt" => 1,
              "reported_result" => "succeeded"
            }
          ]
        )
      end

      for h <- 1..3 do
        at = DateTime.add(f.now, -h * 600, :second)

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,7,'completed','failed',$5,$5,1,$6)",
          [
            f.a.id,
            f.prom.id,
            "00000000-0000-4000-8000-000000000020",
            9200 + h,
            at,
            %{"branch" => "main", "service" => "orders-db"}
          ]
        )
      end
    end)

    Application.put_env(:ops_brain, :prediction_enabled, true)
    assert :ok = PredictionWorker.run(f.now)

    assert {:ok, groups} = Issues.list(f.scope_a)

    pipeline_groups =
      Enum.filter(groups, &String.contains?(&1["data"]["template"], "prediction:pipeline:"))

    assert length(pipeline_groups) == 2

    assert Enum.any?(
             pipeline_groups,
             &String.contains?(&1["data"]["template"], "definition 7, prod")
           )

    assert Enum.any?(
             pipeline_groups,
             &String.contains?(&1["data"]["template"], "definition 7, staging")
           )
  end

  test "CI-only runs never spread to known targets and keep their own identity", f do
    # failed runs mapped by name only (no deployment evidence) -> CI-only partition
    Tenancy.with_scope(f.scope_a, fn ->
      for h <- 1..2 do
        at = DateTime.add(f.now, -h * 600, :second)

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,9,'completed','failed',$5,$5,1,$6)",
          [
            f.a.id,
            f.prom.id,
            "00000000-0000-4000-8000-000000000020",
            9300 + h,
            at,
            %{"branch" => "main", "service" => "orders-db"}
          ]
        )
      end
    end)

    Application.put_env(:ops_brain, :prediction_enabled, true)
    assert :ok = PredictionWorker.run(f.now)

    assert {:ok, [ci]} = Issues.list(f.scope_a)
    assert String.contains?(ci["data"]["template"], "CI-only")
    # the CI-only finding has no structured target: never on any service page
    assert ci["data"]["prediction_target"] == nil
    assert {:ok, page} = Insights.service(f.scope_a, "orders-db", "prod", f.now)
    refute Enum.any?(page.findings, &String.contains?(&1["data"]["template"], "CI-only"))
  end

  test "prod-critical/staging-healthy partitions persist only the prod finding", f do
    staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))

    {:ok, staging_service} =
      Services.create(f.scope_a, %{
        source_id: f.prom.id,
        environment_id: staging.id,
        service_key: "orders-db",
        target: "staging-eu/data/orders-db"
      })

    Tenancy.with_scope(f.scope_a, fn ->
      # prod partition: 2 failed runs with prod deployment evidence
      for h <- 1..2 do
        run = 9400 + h
        at = DateTime.add(f.now, -h * 600, :second)

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,7,'completed','failed',$5,$5,1,$6)",
          [
            f.a.id,
            f.prom.id,
            "00000000-0000-4000-8000-000000000020",
            run,
            at,
            %{"branch" => "main", "service" => "orders-db"}
          ]
        )

        Repo.query!(
          "INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3,'deployment',$4,$4,$5,$6)",
          [
            f.a.id,
            f.prom.id,
            "deploy:prod:#{run}",
            at,
            DateTime.add(at, 1, :day),
            %{
              "run_id" => run,
              "target_id" => f.service_id,
              "attempt" => 1,
              "reported_result" => "succeeded"
            }
          ]
        )
      end

      # staging partition: 2 succeeded runs with staging deployment evidence
      for h <- 1..2 do
        run = 9410 + h
        at = DateTime.add(f.now, -h * 500, :second)

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,7,'completed','succeeded',$5,$5,1,$6)",
          [
            f.a.id,
            f.prom.id,
            "00000000-0000-4000-8000-000000000020",
            run,
            at,
            %{"branch" => "main", "service" => "orders-db"}
          ]
        )

        Repo.query!(
          "INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3,'deployment',$4,$4,$5,$6)",
          [
            f.a.id,
            f.prom.id,
            "deploy:staging:#{run}",
            at,
            DateTime.add(at, 1, :day),
            %{
              "run_id" => run,
              "target_id" => staging_service["id"],
              "attempt" => 1,
              "reported_result" => "succeeded"
            }
          ]
        )
      end
    end)

    Application.put_env(:ops_brain, :prediction_enabled, true)
    assert :ok = PredictionWorker.run(f.now)

    # only the prod pipeline prediction exists; healthy staging never fabricates a finding
    assert {:ok, groups} = Issues.list(f.scope_a)
    assert [%{} = prod] = groups
    assert String.contains?(prod["data"]["template"], "definition 7, prod")
  end

  test "a critical count saturation persists with its own identity and exact target", f do
    # the source carries a verified count profile instead of storage
    config(Map.put(f, :source_a, f.prom), :a, %{
      kind: "prometheus",
      service_id: f.service_id,
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

    Application.put_env(:ops_brain, :prediction_enabled, true)
    assert :ok = PredictionWorker.run(f.now)

    assert {:ok, [%{} = group]} = Issues.list(f.scope_a)
    assert group["severity"] == "critical"
    assert group["data"]["scope"] == "nw-eu/data/orders-db"
    assert String.contains?(group["data"]["template"], "prediction:saturation:")

    target = group["data"]["prediction_target"]
    assert target["service_instance_id"] == f.service_id
    assert target["environment"] == "prod"
    assert target["target"] == "nw-eu/data/orders-db"

    # the finding is visible on its own service page by exact identity
    assert {:ok, page} = Insights.service(f.scope_a, "orders-db", "prod", f.now)
    assert Enum.any?(page.findings, &(&1["id"] == group["id"]))
  end

  test "same-name/same-env targets in distinct clusters partition by actual target", f do
    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    {:ok, service_eu} =
      Services.create(f.scope_a, %{
        source_id: f.prom.id,
        environment_id: env.id,
        service_key: "orders-db",
        target: "eu/data/orders-db"
      })

    {:ok, service_west} =
      Services.create(f.scope_a, %{
        source_id: f.prom.id,
        environment_id: env.id,
        service_key: "orders-db",
        target: "eu-west/data/orders-db"
      })

    Tenancy.with_scope(f.scope_a, fn ->
      # two failed runs per target; the deployment evidence carries the
      # ACTUAL instance ids, which is what the partitions must retain
      for {run_id, target_id} <- [
            {9601, service_eu["id"]},
            {9602, service_eu["id"]},
            {9603, service_west["id"]},
            {9604, service_west["id"]}
          ] do
        at = DateTime.add(f.now, -(run_id - 9600) * 600, :second)

        Repo.query!(
          "INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3,'deployment',$4,$4,$5,$6)",
          [
            f.a.id,
            f.prom.id,
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

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,7,'completed','failed',$5,$5,1,$6)",
          [
            f.a.id,
            f.prom.id,
            "00000000-0000-4000-8000-000000000020",
            run_id,
            at,
            %{"branch" => "main", "service" => "orders-db"}
          ]
        )
      end
    end)

    Application.put_env(:ops_brain, :prediction_enabled, true)
    assert :ok = PredictionWorker.run(f.now)

    assert {:ok, groups} = Issues.list(f.scope_a)
    assert length(groups) == 2

    # each partition carries its own structured target identity: the actual
    # deployment instance, not a name/environment lookup
    targets = Enum.map(groups, & &1["data"]["prediction_target"])
    eu = Enum.find(targets, &(&1["service_instance_id"] == service_eu["id"]))
    west = Enum.find(targets, &(&1["service_instance_id"] == service_west["id"]))

    # the eu partition carries the eu instance, the eu-west partition the
    # eu-west instance — never the first name/environment match
    assert eu["target"] == "eu/data/orders-db"
    assert west["target"] == "eu-west/data/orders-db"
    assert Enum.count(Enum.uniq(Enum.map(targets, & &1["service_instance_id"]))) == 2

    # the read path filters by exact instance: on whichever same-named page,
    # only that instance's findings appear — no cluster-prefix leak
    {:ok, page} = Insights.service(f.scope_a, "orders-db", "prod", f.now)

    expected =
      Enum.count(
        groups,
        &(&1["data"]["prediction_target"]["service_instance_id"] == page.instance["id"])
      )

    assert length(page.findings) == expected

    for finding <- page.findings do
      assert finding["data"]["prediction_target"]["service_instance_id"] == page.instance["id"]
    end
  end

  test "identical definition ids from two sources persist as distinct groups", f do
    {:ok, ado_beta} =
      Tenancy.create_source(f.scope_a, %{name: "build-beta", kind: :azure_build})

    config(Map.put(f, :source_a, ado_beta), :a, %{
      kind: "azure_build",
      service_id: nil,
      profile: nil
    })

    Tenancy.with_scope(f.scope_a, fn ->
      for {source, base} <- [{f.prom, 9700}, {ado_beta, 9710}] do
        for h <- 1..2 do
          run_id = base + h
          at = DateTime.add(f.now, -h * 600, :second)

          Repo.query!(
            "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,7,'completed','failed',$5,$5,1,$6)",
            [
              f.a.id,
              source.id,
              "00000000-0000-4000-8000-000000000020",
              run_id,
              at,
              %{"branch" => "main", "service" => "orders-db"}
            ]
          )
        end
      end
    end)

    Application.put_env(:ops_brain, :prediction_enabled, true)
    assert :ok = PredictionWorker.run(f.now)

    assert {:ok, groups} = Issues.list(f.scope_a)
    assert length(groups) == 2

    # each group's evidence is attributed to the source that actually
    # produced its runs — same definition id never merges the two sources
    {:ok, provenance} =
      Tenancy.with_scope(f.scope_a, fn ->
        Store.rows(
          "SELECT f.group_id::text, e.source_id::text FROM failure_occurrences f JOIN evidence_items e ON e.id=f.evidence_id AND e.company_id=e.company_id WHERE f.company_id=$1::text::uuid",
          [f.a.id]
        )
      end)

    assert length(provenance) == 2

    assert Enum.sort([f.prom.id, ado_beta.id]) ==
             Enum.sort(Enum.map(provenance, & &1["source_id"]))
  end

  test "per-target pipeline recovery freezes only the recovered target", f do
    staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))

    {:ok, service_staging} =
      Services.create(f.scope_a, %{
        source_id: f.prom.id,
        environment_id: staging.id,
        service_key: "orders-db",
        target: "staging-eu/data/orders-db"
      })

    Tenancy.with_scope(f.scope_a, fn ->
      for {run_id, target_id} <- [
            {9801, f.service_id},
            {9802, f.service_id},
            {9803, service_staging["id"]},
            {9804, service_staging["id"]}
          ] do
        at = DateTime.add(f.now, -(run_id - 9800) * 600, :second)

        Repo.query!(
          "INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3,'deployment',$4,$4,$5,$6)",
          [
            f.a.id,
            f.prom.id,
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

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,7,'completed','failed',$5,$5,1,$6)",
          [
            f.a.id,
            f.prom.id,
            "00000000-0000-4000-8000-000000000020",
            run_id,
            at,
            %{"branch" => "main", "service" => "orders-db"}
          ]
        )
      end
    end)

    Application.put_env(:ops_brain, :prediction_enabled, true)
    assert :ok = PredictionWorker.run(f.now)
    assert {:ok, groups} = Issues.list(f.scope_a)
    assert length(groups) == 2

    t2 = DateTime.add(f.now, 600, :second)
    assert :ok = PredictionWorker.run(t2)
    assert {:ok, groups2} = Issues.list(f.scope_a)
    assert length(groups2) == 2

    prod2 = Enum.find(groups2, &String.contains?(&1["data"]["template"], "definition 7, prod"))

    staging2 =
      Enum.find(groups2, &String.contains?(&1["data"]["template"], "definition 7, staging"))

    # staging recovers with a newer succeeded run while prod stays critical
    Tenancy.with_scope(f.scope_a, fn ->
      at = DateTime.add(f.now, 700, :second)

      Repo.query!(
        "INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3,'deployment',$4,$4,$5,$6)",
        [
          f.a.id,
          f.prom.id,
          "deploy:9805",
          at,
          DateTime.add(at, 1, :day),
          %{
            "run_id" => 9805,
            "target_id" => service_staging["id"],
            "attempt" => 1,
            "reported_result" => "succeeded"
          }
        ]
      )

      Repo.query!(
        "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,7,'completed','succeeded',$5,$5,1,$6)",
        [
          f.a.id,
          f.prom.id,
          "00000000-0000-4000-8000-000000000020",
          9805,
          at,
          %{"branch" => "main", "service" => "orders-db"}
        ]
      )
    end)

    t3 = DateTime.add(f.now, 1200, :second)
    assert :ok = PredictionWorker.run(t3)
    assert {:ok, groups3} = Issues.list(f.scope_a)

    prod3 = Enum.find(groups3, &String.contains?(&1["data"]["template"], "definition 7, prod"))

    staging3 =
      Enum.find(groups3, &String.contains?(&1["data"]["template"], "definition 7, staging"))

    # prod stays critical and keeps refreshing; the recovered staging
    # group's last_seen is frozen at its last critical observation
    assert DateTime.compare(prod3["last_seen"], prod2["last_seen"]) == :gt
    assert DateTime.compare(staging3["last_seen"], staging2["last_seen"]) == :eq
  end

  test "a same-cluster staging prediction never appears on the prod page", f do
    staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))

    # its own source and identity-matched config, so the series is trusted
    {:ok, prom_staging} =
      Tenancy.create_source(f.scope_a, %{name: "metrics-staging", kind: :prometheus})

    {:ok, service_staging} =
      Services.create(f.scope_a, %{
        source_id: prom_staging.id,
        environment_id: staging.id,
        service_key: "orders-db",
        target: "nw-eu/data/orders-db"
      })

    config(Map.put(f, :source_a, prom_staging), :a, %{
      kind: "prometheus",
      service_id: service_staging["id"],
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

    insert_history(f, prom_staging, service_staging["id"], :jump)

    Application.put_env(:ops_brain, :prediction_enabled, true)
    assert :ok = PredictionWorker.run(f.now)

    assert {:ok, [%{} = group]} = Issues.list(f.scope_a)

    # stored identity points at the staging instance in the same cluster
    assert group["data"]["prediction_target"]["service_instance_id"] == service_staging["id"]
    assert group["data"]["prediction_target"]["environment"] == "staging"

    assert {:ok, staging_page} = Insights.service(f.scope_a, "orders-db", "staging", f.now)
    assert Enum.any?(staging_page.findings, &(&1["id"] == group["id"]))

    # same cluster, same service key: the scope substring would match the
    # prod page too — only the exact identity filter keeps it off
    assert {:ok, prod_page} = Insights.service(f.scope_a, "orders-db", "prod", f.now)
    refute Enum.any?(prod_page.findings, &(&1["id"] == group["id"]))
  end

  test "same volume name in another company yields a different fingerprint", f do
    {:ok, prom_b} = Tenancy.create_source(f.scope_b, %{name: "metrics", kind: :prometheus})
    env_b = Enum.find(f.envs, &(&1.company_id == f.b.id and &1.name == :prod))

    {:ok, service_b} =
      Services.create(f.scope_b, %{
        source_id: prom_b.id,
        environment_id: env_b.id,
        service_key: "orders-db",
        target: "other/data/orders-db"
      })

    config(Map.put(f, :source_b, prom_b), :b, %{
      kind: "prometheus",
      service_id: service_b["id"],
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

    insert_history(f, :jump)

    Tenancy.with_scope(f.scope_b, fn ->
      for h <- 23..0//-1 do
        used = 215.0 - 2.1 * min(h, 6) - 0.15 * max(h - 6, 0)
        at = DateTime.add(f.now, -h * 3600, :second)

        Repo.query!(
          "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$6,$7)",
          [
            f.b.id,
            prom_b.id,
            service_b["id"],
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

    Application.put_env(:ops_brain, :prediction_enabled, true)
    assert :ok = PredictionWorker.run(f.now)

    assert {:ok, [%{} = group_a]} = Issues.list(f.scope_a)
    assert {:ok, [%{} = group_b]} = Issues.list(f.scope_b)
    assert group_a["id"] != group_b["id"]

    fp = fn scope ->
      Tenancy.with_scope(scope, fn ->
        Store.rows("SELECT fingerprint FROM issue_groups ORDER BY id LIMIT 1")
      end)
    end

    {:ok, [%{"fingerprint" => fp_a}]} = fp.(f.scope_a)
    {:ok, [%{"fingerprint" => fp_b}]} = fp.(f.scope_b)
    assert fp_a != fp_b
  end

  test "the scheduler enqueues the worker only while literally enabled", _f do
    for bad <- [false, "true", 1] do
      Application.put_env(:ops_brain, :prediction_enabled, bad)
      send(OpsBrain.Scheduler, :prediction)
      :sys.get_state(OpsBrain.Scheduler)
    end

    assert Repo.query!("SELECT count(*) FROM oban_jobs WHERE worker='OpsBrain.PredictionWorker'").rows ==
             [[0]]

    Application.put_env(:ops_brain, :prediction_enabled, true)
    on_exit(fn -> Application.delete_env(:ops_brain, :prediction_enabled) end)

    send(OpsBrain.Scheduler, :prediction)
    :sys.get_state(OpsBrain.Scheduler)

    assert Repo.query!("SELECT count(*) FROM oban_jobs WHERE worker='OpsBrain.PredictionWorker'").rows ==
             [[1]]

    assert OpsBrain.Scheduler.prediction_interval() == 300_000
  end

  for kind <- ~w(storage saturation pipeline pipeline-ci) do
    test "#{kind} forecast evaluations respect closure and episode gaps", f do
      prepare_prediction(f, unquote(kind))
      Application.put_env(:ops_brain, :prediction_enabled, true)

      assert :ok = PredictionWorker.run(f.now)
      group = only_group(f)
      assert_kind(group, unquote(kind))
      fingerprint = group_fingerprint(f, group["id"])
      target = group["data"]["prediction_target"]

      if unquote(kind) == "pipeline-ci" do
        assert target == nil
      else
        assert target["service_instance_id"] == f.service_id
      end

      assert group["data"]["count_basis"] == "distinct forecast evaluations; conditional estimate"
      assert occurrences(f, group["id"]) == 1
      first_rows = occurrence_rows(f, group["id"])
      assert_provenance(f, 1)

      # identical evaluation replay does not double count or open another episode
      assert :ok = PredictionWorker.run(f.now)
      replayed = only_group(f)
      assert replayed["id"] == group["id"]
      assert DateTime.compare(replayed["last_seen"], group["last_seen"]) == :eq
      assert DateTime.compare(replayed["first_seen"], group["first_seen"]) == :eq
      assert replayed["revision"] == group["revision"]
      assert occurrences(f, group["id"]) == 1
      assert occurrence_rows(f, group["id"]) == first_rows
      assert_provenance(f, 1)

      # a later evaluation inside the open episode refreshes that group
      t2 = DateTime.add(f.now, 600, :second)
      assert :ok = PredictionWorker.run(t2)
      refreshed = only_group(f)
      assert refreshed["id"] == group["id"]
      assert refreshed["status"] == group["status"]
      assert DateTime.compare(refreshed["first_seen"], group["first_seen"]) == :eq
      assert DateTime.compare(refreshed["last_seen"], group["last_seen"]) == :gt
      assert DateTime.compare(refreshed["last_seen"], t2) == :eq
      assert occurrences(f, group["id"]) == 2
      assert group_fingerprint(f, group["id"]) == fingerprint
      assert refreshed["data"]["prediction_target"] == target
      assert distinct_keys?(f, group["id"])
      assert_provenance(f, 2)

      assert {:ok, _} =
               Issues.review(f.scope_a, group["id"], "closed_by_reviewer",
                 expected_revision: issue_revision(f.scope_a, group["id"])
               )

      closed = only_group(f)
      assert closed["status"] == "closed_by_reviewer"
      closed_rows = occurrence_rows(f, closed["id"])
      closed_seen = closed["last_seen"]
      closed_revision = closed["revision"]

      # reviewer closure is a boundary: the next evaluation is a new episode
      t3 = DateTime.add(f.now, 900, :second)
      assert :ok = PredictionWorker.run(t3)
      [opened, still_closed] = groups_by_seen(f)
      assert still_closed["id"] == group["id"]
      assert still_closed["status"] == "closed_by_reviewer"
      assert still_closed["revision"] == closed_revision
      assert still_closed["owner"] == closed["owner"]
      assert DateTime.compare(still_closed["last_seen"], closed_seen) == :eq
      assert DateTime.compare(still_closed["first_seen"], closed["first_seen"]) == :eq
      assert still_closed["occurrences"] == 2
      assert still_closed["data"]["prediction_target"] == target
      assert occurrence_rows(f, group["id"]) == closed_rows
      assert opened["id"] != group["id"]
      assert opened["status"] == "new"
      assert opened["occurrences"] == 1
      assert DateTime.compare(opened["last_seen"], t3) == :eq
      assert group_fingerprint(f, opened["id"]) == fingerprint
      assert opened["data"]["prediction_target"] == target
      assert_kind(opened, unquote(kind))

      # replaying that post-closure evaluation does not duplicate the new episode
      assert :ok = PredictionWorker.run(t3)
      [opened_again, still_closed_again] = groups_by_seen(f)
      assert opened_again["id"] == opened["id"]
      assert opened_again["occurrences"] == 1
      assert opened_again["revision"] == opened["revision"]
      assert still_closed_again["revision"] == closed_revision
      assert DateTime.compare(still_closed_again["last_seen"], closed_seen) == :eq
      assert_provenance(f, 3)

      # an evaluation outside the episode gap starts another episode and leaves
      # both the closed group and the previous open episode untouched
      gap_at = DateTime.add(t3, OpsBrain.Lifecycle.episode_gap_seconds() + 1, :second)
      assert :ok = PredictionWorker.run(gap_at)
      [gapped, previous, still_closed_gap] = groups_by_seen(f)
      assert gapped["id"] not in [group["id"], opened["id"]]
      assert gapped["status"] == "new"
      assert gapped["occurrences"] == 1
      assert DateTime.compare(gapped["last_seen"], gap_at) == :eq
      assert group_fingerprint(f, gapped["id"]) == fingerprint
      assert gapped["data"]["prediction_target"] == target
      assert previous["id"] == opened["id"]
      assert previous["occurrences"] == 1
      assert previous["revision"] == opened["revision"]
      assert DateTime.compare(previous["last_seen"], opened["last_seen"]) == :eq
      assert still_closed_gap["id"] == group["id"]
      assert still_closed_gap["status"] == "closed_by_reviewer"
      assert still_closed_gap["revision"] == closed_revision
      assert DateTime.compare(still_closed_gap["last_seen"], closed_seen) == :eq
      assert occurrence_rows(f, group["id"]) == closed_rows
      assert_provenance(f, 4)
    end
  end

  defp prepare_prediction(f, "storage"), do: insert_history(f, :jump)

  defp prepare_prediction(f, "saturation") do
    config(Map.put(f, :source_a, f.prom), :a, %{
      kind: "prometheus",
      service_id: f.service_id,
      profile: %{
        id: "connections",
        version: 1,
        reviewed: true,
        semantics: "gauge",
        unit: "count",
        query: "synthetic",
        saturation_signal: "connections",
        capacity_policy: %{
          unit: "count",
          limits_verified: true,
          effective_threshold: 250
        }
      }
    })

    insert_count_history(f)
  end

  defp prepare_prediction(f, "pipeline"), do: insert_pipeline_failures(f, 7, f.service_id)
  defp prepare_prediction(f, "pipeline-ci"), do: insert_pipeline_failures(f, 9, nil)

  defp insert_count_history(f) do
    Tenancy.with_scope(f.scope_a, fn ->
      for h <- 23..0//-1 do
        used = 215.0 - 2.1 * min(h, 6) - 0.15 * max(h - 6, 0)
        at = DateTime.add(f.now, -h * 3600, :second)

        Repo.query!(
          "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$6,$7)",
          [
            f.a.id,
            f.prom.id,
            f.service_id,
            "connections:v1",
            DateTime.add(at, -3600, :second),
            at,
            %{
              "samples" => [
                %{"value" => used, "timestamp" => DateTime.to_unix(at), "series" => "connections"}
              ],
              "unit" => "count"
            }
          ]
        )
      end
    end)
  end

  defp insert_pipeline_failures(f, definition_id, target_id) do
    Tenancy.with_scope(f.scope_a, fn ->
      for h <- 1..3 do
        run_id = definition_id * 1000 + h
        at = DateTime.add(f.now, -h * 600, :second)

        if target_id do
          Repo.query!(
            "INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3,'deployment',$4,$4,$5,$6)",
            [
              f.a.id,
              f.prom.id,
              "deploy:episode:#{definition_id}:#{run_id}",
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

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,$5,'completed','failed',$6,$6,1,$7)",
          [
            f.a.id,
            f.prom.id,
            "00000000-0000-4000-8000-000000000020",
            run_id,
            definition_id,
            at,
            %{"branch" => "main", "service" => "orders-db"}
          ]
        )
      end
    end)
  end

  defp only_group(f) do
    assert {:ok, [group]} = Issues.list(f.scope_a)
    group
  end

  defp groups_by_seen(f) do
    assert {:ok, groups} = Issues.list(f.scope_a)
    Enum.sort_by(groups, &DateTime.to_unix(&1["last_seen"]), :desc)
  end

  defp occurrences(f, id), do: Enum.find(groups_by_seen(f), &(&1["id"] == id))["occurrences"]

  defp occurrence_rows(f, id) do
    {:ok, rows} =
      Tenancy.with_scope(f.scope_a, fn ->
        Store.rows(
          "SELECT occurrence_key, evidence_revision, occurred_at FROM failure_occurrences WHERE group_id=$1::text::uuid ORDER BY occurrence_key",
          [id]
        )
      end)

    rows
  end

  defp distinct_keys?(f, id) do
    keys = Enum.map(occurrence_rows(f, id), & &1["occurrence_key"])
    length(keys) == length(Enum.uniq(keys)) and length(keys) > 1
  end

  defp group_fingerprint(f, id) do
    {:ok, [row]} =
      Tenancy.with_scope(f.scope_a, fn ->
        Store.rows("SELECT fingerprint FROM issue_groups WHERE id=$1::text::uuid", [id])
      end)

    row["fingerprint"]
  end

  defp assert_kind(group, "pipeline-ci") do
    assert String.contains?(group["data"]["template"], "prediction:pipeline:")
    assert String.contains?(group["data"]["template"], "CI-only")
    assert group["data"]["prediction_target"] == nil
  end

  defp assert_kind(group, "pipeline") do
    assert String.contains?(group["data"]["template"], "prediction:pipeline:")
    refute String.contains?(group["data"]["template"], "CI-only")
    assert is_binary(group["data"]["prediction_target"]["service_instance_id"])
  end

  defp assert_kind(group, kind) do
    assert String.contains?(group["data"]["template"], "prediction:#{kind}:")
    assert is_binary(group["data"]["prediction_target"]["service_instance_id"])
  end

  defp assert_provenance(f, evidence_count) do
    {:ok, rows} =
      Tenancy.with_scope(f.scope_a, fn ->
        Store.rows(
          "SELECT source_id::text, kind, received_at, expires_at FROM evidence_items WHERE kind='prediction' ORDER BY received_at, id"
        )
      end)

    assert length(rows) == evidence_count
    assert Enum.all?(rows, &(&1["source_id"] == f.prom.id and &1["kind"] == "prediction"))

    assert Enum.all?(rows, fn row ->
             DateTime.compare(row["expires_at"], DateTime.add(row["received_at"], 7, :day)) == :eq
           end)
  end
end
