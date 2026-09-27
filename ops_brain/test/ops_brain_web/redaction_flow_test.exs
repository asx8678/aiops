defmodule OpsBrainWeb.RedactionFlowTest do
  use OpsBrainWeb.ConnCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{Evidence, Issues, Notifications, SourceConfig, Store}

  test "source OAuth canaries are absent from persisted evidence, UI and delivery", %{conn: conn} do
    f = fixture()
    c = config(f)
    now = DateTime.utc_now()
    on_exit(&cleanup/0)
    Application.put_env(:ops_brain, :clock, fn -> now end)
    Application.put_env(:ops_brain, :delivery_enabled, true)

    Application.put_env(:ops_brain, :notification_sinks, %{
      "redaction-test" => %{
        approved: true,
        enabled: true,
        company_id: f.a.id,
        url: "https://sink.invalid/notice",
        approved_urls: ["https://sink.invalid/notice"],
        approved_ip: "192.0.2.2",
        credential_env: "TEST_REDACTION_SINK",
        digest_seconds: 0
      }
    })

    System.put_env("TEST_REDACTION_SINK", "synthetic-nonfunctional")
    on_exit(fn -> System.delete_env("TEST_REDACTION_SINK") end)
    parent = self()

    Application.put_env(:ops_brain, :notification_plug, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:delivered, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    messages = [
      ~s({"access_token":"CANARY_ACCESS","refresh_token":"CANARY_REFRESH","client_secret":"CANARY_CLIENT"}),
      ~s({"token":"CANARY_TRUNCATED trailing secret),
      "clientSecret='CANARY_ASSIGNMENT alpha beta'"
    ]

    body =
      Jason.encode!(%{
        "records" => [
          %{
            "id" => "failed-step",
            "parentId" => "job",
            "result" => "failed",
            "attempt" => 1,
            "type" => "Task",
            "finishTime" => Store.iso(now),
            "issues" => Enum.map(messages, &%{"message" => &1})
          }
        ]
      })

    assert {:ok, [record]} = Evidence.parse_timeline(body)

    assert {:ok, evidence_id} =
             SourceConfig.transaction(c.id, fn trusted ->
               Evidence.failure(trusted, "oauth-source-message", record, 101, now)
             end)

    assert {:ok, [%{"id" => group_id}]} = Issues.list(f.scope_a)
    assert {:ok, [item]} = Issues.evidence(f.scope_a, group_id, now)
    assert item["id"] == evidence_id
    refute Jason.encode!(item) =~ "CANARY_"
    assert Jason.encode!(item) =~ "[REDACTED]"
    assert {:ok, revisions} = Issues.revisions(f.scope_a, group_id, now)
    refute Jason.encode!(revisions) =~ "CANARY_"

    conn = init_test_session(conn, operator_token: f.token_a)
    assert {:ok, view, _} = live(conn, "/companies/#{f.a.id}/investigations")
    render_click(view, "evidence", %{"id" => group_id})
    assert has_element?(view, "#evidence", "[REDACTED]")
    refute has_element?(view, "#evidence", "CANARY_")
    refute has_element?(view, "#issue-groups", "CANARY_")

    assert {:ok, [out]} = Notifications.status(f.scope_a, group_id)
    assert {:ok, _} = Notifications.deliver(c.id, out["id"], now)
    assert_receive {:delivered, payload}
    assert payload["text"] =~ "[REDACTED]"
    refute Jason.encode!(payload) =~ "CANARY_"
  end
end
