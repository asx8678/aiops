defmodule OpsBrain.Insights.ResourcesTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures

  alias OpsBrain.{Demo, Insights, Repo, Services, Store, Tenancy, TestAdminRepo}
  alias OpsBrain.Insights.Sources

  @kinds %{
    "pods" => "Pod",
    "deployments" => "Deployment",
    "replicasets" => "ReplicaSet",
    "events" => "Event"
  }
  @resources Map.keys(@kinds)

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, k8s_a} = Tenancy.create_source(f.scope_a, %{name: "k8s", kind: :kubernetes})
    {:ok, k8s_b} = Tenancy.create_source(f.scope_b, %{name: "k8s", kind: :kubernetes})

    env_a_prod = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))
    env_a_staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))
    env_b_prod = Enum.find(f.envs, &(&1.company_id == f.b.id and &1.name == :prod))

    services =
      for {label, key, scope, env, source, target} <- [
            {"checkout-a", "checkout-api", f.scope_a, env_a_prod, k8s_a,
             "nw-eu/data/checkout-api"},
            {"reporting-a-prod", "reporting", f.scope_a, env_a_prod, k8s_a,
             "nw-eu/data/reporting"},
            {"reporting-a-staging", "reporting", f.scope_a, env_a_staging, k8s_a,
             "nw-eu-staging/data/reporting"},
            {"checkout-b", "checkout-api", f.scope_b, env_b_prod, k8s_b,
             "other-b/data/checkout-api"}
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
      k8s_a: k8s_a,
      k8s_b: k8s_b,
      services: Map.new(services)
    })
  end

  # Trusted kubernetes source config bound to one service, watching all kinds.
  defp put_k8s_config(f, source, service_id) do
    config(Map.put(f, :source_a, source), :a, %{
      kind: "kubernetes",
      service_id: service_id,
      namespace: "data",
      resources: @resources
    })
  end

  defp put_k8s_config_b(f, source, service_id) do
    config(Map.put(f, :source_b, source), :b, %{
      kind: "kubernetes",
      service_id: service_id,
      namespace: "data",
      resources: @resources
    })
  end

  defp scope_digest(c),
    do: Store.digest({c[:endpoint], c[:namespace], c[:approved_ips], c[:credential_env]})

  defp insert_cursor(scope, company_id, source_id, resource, now, data) do
    Tenancy.with_scope(scope, fn ->
      Repo.query!(
        "INSERT INTO kubernetes_cursors(company_id,source_id,resource,revision,updated_at,data) VALUES($1::text::uuid,$2::text::uuid,$3,1,$4,$5) ON CONFLICT(source_id,resource) DO UPDATE SET data=EXCLUDED.data,updated_at=EXCLUDED.updated_at",
        [company_id, source_id, resource, now, data]
      )
    end)
  end

  # One cursor per resource kind, splitting the uid -> object inventory.
  defp seed_cursors(f, source, company_id, scope, c, inventory, opts \\ []) do
    for {resource, kind} <- @kinds do
      objects = inventory |> Enum.filter(fn {_uid, o} -> o["kind"] == kind end) |> Map.new()

      data =
        %{"namespace" => c[:namespace], "objects" => objects, "scope" => scope_digest(c)}
        |> Map.merge(%{
          "observed_at" => DateTime.to_unix(f.now),
          "coverage" => "complete",
          "gap" => false,
          "error" => nil
        })
        |> Map.merge(Map.new(opts))

      insert_cursor(scope, company_id, source.id, resource, f.now, data)
    end
  end

  defp deployment(uid, name, replicas, ready) do
    %{
      "uid" => uid,
      "name" => name,
      "kind" => "Deployment",
      "resource_version" => "1",
      "generation" => 1,
      "owners" => [],
      "observed_generation" => 1,
      "replicas" => replicas,
      "ready_replicas" => ready,
      "available_replicas" => ready
    }
  end

  defp replica_set(uid, name, dep_uid, replicas, ready) do
    %{
      "uid" => uid,
      "name" => name,
      "kind" => "ReplicaSet",
      "resource_version" => "1",
      "generation" => 1,
      "owners" => [%{"uid" => dep_uid, "kind" => "Deployment"}],
      "observed_generation" => 1,
      "replicas" => replicas,
      "ready_replicas" => ready,
      "available_replicas" => ready
    }
  end

  defp pod(uid, name, rs_uid, opts \\ []) do
    restarts = Keyword.get(opts, :restarts, 3)
    reason = Keyword.get(opts, :reason, "OOMKilled")
    ready = Keyword.get(opts, :ready, restarts == 0)

    %{
      "uid" => uid,
      "name" => name,
      "kind" => "Pod",
      "resource_version" => "1",
      "generation" => 0,
      "owners" => if(rs_uid, do: [%{"uid" => rs_uid, "kind" => "ReplicaSet"}], else: []),
      "containers" => [
        %{
          "name" => "app",
          "restarts" => restarts,
          "ready" => ready,
          "termination" => %{"reason" => reason, "finished_at" => nil, "exit_code" => 137}
        }
      ],
      "ready" => ready,
      "phase" => "Running"
    }
  end

  defp event(uid, name, target_uid, opts \\ []) do
    %{
      "uid" => uid,
      "name" => name,
      "kind" => "Event",
      "resource_version" => "1",
      "generation" => 0,
      "owners" => [],
      "target_uid" => target_uid,
      "target_kind" => Keyword.get(opts, :target_kind, "Pod"),
      "count" => Keyword.get(opts, :count, 4),
      "type" => Keyword.get(opts, :type, "Warning"),
      "reason" => Keyword.get(opts, :reason, "BackOff"),
      "last_seen" => nil
    }
  end

  defp checkout_inventory do
    %{
      "d1" => deployment("d1", "checkout-api", 2, 1),
      "rs1" => replica_set("rs1", "checkout-api-7d9f", "d1", 2, 1),
      "p1" => pod("p1", "checkout-api-7d9f-abcde", "rs1"),
      "p2" => pod("p2", "checkout-api-7d9f-fghij", "rs1", restarts: 0, reason: ""),
      "e1" => event("e1", "checkout-api-7d9f-abcde.17x", "p1")
    }
  end

  describe "mapped runtime objects" do
    test "OOMKilled pod and Warning event render on the right service with the OOM suggestion",
         f do
      c = put_k8s_config(f, f.k8s_a, f.services["checkout-a"])
      seed_cursors(f, f.k8s_a, f.a.id, f.scope_a, c, checkout_inventory())

      assert {:ok, info} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)

      oom = Enum.find(info.resources, &(&1["name"] == "checkout-api-7d9f-abcde"))
      assert oom["kind"] == "Pod"
      assert oom["status"] == "OOMKilled"
      assert oom["service"] == "checkout-api"
      assert oom["environment"] == "prod"
      assert oom["cluster"] == "nw-eu"
      assert oom["namespace"] == "data"
      assert oom["details"]["restartCount"] == 3

      evt = Enum.find(info.resources, &(&1["kind"] == "Event"))
      assert evt["status"] == "Warning"
      assert evt["service"] == "checkout-api"
      assert evt["details"]["reason"] == "BackOff"
      assert evt["details"]["count"] == 4

      dep = Enum.find(info.resources, &(&1["kind"] == "Deployment"))
      assert dep["status"] == "Degraded"
      assert dep["details"]["replicas"] == 2
      assert dep["details"]["readyReplicas"] == 1

      running = Enum.find(info.resources, &(&1["name"] == "checkout-api-7d9f-fghij"))
      assert running["status"] == "Running"

      assert Enum.any?(info.checks, &(&1 =~ "Pods are OOMKilled"))
      assert Enum.any?(info.checks, &(&1 =~ "compare container memory limit"))

      # the command read stays bounded to abnormal runtime signals
      {:ok, command_read} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.resources(f.now) end)

      assert Enum.any?(
               command_read,
               &(&1["kind"] == "Pod" and &1["status"] == "OOMKilled")
             )

      assert Enum.any?(
               command_read,
               &(&1["kind"] == "Event" and &1["status"] == "Warning")
             )

      assert Enum.any?(
               command_read,
               &(&1["kind"] == "Deployment" and &1["status"] == "Degraded")
             )

      refute Enum.any?(
               command_read,
               &(&1["kind"] == "Pod" and &1["status"] == "Running")
             )

      # real runtime anomalies reach command attention with service metadata
      assert {:ok, data} = Insights.command(f.scope_a, f.now)

      oom_item = Enum.find(data.attention, &(&1.kind == "Pod"))
      assert oom_item.level == "critical"
      assert oom_item.service == "checkout-api"
      assert oom_item.environment == "prod"
      assert oom_item.title =~ "pods OOMKilled"

      event_item = Enum.find(data.attention, &(&1.kind == "Event"))
      assert event_item.level == "warning"
      assert event_item.service == "checkout-api"
      assert event_item.environment == "prod"
      assert event_item.detail =~ "BackOff ×4"

      # degraded workloads are suppressed while their pods are already flagged
      refute Enum.any?(data.attention, &(&1.kind == "Workload"))
      refute Enum.any?(data.attention, &(&1.kind in ["Node", "Database"]))
    end

    test "a shared namespace attributes each object to its own service", f do
      c = put_k8s_config(f, f.k8s_a, f.services["checkout-a"])

      inventory =
        Map.merge(checkout_inventory(), %{
          "d2" => deployment("d2", "reporting", 1, 1),
          "rs2" => replica_set("rs2", "reporting-5x", "d2", 1, 1),
          "p3" => pod("p3", "reporting-5x-11111", "rs2"),
          "e2" => event("e2", "reporting-5x-11111.9z", "p3")
        })

      seed_cursors(f, f.k8s_a, f.a.id, f.scope_a, c, inventory)

      assert {:ok, checkout} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert {:ok, reporting} = Insights.service(f.scope_a, "reporting", "prod", f.now)

      reporting_pod = Enum.find(reporting.resources, &(&1["name"] == "reporting-5x-11111"))
      assert reporting_pod["service"] == "reporting"
      # the bound environment/cluster wins: never the staging instance
      assert reporting_pod["environment"] == "prod"
      assert reporting_pod["cluster"] == "nw-eu"

      assert Enum.any?(
               reporting.resources,
               &(&1["kind"] == "Event" and &1["service"] == "reporting")
             )

      refute Enum.any?(reporting.resources, &(&1["name"] == "checkout-api-7d9f-abcde"))
      assert Enum.any?(checkout.resources, &(&1["name"] == "checkout-api-7d9f-abcde"))
      refute Enum.any?(checkout.resources, &(&1["name"] == "reporting-5x-11111"))
    end

    test "objects stay tenant isolated", f do
      c_a = put_k8s_config(f, f.k8s_a, f.services["checkout-a"])
      seed_cursors(f, f.k8s_a, f.a.id, f.scope_a, c_a, checkout_inventory())

      c_b = put_k8s_config_b(f, f.k8s_b, f.services["checkout-b"])

      seed_cursors(f, f.k8s_b, f.b.id, f.scope_b, c_b, %{
        "d1" => deployment("d1", "checkout-api", 1, 1),
        "rs1" => replica_set("rs1", "checkout-api-b", "d1", 1, 1),
        "p1" => pod("p1", "checkout-api-b-00001", "rs1"),
        "e1" => event("e1", "checkout-api-b-00001.3z", "p1")
      })

      assert {:ok, a} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert {:ok, b} = Insights.service(f.scope_b, "checkout-api", "prod", f.now)

      refute Enum.any?(a.resources, &(&1["name"] == "checkout-api-b-00001"))
      assert Enum.any?(a.resources, &(&1["name"] == "checkout-api-7d9f-abcde"))

      b_pod = Enum.find(b.resources, &(&1["name"] == "checkout-api-b-00001"))
      assert b_pod["service"] == "checkout-api"
      assert b_pod["cluster"] == "other-b"
      refute Enum.any?(b.resources, &(&1["name"] == "checkout-api-7d9f-abcde"))
    end
  end

  describe "unresolvable ownership stays unattributed" do
    test "broken chains and unknown targets never become bound-service objects", f do
      c = put_k8s_config(f, f.k8s_a, f.services["checkout-a"])

      inventory = %{
        "p4" => pod("p4", "orphan-pod", "rs-gone"),
        "rs3" => replica_set("rs3", "orphan-rs", "d-gone", 2, 1),
        "e3" => event("e3", "orphan-pod.1z", "uid-gone"),
        "e4" => event("e4", "orphan-rs.2z", "rs3")
      }

      seed_cursors(f, f.k8s_a, f.a.id, f.scope_a, c, inventory)

      # nothing is attributed, so no service page shows these objects
      {:ok, []} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.resources(f.now, "checkout-api") end)

      assert {:ok, info} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert info.resources == []

      # the anomalies still surface in the command read, unattributed
      {:ok, command_read} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.resources(f.now) end)

      orphan_pod = Enum.find(command_read, &(&1["kind"] == "Pod"))
      assert orphan_pod["service"] == nil
      assert orphan_pod["status"] == "OOMKilled"
      # unattributed objects keep the trusted binding's location
      assert orphan_pod["cluster"] == "nw-eu"
      assert orphan_pod["environment"] == "prod"

      orphan_event = Enum.find(command_read, &(&1["kind"] == "Event"))
      assert orphan_event["service"] == nil

      assert {:ok, data} = Insights.command(f.scope_a, f.now)
      unattributed = Enum.find(data.attention, &(&1.kind == "Pod"))
      assert unattributed.service == nil
      assert unattributed.environment == "prod"
      assert unattributed.level == "critical"
      assert String.contains?(unattributed.title, "nw-eu")
    end

    test "a missing bound instance leaves objects unattributed, never location-inferred",
         f do
      c = put_k8s_config(f, f.k8s_a, "00000000-0000-4000-8000-000000000099")

      seed_cursors(f, f.k8s_a, f.a.id, f.scope_a, c, checkout_inventory())

      {:ok, []} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.resources(f.now, "checkout-api") end)

      {:ok, command_read} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.resources(f.now) end)

      pod = Enum.find(command_read, &(&1["kind"] == "Pod"))
      assert pod["service"] == nil
      assert pod["environment"] == nil
    end
  end

  describe "same-cluster environments do not leak across pages" do
    test "prod and staging namesakes on one cluster stay on their own pages", f do
      {:ok, k8s_prod} =
        Tenancy.create_source(f.scope_a, %{name: "k8s-prod", kind: :kubernetes})

      {:ok, k8s_staging} =
        Tenancy.create_source(f.scope_a, %{name: "k8s-staging", kind: :kubernetes})

      env_prod = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

      env_staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))

      {:ok, prod_inst} =
        Services.create(f.scope_a, %{
          source_id: k8s_prod.id,
          environment_id: env_prod.id,
          service_key: "billing-api",
          target: "shared/data/billing-api"
        })

      {:ok, staging_inst} =
        Services.create(f.scope_a, %{
          source_id: k8s_staging.id,
          environment_id: env_staging.id,
          service_key: "billing-api",
          target: "shared/data/billing-api"
        })

      c_prod = put_k8s_config(f, k8s_prod, prod_inst["id"])
      c_staging = put_k8s_config(f, k8s_staging, staging_inst["id"])

      # identical object names, cluster and namespace: only the UIDs differ
      seed_cursors(
        f,
        k8s_prod,
        f.a.id,
        f.scope_a,
        c_prod,
        %{
          "d1p" => deployment("d1p", "billing-api", 2, 2),
          "rs1p" => replica_set("rs1p", "billing-api-7d9f", "d1p", 1, 1),
          "p1p" => pod("p1p", "billing-api-7d9f-abcde", "rs1p")
        }
      )

      seed_cursors(
        f,
        k8s_staging,
        f.a.id,
        f.scope_a,
        c_staging,
        %{
          "d1s" => deployment("d1s", "billing-api", 1, 1),
          "rs1s" => replica_set("rs1s", "billing-api-7d9f", "d1s", 1, 1),
          "p1s" => pod("p1s", "billing-api-7d9f-abcde", "rs1s")
        }
      )

      assert {:ok, prod} = Insights.service(f.scope_a, "billing-api", "prod", f.now)

      assert {:ok, staging} = Insights.service(f.scope_a, "billing-api", "staging", f.now)

      # both pages retain exactly one object of the shared display name
      prod_pods = Enum.filter(prod.resources, &(&1["name"] == "billing-api-7d9f-abcde"))
      assert length(prod_pods) == 1
      assert hd(prod_pods)["environment"] == "prod"
      assert hd(prod_pods)["service_id"] == prod_inst["id"]

      staging_pods = Enum.filter(staging.resources, &(&1["name"] == "billing-api-7d9f-abcde"))
      assert length(staging_pods) == 1
      assert hd(staging_pods)["environment"] == "staging"
      assert hd(staging_pods)["service_id"] == staging_inst["id"]

      assert Enum.all?(prod.resources, &(&1["environment"] == "prod"))
      assert Enum.all?(staging.resources, &(&1["environment"] == "staging"))
    end
  end

  describe "unattributed anomalies keep source and location identity" do
    test "same-named unattributed objects on two clusters neither vanish nor suppress each other",
         f do
      {:ok, k8s_alpha} =
        Tenancy.create_source(f.scope_a, %{name: "k8s-alpha", kind: :kubernetes})

      {:ok, k8s_beta} =
        Tenancy.create_source(f.scope_a, %{name: "k8s-beta", kind: :kubernetes})

      env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

      {:ok, alpha_inst} =
        Services.create(f.scope_a, %{
          source_id: k8s_alpha.id,
          environment_id: env.id,
          service_key: "payments",
          target: "alpha/data/payments"
        })

      {:ok, beta_inst} =
        Services.create(f.scope_a, %{
          source_id: k8s_beta.id,
          environment_id: env.id,
          service_key: "payments",
          target: "beta/data/payments"
        })

      c_alpha = put_k8s_config(f, k8s_alpha, alpha_inst["id"])
      c_beta = put_k8s_config(f, k8s_beta, beta_inst["id"])

      # identical names and kinds; broken chains leave both unattributed
      seed_cursors(
        f,
        k8s_alpha,
        f.a.id,
        f.scope_a,
        c_alpha,
        %{"pa" => pod("pa", "shared-anomaly", "rs-gone")}
      )

      seed_cursors(
        f,
        k8s_beta,
        f.a.id,
        f.scope_a,
        c_beta,
        %{"pb" => pod("pb", "shared-anomaly", "rs-gone")}
      )

      {:ok, command_read} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.resources(f.now) end)

      shared = Enum.filter(command_read, &(&1["name"] == "shared-anomaly"))
      assert length(shared) == 2
      assert Enum.map(shared, & &1["cluster"]) |> Enum.sort() == ["alpha", "beta"]
      assert Enum.all?(shared, &(&1["service"] == nil))

      assert {:ok, data} = Insights.command(f.scope_a, f.now)

      assert Enum.any?(
               data.attention,
               &(&1.kind == "Pod" and String.contains?(&1.title, "alpha: pods OOMKilled"))
             )

      assert Enum.any?(
               data.attention,
               &(&1.kind == "Pod" and String.contains?(&1.title, "beta: pods OOMKilled"))
             )

      # re-seed beta with only a degraded workload: alpha's flagged pod in its
      # own scope must not suppress beta's workload
      seed_cursors(
        f,
        k8s_beta,
        f.a.id,
        f.scope_a,
        c_beta,
        %{"db" => deployment("db", "foreign-workload", 2, 1)}
      )

      assert {:ok, data2} = Insights.command(f.scope_a, f.now)

      assert Enum.any?(
               data2.attention,
               &(&1.kind == "Workload" and String.contains?(&1.title, "beta"))
             )

      assert Enum.any?(
               data2.attention,
               &(&1.kind == "Pod" and String.contains?(&1.title, "alpha: pods OOMKilled"))
             )
    end
  end

  describe "explicitly not-ready pods are never healthy" do
    test "a Running phase with not-ready containers renders NotReady", f do
      c = put_k8s_config(f, f.k8s_a, f.services["checkout-a"])

      seed_cursors(
        f,
        f.k8s_a,
        f.a.id,
        f.scope_a,
        c,
        %{
          "d1" => deployment("d1", "checkout-api", 1, 1),
          "rs1" => replica_set("rs1", "checkout-api-7d9f", "d1", 1, 1),
          "p5" =>
            pod("p5", "checkout-api-7d9f-notready", "rs1", restarts: 0, reason: "", ready: false)
        }
      )

      assert {:ok, info} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)

      not_ready = Enum.find(info.resources, &(&1["name"] == "checkout-api-7d9f-notready"))
      assert not_ready["status"] == "NotReady"

      assert {:ok, data} = Insights.command(f.scope_a, f.now)

      assert Enum.any?(
               data.attention,
               &(&1.kind == "Pod" and String.contains?(&1.title, "NotReady"))
             )
    end
  end

  describe "not-current data never renders as health" do
    test "missing source config, stale, gapped, errored and scope-mismatched cursors are omitted",
         f do
      # no config registered at all: the cursor is not trusted
      seed_cursors(f, f.k8s_a, f.a.id, f.scope_a, %{namespace: "data"}, checkout_inventory())

      {:ok, []} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.resources(f.now, "checkout-api") end)

      assert {:ok, info} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert info.resources == []
      refute Enum.any?(info.checks, &(&1 =~ "OOMKilled"))

      # configured but not current in various collector states
      c = put_k8s_config(f, f.k8s_a, f.services["checkout-a"])

      stale = %{
        "namespace" => "data",
        "objects" => %{"p1" => pod("p1", "stale-pod", nil)},
        "scope" => scope_digest(c),
        "observed_at" => DateTime.to_unix(f.now) - 1000,
        "coverage" => "complete",
        "gap" => false,
        "error" => nil
      }

      insert_cursor(f.scope_a, f.a.id, f.k8s_a.id, "pods", f.now, stale)

      gapped = %{
        "namespace" => "data",
        "objects" => %{"p2" => pod("p2", "gapped-pod", nil)},
        "scope" => scope_digest(c),
        "observed_at" => DateTime.to_unix(f.now),
        "coverage" => "partial",
        "gap" => true,
        "error" => nil
      }

      insert_cursor(f.scope_a, f.a.id, f.k8s_a.id, "deployments", f.now, gapped)

      errored = %{
        "namespace" => "data",
        "objects" => %{"p3" => pod("p3", "errored-pod", nil)},
        "scope" => scope_digest(c),
        "observed_at" => DateTime.to_unix(f.now),
        "coverage" => "partial",
        "gap" => false,
        "error" => "workload_unavailable"
      }

      insert_cursor(f.scope_a, f.a.id, f.k8s_a.id, "replicasets", f.now, errored)

      rescoped = %{
        "namespace" => "data",
        "objects" => %{"p4" => pod("p4", "rescoped-pod", nil)},
        "scope" => "stale-config-scope",
        "observed_at" => DateTime.to_unix(f.now),
        "coverage" => "complete",
        "gap" => false,
        "error" => nil
      }

      insert_cursor(f.scope_a, f.a.id, f.k8s_a.id, "events", f.now, rescoped)

      {:ok, []} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.resources(f.now, "checkout-api") end)

      assert {:ok, info2} = Insights.service(f.scope_a, "checkout-api", "prod", f.now)
      assert info2.resources == []

      # partial inventories are incomplete snapshots, never complete health
      partial = %{
        "namespace" => "data",
        "objects" => %{"p9" => pod("p9", "partial-pod", nil)},
        "scope" => scope_digest(c),
        "observed_at" => DateTime.to_unix(f.now),
        "coverage" => "partial",
        "gap" => false,
        "error" => nil
      }

      insert_cursor(f.scope_a, f.a.id, f.k8s_a.id, "pods", f.now, partial)

      {:ok, []} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.resources(f.now, "checkout-api") end)

      # future-dated observations are rejected like stale ones
      future = %{
        "namespace" => "data",
        "objects" => %{"p9" => pod("p9", "future-pod", nil)},
        "scope" => scope_digest(c),
        "observed_at" => DateTime.to_unix(f.now) + 1000,
        "coverage" => "complete",
        "gap" => false,
        "error" => nil
      }

      insert_cursor(f.scope_a, f.a.id, f.k8s_a.id, "pods", f.now, future)

      {:ok, []} =
        Tenancy.with_scope(f.scope_a, fn -> Sources.resources(f.now, "checkout-api") end)
    end
  end

  describe "demo runtime passthrough" do
    test "demo resources and attention items survive the adapter move", f do
      Demo.seed!(TestAdminRepo, f.alice.name, now: f.now)
      {:ok, demo_scope} = Tenancy.authorize(f.token_a, Demo.company_id())

      assert {:ok, info} = Insights.service(demo_scope, "inventory-api", "prod", f.now)

      oom = Enum.find(info.resources, &(&1["kind"] == "Pod" and &1["status"] == "OOMKilled"))
      assert oom["service"] == "inventory-api"
      assert oom["environment"] == "prod"
      assert oom["details"]["restartCount"] == 7
      assert Enum.any?(info.checks, &(&1 =~ "Pods are OOMKilled"))

      assert {:ok, command} = Insights.command(demo_scope, f.now)

      assert Enum.any?(
               command.attention,
               &(&1.kind == "Pod" and &1.service == "inventory-api" and
                   &1.level == "critical")
             )

      assert Enum.any?(
               command.attention,
               &(&1.kind == "Event" and &1.service == "inventory-api" and
                   &1.detail =~ "OOMKilled ×7")
             )

      # demo pods already flag every degraded deployment: no duplicate spam
      refute Enum.any?(command.attention, &(&1.kind == "Workload"))
      assert Enum.any?(command.attention, &(&1.kind == "Node" and &1.level == "warning"))

      assert Enum.any?(
               command.attention,
               &(&1.kind == "Database" and &1.level == "critical" and &1.title =~ "492/500")
             )
    end
  end
end
