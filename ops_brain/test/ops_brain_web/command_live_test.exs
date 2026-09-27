defmodule OpsBrainWeb.CommandLiveTest do
  # Phase 4.1 owns full coverage of this page; this file only pins the Task 1.1
  # unknown-storage contract: an unverified volume limit renders as unknown on
  # both new pages without crashing on nil numbers.
  use OpsBrainWeb.ConnCase, async: false
  import OpsBrain.SourceFixtures

  alias OpsBrain.{Repo, Services, Store, Tenancy}

  @gib 1_073_741_824.0

  setup do
    on_exit(&cleanup/0)
    f = fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, prom} = Tenancy.create_source(f.scope_a, %{name: "storage-metrics", kind: :prometheus})
    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    {:ok, service} =
      Services.create(f.scope_a, %{
        source_id: prom.id,
        environment_id: env.id,
        service_key: "storage-prod",
        target: "synthetic/storage-prod"
      })

    # 24 hourly byte windows with a growth jump, but no trusted source config:
    # the volume limit is unverified, so the risk must be unknown.
    Tenancy.with_scope(f.scope_a, fn ->
      for hours_ago <- 23..0//-1 do
        used = 215.0 - 2.1 * min(hours_ago, 6) - 0.15 * max(hours_ago - 6, 0)
        at = DateTime.add(now, -hours_ago * 3600, :second)

        Repo.query!(
          "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,'storage:v1','prometheus',$4,$5,$5,$6)",
          [
            f.a.id,
            prom.id,
            service["id"],
            DateTime.add(at, -3600, :second),
            at,
            %{
              "samples" => [
                %{
                  "value" => round(used * @gib),
                  "timestamp" => DateTime.to_unix(at),
                  "series" => "s"
                }
              ],
              "unit" => "bytes"
            }
          ]
        )
      end
    end)

    Map.merge(f, %{
      now: now,
      prom: prom,
      service_id: service["id"],
      conn: init_test_session(build_conn(), operator_token: f.token_a)
    })
  end

  test "unverified volume limits render as unknown without crashing", f do
    {:ok, view, _html} = live(f.conn, "/companies/#{f.a.id}/command")

    assert has_element?(view, "#storage-risks")
    assert has_element?(view, "#storage-risks .cc-spark")
    assert has_element?(view, "#storage-risks .badge", "Unknown")

    html = render(view)
    assert html =~ "volume size not verified"
    assert html =~ "unknown GiB"
    refute has_element?(view, "#storage-risks .badge-danger", "abnormal growth")
    refute has_element?(view, "#storage-risks .cc-meter")
  end

  test "flaky and slowing pipelines surface on the command center", f do
    {:ok, ado} = Tenancy.create_source(f.scope_a, %{name: "azure", kind: :azure_build})

    Tenancy.with_scope(f.scope_a, fn ->
      # alternating results (4 changes) with the latest succeeded: flaky
      for {run_id, result, minutes} <- [
            {9201, "succeeded", 10},
            {9202, "failed", 9},
            {9203, "succeeded", 8},
            {9204, "succeeded", 7},
            {9205, "succeeded", 6},
            {9206, "failed", 5},
            {9207, "succeeded", 4},
            {9208, "succeeded", 3},
            {9209, "succeeded", 2},
            {9210, "succeeded", 1}
          ] do
        at = DateTime.add(f.now, -minutes * 60, :second)

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,8,'completed',$6,$7,$7,1,$8)",
          [
            Ecto.UUID.generate(),
            f.a.id,
            ado.id,
            "00000000-0000-4000-8000-000000000020",
            run_id,
            result,
            at,
            %{"branch" => "main", "service" => "flaky-svc"}
          ]
        )
      end

      # five previous runs at 100s then five at 150s: 1.5x slowdown
      for i <- 1..5 do
        at = DateTime.add(f.now, -(60 + i) * 60, :second)

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,9,'completed','succeeded',$6,$7,1,$8)",
          [
            Ecto.UUID.generate(),
            f.a.id,
            ado.id,
            "00000000-0000-4000-8000-000000000020",
            9300 + i,
            at,
            DateTime.add(at, 60, :second),
            %{
              "branch" => "main",
              "service" => "slow-svc",
              "start_at" => DateTime.to_iso8601(DateTime.add(at, -100, :second))
            }
          ]
        )
      end

      for i <- 1..5 do
        at = DateTime.add(f.now, -i * 60, :second)

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,9,'completed','succeeded',$6,$7,1,$8)",
          [
            Ecto.UUID.generate(),
            f.a.id,
            ado.id,
            "00000000-0000-4000-8000-000000000020",
            9400 + i,
            at,
            DateTime.add(at, 60, :second),
            %{
              "branch" => "main",
              "service" => "slow-svc",
              "start_at" => DateTime.to_iso8601(DateTime.add(at, -150, :second))
            }
          ]
        )
      end
    end)

    {:ok, view, _html} = live(f.conn, "/companies/#{f.a.id}/command")
    html = render(view)

    assert has_element?(view, "#pipeline-risks .badge-warning", "flaky")
    assert html =~ "flaky: alternating results"
    assert html =~ "flaky-svc"

    assert html =~ "run durations up 1.5x"
    assert html =~ "slow-svc"
  end

  test "runtime coverage note is explicit about uncollected node and database health", f do
    {:ok, view, _html} = live(f.conn, "/companies/#{f.a.id}/command")

    assert render(view) =~ "node and database health is not collected"
  end

  test "a count-only command page renders the saturation panel with critical and unknown", f do
    {:ok, prom_connections} =
      Tenancy.create_source(f.scope_a, %{name: "metrics-connections", kind: :prometheus})

    {:ok, prom_queue} =
      Tenancy.create_source(f.scope_a, %{name: "metrics-queue", kind: :prometheus})

    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    {:ok, orders} =
      Services.create(f.scope_a, %{
        source_id: prom_connections.id,
        environment_id: env.id,
        service_key: "orders-db",
        target: "nw-eu/data/orders-db"
      })

    {:ok, queue} =
      Services.create(f.scope_a, %{
        source_id: prom_queue.id,
        environment_id: env.id,
        service_key: "queue-svc",
        target: "nw-eu/data/queue-svc"
      })

    _verified =
      config(Map.put(f, :source_a, prom_connections), :a, %{
        kind: "prometheus",
        service_id: orders["id"],
        profile: %{
          id: "db-connections",
          version: 1,
          reviewed: true,
          semantics: "gauge",
          unit: "count",
          query: "pg_stat_activity_count",
          saturation_signal: "connections",
          capacity_policy: %{unit: "count", limits_verified: true, effective_threshold: 500}
        }
      })

    _unverified =
      config(Map.put(f, :source_a, prom_queue), :a, %{
        kind: "prometheus",
        service_id: queue["id"],
        profile: %{
          id: "queue-depth",
          version: 1,
          reviewed: true,
          semantics: "gauge",
          unit: "count",
          query: "queue_depth",
          capacity_policy: %{unit: "count", limits_verified: false, effective_threshold: 100}
        }
      })

    insert = fn source, profile_id, service_id, series, value_at ->
      Tenancy.with_scope(f.scope_a, fn ->
        for h <- 23..0//-1 do
          at = DateTime.add(f.now, -h * 3600, :second)

          Repo.query!(
            "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$6,$7)",
            [
              f.a.id,
              source.id,
              service_id,
              profile_id,
              DateTime.add(at, -3600, :second),
              at,
              %{
                "samples" => [
                  %{
                    "value" => value_at.(h),
                    "timestamp" => DateTime.to_unix(at),
                    "series" => series
                  }
                ],
                "unit" => "count"
              }
            ]
          )
        end
      end)
    end

    # verified connections: 480/500 with a 10/h jump -> critical
    jump = fn h -> 480 - 10 * min(h, 6) - 1 * max(h - 6, 0) end

    insert.(prom_connections, "db-connections:v1", orders["id"], "connections", jump)

    # unverified queue depth: flat 100, limit not verified -> unknown
    insert.(prom_queue, "queue-depth:v1", queue["id"], "queue", fn _h -> 100 end)

    {:ok, view, _html} = live(f.conn, "/companies/#{f.a.id}/command")
    html = render(view)

    # the saturation panel renders both risks
    assert has_element?(view, "#saturation-risks")
    assert html =~ "db-connections"
    assert html =~ "queue-depth"

    # verified critical: meter, percent and a troubleshoot link
    assert has_element?(view, "#saturation-risks .cc-critical")
    assert has_element?(view, "#saturation-risks .cc-meter")

    assert has_element?(view, "#saturation-risks a", "Troubleshoot") ||
             has_element?(view, "#saturation-risks .text-link")

    # unverified: unknown badge, no meter, no fabricated numbers
    assert has_element?(view, "#saturation-risks .cc-unknown")
    assert html =~ "verified limit unavailable"
  end

  test "unmapped CI-only pipeline groups are labeled on the command center", f do
    {:ok, ado} = Tenancy.create_source(f.scope_a, %{name: "azure", kind: :azure_build})

    Tenancy.with_scope(f.scope_a, fn ->
      at = DateTime.add(f.now, -300, :second)

      Repo.query!(
        "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,7,'completed','failed',$6,$6,1,$7)",
        [
          Ecto.UUID.generate(),
          f.a.id,
          ado.id,
          "00000000-0000-4000-8000-000000000020",
          9101,
          at,
          %{"branch" => "main"}
        ]
      )
    end)

    {:ok, view, _html} = live(f.conn, "/companies/#{f.a.id}/command")

    html = render(view)
    assert html =~ "definition 7"
    assert has_element?(view, "#pipeline-risks .badge-neutral", "CI-only")
  end

  test "real OOMKilled pods reach command attention with a safe troubleshoot link", f do
    {:ok, k8s} = Tenancy.create_source(f.scope_a, %{name: "k8s", kind: :kubernetes})
    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    {:ok, service} =
      Services.create(f.scope_a, %{
        source_id: k8s.id,
        environment_id: env.id,
        service_key: "checkout-api",
        target: "nw-eu/data/checkout-api"
      })

    c =
      config(Map.put(f, :source_a, k8s), :a, %{
        kind: "kubernetes",
        service_id: service["id"],
        namespace: "data",
        resources: ~w(pods deployments replicasets events)
      })

    scope = Store.digest({c[:endpoint], c[:namespace], c[:approved_ips], c[:credential_env]})

    inventory = %{
      "d1" => %{
        "uid" => "d1",
        "name" => "checkout-api",
        "kind" => "Deployment",
        "resource_version" => "1",
        "generation" => 1,
        "owners" => [],
        "observed_generation" => 1,
        "replicas" => 2,
        "ready_replicas" => 1,
        "available_replicas" => 1
      },
      "rs1" => %{
        "uid" => "rs1",
        "name" => "checkout-api-7d9f",
        "kind" => "ReplicaSet",
        "resource_version" => "1",
        "generation" => 1,
        "owners" => [%{"uid" => "d1", "kind" => "Deployment"}],
        "observed_generation" => 1,
        "replicas" => 2,
        "ready_replicas" => 1,
        "available_replicas" => 1
      },
      "p1" => %{
        "uid" => "p1",
        "name" => "checkout-api-7d9f-abcde",
        "kind" => "Pod",
        "resource_version" => "1",
        "generation" => 0,
        "owners" => [%{"uid" => "rs1", "kind" => "ReplicaSet"}],
        "containers" => [
          %{
            "name" => "app",
            "restarts" => 3,
            "ready" => false,
            "termination" => %{"reason" => "OOMKilled", "finished_at" => nil, "exit_code" => 137}
          }
        ],
        "ready" => false,
        "phase" => "Running"
      },
      "e1" => %{
        "uid" => "e1",
        "name" => "checkout-api-7d9f-abcde.17x",
        "kind" => "Event",
        "resource_version" => "1",
        "generation" => 0,
        "owners" => [],
        "target_uid" => "p1",
        "target_kind" => "Pod",
        "count" => 4,
        "type" => "Warning",
        "reason" => "BackOff",
        "last_seen" => nil
      }
    }

    Tenancy.with_scope(f.scope_a, fn ->
      for {resource, kind} <- %{
            "pods" => "Pod",
            "deployments" => "Deployment",
            "replicasets" => "ReplicaSet",
            "events" => "Event"
          } do
        objects = inventory |> Enum.filter(fn {_uid, o} -> o["kind"] == kind end) |> Map.new()

        Repo.query!(
          "INSERT INTO kubernetes_cursors(company_id,source_id,resource,revision,updated_at,data) VALUES($1::text::uuid,$2::text::uuid,$3,1,$4,$5)",
          [
            f.a.id,
            k8s.id,
            resource,
            f.now,
            %{
              "namespace" => "data",
              "objects" => objects,
              "scope" => scope,
              "observed_at" => DateTime.to_unix(f.now),
              "coverage" => "complete",
              "gap" => false,
              "error" => nil
            }
          ]
        )
      end
    end)

    {:ok, view, _html} = live(f.conn, "/companies/#{f.a.id}/command")

    html = render(view)
    assert has_element?(view, "#attention .cc-critical")
    assert html =~ "checkout-api: pods OOMKilled"
    assert has_element?(view, "#attention .btn", "Troubleshoot")
  end

  test "finding attention items link straight to their focused investigation", f do
    c = OpsBrain.SourceFixtures.config(f)

    {:ok, _} =
      OpsBrain.SourceConfig.transaction(c.id, fn trusted ->
        OpsBrain.Evidence.failure(
          trusted,
          "attention-failure",
          %{"issues" => ["HTTP 401 api.invalid"], "tool" => "compiler", "attempt" => 1},
          7,
          f.now
        )
      end)

    {:ok, [group]} = OpsBrain.Issues.list(f.scope_a)

    {:ok, view, _html} = live(f.conn, "/companies/#{f.a.id}/command")

    # the deep link carries the focus id and the #groups-<id> scroll target
    assert has_element?(
             view,
             "#attention a[href='/companies/#{f.a.id}/investigations?focus=#{group["id"]}#groups-#{group["id"]}']"
           )
  end

  # A staging namesake sharing the prod service's key, cluster and volume,
  # with its own flat history, plus pipeline runs deployed to each
  # environment under the same name.
  defp seed_staging_namesake(f) do
    env_staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))

    # its own collector source: window identity is fixed per source/profile
    {:ok, prom_staging} =
      Tenancy.create_source(f.scope_a, %{name: "metrics-staging", kind: :prometheus})

    {:ok, service_staging} =
      Services.create(f.scope_a, %{
        source_id: prom_staging.id,
        environment_id: env_staging.id,
        service_key: "storage-prod",
        target: "synthetic/storage-prod"
      })

    Tenancy.with_scope(f.scope_a, fn ->
      for hours_ago <- 23..0//-1 do
        at = DateTime.add(f.now, -hours_ago * 3600, :second)

        Repo.query!(
          "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,'storage:v1','prometheus',$4,$5,$5,$6)",
          [
            f.a.id,
            prom_staging.id,
            service_staging["id"],
            DateTime.add(at, -3600, :second),
            at,
            %{
              "samples" => [
                %{
                  "value" => round(100.0 * @gib),
                  "timestamp" => DateTime.to_unix(at),
                  "series" => "s"
                }
              ],
              "unit" => "bytes"
            }
          ]
        )
      end
    end)

    {:ok, ado} = Tenancy.create_source(f.scope_a, %{name: "azure", kind: :azure_build})

    Tenancy.with_scope(f.scope_a, fn ->
      for {run_id, result, target_id} <- [
            {9601, "failed", f.service_id},
            {9602, "failed", f.service_id},
            {9603, "succeeded", service_staging["id"]},
            {9604, "succeeded", service_staging["id"]}
          ] do
        at = DateTime.add(f.now, -(run_id - 9600) * 600, :second)

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,7,'completed',$6,$7,$7,1,$8)",
          [
            Ecto.UUID.generate(),
            f.a.id,
            ado.id,
            "00000000-0000-4000-8000-000000000020",
            run_id,
            result,
            at,
            %{"branch" => "main", "service" => "storage-prod"}
          ]
        )

        Repo.query!(
          "INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'deployment',$5,$5,$6,$7)",
          [
            Ecto.UUID.generate(),
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
    end)

    :ok
  end

  test "environment selection filters storage, pipelines and attention and survives refresh",
       f do
    seed_staging_namesake(f)

    {:ok, view, _html} = live(f.conn, "/companies/#{f.a.id}/command?environment=prod")

    # storage narrows to the prod instance's series
    assert has_element?(view, "#storage-risks .env-code", "prod")
    refute has_element?(view, "#storage-risks .env-code", "staging")

    # pipeline health is recomputed from the prod-deployed runs only
    assert has_element?(view, "#pipeline-risks #pipeline-storage-prod .cc-run-critical")
    refute has_element?(view, "#pipeline-risks #pipeline-storage-prod .cc-run-ok")

    # attention narrows with it: the pipeline item carries prod
    assert has_element?(view, "#attention .cc-item .env-code", "prod")
    refute has_element?(view, "#attention .cc-item .env-code", "staging")

    # the selection survives a view refresh
    render_click(view, "refresh")
    assert has_element?(view, "#storage-risks .env-code", "prod")
    refute has_element?(view, "#storage-risks .env-code", "staging")
    assert has_element?(view, "#attention .cc-item .env-code", "prod")
  end

  test "selecting an environment patches the URL and reloads the filtered view", f do
    seed_staging_namesake(f)

    {:ok, view, _html} = live(f.conn, "/companies/#{f.a.id}/command")

    # All environments shows both namesakes
    assert has_element?(view, "#storage-risks .env-code", "prod")
    assert has_element?(view, "#storage-risks .env-code", "staging")

    view
    |> form("#command-environment-form")
    |> render_change(%{"environment" => "staging"})

    assert_patch(view, "/companies/#{f.a.id}/command?environment=staging")

    assert has_element?(view, "#storage-risks .env-code", "staging")
    refute has_element?(view, "#storage-risks .env-code", "prod")

    # recomputed from the staging-deployed runs: no failed streak there
    refute has_element?(view, "#pipeline-risks #pipeline-storage-prod .cc-run-critical")
    assert has_element?(view, "#pipeline-risks #pipeline-storage-prod .cc-run-ok")
  end

  test "the command page renders for a member and redirects non-members", f do
    conn_b = init_test_session(build_conn(), operator_token: f.token_b)

    # an operator without membership in the company is redirected at mount
    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(conn_b, "/companies/#{f.a.id}/command")

    # a member renders the page
    {:ok, view, _html} = live(f.conn, "/companies/#{f.a.id}/command")
    assert has_element?(view, "#attention")
  end

  test "a company without data shows empty states, never healthy claims", f do
    conn_b = init_test_session(build_conn(), operator_token: f.token_b)
    {:ok, view, html} = live(conn_b, "/companies/#{f.b.id}/command")

    # every panel renders its designed no-data state
    assert html =~ "Nothing flagged right now"
    assert html =~ "missing data is not the same as healthy"
    assert html =~ "No storage history"
    assert html =~ "No pipeline runs"

    # no fabricated rows and no healthy claims anywhere
    refute has_element?(view, "#attention .cc-item")
    refute has_element?(view, "#storage-risks .cc-item")
    refute has_element?(view, "#pipeline-risks .cc-item")
    refute html =~ "Everything is healthy"
    refute html =~ "All systems operational"
    refute html =~ "all clear"
  end

  test "demo anomalies surface on the command center", f do
    OpsBrain.Demo.seed!(OpsBrain.TestAdminRepo, f.alice.name, now: f.now)
    {:ok, _scope} = Tenancy.authorize(f.token_a, OpsBrain.Demo.company_id())
    conn = init_test_session(build_conn(), operator_token: f.token_a)

    {:ok, view, html} = live(conn, "/companies/#{OpsBrain.Demo.company_id()}/command")

    # reporting-postgres is flagged with abnormal growth at a critical level
    assert has_element?(view, "#storage-risks .cc-critical strong", "reporting-postgres")
    assert has_element?(view, "#storage-risks .badge-danger", "abnormal growth")

    # the search-indexer pipeline is failing critically
    assert has_element?(view, "#pipeline-risks li#pipeline-search-indexer.cc-critical")

    # the stale staging loki source is listed as a blind spot, not as healthy
    assert html =~ "DEMO · nw-eu-staging · loki"
    assert has_element?(view, "#blind-spots .cc-item")
    refute html =~ "All sources reporting"

    # guided-tour step 0: the storage item links to the reporting service page
    # and attention findings carry focused investigation links
    assert has_element?(
             view,
             "#storage-risks a[href='/companies/#{OpsBrain.Demo.company_id()}/troubleshoot?environment=prod&service=reporting']"
           )

    assert html =~ "/investigations?focus="
  end

  test "invalid environment values fall back to all environments", f do
    seed_staging_namesake(f)

    {:ok, view, _html} = live(f.conn, "/companies/#{f.a.id}/command?environment=production")

    assert has_element?(view, "#storage-risks .env-code", "prod")
    assert has_element?(view, "#storage-risks .env-code", "staging")
  end
end
