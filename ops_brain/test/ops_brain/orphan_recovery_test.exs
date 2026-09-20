defmodule OpsBrain.OrphanRecoveryTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{SourceConfig, Evidence, Store, Notifications}

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

  test "orphan rescue is time-based Lifeline only, with no framework pruner and leadership enabled" do
    conf = Application.fetch_env!(:ops_brain, Oban)
    plugins = Keyword.get(conf, :plugins, [])

    assert Enum.any?(plugins, &lifeline?/1)
    refute Enum.any?(plugins, &pruner?/1)
    refute Keyword.get(conf, :peer) == false
  end

  test "a rescued in-flight delivery is marked ambiguous, never re-sent", f do
    # Simulate an interrupted worker: it had already claimed (and possibly sent)
    # the outbox row before the VM died, leaving it durably in :delivering.
    assert {:ok, %{"status" => "delivering"}} =
             SourceConfig.transaction(f.c.id, fn _ ->
               Store.one(
                 "UPDATE notification_outbox SET status='delivering' WHERE id=$1::text::uuid RETURNING status",
                 [f.out["id"]]
               )
             end)

    Application.put_env(:ops_brain, :notification_plug, fn _ ->
      raise "must not re-send an ambiguous delivery on recovery"
    end)

    assert {:ok, {:skip, :ambiguous_previous_attempt}} =
             Notifications.deliver(f.c.id, f.out["id"], f.now)

    assert {:ok, %{"status" => "ambiguous"}} =
             SourceConfig.transaction(f.c.id, fn _ ->
               Store.one("SELECT status FROM notification_outbox")
             end)
  end

  test "process death after sink POST never repeats the external attempt", f do
    parent = self()

    Application.put_env(:ops_brain, :notification_plug, fn conn ->
      send(parent, {:posted, self()})

      receive do
        :continue -> Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    {pid, ref} = spawn_monitor(fn -> Notifications.deliver(f.c.id, f.out["id"], f.now) end)
    assert_receive {:posted, ^pid}, 2000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert :ok =
             OpsBrain.NotificationWorker.perform(%Oban.Job{
               args: %{"source_id" => f.c.id, "id" => f.out["id"]}
             })

    refute_receive {:posted, _}

    assert {:ok, %{"status" => "ambiguous", "attempts" => 1}} =
             SourceConfig.transaction(f.c.id, fn _ ->
               Store.one(
                 "SELECT status,attempts FROM notification_outbox WHERE id=$1::text::uuid",
                 [f.out["id"]]
               )
             end)
  end

  test "all worker execution bounds stay below rescue age" do
    for worker <- [
          OpsBrain.CollectionWorker,
          OpsBrain.EvidenceWorker,
          OpsBrain.InvestigationWorker,
          OpsBrain.NotificationWorker,
          OpsBrain.MaintenanceWorker,
          OpsBrain.DirectoryMaintenanceWorker
        ] do
      assert worker.timeout(%Oban.Job{}) == :timer.minutes(5)
    end
  end

  test "real Lifeline rescues old jobs, discards exhausted jobs and leaves live work alone" do
    name = __MODULE__.Queue

    start_supervised!(
      {Oban,
       name: name,
       repo: OpsBrain.Repo,
       queues: [],
       testing: :disabled,
       peer: Oban.Peers.Isolated,
       plugins: []}
    )

    conf = Oban.config(name)
    assert Oban.Peer.leader?(conf)

    jobs =
      for {age, attempt} <- [{660, 1}, {660, 3}, {240, 1}] do
        job = %{} |> OpsBrain.DirectoryMaintenanceWorker.new() |> OpsBrain.Repo.insert!()

        OpsBrain.Repo.query!(
          "UPDATE oban_jobs SET state='executing',attempt=$2,attempted_at=$3 WHERE id=$1",
          [job.id, attempt, DateTime.add(DateTime.utc_now(), -age)]
        )

        job.id
      end

    {:noreply, state} =
      Oban.Lifeline.handle_info(
        :rescue,
        %Oban.Lifeline{conf: conf, rescue_after: :timer.minutes(10)}
      )

    Process.cancel_timer(state.timer)

    states =
      for id <- jobs do
        %{rows: [[state]]} = OpsBrain.Repo.query!("SELECT state FROM oban_jobs WHERE id=$1", [id])
        state
      end

    assert states == ["available", "discarded", "executing"]
  end

  defp lifeline?(Oban.Lifeline), do: true
  defp lifeline?({Oban.Lifeline, _}), do: true
  defp lifeline?(_), do: false

  defp pruner?(Oban.Pruner), do: true
  defp pruner?({Oban.Pruner, _}), do: true
  defp pruner?(_), do: false
end
