defmodule OpsBrainWeb.WorkspaceHomeTest do
  use OpsBrainWeb.ConnCase, async: false
  alias OpsBrain.{Accounts, Demo, Repo, Services, Store, Tenancy, TestAdminRepo, Workspace}

  setup do
    f = fixture()
    old = Application.get_env(:ops_brain, :workspace_company_id)
    Application.delete_env(:ops_brain, :workspace_company_id)

    on_exit(fn ->
      if old,
        do: Application.put_env(:ops_brain, :workspace_company_id, old),
        else: Application.delete_env(:ops_brain, :workspace_company_id)
    end)

    Map.put(f, :conn, init_test_session(build_conn(), operator_token: f.token_a))
  end

  test "an explicit workspace lands on the command center without a chooser", f do
    Demo.seed!(TestAdminRepo, f.alice.name)
    Application.put_env(:ops_brain, :workspace_company_id, Demo.company_id())

    # the resolved workspace goes straight to the command center
    command = "/companies/#{Demo.company_id()}/command"
    assert {:error, {:redirect, %{to: ^command}}} = live(f.conn, "/")

    # the destination is the operator's authorized demo workspace, never a chooser
    {:ok, view, _} = live(f.conn, "/companies/#{Demo.company_id()}/command")
    refute has_element?(view, "#companies, #company-search, a.workspace-switch")
    assert has_element?(view, "#demo-banner", "SYNTHETIC DEMO")

    {:ok, home} = Workspace.resolve(f.token_a)
    assert home.company_id == Demo.company_id()
    {:ok, snapshot} = Demo.summary(home)
    assert snapshot["counts"]["Pod"] == 210
    {:ok, nil} = Demo.summary(home, DateTime.add(Store.now(), 31, :day))
    assert Repo.query!("SELECT count(*) FROM oban_jobs").rows == [[0]]
  end

  test "configuration cannot grant access or silently fall back to a different workspace", f do
    for invalid <- [f.b.id, "", "not-a-uuid", Ecto.UUID.generate()] do
      Application.put_env(:ops_brain, :workspace_company_id, invalid)
      assert {:error, :unauthorized} = Workspace.resolve(f.token_a)
      {:ok, view, _} = live(f.conn, "/")
      assert has_element?(view, "#workspace-unavailable")
      refute has_element?(view, "#home-workspace, #home-stats")
      refute has_element?(view, "#workspace-identity", f.b.name)
    end
  end

  test "ambiguous or empty membership gives a setup state, not a selector or arbitrary first company",
       f do
    conn = init_test_session(build_conn(), operator_token: f.token_dual)
    assert {:error, :workspace_not_configured} = Workspace.resolve(f.token_dual)
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#workspace-unavailable")
    refute has_element?(view, "#companies, #home-workspace")
    TestAdminRepo.query!("DELETE FROM memberships WHERE operator_id=$1::text::uuid", [f.alice.id])
    assert {:error, :no_workspace} = Workspace.resolve(f.token_a)
    {:ok, view, _} = live(f.conn, "/")
    assert has_element?(view, "#workspace-unavailable")
  end

  test "the landing rechecks revocation and ignores forged company parameters", f do
    Application.put_env(:ops_brain, :workspace_company_id, f.a.id)

    # the resolved workspace goes straight to the command center; the landing
    # URL carries no company parameter to forge
    command = "/companies/#{f.a.id}/command"
    assert {:error, {:redirect, %{to: ^command}}} = live(f.conn, "/")

    # with membership revoked, the destination itself rejects at mount
    TestAdminRepo.query!(
      "DELETE FROM memberships WHERE operator_id=$1::text::uuid AND company_id=$2::text::uuid",
      [f.alice.id, f.a.id]
    )

    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(f.conn, command)

    # the landing then shows the workspace-error state, never a selector or
    # another company's data — and a forged company parameter changes nothing
    {:ok, view, html} = live(f.conn, "/")
    assert has_element?(view, "#workspace-unavailable")
    refute has_element?(view, "#companies, #company-search, a.workspace-switch")
    refute html =~ f.b.name

    render_click(view, "refresh", %{"company_id" => f.b.id})
    assert has_element?(view, "#workspace-unavailable")

    Accounts.revoke_session(f.token_a)
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(f.conn, "/")
  end

  test "services and capacity filters use explicit environment mappings and survive refresh", f do
    Demo.seed!(TestAdminRepo, f.alice.name)
    {:ok, scope} = Tenancy.authorize(f.token_a, Demo.company_id())
    {:ok, services} = Services.overview(scope)
    {:ok, windows} = Services.windows(scope)
    prod = Enum.filter(services, &(&1["environment"] == "prod"))
    staging = Enum.filter(services, &(&1["environment"] == "staging"))
    prod_ids = MapSet.new(prod, & &1["id"])
    prod_windows = Enum.filter(windows, &MapSet.member?(prod_ids, &1["service_id"]))
    other_windows = windows -- prod_windows
    assert length(prod) == 24 and length(staging) == 24
    assert prod_windows != [] and other_windows != []

    for route <- ~w(services capacity) do
      {:ok, view, _} = live(f.conn, "/companies/#{Demo.company_id()}/#{route}?environment=prod")
      assert has_element?(view, "#environment-filter-note", "Environment: prod")
      for service <- prod, do: assert(has_element?(view, "#service-#{service["id"]}"))
      for service <- staging, do: refute(has_element?(view, "#service-#{service["id"]}"))
      for window <- prod_windows, do: assert(has_element?(view, "#window-#{window["id"]}"))
      for window <- other_windows, do: refute(has_element?(view, "#window-#{window["id"]}"))

      form(view, "#operations-filter", %{query: "checkout", environment: "prod"})
      |> render_change()

      element(view, "#refresh-operations") |> render_click()
      assert has_element?(view, "#operations-environment option[value=prod][selected]")
      assert has_element?(view, "#operations-query[value=checkout]")
      form(view, "#operations-filter", %{query: "", environment: "dev"}) |> render_change()
      refute has_element?(view, "tr[id^=service-], article[id^=window-]")
      assert has_element?(view, ".empty-state", "No mapped service targets")
      form(view, "#operations-filter", %{query: "", environment: ""}) |> render_change()
      for service <- services, do: assert(has_element?(view, "#service-#{service["id"]}"))
    end
  end

  test "the same monochrome vector is shared across surfaces and supplied in black and white",
       f do
    # the landing renders its full frame only for the workspace-error state
    conn = init_test_session(build_conn(), operator_token: f.token_dual)
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, ".sidebar .brand .constellation-logo svg path[stroke=currentColor]")
    assert has_element?(view, ".intro-art .constellation-logo svg g[fill=currentColor]")
    refute has_element?(view, ".sidebar .brand .hero-square-3-stack-3d")
    base = File.read!("priv/static/images/constellation.svg")

    assert File.read!("priv/static/images/constellation-black.svg") ==
             String.replace(base, "currentColor", "#000000")

    assert File.read!("priv/static/images/constellation-white.svg") ==
             String.replace(base, "currentColor", "#ffffff")

    for path <-
          ~w(/images/constellation.svg /images/constellation-black.svg /images/constellation-white.svg) do
      assert get(build_conn(), path).status == 200
    end

    html =
      render_component(&OpsBrainWeb.SessionHTML.new/1, flash: %{}, failed: false)
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(html, ".brand .constellation-logo svg") |> LazyHTML.to_tree() != []
  end
end
