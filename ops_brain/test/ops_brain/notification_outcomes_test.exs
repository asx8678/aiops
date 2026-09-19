defmodule OpsBrain.NotificationOutcomesTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{SourceConfig, Evidence, Store, Notifications, Issues}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    c = config(f)
    now = DateTime.utc_now()

    sink = %{
      approved: true,
      enabled: true,
      company_id: f.a.id,
      url: "https://sink.invalid/notice",
      approved_urls: ["https://sink.invalid/notice"],
      approved_ip: "192.0.2.2",
      credential_env: "OPS_BRAIN_TEST_DELIVERY",
      digest_seconds: 0
    }

    Application.put_env(:ops_brain, :notification_sinks, %{"only-company-a" => sink})
    Application.put_env(:ops_brain, :delivery_enabled, true)
    Application.put_env(:ops_brain, :clock, fn -> now end)
    System.put_env("OPS_BRAIN_TEST_DELIVERY", "synthetic-nonfunctional")
    on_exit(fn -> System.delete_env("OPS_BRAIN_TEST_DELIVERY") end)

    SourceConfig.transaction(c.id, fn cfg ->
      Evidence.failure(
        cfg,
        "one",
        %{"issues" => ["HTTP 401"], "tool" => "test", "attempt" => 1},
        1,
        now
      )
    end)

    {:ok, [out]} =
      SourceConfig.transaction(c.id, fn _ ->
        Store.rows("SELECT id::text,group_id::text FROM notification_outbox")
      end)

    Map.merge(f, %{c: c, now: now, out: out})
  end

  test "429 is durably retried at most three sends with stable delivery identity", f do
    parent = self()

    Application.put_env(:ops_brain, :notification_plug, fn conn ->
      send(parent, {:sent, Plug.Conn.get_req_header(conn, "idempotency-key")})
      conn |> Plug.Conn.put_resp_header("retry-after", "45") |> Plug.Conn.send_resp(429, "")
    end)

    for i <- 0..2 do
      now = DateTime.add(f.now, i * 45)
      Application.put_env(:ops_brain, :clock, fn -> now end)
      assert {:snooze, 45} = Notifications.deliver(f.c.id, f.out["id"], now)
      assert_receive {:sent, [id]}
      assert id == f.out["id"]
    end

    assert {:ok, {:skip, :retry_exhausted}} =
             Notifications.deliver(f.c.id, f.out["id"], DateTime.add(f.now, 135))

    refute_receive {:sent, _}
  end

  test "ambiguous provider outcome is recorded and never automatically sent again", f do
    parent = self()

    Application.put_env(:ops_brain, :notification_plug, fn conn ->
      send(parent, :sent)
      Plug.Conn.send_resp(conn, 503, "")
    end)

    assert {:ok, _} = Notifications.deliver(f.c.id, f.out["id"], f.now)
    assert_receive :sent

    assert {:error, :not_pending} =
             Notifications.deliver(f.c.id, f.out["id"], DateTime.add(f.now, 60))

    refute_receive :sent

    assert {:ok, %{"status" => "ambiguous"}} =
             SourceConfig.transaction(f.c.id, fn _ ->
               Store.one("SELECT status FROM notification_outbox")
             end)
  end

  test "local snooze defers only this application delivery", f do
    assert {:ok, _} = Issues.snooze(f.scope_a, f.out["group_id"], DateTime.add(f.now, 60), f.now)
    Application.put_env(:ops_brain, :notification_plug, fn _ -> raise "snoozed notice sent" end)
    assert {:error, :not_due} = Notifications.deliver(f.c.id, f.out["id"], f.now)
  end
end
