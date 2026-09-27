defmodule OpsBrain.NotificationRevisionTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{Evidence, Issues, Notifications, SourceConfig}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    c = config(f)
    now = DateTime.utc_now()
    Application.put_env(:ops_brain, :clock, fn -> now end)
    Application.put_env(:ops_brain, :delivery_enabled, true)

    Application.put_env(:ops_brain, :notification_sinks, %{
      "reviewed" => %{
        approved: true,
        enabled: true,
        company_id: f.a.id,
        url: "https://sink.invalid/notice",
        approved_urls: ["https://sink.invalid/notice"],
        approved_ip: "192.0.2.2",
        credential_env: "TEST_REVISION_SINK",
        digest_seconds: 0
      }
    })

    System.put_env("TEST_REVISION_SINK", "synthetic-nonfunctional")
    on_exit(fn -> System.delete_env("TEST_REVISION_SINK") end)
    record(c, "one", now)
    {:ok, [group]} = Issues.list(f.scope_a)
    {:ok, [out]} = Notifications.status(f.scope_a, group["id"])
    Map.merge(f, %{c: c, now: now, group: group["id"], out: out})
  end

  defp record(c, key, now) do
    SourceConfig.transaction(c.id, fn trusted ->
      Evidence.failure(
        trusted,
        key,
        %{"issues" => ["HTTP 401"], "tool" => "test", "attempt" => 1},
        1,
        now
      )
    end)
  end

  defp capture(status, parent) do
    Application.put_env(:ops_brain, :notification_plug, fn conn ->
      refute Repo.in_transaction?()
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        parent,
        {:sent, Plug.Conn.get_req_header(conn, "idempotency-key"), Jason.decode!(body)}
      )

      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  test "assignment, unassignment and review preserve the pending identity and deliver current state",
       f do
    assert {:ok, _} =
             Issues.assign(f.scope_a, f.group, "on-call",
               expected_revision: issue_revision(f.scope_a, f.group)
             )

    assert {:ok, _} =
             Issues.unassign(f.scope_a, f.group,
               expected_revision: issue_revision(f.scope_a, f.group)
             )

    assert {:ok, _} =
             Issues.review(f.scope_a, f.group, "locally_acknowledged",
               expected_revision: issue_revision(f.scope_a, f.group)
             )

    {:ok, [before]} = Notifications.status(f.scope_a, f.group)
    assert before["id"] == f.out["id"]
    assert before["next_at"] == f.out["next_at"]
    assert before["status"] == "pending" and before["attempts"] == 0
    {:ok, [group]} = Issues.list(f.scope_a)

    capture(200, self())

    assert :ok =
             OpsBrain.NotificationWorker.perform(%Oban.Job{
               args: %{"source_id" => f.c.id, "id" => f.out["id"]}
             })

    assert_receive {:sent, [id], payload}
    assert id == f.out["id"]
    assert payload["revision"] == group["revision"]
    assert payload["status"] == "locally_acknowledged"

    assert {:ok, [%{"status" => "delivered", "attempts" => 1}]} =
             Notifications.status(f.scope_a, f.group)
  end

  test "local edits during HTTP preserve Retry-After, attempts and the idempotency key", f do
    parent = self()

    Application.put_env(:ops_brain, :notification_plug, fn conn ->
      refute Repo.in_transaction?()

      assert {:ok, _} =
               Issues.assign(f.scope_a, f.group, "during-send",
                 expected_revision: issue_revision(f.scope_a, f.group)
               )

      send(parent, {:first_send, Plug.Conn.get_req_header(conn, "idempotency-key")})
      conn |> Plug.Conn.put_resp_header("retry-after", "90") |> Plug.Conn.send_resp(429, "")
    end)

    assert {:snooze, 90} = Notifications.deliver(f.c.id, f.out["id"], f.now)
    assert_receive {:first_send, [id]}
    assert id == f.out["id"]

    assert {:ok, [%{"status" => "pending", "attempts" => 1} = pending]} =
             Notifications.status(f.scope_a, f.group)

    assert DateTime.diff(pending["next_at"], f.now) == 90

    assert {:ok, _} =
             Issues.unassign(f.scope_a, f.group,
               expected_revision: issue_revision(f.scope_a, f.group)
             )

    assert {:error, :not_due} = Notifications.deliver(f.c.id, id, DateTime.add(f.now, 89))

    capture(200, self())
    assert {:ok, _} = Notifications.deliver(f.c.id, id, DateTime.add(f.now, 90))
    assert_receive {:sent, [^id], _}

    assert {:ok, [%{"status" => "delivered", "attempts" => 2}]} =
             Notifications.status(f.scope_a, f.group)
  end

  test "a real newer outbox entry still supersedes an older rate-limited delivery", f do
    Application.put_env(:ops_brain, :notification_plug, fn conn ->
      refute Repo.in_transaction?()
      assert {:ok, _} = record(f.c, "new-during-send", DateTime.add(f.now, 1))
      conn |> Plug.Conn.put_resp_header("retry-after", "60") |> Plug.Conn.send_resp(429, "")
    end)

    assert {:snooze, 60} = Notifications.deliver(f.c.id, f.out["id"], f.now)
    {:ok, rows} = Notifications.status(f.scope_a, f.group)
    assert length(rows) == 2
    fresh = Enum.find(rows, &(&1["id"] != f.out["id"]))
    capture(200, self())

    assert {:ok, {:skip, :coalesced}} =
             Notifications.deliver(f.c.id, f.out["id"], DateTime.add(f.now, 60))

    assert {:ok, _} = Notifications.deliver(f.c.id, fresh["id"], DateTime.add(f.now, 60))
    assert_receive {:sent, [id], _}
    assert id == fresh["id"]
    refute_receive {:sent, _, _}
  end

  for {status, outcome} <- [{200, "delivered"}, {503, "ambiguous"}, {403, "rejected"}] do
    test "local edits do not resurrect #{outcome} notifications", f do
      capture(unquote(status), self())
      assert {:ok, _} = Notifications.deliver(f.c.id, f.out["id"], f.now)
      assert_receive {:sent, _, _}

      assert {:ok, _} =
               Issues.assign(f.scope_a, f.group, "later-owner",
                 expected_revision: issue_revision(f.scope_a, f.group)
               )

      assert {:ok, _} =
               Issues.review(f.scope_a, f.group, "active",
                 expected_revision: issue_revision(f.scope_a, f.group)
               )

      assert {:error, :not_pending} =
               Notifications.deliver(f.c.id, f.out["id"], DateTime.add(f.now, 60))

      assert {:ok, [%{"status" => unquote(outcome)}]} = Notifications.status(f.scope_a, f.group)
      refute_receive {:sent, _, _}
    end
  end

  test "foreign company updates and source claims cannot alter the pending notice", f do
    other = config(f, :b)

    assert {:ok, nil} =
             Issues.assign(f.scope_b, f.group, "foreign",
               expected_revision: issue_revision(f.scope_a, f.group)
             )

    assert {:ok, []} = Notifications.status(f.scope_b, f.group)
    assert {:error, :not_found} = Notifications.deliver(other.id, f.out["id"], f.now)

    assert {:ok, [%{"status" => "pending", "attempts" => 0}]} =
             Notifications.status(f.scope_a, f.group)
  end
end
