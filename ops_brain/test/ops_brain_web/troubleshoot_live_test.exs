defmodule OpsBrainWeb.TroubleshootLiveTest do
  # Phase 4.1 owns full coverage of this page; this file only pins the Task 1.1
  # unknown-storage contract: an unverified volume limit renders as unknown on
  # the troubleshoot page without crashing on nil numbers.
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
    {:ok, view, _html} =
      live(f.conn, "/companies/#{f.a.id}/troubleshoot?service=storage-prod&environment=prod")

    assert has_element?(view, "#storage .cc-spark")
    assert has_element?(view, "#storage .badge", "Unknown")

    html = render(view)
    assert html =~ "volume size not verified"
    assert html =~ "unknown GiB"
    refute html =~ "abnormal growth"
  end

  test "pipeline runs show environment evidence and separate prod from staging", f do
    {:ok, ado} = Tenancy.create_source(f.scope_a, %{name: "azure", kind: :azure_build})
    env_prod = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))
    env_staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))

    services =
      for {env, target} <- [
            {env_prod, "nw-eu/data/checkout-api"},
            {env_staging, "nw-eu-staging/data/checkout-api"}
          ] do
        {:ok, service} =
          Services.create(f.scope_a, %{
            source_id: ado.id,
            environment_id: env.id,
            service_key: "checkout-api",
            target: target
          })

        {env.name, service["id"]}
      end
      |> Map.new()

    now = f.now

    Tenancy.with_scope(f.scope_a, fn ->
      for {run_id, env_name, data} <- [
            {9001, :prod, %{"branch" => "main"}},
            {9002, :staging, %{"branch" => "main"}},
            {9003, nil, %{"branch" => "main", "service" => "checkout-api"}}
          ] do
        at = DateTime.add(now, -(run_id - 9000) * 10, :minute)

        Repo.query!(
          "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,7,'completed','succeeded',$6,$6,1,$7)",
          [
            Ecto.UUID.generate(),
            f.a.id,
            ado.id,
            "00000000-0000-4000-8000-000000000020",
            run_id,
            at,
            data
          ]
        )

        if env_name do
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
                "attempt" => 1,
                "reported_result" => "succeeded",
                "target_id" => services[env_name]
              }
            ]
          )
        end
      end
    end)

    {:ok, view, _html} =
      live(f.conn, "/companies/#{f.a.id}/troubleshoot?service=checkout-api&environment=prod")

    html = render(view)
    assert html =~ "9001"
    assert html =~ "environment unknown"
    refute html =~ "9002"

    assert has_element?(view, "#service-pipelines .env-code", "prod")
    assert has_element?(view, "#service-pipelines .badge-neutral", "environment unknown")

    {:ok, staging_view, _html} =
      live(f.conn, "/companies/#{f.a.id}/troubleshoot?service=checkout-api&environment=staging")

    staging_html = render(staging_view)
    assert staging_html =~ "9002"
    refute staging_html =~ "9001"
    assert staging_html =~ "environment unknown"
    assert has_element?(staging_view, "#service-pipelines .env-code", "staging")
  end

  test "unverified and mixed count signals render unknown without crashing", f do
    {:ok, prom} = Tenancy.create_source(f.scope_a, %{name: "metrics", kind: :prometheus})
    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    {:ok, service} =
      Services.create(f.scope_a, %{
        source_id: prom.id,
        environment_id: env.id,
        service_key: "orders-db",
        target: "nw-eu/data/orders-db"
      })

    _unverified =
      config(Map.put(f, :source_a, prom), :a, %{
        kind: "prometheus",
        service_id: service["id"],
        profile: %{
          id: "db-connections",
          version: 1,
          reviewed: true,
          semantics: "gauge",
          unit: "count",
          query: "pg_stat_activity_count",
          capacity_policy: %{unit: "count", limits_verified: false, effective_threshold: 500}
        }
      })

    _insert = fn series ->
      Tenancy.with_scope(f.scope_a, fn ->
        for h <- 23..0//-1 do
          at = DateTime.add(f.now, -h * 3600, :second)

          Repo.query!(
            "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$6,$7)",
            [
              f.a.id,
              prom.id,
              service["id"],
              "db-connections:v1",
              DateTime.add(at, -3600, :second),
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
    end

    # mixed digests in one pass: shared unattributable reason, no crash
    Tenancy.with_scope(f.scope_a, fn ->
      for h <- 23..0//-1 do
        at = DateTime.add(f.now, -h * 3600, :second)
        series = if rem(h, 2) == 0, do: "digest-a", else: "digest-b"

        Repo.query!(
          "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$6,$7)",
          [
            f.a.id,
            prom.id,
            service["id"],
            "db-connections:v1",
            DateTime.add(at, -3600, :second),
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

    {:ok, view, _html} =
      live(f.conn, "/companies/#{f.a.id}/troubleshoot?service=orders-db&environment=prod")

    html = render(view)
    assert html =~ "cannot be attributed to one series or source identity"
    assert html =~ "unknown"
    refute html =~ "NaN"
  end

  test "a verified connection saturation renders with its limit and reason", f do
    {:ok, prom} = Tenancy.create_source(f.scope_a, %{name: "metrics", kind: :prometheus})
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
        id: "db-connections",
        version: 1,
        reviewed: true,
        semantics: "gauge",
        unit: "count",
        query: "pg_stat_activity_count",
        freshness_seconds: 600,
        saturation_signal: "connections",
        capacity_policy: %{
          unit: "count",
          limits_verified: true,
          effective_threshold: 500
        }
      }
    })

    Tenancy.with_scope(f.scope_a, fn ->
      for h <- 23..0//-1 do
        value = 480 - 10 * min(h, 6) - 1 * max(h - 6, 0)
        at = DateTime.add(f.now, -h * 3600, :second)

        Repo.query!(
          "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'prometheus',$5,$6,$6,$7)",
          [
            f.a.id,
            prom.id,
            service["id"],
            "db-connections:v1",
            DateTime.add(at, -3600, :second),
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

    {:ok, view, _html} =
      live(f.conn, "/companies/#{f.a.id}/troubleshoot?service=orders-db&environment=prod")

    html = render(view)
    assert html =~ "db-connections"
    assert html =~ "connections"
    assert html =~ "480.0 / 500.0"
    assert html =~ "(96%)"
    assert has_element?(view, "#storage .badge-danger", "Critical")
    assert html =~ "Connections at 480/500 (96%) on db-connections"
  end

  test "a flaky failing pipeline shows the failure reason and the flaky badge", f do
    {:ok, ado} = Tenancy.create_source(f.scope_a, %{name: "azure", kind: :azure_build})
    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    Services.create(f.scope_a, %{
      source_id: ado.id,
      environment_id: env.id,
      service_key: "checkout-api",
      target: "nw-eu/data/checkout-api"
    })

    # alternating results ending in a failure: the failure reason wins but the
    # flaky badge stays visible
    results = [
      {9601, "succeeded", 6},
      {9602, "failed", 5},
      {9603, "succeeded", 4},
      {9604, "failed", 3},
      {9605, "succeeded", 2},
      {9606, "failed", 1}
    ]

    Tenancy.with_scope(f.scope_a, fn ->
      for {run_id, result, minutes} <- results do
        at = DateTime.add(f.now, -minutes * 60, :second)

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
            %{"branch" => "main", "service" => "checkout-api"}
          ]
        )
      end
    end)

    {:ok, view, _html} =
      live(f.conn, "/companies/#{f.a.id}/troubleshoot?service=checkout-api&environment=prod")

    html = render(view)
    # the failure evidence (3 of the last 5) wins the reason...
    assert html =~ "3 of the last 5 runs failed"
    # ...and the flaky badge stays visible beside it
    assert has_element?(view, ".stat-card .badge-warning", "flaky")
  end

  test "real OOMKilled pod and Warning event render with the OOM suggestion", f do
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

    pod = fn uid, rs_uid, restarts, reason ->
      %{
        "uid" => uid,
        "name" => "checkout-api-7d9f-" <> String.slice(uid, 0, 5),
        "kind" => "Pod",
        "resource_version" => "1",
        "generation" => 0,
        "owners" => [%{"uid" => rs_uid, "kind" => "ReplicaSet"}],
        "containers" => [
          %{
            "name" => "app",
            "restarts" => restarts,
            "ready" => restarts == 0,
            "termination" => %{"reason" => reason, "finished_at" => nil, "exit_code" => 137}
          }
        ],
        "ready" => restarts == 0,
        "phase" => "Running"
      }
    end

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
      "p1-aaaaa" => pod.("p1-aaaaa", "rs1", 3, "OOMKilled"),
      "p2-bbbbb" => pod.("p2-bbbbb", "rs1", 0, ""),
      "e1" => %{
        "uid" => "e1",
        "name" => "checkout-api-7d9f-p1-aa.17x",
        "kind" => "Event",
        "resource_version" => "1",
        "generation" => 0,
        "owners" => [],
        "target_uid" => "p1-aaaaa",
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

    {:ok, view, _html} =
      live(f.conn, "/companies/#{f.a.id}/troubleshoot?service=checkout-api&environment=prod")

    html = render(view)
    assert html =~ "checkout-api-7d9f-p1-aa"
    assert has_element?(view, "#runtime .badge-warning", "OOMKilled")
    assert has_element?(view, "#runtime .badge-warning", "Warning")
    assert html =~ "BackOff ×4"
    assert html =~ "Pods are OOMKilled: compare container memory limit"
  end

  test "the troubleshoot page renders for a member and redirects non-members", f do
    conn_b = init_test_session(build_conn(), operator_token: f.token_b)

    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(conn_b, "/companies/#{f.a.id}/troubleshoot")

    {:ok, view, _html} = live(f.conn, "/companies/#{f.a.id}/troubleshoot")
    assert has_element?(view, "#service-picker")
  end

  test "a company without services shows the empty state, never healthy claims", f do
    conn_b = init_test_session(build_conn(), operator_token: f.token_b)
    {:ok, _view, html} = live(conn_b, "/companies/#{f.b.id}/troubleshoot")

    assert html =~ "No service selected"
    assert html =~ "Map a service to an environment first"
    refute html =~ "Everything is healthy"
    refute html =~ "All systems operational"
  end

  test "the service picker patches the URL to the picked service", f do
    env_staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))

    {:ok, service_staging} =
      Services.create(f.scope_a, %{
        source_id: f.prom.id,
        environment_id: env_staging.id,
        service_key: "storage-prod",
        target: "synthetic-staging/storage-prod"
      })

    assert service_staging["id"]

    {:ok, view, _html} =
      live(f.conn, "/companies/#{f.a.id}/troubleshoot?service=storage-prod&environment=prod")

    view
    |> form("#service-picker")
    |> render_change(%{"target" => "storage-prod|staging"})

    assert_patch(
      view,
      "/companies/#{f.a.id}/troubleshoot?environment=staging&service=storage-prod"
    )

    # the page now shows the staging instance, not the prod one
    html = render(view)
    assert html =~ "synthetic-staging/storage-prod"
  end

  test "unknown service or environment params fall back to the default service", f do
    {:ok, _view, html} =
      live(f.conn, "/companies/#{f.a.id}/troubleshoot?service=nonexistent&environment=prod")

    # the first production service is the default; unknown names never crash
    assert html =~ "synthetic/storage-prod"
    refute html =~ "nonexistent"

    {:ok, _view2, html2} =
      live(f.conn, "/companies/#{f.a.id}/troubleshoot?service=storage-prod&environment=bogus")

    assert html2 =~ "synthetic/storage-prod"
    refute html2 =~ "bogus"
  end

  test "open findings on a service page link straight to the focused investigation", f do
    c = OpsBrain.SourceFixtures.config(f)
    now = f.now

    {:ok, _} =
      OpsBrain.SourceConfig.transaction(c.id, fn trusted ->
        evidence_id =
          OpsBrain.Evidence.save(
            trusted,
            "scoped-failure:" <> Store.digest(%{"run" => 1}),
            "pipeline_task",
            %{"issues" => ["HTTP 401 api.invalid"], "tool" => "compiler", "attempt" => 1},
            now,
            now
          )

        fp =
          OpsBrain.Fingerprints.identify(
            trusted.company_id,
            {trusted.id, "runtime"},
            "compiler",
            "HTTP 401 api.invalid"
          )

        OpsBrain.Issues.record(
          trusted,
          "scoped-failure",
          evidence_id,
          fp,
          %{occurred_at: now, severity: "critical", scope: "synthetic/storage-prod"},
          now
        )
      end)

    {:ok, [group]} = OpsBrain.Issues.list(f.scope_a)

    {:ok, view, html} =
      live(f.conn, "/companies/#{f.a.id}/troubleshoot?service=storage-prod&environment=prod")

    # the finding appears on its service page and links to its focused card
    assert has_element?(view, "#finding-#{group["id"]}")
    assert html =~ "Likely cause"

    assert has_element?(
             view,
             "#finding-#{group["id"]} a[href='/companies/#{f.a.id}/investigations?focus=#{group["id"]}#groups-#{group["id"]}']"
           )
  end

  test "the service page does not inherit a cluster-prefix or CI-only finding", f do
    env_staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))

    {:ok, _east_prod} =
      Services.create(f.scope_a, %{
        source_id: f.prom.id,
        environment_id: env_staging.id,
        service_key: "storage-prod",
        target: "synthetic-east-prod/storage-prod"
      })

    Tenancy.with_scope(f.scope_a, fn ->
      for {fp, data} <- [
            {"exact-page",
             %{"template" => "exact page finding", "scope" => "synthetic/storage-prod"}},
            {"prefix-page",
             %{
               "template" => "prefix collision finding",
               "scope" => "synthetic-east-prod/storage-prod"
             }},
            {"ci-page",
             %{
               "template" => "ci only finding",
               "scope" => "synthetic/storage-prod",
               "prediction_target" => nil
             }}
          ] do
        Repo.query!(
          "INSERT INTO error_fingerprints(company_id,source_id,fingerprint,parser_version,data) VALUES($1::text::uuid,$2::text::uuid,$3,1,$4)",
          [f.a.id, f.prom.id, fp, %{"template" => data["template"]}]
        )

        Repo.query!(
          "INSERT INTO issue_groups(id,company_id,source_id,fingerprint,parser_version,first_seen,last_seen,severity,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,1,$5,$5,'critical',$6)",
          [Ecto.UUID.generate(), f.a.id, f.prom.id, fp, f.now, data]
        )
      end
    end)

    {:ok, _view, prod} =
      live(f.conn, "/companies/#{f.a.id}/troubleshoot?service=storage-prod&environment=prod")

    assert prod =~ "exact page finding"
    refute prod =~ "prefix collision finding"
    refute prod =~ "ci only finding"

    {:ok, _staging_view, staging} =
      live(f.conn, "/companies/#{f.a.id}/troubleshoot?service=storage-prod&environment=staging")

    assert staging =~ "prefix collision finding"
    assert staging =~ "synthetic-east-prod/storage-prod"
    refute staging =~ "exact page finding"
    refute staging =~ "ci only finding"
  end

  test "newer windows from another service do not hide this service metric", f do
    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    {:ok, other} =
      Services.create(f.scope_a, %{
        source_id: f.prom.id,
        environment_id: env.id,
        service_key: "noise",
        target: "synthetic/noise"
      })

    Tenancy.with_scope(f.scope_a, fn ->
      metric_end = DateTime.add(f.now, -7200, :second)

      Repo.query!(
        "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,'metric:selected','metric',$4,$5,$5,$6)",
        [
          f.a.id,
          f.prom.id,
          f.service_id,
          DateTime.add(metric_end, -60, :second),
          metric_end,
          %{
            "condition" => "warning",
            "cpu_percent" => 17,
            "memory_percent" => 40,
            "p95_latency_ms" => 80
          }
        ]
      )

      for n <- 1..101 do
        at = DateTime.add(f.now, -n, :second)

        Repo.query!(
          "INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data) VALUES(gen_random_uuid(),$1::text::uuid,$2::text::uuid,$3::text::uuid,$4,'metric',$5,$6,$6,$7)",
          [
            f.a.id,
            f.prom.id,
            other["id"],
            "noise:#{n}",
            DateTime.add(at, -30, :second),
            at,
            %{"condition" => "critical", "cpu_percent" => 99}
          ]
        )
      end
    end)

    {:ok, view, html} =
      live(f.conn, "/companies/#{f.a.id}/troubleshoot?service=storage-prod&environment=prod")

    assert has_element?(view, "#metrics")
    assert html =~ "17%"
    refute html =~ "99%"
  end
end
