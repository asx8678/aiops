defmodule OpsBrain.Insights.FindingAttributionTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures

  alias OpsBrain.{Insights, Repo, Services, Tenancy}

  setup do
    on_exit(&cleanup/0)
    f = fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    env_prod = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))
    env_staging = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :staging))
    {:ok, source} = Tenancy.create_source(f.scope_a, %{name: "metrics", kind: :prometheus})

    Map.merge(f, %{
      now: now,
      source: source,
      env_prod: env_prod,
      env_staging: env_staging
    })
  end

  test "cluster-prefix scopes stay on the exact target", f do
    east = service!(f, f.env_prod, "orders-db", "east/data/orders-db")
    east_prod = service!(f, f.env_staging, "orders-db", "east-prod/data/orders-db")

    insert_finding(f, "east-scope", %{"scope" => "east/data/orders-db"})
    insert_finding(f, "east-prod-scope", %{"scope" => "east-prod/data/orders-db"})

    assert titles(f, "orders-db", "prod") == ["east-scope"]
    assert titles(f, "orders-db", "staging") == ["east-prod-scope"]
    assert east["id"] != east_prod["id"]
  end

  test "the same service and cluster across environments is not assigned", f do
    service!(f, f.env_prod, "orders-db", "nw-eu/data/orders-db")
    service!(f, f.env_staging, "orders-db", "nw-eu/data/orders-db")

    insert_finding(f, "shared-legacy", %{"scope" => "nw-eu/data/orders-db"})
    insert_finding(f, "shared-demo", %{"scope" => "DEMO · nw-eu/data/orders-db"})

    assert titles(f, "orders-db", "prod") == []
    assert titles(f, "orders-db", "staging") == []
  end

  test "exact legacy, demo, and collector scopes stay on the unique instance", f do
    instance = service!(f, f.env_prod, "orders-db", "east/data/orders-db")
    other = service!(f, f.env_staging, "orders-db", "east-prod/data/orders-db")

    insert_finding(f, "exact-legacy", %{"scope" => "east/data/orders-db"})
    insert_finding(f, "exact-demo", %{"scope" => "DEMO · east/data/orders-db"})
    insert_finding(f, "collector", %{"scope" => instance["id"]})
    insert_finding(f, "other-collector", %{"scope" => other["id"]})

    assert titles(f, "orders-db", "prod") == ["collector", "exact-demo", "exact-legacy"]
    assert titles(f, "orders-db", "staging") == ["other-collector"]
  end

  test "same-target ambiguity past the overview cap is excluded from prod", f do
    for n <- 1..99 do
      key = "a-" <> String.pad_leading(Integer.to_string(n), 3, "0")
      service!(f, f.env_prod, key, "other/#{key}")
    end

    service!(f, f.env_prod, "orders-db", "nw-eu/data/orders-db")
    service!(f, f.env_staging, "orders-db", "nw-eu/data/orders-db")

    insert_finding(f, "paged-legacy", %{"scope" => "nw-eu/data/orders-db"})
    insert_finding(f, "paged-demo", %{"scope" => "DEMO · nw-eu/data/orders-db"})

    assert titles(f, "orders-db", "prod") == []
  end

  test "structured predictions match the instance and CI-only stays unscoped", f do
    east = service!(f, f.env_prod, "orders-db", "east/data/orders-db")
    east_prod = service!(f, f.env_staging, "orders-db", "east-prod/data/orders-db")

    insert_finding(f, "structured-east", %{
      "scope" => "east-prod/data/orders-db",
      "prediction_target" => %{
        "service_instance_id" => east["id"],
        "environment" => "prod",
        "target" => "east/data/orders-db"
      }
    })

    insert_finding(f, "structured-west", %{
      "scope" => "east/data/orders-db",
      "prediction_target" => %{
        "service_instance_id" => east_prod["id"],
        "environment" => "staging",
        "target" => "east-prod/data/orders-db"
      }
    })

    insert_finding(f, "ci-only", %{
      "scope" => "east/data/orders-db",
      "prediction_target" => nil
    })

    insert_finding(f, "wrong-environment", %{
      "scope" => "east/data/orders-db",
      "prediction_target" => %{
        "service_instance_id" => east["id"],
        "environment" => "staging",
        "target" => "east/data/orders-db"
      }
    })

    assert titles(f, "orders-db", "prod") == ["structured-east"]
    assert titles(f, "orders-db", "staging") == ["structured-west"]
  end

  defp service!(f, env, key, target) do
    {:ok, service} =
      Services.create(f.scope_a, %{
        source_id: f.source.id,
        environment_id: env.id,
        service_key: key,
        target: target
      })

    service
  end

  defp insert_finding(f, title, data) do
    Tenancy.with_scope(f.scope_a, fn ->
      Repo.query!(
        "INSERT INTO error_fingerprints(company_id,source_id,fingerprint,parser_version,data) VALUES($1::text::uuid,$2::text::uuid,$3,1,$4)",
        [
          f.a.id,
          f.source.id,
          title,
          %{"classification" => "legacy", "template" => title, "reason" => "attribution"}
        ]
      )

      Repo.query!(
        "INSERT INTO issue_groups(id,company_id,source_id,fingerprint,parser_version,first_seen,last_seen,severity,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,1,$5,$5,'critical',$6)",
        [
          Ecto.UUID.generate(),
          f.a.id,
          f.source.id,
          title,
          f.now,
          Map.merge(%{"template" => title, "reason" => "attribution"}, data)
        ]
      )
    end)
  end

  defp titles(f, service_key, environment) do
    assert {:ok, page} = Insights.service(f.scope_a, service_key, environment, f.now)

    page.findings
    |> Enum.map(& &1["data"]["template"])
    |> Enum.sort()
  end
end
