defmodule OpsBrain.Demo.Dataset do
  @moduledoc "Deterministic, explicitly synthetic offline showcase. No clients, credentials or jobs."
  @company "c057e110-0000-4000-8000-000000000001"
  @slug "constellation-demo-northwind-v1"
  @name "Demo · Northwind Retail"
  @version "constellation-offline-v1"

  def company_id, do: @company
  def slug, do: @slug
  def name, do: @name
  def version, do: @version

  def id(key) do
    <<a::binary-size(8), b::binary-size(4), _::binary-size(1), c::binary-size(3),
      _::binary-size(1), d::binary-size(3), e::binary-size(12)>> =
      :crypto.hash(:md5, "#{@version}:#{key}") |> Base.encode16(case: :lower)

    "#{a}-#{b}-4#{c}-8#{d}-#{e}"
  end

  def clusters do
    [
      %{name: "nw-eu-prod", environment: "prod", nodes: 12, replicas: 6},
      %{name: "nw-eu-staging", environment: "staging", nodes: 6, replicas: 2}
    ]
  end

  def workloads do
    ~w(storefront/web storefront/bff checkout/checkout-api checkout/checkout-worker
       payments/payments-api payments/ledger cart/cart-api cart/cart-worker
       catalog/catalog-api catalog/catalog-indexer inventory/inventory-api inventory/stock-sync
       identity/auth-api identity/session-worker notifications/emailer notifications/push-worker
       search/search-api search/search-indexer platform/ingress-nginx platform/cert-manager
       observability/otel-collector observability/grafana data/etl-runner data/reporting)
    |> Enum.map(fn value ->
      [namespace, name] = String.split(value, "/")
      %{namespace: namespace, name: name}
    end)
  end

  def sources do
    for cluster <- clusters(), kind <- ~w(kubernetes prometheus loki) do
      %{
        key: "#{cluster.name}-#{kind}",
        kind: kind,
        cluster: cluster.name,
        environment: cluster.environment,
        name: "DEMO · #{cluster.name} · #{kind}"
      }
    end ++
      [
        %{
          key: "azure-build",
          kind: "azure_build",
          cluster: "delivery",
          environment: nil,
          name: "DEMO · Northwind Build / YAML"
        }
      ]
  end

  def scenarios do
    [
      %{
        key: "checkout",
        title: "Checkout latency after connection-pool rollout",
        service: "checkout-api",
        namespace: "checkout",
        severity: "critical",
        status: "active",
        owner: nil,
        hypothesis:
          "The pool-size increase may exhaust PostgreSQL connections under replica fan-out.",
        counter:
          "Staging has the same image without errors; its traffic and replica count are lower.",
        facts: [
          {"azure-build", "deployment",
           "Build #84071 deployed checkout-api v2.18.0; DB_POOL_SIZE changed 20 → 80."},
          {"nw-eu-prod-kubernetes", "workload_transition",
           "Deployment rolled to 6 replicas; readiness probes began failing."},
          {"nw-eu-prod-prometheus", "metric", "HTTP p95 rose 180 → 2,400 ms; 5xx reached 8.2%."},
          {"nw-eu-prod-loki", "log_sample",
           "checkout-api: SQLSTATE 53300 too_many_connections; pool checkout timed out."},
          {"nw-eu-prod-prometheus", "database_metric",
           "orders-postgres active connections 492 / 500; CPU 42%, disk 58%."}
        ]
      },
      %{
        key: "inventory",
        title: "Inventory pods OOMKilled after cache warm-up",
        service: "inventory-api",
        namespace: "inventory",
        severity: "warning",
        status: "locally_acknowledged",
        owner: "platform-oncall",
        hypothesis: "Cache warm-up after deployment may exceed the 512 MiB container limit.",
        counter: "One old replica also restarted; a historical memory baseline is missing.",
        facts: [
          {"azure-build", "deployment", "inventory-api v1.34.2 enabled eager cache loading."},
          {"nw-eu-prod-kubernetes", "workload_transition",
           "Two pods terminated with OOMKilled, exit code 137, restart count 7."},
          {"nw-eu-prod-prometheus", "metric",
           "Working set reached 510 MiB against a 512 MiB limit."},
          {"nw-eu-prod-loki", "log_sample",
           "Cache warm-up loaded 310,000 catalog entries before termination."}
        ]
      },
      %{
        key: "storage",
        title: "PostgreSQL volume approaching capacity",
        service: "reporting",
        namespace: "data",
        severity: "warning",
        status: "new",
        owner: nil,
        hypothesis: "Retained reporting exports may be consuming the database volume.",
        counter:
          "Growth is irregular; a linear estimate is conditional, not a guaranteed exhaustion time.",
        facts: [
          {"nw-eu-prod-prometheus", "capacity_evaluation",
           "reporting-postgres PVC 86% used; +2.1 GiB/h in this synthetic window."},
          {"nw-eu-prod-kubernetes", "workload_transition",
           "Volume is bound at 250 GiB; no resize event in the retained sample."},
          {"nw-eu-prod-loki", "log_sample",
           "Reporting export batch wrote 18 GiB of intermediate tables."}
        ]
      },
      %{
        key: "registry",
        title: "Image pull denied in staging",
        service: "search-indexer",
        namespace: "search",
        severity: "warning",
        status: "new",
        owner: "delivery-oncall",
        hypothesis: "A tag or repository permission mismatch may explain the denied image pull.",
        counter: "No registry audit evidence is retained; production impact is not established.",
        facts: [
          {"azure-build", "pipeline_failure",
           "Build #84066 pushed search-indexer:4.7.0 to a different repository path."},
          {"nw-eu-staging-kubernetes", "workload_transition",
           "Pod is ImagePullBackOff; registry returned HTTP 403."},
          {"nw-eu-staging-loki", "log_unavailable",
           "No application logs: the container never started."}
        ]
      },
      %{
        key: "telemetry",
        title: "Staging log coverage interrupted",
        service: "otel-collector",
        namespace: "observability",
        severity: "unknown",
        status: "quiet",
        owner: nil,
        hypothesis: "The log backend is unavailable; service condition cannot be inferred.",
        counter:
          "Successful scrape samples do not establish log completeness or overall service health.",
        facts: [
          {"nw-eu-staging-loki", "log_unavailable",
           "Simulated query timed out; the most recent log sample is 28 minutes old."},
          {"nw-eu-staging-prometheus", "metric",
           "Metrics scrape still responds; log coverage remains unknown."}
        ]
      }
    ]
  end

  def build(now) do
    resources = inventory(now)

    rows =
      environment_rows(now) ++
        source_rows(now) ++
        Enum.flat_map(clusters(), fn cluster ->
          Enum.flat_map(Enum.with_index(workloads()), fn {workload, index} ->
            service_rows(cluster, workload, index, now)
          end)
        end) ++
        Enum.map(resources, fn resource ->
          evidence(
            "resource:#{resource["cluster"]}:#{resource["kind"]}:#{resource["namespace"]}:#{resource["name"]}",
            "#{resource["cluster"]}-kubernetes",
            "demo_resource",
            resource,
            now,
            -60
          )
        end) ++ pipeline_rows(now) ++ Enum.flat_map(scenarios(), &scenario_rows(&1, now))

    counts = Enum.frequencies_by(resources, & &1["kind"])

    manifest = %{
      "counts" => counts,
      "resource_count" => length(resources),
      "source_count" => 7,
      "service_count" => 48,
      "pipeline_count" => 72,
      "finding_count" => length(scenarios()),
      "snapshot_at" => DateTime.to_iso8601(now),
      "mode" => "offline snapshot; no live connections"
    }

    rows ++ [evidence("manifest", "azure-build", "demo_manifest", manifest, now, 0)]
  end

  defp environment_rows(now) do
    for env <- ~w(dev staging prod),
        do:
          {"environments",
           %{
             id: id("env:#{env}"),
             company_id: @company,
             name: env,
             inserted_at: now,
             updated_at: now
           }}
  end

  defp source_rows(now) do
    Enum.flat_map(Enum.with_index(sources()), fn {source, index} ->
      unavailable = source.key == "nw-eu-staging-loki"
      at = shift(now, if(unavailable, do: -1680, else: -60))

      [
        {"sources",
         %{
           id: id(source.key),
           company_id: @company,
           environment_id: source.environment && id("env:#{source.environment}"),
           name: source.name,
           kind: source.kind,
           retention_days: 30,
           inserted_at: now,
           updated_at: now
         }},
        {"collection_states",
         %{
           company_id: @company,
           source_id: id(source.key),
           coverage: "synthetic_snapshot",
           mode: "completed",
           completed_at: at,
           last_success_at: at,
           error: if(unavailable, do: "DEMO: simulated timeout; no live connection", else: nil)
         }},
        {"source_budgets",
         %{
           company_id: @company,
           source_id: id(source.key),
           next_at: now,
           requests: 1200 + index * 113,
           bytes: 500_000 + index * 91_000,
           errors: if(unavailable, do: 12, else: 0)
         }}
      ]
    end)
  end

  defp service_rows(cluster, workload, index, now) do
    sid = id("service:#{cluster.name}:#{workload.name}")
    source = id("#{cluster.name}-kubernetes")

    condition =
      cond do
        cluster.environment == "prod" and workload.name == "checkout-api" -> "critical"
        workload.name in ~w(inventory-api reporting search-indexer) -> "warning"
        workload.name == "otel-collector" and cluster.environment == "staging" -> "unknown"
        true -> "normal"
      end

    service =
      {"service_instances",
       %{
         id: sid,
         company_id: @company,
         source_id: source,
         environment_id: id("env:#{cluster.environment}"),
         service_key: workload.name,
         target: "#{cluster.name}/#{workload.namespace}/#{workload.name}"
       }}

    windows =
      for kind <- ~w(metric capacity) do
        key = "window:#{cluster.name}:#{workload.name}:#{kind}"

        data =
          synthetic(%{
            "condition" => condition,
            "service" => workload.name,
            "cluster" => cluster.name,
            "namespace" => workload.namespace,
            "cpu_percent" => 22 + rem(index * 7, 64),
            "memory_percent" => 35 + rem(index * 11, 57),
            "p95_latency_ms" => if(condition == "critical", do: 2400, else: 80 + index * 9),
            "history" =>
              Enum.map(
                0..11,
                &%{
                  "minutes_ago" => (11 - &1) * 5,
                  "cpu_percent" => 20 + rem(index * 7 + &1 * 3, 65)
                }
              ),
            "evaluation_basis" => "Scripted demo evaluation, not a live detector result",
            "missing" =>
              if(condition == "unknown", do: "fresh log evidence unavailable", else: nil),
            "forecast" =>
              if(workload.name == "reporting" and kind == "capacity",
                do: %{
                  "disk_used_percent" => 86,
                  "growth_gib_per_hour" => 2.1,
                  "conditional_hours_remaining" => 16.7,
                  "assumption" => "250 GiB volume; constant synthetic growth"
                },
                else: nil
              )
          })

        {"observation_windows",
         %{
           id: id(key),
           company_id: @company,
           source_id: source,
           service_id: sid,
           profile: "#{workload.name}:#{kind}",
           kind: kind,
           window_start: shift(now, -3600),
           window_end: shift(now, -60),
           received_at: now,
           revision: 1,
           data: data
         }}
      end

    [service | windows]
  end

  def inventory(now) do
    Enum.flat_map(clusters(), fn cluster ->
      base = %{
        "cluster" => cluster.name,
        "environment" => cluster.environment,
        "snapshot_at" => DateTime.to_iso8601(now),
        "namespace" => "—"
      }

      resource = fn kind, name, ns, status, details ->
        Map.merge(base, %{
          "kind" => kind,
          "name" => name,
          "namespace" => ns,
          "status" => status,
          "details" => details
        })
        |> synthetic()
      end

      namespaces = Enum.uniq_by(workloads(), & &1.namespace)

      nodes =
        for n <- 1..cluster.nodes,
            do:
              resource.(
                "Node",
                "#{cluster.name}-pool-#{String.pad_leading(to_string(n), 2, "0")}",
                "—",
                if(n == 3 and cluster.environment == "prod", do: "DiskPressure", else: "Ready"),
                %{
                  "zone" => "westeurope-#{1 + rem(n, 3)}",
                  "kubeletVersion" => "v1.31.8",
                  "capacity" => %{"cpu" => "8", "memory" => "32Gi", "pods" => "110"},
                  "allocatable" => %{"cpu" => "7800m", "memory" => "29Gi"}
                }
              )

      workloads =
        Enum.flat_map(Enum.with_index(workloads()), fn {w, index} ->
          issue =
            cond do
              w.name == "checkout-api" and cluster.environment == "prod" ->
                "ReadinessFailed"

              w.name == "inventory-api" and cluster.environment == "prod" ->
                "OOMKilled"

              w.name == "search-indexer" and cluster.environment == "staging" ->
                "ImagePullBackOff"

              true ->
                "Running"
            end

          version =
            case w.name do
              "checkout-api" -> "2.18.0"
              "inventory-api" -> "1.34.2"
              "search-indexer" -> "4.7.0"
              _ -> "#{1 + rem(index, 4)}.#{12 + index}.0"
            end

          details = %{
            "replicas" => cluster.replicas,
            "readyReplicas" => cluster.replicas - if(issue == "Running", do: 0, else: 1),
            "image" => "registry.demo.invalid/northwind/#{w.name}:#{version}",
            "requests" => %{"cpu" => "250m", "memory" => "256Mi"},
            "limits" => %{"cpu" => "1500m", "memory" => "512Mi"},
            "labels" => %{"app.kubernetes.io/name" => w.name, "team" => w.namespace}
          }

          pods =
            for n <- 1..cluster.replicas do
              status = if n == 1, do: issue, else: "Running"

              resource.(
                "Pod",
                "#{w.name}-7c84b9d6f-#{String.pad_leading(to_string(index * 10 + n), 5, "0")}",
                w.namespace,
                status,
                Map.merge(details, %{
                  "node" =>
                    "#{cluster.name}-pool-#{String.pad_leading(to_string(1 + rem(index + n, cluster.nodes)), 2, "0")}",
                  "podIP" => "10.42.#{index + 1}.#{n + 10}",
                  "restartCount" => if(status == "OOMKilled", do: 7, else: 0),
                  "containerReady" => status == "Running",
                  "owner" => "#{w.name}-7c84b9d6f"
                })
              )
            end

          [
            resource.(
              "Deployment",
              w.name,
              w.namespace,
              if(issue == "Running", do: "Available", else: "Degraded"),
              details
            ),
            resource.(
              "ReplicaSet",
              "#{w.name}-7c84b9d6f",
              w.namespace,
              "Observed",
              Map.put(details, "owner", w.name)
            ),
            resource.("Service", w.name, w.namespace, "Configured", %{
              "type" => "ClusterIP",
              "port" => 8080,
              "selector" => %{"app" => w.name}
            }),
            resource.(
              "Event",
              "#{w.name}.sample",
              w.namespace,
              if(issue == "Running", do: "Normal", else: "Warning"),
              %{
                "reason" => if(issue == "Running", do: "Scheduled", else: issue),
                "involvedObject" => w.name,
                "count" => if(issue == "Running", do: 1, else: 7)
              }
            )
            | pods
          ]
        end)

      databases =
        Enum.flat_map(
          Enum.with_index(~w(orders-postgres reporting-postgres session-redis)),
          fn {db, index} ->
            details = %{
              "engine" =>
                if(String.ends_with?(db, "redis"), do: "Redis 7.2", else: "PostgreSQL 16"),
              "replicas" => 3,
              "endpoint" => "#{db}.data.svc.demo.invalid",
              "port" => if(index == 2, do: 6379, else: 5432),
              "volume_gib" => 250,
              "volume_used_percent" => if(index == 1, do: 86, else: 58),
              "connections" =>
                if(index == 0 and cluster.environment == "prod", do: 492, else: 62),
              "max_connections" => 500,
              "replication_lag_seconds" => 0.8
            }

            status =
              if(cluster.environment == "prod" and index < 2, do: "Warning", else: "Available")

            [
              resource.("Database", db, "data", status, details),
              resource.("StatefulSet", db, "data", status, details),
              resource.("PersistentVolumeClaim", "data-#{db}-0", "data", "Bound", %{
                "capacity" => "250Gi",
                "storageClass" => "managed-premium"
              })
              | for(
                  n <- 0..2,
                  do:
                    resource.(
                      "Pod",
                      "#{db}-#{n}",
                      "data",
                      "Running",
                      Map.merge(details, %{
                        "ordinal" => n,
                        "role" => if(n == 0, do: "primary", else: "replica")
                      })
                    )
                )
            ]
          end
        )

      [
        resource.("Cluster", cluster.name, "—", "Simulated", %{
          "provider" => "AKS-shaped fixture",
          "region" => "westeurope",
          "version" => "1.31.8"
        })
      ] ++
        Enum.map(
          namespaces,
          &resource.("Namespace", &1.namespace, &1.namespace, "Active", %{"team" => &1.namespace})
        ) ++ nodes ++ workloads ++ databases
    end)
  end

  defp pipeline_rows(now) do
    Enum.flat_map(0..71, fn index ->
      service =
        case index do
          71 -> "checkout-api"
          70 -> "inventory-api"
          66 -> "search-indexer"
          _ -> nil
        end

      w = Enum.find(workloads(), &(&1.name == service)) || Enum.at(workloads(), rem(index, 24))
      cluster = if index == 66, do: "nw-eu-staging", else: "nw-eu-prod"

      result =
        if index in [70, 71],
          do: "succeeded",
          else:
            Enum.at(
              ~w(succeeded succeeded succeeded failed succeeded canceled partiallySucceeded),
              rem(index, 7)
            )

      at = shift(now, -(71 - index) * 900 - 1800)

      row =
        {"pipeline_runs",
         %{
           id: id("run:#{index}"),
           company_id: @company,
           source_id: id("azure-build"),
           project_id: id("project"),
           run_id: 84000 + index,
           definition_id: 100 + rem(index, 24),
           status: "completed",
           result: result,
           finish_at: at,
           received_at: shift(at, 30),
           revision: 1,
           data: synthetic(%{"branch" => "refs/heads/main", "service" => w.name})
         }}

      deployment =
        evidence(
          "deploy:#{index}",
          "azure-build",
          "deployment",
          %{
            "run_id" => 84000 + index,
            "target_id" => id("service:#{cluster}:#{w.name}"),
            "reported_result" => result,
            "attempt" => 1
          },
          now,
          DateTime.diff(at, now)
        )

      if rem(index, 9) == 0, do: [row], else: [row, deployment]
    end)
  end

  defp scenario_rows(scenario, now) do
    gid = id("finding:#{scenario.key}")
    fp = "demo:#{scenario.key}"
    cluster = if scenario.key in ~w(registry telemetry), do: "nw-eu-staging", else: "nw-eu-prod"

    offset =
      case scenario.key do
        "inventory" -> -2700
        "registry" -> -6300
        _ -> -1800
      end

    at = shift(now, offset)
    primary = elem(hd(scenario.facts), 0)

    base = [
      {"error_fingerprints",
       %{
         company_id: @company,
         fingerprint: fp,
         source_id: id(primary),
         parser_version: 1,
         data: synthetic(%{"template" => scenario.title})
       }},
      {"issue_groups",
       %{
         id: gid,
         company_id: @company,
         source_id: id(primary),
         fingerprint: fp,
         parser_version: 1,
         first_seen: at,
         last_seen: shift(now, -60),
         severity: scenario.severity,
         status: scenario.status,
         owner: scenario.owner,
         data:
           synthetic(%{
             "template" => scenario.title,
             "reason" => scenario.hypothesis,
             "scope" => "DEMO · #{cluster}/#{scenario.namespace}/#{scenario.service}",
             "count_basis" =>
               "distinct synthetic evidence observations, not independent incidents",
             "missing" => "Causal mechanism not confirmed; inspect alternative explanations."
           })
       }},
      {"notification_outbox",
       %{
         id: id("notice:#{scenario.key}"),
         company_id: @company,
         source_id: id(primary),
         group_id: gid,
         revision: 1,
         destination: "DEMO · local-only / no delivery",
         status: "disabled",
         attempts: 0,
         next_at: now,
         updated_at: now
       }}
    ]

    facts = Enum.with_index(scenario.facts)

    samples =
      Enum.flat_map(facts, fn {{source, kind, text}, index} ->
        key = "fact:#{scenario.key}:#{index}"
        occurrence = id("occurrence:#{key}")
        occurred = shift(at, index * 90)

        run_id =
          if source == "azure-build",
            do:
              Enum.find_value(
                [{"checkout", 84071}, {"inventory", 84070}, {"registry", 84066}],
                fn {key, run} -> if key == scenario.key, do: run end
              )

        [
          evidence(
            key,
            source,
            kind,
            %{
              "summary" => text,
              "scenario" => scenario.key,
              "cluster" => cluster,
              "namespace" => scenario.namespace,
              "service" => scenario.service,
              "run_id" => run_id,
              "target_id" => id("service:#{cluster}:#{scenario.service}"),
              "reported_result" => if(kind == "deployment", do: "succeeded", else: nil),
              "attempt" => 1
            },
            now,
            DateTime.diff(occurred, now)
          ),
          {"failure_occurrences",
           %{
             id: occurrence,
             company_id: @company,
             source_id: id(source),
             occurrence_key: key,
             run_id: run_id,
             group_id: gid,
             evidence_id: id(key),
             occurred_at: occurred,
             fingerprint: fp,
             parser_version: 1,
             evidence_revision: 1
           }},
          {"occurrence_evidence",
           %{
             id: id("revision:#{key}"),
             company_id: @company,
             source_id: id(source),
             occurrence_id: occurrence,
             group_id: gid,
             evidence_id: id(key),
             revision: 1,
             fingerprint: fp,
             parser_version: 1,
             reason: "synthetic initial observation",
             inserted_at: shift(occurred, 15)
           }}
        ]
      end)

    symptom = %{
      company_id: @company,
      environment_id: id("env:#{if cluster == "nw-eu-prod", do: "prod", else: "staging"}"),
      target_id: id("service:#{cluster}:#{scenario.service}"),
      evidence_id: id("fact:#{scenario.key}:1"),
      occurred_at: DateTime.to_unix(at) + 90,
      received_at: DateTime.to_unix(at) + 105
    }

    change = %{
      symptom
      | evidence_id: id("fact:#{scenario.key}:0"),
        occurred_at: DateTime.to_unix(at),
        received_at: DateTime.to_unix(at) + 15
    }

    changes = if scenario.key in ~w(checkout inventory registry), do: [change], else: []
    result = OpsBrain.Correlation.evaluate(symptom, changes, [], DateTime.to_unix(now))

    result =
      update_in(
        result,
        [:candidates],
        &Enum.map(&1, fn c ->
          Map.update!(c, :counterevidence, fn existing -> existing ++ [scenario.counter] end)
        end)
      )

    timeline =
      Enum.map(facts, fn {{source, kind, text}, index} ->
        %{
          "evidence_id" => id("fact:#{scenario.key}:#{index}"),
          "source" => source,
          "kind" => kind,
          "at" => DateTime.to_iso8601(shift(at, index * 90)),
          "summary" => text
        }
      end)

    base ++
      samples ++
      [
        evidence(
          "correlation:#{scenario.key}",
          primary,
          "correlation",
          %{
            "group_id" => gid,
            "result" => result,
            "timeline" => timeline,
            "hypothesis" => scenario.hypothesis
          },
          now,
          -30
        )
      ]
  end

  defp evidence(key, source, kind, data, now, offset) do
    {"evidence_items",
     %{
       id: id(key),
       company_id: @company,
       source_id: id(source),
       evidence_key: key,
       kind: kind,
       occurred_at: shift(now, offset),
       received_at: shift(now, min(offset + 15, 0)),
       expires_at: shift(now, 30 * 86_400),
       data: synthetic(data)
     }}
  end

  defp synthetic(data), do: Map.merge(data, %{"synthetic" => true, "fixture_version" => @version})
  defp shift(now, seconds), do: DateTime.add(now, seconds, :second)
end
