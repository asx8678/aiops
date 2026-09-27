defmodule OpsBrain.Insights.PipelinesTest do
  use OpsBrain.DataCase, async: false

  alias OpsBrain.{Demo, Insights, Repo, Services, Tenancy, TestAdminRepo}

  setup do
    f = fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, ado_a} = Tenancy.create_source(f.scope_a, %{name: "azure", kind: :azure_build})
    {:ok, ado_b} = Tenancy.create_source(f.scope_b, %{name: "azure", kind: :azure_build})

    env_a_prod = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))
    env_a_staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))
    env_b_prod = Enum.find(f.envs, &(&1.company_id == f.b.id and &1.name == :prod))

    services =
      for {label, key, scope, env, source, target} <- [
            {"checkout-prod", "checkout-api", f.scope_a, env_a_prod, ado_a,
             "nw-eu/data/checkout-api"},
            {"checkout-staging", "checkout-api", f.scope_a, env_a_staging, ado_a,
             "nw-eu-staging/data/checkout-api"},
            {"checkout-b", "checkout-api", f.scope_b, env_b_prod, ado_b,
             "other/data/checkout-api"}
          ] do
        {:ok, service} =
          Services.create(scope, %{
            source_id: source.id,
            environment_id: env.id,
            service_key: key,
            target: target
          })

        {label, service["id"]}
      end

    Map.merge(f, %{
      now: now,
      ado_a: ado_a,
      ado_b: ado_b,
      services: Map.new(services)
    })
  end

  defp insert_run(scope, company_id, source_id, run_id, definition_id, result, minutes_ago, data) do
    at = DateTime.add(scope_now(scope), -minutes_ago * 60, :second)

    Tenancy.with_scope(scope, fn ->
      Repo.query!(
        "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,$6,'completed',$7,$8,$8,1,$9)",
        [
          Ecto.UUID.generate(),
          company_id,
          source_id,
          "00000000-0000-4000-8000-000000000020",
          run_id,
          definition_id,
          result,
          at,
          data
        ]
      )
    end)
  end

  defp scope_now(_scope), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp insert_deployment(scope, company_id, source_id, run_id, target_id, opts \\ []) do
    at = Keyword.get(opts, :at, DateTime.add(scope_now(scope), -30, :second))

    Tenancy.with_scope(scope, fn ->
      Repo.query!(
        "INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'deployment',$5,$6,$7,$8)",
        [
          Ecto.UUID.generate(),
          company_id,
          source_id,
          "deploy:#{company_id}:#{Keyword.get(opts, :key, to_string(run_id))}",
          Keyword.get(opts, :occurred_at, at),
          at,
          DateTime.add(at, Keyword.get(opts, :expires_in_days, 1), :day),
          %{
            "run_id" => run_id,
            "record_id" => "r-#{run_id}",
            "attempt" => 1,
            "reported_result" => "succeeded",
            "target_id" => target_id
          }
        ]
      )
    end)
  end

  describe "deployment evidence maps runs to service and environment" do
    test "prod and staging deployments appear only on their own troubleshoot pages", f do
      insert_run(f.scope_a, f.a.id, f.ado_a.id, 9001, 7, "succeeded", 40, %{"branch" => "main"})

      insert_run(f.scope_a, f.a.id, f.ado_a.id, 9002, 7, "succeeded", 30, %{"branch" => "main"})

      insert_deployment(f.scope_a, f.a.id, f.ado_a.id, 9001, f.services["checkout-prod"])
      insert_deployment(f.scope_a, f.a.id, f.ado_a.id, 9002, f.services["checkout-staging"])

      assert {:ok, prod} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert {:ok, staging} = Insights.service(f.scope_a, "checkout-api", "staging", f.now)

      assert Enum.map(prod.runs, & &1["run_id"]) == [9001]
      assert Enum.map(staging.runs, & &1["run_id"]) == [9002]
      assert prod.pipeline.name == "checkout-api"
      assert staging.pipeline.name == "checkout-api"

      assert {:ok, data} = Insights.command(f.scope_a, f.now)
      assert Enum.any?(data.pipelines, &(&1.name == "checkout-api"))
    end

    test "runs without deployment evidence keep the name fallback on every environment", f do
      insert_run(f.scope_a, f.a.id, f.ado_a.id, 9003, 8, "succeeded", 20, %{
        "branch" => "main",
        "service" => "checkout-api"
      })

      assert {:ok, prod} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert {:ok, staging} = Insights.service(f.scope_a, "checkout-api", "staging", f.now)

      assert Enum.map(prod.runs, & &1["run_id"]) == [9003]
      assert Enum.map(staging.runs, & &1["run_id"]) == [9003]
      refute prod.runs |> hd() |> Map.get("ci_only")
    end

    test "unmapped runs group under their definition id as explicit CI-only", f do
      insert_run(f.scope_a, f.a.id, f.ado_a.id, 9004, 7, "failed", 10, %{"branch" => "main"})

      assert {:ok, data} = Insights.command(f.scope_a, f.now)

      unmapped = Enum.find(data.pipelines, &(&1.name == "definition 7"))
      assert unmapped != nil
      assert unmapped.ci_only == true
      assert unmapped.level == "warning"

      refute Enum.any?(data.pipelines, &(&1.name != "definition 7" and &1.ci_only))

      # unmapped CI-only runs are never attributed to a service page
      assert {:ok, prod} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert prod.runs == []
    end

    test "runs stay tenant isolated", f do
      insert_run(f.scope_a, f.a.id, f.ado_a.id, 9100, 7, "succeeded", 15, %{"branch" => "main"})

      insert_deployment(f.scope_a, f.a.id, f.ado_a.id, 9100, f.services["checkout-prod"])

      insert_run(f.scope_b, f.b.id, f.ado_b.id, 9100, 7, "failed", 12, %{"branch" => "main"})

      insert_deployment(f.scope_b, f.b.id, f.ado_b.id, 9100, f.services["checkout-b"])

      assert {:ok, a} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert {:ok, b} = Insights.service(f.scope_b, "checkout-api", "prod", f.now)

      assert [%{"run_id" => 9100, "result" => "succeeded"}] = a.runs
      assert [%{"run_id" => 9100, "result" => "failed"}] = b.runs
    end
  end

  describe "evidence boundaries and multi-target mapping" do
    test "more than 300 unrelated newer runs cannot hide a service's history", f do
      Tenancy.with_scope(f.scope_a, fn ->
        for i <- 1..320 do
          at = DateTime.add(scope_now(f.scope_a), -i, :second)

          Repo.query!(
            "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,2,'completed','succeeded',$6,$6,1,$7)",
            [
              Ecto.UUID.generate(),
              f.a.id,
              f.ado_a.id,
              "00000000-0000-4000-8000-000000000020",
              20000 + i,
              at,
              %{"branch" => "main"}
            ]
          )
        end
      end)

      insert_run(f.scope_a, f.a.id, f.ado_a.id, 9005, 7, "succeeded", 400, %{"branch" => "main"})

      insert_deployment(f.scope_a, f.a.id, f.ado_a.id, 9005, f.services["checkout-prod"])

      assert {:ok, prod} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert Enum.any?(prod.runs, &(&1["run_id"] == 9005))
      assert prod.runs |> hd() |> Map.get("environment") == "prod"
    end

    test "expired, cross-source and future deployment evidence never map a run", f do
      {:ok, ado_a2} = Tenancy.create_source(f.scope_a, %{name: "azure-2", kind: :azure_build})

      insert_run(f.scope_a, f.a.id, f.ado_a.id, 9006, 7, "succeeded", 50, %{
        "branch" => "main",
        "service" => "checkout-api"
      })

      # expired evidence
      insert_deployment(f.scope_a, f.a.id, f.ado_a.id, 9006, f.services["checkout-prod"],
        key: "expired",
        expires_in_days: -1
      )

      # evidence from a different source than the run
      insert_deployment(f.scope_a, f.a.id, ado_a2.id, 9006, f.services["checkout-prod"],
        key: "cross-source"
      )

      # evidence received in the future
      insert_deployment(f.scope_a, f.a.id, f.ado_a.id, 9006, f.services["checkout-prod"],
        key: "future",
        at: DateTime.add(f.now, 3600, :second)
      )

      # evidence received now but occurred in the future
      insert_deployment(f.scope_a, f.a.id, f.ado_a.id, 9006, f.services["checkout-prod"],
        key: "occurred-future",
        at: DateTime.add(f.now, -30, :second),
        occurred_at: DateTime.add(f.now, 3600, :second)
      )

      assert {:ok, prod} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert {:ok, staging} = Insights.service(f.scope_a, "checkout-api", "staging", f.now)

      run = hd(prod.runs)
      assert run["run_id"] == 9006
      assert run["environment"] == nil
      assert run["environments"] == []

      assert Enum.any?(staging.runs, &(&1["run_id"] == 9006))
      assert staging.runs |> hd() |> Map.get("environment") == nil
    end

    test "a run deployed to two services appears once in each service group", f do
      env_prod = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

      {:ok, reporting} =
        Services.create(f.scope_a, %{
          source_id: f.ado_a.id,
          environment_id: env_prod.id,
          service_key: "reporting",
          target: "nw-eu/data/reporting"
        })

      insert_run(f.scope_a, f.a.id, f.ado_a.id, 9007, 7, "succeeded", 25, %{"branch" => "main"})

      insert_deployment(f.scope_a, f.a.id, f.ado_a.id, 9007, f.services["checkout-prod"],
        key: "9007-checkout"
      )

      insert_deployment(f.scope_a, f.a.id, f.ado_a.id, 9007, reporting["id"],
        key: "9007-reporting"
      )

      assert {:ok, checkout} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert {:ok, reporting_page} = Insights.service(f.scope_a, "reporting", "prod", f.now)

      assert [%{"run_id" => 9007}] = checkout.runs
      assert [%{"run_id" => 9007}] = reporting_page.runs

      assert {:ok, data} = Insights.command(f.scope_a, f.now)

      assert Enum.find(data.pipelines, &(&1.name == "checkout-api")).total == 1
      assert Enum.find(data.pipelines, &(&1.name == "reporting")).total == 1
    end

    test "a run deployed to prod and staging of one service is single and visible on both pages",
         f do
      insert_run(f.scope_a, f.a.id, f.ado_a.id, 9008, 7, "succeeded", 25, %{"branch" => "main"})

      insert_deployment(f.scope_a, f.a.id, f.ado_a.id, 9008, f.services["checkout-prod"],
        key: "9008-prod"
      )

      insert_deployment(f.scope_a, f.a.id, f.ado_a.id, 9008, f.services["checkout-staging"],
        key: "9008-staging"
      )

      assert {:ok, prod} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert {:ok, staging} = Insights.service(f.scope_a, "checkout-api", "staging", f.now)

      assert [%{"run_id" => 9008, "environments" => ["prod", "staging"]}] = prod.runs
      assert [%{"run_id" => 9008}] = staging.runs

      # one row per group: the run is not double-counted
      assert prod.pipeline.total == 1
    end
  end

  describe "occurrence and finish time guards" do
    test "future-finished runs are excluded while unfinished runs stay", f do
      Tenancy.with_scope(f.scope_a, fn ->
        # received now but finish_at in the future: not yet a fact
        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,7,'completed','succeeded',$6,$7,1,$8)",
          [
            Ecto.UUID.generate(),
            f.a.id,
            f.ado_a.id,
            "00000000-0000-4000-8000-000000000020",
            9110,
            DateTime.add(f.now, 3600, :second),
            DateTime.add(f.now, -30, :second),
            %{"branch" => "main"}
          ]
        )

        # unfinished run (finish_at NULL) deployed to prod: still a fact
        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,7,'inProgress',NULL,NULL,$6,1,$7)",
          [
            Ecto.UUID.generate(),
            f.a.id,
            f.ado_a.id,
            "00000000-0000-4000-8000-000000000020",
            9111,
            DateTime.add(f.now, -20, :second),
            %{"branch" => "main"}
          ]
        )
      end)

      insert_deployment(f.scope_a, f.a.id, f.ado_a.id, 9110, f.services["checkout-prod"],
        key: "9110"
      )

      insert_deployment(f.scope_a, f.a.id, f.ado_a.id, 9111, f.services["checkout-prod"],
        key: "9111"
      )

      assert {:ok, prod} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert Enum.map(prod.runs, & &1["run_id"]) == [9111]

      assert {:ok, data} = Insights.command(f.scope_a, f.now)
      refute Enum.any?(data.pipelines, &(&1.name == "definition 7"))
    end
  end

  describe "unbounded service mapping" do
    test "a selected service beyond the first 20 deployment targets still maps its runs",
         f do
      env_prod = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

      Tenancy.with_scope(f.scope_a, fn ->
        run_at = DateTime.add(f.now, -30, :minute)

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,7,'completed','succeeded',$6,$6,1,$7)",
          [
            Ecto.UUID.generate(),
            f.a.id,
            f.ado_a.id,
            "00000000-0000-4000-8000-000000000020",
            9009,
            run_at,
            %{"branch" => "main"}
          ]
        )

        for i <- 1..25 do
          key = "svc-#{String.pad_leading(to_string(i), 2, "0")}"
          sid = Ecto.UUID.generate()

          Repo.query!(
            "INSERT INTO service_instances(id,company_id,source_id,environment_id,service_key,target) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,$6)",
            [sid, f.a.id, f.ado_a.id, env_prod.id, key, "nw-eu/data/#{key}"]
          )

          # svc-25's evidence is the oldest: it sorts after any first-20 cap
          received = DateTime.add(run_at, (26 - i) * 10, :second)

          Repo.query!(
            "INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'deployment',$5,$5,$6,$7)",
            [
              Ecto.UUID.generate(),
              f.a.id,
              f.ado_a.id,
              "deploy:9009:#{key}",
              received,
              DateTime.add(f.now, 1, :day),
              %{
                "run_id" => 9009,
                "attempt" => 1,
                "reported_result" => "succeeded",
                "target_id" => sid
              }
            ]
          )
        end
      end)

      assert {:ok, last} = Insights.service(f.scope_a, "svc-25", "prod", f.now)
      assert [%{"run_id" => 9009, "environment" => "prod"}] = last.runs

      assert {:ok, first} = Insights.service(f.scope_a, "svc-01", "prod", f.now)
      assert Enum.any?(first.runs, &(&1["run_id"] == 9009))
    end

    test "more than 300 newer staging runs cannot hide the selected prod run", f do
      Tenancy.with_scope(f.scope_a, fn ->
        for i <- 1..320 do
          at = DateTime.add(f.now, -i, :second)
          rid = 30000 + i

          Repo.query!(
            "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,2,'completed','succeeded',$6,$6,1,$7)",
            [
              Ecto.UUID.generate(),
              f.a.id,
              f.ado_a.id,
              "00000000-0000-4000-8000-000000000020",
              rid,
              at,
              %{"branch" => "main", "service" => "checkout-api"}
            ]
          )

          Repo.query!(
            "INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'deployment',$5,$5,$6,$7)",
            [
              Ecto.UUID.generate(),
              f.a.id,
              f.ado_a.id,
              "deploy:#{rid}",
              at,
              DateTime.add(f.now, 1, :day),
              %{
                "run_id" => rid,
                "attempt" => 1,
                "reported_result" => "succeeded",
                "target_id" => f.services["checkout-staging"]
              }
            ]
          )
        end
      end)

      insert_run(f.scope_a, f.a.id, f.ado_a.id, 9010, 7, "succeeded", 400, %{
        "branch" => "main",
        "service" => "checkout-api"
      })

      insert_deployment(f.scope_a, f.a.id, f.ado_a.id, 9010, f.services["checkout-prod"],
        key: "9010"
      )

      assert {:ok, prod} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert Enum.any?(prod.runs, &(&1["run_id"] == 9010))
      assert Enum.all?(prod.runs, &(&1["run_id"] == 9010))
    end
  end

  describe "duration trend through the real command read" do
    defp insert_timed_run(f, run_id, _minutes_ago, result, start_at, finish_at) do
      Tenancy.with_scope(f.scope_a, fn ->
        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,7,'completed',$6,$7,$7,1,$8)",
          [
            Ecto.UUID.generate(),
            f.a.id,
            f.ado_a.id,
            "00000000-0000-4000-8000-000000000020",
            run_id,
            result,
            finish_at,
            %{"branch" => "main", "service" => "checkout-api", "start_at" => start_at}
          ]
        )
      end)
    end

    test "retained start_at durations reach the trend with usable fields", f do
      # five previous runs at 120s, five newer at 240s: 2x slowdown
      for i <- 1..5 do
        minutes = 30 + i
        finish = DateTime.add(f.now, -minutes * 60, :second)

        insert_timed_run(
          f,
          9500 + i,
          minutes,
          "succeeded",
          DateTime.to_iso8601(DateTime.add(finish, -120, :second)),
          finish
        )
      end

      for i <- 1..5 do
        minutes = i
        finish = DateTime.add(f.now, -minutes * 60, :second)

        insert_timed_run(
          f,
          9600 + i,
          minutes,
          "succeeded",
          DateTime.to_iso8601(DateTime.add(finish, -240, :second)),
          finish
        )
      end

      assert {:ok, data} = Insights.command(f.scope_a, f.now)

      group = Enum.find(data.pipelines, &(&1.name == "checkout-api"))
      assert group != nil
      assert group.last5_median_seconds == 240
      assert group.prev5_median_seconds == 120
      assert group.duration_ratio == 2.0
      assert group.level == "warning"
      assert group.reason =~ "run durations up 2.0x"

      # the service read carries the same trend
      assert {:ok, page} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert page.pipeline.duration_ratio == 2.0
      assert page.pipeline.reason =~ "run durations up 2.0x"
    end

    test "malformed, missing, unfinished and inverted starts never fabricate durations", f do
      # previous five timed at 120s; newer five unusable: no trend, no warning
      for i <- 1..5 do
        minutes = 30 + i
        finish = DateTime.add(f.now, -minutes * 60, :second)

        insert_timed_run(
          f,
          9700 + i,
          minutes,
          "succeeded",
          DateTime.to_iso8601(DateTime.add(finish, -120, :second)),
          finish
        )
      end

      # malformed start
      finish = DateTime.add(f.now, -300, :second)
      insert_timed_run(f, 9800, 5, "succeeded", "not-a-timestamp", finish)
      # missing start
      insert_timed_run(f, 9801, 4, "succeeded", nil, DateTime.add(f.now, -240, :second))
      # inverted: start after finish
      finish = DateTime.add(f.now, -180, :second)

      insert_timed_run(
        f,
        9802,
        3,
        "succeeded",
        DateTime.to_iso8601(DateTime.add(finish, 600, :second)),
        finish
      )

      # unfinished run: finish_at NULL
      Tenancy.with_scope(f.scope_a, fn ->
        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,7,'inProgress',NULL,NULL,$6,1,$7)",
          [
            Ecto.UUID.generate(),
            f.a.id,
            f.ado_a.id,
            "00000000-0000-4000-8000-000000000020",
            9803,
            DateTime.add(f.now, -120, :second),
            %{
              "branch" => "main",
              "service" => "checkout-api",
              "start_at" => DateTime.to_iso8601(DateTime.add(f.now, -600, :second))
            }
          ]
        )
      end)

      # one valid newest run keeps the group present
      finish = DateTime.add(f.now, -60, :second)

      insert_timed_run(
        f,
        9804,
        1,
        "succeeded",
        DateTime.to_iso8601(DateTime.add(finish, -100, :second)),
        finish
      )

      assert {:ok, page} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)

      by_run = Map.new(page.runs, &{&1["run_id"], &1["duration_seconds"]})

      # malformed, missing, inverted and unfinished runs never get a duration
      assert by_run[9800] == nil
      assert by_run[9801] == nil
      assert by_run[9802] == nil
      assert by_run[9803] == nil
      assert by_run[9804] == 100

      assert {:ok, data} = Insights.command(f.scope_a, f.now)
      group = Enum.find(data.pipelines, &(&1.name == "checkout-api"))

      # the last five hold two timed runs (100 and 120): no slowdown trend
      assert group.last5_median_seconds == 110.0
      assert group.duration_ratio == nil
      assert group.level == "ok"
      assert group.reason == "no recent failures"
    end
  end

  describe "demo pipeline mapping" do
    test "demo runs keep groups; evidence-mapped runs go to their environment only", f do
      Demo.seed!(TestAdminRepo, f.alice.name, now: f.now)
      {:ok, demo_scope} = Tenancy.authorize(f.token_a, Demo.company_id())

      # run 84066 (search-indexer) carries demo deployment evidence targeting staging
      assert {:ok, staging} = Insights.service(demo_scope, "search-indexer", "staging", f.now)
      assert Enum.any?(staging.runs, &(&1["run_id"] == 84066))

      assert {:ok, prod} = Insights.service(demo_scope, "search-indexer", "prod", f.now)
      refute Enum.any?(prod.runs, &(&1["run_id"] == 84066))
      # prod-evidenced runs stay on the prod page
      assert Enum.any?(prod.runs, &(&1["run_id"] == 84065))

      # runs without any deployment evidence stay on every page of their service
      assert {:ok, push_staging} = Insights.service(demo_scope, "push-worker", "staging", f.now)
      assert Enum.any?(push_staging.runs, &(&1["run_id"] == 84063))

      # demo groups stay service-mapped and are never labeled CI-only
      assert {:ok, data} = Insights.command(demo_scope, f.now)
      assert Enum.any?(data.pipelines, &(&1.name == "push-worker"))
      assert Enum.any?(data.pipelines, &(&1.name == "search-indexer"))
      refute Enum.any?(data.pipelines, & &1.ci_only)
      refute Enum.any?(data.pipelines, & &1.flaky)

      # degraded latest demo runs are warnings, never healthy; the verified
      # demo predicted count includes those honest warnings
      degraded =
        Enum.filter(
          data.pipelines,
          &(&1.last_run["result"] in ["partiallySucceeded", "canceled"])
        )

      assert degraded != []
      assert Enum.all?(degraded, &(&1.level == "warning"))
      assert data.counts.predicted == 12
    end
  end
end
