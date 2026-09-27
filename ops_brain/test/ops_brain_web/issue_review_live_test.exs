defmodule OpsBrainWeb.IssueReviewLiveTest do
  use OpsBrainWeb.ConnCase, async: false
  alias OpsBrain.{Evidence, Issues, SourceConfig, Store, Tenancy, TestAdminRepo}

  setup do
    f = fixture()
    c = OpsBrain.SourceFixtures.config(f)
    on_exit(&OpsBrain.SourceFixtures.cleanup/0)

    {:ok, _} =
      SourceConfig.transaction(c.id, fn trusted ->
        Evidence.failure(
          trusted,
          "ui-audit",
          %{"issues" => ["HTTP 401"], "tool" => "test", "attempt" => 1},
          1,
          Store.now()
        )
      end)

    {:ok, [group]} = Issues.list(f.scope_a)
    Map.merge(f, %{group: group["id"], revision: group["revision"]})
  end

  defp open(f, token) do
    conn = Plug.Test.init_test_session(build_conn(), %{operator_token: token})
    {:ok, view, _} = live(conn, "/companies/#{f.a.id}/investigations")
    view
  end

  test "rendered controls carry current revisions and history shows redacted authenticated actions",
       f do
    view = open(f, f.token_a)
    id = f.group
    assert has_element?(view, "#assign-revision-#{id}[value='#{f.revision}']")
    assert has_element?(view, "#snooze-#{id}[phx-value-revision='#{f.revision}']")
    render_click(view, "evidence", %{"id" => id})
    assert has_element?(view, "#audit-empty")
    view |> form("#assign-#{id}", %{"owner" => "token=UI_CANARY"}) |> render_submit()
    refute has_element?(view, "#evidence")

    view
    |> element("#groups-#{id} button[phx-value-status=locally_acknowledged]")
    |> render_click()

    view |> element("#snooze-#{id}") |> render_click()
    view |> form("#assign-#{id}", %{"owner" => ""}) |> render_submit()
    assert has_element?(view, "#assign-revision-#{id}[value='#{f.revision + 4}']")
    render_click(view, "evidence", %{"id" => id})
    assert {:ok, events} = Issues.audit_history(f.scope_a, id)
    assert length(events) == 4

    for event <- events,
        do: assert(has_element?(view, "#audit_events-#{event["id"]}", f.alice.name))

    assert has_element?(view, "#issue-audit-history", "token=[REDACTED]")
    refute render(view) =~ "UI_CANARY"
    render_click(view, "refresh", %{})
    refute has_element?(view, "#issue-audit-history")
  end

  test "two operators cannot overwrite a stale snapshot; refreshed controls can be retried", f do
    first = open(f, f.token_a)
    second = open(f, f.token_dual)
    id = f.group
    first |> form("#assign-#{id}", %{"owner" => "first-winner"}) |> render_submit()
    second |> form("#assign-#{id}", %{"owner" => "stale-loser"}) |> render_submit()
    assert has_element?(second, "#flash-error", "Your action was not saved")
    assert has_element?(second, "#groups-#{id}", "first-winner")
    assert has_element?(second, "#assign-revision-#{id}[value='#{f.revision + 1}']")

    for {event, extra} <- [
          {"review", %{"status" => "locally_acknowledged"}},
          {"snooze", %{}},
          {"assign", %{"owner" => ""}}
        ] do
      render_click(
        second,
        event,
        Map.merge(%{"id" => id, "revision" => to_string(f.revision)}, extra)
      )

      assert has_element?(second, "#flash-error", "changed since you viewed it")
    end

    assert {:ok, [_]} = Issues.audit_history(f.scope_a, id)

    second
    |> element("#groups-#{id} button[phx-value-status=locally_acknowledged]")
    |> render_click()

    assert {:ok, [latest, _]} = Issues.audit_history(f.scope_a, id)
    refute has_element?(second, "#flash-error")
    assert latest["actor_id"] == f.dual.id
    assert latest["after_state"]["owner"] == "first-winner"
    assert has_element?(second, "#groups-#{id}", "locally_acknowledged")
  end

  test "browser revisions fail closed and supplied actor identity cannot impersonate another operator",
       f do
    view = open(f, f.token_a)

    for revision <- [nil, "", "-1", "1junk", "999999999999999999"] do
      render_click(view, "assign", %{
        "id" => f.group,
        "owner" => "rejected",
        "revision" => revision
      })

      assert has_element?(view, "#flash-error", "valid displayed revision is required")
    end

    render_click(view, "snooze", %{"id" => f.group})
    assert has_element?(view, "#flash-error", "valid displayed revision is required")
    assert {:ok, []} = Issues.audit_history(f.scope_a, f.group)

    render_click(view, "assign", %{
      "id" => f.group,
      "owner" => "real-action",
      "revision" => to_string(f.revision),
      "actor_id" => f.bob.id,
      "actor_name" => "forged"
    })

    assert {:ok, [event]} = Issues.audit_history(f.scope_a, f.group)
    assert event["actor_id"] == f.alice.id and event["actor_name"] == f.alice.name
  end

  test "history clears across companies and revoked sessions cannot add an action", f do
    assert {:ok, updated} =
             Issues.assign(f.scope_a, f.group, "company-a-only", expected_revision: f.revision)

    view = open(f, f.token_dual)
    render_click(view, "evidence", %{"id" => f.group})
    assert has_element?(view, "#issue-audit-history", "company-a-only")
    render_patch(view, "/companies/#{f.b.id}/investigations")
    refute has_element?(view, "#issue-audit-history")
    render_click(view, "evidence", %{"id" => f.group})
    assert has_element?(view, "#audit-empty")
    refute has_element?(view, "#issue-audit-history", "company-a-only")

    render_click(view, "assign", %{
      "id" => f.group,
      "owner" => "foreign",
      "revision" => updated["revision"]
    })

    assert has_element?(view, "#flash-error", "Finding unavailable")
    revoked = open(f, f.token_a)

    TestAdminRepo.query!(
      "DELETE FROM memberships WHERE operator_id=$1::text::uuid AND company_id=$2::text::uuid",
      [f.alice.id, f.a.id]
    )

    render_click(revoked, "review", %{
      "id" => f.group,
      "status" => "closed_by_reviewer",
      "revision" => updated["revision"]
    })

    assert_redirect(revoked, "/sign-in")
    {:ok, scope} = Tenancy.authorize(f.token_dual, f.a.id)
    assert {:ok, [_]} = Issues.audit_history(scope, f.group)
  end
end
