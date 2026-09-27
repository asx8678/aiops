defmodule OpsBrainWeb.OperationsLiveTest do
  use OpsBrainWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import OpsBrain.Fixtures

  setup do
    OpsBrain.Fixtures.clean!()
    fixture()
  end

  alias OpsBrain.{Issues, Notifications, Repo, SourceConfig, Store, Tenancy}

  defp capture_query(_event, _measurements, metadata, parent),
    do: send(parent, {:query, metadata.query})

  defp queries(acc \\ []) do
    receive do
      {:query, sql} -> queries([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp seed_finding(f) do
    c = OpsBrain.SourceFixtures.config(f)
    on_exit(&OpsBrain.SourceFixtures.cleanup/0)
    now = Store.now()

    {:ok, _} =
      SourceConfig.transaction(c.id, fn trusted ->
        OpsBrain.Evidence.failure(
          trusted,
          "ui-failure",
          %{"issues" => ["HTTP 401 api.invalid"], "tool" => "compiler", "attempt" => 1},
          7,
          now
        )
      end)

    {:ok, [group]} = Issues.list(f.scope_a)
    {c, group}
  end

  test "refresh queries only the route's operational datasets", f do
    handler = "operations-route-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:ops_brain, :repo, :query], &capture_query/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    conn = Plug.Test.init_test_session(build_conn(), %{operator_token: f.token_a})

    for {area, expected, forbidden} <- [
          {"pipelines", "FROM pipeline_runs",
           ["FROM issue_groups", "FROM observation_windows", "FROM sources s"]},
          {"investigations", "FROM issue_groups",
           ["FROM pipeline_runs", "FROM observation_windows", "FROM sources s"]},
          {"services", "FROM service_instances",
           ["FROM pipeline_runs", "FROM issue_groups", "FROM sources s"]},
          {"capacity", "FROM observation_windows",
           ["FROM pipeline_runs", "FROM issue_groups", "FROM sources s"]},
          {"source-health", "FROM sources s",
           ["FROM pipeline_runs", "FROM issue_groups", "FROM observation_windows"]}
        ] do
      {:ok, view, _} = live(conn, "/companies/#{f.a.id}/#{area}")
      queries()
      view |> element("#refresh-operations") |> render_click()
      sql = Enum.join(queries(), "\n")
      assert sql =~ expected
      if area == "capacity", do: assert(sql =~ "e.kind='capacity_evaluation'")
      if area == "services", do: refute(sql =~ "e.kind='capacity_evaluation'")
      for table <- forbidden, do: refute(sql =~ table)
      refute has_element?(view, "#evidence")
    end
  end

  test "investigation evidence, notification state, owner, review and snooze are local and scoped",
       f do
    {c, group} = seed_finding(f)
    id = group["id"]

    {:ok, _} =
      Tenancy.with_scope(f.scope_a, fn ->
        symptom = %{
          company_id: f.a.id,
          environment_id: "synthetic",
          target_id: "synthetic",
          occurred_at: 100,
          received_at: 100,
          evidence_id: "synthetic-symptom"
        }

        change = %{symptom | occurred_at: 101, received_at: 101, evidence_id: "synthetic-change"}
        result = OpsBrain.Correlation.evaluate(symptom, [change], [], 102)

        OpsBrain.Evidence.save(
          c,
          "ui-correlation",
          "correlation",
          %{"group_id" => id, "result" => result},
          Store.now(),
          Store.now()
        )

        for revision <- 1..25 do
          Repo.query!(
            "INSERT INTO notification_outbox(id,company_id,source_id,group_id,revision,destination,status,next_at,updated_at) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,'synthetic-destination','ambiguous',$6,$6)",
            [Ecto.UUID.generate(), f.a.id, f.source_a.id, id, revision, Store.now()]
          )
        end
      end)

    assert {:ok, []} = Notifications.status(f.scope_b, id)
    assert {:error, :not_found} = Notifications.status(f.scope_a, "bad-id")
    conn = Plug.Test.init_test_session(build_conn(), %{operator_token: f.token_a})
    {:ok, view, _} = live(conn, "/companies/#{f.a.id}/investigations")
    view |> form("#assign-#{id}", %{"owner" => "operator-one"}) |> render_submit()
    assert has_element?(view, "#groups-#{id}", "operator-one")
    view |> element("#snooze-#{id}") |> render_click()
    assert {:ok, [%{"snoozed_until" => %DateTime{}}]} = Issues.list(f.scope_a)

    view
    |> element("#groups-#{id} button[phx-value-status=locally_acknowledged]")
    |> render_click()

    assert has_element?(view, "#groups-#{id}", "locally_acknowledged")

    render_click(view, "review", %{
      "id" => id,
      "status" => "bogus",
      "revision" => issue_revision(f.scope_a, id)
    })

    assert has_element?(view, "#flash-error", "Review could not be saved")
    render_click(view, "evidence", %{"id" => id})
    assert has_element?(view, "#evidence-revisions", "current")
    render_click(element(view, "#close-evidence"))
    refute has_element?(view, "#evidence")
    render_click(view, "evidence", %{"id" => id})
    assert has_element?(view, ".investigation-candidates", "not established cause")
    assert has_element?(view, ".investigation-candidates", "symptom predates change")
    assert {:ok, notices} = Notifications.status(f.scope_a, id)
    assert length(notices) == 20
    for notice <- notices, do: assert(has_element?(view, "#notice-#{notice["id"]}", "ambiguous"))
    render_click(view, "refresh", %{})
    refute has_element?(view, "#evidence")
    render_click(view, "evidence", %{"id" => id})

    OpsBrain.TestAdminRepo.query!("DELETE FROM memberships WHERE operator_id=$1::text::uuid", [
      f.alice.id
    ])

    send(view.pid, :refresh)
    assert_redirect(view, "/sign-in")
  end

  test "company navigation clears evidence, and expired revisions never expose payloads", f do
    {_c, group} = seed_finding(f)
    conn = Plug.Test.init_test_session(build_conn(), %{operator_token: f.token_dual})
    {:ok, view, _} = live(conn, "/companies/#{f.a.id}/investigations")
    render_click(view, "evidence", %{"id" => group["id"]})
    assert has_element?(view, "#evidence-revisions", "current")

    {:ok, _} =
      Tenancy.with_scope(f.scope_a, fn ->
        Repo.query!("UPDATE evidence_items SET expires_at=$1", [DateTime.add(Store.now(), -1)])
      end)

    render_click(view, "evidence", %{"id" => group["id"]})
    assert has_element?(view, "#evidence-revisions", "expired")
    refute has_element?(view, "#evidence pre", "api.invalid")
    render_patch(view, "/companies/#{f.b.id}/investigations")
    refute has_element?(view, "#evidence")
    refute has_element?(view, "#groups-#{group["id"]}")
    render_click(view, "evidence", %{"id" => group["id"]})
    refute has_element?(view, "#evidence-revisions")
  end

  test "pipeline mapping comes from retained explicit deployment evidence, not success", f do
    c = OpsBrain.SourceFixtures.config(f)
    on_exit(&OpsBrain.SourceFixtures.cleanup/0)
    env = Enum.find(f.envs, &(&1.company_id == f.a.id))

    {:ok, service} =
      OpsBrain.Services.create(f.scope_a, %{
        source_id: c.id,
        environment_id: env.id,
        service_key: "synthetic-service",
        target: "namespace/workload"
      })

    {:ok, _} =
      Tenancy.with_scope(f.scope_a, fn ->
        for run <- [7, 8] do
          Repo.query!(
            "INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,received_at) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,7,'completed','succeeded',$6)",
            [Ecto.UUID.generate(), f.a.id, c.id, c.project_id, run, Store.now()]
          )
        end

        OpsBrain.Evidence.save(
          c,
          "mapped",
          "deployment",
          %{
            "run_id" => 7,
            "target_id" => service["id"],
            "reported_result" => "succeeded",
            "attempt" => 1
          },
          Store.now(),
          Store.now()
        )
      end)

    conn = Plug.Test.init_test_session(build_conn(), %{operator_token: f.token_a})
    {:ok, view, _} = live(conn, "/companies/#{f.a.id}/pipelines")
    assert has_element?(view, ".mapped-target", "synthetic-service")
    assert has_element?(view, ".target", "Target unresolved")

    {:ok, _} =
      Tenancy.with_scope(f.scope_a, fn ->
        Repo.query!("UPDATE evidence_items SET expires_at=$1", [DateTime.add(Store.now(), -1)])
      end)

    render_click(view, "refresh", %{})
    refute has_element?(view, ".mapped-target")
  end

  test "all operations routes enforce company and current membership", f do
    conn = Plug.Test.init_test_session(build_conn(), %{operator_token: f.token_a})

    for area <- ~w(pipelines services investigations capacity source-health) do
      assert {:ok, view, _} = live(conn, "/companies/#{f.a.id}/#{area}")
      assert has_element?(view, "#coverage-disclaimer")
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/companies/#{f.b.id}/#{area}")
    end

    assert {:ok, view, _} = live(conn, "/companies/#{f.a.id}/investigations")

    OpsBrain.TestAdminRepo.query!("DELETE FROM memberships WHERE operator_id=$1::text::uuid", [
      f.alice.id
    ])

    render_click(view, "refresh", %{})
    assert_redirect(view, "/sign-in")
  end

  test "focus deep link opens the finding's evidence and anchors its card", f do
    {_c, group} = seed_finding(f)
    id = group["id"]

    conn = Plug.Test.init_test_session(build_conn(), %{operator_token: f.token_a})
    {:ok, view, html} = live(conn, "/companies/#{f.a.id}/investigations?focus=#{id}")

    # the finding card is the link target: the #groups-<id> fragment anchor
    # exists on the page as the streamed card's own id
    assert has_element?(view, "#groups-#{id}")

    # the evidence workspace opens for exactly that finding
    assert has_element?(view, "#evidence")
    assert html =~ "Finding #{id}"
    assert html =~ "HTTP 401 api.invalid"
  end

  test "a nonexistent focus id is ignored without crashing or leaking", f do
    {_c, group} = seed_finding(f)

    conn = Plug.Test.init_test_session(build_conn(), %{operator_token: f.token_a})

    {:ok, view, _html} =
      live(conn, "/companies/#{f.a.id}/investigations?focus=#{Ecto.UUID.generate()}")

    # the page renders normally with its own findings; no evidence opens and
    # nothing hints at whether any other group exists
    assert has_element?(view, "#investigations")
    assert has_element?(view, "#groups-#{group["id"]}")
    refute has_element?(view, "#evidence")
  end

  test "another company's focus id never opens evidence or leaks its data", f do
    {_c, group} = seed_finding(f)

    cb = OpsBrain.SourceFixtures.config(f, :b)

    {:ok, _} =
      SourceConfig.transaction(cb.id, fn trusted ->
        OpsBrain.Evidence.failure(
          trusted,
          "foreign-failure",
          %{"issues" => ["SECRET COMPANY B PAYLOAD"], "tool" => "compiler", "attempt" => 1},
          9,
          Store.now()
        )
      end)

    {:ok, [foreign]} = Issues.list(f.scope_b)

    conn = Plug.Test.init_test_session(build_conn(), %{operator_token: f.token_a})
    {:ok, view, html} = live(conn, "/companies/#{f.a.id}/investigations?focus=#{foreign["id"]}")

    # the foreign id is not a member of company A's visible findings: nothing
    # opens and company B's content never renders
    refute has_element?(view, "#evidence")
    refute html =~ "SECRET COMPANY B PAYLOAD"
    assert has_element?(view, "#groups-#{group["id"]}")
  end

  test "focus respects the bounded findings page: a group beyond it never opens", f do
    {_c, group} = seed_finding(f)

    # 150 newer same-shaped groups push the focused one off the first page
    {:ok, _} =
      Tenancy.with_scope(f.scope_a, fn ->
        Repo.query!(
          """
          INSERT INTO issue_groups(id,company_id,source_id,fingerprint,parser_version,first_seen,last_seen,severity,data)
          SELECT gen_random_uuid(),company_id,source_id,fingerprint,parser_version,first_seen,last_seen + interval '1 second',severity,data
          FROM issue_groups CROSS JOIN generate_series(1,150) WHERE id=$1::text::uuid
          """,
          [group["id"]]
        )
      end)

    conn = Plug.Test.init_test_session(build_conn(), %{operator_token: f.token_a})
    {:ok, view, _html} = live(conn, "/companies/#{f.a.id}/investigations?focus=#{group["id"]}")

    # not visible in the loaded set: the focus is silently ignored
    refute has_element?(view, "#evidence")
    refute has_element?(view, "#groups-#{group["id"]}")
  end
end
