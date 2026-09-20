defmodule OpsBrainWeb.DemoLiveTest do
  use OpsBrainWeb.ConnCase, async: false
  alias OpsBrain.{Demo, Repo, TestAdminRepo, Tenancy, Issues, Store}
  alias OpsBrain.Demo.Dataset

  setup do
    f = fixture()
    now = DateTime.utc_now()
    Demo.seed!(TestAdminRepo, f.alice.name, now: now)
    {:ok, scope} = Tenancy.authorize(f.token_a, Demo.company_id())

    Map.merge(f, %{
      demo_scope: scope,
      now: now,
      demo_conn: init_test_session(build_conn(), operator_token: f.token_a)
    })
  end

  test "deterministic mid-size inventory, explicit provenance, and no live side effects", f do
    assert Dataset.build(f.now) == Dataset.build(f.now)
    {:ok, snapshot} = Demo.snapshot(f.demo_scope)
    counts = snapshot.manifest["counts"]
    assert counts["Cluster"] == 2
    assert counts["Node"] == 18
    assert counts["Namespace"] == 24
    assert counts["Deployment"] == 48
    assert counts["Database"] == 6
    assert counts["Pod"] == 210
    assert length(snapshot.resources) == snapshot.manifest["resource_count"]
    assert Enum.all?(snapshot.resources, &(&1["data"]["synthetic"] == true))
    assert Repo.query!("SELECT count(*) FROM oban_jobs").rows == [[0]]
    refute Application.get_env(:ops_brain, :collection_enabled)
    refute Application.get_env(:ops_brain, :delivery_enabled)
    assert OpsBrain.SourceConfig.all() == %{}

    assert {:ok, []} =
             Tenancy.with_scope(f.scope_b, fn -> Store.rows("SELECT id FROM evidence_items") end)
  end

  test "rerun preserves local decisions; reset/remove affect only the reserved demo company", f do
    gid = Dataset.id("finding:checkout")
    assert {:ok, _} = Issues.assign(f.demo_scope, gid, "demo-reviewer")
    {:ok, before} = Demo.snapshot(f.demo_scope)
    Demo.seed!(TestAdminRepo, f.alice.name)
    {:ok, after_seed} = Demo.snapshot(f.demo_scope)
    assert before == after_seed
    {:ok, groups} = Issues.list(f.demo_scope)
    assert Enum.find(groups, &(&1["id"] == gid))["owner"] == "demo-reviewer"
    Demo.seed!(TestAdminRepo, f.alice.name, reset: true, now: f.now)

    assert {:ok, [%{"n" => 7}]} =
             Tenancy.with_scope(f.demo_scope, fn ->
               Store.rows("SELECT count(*) AS n FROM sources")
             end)

    assert {:ok, _} = Demo.remove!(TestAdminRepo)
    assert {:ok, data} = Tenancy.overview(f.scope_a)
    assert Enum.any?(data.sources, &(&1.id == f.source_a.id))
    assert {:error, :unauthorized} = Tenancy.authorize(f.token_a, Demo.company_id())
  end

  test "provisioning rejects unavailable operators and reserved identity collisions without altering data",
       f do
    assert_raise MatchError, fn -> Demo.seed!(TestAdminRepo, "nonexistent-operator") end

    TestAdminRepo.query!("UPDATE companies SET name='Do not overwrite' WHERE id=$1::text::uuid", [
      Demo.company_id()
    ])

    assert_raise RuntimeError, ~r/collision/, fn ->
      Demo.seed!(TestAdminRepo, f.alice.name, reset: true)
    end

    assert_raise RuntimeError, ~r/collision/, fn -> Demo.remove!(TestAdminRepo) end

    assert TestAdminRepo.query!("SELECT name FROM companies WHERE id=$1::text::uuid", [
             Demo.company_id()
           ]).rows == [["Do not overwrite"]]
  end

  test "resource explorer filters, paginates, and never shows another company's data", f do
    path = "/companies/#{Demo.company_id()}/demo"
    {:ok, view, _} = live(f.demo_conn, path)
    assert has_element?(view, "#demo-banner", "SYNTHETIC DEMO")
    assert has_element?(view, "#demo-page", "Page 1")
    view |> element("#demo-next") |> render_click()
    assert has_element?(view, "#demo-page", "Page 2")

    view
    |> form("#demo-filter", %{
      kind: "Pod",
      cluster: "nw-eu-prod",
      namespace: "checkout",
      query: "checkout-api"
    })
    |> render_change()

    assert has_element?(view, "#demo-page", "6 matching")
    assert has_element?(view, "#demo-resources", "ReadinessFailed")
    refute has_element?(view, "#demo-resources", "nw-eu-staging")

    view
    |> form("#demo-filter", %{kind: "Database", cluster: "", namespace: "", query: ""})
    |> render_change()

    assert has_element?(view, "#demo-resources", "orders-postgres")
    assert has_element?(view, "#demo-page", "6 matching")
    view |> form("#demo-filter", %{query: "nonexistent-resource"}) |> render_change()
    assert has_element?(view, "#demo-empty")
    other = init_test_session(build_conn(), operator_token: f.token_b)
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(other, path)
    assert {:error, {:redirect, %{to: company_path}}} = live(other, "/companies/#{f.b.id}/demo")
    assert company_path == "/companies/#{f.b.id}"

    TestAdminRepo.query!(
      "DELETE FROM memberships WHERE operator_id=$1::text::uuid AND company_id=$2::text::uuid",
      [f.alice.id, Demo.company_id()]
    )

    view |> element("#refresh-demo") |> render_click()
    assert_redirect(view, "/sign-in")
  end

  test "all existing views have synthetic provenance and populated operational records", f do
    for {route, selector} <- [
          {"", "#demo-entry"},
          {"pipelines", "#pipelines"},
          {"services", "#services"},
          {"capacity", "#services"},
          {"investigations", "#investigations"},
          {"source-health", "#source-health"}
        ] do
      {:ok, view, _} =
        live(
          f.demo_conn,
          "/companies/#{Demo.company_id()}#{if route == "", do: "", else: "/" <> route}"
        )

      assert has_element?(view, "#demo-banner")
      assert has_element?(view, selector)
    end

    {:ok, view, _} = live(f.demo_conn, "/companies/#{Demo.company_id()}/investigations")
    render_click(view, "evidence", %{"id" => Dataset.id("finding:checkout")})
    assert has_element?(view, ".demo-timeline", "SQLSTATE 53300")
    assert has_element?(view, ".investigation-candidates", "Staging has the same image")
    assert has_element?(view, "#evidence-revisions", "current")
    assert has_element?(view, "#evidence", "no delivery")
    {:ok, revisions} = Issues.revisions(f.demo_scope, Dataset.id("finding:checkout"))
    assert length(revisions) == 5
    {:ok, items} = Issues.evidence(f.demo_scope, Dataset.id("finding:checkout"))
    correlation = Enum.find(items, &(&1["kind"] == "correlation"))
    ids = MapSet.new(Enum.map(items, & &1["id"]))
    assert Enum.all?(correlation["data"]["timeline"], &MapSet.member?(ids, &1["evidence_id"]))
  end

  test "CLI requires explicit approval and cannot seed a test build", _f do
    assert_raise Mix.Error, ~r/Use --operator/, fn ->
      Mix.Tasks.OpsBrain.Demo.run(["--operator", "synthetic-alice"])
    end

    assert_raise Mix.Error, ~r/Use --operator/, fn ->
      Mix.Tasks.OpsBrain.Demo.run(["--remove", "--reset", "--confirm"])
    end

    assert_raise Mix.Error, ~r/only runs in MIX_ENV=dev/, fn ->
      Mix.Tasks.OpsBrain.Demo.run(["--operator", "synthetic-alice", "--confirm"])
    end
  end

  test "expired snapshots are unavailable rather than fabricated current health", f do
    {:ok, snapshot} = Demo.snapshot(f.demo_scope, DateTime.add(f.now, 31, :day))
    assert snapshot.manifest == nil
    assert snapshot.resources == []

    {:ok, _} =
      Tenancy.with_scope(f.demo_scope, fn ->
        Repo.query!("UPDATE evidence_items SET expires_at=$1", [DateTime.add(f.now, -1)])
      end)

    {:ok, view, _} = live(f.demo_conn, "/companies/#{Demo.company_id()}/demo")
    refute has_element?(view, "#demo-inventory")
    assert has_element?(view, ".empty-state", "Demo snapshot unavailable")
  end
end
