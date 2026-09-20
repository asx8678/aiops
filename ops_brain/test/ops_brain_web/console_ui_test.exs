defmodule OpsBrainWeb.ConsoleUITest do
  use OpsBrainWeb.ConnCase, async: false
  alias OpsBrain.{Accounts, Repo, Store, Tenancy}

  setup do
    f = fixture()
    Map.put(f, :conn, init_test_session(build_conn(), operator_token: f.token_a))
  end

  test "Constellation brands sign-in, failed sign-in and SSO completion", _f do
    for conn <- [
          get(build_conn(), "/sign-in"),
          post(build_conn(), "/sign-in", %{"login" => %{"token" => "invalid-brand-check"}})
        ] do
      html = html_response(conn, conn.status) |> LazyHTML.from_document()

      assert LazyHTML.query(html, "title") |> LazyHTML.text() ==
               "Constellation · Operations console"

      assert LazyHTML.query(html, "#sign-in-title") |> LazyHTML.text() ==
               "Welcome to Constellation."

      assert LazyHTML.query(html, ".auth-footer") |> LazyHTML.text() =~ "Constellation"
      assert_brand(html)
    end

    html =
      render_component(&OpsBrainWeb.OIDCHTML.complete/1, flash: %{})
      |> LazyHTML.from_fragment()

    assert_brand(html)

    assert LazyHTML.query(html, "#oidc-continue") |> LazyHTML.text() =~
             "Continue to Constellation"
  end

  test "Constellation branding persists throughout authorized navigation", f do
    for path <-
          ["/", "/companies/#{f.a.id}", "/companies/#{f.a.id}/sources/#{f.source_a.id}"] ++
            Enum.map(
              ~w(pipelines services investigations capacity source-health),
              &"/companies/#{f.a.id}/#{&1}"
            ) do
      {:ok, view, _} = live(f.conn, path)

      assert has_element?(
               view,
               ".sidebar .brand[aria-label='Constellation home']",
               "Constellation"
             )

      assert has_element?(view, ".sidebar-version", "CONSTELLATION")
      assert_brand(render(view) |> LazyHTML.from_fragment())
    end
  end

  defp assert_brand(html) do
    assert LazyHTML.query(html, ".brand[aria-label='Constellation home'] .brand-wordmark")
           |> LazyHTML.text() =~ "Constellation"

    refute LazyHTML.text(html) =~ ~r/ops\s*brain/i
  end

  test "home opens the authorized workspace without a company chooser", f do
    {:ok, view, _} = live(f.conn, "/")
    assert has_element?(view, "nav[aria-label='Main navigation'] a[aria-current='page']", "Home")
    assert has_element?(view, "h1", "A clearer view of operations.")
    assert has_element?(view, ".portfolio-intro .intro-art")
    assert has_element?(view, "#home-workspace[data-company-id='#{f.a.id}']")
    refute has_element?(view, "#home-workspace[data-company-id='#{f.b.id}']")
    refute has_element?(view, "#companies, #company-search, a.workspace-switch")
    assert has_element?(view, "#workspace-identity strong", f.a.name)

    for env <- ~w(dev staging prod) do
      assert has_element?(
               view,
               "#home-environment-#{env}[href='/companies/#{f.a.id}/services?environment=#{env}']"
             )
    end

    view |> element("#refresh") |> render_click()
    assert has_element?(view, "#home-workspace[data-company-id='#{f.a.id}']")
  end

  test "home refresh reauthorizes expired sessions", f do
    {:ok, view, _} = live(f.conn, "/")
    Accounts.revoke_session(f.token_a)
    view |> element("#refresh") |> render_click()
    assert_redirect(view, "/sign-in")
  end

  test "overview labels identity separately from health and links all operations", f do
    {:ok, view, _} = live(f.conn, "/companies/#{f.a.id}")
    assert has_element?(view, "#overview-stats", "Unknown")
    assert has_element?(view, "#environments .environment-card", "Identity only")
    refute has_element?(view, "#environments .badge-success")
    assert has_element?(view, "#source-setup-guide")

    for route <- ~w(pipelines services investigations capacity source-health) do
      assert has_element?(view, "a[href='/companies/#{f.a.id}/#{route}']")
    end

    render_patch(view, "/companies/#{f.a.id}/sources/#{f.source_a.id}")
    assert has_element?(view, "#selected-source", "Source identity")
    view |> element("#selected-source a[aria-label='Close source details']") |> render_click()
    refute has_element?(view, "#selected-source")
  end

  test "every operations route renders accessible navigation, search and honest empty states",
       f do
    for route <- ~w(pipelines services investigations capacity source-health) do
      {:ok, view, _} = live(f.conn, "/companies/#{f.a.id}/#{route}")

      assert has_element?(
               view,
               "nav a[aria-current='page'][href='/companies/#{f.a.id}/#{route}']"
             )

      assert has_element?(view, "#main-content h1")
      assert has_element?(view, "#operations-filter input[type='search'][aria-label]")
      assert has_element?(view, "#view-updated")
      assert has_element?(view, "#refresh-operations[phx-disable-with]")
      assert has_element?(view, "#coverage-disclaimer", "Missing data is unknown")
      view |> form("#operations-filter", query: "no-match") |> render_change()
      assert has_element?(view, ".empty-state h3", "No matching")
      view |> element("#refresh-operations") |> render_click()
      assert has_element?(view, "#operations-query[value='no-match']")
    end
  end

  test "pipeline search operates on bounded records and resets on route navigation", f do
    {:ok, _} =
      Tenancy.with_scope(f.scope_a, fn ->
        for {run, result} <- [{701, "failed"}, {702, "succeeded"}] do
          Repo.query!(
            "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,received_at) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,7,'completed',$6,$7)",
            [
              Ecto.UUID.generate(),
              f.a.id,
              f.source_a.id,
              Ecto.UUID.generate(),
              run,
              result,
              Store.now()
            ]
          )
        end
      end)

    {:ok, view, _} = live(f.conn, "/companies/#{f.a.id}/pipelines")
    assert has_element?(view, "#pipelines tbody tr", "701")
    assert has_element?(view, "#pipelines tbody tr", "702")
    view |> form("#operations-filter", query: "FAILED") |> render_submit()
    assert has_element?(view, "#pipelines tbody tr .badge-danger", "Failed")
    assert has_element?(view, "#operations-stats .stat-card:first-child .stat-value", "2")
    assert has_element?(view, "#operations-stats", "before search")
    refute has_element?(view, "#pipelines tbody tr", "702")
    view |> element("#refresh-operations") |> render_click()
    assert has_element?(view, "#pipelines tbody tr", "701")
    render_patch(view, "/companies/#{f.a.id}/source-health")
    assert has_element?(view, "#operations-query[value='']")
    assert has_element?(view, "#health-#{f.source_a.id}")
    refute has_element?(view, "#health-#{f.source_b.id}")
  end

  test "operation navigation keeps the selected company identity explicit", f do
    conn = init_test_session(build_conn(), operator_token: f.token_dual)
    {:ok, view, _} = live(conn, "/companies/#{f.a.id}/pipelines")
    assert has_element?(view, ".workspace-identity strong", f.a.name)
    view |> form("#operations-filter", query: "retained-query") |> render_change()
    render_patch(view, "/companies/#{f.b.id}/pipelines")
    assert has_element?(view, ".workspace-identity strong", f.b.name)
    refute has_element?(view, ".workspace-identity strong", f.a.name)
    assert has_element?(view, "#operations-query[value='']")
    assert has_element?(view, "nav a[aria-current='page'][href='/companies/#{f.b.id}/pipelines']")
  end

  test "source with no collection never receives a healthy badge", f do
    {:ok, view, _} = live(f.conn, "/companies/#{f.a.id}/source-health")

    assert has_element?(
             view,
             "#health-#{f.source_a.id} .badge-neutral",
             "Not configured or unavailable"
           )

    assert has_element?(view, "#health-#{f.source_a.id}", "Not observed")
    refute has_element?(view, "#health-#{f.source_a.id} .badge-success")
  end

  test "sign-in is a dedicated accessible screen with no echoed token", _f do
    conn = get(build_conn(), "/sign-in")
    html = html_response(conn, 200) |> LazyHTML.from_document()

    assert LazyHTML.query(
             html,
             ".auth-shell #sign-in-form input[type=password][aria-describedby=token-help]"
           )
           |> LazyHTML.to_tree() != []

    assert LazyHTML.query(html, ".sidebar") |> LazyHTML.to_tree() == []
    conn = post(build_conn(), "/sign-in", %{"login" => %{"token" => "private-invalid-token"}})
    html = html_response(conn, 401) |> LazyHTML.from_document()
    assert LazyHTML.query(html, "#sign-in-error[role=alert]") |> LazyHTML.to_tree() != []

    assert LazyHTML.query(html, "input[value='private-invalid-token']") |> LazyHTML.to_tree() ==
             []
  end
end
